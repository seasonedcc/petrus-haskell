-- | Replays @differential/hosts_corpus.json@, which @hosts_corpus.py@
-- generates from the reference: the Codex, Claude and Amp hosts' protocol
-- validators, wire encoders and stream admission must return the same value
-- or the same @{class, message}@ refusal, case by case.
module Petrus.Agenticus.Runtime.HostsDifferentialSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (digitToInt, intToDigit)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Runtime.Amp.Internal
import Petrus.Agenticus.Runtime.Claude
import Petrus.Agenticus.Runtime.Codex
import Petrus.Agenticus.Runtime.CodexGondolin (jsonBytes, parseTerminal)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (StrEnum (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Json.Python qualified as Python
import Test.Hspec

-- | The corpus, read once before the sections run.
loadCorpus :: IO Json
loadCorpus = do
  bytes <- B.readFile "differential/hosts_corpus.json"
  either (fail . ("hosts_corpus.json: " <>) . show) pure (Python.loadsBytes bytes)

field :: Text -> Json -> Maybe Json
field key = \case
  Object members -> lookup key members
  _ -> Nothing

member :: Text -> Json -> Json
member key value = fromMaybe (error ("missing " <> T.unpack key)) (field key value)

items :: Json -> [Json]
items = \case
  Array xs -> xs
  other -> error ("not an array: " <> show other)

str :: Json -> Text
str = \case
  String t -> t
  other -> error ("not text: " <> show other)

optionalStr :: Json -> Maybe Text
optionalStr = \case
  Null -> Nothing
  other -> Just (str other)

int :: Json -> Int
int = \case
  Int n -> fromInteger n
  other -> error ("not an int: " <> show other)

bool :: Json -> Bool
bool = \case
  Bool b -> b
  other -> error ("not a bool: " <> show other)

unhex :: Json -> ByteString
unhex = B.pack . pairs . T.unpack . str
  where
    pairs (a : b : rest) = fromIntegral ((digitToInt a `shiftL` 4) .|. digitToInt b) : pairs rest
    pairs _ = []

hexText :: ByteString -> Json
hexText = String . T.pack . concatMap (\w -> [intToDigit (fromIntegral (w `shiftR` 4)), intToDigit (fromIntegral (w .&. 15))]) . B.unpack

-- | Compact JSON with every object's keys sorted: member order is checked
-- through the hex-encoded wire bytes where it matters.
render :: Json -> Text
render = either (error . show) id . J.dumpsText J.compact {J.allowNan = True} . canonical
  where
    canonical = \case
      Object members -> Object (sortOn fst [(k, canonical v) | (k, v) <- members])
      Array values -> Array (map canonical values)
      other -> other

refusal :: Text -> Text -> Json
refusal cls message = Object [("class", String cls), ("message", String message)]

outcome :: Either AgenticusError Json -> Json
outcome = \case
  Right v -> Object [("ok", v)]
  Left e -> Object [("error", refusal (errorClassName e.errorClass) e.errorMessage)]

-- | A refusal raised as @ValueError(message)@.
valueErr :: Either Text Json -> Json
valueErr = \case
  Right v -> Object [("ok", v)]
  Left message -> Object [("error", refusal "ValueError" message)]

expected :: Json -> Json
expected c = case (field "ok" c, field "error" c) of
  (Just v, _) -> Object [("ok", v)]
  (_, Just e) -> Object [("error", e)]
  _ -> error "no outcome"

-- | Replays one section: every case's actual outcome must render to the
-- reference's bytes.
section :: Text -> Text -> (Json -> Json) -> SpecWith Json
section host name run =
  it (T.unpack (host <> "." <> name)) $ \corpus -> do
    let cases = items (member name (member host corpus))
        failures =
          [ T.unpack (render input <> "\n  expected " <> render want <> "\n  actual   " <> render got)
          | c <- cases
          , let input = member "input" c
                want = expected c
                got = run input
          , not (agrees want got)
          ]
    length cases `shouldSatisfy` (> 0)
    take 5 failures `shouldBe` []

-- | Whether the port's outcome matches the reference's. CPython's
-- @UnicodeEncodeError@ (a lone surrogate reaching @str.encode()@) is a
-- @ValueError@ subclass: the port raises it as class @ValueError@ with
-- CPython's exact message, everything else must agree verbatim.
agrees :: Json -> Json -> Bool
agrees want got = case (field "error" want, field "error" got) of
  (Just (Object e), Just (Object g))
    | lookup "class" e == Just (String "UnicodeEncodeError") ->
        lookup "class" g == Just (String "ValueError") && lookup "message" g == lookup "message" e
  _ -> render want == render got

args :: Json -> [Json]
args = items

spec :: Spec
spec = beforeAll loadCorpus . describe "hosts differential corpus" $ do
  codexSpecs
  claudeSpecs
  ampSpecs

codexSpecs :: SpecWith Json
codexSpecs = do
  section "codex" "text" $ \i -> case args i of
    [n, v, m] -> outcome (String <$> codexText (str n) (int m) (str v))
    _ -> error "text"
  section "codex" "uuid" $ outcome . fmap String . codexUuid . str
  section "codex" "rollout_path" $ \i -> case args i of
    [p, t] -> outcome (String <$> codexRolloutPath (str p) (str t))
    _ -> error "rollout_path"
  section "codex" "final_text" $ \case
    Object [("repeat", p), ("times", n)] -> outcome (String <$> finalText (T.replicate (int n) (str p)))
    Object [("times", n), ("repeat", p)] -> outcome (String <$> finalText (T.replicate (int n) (str p)))
    v -> outcome (String <$> finalText (str v))
  section "codex" "payload" $ \i -> case args i of
    [t, p, r] ->
      outcome $
        (\payload -> Object [("rollout", hexText payload.rollout), ("rollout_path", String payload.rolloutPath), ("thread_id", String payload.threadId)])
          <$> mkCodexContinuationPayloadV1 (str t) (str p) (unhex r)
    _ -> error "payload"
  section "codex" "helper" $ \i -> case args i of
    [s, c] -> outcome (fromMaybe Null <$> parseHelper (unhex s) (bool c))
    _ -> error "helper"
  section "codex" "jsonl" $ \i -> case args i of
    [r, c] ->
      outcome $
        (\candidate -> Object [("completed", Bool candidate.completed), ("text", maybe Null String candidate.text), ("thread_id", String candidate.threadId)])
          <$> parseJsonl (unhex r) (int c)
    _ -> error "jsonl"
  section "codex" "json_bytes" $ valueErr . fmap hexText . jsonBytes
  section "codex" "terminal" $ \i -> case args i of
    [f, o, e, t] ->
      valueErr $
        parseTerminal
          (unhex f)
          (optionalStr o)
          (either (error . show) id . mkEpisodeId <$> optionalStr e)
          (either (error . show) id . mkTurnId <$> optionalStr t)
    _ -> error "terminal"

claudeSpecs :: SpecWith Json
claudeSpecs = do
  section "claude" "text" $ \i -> case args i of
    [n, v, m] -> outcome (String <$> claudeText (str n) (int m) (str v))
    _ -> error "text"
  section "claude" "uuid" $ outcome . fmap String . claudeUuid . str
  section "claude" "encode_transcript" $ \i -> case args i of
    [v, e, t] -> outcome (hexText <$> encodeTranscript (int e) (int t) v)
    _ -> error "encode_transcript"
  section "claude" "decode_transcript" $ \i -> case args i of
    [v, e, t] -> outcome (Array <$> decodeTranscript (int e) (int t) (unhex v))
    _ -> error "decode_transcript"
  section "claude" "canonical_input" $ outcome . fmap hexText . canonicalInput
  section "claude" "sanitize" $ \i -> case args i of
    [v, m] -> outcome (String <$> sanitize (int m) (str v))
    _ -> error "sanitize"
  section "claude" "payload" $ \i -> case args i of
    [s, b, k, t] ->
      outcome $
        (\payload -> Object [("project_binding", String payload.projectBinding), ("project_key", String payload.projectKey), ("session_id", String payload.sessionId)])
          <$> mkClaudeContinuationPayloadV1 (str s) (str b) (str k) (unhex t)
    _ -> error "payload"

ampSpecs :: SpecWith Json
ampSpecs = do
  section "amp" "bounded_text" $ \i -> case args i of
    [n, v, m] -> outcome (String <$> ampBoundedText (str n) (int m) (str v))
    _ -> error "bounded_text"
  section "amp" "thread_id" $ outcome . fmap String . ampThreadId . str
  section "amp" "safe_final_text" $ \i -> case args i of
    [v, m] -> outcome (String <$> safeFinalText (int m) (str v))
    _ -> error "safe_final_text"
  section "amp" "payload_from_data" $ outcome . fmap ampPayloadToData . ampPayloadFromData
  section "amp" "execution_options" $ \i -> case args i of
    [p, m, v, n, c] ->
      let base = ampRuntimeConfig (str p)
          config = AmpRuntimeConfig (str p) (str m) (str v) (bool n) base.sdkVersion base.cliVersion base.maxEvents base.maxEventBytes base.maxTotalEventBytes base.maxFinalTextBytes base.cancellationGrace
       in Object [("ok", Array [Array [String k, x] | (k, x) <- executionOptions config (optionalStr c)])]
    _ -> error "execution_options"
  section "amp" "streams" $ \i ->
    let limits = map int (items (member "limits" i))
        config = case limits of
          [eventLimit, eventBytes, totalBytes, finalBytes] ->
            let base = ampRuntimeConfig "project"
             in AmpRuntimeConfig base.project base.mode base.visibility base.noArchiveAfterExecute base.sdkVersion base.cliVersion eventLimit eventBytes totalBytes finalBytes base.cancellationGrace
          _ -> error "limits"
        events = [jsonEvent members | Object members <- items (member "events" i)]
     in case admitEvents config (optionalStr (member "continuation" i)) events of
          Left code -> Object [("error", String code)]
          Right candidate ->
            Object
              [ ( "ok"
                , Object
                    [ ("accepted_appends", Int candidate.acceptedAppends)
                    , ("final_text", maybe Null String candidate.finalText)
                    , ("outcome", String (enumText candidate.outcome))
                    , ("provider_terminal", Bool candidate.providerTerminal)
                    , ("termination_code", String candidate.terminationCode)
                    , ("thread_id", maybe Null String candidate.threadId)
                    ]
                )
              ]
