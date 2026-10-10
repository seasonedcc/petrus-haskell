-- | Python clients against this server: @test/python_clients.py@ runs the
-- upstream HTTP tests' own urllib and raw-socket clients and assertions
-- (@tests/petrus/engine/test_simulation_http.py@, every parametrization of
-- the 15 tests whose assertions hold for any correct server) against a
-- Haskell server, including the upstream success test, which compares the
-- served bytes with the Python runner's @simulate@.
module PythonClientSpec (spec) where

import Data.ByteString.Char8 qualified as BC
import Data.List (isPrefixOf)
import Data.Text qualified as T
import Petrus.Simulation.Http
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "upstream Python clients against this server" $
  it "pass the upstream HTTP tests' assertions (42 cases)" $ do
    root <- repoRoot
    script <- T.pack <$> readFile (root <> "/packages/petrus-simulation/test/python_clients.py")
    withSimulationServer (simulationServerConfig "127.0.0.1" 0 origin) (fst buildScenario) $ \server -> do
      port <- serverPort (simulationHttp server)
      result <- runPython script [show port] ""
      let output = BC.unpack (resultStdout result)
          failures = filter ("FAIL" `isPrefixOf`) (lines output)
      (resultExit result, failures) `shouldBe` (ExitSuccess, [])
      filter ("DONE" `isPrefixOf`) (lines output) `shouldBe` ["DONE 42 0"]
