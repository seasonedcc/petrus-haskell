-- | Benchmarks for hamsterdan-agents; bench.py runs the same operations on
-- the same inputs (@bench/inputs.json@, made by @make_inputs.py@) in the
-- pinned Python.
--
-- > cabal bench hamsterdan-agents --benchmark-options='-j1 --csv agents.csv +RTS -M2G -RTS'
--
-- Every row is measured in wall-clock time ('WallTime'), as bench.py
-- measures it: the agent turn spends much of its time in git child
-- processes and file system calls, which tasty-bench's default CPU time
-- would not count.
--
-- * prompt: 'encodePrompt' of a review request with lenses, context,
--   evidence and prior comments;
-- * result: 'parseResult' and 'validateResult' of an eight-finding blocking
--   review;
-- * archive admission: 'validatedEntries' of a 200-file settled workspace
--   archive;
-- * sealed key: seal then open of connection state with the persistent key
--   operations (the key loaded from its file each time);
-- * route claim: 'claimRoute' of a new operation then 'settleRoutes', on one
--   long-lived store;
-- * agent turn: one scripted Pi review through the Pi native runner from a
--   fresh state directory ('composeAgentRuntimeWith': the workspace
--   receiver, then the owned Pi A2 runtime over the scripted runtime; the
--   review: clone of a local repository, review inputs, workspace archive,
--   prompt, the scripted turn, result validation, bodies and ledger; close;
--   remove the directory).
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Control.Exception (throwIO)
import Control.Monad (unless, void)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Pi (PromptKind (..), encodePrompt, parseResult)
import Hamsterdan.Agents.Protocol (AgentRequest (..), AgentResult (..), AgentRunner (..), Invocation (..), ReviewRequest (..), ReviewResult (..))
import Hamsterdan.Agents.Validate (ResultKind (..), validateResult)
import Hamsterdan.Contracts.Codec (validate)
import Hamsterdan.Host.AgentRuntime (composeAgentRuntimeWith)
import Hamsterdan.Host.Agenticus (activateRoutes, claimRoute, composeAgent, openAgentRouteStore, settleRoutes)
import Hamsterdan.Host.PiA2 (OwnedPiA2 (..), PiA2InstallationConfig (..), composeOwnedPiA2With, persistentKeyOperations)
import Hamsterdan.Host.PiWorkspace (ArchiveEntry (..), gitPiWorkspaceProvider, newGitPiWorkspaceProvider, validatedEntries)
import Hamsterdan.Host.Scripted (clearReviewText, deterministicRepository, localClone, scriptedAgentRunner, scriptedPiA2Hooks)
import Petrus.Agenticus.Connection.Key (KeyOperations (..), mkKeyContext)
import Petrus.Agenticus.Error (throwLeft)
import Petrus.Agenticus.Runtime.PiA2Host (closeHost)
import Petrus.Json (Json (..), parseJson, pythonLoads)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive, removePathForcibly)
import System.FilePath ((</>))
import Test.Tasty (localOption)
import Test.Tasty.Bench

url :: Text
url = "https://github.com/owner/one.git"

data Inputs = Inputs
  { request :: ReviewRequest
  , result :: Text
  , archive :: ByteString
  }

readInputs :: FilePath -> IO Inputs
readInputs file = do
  bytes <- BS.readFile file
  case parseJson pythonLoads bytes of
    Right (Object members)
      | Just requestJson <- lookup "request" members
      , Right request <- validate requestJson
      , Just (String result) <- lookup "result" members
      , Just (String encoded) <- lookup "archive" members
      , Right archive <- B64.decode (TE.encodeUtf8 encoded) ->
          pure Inputs {request, result, archive}
    other -> fail ("unreadable inputs: " <> take 200 (show other))

main :: IO ()
main = do
  inputs <- readInputs "bench/inputs.json"
  temporary <- getTemporaryDirectory
  let scratch = temporary </> "hamsterdan-agents-bench"
  removePathForcibly scratch
  createDirectoryIfMissing True scratch
  sealOpen <- keyCase scratch
  claimSettle <- routeCase scratch
  turn <- turnCase scratch inputs.request
  defaultMain
    [ localOption WallTime $
        bgroup
          "agents"
          -- The pure rows apply their function to the input on every
          -- iteration ('nf' / 'whnf'), so nothing is shared between them.
          [ bench "prompt/encode a review prompt" (nf prompt inputs.request)
          , bench "result/parse and validate an 8-finding review result" (whnf (resultCase inputs.request) inputs.result)
          , bench "archive/admit a 200-file settled workspace archive" (whnf archiveCase inputs.archive)
          , bench "keys/seal and open connection state" (whnfIO sealOpen)
          , bench "routes/claim and settle one operation" (whnfIO claimSettle)
          , bench "agent turn/one scripted Pi review through the Pi native runner" (whnfIO turn)
          ]
    ]
  removePathForcibly scratch

prompt :: ReviewRequest -> Text
prompt request = either (error . show) id (encodePrompt ReviewKind url (AgentReview request))

-- | The validated result's findings, forced: validation decides 'Right'
-- only after every check, and the findings are what it builds.
resultCase :: ReviewRequest -> Text -> Int
resultCase request raw =
  case parseResult raw >>= \members -> validateResult KindReview (Object members) (AgentReview request) Nothing of
    Right (ResultReview validated) -> length validated.findings
    Right _ -> error "not a review result"
    Left failure -> error (show failure)

archiveCase :: ByteString -> Int
archiveCase archive = case validatedEntries (64 * 1024 * 1024) archive of
  Right entries -> sum [BS.length entry.content | entry <- entries]
  Left failure -> error (show failure)

keyCase :: FilePath -> IO (IO ())
keyCase scratch = do
  keys <- persistentKeyOperations (scratch </> "keys")
  context <- throwLeft (mkKeyContext "hamsterdan-pi-a2" 1 1)
  let plain = "opaque connection state of a Pi A2 direct authority" :: ByteString
  pure $ do
    sealed <- keys.seal context (BA.convert plain)
    opened <- keys.open context sealed
    unless (BA.convert opened == plain) $ throwIO (userError "the opened state differs")

routeCase :: FilePath -> IO (IO ())
routeCase scratch = do
  composition <- composeAgent Nothing Nothing Nothing
  store <- openAgentRouteStore (scratch </> "routes" </> "agent-routes.sqlite3")
  activateRoutes store composition (scratch </> "routes" </> "applications")
  counter <- newIORef (0 :: Int)
  pure $ do
    n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
    let operation = "review:bench:" <> T.pack (show n)
    void (claimRoute store operation composition)
    settleRoutes store [operation]

turnCase :: FilePath -> ReviewRequest -> IO (IO ())
turnCase scratch template = do
  let repository = scratch </> "repository"
  (base, first, _) <- deterministicRepository repository
  let request = template {epoch = 1, head = first, base, priorComments = []}
      text = clearReviewText request.repository request.pullRequest request.epoch request.head request.base
      installation =
        PiA2InstallationConfig
          { provider = "anthropic"
          , model = "claude-sonnet-4-5"
          , directKey = "synthetic-direct-authority"
          , cliPath = "/opt/pi/cli.js"
          , nodePath = "/opt/pi/node"
          , packageRoot = "/opt/pi/package"
          }
  pure $ do
    let root = scratch </> "turn"
    (host, receiver) <-
      composeAgentRuntimeWith
        newGitPiWorkspaceProvider
        (\state selected -> (.host) <$> composeOwnedPiA2With (scriptedPiA2Hooks [text]) state (Just selected))
        root
        installation
    runner <- scriptedAgentRunner host (localClone repository (gitPiWorkspaceProvider receiver))
    reviewed <- runner.review url request Invocation {operation = "review:bench:turn", attempt = 1, isCurrent = Nothing}
    closed <- closeHost host
    unless (reviewed.status == "clear" && closed) $ throwIO (userError "the scripted review did not settle clear")
    removeDirectoryRecursive root
