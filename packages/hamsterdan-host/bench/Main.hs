-- | Hot-path benchmarks for hamsterdan-host; bench.py runs the same
-- operations on the same inputs in the pinned Python.
--
-- > cabal bench hamsterdan-host --benchmark-options='-j1 --csv hs.csv +RTS -M2G -RTS'
--
-- Every row is measured in wall-clock time ('WallTime'), as bench.py
-- measures it: the reconciliation and agent rows wait on SQLite, file system
-- calls and git child processes, which tasty-bench's default CPU time would
-- not count.
--
-- Read the numbers from the CSV: the reconciliation row sends stdout (the
-- Worker's progress lines) to /dev/null while it runs, and the console
-- reporter can print the previous row's result in that window, so the
-- console may show a row's name over its neighbour's time.
--
-- * webhook ingest: 100 signed @pull_request@ deliveries, each a
--   @POST /github/webhooks@ through the WAI application called in process,
--   into one long-lived host;
-- * reconciliation step: one webhook to quiescence on a fresh Instance
--   (open the host on a fresh state directory, custody the delivery,
--   process it through the real V5 application against the @V5Provider@
--   double, pump until nothing is runnable, close, remove the directory);
-- * agent turn: the same step with the composed agent of @serve@ in place of
--   the clear-review runner ('composeHostAgent': the Pi A2 installation from
--   the environment, @agent-routes.sqlite3@, the workspace receiver, the
--   owned Pi A2 runtime over the scripted Pi runtime, the Pi native runner),
--   so the review is one scripted Pi turn over a clone of a local
--   repository, with its route claimed and settled;
-- * gate classification: the reply, reminder and dashboard gates under the
--   eight publisher outcomes of @test_v5_gates.py@ (24 classifications);
-- * timer rebuild: a fresh timer store opened from the 333-fact History of
--   @bench/inputs.json@, closed, and removed; and the same open of a fresh
--   store with no History, to separate the file work from the replay.
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Control.Exception (bracket, evaluate, throwIO)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol (AgentRunner (..))
import Hamsterdan.Contracts.Codec (validate)
import Hamsterdan.Contracts.ReadinessV5 (DashReq, RemReq (..), ReplyReq (..), TimerCommandApplied, TimerDue)
import Hamsterdan.GitHub.Models (CommentReference (..), PublicationCollision (..), PublicationResult (..), boundary)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agents (AgentSeams (..), composeHostAgent, newOwnedAgent, productionAgentSeams)
import Hamsterdan.Host.Api (hostWaiApplication)
import Hamsterdan.Host.PiWorkspace (gitPiWorkspaceProvider)
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.Scripted (clearReviewText, deterministicRepository, localClone, scriptedAgentRunner, scriptedPiA2Hooks)
import Hamsterdan.Host.Service (AgentCustody, HostService (..), ServiceOptions (..), noAgentCustody, openHostService, serviceOptions, v5ApplicationFactory)
import Hamsterdan.Host.Service qualified as Host
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Gates
import Hamsterdan.Host.V5.Timers qualified as T5
import Hamsterdan.Readiness.NetV5.Gating (Variant (..))
import Network.HTTP.Types (http11, statusCode)
import Network.Wai (Application, RequestBodyLength (..), defaultRequest, responseStatus, setRequestBodyChunks)
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (..))
import Petrus.Json (Json (..), parseJson, pythonLoads)
import System.Directory (canonicalizePath, createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive, removePathForcibly)
import System.FilePath ((</>))
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (..), hClose, hFlush, openFile, stdout)
import Test.Tasty (localOption)
import Test.Tasty.Bench
import Text.Printf (printf)
import V5Doubles

synchronize :: ByteString
synchronize =
  "{\"action\": \"synchronize\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"pull_request\": {\"number\": 7}}"

main :: IO ()
main = do
  -- Canonical: the host refuses a state root with a symbolic link among
  -- its ancestors, and the temporary directory is under one on macOS (/var).
  temporary <- canonicalizePath =<< getTemporaryDirectory
  let scratch = temporary </> "hamsterdan-host-bench"
  removePathForcibly scratch
  createDirectoryIfMissing True scratch
  facts <- timerHistory "bench/inputs.json"
  ingestHost <- openHost (scratch </> "ingest") =<< newIORef []
  counter <- newIORef (0 :: Int)
  let app = hostWaiApplication ingestHost
  commits <- deterministicRepository (scratch </> "repository")
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "webhook ingest"
        [bench "100 deliveries through POST /github/webhooks" (whnfIO (ingest app counter))]
    , bgroup
        "reconciliation"
        [bench "one webhook to quiescence on a fresh Instance" (whnfIO (reconcileOnce scratch))]
    , bgroup
        "agent turn"
        [bench "one webhook to quiescence through the scripted Pi agent" (whnfIO (agentReconcileOnce scratch commits))]
    , bgroup
        "gates"
        [bench "24 classifications (reply, reminder, dash x 8 outcomes)" (whnfIO classifyAll)]
    , bgroup
        "timers"
        [ bench ("rebuild from a " <> show (length facts) <> "-fact History") (whnfIO (rebuildOnce scratch facts))
        , bench "open a fresh store with no History" (whnfIO (rebuildOnce scratch []))
        ]
    ]
  Host.close ingestHost
  removePathForcibly scratch

-- | The host over the doubles, with installation 44 and @owner/one@ active.
openHost :: FilePath -> IORef [Json] -> IO HostService
openHost root reviews = do
  provider <- newProvider (T.replicate 40 "a") []
  host <-
    openHostService
      (doublesConfig root "private-key-secret")
      (serviceOptions (clearRunner reviews) noAgentCustody)
        { clients = Just (doubleClients (providerTransport provider))
        , applicationFactory = v5ApplicationFactory
        }
  activate host
  pure host

-- ---------------------------------------------------------------------------
-- Webhook ingest

ingest :: Application -> IORef Int -> IO ()
ingest app counter =
  forM_ [1 .. 100 :: Int] $ \_ -> do
    n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
    status <- post app (T.pack (printf "%08x-0000-4000-8000-000000000000" n))
    unless (status == 202) $ throwIO (userError ("ingest answered " <> show status))

post :: Application -> Text -> IO Int
post app delivery = do
  chunks <- newIORef [synchronize]
  let next = atomicModifyIORef' chunks (\case [] -> ([], BS.empty); c : cs -> (cs, c))
      request =
        setRequestBodyChunks
          next
          defaultRequest
            { Wai.requestMethod = "POST"
            , Wai.httpVersion = http11
            , Wai.rawPathInfo = "/github/webhooks"
            , Wai.pathInfo = ["github", "webhooks"]
            , Wai.requestHeaders = [(CI.mk (TE.encodeUtf8 k), TE.encodeUtf8 v) | (k, v) <- signedHeaders synchronize delivery "pull_request"]
            , Wai.requestBodyLength = KnownLength (fromIntegral (BS.length synchronize))
            }
  status <- newIORef 0
  _ <- app request (\response -> writeIORef status (statusCode (responseStatus response)) >> pure ResponseReceived)
  readIORef status

-- ---------------------------------------------------------------------------
-- Reconciliation step

reconcileOnce :: FilePath -> IO ()
reconcileOnce scratch = do
  reviews <- newIORef []
  provider <- newProvider (T.replicate 40 "a") []
  toQuiescence (scratch </> "reconcile") provider (\_ -> pure (clearRunner reviews, noAgentCustody))

-- | The reconciliation step with @serve@'s composed agent over the scripted
-- Pi runtime: one clear review turn at the first feature commit.
agentReconcileOnce :: FilePath -> (Text, Text, Text) -> IO ()
agentReconcileOnce scratch (base, first, _) = do
  provider <- newProviderOn base first []
  turns <- newIORef (0 :: Int)
  let seams =
        productionAgentSeams
          { hooks = scriptedPiA2Hooks [clearReviewText "owner/one" 7 1 first base]
          , workspaces = localClone (scratch </> "repository") . gitPiWorkspaceProvider
          , selectRunner = scriptedAgentRunner
          }
      compose root = do
        owned <- newOwnedAgent
        (runner, custody) <- composeHostAgent seams owned agentEnvironment (pure ()) root
        pure (runner {review = \url request invocation -> modifyIORef' turns (+ 1) >> runner.review url request invocation}, custody)
  toQuiescence (scratch </> "agent") provider compose
  reviewed <- readIORef turns
  unless (reviewed == 1) $ throwIO (userError ("the agent reviewed " <> show reviewed <> " times"))

-- | What @serve@ reads from the environment for the agent (the Pi
-- installation paths must be absolute; the scripted runtime never runs
-- them).
agentEnvironment :: [(Text, Text)]
agentEnvironment =
  [ ("HAMSTERDAN_PI_PROVIDER", "anthropic")
  , ("HAMSTERDAN_PI_MODEL", "claude-sonnet-4-5")
  , ("HAMSTERDAN_PI_API_KEY", "synthetic-direct-authority")
  , ("HAMSTERDAN_PI_CLI_PATH", "/opt/pi/cli.js")
  , ("HAMSTERDAN_PI_NODE_PATH", "/opt/pi/node")
  , ("HAMSTERDAN_PI_PACKAGE_ROOT", "/opt/pi/package")
  ]

-- | Open the host on a fresh state directory with the composed runner,
-- custody one webhook, process it, pump to quiescence, close, check the
-- dashboard was posted, remove the directory.
toQuiescence :: FilePath -> Provider -> (FilePath -> IO (AgentRunner, AgentCustody)) -> IO ()
toQuiescence root provider compose = do
  comments <- quietly $ do
    (runner, custody) <- compose root
    host <-
      openHostService
        (doublesConfig root "private-key-secret")
        (serviceOptions runner custody)
          { clients = Just (doubleClients (providerTransport provider))
          , applicationFactory = v5ApplicationFactory
          }
    activate host
    let delivery = "11111111-1111-4111-8111-111111111111"
    receipt <- Custody.receive host.custody (signedHeaders synchronize delivery "pull_request") synchronize
    unless (receipt.disposition == Custody.Accepted) $ throwIO (userError "the delivery was not accepted")
    Custody.pending host.custody 100 Nothing >>= \case
      item : _ -> Host.process host item
      [] -> throwIO (userError "no pending delivery")
    let converge = do
          processed <- Host.pump host 20
          unless (processed == 0) converge
    converge
    Host.close host
    readIORef provider.comments
  unless (length comments == 1) $ throwIO (userError "the dashboard was not posted")
  removeDirectoryRecursive root

-- | Run with stdout on /dev/null (the Worker's progress lines).
quietly :: IO a -> IO a
quietly action = do
  hFlush stdout
  bracket (hDuplicate stdout) (\saved -> hFlush stdout >> hDuplicateTo saved stdout >> hClose saved) $ \_ -> do
    bracket (openFile "/dev/null" WriteMode) hClose $ \devnull -> hDuplicateTo devnull stdout
    action

-- ---------------------------------------------------------------------------
-- Gate classification

data Outcome = Created | Existing | Boundary | Collision | Unknown | Capability | Unclassified

reference :: CommentReference
reference = CommentReference 1 "https://example.test/c/1"

held :: PublicationResult
held = PublicationResult "existing" (Just reference) True False

-- | @FakePublisher@ of @test_v5_gates.py@ without the call record.
publisher :: Outcome -> Bool -> PublicationProvider
publisher outcome found =
  PublicationProvider
    { find = \_ _ _ _ _ -> unused
    , immutable = \_ _ _ _ _ _ _ -> unused
    , immutableOperation = \_ _ _ context _ ->
        if found then pure held else context >> result
    , dashboard = \_ _ _ _ -> result
    , reminderOperation = \_ context ->
        if found then pure held else context >> result
    , finding = \_ _ _ _ -> unused
    , findings = \_ _ _ _ -> unused
    , findingFind = \_ _ -> unused
    }
  where
    unused = throwIO (userError "not part of the benchmark")
    result = case outcome of
      Existing -> pure held
      Boundary -> throwIO (boundary "GitHub did not prove comment publication")
      Collision -> throwIO PublicationCollision
      Unknown -> throwIO (RuntimeError "provider returned an unclassifiable terminal")
      Capability -> pure (PublicationResult "capability_unavailable" Nothing False False)
      Unclassified -> pure (PublicationResult "banana" (Just reference) True False)
      Created -> pure (PublicationResult "created" (Just reference) True False)

gateSet :: [V5PublicationGates]
gateSet =
  [ V5PublicationGates
      { publisher = p
      , claim = pure claim
      , recipients = pure (Just "the-reviewer", "the-author")
      , dashboardPhase = pure claim.phase
      , resolveStaleThreads = Nothing
      }
  | p <- [publisher o False | o <- [Created, Existing, Boundary, Collision, Unknown, Capability, Unclassified]] <> [publisher Created True]
  ]
  where
    claim = CurrentClaim {phase = "running", incarnation = 1, head = "h1", base = "b1", policy = "p1"}

dashWork :: DashReq
dashWork =
  either (error . show) id $
    validate
      ( Object
          [ ("entries", Array [String "row1", String "row2"])
          , ("digest", String "d1")
          , ("desired_entries", Array [String "row1", String "row2"])
          , ("desired_digest", String "d1")
          ]
      )

classifyAll :: IO Int
classifyAll = do
  names <- forM gateSet $ \gates -> do
    reply <- replyGate gates ReplyReq {id = "c1", text = "the answer"}
    reminder <- reminderGate gates RemReq {timerId = "t1"}
    dash <- dashGate gates dashWork
    pure (T.length reply.name + T.length reminder.name + T.length dash.name)
  evaluate (sum names)

-- ---------------------------------------------------------------------------
-- Timer rebuild

timerHistory :: FilePath -> IO [T5.TimerFact]
timerHistory file = do
  bytes <- BS.readFile file
  case parseJson pythonLoads bytes of
    Right (Object members) | Just (Array rows) <- lookup "timer_history" members -> traverse fact rows
    other -> fail ("unreadable timer history: " <> show other)
  where
    fact = \case
      Object [("applied", value)] -> T5.FactApplied <$> either (fail . show) pure (validate @TimerCommandApplied value)
      Object [("due", value)] -> T5.FactDue <$> either (fail . show) pure (validate @TimerDue value)
      other -> fail ("unreadable timer fact: " <> show other)

rebuildOnce :: FilePath -> [T5.TimerFact] -> IO ()
rebuildOnce scratch facts = do
  let path = scratch </> "timers.sqlite3"
  store <- T5.openTimerStore path "github:44:31:pr:7" facts Nothing
  T5.close store
  forM_ ["", "-wal", "-shm"] $ \suffix -> removePathForcibly (path <> suffix)
