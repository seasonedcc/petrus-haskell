-- | @hamsterdan-e2e-host <host arguments>@: the Haskell host for a tier C
-- run, the twin of @python/e2e_host.py@. It is the production
-- @hamsterdan-host@ command line ('runCli' over 'productionEnvironment'),
-- configured the same way (docs/hamsterdan.md §1.8), with two optional
-- seams the command line already takes through 'CliEnvironment':
--
-- [@HAMSTERDAN_E2E_AGENTS=TAPE@] every agent call is answered from the
--   @agents.jsonl@ of another run's tape, carried to this repository
--   ("Hamsterdan.E2E.Agents"): tier C's deterministic agent. The real Pi
--   composition is still built and owned (and released), but not called.
--
-- [@HAMSTERDAN_E2E_GITHUB_PORT=PORT@] every GitHub request goes to
--   @http://127.0.0.1:PORT@. For testing against fakes only.
--
-- Recording a tape is the reference's job (@HAMSTERDAN_E2E_RECORD@ in
-- @e2e_host.py@); this host only replays.
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Hamsterdan.E2E.Agents (CarriedRunner (..), carriedRunner)
import Hamsterdan.E2E.Tape (readTape)
import Hamsterdan.GitHub.Client (ClientOptions (..))
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.Host.Cli (CliEnvironment (..), productionEnvironment, runCli)
import System.Environment (getArgs, getEnvironment, unsetEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

seams :: [String]
seams = ["HAMSTERDAN_E2E_RECORD", "HAMSTERDAN_E2E_AGENTS", "HAMSTERDAN_E2E_GITHUB_PORT"]

main :: IO ()
main = do
  full <- Map.fromList <$> getEnvironment
  case Map.lookup "HAMSTERDAN_E2E_RECORD" full of
    Just _ -> hPutStrLn stderr "HAMSTERDAN_E2E_RECORD: tapes are recorded from the reference host (e2e_host.py)" >> exitWith (ExitFailure 2)
    Nothing -> pure ()
  mapM_ unsetEnv seams
  arguments <- map T.pack <$> getArgs
  let environment = foldr Map.delete full seams
      production = productionEnvironment environment
      withAgents = case Map.lookup "HAMSTERDAN_E2E_AGENTS" full of
        Nothing -> production
        Just path ->
          production
            { composeAgent = \owned root -> do
                (_, custody) <- production.composeAgent owned root
                carried <- carriedRunner =<< readTape path
                pure (carried.runner, custody)
            }
      configured = case Map.lookup "HAMSTERDAN_E2E_GITHUB_PORT" full >>= readMaybe of
        Nothing -> withAgents
        Just port ->
          withAgents
            { clientOptions = do
                exchange <- newPlainExchangeAt "127.0.0.1" port
                pure ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
            }
  runCli configured arguments >>= exitWith
