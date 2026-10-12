-- | Canonical, restart-safe host custody for V5 reminder timers
-- (@host/v5/timers.py@).
--
-- @timers.sqlite3@ has the reference's exact DDL, statements, and
-- canonical JSON columns, so either host can resume the other's ledger.
module Hamsterdan.Host.V5.Timers
  ( TimerMaturity (..)
  , TimerFact (..)
  , V5TimerStore
  , storePath
  , storeSubject
  , storeConnection
  , openTimerStore
  , openTimerStoreWith
  , apply
  , pendingAck
  , ackIdentity
  , markAckDelivered
  , pendingMaturity
  , claimDue
  , claimDueAt
  , maturityIdentity
  , dueIdentity
  , markMaturityDelivered
  , nextDue
  , close
  , formatUs
  , parseUs
  , timerValue
  , timerHistory
  ) where

import Control.Exception (Exception (..), SomeException, catch, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Char (isDigit, ord)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorianValid, toGregorian)
import Data.Time.Calendar.OrdinalDate ()
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Calendar (Day (..))
import Hamsterdan.Contracts.Codec (Contract, dump, validate, validateJson)
import Petrus.Impetus.History.Records (ExternalEventDelivered (..), Record (..))
import Petrus.Impetus.Petrinet.Marking (Token (..))
import Petrus.Impetus.Petrinet.Schema (netPathText)
import Petrus.Json (Json)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Python (isAscii, isPrintable, utf8Length)
import Hamsterdan.Sqlite (Connection, SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.Host.Python
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as Posix

-- | @TimerMaturity@.
data TimerMaturity = TimerMaturity
  { value :: TimerDue
  , identity :: Text
  }
  deriving stock (Eq, Show)

-- | One accepted timer fact of History.
data TimerFact
  = FactApplied TimerCommandApplied
  | FactDue TimerDue
  deriving stock (Eq, Show)

data V5TimerStore = V5TimerStore
  { path :: FilePath
  , subject :: Text
  , db :: Connection
  , clockUs :: IO Integer
  , closed :: IORef Bool
  }

storePath :: V5TimerStore -> FilePath
storePath store = store.path

storeSubject :: V5TimerStore -> Text
storeSubject store = store.subject

-- | The store's own connection (the reference's @_db@, for tests).
storeConnection :: V5TimerStore -> Connection
storeConnection store = store.db

maxI64, minI64 :: Integer
maxI64 = 2 ^ (63 :: Int) - 1
minI64 = -(2 ^ (63 :: Int))

maxDelay :: Integer
maxDelay = 2147483647

-- ---------------------------------------------------------------------------
-- Instants

-- | @_format_us(value)@.
formatUs :: Integer -> Either ValueError Text
formatUs value
  | value < minI64 || value > maxI64 = Left (ValueError "V5 timer instant is outside signed 64-bit microseconds")
  | otherwise =
      let (days, rest) = value `divMod` 86400000000
          (secondsOfDay, micros) = rest `divMod` 1000000
          day = ModifiedJulianDay (40587 + days)
          (year, month, dom) = toGregorian day
          (hours, rest') = secondsOfDay `divMod` 3600
          (minutes, seconds) = rest' `divMod` 60
       in if year < 1 || year > 9999
            then Left (ValueError "V5 timer instant is outside datetime range")
            else
              Right $
                T.pack $
                  pad 4 year <> "-" <> pad 2 (toInteger month) <> "-" <> pad 2 (toInteger dom) <> "T"
                    <> pad 2 hours <> ":" <> pad 2 minutes <> ":" <> pad 2 seconds <> "." <> pad 6 micros <> "Z"
  where
    pad n x = let s = show x in replicate (n - length s) '0' <> s

-- | @_parse_us(value)@.
parseUs :: Text -> Either ValueError Integer
parseUs value = do
  let s = T.unpack value
      bad = Left (ValueError "V5 timer instant must be canonical UTC")
  case s of
    [y1, y2, y3, y4, '-', mo1, mo2, '-', d1, d2, 'T', h1, h2, ':', mi1, mi2, ':', s1, s2, '.', f1, f2, f3, f4, f5, f6, 'Z']
      | all isDigit [y1, y2, y3, y4, mo1, mo2, d1, d2, h1, h2, mi1, mi2, s1, s2, f1, f2, f3, f4, f5, f6] -> do
          let num :: String -> Integer
              num = foldl' (\acc c -> acc * 10 + toInteger (ord c - ord '0')) 0
              year = num [y1, y2, y3, y4]
              hours = num [h1, h2]
              minutes = num [mi1, mi2]
              seconds = num [s1, s2]
              micros = num [f1, f2, f3, f4, f5, f6]
          day <- maybe bad Right (fromGregorianValid year (fromInteger (num [mo1, mo2])) (fromInteger (num [d1, d2])))
          when (year < 1 || hours > 23 || minutes > 59 || seconds > 59) bad
          let result =
                (toModifiedJulianDay' day - 40587) * 86400000000
                  + hours * 3600000000
                  + minutes * 60000000
                  + seconds * 1000000
                  + micros
          when (result < minI64 || result > maxI64) $
            Left (ValueError "V5 timer instant is outside signed 64-bit microseconds")
          pure result
    _ -> bad
  where
    toModifiedJulianDay' (ModifiedJulianDay d) = d

formatUsIO :: Integer -> IO Text
formatUsIO = either throwIO pure . formatUs

parseUsIO :: Text -> IO Integer
parseUsIO = either throwIO pure . parseUs

-- ---------------------------------------------------------------------------
-- Canonical JSON

canonical :: (Contract a) => a -> Text
canonical = dumpsSortedText . dump

load :: forall a. (Contract a) => SQLData -> Text -> IO a
load raw label = case raw of
  SQLText text -> case validateJson @a (TE.encodeUtf8 text) of
    Left _ -> throwIO (RuntimeError ("stored V5 timer " <> label <> " is malformed"))
    Right value -> do
      when (canonical value /= text) $ throwIO (RuntimeError ("stored V5 timer " <> label <> " is not canonical"))
      pure value
  _ -> throwIO (TypeError ("stored V5 timer " <> label <> " is malformed"))

commandTimer :: TimerCommand -> ReminderTimer
commandTimer issued = case issued.command of
  CommandArm arm -> arm.timer
  CommandCancel cancel -> cancel.timer

resultTimer :: TimerCommandApplied -> ReminderTimer
resultTimer applied = case applied.result of
  ResultArmed armed -> armed.timer
  ResultCancelled cancelled -> cancelled.timer

-- | The result variant matches the command variant.
variantsAgree :: TimerCommand -> TimerCommandApplied -> Bool
variantsAgree issued applied = case (issued.command, applied.result) of
  (CommandArm _, ResultArmed _) -> True
  (CommandCancel _, ResultCancelled _) -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Opening

subjectValid :: Text -> Bool
subjectValid subject =
  not (T.null subject) && utf8Length subject <= 900 && isAscii subject && isPrintable subject

-- | Errors the reference's @open@ treats as a damaged ledger:
-- @sqlite3.DatabaseError@, @RuntimeError@, @TypeError@, @ValueError@.
data Recoverable = Recoverable SomeException

recoverable :: SomeException -> Maybe Recoverable
recoverable e
  | Sql.isDatabaseError e = Just (Recoverable e)
  | isJust (fromException @RuntimeError e) = Just (Recoverable e)
  | isTypeError e = Just (Recoverable e)
  | isJust (fromException @ValueError e) = Just (Recoverable e)
  | otherwise = Nothing

databaseOrRuntime :: SomeException -> Bool
databaseOrRuntime e = Sql.isDatabaseError e || isJust (fromException @RuntimeError e)

-- | @V5TimerStore.open(path, subject, history=..., outstanding=...)@ with
-- the wall clock.
openTimerStore :: FilePath -> Text -> [TimerFact] -> Maybe TimerCommand -> IO V5TimerStore
openTimerStore path subject facts outstanding =
  openTimerStoreWith path subject facts outstanding ((`div` 1000) . floor . (* 1000000000) <$> getPOSIXTime)

-- | @V5TimerStore.open@ with an injected microsecond clock.
openTimerStoreWith :: FilePath -> Text -> [TimerFact] -> Maybe TimerCommand -> IO Integer -> IO V5TimerStore
openTimerStoreWith path subject facts outstanding clockUs = do
  unless (subjectValid subject) $ throwIO (ValueError "V5 timer subject is malformed")
  makeParents (takeDirectory path)
  existed <- doesFileExist path
  let unrecoverableArm = case outstanding of
        Just issued
          | CommandArm arm <- issued.command ->
              not
                ( any
                    ( \case
                        FactApplied fact
                          | fact.operation == issued.operation
                          , ResultArmed armed <- fact.result ->
                              armed.timer == arm.timer
                        _ -> False
                    )
                    facts
                )
        _ -> False
      cannotRecover = RuntimeError "V5 timer store cannot recover an unacknowledged arm"
  when (not existed && unrecoverableArm) $ throwIO cannotRecover
  attempt <- try @SomeException $ do
    database <- Sql.open (T.pack path)
    ( do
        configure database
        if existed then validateSchema database subject else createSchema database subject
        pure database
      )
      `onException` Sql.close database
  (database, rebuilt) <- case attempt of
    Right database -> pure (database, not existed)
    Left e
      | databaseOrRuntime e -> do
          when unrecoverableArm $ throwIO cannotRecover
          quarantine path
          database <- fresh
          pure (database, True)
      | otherwise -> throwIO e
  store <- newStore database
  outcome <- try @SomeException $ do
    if rebuilt
      then rebuild store facts
      else do
        validateContents store facts outstanding True
        reconcileHistory store facts
    validateContents store facts outstanding False
  case outcome of
    Right () -> pure store
    Left e -> case recoverable e of
      Nothing -> close store >> throwIO e
      Just _ -> do
        close store
        if rebuilt
          then discard path >> throwIO e
          else do
            when unrecoverableArm $ throwIO cannotRecover
            quarantine path
            replacementDb <- fresh
            replacement <- newStore replacementDb
            ( do
                rebuild replacement facts
                validateContents replacement facts outstanding False
                pure replacement
              )
              `onException` (close replacement >> discard path)
  where
    fresh = do
      database <- Sql.open (T.pack path)
      configure database
      createSchema database subject
      pure database
    newStore database = do
      closed <- newIORef False
      pure V5TimerStore {path, subject, db = database, clockUs, closed}
    makeParents directory = do
      exists <- doesDirectory directory
      unless exists $ do
        createDirectoryIfMissing True (takeDirectory directory)
        PosixDir.createDirectory directory 0o700 `catch` \(e :: IOError) -> do
          again <- doesDirectory directory
          unless again (throwIO e)
    doesDirectory directory = either (const False) Posix.isDirectory <$> try @IOError (Posix.getFileStatus directory)

configure :: Connection -> IO ()
configure database = do
  journal <- Sql.query database "PRAGMA journal_mode=WAL" []
  Sql.script database "PRAGMA foreign_keys=ON"
  foreignKeys <- Sql.query database "PRAGMA foreign_keys" []
  unless (take 1 journal == [[SQLText "wal"]] && take 1 foreignKeys == [[SQLInteger 1]]) $
    throwIO (RuntimeError "V5 timer store could not enforce SQLite safety settings")

-- | @_create_schema@. The reference's @executescript@ (in autocommit mode)
-- commits each of the six DDL statements and then the meta row on its own,
-- seven WAL commits and their fsyncs. Here they share one transaction. The
-- closed file holds the same bytes either way (the schema cookie still counts
-- one change per statement), and a crash part-way leaves a store that the
-- next open quarantines either way: the reference's has a partial schema,
-- this one an empty one. See DIVERGENCES.md.
createSchema :: Connection -> Text -> IO ()
createSchema database subject = Sql.transaction database $ do
  Sql.script
    database
    "\n\
    \            CREATE TABLE v5_timer_meta (\n\
    \              singleton INTEGER PRIMARY KEY CHECK (singleton = 1),\n\
    \              schema_version INTEGER NOT NULL CHECK (schema_version = 1),\n\
    \              topology TEXT NOT NULL CHECK (topology = 'v5'),\n\
    \              subject TEXT NOT NULL UNIQUE,\n\
    \              last_generation INTEGER NOT NULL CHECK (last_generation >= 0)\n\
    \            );\n\
    \            CREATE TABLE v5_timer_operations (\n\
    \              operation TEXT PRIMARY KEY,\n\
    \              subject TEXT NOT NULL,\n\
    \              generation INTEGER NOT NULL CHECK (generation > 0),\n\
    \              command_json TEXT NOT NULL,\n\
    \              result_json TEXT NOT NULL,\n\
    \              ack_identity TEXT NOT NULL UNIQUE,\n\
    \              applied_at_us INTEGER NOT NULL,\n\
    \              ack_delivered INTEGER NOT NULL DEFAULT 0 CHECK (ack_delivered IN (0, 1)),\n\
    \              UNIQUE(subject, generation)\n\
    \            );\n\
    \            CREATE TABLE v5_timers (\n\
    \              timer_id TEXT PRIMARY KEY,\n\
    \              subject TEXT NOT NULL,\n\
    \              incarnation INTEGER NOT NULL CHECK (incarnation >= 0),\n\
    \              sequence INTEGER NOT NULL CHECK (sequence >= 0),\n\
    \              head TEXT NOT NULL,\n\
    \              due_at_us INTEGER NOT NULL,\n\
    \              arm_operation TEXT NOT NULL,\n\
    \              state TEXT NOT NULL CHECK (state IN ('armed','superseded','cancelled','matured','retired')),\n\
    \              terminal_operation TEXT,\n\
    \              matured_at_us INTEGER,\n\
    \              maturity_identity TEXT UNIQUE,\n\
    \              maturity_delivered INTEGER NOT NULL DEFAULT 0 CHECK (maturity_delivered IN (0, 1)),\n\
    \              CHECK (\n\
    \                (state = 'armed' AND terminal_operation IS NULL AND matured_at_us IS NULL\n\
    \                  AND maturity_identity IS NULL AND maturity_delivered = 0)\n\
    \                OR (state IN ('superseded','cancelled') AND terminal_operation IS NOT NULL\n\
    \                  AND matured_at_us IS NULL AND maturity_identity IS NULL AND maturity_delivered = 0)\n\
    \                OR (state = 'retired' AND terminal_operation IS NULL AND matured_at_us IS NULL\n\
    \                  AND maturity_identity IS NULL AND maturity_delivered = 0)\n\
    \                OR (state = 'matured' AND terminal_operation IS NULL AND matured_at_us IS NOT NULL\n\
    \                  AND maturity_identity IS NOT NULL)\n\
    \              )\n\
    \            );\n\
    \            CREATE UNIQUE INDEX v5_timers_one_armed ON v5_timers(subject) WHERE state='armed';\n\
    \            CREATE INDEX v5_timers_due ON v5_timers(subject,due_at_us,timer_id) WHERE state='armed';\n\
    \            CREATE INDEX v5_timer_pending_acks\n\
    \              ON v5_timer_operations(subject,ack_delivered,generation);\n\
    \            "
  void $
    Sql.execute
      database
      "INSERT INTO v5_timer_meta(singleton,schema_version,topology,subject,last_generation) VALUES(1,1,'v5',?,0)"
      [SQLText subject]

column :: Integer -> Text -> Text -> Integer -> Maybe Text -> Integer -> [SQLData]
column cid name kind notNull dflt pk =
  [SQLInteger (fromInteger cid), SQLText name, SQLText kind, SQLInteger (fromInteger notNull), maybe SQLNull SQLText dflt, SQLInteger (fromInteger pk)]

schemaColumns :: [(Text, [[SQLData]])]
schemaColumns =
  [ ( "v5_timer_meta"
    , [ column 0 "singleton" "INTEGER" 0 Nothing 1
      , column 1 "schema_version" "INTEGER" 1 Nothing 0
      , column 2 "topology" "TEXT" 1 Nothing 0
      , column 3 "subject" "TEXT" 1 Nothing 0
      , column 4 "last_generation" "INTEGER" 1 Nothing 0
      ]
    )
  , ( "v5_timer_operations"
    , [ column 0 "operation" "TEXT" 0 Nothing 1
      , column 1 "subject" "TEXT" 1 Nothing 0
      , column 2 "generation" "INTEGER" 1 Nothing 0
      , column 3 "command_json" "TEXT" 1 Nothing 0
      , column 4 "result_json" "TEXT" 1 Nothing 0
      , column 5 "ack_identity" "TEXT" 1 Nothing 0
      , column 6 "applied_at_us" "INTEGER" 1 Nothing 0
      , column 7 "ack_delivered" "INTEGER" 1 (Just "0") 0
      ]
    )
  , ( "v5_timers"
    , [ column 0 "timer_id" "TEXT" 0 Nothing 1
      , column 1 "subject" "TEXT" 1 Nothing 0
      , column 2 "incarnation" "INTEGER" 1 Nothing 0
      , column 3 "sequence" "INTEGER" 1 Nothing 0
      , column 4 "head" "TEXT" 1 Nothing 0
      , column 5 "due_at_us" "INTEGER" 1 Nothing 0
      , column 6 "arm_operation" "TEXT" 1 Nothing 0
      , column 7 "state" "TEXT" 1 Nothing 0
      , column 8 "terminal_operation" "TEXT" 0 Nothing 0
      , column 9 "matured_at_us" "INTEGER" 0 Nothing 0
      , column 10 "maturity_identity" "TEXT" 0 Nothing 0
      , column 11 "maturity_delivered" "INTEGER" 1 (Just "0") 0
      ]
    )
  ]

schemaIndexes :: [(Text, [[SQLData]])]
schemaIndexes =
  [ ("v5_timers_one_armed", [idx 0 1 "subject"])
  , ("v5_timers_due", [idx 0 1 "subject", idx 1 5 "due_at_us", idx 2 0 "timer_id"])
  , ("v5_timer_pending_acks", [idx 0 1 "subject", idx 1 7 "ack_delivered", idx 2 2 "generation"])
  ]
  where
    idx :: Integer -> Integer -> Text -> [SQLData]
    idx a b name = [SQLInteger (fromInteger a), SQLInteger (fromInteger b), SQLText name]

validateSchema :: Connection -> Text -> IO ()
validateSchema database subject = do
  check <- Sql.query database "PRAGMA quick_check" []
  unless (take 1 check == [[SQLText "ok"]]) $ throwIO (RuntimeError "V5 timer store is corrupt")
  names <- Sql.query database "SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'" []
  let observed = Set.fromList [(k, n) | [SQLText k, SQLText n] <- names]
      malformedName = any (\case [SQLText _, SQLText _] -> False; _ -> True) names
      expected =
        Set.fromList
          [ ("table", "v5_timer_meta")
          , ("table", "v5_timer_operations")
          , ("table", "v5_timers")
          , ("index", "v5_timers_one_armed")
          , ("index", "v5_timers_due")
          , ("index", "v5_timer_pending_acks")
          ]
      incompatible = throwIO (RuntimeError "V5 timer store schema is incompatible")
  when (malformedName || observed /= expected) incompatible
  forM_ schemaColumns $ \(table, columns) -> do
    rows <- Sql.query database ("PRAGMA table_info(" <> table <> ")") []
    when (rows /= columns) incompatible
  forM_ schemaIndexes $ \(index, columns) -> do
    rows <- Sql.query database ("PRAGMA index_info(" <> index <> ")") []
    when (rows /= columns) incompatible
  meta <- Sql.query database "SELECT schema_version,topology,subject,last_generation FROM v5_timer_meta WHERE singleton=1" []
  case meta of
    [SQLInteger 1, SQLText "v5", SQLText s, SQLInteger g] : _ | s == subject, g >= 0 -> pure ()
    _ -> throwIO (RuntimeError "V5 timer store metadata is incompatible")

quarantine :: FilePath -> IO ()
quarantine path = do
  target <- pick (path <> ".corrupt") (0 :: Int)
  forM_ suffixes $ \suffix -> do
    let source = path <> suffix
    exists <- doesFileExist source
    when exists $ renameFile source (target <> suffix)
  where
    suffixes = ["", "-wal", "-shm"]
    pick candidate sequence' = do
      taken <- or <$> mapM (\suffix -> doesFileExist (candidate <> suffix)) suffixes
      if taken
        then pick (path <> ".corrupt." <> show (sequence' + 1)) (sequence' + 1)
        else pure candidate

discard :: FilePath -> IO ()
discard path = forM_ [path, path <> "-wal", path <> "-shm"] $ \candidate ->
  removeFile candidate `catch` \(e :: IOError) -> unless (isDoesNotExistError e) (throwIO e)

-- ---------------------------------------------------------------------------
-- Identity

operationGeneration :: V5TimerStore -> Text -> IO Integer
operationGeneration store operation = do
  let prefix = "timer-command:" <> store.subject <> ":g"
  case T.stripPrefix prefix operation of
    Just digits
      | Just (first, _) <- T.uncons digits
      , first >= '1' && first <= '9'
      , T.all (\c -> c >= '0' && c <= '9') digits -> do
          let result = T.foldl' (\acc c -> acc * 10 + toInteger (ord c - ord '0')) 0 digits :: Integer
          when (result > maxI64) $ throwIO (ValueError "V5 timer operation generation is out of range")
          pure result
    _ -> throwIO (ValueError "V5 timer operation identity is malformed")

validateTimer :: V5TimerStore -> ReminderTimer -> IO ()
validateTimer store timer =
  when
    ( timer.incarnation < 0
        || timer.sequence < 0
        || T.null timer.head
        || timer.id /= "timer:" <> store.subject <> ":i" <> tshow timer.incarnation <> ":s" <> tshow timer.sequence
    )
    $ throwIO (ValueError "V5 timer identity is malformed")

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | @V5TimerStore.ack_identity(operation)@.
ackIdentity :: Text -> Text
ackIdentity operation = "v5-timer-command-applied:" <> operation

-- | @V5TimerStore.maturity_identity(timer_id, due_at_us)@.
maturityIdentity :: Text -> Integer -> Text
maturityIdentity timerId due = "v5-timer-due:" <> timerId <> ":" <> tshow due

-- | @V5TimerStore.due_identity(value)@.
dueIdentity :: TimerDue -> Either ValueError Text
dueIdentity due = maturityIdentity due.timer.id <$> parseUs due.dueAt

nowUs :: V5TimerStore -> IO Integer
nowUs store = do
  value <- store.clockUs
  when (value < minI64 || value > maxI64) $ throwIO (ValueError "V5 timer clock returned an invalid instant")
  pure value

-- ---------------------------------------------------------------------------
-- Commands

-- | @apply(issued)@.
apply :: V5TimerStore -> TimerCommand -> IO TimerCommandApplied
apply store issued = do
  generation <- operationGeneration store issued.operation
  validateTimer store (commandTimer issued)
  let encoded = canonical issued
      db = store.db
  immediate db $ do
    existing <- Sql.query db "SELECT command_json,result_json FROM v5_timer_operations WHERE operation=?" [SQLText issued.operation]
    case existing of
      [stored, resultJson] : _ -> do
        when (stored /= SQLText encoded) $ throwIO (RuntimeError "timer operation has a different timer command")
        result <- load @TimerCommandApplied resultJson "operation result"
        when
          ( result.operation /= issued.operation
              || resultTimer result /= commandTimer issued
              || not (variantsAgree issued result)
          )
          $ throwIO (RuntimeError "stored V5 timer operation result contradicts its command")
        pure result
      _ -> do
        meta <- Sql.query db "SELECT last_generation FROM v5_timer_meta WHERE singleton=1" []
        lastGeneration <- case meta of
          [SQLInteger g] : _ -> pure (toInteger g)
          _ -> throwIO (TypeError "unsupported operand type(s) for +")
        when (generation /= lastGeneration + 1) $ throwIO (RuntimeError "V5 timer operation generation is not contiguous")
        now <- nowUs store
        result <- case issued.command of
          CommandArm arm -> do
            let delay = arm.delayS
            when (delay < 1 || delay > maxDelay) $
              throwIO (ValueError "V5 timer arm delay must be a positive bounded integer")
            let due = now + delay * 1000000
            dueText <- formatUsIO due
            void $
              Sql.execute
                db
                "UPDATE v5_timers SET state='superseded',terminal_operation=? WHERE subject=? AND state='armed'"
                [SQLText issued.operation, SQLText store.subject]
            let timer = arm.timer
            void $
              Sql.execute
                db
                "INSERT INTO v5_timers(timer_id,subject,incarnation,sequence,head,due_at_us,arm_operation,state) VALUES(?,?,?,?,?,?,?,'armed')"
                [SQLText timer.id, SQLText store.subject, int timer.incarnation, int timer.sequence, SQLText timer.head, int due, SQLText issued.operation]
            pure TimerCommandApplied {operation = issued.operation, result = ResultArmed TimerArmed {timer = arm.timer, dueAt = dueText}}
          CommandCancel cancel -> do
            let timer = cancel.timer
            void $
              Sql.execute
                db
                "UPDATE v5_timers SET state='cancelled',terminal_operation=? WHERE timer_id=? AND subject=? AND incarnation=? AND sequence=? AND head=? AND state='armed'"
                [SQLText issued.operation, SQLText timer.id, SQLText store.subject, int timer.incarnation, int timer.sequence, SQLText timer.head]
            pure TimerCommandApplied {operation = issued.operation, result = ResultCancelled TimerCancelled {timer = cancel.timer}}
        void $
          Sql.execute
            db
            "INSERT INTO v5_timer_operations(operation,subject,generation,command_json,result_json,ack_identity,applied_at_us,ack_delivered) VALUES(?,?,?,?,?,?,?,0)"
            [SQLText issued.operation, SQLText store.subject, int generation, SQLText encoded, SQLText (canonical result), SQLText (ackIdentity issued.operation), int now]
        void $ Sql.execute db "UPDATE v5_timer_meta SET last_generation=? WHERE singleton=1" [int generation]
        pure result

int :: Integer -> SQLData
int = SQLInteger . fromInteger

-- | @pending_ack()@.
pendingAck :: V5TimerStore -> IO (Maybe TimerCommandApplied)
pendingAck store = do
  rows <-
    Sql.withLock store.db $
      Sql.query
        store.db
        "SELECT operation,command_json,result_json,ack_identity FROM v5_timer_operations WHERE subject=? AND ack_delivered=0 ORDER BY generation LIMIT 1"
        [SQLText store.subject]
  case rows of
    [operation, commandJson, resultJson, identity] : _ -> do
      command <- load @TimerCommand commandJson "operation command"
      result <- load @TimerCommandApplied resultJson "operation result"
      unless
        ( operation == SQLText command.operation
            && operation == SQLText result.operation
            && commandTimer command == resultTimer result
            && variantsAgree command result
            && identity == SQLText (ackIdentity result.operation)
        )
        $ throwIO (RuntimeError "stored V5 timer acknowledgement is malformed")
      pure (Just result)
    _ -> pure Nothing

-- | @mark_ack_delivered(operation)@.
markAckDelivered :: V5TimerStore -> Text -> IO ()
markAckDelivered store operation = immediate store.db $ do
  changed <- Sql.execute store.db "UPDATE v5_timer_operations SET ack_delivered=1 WHERE operation=? AND subject=?" [SQLText operation, SQLText store.subject]
  when (changed /= 1) $ throwIO (RuntimeError "V5 timer acknowledgement has no operation")

-- | @pending_maturity()@.
pendingMaturity :: V5TimerStore -> IO (Maybe TimerMaturity)
pendingMaturity store = do
  rows <-
    Sql.withLock store.db $
      Sql.query
        store.db
        "SELECT timer_id,incarnation,sequence,head,due_at_us,matured_at_us,maturity_identity FROM v5_timers WHERE subject=? AND state='matured' AND maturity_delivered=0 ORDER BY matured_at_us,timer_id LIMIT 1"
        [SQLText store.subject]
  case rows of
    row : _ -> Just <$> maturity store row
    [] -> pure Nothing

-- | @claim_due()@ at the store clock.
claimDue :: V5TimerStore -> IO (Maybe TimerMaturity)
claimDue store = nowUs store >>= claimDueAt store

-- | @claim_due(now_us)@.
claimDueAt :: V5TimerStore -> Integer -> IO (Maybe TimerMaturity)
claimDueAt store now = do
  when (now < minI64 || now > maxI64) $ throwIO (ValueError "V5 timer claim instant is invalid")
  let db = store.db
  claimed <- immediate db $ do
    rows <-
      Sql.query
        db
        "SELECT timer_id,incarnation,sequence,head,due_at_us FROM v5_timers WHERE subject=? AND state='armed' AND due_at_us<=? ORDER BY due_at_us,timer_id LIMIT 1"
        [SQLText store.subject, int now]
    case rows of
      row@[timerId, _, _, _, SQLInteger due] : _ -> do
        let identity = case timerId of
              SQLText t -> maturityIdentity t (toInteger due)
              _ -> ""
        void $
          Sql.execute
            db
            "UPDATE v5_timers SET state='matured',matured_at_us=?,maturity_identity=? WHERE timer_id=? AND subject=? AND state='armed'"
            [int now, SQLText identity, timerId, SQLText store.subject]
        pure (Just (row <> [int now, SQLText identity]))
      _ : _ -> throwIO (RuntimeError "stored V5 timer maturity is malformed")
      [] -> pure Nothing
  traverse (maturity store) claimed

maturity :: V5TimerStore -> [SQLData] -> IO TimerMaturity
maturity store = \case
  [SQLText timerId, SQLInteger incarnation, SQLInteger sequence', SQLText head', SQLInteger due, SQLInteger matured, SQLText identity]
    | identity == maturityIdentity timerId (toInteger due)
    , matured >= due -> do
        let timer = ReminderTimer {id = timerId, incarnation = toInteger incarnation, sequence = toInteger sequence', head = head'}
        validateTimer store timer
        dueText <- formatUsIO (toInteger due)
        maturedText <- formatUsIO (toInteger matured)
        pure TimerMaturity {value = TimerDue {timer, dueAt = dueText, maturedAt = maturedText}, identity}
  _ -> throwIO (RuntimeError "stored V5 timer maturity is malformed")

-- | @mark_maturity_delivered(timer_id)@.
markMaturityDelivered :: V5TimerStore -> Text -> IO ()
markMaturityDelivered store timerId = immediate store.db $ do
  changed <- Sql.execute store.db "UPDATE v5_timers SET maturity_delivered=1 WHERE timer_id=? AND subject=? AND state='matured'" [SQLText timerId, SQLText store.subject]
  when (changed /= 1) $ throwIO (RuntimeError "V5 timer maturity has no claimed timer")

-- | @next_due()@ in POSIX seconds.
nextDue :: V5TimerStore -> IO (Maybe Double)
nextDue store = do
  rows <- Sql.withLock store.db $ Sql.query store.db "SELECT MIN(due_at_us) FROM v5_timers WHERE subject=? AND state='armed'" [SQLText store.subject]
  case rows of
    [SQLNull] : _ -> pure Nothing
    [] -> pure Nothing
    [SQLInteger us] : _ -> pure (Just (fromIntegral us / 1000000))
    _ -> throwIO (RuntimeError "stored V5 timer deadline is malformed")

-- ---------------------------------------------------------------------------
-- Projection

data Projected = Projected
  { timer :: ReminderTimer
  , dueAtUs :: Integer
  , armOperation :: Text
  , state :: Text
  , terminalOperation :: Maybe Text
  , maturedAtUs :: Maybe Integer
  , maturityIdentity' :: Maybe Text
  , maturityDelivered :: Integer
  }

projectedRow :: Text -> Projected -> [SQLData]
projectedRow subject p =
  [ SQLText p.timer.id
  , SQLText subject
  , int p.timer.incarnation
  , int p.timer.sequence
  , SQLText p.timer.head
  , int p.dueAtUs
  , SQLText p.armOperation
  , SQLText p.state
  , maybe SQLNull SQLText p.terminalOperation
  , maybe SQLNull int p.maturedAtUs
  , maybe SQLNull SQLText p.maturityIdentity'
  , int p.maturityDelivered
  ]

projectApplied :: V5TimerStore -> Map Text Projected -> TimerCommandApplied -> IO (Map Text Projected)
projectApplied store timers fact = do
  validateTimer store (resultTimer fact)
  case fact.result of
    ResultArmed armed -> do
      due <- parseUsIO armed.dueAt
      let superseded = Map.map (\p -> if p.state == "armed" then p {state = "superseded", terminalOperation = Just fact.operation} else p) timers
      when (Map.member armed.timer.id superseded) $ throwIO (RuntimeError "accepted V5 timer arm reuses a timer identity")
      pure $
        Map.insert
          armed.timer.id
          Projected
            { timer = armed.timer
            , dueAtUs = due
            , armOperation = fact.operation
            , state = "armed"
            , terminalOperation = Nothing
            , maturedAtUs = Nothing
            , maturityIdentity' = Nothing
            , maturityDelivered = 0
            }
          superseded
    ResultCancelled cancelled ->
      pure $
        Map.adjust
          (\p -> if p.state == "armed" && p.timer == cancelled.timer then p {state = "cancelled", terminalOperation = Just fact.operation} else p)
          cancelled.timer.id
          timers

projectDue :: V5TimerStore -> Map Text Projected -> TimerDue -> Integer -> IO (Map Text Projected)
projectDue store timers fact delivered = do
  validateTimer store fact.timer
  due <- parseUsIO fact.dueAt
  matured <- parseUsIO fact.maturedAt
  when (matured < due) $ throwIO (RuntimeError "accepted V5 timer maturity predates its deadline")
  pure $
    Map.adjust
      ( \p ->
          if p.state == "armed" && p.timer == fact.timer && p.dueAtUs == due
            then p {state = "matured", maturedAtUs = Just matured, maturityIdentity' = Just (maturityIdentity fact.timer.id due), maturityDelivered = delivered}
            else p
      )
      fact.timer.id
      timers

validateContents :: V5TimerStore -> [TimerFact] -> Maybe TimerCommand -> Bool -> IO ()
validateContents store facts outstanding tolerate = do
  let db = store.db
  (timers0, accepted, historyGeneration) <- foldlM' step (Map.empty, Map.empty, 0) facts
  meta <- Sql.query db "SELECT last_generation FROM v5_timer_meta WHERE singleton=1" []
  rows <- Sql.query db "SELECT operation,subject,generation,command_json,result_json,ack_identity,applied_at_us,ack_delivered FROM v5_timer_operations ORDER BY generation" []
  (pending, observed) <- foldlM' (operationRow accepted historyGeneration) ([], Set.empty) rows
  lastGeneration <- case meta of
    [SQLInteger g] : _ -> pure (toInteger g)
    _ -> throwIO (RuntimeError "stored V5 timer generation is malformed")
  let pendingInOrder = reverse pending
      expectedLast = maximum (historyGeneration : Set.toList observed)
      pendingGenerations = [g | (g, _, _) <- pendingInOrder]
  when
    ( lastGeneration /= expectedLast
        || pendingGenerations /= [historyGeneration + 1 .. lastGeneration]
        || length pendingInOrder > 1
        || (case pendingInOrder of (_, command, _) : _ -> Just command /= outstanding; [] -> False)
    )
    $ throwIO (RuntimeError "stored V5 timer generations contradict canonical History")
  timers1 <- foldlM' (\acc (_, _, result) -> projectApplied store acc result) timers0 pendingInOrder
  timerRows <- Sql.query db "SELECT timer_id,subject,incarnation,sequence,head,due_at_us,arm_operation,state,terminal_operation,matured_at_us,maturity_identity,maturity_delivered FROM v5_timers ORDER BY timer_id" []
  timers2 <-
    foldlM'
      ( \acc row -> case row of
          [r0, _, r2, r3, r4, r5, _, SQLText "matured", _, r9, r10, SQLInteger 0] -> do
            m <- maturity store [r0, r2, r3, r4, r5, r9, r10]
            due <- parseUsIO m.value.dueAt
            case Map.lookup m.value.timer.id acc of
              Just p
                | p.state == "armed"
                , p.timer == m.value.timer
                , p.dueAtUs == due ->
                    projectDue store acc m.value 0
              _ -> pure acc
          _ -> pure acc
      )
      timers1
      timerRows
  let expectedRows = map (projectedRow store.subject . snd) (sortOn fst (Map.toList timers2))
      expectedById = Map.fromList [(r0, r) | r@(SQLText r0 : _) <- expectedRows]
      compared
        | tolerate =
            [ case (last row, row) of
                (SQLInteger 0, SQLText rid : _)
                  | Just expected <- Map.lookup rid expectedById
                  , last expected == SQLInteger 1
                  , init row == init expected ->
                      init row <> [SQLInteger 1]
                _ -> row
            | row <- timerRows
            , not (null row)
            ]
        | otherwise = timerRows
  when (compared /= expectedRows) $
    throwIO (RuntimeError "stored V5 timers contradict canonical History and pending operations")
  where
    step (timers, accepted, generationSoFar) = \case
      FactApplied fact -> do
        generation <- operationGeneration store fact.operation
        when (generation /= generationSoFar + 1) $ throwIO (RuntimeError "accepted V5 timer operations are not contiguous")
        timers' <- projectApplied store timers fact
        pure (timers', Map.insert fact.operation fact accepted, generation)
      FactDue fact -> do
        timers' <- projectDue store timers fact 1
        pure (timers', accepted, generationSoFar)
    operationRow accepted historyGeneration (pending, observed) row = do
      let malformed = throwIO (RuntimeError "stored V5 timer operation is malformed")
      case row of
        [SQLText operation, subject, SQLInteger generation', commandJson, resultJson, ackIdentity', SQLInteger appliedAt, SQLInteger delivered] -> do
          let generation = toInteger generation'
          when
            ( subject /= SQLText store.subject
                || Set.member generation observed
                || delivered `notElem` [0, 1]
                || ackIdentity' /= SQLText (ackIdentity operation)
            )
            malformed
          expectedGeneration <- operationGeneration store operation
          when (generation /= expectedGeneration) malformed
          command <- load @TimerCommand commandJson "operation command"
          result <- load @TimerCommandApplied resultJson "operation result"
          validateTimer store (commandTimer command)
          when
            ( command.operation /= operation
                || result.operation /= operation
                || commandTimer command /= resultTimer result
                || not (variantsAgree command result)
            )
            $ throwIO (RuntimeError "stored V5 timer operation contradicts its command")
          case (command.command, result.result) of
            (CommandArm arm, ResultArmed armed) -> do
              let due = toInteger appliedAt + arm.delayS * 1000000
              parsed <- parseUsIO armed.dueAt
              formatted <- formatUsIO due
              when (parsed /= due || formatted /= armed.dueAt) $
                throwIO (RuntimeError "stored V5 timer arm deadline contradicts its command")
            _ -> pure ()
          let observed' = Set.insert generation observed
          case Map.lookup operation accepted of
            Just acceptedResult -> do
              when (result /= acceptedResult || (delivered /= 1 && not tolerate)) $
                throwIO (RuntimeError "stored V5 timer operation contradicts canonical History")
              pure (pending, observed')
            Nothing -> do
              when (delivered /= 0 || generation <= historyGeneration) $
                throwIO (RuntimeError "stored V5 timer operation has no canonical acknowledgement")
              pure ((generation, command, result) : pending, observed')
        _ -> malformed

foldlM' :: (b -> a -> IO b) -> b -> [a] -> IO b
foldlM' f = go
  where
    go acc = \case
      [] -> pure acc
      x : xs -> f acc x >>= \acc' -> acc' `seq` go acc' xs

rebuild :: V5TimerStore -> [TimerFact] -> IO ()
rebuild store facts = do
  let db = store.db
  immediate db $ do
    lastGeneration <-
      foldlM'
        ( \lastGeneration -> \case
            FactApplied fact -> do
              generation <- operationGeneration store fact.operation
              when (generation /= lastGeneration + 1) $ throwIO (RuntimeError "accepted V5 timer operations are not contiguous")
              validateTimer store (resultTimer fact)
              case fact.result of
                ResultArmed armed -> do
                  due <- parseUsIO armed.dueAt
                  void $
                    Sql.execute
                      db
                      "UPDATE v5_timers SET state='superseded',terminal_operation=? WHERE subject=? AND state='armed'"
                      [SQLText fact.operation, SQLText store.subject]
                  let timer = armed.timer
                  void $
                    Sql.execute
                      db
                      "INSERT INTO v5_timers(timer_id,subject,incarnation,sequence,head,due_at_us,arm_operation,state) VALUES(?,?,?,?,?,?,?,'armed')"
                      [SQLText timer.id, SQLText store.subject, int timer.incarnation, int timer.sequence, SQLText timer.head, int due, SQLText fact.operation]
                ResultCancelled cancelled -> do
                  let timer = cancelled.timer
                  void $
                    Sql.execute
                      db
                      "UPDATE v5_timers SET state='cancelled',terminal_operation=? WHERE timer_id=? AND subject=? AND incarnation=? AND sequence=? AND head=? AND state='armed'"
                      [SQLText fact.operation, SQLText timer.id, SQLText store.subject, int timer.incarnation, int timer.sequence, SQLText timer.head]
              pure generation
            FactDue fact -> do
              validateTimer store fact.timer
              due <- parseUsIO fact.dueAt
              matured <- parseUsIO fact.maturedAt
              when (matured < due) $ throwIO (RuntimeError "accepted V5 timer maturity predates its deadline")
              void $
                Sql.execute
                  db
                  "UPDATE v5_timers SET state='matured',matured_at_us=?,maturity_identity=?,maturity_delivered=1 WHERE timer_id=? AND subject=? AND incarnation=? AND sequence=? AND head=? AND state='armed' AND due_at_us=?"
                  [int matured, SQLText (maturityIdentity fact.timer.id due), SQLText fact.timer.id, SQLText store.subject, int fact.timer.incarnation, int fact.timer.sequence, SQLText fact.timer.head, int due]
              pure lastGeneration
        )
        0
        facts
    void $ Sql.execute db "UPDATE v5_timer_meta SET last_generation=? WHERE singleton=1" [int lastGeneration]

reconcileHistory :: V5TimerStore -> [TimerFact] -> IO ()
reconcileHistory store facts = do
  let db = store.db
      acknowledged = Set.toList (Set.fromList [fact.operation | FactApplied fact <- facts])
      maturities = [fact | FactDue fact <- facts]
  dues <- forM maturities $ \fact -> (fact,) <$> parseUsIO fact.dueAt
  immediate db $ do
    forM_ acknowledged $ \operation ->
      Sql.execute db "UPDATE v5_timer_operations SET ack_delivered=1 WHERE operation=? AND subject=?" [SQLText operation, SQLText store.subject]
    forM_ dues $ \(fact, due) ->
      Sql.execute
        db
        "UPDATE v5_timers SET maturity_delivered=1 WHERE timer_id=? AND subject=? AND incarnation=? AND sequence=? AND head=? AND state='matured' AND due_at_us=?"
        [SQLText fact.timer.id, SQLText store.subject, int fact.timer.incarnation, int fact.timer.sequence, SQLText fact.timer.head, int due]

close :: V5TimerStore -> IO ()
close store = do
  done <- readIORef store.closed
  unless done $ do
    writeIORef store.closed True
    Sql.close store.db

-- ---------------------------------------------------------------------------
-- History projection (@V5Runtime.timer_history@ and @_timer_value@)

-- | @V5Runtime._timer_value(model, data, label)@.
timerValue :: forall a. (Contract a) => Json -> Text -> Either RuntimeError a
timerValue value label = case validate @a value of
  Left _ -> Left (RuntimeError ("V5 timer " <> label <> " is malformed"))
  Right decoded -> Right decoded

-- | @V5Runtime.timer_history()@: the accepted typed timer boundary facts in
-- canonical History order.
timerHistory :: [Record] -> IO [TimerFact]
timerHistory records = fmap concat . forM records $ \case
  RExternalEventDelivered record
    | netPathText record.source == "on_timer_command_applied" -> do
        fact <- single record "TimerCommandApplied" >>= \v -> either throwIO pure (timerValue @TimerCommandApplied v "History delivery")
        expect record (ackIdentity fact.operation)
        pure [FactApplied fact]
    | netPathText record.source == "on_timer" -> do
        fact <- single record "TimerDue" >>= \v -> either throwIO pure (timerValue @TimerDue v "History delivery")
        identity <- either throwIO pure (dueIdentity fact)
        expect record identity
        pure [FactDue fact]
  _ -> pure []
  where
    single record color = case record.tokens of
      [token] | token.color == Just color -> pure token.payload
      _ -> throwIO (RuntimeError "V5 timer History delivery is malformed")
    expect record identity =
      when (record.identity /= identity) $ throwIO (RuntimeError "V5 timer History delivery identity is malformed")
