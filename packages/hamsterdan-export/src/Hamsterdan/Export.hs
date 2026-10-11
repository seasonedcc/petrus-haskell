-- | Export one PR's durable state as a self-contained offline evidence
-- package (@host/export.py@).
--
-- Reconstructing a hero journey without the production VM needs the
-- workflow authority (canonical History), the agent bodies and full
-- session transcripts that produced its effects, the webhook rows that
-- drove it together with the raw GitHub delivery records behind them, and
-- every board the PR page ever showed. This module copies exactly those
-- out of a local state-directory copy, joins the agent bodies on the
-- @pi:@ operation id, and NAMES every piece the state directory does not
-- hold instead of dropping it.
--
-- The package is the reference's, byte for byte: the same files with the
-- same contents, written in the same order (so a refusal or a failure
-- part-way leaves the same partial package), the same report, and the
-- same exception where the reference raises one. Only the named durable
-- stores are opened, and each is copied to a scratch directory before it
-- is queried, so the source copy is never written to.
module Hamsterdan.Export
  ( -- * Exporting
    ExportRequest (..)
  , Report (..)
  , EvidenceExportError (..)
  , exportPackage
  , agentOperationId

    -- * The command line
  , ExportEnvironment (..)
  , productionEnvironment
  , runExport
  , exportParser
  ) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteString qualified as BS
import Data.ByteArray qualified as BA
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Unsafe qualified as BU
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Containers.ListUtils (nubOrd)
import Data.List (nub, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Cli.Argparse
  ( Action (..)
  , Behavior (..)
  , Outcome (..)
  , Parser
  , Value (..)
  , ValueType (..)
  , lookupInteger
  , lookupList
  , lookupText
  , newParser
  , option
  , parseArgs
  , terminalColumns
  )
import Hamsterdan.Export.Files
import Hamsterdan.Export.Parallel (parallelMap, writeFiles)
import Hamsterdan.Export.Python
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.PyLiteral (PyValue (..), literalEval, strRepr)
import Hamsterdan.PyLiteral qualified as Lit
import Hamsterdan.Readiness.NetV5.Board (renderBoard)
import Petrus.Json (Json (..))
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (Handle, hFlush, stderr, stdout)

-- ---------------------------------------------------------------------------
-- Constants

historySchema :: Integer
historySchema = 5

packageSchema :: Integer
packageSchema = 1

credentialNames :: [Text]
credentialNames = [".env", "env", "hamsterdan.env", "installations.json"]

credentialSuffixes :: [Text]
credentialSuffixes = [".pem", ".key", ".crt", ".p12"]

credentialMarkers :: [Text]
credentialMarkers = ["secret", "token", "credential", "private-key", "privatekey", "apikey", "api-key"]

identityStateFiles :: [Text]
identityStateFiles = ["image.txt", "image-identity.txt", "runtime-identity.txt", "pins.md", "petrus-pin.txt"]

terminalRecords :: [Text]
terminalRecords = ["ActivityCompleted", "ActivityFailed", "ActivityTerminalQuarantined"]

agentDeferralVariants :: [Text]
agentDeferralVariants = ["RoundDeferred"]

indexFields :: [(Text, [Text])]
indexFields =
  [ ("InstanceCreated", ["instance", "name"])
  , ("TokensInitialized", ["place"])
  , ("DeliveryRegistrationOpened", ["source", "key"])
  , ("ExternalEventDelivered", ["source", "identity"])
  , ("CandidateSelected", ["transition"])
  , ("FiringBegun", ["transition"])
  , ("FiringCompleted", ["transition"])
  , ("TokensConsumed", ["place"])
  , ("TokensProduced", ["place"])
  , ("ActivityRequested", ["transition", "activity", "correlation"])
  , ("ActivityCompleted", ["transition"])
  , ("ActivityFailed", ["transition", "reason"])
  , ("ActivityTerminalQuarantined", ["transition", "reason"])
  ]

inboxColumns :: [Text]
inboxColumns = ["delivery_id", "event", "observation", "status", "attempts", "reason", "error_class"]

bodyColumns :: [Text]
bodyColumns =
  [ "operation_id"
  , "output_reference"
  , "output_text"
  , "continuation_reference"
  , "session_id"
  , "working_binding"
  , "workspace_digest"
  , "aggregate_verified"
  ]

piOperationColumns :: [Text]
piOperationColumns =
  [ "operation_id"
  , "fingerprint"
  , "episode_id"
  , "turn_id"
  , "phase"
  , "outcome"
  , "accepted_appends"
  , "termination_code"
  , "output_reference"
  , "continuation_reference"
  , "cleanup"
  , "cleanup_code"
  , "acknowledged"
  ]

-- ---------------------------------------------------------------------------
-- Types

-- | The evidence package cannot be built from the given state directory.
newtype EvidenceExportError = EvidenceExportError Text
  deriving stock (Eq, Show)

instance Exception EvidenceExportError

refuse :: Text -> IO a
refuse = throwIO . EvidenceExportError

-- | The keyword arguments of @export_package@.
data ExportRequest = ExportRequest
  { stateDir :: Text
  , out :: Text
  , repository :: Text
  , pullRequest :: Integer
  , identity :: [Text]
  , webhookDeliveries :: [Text]
  }
  deriving stock (Show)

-- | What the package holds, and what the state directory did not.
data Report = Report
  { numbers :: Map Text Json
  , gaps :: [Text]
  }
  deriving stock (Show)

data Reporter = Reporter (IORef (Map Text Json)) (IORef [Text])

gap :: Reporter -> Text -> IO ()
gap (Reporter _ gaps) message = modifyIORef' gaps (message :)

setNumber :: Reporter -> Text -> Json -> IO ()
setNumber (Reporter numbers _) key value = modifyIORef' numbers (Map.insert key value)

snapshot :: Reporter -> IO Report
snapshot (Reporter numbers gaps) = Report <$> readIORef numbers <*> (reverse <$> readIORef gaps)

data Instance = Instance
  { directory :: Text
  , installationId :: Integer
  , repositoryId :: Integer
  , pullRequest :: Integer
  , instanceId :: Text
  , repository :: Text
  , topology :: Text
  }

data Operation = Operation
  { operationId :: Text
  , logicalOperation :: Text
  , attempt :: Integer
  , kind :: Text
  , origin :: Text
  , historyOccurrences :: [Integer]
  , historyInputs :: [PV]
  }

data RawDelivery = RawDelivery {path :: Text, deliveryId :: Text, label :: Text}

type Record = [(Text, PV)]

type Row = [(Text, PV)]

-- | The @bodies.sqlite3@ key for one logical agent operation attempt: the
-- ONLY join between canonical History and the agent session bodies.
agentOperationId :: Text -> Integer -> Text
agentOperationId operation attempt =
  "pi:" <> sha256Hex (TE.encodeUtf8 (operation <> "\0" <> tshow attempt))

tshow :: (Show a) => a -> Text
tshow = T.pack . show

sha256Hex :: BS.ByteString -> Text
sha256Hex bytes = TE.decodeUtf8 (Base16.encode (BA.convert (hashWith SHA256 bytes)))

-- ---------------------------------------------------------------------------
-- Reading the state directory

-- | Query a copy so a WAL rollforward can never touch the source.
rowsOf :: Text -> Text -> Text -> IO [Row]
rowsOf path scratch query = do
  let target = joinPath scratch (pathName path)
  copyFile path target
  forM_ ["-wal", "-shm"] $ \sidecar -> do
    let companion = joinPath (pathParent path) (pathName path <> sidecar)
    present <- exists companion
    when present $ copyFile companion (target <> sidecar)
  queryRows target query

-- | Select the one Instance directory whose binding matches the PR.
findInstance :: Text -> Text -> Integer -> IO Instance
findInstance stateDir repository pullRequest = do
  paths <- globBindings stateDir (tshow pullRequest)
  matches <- fmap concat . forM paths $ \bindingPath -> do
    binding <- readText bindingPath >>= raiseEither . loadsText
    stated <- fromMaybe (PStr "") <$> raiseEither (get "repository" binding)
    statedText <- case stated of
      PStr s -> pure s
      other -> raise (PyError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'lower'"))
    let members = case binding of
          PDict m -> m
          _ -> []
    if pyLower statedText /= pyLower repository
      then pure []
      else do
        unless (maybe False (pyEq (PInt pullRequest)) (getKey "pull_request" members)) $
          refuse ("binding " <> bindingPath <> " disagrees with its own path")
        let directory = pathParent bindingPath
            parts = reverse (T.splitOn "/" directory)
            part n = if length parts > n then parts !! n else ""
        installation <- raiseEither (intText (part 2))
        repositoryId <- raiseEither (intText (part 1))
        instanceId <- pyStr <$> raiseEither (subscript "instance_id" members)
        boundRepository <- pyStr <$> raiseEither (subscript "repository" members)
        pure
          [ Instance
              { directory
              , installationId = installation
              , repositoryId
              , pullRequest
              , instanceId
              , repository = boundRepository
              , topology = pyStr (fromMaybe (PStr "") (getKey "topology" members))
              }
          ]
  case matches of
    [one] -> pure one
    _ ->
      refuse
        ( "state directory holds "
            <> tshow (length matches)
            <> " Instances for "
            <> repository
            <> " PR "
            <> tshow pullRequest
            <> "; expected exactly one"
        )

-- | Canonical History in file order; the line number is the record seq.
readHistory :: Text -> IO [Record]
readHistory path = do
  bytes <- readText path
  -- Every line parses on its own, so they parse at once; the first bad
  -- one in file order is still the one reported.
  parsed <- parallelMap 256 forceParsed parseLine (zip [1 :: Integer ..] (splitLines bytes))
  fmap concat . forM parsed $ \(seq', outcome) -> case outcome of
    Nothing -> pure []
    Just (Left e) | e.cls == "json.decoder.JSONDecodeError" -> refuse ("History record " <> tshow seq' <> " is not JSON")
    Just (Left e) -> raise e
    Just (Right (PDict members)) | contains "record" members -> pure [members]
    Just (Right _) -> refuse ("History record " <> tshow seq' <> " has no record kind")
  where
    parseLine (seq', line) = (seq', if blank line then Nothing else Just (loadsText line))
    forceParsed (_, outcome) = case outcome of
      Just (Right value) -> forceValue value
      Just (Left e) -> e `seq` ()
      Nothing -> ()
    -- @not line.strip()@: decided on the bytes unless only non-ASCII
    -- characters could be the non-space ones.
    blank line
      | BS.any (\b -> b < 0x80 && not (asciiSpace b)) line = False
      | BS.all (< 0x80) line = True
      | otherwise = T.null (Py.strip (TE.decodeUtf8 line))
    asciiSpace b = (b >= 0x09 && b <= 0x0D) || (b >= 0x1C && b <= 0x20)

-- | @str.splitlines()@ over UTF-8 text, on its bytes: the line breaks are
-- @\\n \\v \\f \\r \\x1c \\x1d \\x1e@ (one byte each), @\\x85@ (C2 85) and
-- @\\u2028 \\u2029@ (E2 80 A8, E2 80 A9), and @\\r\\n@ breaks once.
splitLines :: BS.ByteString -> [BS.ByteString]
splitLines bytes = go 0 0
  where
    size = BS.length bytes
    at i = BU.unsafeIndex bytes i
    candidate b = (b >= 0x0A && b <= 0x0D) || (b >= 0x1C && b <= 0x1E) || b == 0xC2 || b == 0xE2
    slice start end = BU.unsafeTake (end - start) (BU.unsafeDrop start bytes)
    -- @start@ begins the current line; @from@ is where to look for its end.
    go !start !from = case BS.findIndex candidate (BU.unsafeDrop from bytes) of
      Nothing -> [slice start size | size > start]
      Just offset ->
        let i = from + offset
         in case breakWidth i (at i) of
              0 -> go start (i + 1)
              width -> slice start i : go (i + width) (i + width)
    breakWidth i b
      | b == 0x0D = if i + 1 < size && at (i + 1) == 0x0A then 2 else 1
      | b == 0xC2 = if i + 1 < size && at (i + 1) == 0x85 then 2 else 0
      | b == 0xE2 = if i + 2 < size && at (i + 1) == 0x80 && (at (i + 2) == 0xA8 || at (i + 2) == 0xA9) then 3 else 0
      | otherwise = 1 :: Int

recordKind :: Record -> PV
recordKind record = fromMaybe PNone (getKey "record" record)

isStr :: Text -> PV -> Bool
isStr expected = \case
  PStr s -> s == expected
  _ -> False

indexLine :: Reporter -> Integer -> Record -> IO Text
indexLine reporter seq' record = do
  let kind = pyStr (recordKind record)
  fields <- case lookup kind indexFields of
    Just known -> pure known
    Nothing -> do
      gap reporter ("history index has no field vocabulary for record kind " <> strRepr kind <> " (record " <> tshow seq' <> ")")
      pure (sort [name | (name, _) <- record, name `notElem` ["record", "schema", "instant", "occurrence"]])
  let occurrence = ["occurrence=" <> pyStr value | Just value <- [getKey "occurrence" record]]
      named = [name <> "=" <> pyStr value | name <- fields, Just value <- [getKey name record], not (isNone value)]
      tokens = case getKey "tokens" record of
        Just (PList items) ->
          ["tokens=" <> T.intercalate "," [pyStr (fromMaybe PNone (getKey "color" token)) | PDict token <- items]]
        _ -> []
      result = case getKey "result" record of
        Just (PDict members) | Just variant <- getKey "$variant" members -> ["result=" <> pyStr variant]
        _ -> []
  pure (T.justifyRight 5 ' ' (tshow seq') <> "  " <> T.justifyLeft 30 ' ' kind <> " " <> T.unwords (occurrence ++ named ++ tokens ++ result))

isNone :: PV -> Bool
isNone = \case
  PNone -> True
  _ -> False

historyIndex :: Reporter -> [Record] -> IO Text
historyIndex reporter records = do
  lines' <- forM (zip [1 ..] records) (uncurry (indexLine reporter))
  pure
    ( "# History index\n\n"
        <> "One line per record of `history.jsonl`, in file order. `seq` is the\n"
        <> "1-based line number in that file \x2014 open the raw line to see the full\n"
        <> "record. `occurrence` correlates an Activity request with its terminal\n"
        <> "and with the firing that produced it.\n\n"
        <> "```\n  seq  kind                           fields\n"
        <> T.intercalate "\n" lines'
        <> "\n```\n"
    )

-- | Every landed dashboard publication, paired with its History seq.
boardDocuments :: [Record] -> [(Integer, [(Text, PV)])]
boardDocuments records =
  [ (seq', result)
  | (seq', record) <- zip [1 ..] records
  , isStr "ActivityCompleted" (recordKind record)
  , Just (PDict result) <- [getKey "result" record]
  , maybe False (isStr "DashLanded") (getKey "$variant" result)
  ]

-- | Every Activity terminal variant, keyed by the occurrence it settles.
historyTerminals :: [Record] -> IO (Map Integer [Text])
historyTerminals = foldM step Map.empty
  where
    step terminals record = do
      let kind = recordKind record
      raiseEither (hashCheck kind)
      if not (any (`isStr` kind) terminalRecords) || not (contains "occurrence" record)
        then pure terminals
        else do
          let variant = case getKey "result" record of
                Just (PDict result) -> fromMaybe PNone (getKey "$variant" result)
                _ -> PNone
              chosen = case filter truthy [variant, fromMaybe PNone (getKey "reason" record)] of
                first : _ -> first
                [] -> kind
          occurrence <- raiseEither (subscript "occurrence" record >>= pyInt)
          pure (Map.insertWith (flip (++)) occurrence [pyStr chosen] terminals)

-- | Every agent operation attempt canonical History itself requests.
historyOperations :: [Record] -> Instance -> IO [Operation]
historyOperations records inst = do
  (order, table) <- foldM step ([], Map.empty) records
  pure (mapMaybe (`Map.lookup` table) (reverse order))
  where
    step acc@(order, table) record
      | not (isStr "ActivityRequested" (recordKind record)) = pure acc
      | otherwise = do
          let payload = getKey "input" record
              work = case payload of
                Just (PDict members) -> getKey "work" members
                _ -> Nothing
              activity = getKey "activity" record
          case work of
            Just (PDict members)
              | maybe False (isStr "review_agent") activity -> do
                  logical <- pyStr <$> raiseEither (subscript "operation" members)
                  attempt <- raiseEither (subscript "attempt" members >>= pyInt)
                  settle logical attempt "review"
              | maybe False (isStr "git_gate") activity -> do
                  opKey <- raiseEither (subscript "op_key" members)
                  let logical = "mutation:" <> inst.repository <> ":pr:" <> tshow inst.pullRequest <> ":" <> pyStr opKey
                  settle logical 1 "mutation"
              where
                settle logical attempt kind = do
                  let operationId = agentOperationId logical attempt
                      seen = Map.lookup operationId table
                  occurrence <- raiseEither (subscript "occurrence" record >>= pyInt)
                  let operation =
                        Operation
                          { operationId
                          , logicalOperation = logical
                          , attempt
                          , kind
                          , origin = "history"
                          , historyOccurrences = maybe [] (.historyOccurrences) seen ++ [occurrence]
                          , historyInputs = maybe [] (.historyInputs) seen ++ [fromMaybe PNone payload]
                          }
                  pure (if isJust seen then order else operationId : order, Map.insert operationId operation table)
            _ -> pure acc

-- | Agent operations routed outside the net, chiefly conversation.
routedOperations :: [Row] -> [Operation] -> IO [Operation]
routedOperations routes known = do
  let logicalKnown = Set.fromList (map (.logicalOperation) known)
  fmap concat . forM routes $ \row -> do
    logical <- pyStr <$> raiseEither (subscript "operation" row)
    pure
      [ Operation
          { operationId = agentOperationId logical 1
          , logicalOperation = logical
          , attempt = 1
          , kind = fst (T.breakOn ":" logical)
          , origin = "agent-routes"
          , historyOccurrences = []
          , historyInputs = []
          }
      | not (Set.member logical logicalKnown)
      ]

transcriptStem :: Text -> IO Text
transcriptStem operationId
  | wellFormed = pure (T.replace ":" "-" operationId)
  | otherwise = refuse ("agent operation id " <> strRepr operationId <> " is malformed")
  where
    wellFormed =
      not (T.null operationId) && T.length operationId <= 256 && T.all allowed operationId
    allowed c = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c `elem` (":._-" :: String)

-- | How much of one operation survived, and why no more than that.
sessionCoverage :: Operation -> Maybe Row -> Maybe PV -> Maybe Row -> Map Integer [Text] -> (Text, Text)
sessionCoverage operation body session piOperation terminals
  | maybe False truthy session = ("session_exported", "")
  | isJust body =
      let outcome = pyStr (orEmpty (piGet "outcome"))
       in if outcome /= "cancelled"
            then
              ( "body_without_session"
              , "the agent runtime records outcome " <> (if T.null outcome then "unknown" else outcome) <> " (" <> settled <> ")"
              )
            else
              ( "body_without_session"
              , "the agent turn was cancelled before any transcript line was appended (termination "
                  <> pyStr (fromMaybe PNone (piGet "termination_code"))
                  <> ", accepted_appends "
                  <> pyStr (fromMaybe PNone (piGet "accepted_appends"))
                  <> "; "
                  <> settled
                  <> ")"
              )
  | not (null variants) && all (`elem` agentDeferralVariants) variants =
      ("no_body_no_session", "the round was deferred before the agent runtime stored a body (" <> settled <> ")")
  | otherwise = ("no_body_no_session", "the agent runtime stored nothing and History does not say why (" <> settled <> ")")
  where
    variants = nub [name | occurrence <- operation.historyOccurrences, name <- Map.findWithDefault [] occurrence terminals]
    settled = if null variants then "no History terminal" else "History terminal " <> T.intercalate "/" variants
    piGet key = piOperation >>= getKey key
    orEmpty = \case
      Just value | truthy value -> value
      _ -> PStr ""

-- ---------------------------------------------------------------------------
-- Writing the package

writeJsonFile :: Text -> Bool -> PV -> IO ()
writeJsonFile path sorted value = do
  bytes <- raiseEither (dumpsIndentedBytes sorted value)
  writeBytes path (bytes <> "\n")

pvList :: [Text] -> PV
pvList = PList . map PStr

pvInts :: [Integer] -> PV
pvInts = PList . map PInt

writeTranscripts ::
  Text ->
  [Operation] ->
  Map Text Row ->
  Map Text PV ->
  Map Text Row ->
  Map (Text, Integer) Row ->
  Map Integer [Text] ->
  Reporter ->
  IO ()
writeTranscripts out operations bodies sessions piOperations reviewRequests terminals reporter = do
  mkdirParents out
  -- The loop plans its files; they are written together, then the loop's
  -- failure (if any) is raised, leaving what the reference's loop leaves.
  planned <- newIORef []
  let plan path bytes = modifyIORef' planned ((path, bytes) :)
  outcome <- try (foldM (step plan) ([], 0 :: Integer, 0 :: Integer, Map.empty) operations)
  readIORef planned >>= writeFiles . reverse
  (index, joined, sessionBytes, classes) <- either (\(e :: SomeException) -> throwIO e) pure outcome
  writeJsonFile (joinPath out "index.json") True (PList (reverse index))
  let classCount name = Map.findWithDefault 0 name classes
  setNumber reporter "transcripts" $
    Object
      [ ("operations", Int (toInteger (length operations)))
      , ("bodies_joined", Int joined)
      , ("bodies_missing", Int (toInteger (length operations) - joined))
      , ("sessions_exported", Int (classCount "session_exported"))
      , ("session_jsonl_bytes", Int sessionBytes)
      ,
        ( "coverage"
        , Object
            [ ("session_exported", Int (classCount "session_exported"))
            , ("body_without_session", Int (classCount "body_without_session"))
            , ("no_body_no_session", Int (classCount "no_body_no_session"))
            ]
        )
      ]
  where
    step plan (index, joined, sessionBytes, classes) operation = do
      stem <- transcriptStem operation.operationId
      let body = Map.lookup operation.operationId bodies
          session = Map.lookup operation.operationId sessions
          piOperation = Map.lookup operation.operationId piOperations
          (coverage, reason) = sessionCoverage operation body session piOperation terminals
          classes' = Map.insertWith (+) coverage (1 :: Integer) classes
      (sessionName, sessionLength) <- case session of
        Just value | truthy value -> do
          let name = stem <> ".session.jsonl"
          bytes <- case value of
            PBytes bytes -> pure bytes
            other -> raise (typeError ("memoryview: a bytes-like object is required, not " <> strRepr (typeName other)))
          plan (joinPath out name) bytes
          pure (Just name, toInteger (BS.length bytes))
        _ -> pure (Nothing, 0)
      let request = Map.lookup (operation.logicalOperation, operation.attempt) reviewRequests
      reviewRequest <- case request of
        Just row -> raiseEither (subscript "request_json" row >>= loadsValue)
        Nothing -> pure PNone
      digest <- case request of
        Just row -> raiseEither (subscript "digest" row)
        Nothing -> pure PNone
      let bodyMembers = case body of
            Just row | not (null row) -> [(name, fromMaybe PNone (getKey name row)) | name <- bodyColumns, name /= "operation_id"]
            _ -> []
          document =
            PDict
              [ ("operation_id", PStr operation.operationId)
              , ("logical_operation", PStr operation.logicalOperation)
              , ("attempt", PInt operation.attempt)
              , ("kind", PStr operation.kind)
              , ("origin", PStr operation.origin)
              , ("history_occurrences", pvInts operation.historyOccurrences)
              ,
                ( "history_terminals"
                , pvList [name | occurrence <- operation.historyOccurrences, name <- Map.findWithDefault [] occurrence terminals]
                )
              , ("coverage", PStr coverage)
              , ("coverage_reason", PStr reason)
              ,
                ( "request"
                , PDict
                    [ ("history_activity_inputs", PList operation.historyInputs)
                    , ("review_request", reviewRequest)
                    , ("review_request_digest", digest)
                    ]
                )
              ,
                ( "response"
                , PDict
                    ( [("body_present", PBool (isJust body))]
                        ++ bodyMembers
                        ++ [ ("session_present", PBool (isJust sessionName))
                           , ("session_jsonl", maybe PNone PStr sessionName)
                           , ("session_jsonl_bytes", PInt sessionLength)
                           ]
                    )
                )
              , ("pi_operation", maybe PNone PDict piOperation)
              ]
      rendered <- raiseEither (dumpsIndentedBytes True document)
      plan (joinPath out (stem <> ".json")) (rendered <> "\n")
      let entry =
            PDict
              [ ("operation_id", PStr operation.operationId)
              , ("logical_operation", PStr operation.logicalOperation)
              , ("attempt", PInt operation.attempt)
              , ("kind", PStr operation.kind)
              , ("origin", PStr operation.origin)
              , ("history_occurrences", pvInts operation.historyOccurrences)
              , ("file", PStr (stem <> ".json"))
              , ("body_present", PBool (isJust body))
              , ("session_present", PBool (isJust sessionName))
              , ("session_jsonl", maybe PNone PStr sessionName)
              , ("coverage", PStr coverage)
              , ("coverage_reason", PStr reason)
              ]
          named =
            "agent operation "
              <> operation.logicalOperation
              <> " attempt "
              <> tshow operation.attempt
              <> " ("
              <> operation.operationId
              <> ")"
      joined' <- case coverage of
        "no_body_no_session" -> do
          gap reporter (named <> " has no body in bodies.sqlite3 and no session transcript: " <> reason)
          pure joined
        "body_without_session" -> do
          gap reporter (named <> " has a body but no session transcript: " <> reason)
          pure (joined + 1)
        _ -> pure (joined + 1)
      pure (entry : index, joined', sessionBytes + sessionLength, classes')

-- | Every saved delivery record in the supplied directories, by delivery
-- id (in first-seen order), and the files that are not delivery records.
indexRawDeliveries :: [Text] -> IO ([(Text, [RawDelivery])], [Text])
indexRawDeliveries directories = do
  (table, keys, unrecognized) <- foldM visit (Map.empty, [], []) directories
  -- Latest-first by first sighting, each delivery's records in order.
  pure ([(key, reverse (Map.findWithDefault [] key table)) | key <- keys], reverse unrecognized)
  where
    visit acc directory = do
      present <- isDir directory
      unless present $ refuse ("webhook delivery directory " <> directory <> " does not exist")
      paths <- sortOn pathName <$> iterdir directory
      foldM classify acc paths
    classify acc@(table, keys, unrecognized) path = do
      regular <- isFile path
      if not regular
        then pure acc
        else case deliveryName (pathName path) of
          Nothing -> pure (table, keys, path : unrecognized)
          Just (delivery, label) ->
            let record = RawDelivery {path, deliveryId = delivery, label}
                keys' = if Map.member delivery table then keys else delivery : keys
             in pure (Map.insertWith (++) delivery [record] table, keys', unrecognized)

-- | @_DELIVERY_FILE.fullmatch(name)@: the lower-cased delivery guid and the
-- label.
deliveryName :: Text -> Maybe (Text, Text)
deliveryName name = do
  let (guid, rest) = T.splitAt 36 name
  if T.length guid == 36 && guidShape guid then Just () else Nothing
  afterDash <- T.stripPrefix "-" rest
  let size = T.length afterDash
  if size < 6 then Nothing else Just ()
  let (label, suffix) = T.splitAt (size - 5) afterDash
  if jsonSuffix (T.unpack suffix) && not (T.any (== '\n') label) then Just (T.toLower guid, label) else Nothing
  where
    guidShape guid =
      and
        [ if i `elem` [8, 13, 18, 23] then c == '-' else isHex c
        | (i, c) <- zip [0 :: Int ..] (T.unpack guid)
        ]
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    jsonSuffix = \case
      ['.', j, s, o, n] ->
        j `elem` ("jJ" :: String) && s `elem` ("sS\x17F" :: String) && o `elem` ("oO" :: String) && n `elem` ("nN" :: String)
      _ -> False

-- | Copy the raw record behind every inbox row, and only those.
writeRawDeliveries :: Text -> [Text] -> [Row] -> Reporter -> IO ()
writeRawDeliveries out directories rows reporter
  | null directories = do
      setNumber reporter "raw_deliveries" $
        Object [("supplied", Bool False), ("directories", Array []), ("copied", Int 0)]
      gap
        reporter
        ( "the webhook inbox stores the DERIVED observation, not the raw request body; "
            <> "the state directory retains no raw webhook payloads and no --webhook-deliveries "
            <> "directory was supplied, so this package holds no raw delivery record"
        )
  | otherwise = do
      (byDelivery, unrecognized) <- indexRawDeliveries directories
      keyed <- forM rows $ \row -> do
        key <- pyLower . pyStr <$> raiseEither (subscript "delivery_id" row)
        pure (key, row)
      -- A dict keyed by the lower-cased id: first position, last row.
      let latest = Map.fromList keyed
          admitted = [(key, latest Map.! key) | key <- nubOrd (map fst keyed)]
          deliveryTable = Map.fromList byDelivery
      let target = joinPath out "deliveries"
      mkdirParents target
      copied <- fmap concat . forM admitted $ \(delivery, row) -> do
        let records = Map.findWithDefault [] delivery deliveryTable
        if null records
          then do
            gap
              reporter
              ( "webhook inbox row "
                  <> pyStr (fromMaybe PNone (getKey "delivery_id" row))
                  <> " ("
                  <> pyStr (fromMaybe PNone (getKey "event" row))
                  <> ") has no raw delivery "
                  <> "record in the supplied directories; only its derived observation travels"
              )
            pure []
          else fmap concat . forM records $ \record -> do
            let fileName = pathName record.path
                destination = joinPath target fileName
            taken <- exists destination
            if taken
              then do
                gap reporter ("two supplied directories hold a delivery record named " <> fileName <> "; kept the first")
                pure []
              else do
                copyFile record.path destination
                payload <- readBytes destination
                pure
                  [ PDict
                      [ ("file", PStr fileName)
                      , ("delivery_id", PStr record.deliveryId)
                      , ("label", PStr record.label)
                      , ("inbox_event", fromMaybe PNone (getKey "event" row))
                      , ("bytes", PInt (toInteger (BS.length payload)))
                      , ("sha256", PStr (sha256Hex payload))
                      , ("source", PStr record.path)
                      ]
                  ]
      let admittedIds = map fst admitted
          admittedSet = Set.fromList admittedIds
          outOfScope =
            [ PDict
                [ ("file", PStr (pathName record.path))
                , ("delivery_id", PStr record.deliveryId)
                , ("label", PStr record.label)
                , ("source", PStr record.path)
                ]
            | (delivery, records) <- sortOn fst byDelivery
            , not (Set.member delivery admittedSet)
            , record <- records
            ]
      writeJsonFile (joinPath target "index.json") True (PList copied)
      writeJsonFile (joinPath out "out-of-scope-deliveries.json") True $
        PDict
          [ ( "note"
            , PStr
                ( "delivery records found in the supplied directories whose delivery id this "
                    <> "pull request's webhook inbox never admitted; none of them were copied"
                )
            )
          , ("count", PInt (toInteger (length outOfScope)))
          , ("unrecognized_file_names", pvList (sort unrecognized))
          , ("files", PList outOfScope)
          ]
      forM_ (sort unrecognized) $ \name ->
        gap reporter (name <> " is not named <delivery_id>-<event>.json; it was not classified as a delivery record")
      let byteCount = sum [n | PDict entry <- copied, Just (PInt n) <- [getKey "bytes" entry]]
      setNumber reporter "raw_deliveries" $
        Object
          [ ("supplied", Bool True)
          , ("directories", Array (map String directories))
          , ("files_seen", Int (toInteger (sum (map (length . snd) byDelivery))))
          , ("matched_deliveries", Int (toInteger (length [d | d <- admittedIds, Map.member d deliveryTable])))
          , ("copied", Int (toInteger (length copied)))
          , ("bytes", Int byteCount)
          , ("inbox_rows_without_raw", Array (map String (sort [d | d <- admittedIds, not (Map.member d deliveryTable)])))
          , ("out_of_scope_files", Int (toInteger (length outOfScope)))
          , ("out_of_scope_listing", String "webhooks/out-of-scope-deliveries.json")
          , ("unrecognized_files", Array (map String (sort unrecognized)))
          ]

writeWebhooks :: Text -> Text -> Text -> [Text] -> Reporter -> IO ()
writeWebhooks out stateDir scratch deliveries reporter = do
  let path = joinPath stateDir "webhooks.sqlite3"
  present <- exists path
  if not present
    then do
      gap reporter "state directory has no webhooks.sqlite3; the webhook inbox is absent from this package"
      setNumber reporter "webhooks" (Object [("rows", Int 0), ("by_event", Object [])])
      writeRawDeliveries out deliveries [] reporter
    else do
      mkdirParents out
      rows <- rowsOf path scratch ("SELECT rowid, " <> T.intercalate ", " inboxColumns <> " FROM inbox ORDER BY rowid")
      (parsed, byEvent) <- withAppend (joinPath out "inbox.jsonl") $ \write ->
        foldM
          ( \(done, counts) row -> do
              observation <- raiseEither (subscript "observation" row >>= loadsValue)
              let row' = [(k, if k == "observation" then observation else v) | (k, v) <- row]
              event <- pyStr <$> raiseEither (subscript "event" row')
              line <- raiseEither (dumpsLine (PDict row'))
              write (line <> "\n")
              pure (row' : done, Map.insertWith (+) event (1 :: Integer) counts)
          )
          ([], Map.empty)
          rows
          >>= \(done, counts) -> pure (reverse done, counts)
      setNumber reporter "webhooks" $
        Object [("rows", Int (toInteger (length rows))), ("by_event", Object [(k, Int v) | (k, v) <- Map.toList byEvent])]
      writeRawDeliveries out deliveries parsed reporter

writeBoards :: Text -> [Record] -> Reporter -> IO ()
writeBoards out records reporter = do
  let landed = boardDocuments records
  mkdirParents out
  -- The boards render at once; each still fails where the reference's
  -- loop would, after the boards before it are written.
  rendered <- parallelMap 4 forceRendered render (zip [1 :: Int ..] landed)
  planned <- newIORef []
  outcome <- try . forM rendered $ \(name, seq', result, board) -> do
    text <- either raise pure board
    modifyIORef' planned ((joinPath out name, TE.encodeUtf8 (text <> "\n")) :)
    pure
      ( "- ["
          <> name
          <> "]("
          <> name
          <> ") \x2014 History seq "
          <> tshow seq'
          <> ", digest `"
          <> pyStr (fromMaybe (PStr "") (getKey "digest" result))
          <> "`"
      )
  readIORef planned >>= writeFiles . reverse
  entries' <- either (\(e :: SomeException) -> throwIO e) pure outcome
  let index = ["# Board history", "", "Every board the PR page showed, in publication order.", ""] ++ entries'
  writeText (joinPath out "index.md") (T.intercalate "\n" index <> "\n")
  setNumber reporter "boards" $
    Object [("dash_landed", Int (toInteger (length landed))), ("files", Int (toInteger (length landed)))]
  when (null landed) $
    gap reporter "canonical History holds no landed dashboard publication; no board state is reproducible"
  where
    render (ordinal, (seq', result)) =
      let name = T.justifyRight 4 '0' (tshow ordinal) <> ".md"
          board = do
            items <- subscript "entries" result >>= iterateValue
            either (Left . boardFailure) Right (renderBoard (map pyStr items))
       in (name, seq', result, board)
    forceRendered (_, _, _, board) = either (`seq` ()) (`seq` ()) board

-- | The board renderer's recorded failure text (@Name('message')@) as the
-- exception it stands for.
boardFailure :: Text -> PyError
boardFailure text =
  let (name, rest) = T.breakOn "(" text
      arguments = T.dropEnd 1 (T.drop 1 rest)
   in case literalEval ("[" <> arguments <> "]") of
        Right (PyList [PyStr message]) | name /= "KeyError" -> PyError name message
        Right (PyList [single]) -> PyError name (Lit.repr single)
        Right (PyList []) -> PyError name ""
        Right (PyList many) -> PyError name (Lit.repr (PyTuple many))
        _ -> PyError name arguments

credentialNamed :: Text -> Bool
credentialNamed path =
  let name = pyLower (pathName path)
   in name `elem` credentialNames
        || pyLower (pathSuffix path) `elem` credentialSuffixes
        || any (`T.isInfixOf` name) credentialMarkers

writeIdentity :: Text -> Text -> Instance -> [Text] -> Reporter -> IO ()
writeIdentity out stateDir inst extra reporter = do
  mkdirParents out
  copyFile (joinPath inst.directory "binding.json") (joinPath out "binding.json")
  fromState <- fmap concat . forM identityStateFiles $ \name -> do
    let candidate = joinPath stateDir name
    present <- isFile candidate
    if present
      then [name] <$ copyFile candidate (joinPath out name)
      else pure []
  (fromExtra, excludedExtra) <- foldM supplied ([], []) extra
  found <- rglobFiles stateDir
  let excluded = excludedExtra ++ [relative | (relative, full) <- found, credentialNamed full]
      copied = sort ("binding.json" : fromState ++ fromExtra)
      excludedNames = Set.toAscList (Set.fromList excluded)
      listing = PDict [("files", pvList copied), ("excluded_by_name", pvList excludedNames)]
  writeJsonFile (joinPath out "index.json") False listing
  setNumber reporter "identity" $
    Object [("files", Array (map String copied)), ("excluded_by_name", Array (map String excludedNames))]
  when (length copied == 1) $
    gap
      reporter
      ( "the state directory holds no run-identity artifact (image sha, petrus pin, runtime identity); "
          <> "only binding.json is in identity/ \x2014 pass --identity for the captured ones"
      )
  where
    supplied (copied, excluded) path
      | credentialNamed path = pure (copied, excluded ++ [pathName path])
      | otherwise = do
          present <- isFile path
          unless present $ refuse ("identity file " <> path <> " does not exist")
          copyFile path (joinPath out (pathName path))
          pure (copied ++ [pathName path], excluded)

writeHistory :: Text -> Text -> [Record] -> Reporter -> IO ()
writeHistory out source records reporter = do
  mkdirParents out
  copyFile source (joinPath out "history.jsonl")
  historyIndex reporter records >>= writeText (joinPath out "index.md")
  schemas <- foldM addSchema [] records
  let alone = case schemas of
        [only] -> pyEq only (PInt historySchema)
        _ -> False
      spelled = sort (map pyStr schemas)
  unless alone $
    gap
      reporter
      ( "canonical History carries schema versions "
          <> Lit.repr (PyList (map PyStr spelled))
          <> ", expected "
          <> tshow historySchema
      )
  size <- fileSize source
  bytes <- readBytes source
  setNumber reporter "history" $
    Object
      [ ("records", Int (toInteger (length records)))
      , ("bytes", Int size)
      , ("sha256", String (sha256Hex bytes))
      , ("schemas", Array (map String spelled))
      ]
  where
    addSchema schemas record = do
      let schema = fromMaybe PNone (getKey "schema" record)
      raiseEither (hashCheck schema)
      pure (if any (sameMember schema) schemas then schemas else schemas ++ [schema])
    -- A set compares by identity first, and @json.loads@ spells every
    -- @NaN@ as the one @float('nan')@ object, so NaN members collapse.
    sameMember a b = pyEq a b || (isNaNValue a && isNaNValue b)
    isNaNValue = \case
      PFloat d -> isNaN d
      _ -> False

agentRoutes :: Text -> Text -> Reporter -> IO [Row]
agentRoutes stateDir scratch reporter = do
  let path = joinPath stateDir "agent-routes.sqlite3"
  present <- exists path
  if not present
    then do
      gap reporter "state directory has no agent-routes.sqlite3; operations routed outside History cannot be recovered"
      pure []
    else rowsOf path scratch "SELECT operation, profile, resolved FROM agent_routes ORDER BY operation"

agentBodies :: Text -> Text -> Reporter -> IO (Map Text Row, Map Text PV)
agentBodies stateDir scratch reporter = do
  let relative = "pi-a2/runtime-host/bodies.sqlite3"
      path = joinPath stateDir relative
  present <- exists path
  if not present
    then do
      gap reporter ("state directory has no " <> relative <> "; no agent session body is available")
      pure (Map.empty, Map.empty)
    else do
      rows <-
        rowsOf
          path
          scratch
          ( "SELECT "
              <> T.intercalate ", " bodyColumns
              <> ", length(workspace_archive) AS workspace_archive_bytes,"
              <> " session_jsonl FROM pi_a2_bodies"
          )
      foldM
        ( \(bodies, sessions) row -> do
            key <- pyStr <$> raiseEither (subscript "operation_id" row)
            session <- raiseEither (subscript "session_jsonl" row)
            let body = [(k, v) | (k, v) <- row, k /= "session_jsonl"]
            pure (Map.insert key body bodies, Map.insert key session sessions)
        )
        (Map.empty, Map.empty)
        rows

piOperationsOf :: Text -> Text -> Reporter -> IO (Map Text Row)
piOperationsOf stateDir scratch reporter = do
  let relative = "pi-a2/runtime-host/operations.sqlite3"
      path = joinPath stateDir relative
  present <- exists path
  if not present
    then do
      gap reporter ("state directory has no " <> relative <> "; agent settlement outcomes are unavailable")
      pure Map.empty
    else do
      rows <- rowsOf path scratch ("SELECT " <> T.intercalate ", " piOperationColumns <> " FROM pi_operations ORDER BY sequence")
      foldM
        (\table row -> (\key -> Map.insert key row table) . pyStr <$> raiseEither (subscript "operation_id" row))
        Map.empty
        rows

reviewRequestsOf :: Instance -> Text -> Reporter -> IO (Map (Text, Integer) Row)
reviewRequestsOf inst scratch reporter = do
  let path = joinPath inst.directory "review-requests.sqlite3"
  present <- exists path
  if not present
    then do
      gap reporter "Instance has no review-requests.sqlite3; composed review requests are unavailable"
      pure Map.empty
    else do
      rows <- rowsOf path scratch "SELECT operation, attempt, request_json, digest FROM v5_review_requests"
      foldM
        ( \table row -> do
            operation <- pyStr <$> raiseEither (subscript "operation" row)
            attempt <- raiseEither (subscript "attempt" row >>= pyInt)
            pure (Map.insert (operation, attempt) row table)
        )
        Map.empty
        rows

-- | Export a body no known operation claims rather than dropping it.
adoptUnattributed :: [Operation] -> Map Text Row -> Reporter -> IO [Operation]
adoptUnattributed operations bodies reporter = do
  let claimed = Set.fromList (map (.operationId) operations)
      orphans = [operationId | operationId <- Map.keys bodies, not (Set.member operationId claimed)]
  adopted <- forM orphans $ \operationId -> do
    gap reporter ("agent body " <> operationId <> " matches no known operation; exported as unattributed")
    pure
      Operation
        { operationId
        , logicalOperation = ""
        , attempt = 0
        , kind = "unattributed"
        , origin = "bodies"
        , historyOccurrences = []
        , historyInputs = []
        }
  pure (operations ++ adopted)

-- | Write the evidence package and return what it holds and lacks.
--
-- Raises 'EvidenceExportError' where the reference refuses, and 'PyError'
-- where the reference raises anything else.
exportPackage :: ExportRequest -> IO Report
exportPackage request = do
  stateIsDir <- isDir request.stateDir
  unless stateIsDir $ refuse ("state directory " <> request.stateDir <> " does not exist")
  outExists <- exists request.out
  when outExists $ do
    entries <- iterdir request.out
    unless (null entries) $ refuse ("output directory " <> request.out <> " already exists and is not empty")
  inst <- findInstance request.stateDir request.repository request.pullRequest
  let historyPath = joinPath inst.directory "history.jsonl"
  historyIsFile <- isFile historyPath
  unless historyIsFile $
    refuse ("Instance " <> inst.instanceId <> " has no canonical History at " <> historyPath)
  records <- readHistory historyPath
  reporter <- Reporter <$> newIORef Map.empty <*> newIORef []
  setNumber reporter "instance" $
    Object
      [ ("repository", String inst.repository)
      , ("pull_request", Int inst.pullRequest)
      , ("installation_id", Int inst.installationId)
      , ("repository_id", Int inst.repositoryId)
      , ("instance_id", String inst.instanceId)
      , ("topology", String inst.topology)
      , ("state_directory", String request.stateDir)
      ]
  mkdirParents request.out
  withScratch "hamsterdan-export-" $ \scratch -> do
    fromHistory <- historyOperations records inst
    routed <- agentRoutes request.stateDir scratch reporter >>= (`routedOperations` fromHistory)
    (bodies, sessions) <- agentBodies request.stateDir scratch reporter
    operations <- adoptUnattributed (fromHistory ++ routed) bodies reporter
    writeHistory (joinPath request.out "history") historyPath records reporter
    writeBoards (joinPath request.out "boards") records reporter
    piOperations <- piOperationsOf request.stateDir scratch reporter
    reviewRequests <- reviewRequestsOf inst scratch reporter
    terminals <- historyTerminals records
    writeTranscripts (joinPath request.out "transcripts") operations bodies sessions piOperations reviewRequests terminals reporter
    writeWebhooks (joinPath request.out "webhooks") request.stateDir scratch request.webhookDeliveries reporter
    writeIdentity (joinPath request.out "identity") request.stateDir inst request.identity reporter
  Report {gaps} <- snapshot reporter
  setNumber reporter "gaps" (Int (toInteger (length gaps)))
  report <- snapshot reporter
  manifest <-
    raiseEither
      ( dumpsIndentedJson
          (Object (("schema", Int packageSchema) : Map.toList report.numbers ++ [("gap_details", Array (map String report.gaps))]))
      )
  writeText (joinPath request.out "MANIFEST.json") (manifest <> "\n")
  writeText (joinPath request.out "README.md") (readme inst report)
  pure report

dumpsIndentedJson :: Json -> Either PyError Text
dumpsIndentedJson = dumpsIndented True . fromJsonValue

fromJsonValue :: Json -> PV
fromJsonValue = \case
  Null -> PNone
  Bool b -> PBool b
  Int i -> PInt i
  Float d -> PFloat d
  String s -> PStr s
  Array items -> PList (map fromJsonValue items)
  Object members -> PDict [(k, fromJsonValue v) | (k, v) <- members]

-- ---------------------------------------------------------------------------
-- README

numberAt :: [Text] -> Report -> Maybe Json
numberAt keys report = case keys of
  [] -> Nothing
  first : rest -> Map.lookup first report.numbers >>= descend rest
  where
    descend [] value = Just value
    descend (key : more) (Object members) = lookup key members >>= descend more
    descend _ _ = Nothing

jsonText :: Maybe Json -> Text
jsonText = \case
  Just (Int i) -> tshow i
  Just (String s) -> s
  Just (Bool True) -> "True"
  Just (Bool False) -> "False"
  Just Null -> "None"
  _ -> ""

rawDeliveryProse :: Report -> Text
rawDeliveryProse report
  | numberAt ["raw_deliveries", "supplied"] report /= Just (Bool True) =
      "No `--webhook-deliveries` directory was supplied to this build, so\n"
        <> "**this package holds no raw GitHub delivery record**. The webhook\n"
        <> "inbox persists the DERIVED observation only; the full request\n"
        <> "payload and the request/response metadata of each delivery are not\n"
        <> "in the state directory and were not supplied from outside it.\n"
  | otherwise =
      "`webhooks/deliveries/` holds "
        <> at "copied"
        <> " raw GitHub delivery record file(s),\n"
        <> "covering "
        <> at "matched_deliveries"
        <> " of the "
        <> jsonText (numberAt ["webhooks", "rows"] report)
        <> " inbox rows"
        <> " (a redelivered id has two files), copied\n"
        <> "byte-for-byte from "
        <> T.intercalate ", " ["`" <> name <> "`" | String name <- listAt "directories"]
        <> " with a\n"
        <> "sha256 per file in `webhooks/deliveries/index.json`. A record is copied only when\n"
        <> "this pull request's own inbox admitted its delivery id; the other\n"
        <> at "out_of_scope_files"
        <> " record(s) in those directories belong to deliveries this\n"
        <> "PR never admitted and are named \x2014 not copied \x2014 in\n"
        <> "`webhooks/out-of-scope-deliveries.json`. Inbox rows with no raw record:\n"
        <> tshow (length (listAt "inbox_rows_without_raw"))
        <> ".\n"
  where
    at key = jsonText (numberAt ["raw_deliveries", key] report)
    listAt key = case numberAt ["raw_deliveries", key] report of
      Just (Array items) -> items
      _ -> []

coverageProse :: Report -> Text
coverageProse report =
  "Of "
    <> count ["transcripts", "operations"]
    <> " operations,\n"
    <> count ["transcripts", "coverage", "session_exported"]
    <> " carry a full `.session.jsonl` transcript,\n"
    <> count ["transcripts", "coverage", "body_without_session"]
    <> " have a response body but no transcript, and\n"
    <> count ["transcripts", "coverage", "no_body_no_session"]
    <> " have neither. Every operation names its own class in\n"
    <> "`transcripts/index.json` (`coverage`) together with the reason\n"
    <> "(`coverage_reason`), and each of the last two classes is listed under\n"
    <> "Gaps below. A session transcript exists only in the `session_jsonl`\n"
    <> "column of `pi_a2_bodies`; there is no other store of one, so a body\n"
    <> "without a transcript is a turn that appended none \x2014 chiefly a review\n"
    <> "round the gate deferred, cancelling the agent turn at once.\n"
  where
    count keys = maybe "0" (jsonText . Just) (numberAt keys report)

readme :: Instance -> Report -> Text
readme inst report =
  let gaps = if null report.gaps then "- none reported." else T.intercalate "\n" ["- " <> g | g <- report.gaps]
      rawDeliveries = rawDeliveryProse report
      coverage = coverageProse report
   in T.concat
      [ "# Hamsterdan evidence package \x2014\& "
      , inst.repository
      , " PR "
      , tshow inst.pullRequest
      , "\n"
      , "\n"
      , "Built offline from a local copy of `/var/lib/hamsterdan` by\n"
      , "`python -m hamsterdan.host.export`. Everything here is a copy or a\n"
      , "derivation of that durable state; nothing was fetched and nothing was\n"
      , "rerun. `MANIFEST.json` carries the same numbers as this file, machine\n"
      , "readable.\n"
      , "\n"
      , "Instance `"
      , inst.instanceId
      , "` (installation "
      , tshow inst.installationId
      , ",\n"
      , "repository "
      , tshow inst.repositoryId
      , ", topology `"
      , inst.topology
      , "`).\n"
      , "\n"
      , "## What each directory is\n"
      , "\n"
      , "- `history/history.jsonl` \x2014\& canonical History, copied verbatim. This is\n"
      , "  the workflow authority: every other artifact here is derived from it\n"
      , "  or joined to it. `history/index.md` is a navigation aid, one line per\n"
      , "  record, keyed by the 1-based line number (`seq`) of the raw file.\n"
      , "- `transcripts/` \x2014\& one `.json` per agent operation attempt with its\n"
      , "  request and its response body, plus the full Pi session transcript as\n"
      , "  `<id>.session.jsonl` whenever the turn appended one.\n"
      , "  `transcripts/index.json` lists every operation, whether its body was\n"
      , "  found, whether its session travelled, and why not when it did not.\n"
      , "- `webhooks/inbox.jsonl` \x2014\& every row of the durable webhook inbox, one\n"
      , "  JSON object per line, all columns.\n"
      , "- `webhooks/deliveries/` \x2014\& the raw GitHub delivery record (full request\n"
      , "  payload plus request and response metadata) behind each of those rows,\n"
      , "  when one was supplied; `webhooks/out-of-scope-deliveries.json` names\n"
      , "  the supplied records this PR's inbox never admitted.\n"
      , "- `boards/` \x2014\& every board the PR page ever showed, rendered from each\n"
      , "  landed dashboard publication in History with the production renderer\n"
      , "  (`hamsterdan.readiness.net_v5.board.render_board`), numbered in\n"
      , "  publication order. `boards/index.md` maps each file to its History\n"
      , "  `seq`.\n"
      , "- `identity/` \x2014\& the Instance binding plus whatever run-identity\n"
      , "  artifacts were available (image sha, petrus pin, runtime identity).\n"
      , "\n"
      , "## How records join\n"
      , "\n"
      , "Canonical History records an agent Activity as `ActivityRequested` with\n"
      , "the logical operation and attempt inside `input.work`. The agent runner\n"
      , "derives the body key from exactly those two values:\n"
      , "\n"
      , "    operation_id = \"pi:\" + sha256(f\"{operation}\\0{attempt}\").hexdigest()\n"
      , "\n"
      , "That `operation_id` is the primary key of `pi_a2_bodies` in\n"
      , "`pi-a2/runtime-host/bodies.sqlite3` and of `pi_operations` in\n"
      , "`operations.sqlite3`. Each `transcripts/<id>.json` carries the logical\n"
      , "operation, the attempt, every History `occurrence` that requested it,\n"
      , "and the joined body \x2014\& or `\"body_present\": false` when the state\n"
      , "directory did not retain one.\n"
      , "\n"
      , "Three operation families use the key:\n"
      , "\n"
      , "- `review:...` \x2014\& attempt is the net's review attempt, taken from\n"
      , "  History; the composed request also survives in\n"
      , "  `review-requests.sqlite3` and is inlined as `request.review_request`.\n"
      , "- `mutation:...` \x2014\& one agent turn per `op_key`, so attempt is 1. A gate\n"
      , "  that reconciles lookup-first is requested again under the same key, so\n"
      , "  one transcript can list several `history_occurrences`.\n"
      , "- `conversation:...` \x2014\& comment classification runs BEFORE the ingress\n"
      , "  manifest stages, so these operations never enter History. They are\n"
      , "  recovered from `agent-routes.sqlite3` at attempt 1; their `origin` is\n"
      , "  `agent-routes` and their `history_occurrences` list is empty.\n"
      , "\n"
      , "Webhook inbox rows join to History through the delivery id: the\n"
      , "observation's `delivery_id` appears in the conversation operation name\n"
      , "and in the ingress identities of `ExternalEventDelivered` records.\n"
      , "\n"
      , "## Session transcript coverage\n"
      , "\n"
      , coverage
      , "\n"
      , "## Raw webhook deliveries\n"
      , "\n"
      , rawDeliveries
      , "\n"
      , "## How to replay the net from History\n"
      , "\n"
      , "`history.jsonl` alone reconstructs the run. `Engine.load` binds every\n"
      , "declared handler before it replays, so the V5 gate implementations have\n"
      , "to be present \x2014\& but replay never CALLS one, it only re-reads the\n"
      , "recorded terminals. Uninitialized gate instances are therefore enough,\n"
      , "and nothing in this recipe can touch GitHub, Pi, or the network:\n"
      , "\n"
      , "```python\n"
      , "from pathlib import Path\n"
      , "\n"
      , "from petrus.engine import Engine\n"
      , "from petrus.impetus.history_store import JsonlHistoryStore\n"
      , "from petrus.impetus.petrinet import NetPath\n"
      , "from petrus.motus.activity import activity\n"
      , "from petrus.motus.dispatch import InlineDispatch\n"
      , "\n"
      , "from hamsterdan.host.v5.gates import V5PublicationGates\n"
      , "from hamsterdan.host.v5.mutation import V5MutationGate\n"
      , "from hamsterdan.host.v5.rerun import V5RerunGate\n"
      , "from hamsterdan.host.v5.review import V5ReviewGate\n"
      , "from hamsterdan.readiness.net_v5 import build_net_v5\n"
      , "from hamsterdan.readiness.net_v5.gating import VariantPayloadConverter, wire_gates\n"
      , "from hamsterdan.readiness.net_v5.topology import DERIVED, GATES\n"
      , "\n"
      , "publications = V5PublicationGates.__new__(V5PublicationGates)\n"
      , "mutation = V5MutationGate.__new__(V5MutationGate)\n"
      , "rerun = V5RerunGate.__new__(V5RerunGate)\n"
      , "review = V5ReviewGate.__new__(V5ReviewGate)\n"
      , "converter = VariantPayloadConverter()\n"
      , "definitions = {\n"
      , "    name: activity(implementation, name=name, converter=converter)\n"
      , "    for name, implementation in {\n"
      , "        \"rerun_gate\": rerun.rerun_gate,\n"
      , "        \"review_agent\": review.review_agent,\n"
      , "        \"publish_gate\": publications.publish_gate,\n"
      , "        \"git_gate\": mutation.git_gate,\n"
      , "        \"reply_gate\": publications.reply_gate,\n"
      , "        \"dash_gate\": publications.dash_gate,\n"
      , "        \"reminder_gate\": publications.reminder_gate,\n"
      , "        \"announce_gate\": publications.announce_gate,\n"
      , "    }.items()\n"
      , "}\n"
      , "built = build_net_v5()\n"
      , "engine = Engine.load(\n"
      , "    built.net,\n"
      , "    \""
      , inst.instanceId
      , "\",\n"
      , "    history=JsonlHistoryStore(Path(\"history/history.jsonl\")),\n"
      , "    dispatch=InlineDispatch(definitions),\n"
      , "    handlers=wire_gates(built, GATES, definitions, DERIVED),\n"
      , "    guards=built.guards,\n"
      , "    activities=tuple(item.declaration for item in definitions.values()),\n"
      , ")\n"
      , "print(len(tuple(engine.records)), \"records\")\n"
      , "print(tuple(engine.marking.place(NetPath(\"life.state\"))))\n"
      , "```\n"
      , "\n"
      , "Loading replays every record in order and rebuilds the exact final\n"
      , "marking. The board sequence in `boards/` is the same replay projected at\n"
      , "the publication seam: each landed dashboard result carries the entry log\n"
      , "the board renderer folds.\n"
      , "\n"
      , "## Excluded by name\n"
      , "\n"
      , "The exporter opens only the durable stores it names above, and it\n"
      , "refuses to copy any file whose name matches credential material\n"
      , "(`.env`, `*.pem`, `*.key`, or a name containing `secret`, `token`,\n"
      , "`credential`, `api-key`). `identity/index.json` lists every such path\n"
      , "seen under the state directory; none of them were copied. No\n"
      , "secret value is read, printed, or stored anywhere in this package.\n"
      , "\n"
      , "## Gaps\n"
      , "\n"
      , gaps
      , "\n"
      ]

-- ---------------------------------------------------------------------------
-- The command line

-- | Where the command line reads and writes.
data ExportEnvironment = ExportEnvironment
  { environment :: Map String String
  , output :: Handle
  , errors :: Handle
  }

productionEnvironment :: IO ExportEnvironment
productionEnvironment = do
  environment <- Map.fromList <$> getEnvironment
  pure ExportEnvironment {environment, output = stdout, errors = stderr}

-- | The reference's @ArgumentParser@.
exportParser :: Parser
exportParser =
  newParser
    "python -m hamsterdan.host.export"
    (Just "Export one PR's durable Hamsterdan state as an offline evidence package.")
    [ (option ["--state-dir"]) {valueType = AsPath, required = True, help = Just "local copy of /var/lib/hamsterdan"}
    , (option ["--out"]) {valueType = AsPath, required = True, help = Just "package directory to create"}
    , (option ["--repository"]) {required = True, help = Just "owner/name of the monitored repository"}
    , (option ["--pull-request"]) {valueType = AsInt, required = True, help = Just "pull request number"}
    , (option ["--identity"])
        { valueType = AsPath
        , behavior = Append
        , defaultValue = Just (List [])
        , help = Just "extra run-identity file to copy into identity/ (repeatable)"
        }
    , (option ["--webhook-deliveries"])
        { valueType = AsPath
        , behavior = Append
        , defaultValue = Just (List [])
        , dest = "webhook_deliveries"
        , help = Just "directory of raw GitHub delivery records named <delivery_id>-<event>.json (repeatable)"
        }
    ]

-- | @main(argv)@ as @python -m hamsterdan.host.export@ runs it: the exit
-- status, with every line the reference prints. An exception the
-- reference does not catch prints the last line of its traceback and
-- exits 1.
runExport :: ExportEnvironment -> [Text] -> IO ExitCode
runExport env argv = do
  width <- subtract 2 <$> terminalColumns env.environment
  case parseArgs width exportParser argv of
    Exited status printed problems -> do
      emit env.output printed
      emit env.errors problems
      pure (if status == 0 then ExitSuccess else ExitFailure status)
    Parsed namespace -> do
      let request =
            ExportRequest
              { stateDir = fromMaybe "." (lookupText "state_dir" namespace)
              , out = fromMaybe "." (lookupText "out" namespace)
              , repository = fromMaybe "" (lookupText "repository" namespace)
              , pullRequest = fromMaybe 0 (lookupInteger "pull_request" namespace)
              , identity = [p | Str p <- lookupList "identity" namespace]
              , webhookDeliveries = [p | Str p <- lookupList "webhook_deliveries" namespace]
              }
      outcome <- try (exportPackage request)
      case outcome of
        Right report -> do
          emit env.errors (T.concat ["GAP: " <> g <> "\n" | g <- report.gaps])
          numbers <- raiseEither (dumpsIndentedJson (Object (Map.toList report.numbers)))
          emit env.output (numbers <> "\n")
          emit env.output ("package written to " <> request.out <> " (gaps: " <> tshow (length report.gaps) <> ")\n")
          hFlush env.output
          pure ExitSuccess
        Left (e :: SomeException)
          | Just (EvidenceExportError message) <- fromException e -> do
              emit env.errors ("export failed: " <> message <> "\n")
              pure (ExitFailure 2)
          | Just (problem :: PyError) <- fromException e -> do
              emit env.errors (errorLine problem <> "\n")
              pure (ExitFailure 1)
          | otherwise -> do
              emit env.errors (T.pack (show e) <> "\n")
              pure (ExitFailure 1)

-- | Write text to a handle in one piece: @Data.Text.IO@ writes an
-- unbuffered handle (stderr) one character at a time.
emit :: Handle -> Text -> IO ()
emit handle text = BS.hPut handle (TE.encodeUtf8 text)
