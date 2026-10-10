{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The process runner against the reference: the Haskell child writes the
-- exact progress bytes the Python child writes for the same toy scenarios
-- (@scripts/process_vectors.py@), the fold of every crafted progress file
-- gives the reference's result bytes, and the ported
-- @tests/dst/test_process_runner.py@ proofs run real child processes (this
-- test executable re-entered through 'processChildHook').
module Spec.Runner (spec, entrypoints) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Decode (LocPart (..), SchemaError (..))
import Petrus.Testing.Dst.Runner
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support
import System.Directory (getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Signals (Handler (Ignore), installHandler, sigTERM)
import System.Posix.Temp (mkdtemp)
import Test.Hspec
import Toy

-- ---------------------------------------------------------------------------
-- The toy entrypoints of scripts/process_vectors.py and
-- tests/dst/process_world.py

-- | Every entrypoint the test executable serves as a runner child.
entrypoints :: Entrypoints
entrypoints =
  Map.fromList
    [ ("process_vectors:queue_story", queueStory)
    , ("process_vectors:resource_story", resourceStory)
    , ("process_vectors:checker_failure_story", checkerFailureStory)
    , ("process_vectors:failing_story", failingStory)
    , ("process_vectors:wrong_identity_story", wrongIdentityStory)
    , ("process_vectors:two_worlds_story", twoWorldsStory)
    , ("process_vectors:tiny_progress_story", tinyProgressStory)
    , ("tests.dst.process_world:hang_during_command", hangDuringCommand)
    ]

storyBudget :: SomeBudget
storyBudget = budget 8 2 1 5 1 2

storyResourceBudget :: SomeBudget
storyResourceBudget = budgetV4 (budget 8 2 1 5 1 4) 2

scenarioOf :: Json -> IO Text
scenarioOf payload = case lookupMember "scenario_id" payload of
  Just (String s) -> pure s
  _ -> throwIO (userError "the payload names no scenario_id")

gaveUp :: String -> IO a
gaveUp = throwIO . userError

queueStory :: Entrypoint
queueStory session payload = do
  sid <- scenarioOf payload
  q <- newQueue
  sessionWorld session (config (queueProfile q) storyBudget [rejectBadValueChecker] Nothing) $ do
    t <- World.timeline
    _ <- World.step
    _ <- World.step
    _ <- Timeline.observe t "queue.state"
    Timeline.finish t Quiescent
    World.artifact sid

valuesOf :: Observation -> [Json]
valuesOf o = case lookupMember "values" o.value of
  Just (Array vs) -> vs
  _ -> []

resourceStory :: Entrypoint
resourceStory session payload = do
  sid <- scenarioOf payload
  q <- newQueue
  sessionWorld session (config (resourceQueueProfile q) storyResourceBudget [] (Just 7)) $ do
    t <- World.timeline
    _ <- Timeline.runUntil t "queue.state" (\o -> length (valuesOf o) == 2)
    Timeline.crash t "cut"
    _ <- World.restart
    t' <- World.timeline
    Timeline.finish t' Converged
    World.artifact sid

checkerFailureStory :: Entrypoint
checkerFailureStory session payload = do
  sid <- scenarioOf payload
  q <- newQueue
  sessionWorld session (config (queueProfile q) storyBudget [rejectBadValueChecker] Nothing) $ do
    t <- World.timeline
    _ <- World.step
    _ <- World.step
    _ <- World.tryWorld (Timeline.command t "queue.record" (Object [("id", String "bad")]))
    World.artifact sid

failingStory :: Entrypoint
failingStory session _ = do
  q <- newQueue
  sessionWorld session (config (queueProfile q) storyBudget [] Nothing) (void World.step)
  gaveUp "the scenario gave up"

wrongIdentityStory :: Entrypoint
wrongIdentityStory = finishedStory (Just "some-other-scenario")

twoWorldsStory :: Entrypoint
twoWorldsStory session _ = do
  q <- newQueue
  sessionWorld session (config (queueProfile q) storyBudget [] Nothing) (pure ())
  sessionWorld session (config (queueProfile q) storyBudget [] Nothing) (pure ())
  gaveUp "unreachable"

tinyProgressStory :: Entrypoint
tinyProgressStory = finishedStory Nothing

-- | Two steps, a quiescent finish, and the artifact under the payload's
-- scenario id unless another is given.
finishedStory :: Maybe Text -> Entrypoint
finishedStory fixed session payload = do
  sid <- maybe (scenarioOf payload) pure fixed
  q <- newQueue
  sessionWorld session (config (queueProfile q) storyBudget [] Nothing) $ do
    _ <- World.step
    _ <- World.step
    t <- World.timeline
    Timeline.finish t Quiescent
    World.artifact sid

-- | @HangProfile@ of @tests/dst/process_world.py@: its only command never
-- returns and ignores @SIGTERM@, so only the watchdog's @SIGKILL@ ends it.
hangProfile :: Profile IO ()
hangProfile =
  Profile
    { identity =
        Identity
          { name = "petrus.testing.process-watchdog-hang"
          , version = 1
          , digest = digestOf (Object [("commands", Array [String "runtime.hang"]), ("observations", Array [String "state"])])
          }
    , validate = \c ->
        if c.name /= "runtime.hang" || c.payload /= Null
          then refuse "unsupported watchdog proof command"
          else pure c
    , validateFault = \_ -> refuse "the watchdog proof profile has no faults"
    , create = pure GenerationStart {generation = (), scheduled = []}
    , load = raise "ValueError" "the watchdog proof profile cannot load"
    , apply = \() _ -> do
        liftIO $ do
          _ <- installHandler sigTERM Ignore Nothing
          threadDelay 60000000
        pure ApplyResult {disposition = Applied, value = Null, scheduled = []}
    , observe = \() request ->
        if request.name /= "state" || request.payload /= Null
          then raise "ValueError" "unsupported watchdog proof observation"
          else pure (Object [("state", String "waiting")])
    , dropGeneration = \() -> pure ()
    , closeGeneration = \() -> pure ()
    , resourceUsage = Nothing
    }
  where
    refuse :: Text -> Door IO a
    refuse message = throwError (ProfileError "ValueError" message)

hangDuringCommand :: Entrypoint
hangDuringCommand session payload = do
  when (payload /= Null) (gaveUp "watchdog hang scenario payload must be null")
  sessionWorld session (config hangProfile (SomeBudget Budget {actions = 8, queuedCommands = 1, timerAdvances = 0, logicalInstant = 0, reloads = 0, predicatePolls = 1, artifactBytes = 64000}) [] Nothing) $ do
    t <- World.timeline
    void (Timeline.command t "runtime.hang" Null)
  gaveUp "the deliberately hanging profile call returned"

-- ---------------------------------------------------------------------------
-- Vectors

vectors :: IO Json
vectors = readJson (dataFile "process-vectors.json")

specOf :: Json -> ProcessRunSpec
specOf vector = case loadStrictJson (textBytes (memberText "spec" vector)) of
  Left message -> error (T.unpack message)
  Right value -> either (error . show) id (pProcessRunSpec [] value)

resultText :: ProcessRunResult -> Text
resultText = TE.decodeUtf8 . encodeProcessRunResult

withScratch :: (FilePath -> IO a) -> IO a
withScratch body = do
  temporary <- getTemporaryDirectory
  bracket (mkdtemp (temporary </> "petrus-dst-spec-")) removeDirectoryRecursive body

terminationOf :: Text -> Termination
terminationOf = \case
  "killed" -> Killed
  "terminated" -> Terminated
  _ -> Exited

spec :: Spec
spec = describe "process runner" $ do
  it "writes the reference child's exact progress bytes and exit status (in-process)" $ do
    children <- memberList "children" <$> vectors
    length children `shouldBe` 8
    forM_ children $ \child -> withScratch $ \root -> do
      let specPath = root </> "spec.json"
          progressPath = root </> "progress.jsonl"
          runSpec = specOf child
      BS.writeFile specPath (textBytes (memberText "spec" child))
      status <- processChildMain entrypoints specPath progressPath
      progress <- BS.readFile progressPath
      (runSpec.scenarioId, TE.decodeUtf8 progress) `shouldBe` (runSpec.scenarioId, memberText "progress" child)
      Int (toInteger status) `shouldBeJson` member "status" child
      resultText (processResult runSpec status Exited False (Just progress)) `shouldBe` memberText "result" child

  it "re-encodes every reference progress frame byte for byte" $ do
    children <- memberList "children" <$> vectors
    forM_ children $ \child ->
      forM_ (BC.lines (textBytes (memberText "progress" child))) $ \line ->
        case parseFrame line of
          Left e -> expectationFailure (show e <> " for " <> BC.unpack line)
          Right frame -> encodeFrame frame `shouldBe` Right (line <> "\n")

  it "folds every crafted progress file to the reference's result" $ do
    folds <- memberList "folds" <$> vectors
    length folds `shouldBe` 36
    forM_ folds $ \fold -> do
      let progress = case member "progress" fold of
            String s -> Just (textBytes s)
            _ -> Nothing
          returncode = case member "returncode" fold of
            Int n -> fromInteger n
            other -> error (show other)
          timedOut = member "timed_out" fold == Bool True
          result = processResult (specOf fold) returncode (terminationOf (memberText "termination" fold)) timedOut progress
      (memberText "name" fold, resultText result) `shouldBe` (memberText "name" fold, memberText "result" fold)

  it "runs each toy scenario in a child process with the reference's result" $ do
    command <- selfChildCommand
    children <- memberList "children" <$> vectors
    forM_ children $ \child -> do
      outcome <- runProcessScenario command (specOf child)
      case outcome of
        Left failure -> expectationFailure (show failure)
        Right result -> resultText result `shouldBe` memberText "result" child

  it "replays a child's complete World from a fresh registry in the parent" $ do
    command <- selfChildCommand
    children <- memberList "children" <$> vectors
    child <- case [c | c <- children, memberText "scenario_id" c == "resource-story"] of
      c : _ -> pure c
      [] -> fail "no resource-story vector"
    outcome <- runProcessScenario command (specOf child)
    result <- either (fail . show) pure outcome
    result.outcome `shouldBe` Completed
    result.termination `shouldBe` Exited
    result.failure `shouldBe` Nothing
    result.unfinishedAttempt `shouldBe` Nothing
    result.prefix.disposition `shouldBe` Just DConverged
    fmap (\e -> e.kind) (lastResource result.prefix) `shouldBe` Just JResource
    artifact <- maybe (fail "no artifact") pure result.artifact
    q <- newQueue
    replayed <- replay (registryOf [SomeProfile (resourceQueueProfile q)] []) artifact
    case replayJson replayed of
      Object [("result", String encoded)] -> do
        value <- either (fail . T.unpack) pure (loadStrictJson (textBytes encoded))
        member "outcome" value `shouldBeJson` String "pass"
        member "disposition" value `shouldBeJson` String "converged"
      other -> expectationFailure (show other)

  it "refuses a spec over its input budget before launch" $ do
    refusal <- member "refusal" <$> vectors
    command <- selfChildCommand
    outcome <- runProcessScenario command (specOf refusal)
    pyErrorOf outcome `shouldBeJson` Object [("message", member "message" refusal), ("type", member "type" refusal)]

  it "refuses a spec payload nested past pydantic's recursion guard" $ do
    -- The reference's ProcessRunSpec.model_validate admits a leaf inside
    -- 254 lists and refuses one inside 255, at the leaf.
    let runSpec depth =
          Object
            [ ("scenario_id", String "s")
            , ("entrypoint", String "a.b:c")
            , ("payload", iterate (\v -> Array [v]) (Int 0) !! depth)
            , ("budget", Object [("wall_clock_ms", Int 1000), ("termination_grace_ms", Int 100), ("input_bytes", Int 10), ("progress_bytes", Int 10)])
            ]
    either (Left . show) (const (Right ())) (pProcessRunSpec [] (runSpec 254)) `shouldBe` Right ()
    case pProcessRunSpec [] (runSpec 255) of
      Left e -> do
        e.errorType `shouldBe` "recursion_loop"
        e.loc `shouldBe` LKey "payload" : concat (replicate 255 [LKey "list", LIndex 0])
      Right _ -> expectationFailure "admitted a payload nested 255 lists deep"

  it "terminates and reaps a hung profile, keeping its acknowledged prefix" $ do
    command <- selfChildCommand
    let hang =
          ProcessRunSpec
            { scenarioId = "process-watchdog-hang-v1"
            , entrypoint = "tests.dst.process_world:hang_during_command"
            , payload = Null
            , budget = ProcessBudget {wallClockMs = 2000, terminationGraceMs = 100, inputBytes = 64000, progressBytes = 4194304}
            }
    outcome <- runProcessScenario command hang
    result <- either (fail . show) pure outcome
    result.outcome `shouldBe` HarnessFailure
    result.termination `shouldBe` Killed
    result.returncode `shouldNotBe` 0
    result.failure `shouldBe` Just (WallClockTimeout 2000)
    result.artifact `shouldBe` Nothing
    case result.unfinishedAttempt of
      Just (WorldAttempt (ASubmit a)) -> a.command.name `shouldBe` "runtime.hang"
      other -> expectationFailure ("not a submit attempt: " <> show other)
    result.prefix.operations `shouldBe` []
    map (\e -> e.kind) result.prefix.journal `shouldBe` [JCreated]
    result.prefix.disposition `shouldBe` Nothing
