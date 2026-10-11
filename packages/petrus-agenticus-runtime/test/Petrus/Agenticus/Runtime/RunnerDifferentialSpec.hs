-- | Replays @differential/runner_corpus.json@, which @runner_corpus.py@
-- generates from the reference.
--
-- * Each scripted run must write the reference's @thread.json@ bytes after
--   @create@ and after every @advance@, the same @history.jsonl@ bytes, the
--   same refusal, and the same Workspace and Binding call logs.
-- * Each projection case (a committed @thread.json@ value, or a mutation of
--   one) must decode to the same compact sorted bytes or the same
--   @{class, message}@ refusal.
module Petrus.Agenticus.Runtime.RunnerDifferentialSpec (spec) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ActivityError (..), ActivityExecutionContext (..), ActivityFailureFields (..), ActivityInvocation (..), activityFailure)
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Catalog.Descriptor (capabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (capabilityScopedHands, parseToolMethod)
import Petrus.Agenticus.Hands.Grants (GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Program.AgentNet
import Petrus.Agenticus.Runtime.AgentNetRunner
import Petrus.Agenticus.Runtime.AgentNetRunnerSpec (scriptedBinding, workspace)
import Petrus.Agenticus.Runtime.Profiles (TerritoryProfile (..), agentAsNetA5Local, territoryIdentity)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkThreadId)
import Petrus.Agenticus.Thread.Lifecycle (newThread)
import Petrus.Engine qualified as Engine
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

loadCorpus :: IO Json
loadCorpus = do
  bytes <- B.readFile "differential/runner_corpus.json"
  either (fail . ("runner_corpus.json: " <>)) pure (J.parseJson J.pythonLoads bytes)

member :: Text -> Json -> Json
member key = \case
  Object members -> fromMaybe (error ("missing " <> T.unpack key)) (lookup key members)
  _ -> error ("not an object at " <> T.unpack key)

text :: Text -> Json -> Text
text key value = case member key value of
  String t -> t
  other -> error ("not text at " <> T.unpack key <> ": " <> show other)

int :: Text -> Json -> Integer
int key value = case member key value of
  Int n -> n
  other -> error ("not an int at " <> T.unpack key <> ": " <> show other)

items :: Json -> [Json]
items = \case
  Array xs -> xs
  other -> error ("not an array: " <> show other)

texts :: Json -> [Text]
texts = map (\case String t -> t; other -> error (show other)) . items

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- | @json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True)@.
dumpsSorted :: Json -> Text
dumpsSorted value =
  ok (J.dumpsText J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True, J.allowNan = False} value)

-- ---------------------------------------------------------------------------
-- Scripted runs

-- | The corpus's scripted model: one plan per phase, or a provider failure.
scriptedModel :: Json -> IO (ActivityInvocation -> ActivityExecutionContext -> IO Json)
scriptedModel run' = do
  remaining <- newIORef (items (member "plans" run'))
  let failing = member "failing" run' == Bool True
  pure $ \invocation ctx ->
    if failing
      then -- The reference raises @RuntimeError("provider-failed")@.
        throwIO . ActivityError . ok $
          activityFailure
            ActivityFailureFields
              { failureError = "provider-failed"
              , failureKind = "RuntimeError"
              , failureDetails = Null
              , failureRetryable = True
              , failureRetryAfter = Nothing
              }
      else do
        state' <- either throwIO pure (loopStateFromData invocation.input)
        void (ctx.heartbeat (Just (Object [("phase", String "model")])))
        plan <-
          atomicModifyIORef' remaining $ \case
            x : xs -> (xs, x)
            [] -> ([], error "StopIteration")
        stop <- either throwIO pure (parseStopReason (member "stop" plan))
        let proposals = [ok (mkProposal (text "id" p) (text "name" p) (member "arguments" p)) | p <- items (member "proposals" plan)]
            suffix = T.pack (show state'.phase)
        either throwIO (pure . modelSettlementToData) $
          mkModelSettlement state' stop (T.replicate 64 "a") ("output-" <> suffix) ("continuation-" <> suffix) proposals

-- | The refusal an exception stands for, as the reference names it.
refusal :: SomeException -> (Text, Text)
refusal e
  | Just (a :: AgenticusError) <- fromException e = (errorClassName a.errorClass, a.errorMessage)
  | Just (Engine.EngineRuntimeError t) <- fromException e = ("RuntimeError", t)
  | Just (Engine.EngineValueError t) <- fromException e = ("ValueError", t)
  | Just (Engine.EngineTypeError t) <- fromException e = ("TypeError", t)
  | otherwise = ("?", T.pack (show e))

replayRun :: Json -> IO ()
replayRun run' = withSystemTempDirectory "runner-corpus" $ \tmp -> do
  (binding, events) <- scriptedBinding
  (adapter, calls) <- workspace
  let snapshot =
        ok $
          mkResolutionSnapshot
            1
            [agentAsNetA5Local, capabilityScopedHands, capabilityDescriptor (territoryIdentity Local) [] []]
      methods = mapMaybe parseToolMethod (texts (member "methods" run'))
  current <-
    newEpisodeAttachment (ok (mkEpisodeId "episode-1")) snapshot binding "attachment-1" 100 episodeOptions {clock = pure 1}
  void $
    openGrant
      (grants current)
      (grantSpec methods 90 (int "max_calls" run')) {specWritablePaths = ["out.txt"], specAllowedArgv = [["printf", "ok"]]}
  let initial =
        ok $
          mkLoopState
            "episode-1"
            "turn-1"
            1
            (int "phase_limit" run')
            0
            (int "tool_limit" run')
            Nothing
            Nothing
            1
            (texts (member "capabilities" run'))
            []
  model' <- scriptedModel run'
  runner <- createRunner tmp "agent-net-1" (ok (newThread (ok (mkThreadId "thread-1")) Nothing)) initial current model' adapter
  let snapshotThread = TE.decodeUtf8 <$> B.readFile (tmp </> "thread.json")
  first <- snapshotThread
  steps <- newIORef [first]
  let loop :: Int -> IO (Maybe (Text, Text))
      loop 0 = pure Nothing
      loop n = do
        settled' <- runnerSettled runner
        if settled'
          then pure Nothing
          else
            try (advance runner) >>= \case
              Left e -> do
                s <- snapshotThread
                modifyIORef' steps (<> [s])
                pure (Just (refusal e))
              Right _ -> do
                s <- snapshotThread
                modifyIORef' steps (<> [s])
                loop (n - 1)
  failure <- loop 64
  history <- TE.decodeUtf8 <$> B.readFile (tmp </> "history.jsonl")
  closeRunner runner
  written <- readIORef steps
  let expectedSteps = texts (member "steps" run')
  length written `shouldBe` length expectedSteps
  forM_ (zip3 [0 :: Int ..] expectedSteps written) $ \(i, expected, actual) ->
    (i, actual) `shouldBe` (i, expected)
  let expectedFailure = case member "error" run' of
        Null -> Nothing
        e -> Just (text "class" e, text "message" e)
  failure `shouldBe` expectedFailure
  history `shouldBe` text "history" run'
  readIORef calls `shouldReturn` texts (member "workspace_calls" run')
  readIORef events `shouldReturn` texts (member "binding_events" run')

-- ---------------------------------------------------------------------------
-- Projection mutations

adjust :: Json -> (Json -> Json) -> Json -> Json
adjust key f = \case
  Object members | String k <- key -> Object [(k', if k' == k then f v else v) | (k', v) <- members]
  Array xs | Int i <- key -> Array [if j == i then f v else v | (j, v) <- zip [0 ..] xs]
  other -> error ("cannot step into " <> show other <> " with " <> show key)

replaceAt :: [Json] -> Json -> Json -> Json
replaceAt [] new _ = new
replaceAt (k : ks) new value = adjust k (replaceAt ks new) value

removeAt :: [Json] -> Json -> Json
removeAt [String k] (Object members) = Object [(k', v) | (k', v) <- members, k' /= k]
removeAt (k : ks@(_ : _)) value = adjust k (removeAt ks) value
removeAt path value = error ("cannot remove " <> show path <> " from " <> show value)

extraAt :: [Json] -> Json -> Json
extraAt [] (Object members) = Object (members <> [("extra", Int 1)])
extraAt (k : ks) value = adjust k (extraAt ks) value
extraAt path value = error ("cannot extend " <> show path <> " in " <> show value)

checkProjection :: [Json] -> Json -> Maybe String
checkProjection runs entry =
  let run' = runs !! fromInteger (int "run" entry)
      base = ok (J.parseJson J.pythonLoads (TE.encodeUtf8 (texts (member "steps" run') !! fromInteger (int "step" entry))))
      path = items (member "path" entry)
      input = case text "op" entry of
        "none" -> base
        "remove" -> removeAt path base
        "extra" -> extraAt path base
        "replace" -> replaceAt path (member "value" entry) base
        other -> error ("unknown op " <> T.unpack other)
      expected = case entry of
        Object members | Just (String bytes) <- lookup "data" members -> Right bytes
        _ -> Left (text "class" entry, text "message" entry)
      actual = either (\e -> Left (errorClassName e.errorClass, e.errorMessage)) (Right . dumpsSorted . projectionToData) (projectionFromData input)
      label = show (int "run" entry, int "step" entry, path, text "op" entry, member "value" entry)
   in if actual == expected then Nothing else Just (label <> ": expected " <> show expected <> ", got " <> show actual)

spec :: Spec
spec = describe "differential/runner_corpus.json" $ do
  corpus <- runIO loadCorpus
  let runs = items (member "runs" corpus)
  describe "scripted runs write the reference's thread.json and history.jsonl bytes" $
    forM_ runs $ \run' ->
      it (T.unpack (text "name" run')) (replayRun run')
  it "AgentNetThreadProjection.from_data agrees with the reference on every committed and mutated value" $ do
    let cases = items (member "projections" corpus)
        failures = mapMaybe (checkProjection runs) cases
    length cases `shouldSatisfy` (> 6000)
    take 10 failures `shouldBe` []
