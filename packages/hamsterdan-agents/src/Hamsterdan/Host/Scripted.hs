-- | The real agent over Petrus's deterministic scripted Pi runtime, as the
-- cross-language state interop and the benchmarks compose it on both sides
-- (@differential/state_reference.py@'s @compose_real_agent@ and the
-- @bench.py@ twins):
--
-- * 'scriptedPiA2Hooks': @compose_owned_pi_a2@ composes
--   @compose_pi_a2_scripted_runtime@ (one 'piA2ScriptedTurn' per output
--   text) in place of the installed Pi, made ready by its own
--   @scripted_readiness()@;
-- * 'scriptedAgentRunner': the Pi native runner, selected without the READY
--   probe (which the scripted runtime refuses);
-- * 'localClone': the workspace receiver cloning a local repository for
--   every repository URL;
-- * 'deterministicRepository': a repository whose commits have the same
--   identities in every run and either language;
-- * 'clearReviewText': the final text of a clear review turn.
module Hamsterdan.Host.Scripted
  ( scriptedPiA2Hooks
  , scriptedAgentRunner
  , localClone
  , deterministicRepository
  , clearReviewText
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Agents.Pi (PiWorkspaceProvider (..), defaultPiRunnerOptions, newPiNativeRunner, piA2Runtime, piAgentRunner)
import Hamsterdan.Agents.Protocol (AgentRunner)
import Hamsterdan.Host.PiA2 (PiA2Hooks (..), defaultPiA2Hooks)
import Hamsterdan.Python.Exception (raisingDumps)
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimeHost, PiA2ScriptedReadiness (..), composePiA2ScriptedRuntime, piA2ScriptedTurn, scriptedReadiness)
import Petrus.Json (Json (..), compact, dumps)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import System.Process qualified as Process

-- | The Pi A2 hooks composing the scripted runtime with these turns.
scriptedPiA2Hooks :: [Text] -> PiA2Hooks
scriptedPiA2Hooks turns = defaultPiA2Hooks {composeRuntime = scripted}
  where
    scripted config authority = do
      host <- composePiA2ScriptedRuntime config authority (map piA2ScriptedTurn turns) getMonotonicTime
      readiness <- scriptedReadiness host
      unless readiness.ready $ throwIO (userError "the scripted Pi runtime is not ready")
      pure host

-- | @PiNativeRunner(runtime, workspaces)@ without the probe.
scriptedAgentRunner :: PiA2RuntimeHost -> PiWorkspaceProvider -> IO AgentRunner
scriptedAgentRunner host provider =
  either (throwIO . userError . T.unpack) (pure . piAgentRunner) (newPiNativeRunner (piA2Runtime host) provider defaultPiRunnerOptions)

-- | The receiver, cloning the local repository whatever URL it is given.
localClone :: FilePath -> PiWorkspaceProvider -> PiWorkspaceProvider
localClone repository (PiWorkspaceProvider open) =
  PiWorkspaceProvider (\kind _ request operation body -> open kind (T.pack repository) request operation body)

-- | The final text of a clear review: the request's repository, pull
-- request, epoch (its incarnation), head and base, no findings.
clearReviewText :: Text -> Integer -> Integer -> Text -> Text -> Text
clearReviewText repository pullRequest epoch commit base =
  TE.decodeUtf8 . raisingDumps . dumps compact $
    Object
      [ ("repository", String repository)
      , ("pull_request", Int pullRequest)
      , ("epoch", Int epoch)
      , ("head", String commit)
      , ("base", String base)
      , ("status", String "clear")
      , ("findings", Array [])
      , ("lineage", Array [])
      ]

-- | A repository with fixed identities and dates, so every run and both
-- languages see the same commits: @main@ at the base, and @feature@ two
-- commits on. Returns the base, the first and the second head.
deterministicRepository :: FilePath -> IO (Text, Text, Text)
deterministicRepository repo = do
  inherited <- getEnvironment
  let identity =
        [ ("GIT_AUTHOR_NAME", "Author")
        , ("GIT_AUTHOR_EMAIL", "author@example.test")
        , ("GIT_COMMITTER_NAME", "Author")
        , ("GIT_COMMITTER_EMAIL", "author@example.test")
        , ("GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z")
        , ("GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z")
        , ("GIT_CONFIG_NOSYSTEM", "1")
        , ("GIT_CONFIG_GLOBAL", "/dev/null")
        ]
      environment = identity <> [(k, v) | (k, v) <- inherited, k `notElem` map fst identity]
      git arguments = do
        (status, out, err) <- readCreateProcessWithExitCode (proc "git" arguments) {Process.env = Just environment} ""
        unless (status == ExitSuccess) $ throwIO (userError ("git " <> unwords arguments <> ": " <> err))
        pure (T.strip (T.pack out))
      commit message content = do
        BS.writeFile (repo </> "README.md") content
        _ <- git ["-C", repo, "add", "README.md"]
        git ["-C", repo, "commit", "-q", "-m", message]
  _ <- git ["init", "-q", "-b", "main", repo]
  _ <- commit "base" "hello\n"
  _ <- git ["-C", repo, "checkout", "-q", "-b", "feature"]
  _ <- commit "first" "hello\nworld\n"
  _ <- commit "second" "hello\nworld\nagain\n"
  (,,) <$> git ["-C", repo, "rev-parse", "main"] <*> git ["-C", repo, "rev-parse", "feature~1"] <*> git ["-C", repo, "rev-parse", "feature"]
