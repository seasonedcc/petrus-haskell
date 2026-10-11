-- | Replays @differential/pi_corpus.json@, which @pi_corpus.py@ generates
-- from the reference, and cross-opens @pi_reference_ledger.sqlite3@, the
-- ledger file the reference wrote.
--
-- * Every protocol validator must return the same value or the same
--   @{class, message}@ refusal (a @JSONDecodeError@ only needs a
--   @ValueError@-family refusal; @_strict_load@ only needs to refuse).
-- * Every @start@, @tool_result@, @abort@ and arbitrary frame must encode to
--   the reference's exact wire bytes, or fail with its refusal.
-- * Durable work fingerprints and @PiOperationRecord@ construction must
--   agree case by case.
-- * The scripted ledger session must return the same records and refusals
--   and leave the same @sqlite_master@, @table_info@, rows,
--   @sqlite_sequence@ and journal mode; the reference-written file must
--   open, recover and project identically, including after raw row
--   mutations.
module Petrus.Agenticus.Runtime.PiDifferentialSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM, (>=>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Connection.Custody (mkConnectionIdentity)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (parseToolMethod)
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Runtime.Operation (mkRuntimeOperationCleanup, runtimeProtocolError)
import Petrus.Agenticus.Runtime.Pi
import Petrus.Agenticus.Runtime.PiRecovery
import Petrus.Agenticus.Runtime.PiSupport (invocation, newRig, rigOptions, withTemp)
import Petrus.Agenticus.Runtime.Result (mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (LifecycleId (..), mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (StrEnum (..), parseStrEnum)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (copyFile, createDirectory)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFileMode)
import Test.Hspec

corpus :: Json
corpus = unsafePerformIO $ do
  bytes <- B.readFile "differential/pi_corpus.json"
  either (fail . ("pi_corpus.json: " <>)) pure (J.parseJson J.pythonLoads bytes)
{-# NOINLINE corpus #-}

referenceLedger :: FilePath
referenceLedger = "differential/pi_reference_ledger.sqlite3"

field :: Text -> Json -> Maybe Json
field key = \case
  Object members -> lookup key members
  _ -> Nothing

member :: Text -> Json -> Json
member key value = fromMaybe (error ("missing " <> T.unpack key <> " in " <> show value)) (field key value)

text :: Text -> Json -> Text
text key value = case member key value of
  String t -> t
  other -> error ("not text at " <> T.unpack key <> ": " <> show other)

optionalText :: Text -> Json -> Maybe Text
optionalText key value = case member key value of
  Null -> Nothing
  String t -> Just t
  other -> error ("not optional text at " <> T.unpack key <> ": " <> show other)

int :: Text -> Json -> Int
int key value = case member key value of
  Int n -> fromInteger n
  other -> error ("not an int at " <> T.unpack key <> ": " <> show other)

items :: Json -> [Json]
items = \case
  Array xs -> xs
  other -> error ("not an array: " <> show other)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- | Base64 text from the corpus, decoded.
unb64 :: Text -> ByteString
unb64 = ok . pyB64DecodeStrict . TE.encodeUtf8

-- | @json.dumps(value, separators=(",", ":"), ensure_ascii=False)@.
render :: Json -> Text
render = ok . J.dumpsText J.compact {J.allowNan = True}

-- | @json.dumps(value, separators=(",", ":"), ensure_ascii=True)@.
renderAscii :: Json -> Text
renderAscii = ok . J.dumpsText J.compact {J.allowNan = True, J.ensureAscii = True}

-- ---------------------------------------------------------------------------
-- Outcomes

refusal :: AgenticusError -> Json
refusal e = Object [("class", String (errorClassName e.errorClass)), ("message", String e.errorMessage)]

outcome :: Either AgenticusError Json -> Json
outcome = \case
  Right v -> Object [("ok", v)]
  Left e -> Object [("error", refusal e)]

attempt :: IO Json -> IO Json
attempt action = outcome <$> try action

-- | The @ok@/@error@ members of a corpus case.
expectedOutcome :: Json -> Json
expectedOutcome c = case (field "ok" c, field "error" c) of
  (Just v, _) -> Object [("ok", v)]
  (_, Just e) -> Object [("error", e)]
  _ -> error ("no outcome in " <> show c)

-- | Whether an actual outcome matches the expected one. A @JSONDecodeError@
-- only needs a @ValueError@-family refusal: the port's JSON reader has its
-- own diagnostics.
agrees :: Json -> Json -> Bool
agrees expected actual = case (field "error" expected, field "error" actual) of
  (Just e, Just a)
    | text "class" e == "JSONDecodeError" -> text "class" a `elem` ["ValueError", "JSONDecodeError"]
  _ -> render expected == render actual

-- | Every disagreement, labelled.
mismatches :: [(String, Json, Json)] -> [String]
mismatches cases =
  [ label <> "\n  expected " <> T.unpack (render expected) <> "\n  actual   " <> T.unpack (render actual)
  | (label, expected, actual) <- cases
  , not (agrees expected actual)
  ]

noMismatches :: [(String, Json, Json)] -> Expectation
noMismatches cases = do
  case mismatches cases of
    [] -> pure ()
    found -> expectationFailure (show (length found) <> " of " <> show (length cases) <> " disagree:\n" <> unlines (take 20 found))

-- ---------------------------------------------------------------------------
-- Validation

validation :: Text -> Json -> Either AgenticusError Json
validation function arguments = case function of
  "uuid" -> String <$> piUuid (text "value" arguments)
  "text" -> String <$> piText "Pi label" (int "maximum" arguments) (text "value" arguments)
  "b64decode" -> String . b64Encode <$> pyB64DecodeText (text "value" arguments)
  "validate_native_auth" ->
    String . b64Encode
      <$> validateNativeAuth (unb64 (text "value" arguments)) (text "provider" arguments) (int "maximum" arguments)
  "decode_native_auth" ->
    String . b64Encode <$> decodeNativeAuth (member "value" arguments) (text "provider" arguments) (int "maximum" arguments)
  "validate_session" ->
    String . b64Encode
      <$> validateSession
        (unb64 (text "value" arguments))
        (text "session_id" arguments)
        (int "maximum" arguments)
        (int "events" arguments)
  "working_binding" -> Right (String (workingBinding (T.unpack (text "value" arguments))))
  "payload" ->
    String . b64Encode . (.sessionJsonl)
      <$> mkPiContinuationPayloadV1 (text "session_id" arguments) (text "binding" arguments) (unb64 (text "session" arguments))
  other -> error ("unknown validation function " <> T.unpack other)

-- | @_strict_load@ refuses without a message in the port; only acceptance
-- and the decoded value are compared.
strictLoadCase :: Json -> Json -> (String, Json, Json)
strictLoadCase c arguments =
  let expected = expectedOutcome c
      actual = case strictLoad (unb64 (text "value" arguments)) of
        Right v -> Object [("ok", String (renderAscii v))]
        Left () -> expected `orRefusal` Object [("error", Object [("class", String "refused"), ("message", String "")])]
   in ("strict_load " <> T.unpack (text "value" arguments), expected, actual)
  where
    orRefusal expected refused = maybe refused (const expected) (field "error" expected)

validationCases :: [(String, Json, Json)]
validationCases =
  [ if function == "strict_load"
      then strictLoadCase c arguments
      else (show i <> " " <> T.unpack function <> " " <> T.unpack (render arguments), expectedOutcome c, outcome (validation function arguments))
  | (i, c) <- zip [0 :: Int ..] (items (member "validation" corpus))
  , let function = text "function" c
        arguments = member "arguments" c
  ]

-- ---------------------------------------------------------------------------
-- Frames

-- | @_SubprocessClient._write@ into a buffer.
written :: Int -> Json -> Json
written bound frame = outcome $ case frameBytes frame of
  Left _ -> Left (runtimeProtocolError "helper-pipe-failed")
  Right encoded
    | B.length encoded > bound -> Left (runtimeProtocolError "frame-overflow")
    | otherwise -> Right (String (b64Encode encoded))

startCases :: FilePath -> IO [(String, Json, Json)]
startCases root = do
  rig <- newRig root rigOptions
  base <- invocation rig "start"
  forM (zip [0 :: Int ..] (items (member "starts" (member "frames" corpus)))) $ \(i, c) -> do
    let cwd = T.unpack (text "cwd" c)
        config = piRuntimeConfig (text "provider" c) (text "model" c) cwd "/unused"
        expected = member "frame" c
        expectedBytes = unb64 (text "ok" expected)
        session = case optionalText "session_id" c of
          Just s -> s
          Nothing -> text "session_id" (ok (J.parseJson J.pythonLoads expectedBytes))
        prior =
          ok . mkPiContinuationPayloadV1 (text "session_id" c) (workingBinding cwd) . unb64
            <$> optionalText "prior" c
        args =
          PiHelperArgs
            { node = "/usr/bin/true"
            , sdkEntrypoint = "/ignored"
            , privateRoot = T.unpack (text "root" c)
            , config
            , invocation = base {prompt = text "prompt" c, grantEpoch = base.grantEpoch}
            , prior
            , apiKey = optionalText "api_key" c
            , nativeAuth = unb64 <$> optionalText "auth" c
            , extension = Nothing
            }
        granted = Set.fromList [fromMaybe (error (T.unpack m)) (parseToolMethod m) | String m <- items (member "capabilities" c)]
        actual = written config.maxFrameBytes (Object (startFrame config args session granted))
    pure ("start " <> show i, Object [("ok", String (text "ok" expected))], actual)

frameCases :: [(String, Json, Json)]
frameCases =
  [ ("frame " <> show i, member "result" c, written defaultBound (member "frame" c))
  | (i, c) <- zip [0 :: Int ..] (items (member "others" frames))
  ]
    <> [ ("bounded frame " <> show i, member "result" c, written (int "maximum" c) (member "frame" c))
       | (i, c) <- zip [0 :: Int ..] (items (member "bounded" frames))
       ]
  where
    frames = member "frames" corpus
    defaultBound = (piRuntimeConfig "provider" "model" "/unused" "/unused").maxFrameBytes

-- ---------------------------------------------------------------------------
-- Fingerprints

fingerprintCases :: [(String, Json, Json)]
fingerprintCases =
  [ ("fingerprint " <> show i, expectedOutcome c, outcome (String <$> fingerprint c))
  | (i, c) <- zip [0 :: Int ..] (items (member "fingerprints" corpus))
  ]
  where
    configFor = \case
      "api-key" -> piRuntimeConfig "provider" "model" "/w" "/p"
      "gondolin" -> let d = piRuntimeConfig "provider" "model" "/w" "/p" in d {hostId = d.hostId, territoryProfile = "gondolin"}
      "cc-patch" -> let d = piRuntimeConfig "anthropic" "claude-sonnet-4-5" "/w" "/p" in d {hostId = d.hostId, ccPatch = True}
      "other-model" -> piRuntimeConfig "provider" "model-2" "/w" "/p"
      other -> error (T.unpack other)
    fingerprint c = do
      episode <- mkEpisodeId (text "episode_id" c)
      turn <- mkTurnId (text "turn_id" c)
      connection <- case [t | String t <- items (member "connection" c)] of
        [i, p, a, profile] -> mkConnectionIdentity i p a profile
        other -> error (show other)
      continuation <- case member "continuation" c of
        Null -> pure Nothing
        Array [String i, String thread, String reference] -> do
          continuationId <- mkContinuationId i
          threadId <- mkThreadId thread
          Just <$> mkContinuation continuationId threadId piContinuationDescriptor reference ContinuationInUse
        other -> error (show other)
      piDurableWorkFingerprint (configFor (text "config" c)) episode turn (text "prompt" c) connection continuation

-- ---------------------------------------------------------------------------
-- Records

recordJson :: PiOperationRecord -> Json
recordJson r =
  Object
    [ ("operation_id", String r.operationId)
    , ("fingerprint", String r.fingerprint)
    , ("episode_id", String (lifecycleIdText r.episodeId))
    , ("turn_id", String (lifecycleIdText r.turnId))
    , ("sequence", Int r.sequence)
    , ("phase", String (phaseText r.phase))
    , ("outcome", maybe Null (String . enumText) r.outcome)
    , ("accepted_appends", maybe Null Int r.acceptedAppends)
    , ("termination_code", maybe Null String r.terminationCode)
    , ("output_reference", maybe Null String r.outputReference)
    , ("continuation_reference", maybe Null String r.continuationReference)
    , ("cleanup", String (enumText r.cleanup))
    , ("cleanup_code", String r.cleanupCode)
    , ("acknowledged", Bool r.acknowledged)
    ]

-- | @record_from(data)@.
recordFrom :: Json -> Either AgenticusError PiOperationRecord
recordFrom d = do
  episodeId <- mkEpisodeId (text "episode_id" d)
  turnId <- mkTurnId (text "turn_id" d)
  mkPiOperationRecord
    PiOperationRecord
      { operationId = text "operation_id" d
      , fingerprint = text "fingerprint" d
      , episodeId
      , turnId
      , sequence = case member "sequence" d of Int n -> n; other -> error (show other)
      , phase = case text "phase" d of
          "executing" -> PhaseExecuting
          "settled" -> PhaseSettled
          other -> error (T.unpack other)
      , outcome = enum <$> optionalText "outcome" d
      , acceptedAppends = case member "accepted_appends" d of Null -> Nothing; Int n -> Just n; other -> error (show other)
      , terminationCode = optionalText "termination_code" d
      , outputReference = optionalText "output_reference" d
      , continuationReference = optionalText "continuation_reference" d
      , cleanup = enum (text "cleanup" d)
      , cleanupCode = text "cleanup_code" d
      , acknowledged = case member "acknowledged" d of Bool b -> b; other -> error (show other)
      }

enum :: (StrEnum a) => Text -> a
enum value = fromMaybe (error (T.unpack value)) (parseStrEnum value)

settledBase, executingBase :: Json
settledBase =
  Object
    [ ("operation_id", String "operation")
    , ("fingerprint", String (T.replicate 4 "0123456789abcdef"))
    , ("episode_id", String "episode")
    , ("turn_id", String "turn")
    , ("sequence", Int 1)
    , ("phase", String "settled")
    , ("outcome", String "completed")
    , ("accepted_appends", Int 1)
    , ("termination_code", String "turn-completed")
    , ("output_reference", String "pi-turn-operation")
    , ("continuation_reference", String "pi-continuation-operation")
    , ("cleanup", String "clean")
    , ("cleanup_code", String "cleanup-verified")
    , ("acknowledged", Bool True)
    ]
executingBase =
  replaceAll
    settledBase
    [ ("phase", String "executing")
    , ("outcome", Null)
    , ("accepted_appends", Null)
    , ("termination_code", Null)
    , ("output_reference", Null)
    , ("continuation_reference", Null)
    , ("cleanup", String "unverified")
    , ("cleanup_code", String "cleanup-uncertain")
    , ("acknowledged", Bool False)
    ]

replaceAll :: Json -> [(Text, Json)] -> Json
replaceAll value changes = case value of
  Object members -> Object [(k, fromMaybe v (lookup k changes)) | (k, v) <- members]
  other -> error (show other)

recordCases :: [(String, Json, Json)]
recordCases =
  [ ("record " <> show i <> " " <> T.unpack (render (input c)), expectedOutcome c, outcome (recordJson <$> recordFrom (input c)))
  | (i, c) <- zip [0 :: Int ..] (items (member "records" corpus))
  ]
  where
    input c = case field "mutation" c of
      Just mutated -> mutated
      Nothing ->
        let base = if text "base" c == "settled" then settledBase else executingBase
         in case member "path" c of
              Null -> base
              String key -> replaceAll base [(key, member "value" c)]
              other -> error (show other)

-- ---------------------------------------------------------------------------
-- The ledger

-- | @run(ledger, step)@.
runStep :: SqlitePiOperationLedger -> Json -> IO Json
runStep l step = attempt $ case text "op" step of
  "admit" -> do
    episode <- throwLeft (mkEpisodeId (text "episode" step))
    turn <- throwLeft (mkTurnId (text "turn" step))
    recordJson <$> ledgerAdmit l (text "id" step) (text "fingerprint" step) episode turn
  "lookup" -> maybe Null recordJson <$> ledgerLookup l (text "id" step)
  "settle" -> case items (member "settlement" step) of
    [String e, String t, String o, Int appends, String code, output, continuation] -> do
      episode <- throwLeft (mkEpisodeId e)
      turn <- throwLeft (mkTurnId t)
      settlement <- throwLeft (mkRuntimeTurnSettlement episode turn (enum o) appends code (optional output) (optional continuation))
      recordJson <$> ledgerSettle l (text "id" step) settlement
    other -> error (show other)
  "upgrade" -> case items (member "cleanup" step) of
    [String operation, String disposition, String code, Bool erased] -> do
      evidence <- throwLeft (mkRuntimeOperationCleanup operation (enum disposition) code erased)
      recordJson <$> ledgerUpgradeCleanup l (text "id" step) evidence
    other -> error (show other)
  "acknowledge" -> recordJson <$> ledgerAcknowledge l (text "id" step)
  "watermark" -> Int <$> ledgerWatermark l
  "records" -> Array . map recordJson <$> ledgerRecords l
  "recover" -> Array . map recordJson <$> ledgerRecover l
  other -> error (T.unpack other)
  where
    optional = \case
      Null -> Nothing
      String t -> Just t
      other -> error (show other)

script :: SqlitePiOperationLedger -> Text -> [Json] -> IO [(String, Json, Json)]
script l name steps =
  forM (zip [0 :: Int ..] steps) $ \(i, s) -> do
    actual <- runStep l (member "step" s)
    pure (T.unpack name <> " " <> show i <> " " <> T.unpack (render (member "step" s)), member "result" s, actual)

cell :: SqlValue -> Json
cell = \case
  SQLNull -> Null
  SQLInteger n -> Object [("int", Int (toInteger n))]
  SQLText t -> Object [("text", String t)]
  other -> Object [("other", String (T.pack (show other)))]

-- | @dump(path)@.
dump :: FilePath -> IO Json
dump path = do
  database <- openDatabase path
  let rows sql = do
        found <- queryRows database sql []
        pure (Array [Array (map cell row) | row <- found])
  master <- rows "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
  tableInfo <- rows "PRAGMA table_info(pi_operations)"
  stored <- rows "SELECT * FROM pi_operations ORDER BY sequence"
  sequenceRows <- rows "SELECT name, seq FROM sqlite_sequence"
  journal <- rows "PRAGMA journal_mode"
  closeDatabase database
  pure
    ( Object
        [ ("master", master)
        , ("table_info", tableInfo)
        , ("rows", stored)
        , ("sequence", sequenceRows)
        , ("journal_mode", case journal of Array [Array [Object [("text", mode)]]] -> mode; other -> other)
        ]
    )

-- | A fresh private directory with a private copy of the reference file.
referenceCopy :: FilePath -> String -> IO FilePath
referenceCopy root name = do
  let directory = root </> name
      path = directory </> "operations.sqlite3"
  createDirectory directory
  setFileMode directory 0o700
  copyFile referenceLedger path
  setFileMode path 0o600
  pure path

private :: FilePath -> String -> IO FilePath
private root name = do
  createDirectory (root </> name)
  setFileMode (root </> name) 0o700
  pure (root </> name </> "operations.sqlite3")

withLedger :: FilePath -> (SqlitePiOperationLedger -> IO a) -> IO a
withLedger path action = do
  l <- openSqlitePiOperationLedger path
  result <- action l
  ledgerClose l
  pure result

ledgerSection :: Json
ledgerSection = member "ledger" corpus

parameter :: Json -> SqlValue
parameter = \case
  Null -> SQLNull
  Object [("text", String t)] -> SQLText t
  Object [("int", Int n)] -> SQLInteger (fromInteger n)
  Object [("blob", String b)] -> SQLBlob (unb64 b)
  other -> error (show other)

mutationCases :: FilePath -> IO [(String, Json, Json)]
mutationCases root =
  fmap concat . forM (zip [0 :: Int ..] (items (member "mutations" ledgerSection))) $ \(i, c) -> do
    path <- referenceCopy root ("mutation-" <> show i)
    database <- openDatabase path
    runSql database (text "sql" c) (map parameter (items (member "parameters" c)))
    closeDatabase database
    withLedger path $ \l -> do
      looked <- runStep l (Object [("op", String "lookup"), ("id", String "op-a")])
      listed <- runStep l (Object [("op", String "records")])
      let label = "mutation " <> show i <> " " <> T.unpack (text "sql" c)
      pure [(label <> " lookup", member "lookup" c, looked), (label <> " records", member "records" c, listed)]

spec :: Spec
spec = describe "differential/pi_corpus.json" $ do
  it "the protocol validators agree with the reference on every accepted and refused input" $
    noMismatches validationCases
  it "start frames encode to the reference's exact wire bytes" $
    withTemp (startCases >=> noMismatches)
  it "tool_result, abort and arbitrary frames encode to the same bytes or the same refusal" $
    noMismatches frameCases
  it "durable work fingerprints agree with pi_durable_work_fingerprint" $
    noMismatches fingerprintCases
  it "PiOperationRecord construction agrees on the settled and executing bases and their mutations" $
    noMismatches recordCases
  it "the scripted ledger session returns the same records and refusals and writes the same database" $
    withTemp $ \root -> do
      path <- private root "ledger"
      results <- withLedger path (\l -> script l "script" (items (member "script" ledgerSection)))
      noMismatches results
      written' <- dump path
      noMismatches [("dump", member "dump" ledgerSection, written')]
      recovered <- withLedger path (\l -> script l "recover" (items (member "recover_script" ledgerSection)))
      noMismatches recovered
      afterwards <- dump path
      noMismatches [("recovered dump", member "recovered_dump" ledgerSection, afterwards)]
  it "the reference-written ledger cross-opens, recovers and projects identically" $
    withTemp $ \root -> do
      path <- referenceCopy root "reference"
      opened <- dump path
      noMismatches [("reference dump", member "dump" ledgerSection, opened)]
      recovered <- withLedger path (\l -> script l "recover" (items (member "recover_script" ledgerSection)))
      noMismatches recovered
      afterwards <- dump path
      noMismatches [("recovered dump", member "recovered_dump" ledgerSection, afterwards)]
  it "raw row mutations of the reference-written ledger are refused or projected identically" $
    withTemp (mutationCases >=> noMismatches)
