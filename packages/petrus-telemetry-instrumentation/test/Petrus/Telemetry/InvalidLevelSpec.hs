-- | An invalid @IMPETUS_TELEMETRY_LEVEL@ refuses the process before it
-- writes anything. The reference validates the variable when
-- @petrus.telemetry@ is imported, so a program that loads the Instance or a
-- History store aborts before any Petrus code runs. The level is read once
-- per process, so the evidence runs in a child: this suite's own executable,
-- re-entered through 'probeVariable' with the variable set.
module Petrus.Telemetry.InvalidLevelSpec
  ( probeVariable
  , probe
  , spec
  ) where

import Control.Exception (displayException, try)
import Data.ByteString qualified as BS
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (withScratch)
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet (markingFromList)
import Petrus.Telemetry (TelemetryError, levelEnvVar)
import Petrus.Telemetry.Scenarios (forkNet, p, x)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (env, proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | Set to a scratch directory, it turns the suite's executable into the
-- probe.
probeVariable :: String
probeVariable = "PETRUS_TELEMETRY_LEVEL_PROBE"

-- | Construct an Instance over a JSONL History in @dir@, then one over an
-- in-memory History, and report what each did and how many records the
-- in-memory History holds afterwards.
probe :: FilePath -> IO ()
probe dir = do
  let config = defaultInstanceConfig {initialMarking = markingFromList [(p "a", [x])]}
  overJsonl <- try $ do
    store <- openJsonlHistoryStore (dir </> "history.jsonl")
    newInstance forkNet config {historyStore = Just store}
  report "jsonl" overJsonl
  memory <- inMemoryHistoryStore
  overMemory <- try (newInstance forkNet config {historyStore = Just memory})
  report "memory" overMemory
  held <- length <$> Store.records memory
  putStrLn ("memory records: " <> show held)
  where
    report :: String -> Either TelemetryError (Either InstanceError Instance) -> IO ()
    report label = \case
      Left refusal -> putStrLn (label <> ": " <> displayException refusal)
      Right (Left e) -> putStrLn (label <> ": instance error " <> show e)
      Right (Right _) -> putStrLn (label <> ": constructed")

-- | Run the probe in a child process with the level set to @value@.
probed :: String -> FilePath -> IO (ExitCode, String, String)
probed value dir = do
  self <- getExecutablePath
  inherited <- getEnvironment
  let child = filter ((`notElem` [levelEnvVar, probeVariable]) . fst) inherited
  readCreateProcessWithExitCode
    (proc self ["+RTS", "-M512M", "-RTS"])
      { env = Just (child <> [(levelEnvVar, value), (probeVariable, dir)])
      }
    ""

spec :: Spec
spec = describe "IMPETUS_TELEMETRY_LEVEL refused at construction" $ do
  it "a valid level constructs and writes (the control)" $ withScratch $ \dir -> do
    (code, out, err) <- probed "facts" dir
    (code, err) `shouldBe` (ExitSuccess, "")
    lines out `shouldBe` ["jsonl: constructed", "memory: constructed", "memory records: 2"]
    written <- BS.readFile (dir </> "history.jsonl")
    BS.length written `shouldSatisfy` (> 0)

  it "an invalid level refuses before any durable write" $ withScratch $ \dir -> do
    (code, out, err) <- probed "bogus" dir
    (code, err) `shouldBe` (ExitSuccess, "")
    -- The reference's ValueError text.
    let refused = "unknown telemetry level 'bogus': one of off, facts, profile, debug"
    lines out `shouldBe` ["jsonl: " <> refused, "memory: " <> refused, "memory records: 0"]
    doesFileExist (dir </> "history.jsonl") `shouldReturn` False
