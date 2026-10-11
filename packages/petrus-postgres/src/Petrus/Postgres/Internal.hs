{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | The connection core shared by the public modules: the connection
-- record, the statement runner (asynchronous libpq calls, cancellation on
-- asynchronous exceptions) and error construction.
module Petrus.Postgres.Internal
  ( -- * Connections
    Connection (..)
  , Isolation (..)
  , beginStatement
  , withLockedConnection
  , ensureOpen

    -- * Prepared statements
  , PrepareCache
  , emptyPrepareCache
  , discardPrepared
  , maintainPrepared

    -- * Running statements
  , runStatement
  , runCommand
  , waitReadable
  , waitReadableFor

    -- * Results
  , Result (..)

    -- * Errors
  , PostgresError (..)
  , ErrorClass (..)
  , errorClassForState
  , connectionFailure
  , clientError
  , stripSeverity
  , decodeLenient
  ) where

import Control.Concurrent (rtsSupportsBoundThreads, threadWaitRead)
import Control.Concurrent.MVar (MVar, withMVar)
import Control.Exception (Exception (..), finally, mask, onException, throwIO, uninterruptibleMask_)
import Control.Monad (unless, void, when, (>=>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Database.PostgreSQL.LibPQ qualified as PQ
import Database.PostgreSQL.LibPQ.Internal (PGconn, withConn)
import Foreign.C.Error (Errno (..), eINTR, errnoToIOError)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, nullPtr)
import Petrus.Postgres.Param (Param (..), ParamFormat (..), Sql, sqlConverted, sqlRaw)
import GHC.Clock (getMonotonicTime)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | One PostgreSQL connection (psycopg's @Connection@). Operations on it
-- are serialized by an internal lock, as psycopg serializes them.
data Connection = Connection
  { rawConnection :: PQ.Connection
  , connectionLock :: MVar ()
  , autocommitRef :: IORef Bool
  , closedRef :: IORef Bool
  , connectionIsolation :: Isolation
  , prepareThreshold :: Maybe Int
  -- ^ psycopg's @prepare_threshold@: executions of a statement before it
  -- is prepared ('Nothing' never prepares).
  , preparedMax :: Int
  -- ^ psycopg's @prepared_max@.
  , prepareCacheRef :: IORef PrepareCache
  }

-- | The isolation level transactions start with.
data Isolation
  = -- | @BEGIN ISOLATION LEVEL READ COMMITTED@: what upstream's
    -- verify-on-conflict re-reads rely on, made explicit (the default).
    ReadCommitted
  | -- | @BEGIN@: the server's @default_transaction_isolation@ (psycopg's
    -- default when no isolation level is set).
    ServerDefault
  | RepeatableRead
  | Serializable
  deriving stock (Eq, Show)

-- | The statement that opens a transaction, as psycopg spells it.
beginStatement :: Isolation -> ByteString
beginStatement = \case
  ReadCommitted -> "BEGIN ISOLATION LEVEL READ COMMITTED"
  ServerDefault -> "BEGIN"
  RepeatableRead -> "BEGIN ISOLATION LEVEL REPEATABLE READ"
  Serializable -> "BEGIN ISOLATION LEVEL SERIALIZABLE"

-- * Prepared statements

-- | psycopg's @PrepareManager@ (psycopg/_preparing.py), state for state:
-- a statement (its text as sent and its parameter type OIDs) executed
-- @prepare_threshold@ times is prepared on the server as @_pg3_<n>@ and
-- executed by name from then on, which skips the server's parse and plan.
-- At most @prepared_max@ statements stay prepared (and as many counted),
-- least recently used first out; a @ROLLBACK@, or a newly seen statement
-- answering @DROP …@, discards them all with @DEALLOCATE ALL@.
data PrepareCache = PrepareCache
  { cacheCounts :: Map PrepareKey (Word64, Int)
  -- ^ Statements not prepared yet: recency stamp and executions so far.
  , cacheNames :: Map PrepareKey (Word64, ByteString)
  -- ^ Prepared statements: recency stamp and name.
  , cacheClock :: Word64
  -- ^ The next recency stamp (stands for the OrderedDicts' order).
  , cacheIndex :: Int
  -- ^ The next statement name's number.
  , cacheFlush :: [Maybe ByteString]
  -- ^ Pending deallocations, oldest first ('Nothing' is @DEALLOCATE ALL@).
  }

type PrepareKey = (ByteString, [Word32])

emptyPrepareCache :: PrepareCache
emptyPrepareCache = PrepareCache Map.empty Map.empty 0 0 []

data Prepare = PrepareNo | PrepareYes ByteString | PrepareShould ByteString
  deriving stock (Eq)

-- | @PrepareManager.get@: whether to run unprepared, by an existing name,
-- or to prepare under a new name first (which consumes the name).
prepareDecision :: Maybe Int -> PrepareKey -> PrepareCache -> (Prepare, PrepareCache)
prepareDecision threshold key cache = case threshold of
  Nothing -> (PrepareNo, cache)
  Just limit
    | Just (_, name) <- Map.lookup key (cacheNames cache) -> (PrepareYes name, cache)
    | maybe 0 snd (Map.lookup key (cacheCounts cache)) >= limit ->
        ( PrepareShould ("_pg3_" <> BC.pack (show (cacheIndex cache)))
        , cache {cacheIndex = cacheIndex cache + 1}
        )
    | otherwise -> (PrepareNo, cache)

-- | @PrepareManager.maybe_add_to_cache@: record the execution; 'True' when
-- the statement was not known before (and its results must be validated).
recordExecution :: Maybe Int -> PrepareKey -> Prepare -> PrepareCache -> (Bool, PrepareCache)
recordExecution threshold key prep cache
  | Nothing <- threshold = (False, cache)
  | Just (_, count) <- Map.lookup key (cacheCounts cache) = case prep of
      PrepareShould name ->
        (False, stamped {cacheCounts = Map.delete key (cacheCounts cache), cacheNames = Map.insert key (stamp, name) (cacheNames cache)})
      _ -> (False, stamped {cacheCounts = Map.insert key (stamp, count + 1) (cacheCounts cache)})
  | Just (_, name) <- Map.lookup key (cacheNames cache) =
      (False, stamped {cacheNames = Map.insert key (stamp, name) (cacheNames cache)})
  | otherwise = case prep of
      PrepareShould name -> (True, stamped {cacheNames = Map.insert key (stamp, name) (cacheNames cache)})
      _ -> (True, stamped {cacheCounts = Map.insert key (stamp, 1) (cacheCounts cache)})
  where
    stamp = cacheClock cache
    stamped = cache {cacheClock = stamp + 1}

-- | @PrepareManager.validate@ for a newly recorded statement, given each
-- result's status and command tag.
validateExecution :: Int -> PrepareKey -> Prepare -> [(CInt, ByteString)] -> PrepareCache -> PrepareCache
validateExecution limit key prep results cache
  | not (Map.null (cacheNames cache)) || isShould prep
  , any (\(status, tag) -> status == statusCommandOk && ("DROP " `BS.isPrefixOf` tag || tag == "ROLLBACK")) results =
      discardPrepared cache
  | not usable = cache {cacheNames = Map.delete key (cacheNames cache), cacheCounts = Map.delete key (cacheCounts cache)}
  | otherwise = rotate
  where
    isShould = \case
      PrepareShould _ -> True
      _ -> False
    usable = case results of
      [(status, _)] -> status == statusCommandOk || status == statusTuplesOk
      _ -> False
    rotate =
      let counts = cacheCounts cache
          names = cacheNames cache
          counts'
            | Map.size counts > limit = maybe counts (`Map.delete` counts) (oldest counts)
            | otherwise = counts
          (names', flush')
            | Map.size names > limit, Just evicted <- oldest names =
                (Map.delete evicted names, cacheFlush cache ++ maybe [] (\(_, name) -> [Just name]) (Map.lookup evicted names))
            | otherwise = (names, cacheFlush cache)
       in cache {cacheCounts = counts', cacheNames = names', cacheFlush = flush'}
    oldest :: Map PrepareKey (Word64, a) -> Maybe PrepareKey
    oldest entries =
      fst
        <$> Map.foldlWithKey'
          (\best k (s, _) -> case best of
              Just (_, b) | b <= s -> best
              _ -> Just (k, s))
          Nothing
          entries

-- | @PrepareManager.clear@: forget every statement; when some were
-- prepared, schedule @DEALLOCATE ALL@.
discardPrepared :: PrepareCache -> PrepareCache
discardPrepared cache
  | Map.null (cacheNames cache) = cache {cacheCounts = Map.empty}
  | otherwise = cache {cacheCounts = Map.empty, cacheNames = Map.empty, cacheFlush = [Nothing]}

-- | @PrepareManager.maintain_gen@: run the pending deallocations (as
-- psycopg does without libpq 17's @PQsendClosePrepared@: @DEALLOCATE@
-- statements).
maintainPrepared :: Connection -> PQ.Connection -> IO ()
maintainPrepared connection raw = do
  cache <- readIORef (prepareCacheRef connection)
  case cacheFlush cache of
    [] -> pure ()
    next : rest -> do
      writeIORef (prepareCacheRef connection) cache {cacheFlush = rest}
      runCommand raw (maybe "DEALLOCATE ALL" ("DEALLOCATE " <>) next)
      maintainPrepared connection raw

-- | One statement's outcome (psycopg's cursor after @execute@).
data Result = Result
  { resultColumns :: [Text]
  -- ^ Column names (@cursor.description@ names); empty for commands.
  , resultRows :: [[Maybe ByteString]]
  -- ^ Every row, each value in PostgreSQL's text output format ('Nothing'
  -- for @NULL@); decode with "Petrus.Postgres.Value".
  , resultRowCount :: Int
  -- ^ @cursor.rowcount@: the number of rows returned, else the rows the
  -- command affected, else -1.
  , resultCommand :: Text
  -- ^ @cursor.statusmessage@, e.g. @INSERT 0 1@.
  }
  deriving stock (Eq, Show)

-- | psycopg's DB-API exception classes.
data ErrorClass
  = InterfaceError
  | DataError
  | OperationalError
  | IntegrityError
  | InternalError
  | ProgrammingError
  | NotSupportedError
  | -- | @psycopg.DatabaseError@ itself (an SQLSTATE with no narrower class).
    DatabaseError
  deriving stock (Eq, Show)

-- | A PostgreSQL failure (psycopg's @psycopg.Error@ family).
data PostgresError = PostgresError
  { errorClass :: ErrorClass
  -- ^ The psycopg class the error would be raised as.
  , errorSqlState :: Maybe Text
  -- ^ @e.sqlstate@ (e.g. @55P03@ for @LockNotAvailable@); 'Nothing' for
  -- client-side failures.
  , errorMessage :: Text
  -- ^ @str(e)@: libpq's message with the severity prefix and surrounding
  -- whitespace stripped.
  , errorSeverity :: Maybe Text
  , errorPrimary :: Maybe Text
  -- ^ @e.diag.message_primary@.
  , errorDetail :: Maybe Text
  , errorHint :: Maybe Text
  }
  deriving stock (Eq, Show)

instance Exception PostgresError where
  displayException = T.unpack . errorMessage

-- | psycopg's class for an SQLSTATE (@psycopg.errors.get_base_exception@).
errorClassForState :: Text -> ErrorClass
errorClassForState state = case T.take 2 state of
  "08" -> OperationalError
  "0A" -> NotSupportedError
  "10" -> ProgrammingError
  "20" -> ProgrammingError
  "21" -> ProgrammingError
  "22" -> DataError
  "23" -> IntegrityError
  "24" -> InternalError
  "25" -> InternalError
  "26" -> ProgrammingError
  "27" -> OperationalError
  "28" -> OperationalError
  "2B" -> InternalError
  "2D" -> InternalError
  "2F" -> OperationalError
  "34" -> ProgrammingError
  "38" -> OperationalError
  "39" -> OperationalError
  "3B" -> OperationalError
  "3D" -> ProgrammingError
  "3F" -> ProgrammingError
  "40" -> OperationalError
  "42" -> ProgrammingError
  "44" -> ProgrammingError
  "53" -> OperationalError
  "54" -> OperationalError
  "55" -> OperationalError
  "57" -> OperationalError
  "58" -> OperationalError
  _ -> case T.take 1 state of
    "F" -> OperationalError
    "H" -> OperationalError
    "P" -> ProgrammingError
    "X" -> InternalError
    _ -> DatabaseError

-- | psycopg's @strip_severity@ for English server messages: drop a leading
-- @ERROR:@ (or another severity) and the whitespace after it, then strip.
stripSeverity :: Text -> Text
stripSeverity message = T.strip (fromMaybe message stripped)
  where
    stripped = do
      let (word, rest) = T.break (== ':') message
      unless (word `elem` severities) Nothing
      let afterColon = T.drop 1 rest
          body = T.dropWhile isPythonSpace afterColon
      when (T.length body == T.length afterColon) Nothing
      pure body
    severities = ["DEBUG", "INFO", "NOTICE", "WARNING", "ERROR", "LOG", "FATAL", "PANIC"]
    isPythonSpace c = c == ' ' || (c >= '\t' && c <= '\r')

-- | Text from libpq bytes, replacing invalid UTF-8 (psycopg decodes with
-- @errors="replace"@).
decodeLenient :: ByteString -> Text
decodeLenient = TE.decodeUtf8With TE.lenientDecode

-- | A client-side failure of the given class.
clientError :: ErrorClass -> Text -> PostgresError
clientError cls message = PostgresError cls Nothing message Nothing Nothing Nothing Nothing

-- | A connection-level failure: the given prefix and libpq's connection
-- error message.
connectionFailure :: PQ.Connection -> Text -> IO PostgresError
connectionFailure raw prefix = do
  message <- maybe "" decodeLenient <$> PQ.errorMessage raw
  let cleaned = stripSeverity message
  pure (clientError OperationalError (prefix <> (if T.null cleaned then "no error details available" else cleaned)))

-- | Fail with psycopg's message when the connection was closed.
ensureOpen :: Connection -> IO ()
ensureOpen connection = do
  closed <- readIORef (closedRef connection)
  when closed (throwIO (clientError OperationalError "the connection is closed"))

-- | Run an action holding the connection lock, after checking that the
-- connection is open.
withLockedConnection :: Connection -> (PQ.Connection -> IO a) -> IO a
withLockedConnection connection action =
  withMVar (connectionLock connection) $ \() -> do
    ensureOpen connection
    action (rawConnection connection)

-- | Wait until the connection's socket is readable.
waitReadable :: PQ.Connection -> IO ()
waitReadable raw = void (waitReadableFor raw Nothing)

-- | Wait until the connection's socket is readable ('True') or the given
-- number of seconds elapses ('False'). With the threaded runtime the wait
-- is an interruptible @poll(2)@ on the calling OS thread, which wakes as
-- fast as psycopg's own @poll@ wait (the IO manager's event round trip
-- costs several microseconds per wake-up); asynchronous exceptions still
-- interrupt it. The non-threaded runtime uses the IO manager.
waitReadableFor :: PQ.Connection -> Maybe Double -> IO Bool
waitReadableFor raw limit =
  PQ.socket raw >>= \case
    Nothing -> connectionFailure raw "the connection is lost: " >>= throwIO
    Just fd@(Fd descriptor)
      | rtsSupportsBoundThreads -> do
          deadline <- traverse (\seconds -> (+ seconds) <$> getMonotonicTime) limit
          let loop = do
                milliseconds <- case deadline of
                  Nothing -> pure (-1)
                  Just end -> do
                    now <- getMonotonicTime
                    pure (max 0 (ceiling ((end - now) * 1000)))
                rc <- c_waitReadable descriptor milliseconds
                if
                  | rc > 0 -> pure True
                  | rc == 0 -> pure False
                  | Errno (negate rc) == eINTR -> loop
                  | otherwise -> throwIO (errnoToIOError "poll" (Errno (negate rc)) Nothing Nothing)
          loop
      | otherwise -> case limit of
          Nothing -> True <$ threadWaitRead fd
          Just seconds -> isJust <$> timeout (max 1 (ceiling (seconds * 1e6))) (threadWaitRead fd)

foreign import ccall interruptible "petrus_pg_wait_readable"
  c_waitReadable :: CInt -> CInt -> IO CInt

-- | Send with the given action and collect every result. An asynchronous
-- exception while waiting cancels the running statement on the server and
-- drains its results before being rethrown, so the connection stays
-- usable. The results must be freed with 'clearResults'.
sendAndCollect :: PQ.Connection -> Text -> IO Bool -> IO [Ptr PGresult]
sendAndCollect raw failurePrefix send = mask $ \restore -> do
  sent <- send
  unless sent (connectionFailure raw failurePrefix >>= throwIO)
  let collect acc = do
        busy <- withConn raw c_PQisBusy
        if busy /= 0
          then do
            (restore (waitReadable raw) `onException` cancelAndDrain raw) `onException` clearResults acc
            consumed <- withConn raw c_PQconsumeInput
            when (consumed == 0) $ do
              clearResults acc
              connectionFailure raw "consuming input failed: " >>= throwIO
            collect acc
          else do
            result <- withConn raw c_PQgetResult
            if result == nullPtr then pure (reverse acc) else collect (result : acc)
  collect []

clearResults :: [Ptr PGresult] -> IO ()
clearResults = mapM_ c_PQclear

-- Result access goes through direct unsafe calls: these libpq functions only
-- read the result (or the already-received input) and never block, and the
-- per-value safe calls of postgresql-libpq's accessors cost microseconds
-- each on large results.
data PGresult

foreign import ccall unsafe "PQisBusy" c_PQisBusy :: Ptr PGconn -> IO CInt
foreign import ccall unsafe "PQconsumeInput" c_PQconsumeInput :: Ptr PGconn -> IO CInt
foreign import ccall unsafe "PQgetResult" c_PQgetResult :: Ptr PGconn -> IO (Ptr PGresult)
foreign import ccall unsafe "PQclear" c_PQclear :: Ptr PGresult -> IO ()
foreign import ccall unsafe "PQresultStatus" c_PQresultStatus :: Ptr PGresult -> IO CInt
foreign import ccall unsafe "PQntuples" c_PQntuples :: Ptr PGresult -> IO CInt
foreign import ccall unsafe "PQnfields" c_PQnfields :: Ptr PGresult -> IO CInt
foreign import ccall unsafe "PQfname" c_PQfname :: Ptr PGresult -> CInt -> IO CString
foreign import ccall unsafe "PQgetvalue" c_PQgetvalue :: Ptr PGresult -> CInt -> CInt -> IO CString
foreign import ccall unsafe "PQgetlength" c_PQgetlength :: Ptr PGresult -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "PQgetisnull" c_PQgetisnull :: Ptr PGresult -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "PQcmdStatus" c_PQcmdStatus :: Ptr PGresult -> IO CString
foreign import ccall unsafe "PQcmdTuples" c_PQcmdTuples :: Ptr PGresult -> IO CString
foreign import ccall unsafe "PQresultErrorField" c_PQresultErrorField :: Ptr PGresult -> CInt -> IO CString
foreign import ccall unsafe "PQresultErrorMessage" c_PQresultErrorMessage :: Ptr PGresult -> IO CString

-- libpq's ExecStatusType values.
statusEmptyQuery, statusCommandOk, statusTuplesOk, statusFatalError :: CInt
statusEmptyQuery = 0
statusCommandOk = 1
statusTuplesOk = 2
statusFatalError = 7

cText :: CString -> IO Text
cText ptr
  | ptr == nullPtr = pure ""
  | otherwise = decodeLenient <$> BS.packCString ptr

cBytes :: CString -> IO ByteString
cBytes ptr
  | ptr == nullPtr = pure BS.empty
  | otherwise = BS.packCString ptr

cMaybeText :: CString -> IO (Maybe Text)
cMaybeText ptr
  | ptr == nullPtr = pure Nothing
  | otherwise = Just . decodeLenient <$> BS.packCString ptr

cancelAndDrain :: PQ.Connection -> IO ()
cancelAndDrain raw = uninterruptibleMask_ $ do
  PQ.getCancel raw >>= mapM_ (void . PQ.cancel)
  let drain = do
        busy <- PQ.isBusy raw
        if busy
          then do
            readable <- PQ.socket raw
            case readable of
              Nothing -> pure ()
              Just fd -> do
                threadWaitRead fd
                consumed <- PQ.consumeInput raw
                when consumed drain
          else PQ.getResult raw >>= maybe (pure ()) (const drain)
  drain

-- | Run a statement the way psycopg's @execute@ does on a locked
-- connection: open the transaction first when the connection is not in
-- autocommit mode and is idle; use the simple query protocol when there
-- are no parameters (several statements allowed, the text sent as
-- written) and the extended protocol otherwise. Every result is checked;
-- all are returned.
--
-- Statements go through psycopg's prepared-statement cache (see
-- 'PrepareCache'): once a statement has run @prepare_threshold@ times on
-- this connection it is prepared under psycopg's name (one extra round
-- trip, once) and executed by name afterwards, with or without
-- parameters.
runStatement :: Connection -> PQ.Connection -> Sql -> [Param] -> IO [Result]
runStatement connection raw statement params = do
  autocommit <- readIORef (autocommitRef connection)
  unless autocommit $ do
    status <- PQ.transactionStatus raw
    when (status == PQ.TransIdle) (runCommand raw (beginStatement (connectionIsolation connection)))
  (text, wire) <-
    if null params
      then do
        let text = sqlRaw statement
        when (BS.elem 0 text) (throwIO (clientError DataError "PostgreSQL text fields cannot contain NUL (0x00) bytes"))
        pure (text, Nothing)
      else do
        (converted, placeholders) <- either (throwIO . clientError ProgrammingError) pure (sqlConverted statement)
        when (placeholders /= length params) $
          throwIO
            ( clientError
                ProgrammingError
                ( "the query has "
                    <> T.pack (show placeholders)
                    <> " placeholders but "
                    <> T.pack (show (length params))
                    <> " parameters were passed"
                )
            )
        wire <- mapM toWire params
        pure (converted, Just wire)
  let threshold = prepareThreshold connection
      key = (text, maybe [] (map wireOid) wire)
      cacheRef = prepareCacheRef connection
  prep <- do
    (decision, cache) <- prepareDecision threshold key <$> readIORef cacheRef
    writeIORef cacheRef cache
    pure decision
  newKey <- newIORefBool
  let record = do
        (added, cache) <- recordExecution threshold key prep <$> readIORef cacheRef
        writeIORef cacheRef cache
        writeIORef newKey added
      values = maybe [] (map wireValue) wire
  results <- case prep of
    PrepareNo -> case wire of
      Nothing -> sendAndCollect raw "sending query failed: " (sentThen record (PQ.sendQuery raw text))
      Just ws -> sendAndCollect raw "sending query and params failed: " (sentThen record (PQ.sendQueryParams raw text (map libpqParam ws) PQ.Text))
    PrepareYes name ->
      sendAndCollect raw "sending prepared query failed: " (sentThen record (PQ.sendQueryPrepared raw name values PQ.Text))
    PrepareShould name -> do
      prepared <- sendAndCollect raw "sending query failed: " (PQ.sendPrepare raw name text (Just (map (PQ.Oid . fromIntegral) (snd key))))
      mapM_ checkResult prepared `finally` clearResults prepared
      sendAndCollect raw "sending prepared query failed: " (sentThen record (PQ.sendQueryPrepared raw name values PQ.Text))
  flip finally (clearResults results) $ do
    added <- readIORef newKey
    when added $ do
      shapes <- mapM (\result -> (,) <$> c_PQresultStatus result <*> (c_PQcmdStatus result >>= cBytes)) results
      cache <- readIORef cacheRef
      writeIORef cacheRef (validateExecution (preparedMax connection) key prep shapes cache)
    mapM_ checkResult results
    rows <- mapM readResult results
    maintainPrepared connection raw
    pure rows
  where
    toWire (Param oid value format) = case value of
      Nothing -> pure (oid, Nothing)
      Just bytes -> do
        when (format == TextFormat && BS.elem 0 bytes) $
          throwIO (clientError DataError "PostgreSQL text fields cannot contain NUL (0x00) bytes")
        pure (oid, Just (bytes, if format == TextFormat then PQ.Text else PQ.Binary))
    wireOid (oid, value) = maybe 0 (const oid) value
    libpqParam (oid, value) = (\(bytes, format) -> (PQ.Oid (fromIntegral oid), bytes, format)) <$> value
    wireValue = snd
    sentThen after send = do
      sent <- send
      when sent after
      pure sent
    newIORefBool = newIORef False

-- | Run a parameterless command (@BEGIN@, @COMMIT@, @ROLLBACK@) on a
-- locked connection, outside the implicit-transaction rule.
runCommand :: PQ.Connection -> ByteString -> IO ()
runCommand raw command = do
  results <- sendAndCollect raw "sending query failed: " (PQ.sendQuery raw command)
  mapM_ checkResult results `finally` clearResults results

checkResult :: Ptr PGresult -> IO ()
checkResult result = do
  status <- c_PQresultStatus result
  if
    | status == statusTuplesOk || status == statusCommandOk || status == statusEmptyQuery -> pure ()
    | status == statusFatalError -> resultError result >>= throwIO
    | otherwise -> throwIO (clientError InternalError ("unexpected result status from query: " <> T.pack (show status)))

resultError :: Ptr PGresult -> IO PostgresError
resultError result = do
  let field code = c_PQresultErrorField result (fromIntegral (fromEnum code)) >>= cMaybeText
  state <- field 'C'
  severity <- field 'S'
  primary <- field 'M'
  detail <- field 'D'
  hint <- field 'H'
  message <- c_PQresultErrorMessage result >>= cText
  let cleaned = stripSeverity message
  pure
    PostgresError
      { errorClass = maybe DatabaseError errorClassForState state
      , errorSqlState = state
      , errorMessage = if T.null cleaned then "no error details available" else cleaned
      , errorSeverity = severity
      , errorPrimary = primary
      , errorDetail = detail
      , errorHint = hint
      }

readResult :: Ptr PGresult -> IO Result
readResult result = do
  status <- c_PQresultStatus result
  columnCount <- c_PQnfields result
  rowCount <- c_PQntuples result
  names <- mapM (c_PQfname result >=> cText) (range columnCount)
  let value r c = do
        isNull <- c_PQgetisnull result r c
        if isNull /= 0
          then pure Nothing
          else do
            ptr <- c_PQgetvalue result r c
            len <- c_PQgetlength result r c
            Just <$> BS.packCStringLen (ptr, fromIntegral len)
      row r = mapM (value r) (range columnCount)
  rows <- mapM row (range rowCount)
  command <- c_PQcmdStatus result >>= cText
  affected <- c_PQcmdTuples result >>= cText
  let count
        | status == statusTuplesOk = fromIntegral rowCount
        | otherwise = fromMaybe (-1) (readMaybe (T.unpack affected))
  pure Result {resultColumns = names, resultRows = rows, resultRowCount = count, resultCommand = command}
  where
    range n = [0 .. n - 1]
