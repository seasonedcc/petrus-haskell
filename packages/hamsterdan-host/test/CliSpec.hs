-- | @host/__main__.py@: the operator inspection cases and the startup
-- selector case of @tests/integration/host/test_service.py@, and a
-- differential run of the whole command line against the reference
-- (@differential/cli_reference.py@): for every case, the same stdout,
-- stderr and exit status, the same state effects, and the same GitHub
-- calls against a recording fake GitHub.
module CliSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, finally, throwIO)
import Data.Char (isDigit, toLower)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite3 qualified as S
import FakeGitHub
import Hamsterdan.GitHub.Client (ClientOptions (..))
import Hamsterdan.GitHub.Config (fromEnvironment)
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.Agents.Pi.Doubles (piPackageFixture)
import Hamsterdan.Host.Agents (composeHostAgent, productionAgentSeams)
import Hamsterdan.Host.Cli
import Petrus.Argparse (environmentColumns)
import Hamsterdan.Host.Python (ValueError (..))
import Hamsterdan.Host.Service (noAgentCustody, openHostService, serviceOptions)
import Hamsterdan.Host.Service qualified as Host
import IngressApplicationSpec (objectRunner)
import Petrus.Json (Json (..), compact, dumps, parseJson, surrogateRefusingLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import ServiceSupport (envelope, hostClientsOf, hostConfig, newFakeClients, receiveSigned, sqlExec)
import System.Directory (createDirectory, createDirectoryIfMissing, createDirectoryLink, doesFileExist, removeFile)
import System.Posix.Signals (raiseSignal, sigINT, sigTERM, signalProcess)
import System.Timeout (timeout)
import Network.Socket (Family (AF_INET), SockAddr (SockAddrInet), Socket, SocketType (Stream), bind, close, defaultProtocol, listen, socket, socketPort, tupleToHostAddress)
import Network.Wai.Handler.Warp qualified as Warp
import RawHttp (RawResponse (..), parseResponse)
import RawHttp qualified
import System.FilePath ((</>))
import System.IO (Handle, IOMode (..), hClose, openFile, withFile)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process.Typed
import Test.Hspec
import TestSupport (withTempRoot)

-- ---------------------------------------------------------------------------
-- Fixtures

writeJson :: FilePath -> Json -> IO ()
writeJson path value = BS.writeFile path (either (error . show) id (dumps compact value))

binding7 :: Json
binding7 = Object [("instance_id", String "github:44:31:pr:7"), ("repository", String "owner/one"), ("pull_request", Int 7)]

-- | @json.dumps(binding)@ as the reference test writes it (default
-- separators).
bindingText :: ByteString
bindingText = "{\"instance_id\": \"github:44:31:pr:7\", \"repository\": \"owner/one\", \"pull_request\": 7}"

inspectionHistory :: ByteString
inspectionHistory =
  BS.concat
    [ line <> "\n"
    | line <-
        [ "{\"record\": \"InstanceCreated\", \"instant\": 0}"
        , "{\"record\": \"ActivityRequested\", \"occurrence\": 3, \"instant\": 1, \"transition\": \"execute.dashboard_publish\", \"activity\": \"dashboard_publish\", \"input\": {\"work\": {\"operation\": \"dashboard:three\", \"payload\": {\"secret\": \"must-not-escape\"}}}}"
        , "{\"record\": \"ActivityFailed\", \"occurrence\": 3, \"instant\": 2, \"error\": \"credential-bearing failure must not escape\"}"
        , "{\"record\": \"FiringFailed\", \"occurrence\": 3, \"instant\": 2}"
        , "{\"record\": \"ActivityRequested\", \"occurrence\": 4, \"instant\": 3, \"transition\": \"execute.review\", \"activity\": \"review\", \"input\": {\"work\": {\"operation\": \"review:four\"}}}"
        ]
    ]

instanceRoot :: FilePath -> FilePath
instanceRoot tmp = tmp </> "applications" </> "44" </> "31" </> "7"

shouldRaiseValue :: IO a -> Text -> Expectation
shouldRaiseValue action fragment = action `shouldThrow` \(ValueError message) -> fragment `T.isInfixOf` message

spec :: Spec
spec = do
  describe "tests/integration/host/test_service.py (CLI)" $ do
    it "test_unknown_startup_selector_stops_before_agent_or_provider_composition" . withTempRoot $ \tmp -> do
      composed <- newIORef ([] :: [Text])
      networked <- newIORef (0 :: Int)
      silent <- discard tmp
      let environment = Map.fromList [("HAMSTERDAN_READINESS_TOPOLOGY", "V5")]
          cli =
            (testEnvironment environment silent)
              { loadConfig = pure (hostConfig tmp [(31, "owner/one"), (32, "owner/two")] Set.empty)
              , composeAgent = \_ _ -> modifyIORef' composed (<> ["agent"]) >> pure (objectRunner, noAgentCustody)
              , clientOptions = modifyIORef' networked (+ 1) >> throwIO (userError "no provider composition")
              }
      runCli cli ["serve"] `shouldReturn` ExitFailure 2
      readIORef composed `shouldReturn` []
      readIORef networked `shouldReturn` 0

    it "test_instance_inspection_is_bounded_and_excludes_payloads_and_errors" . withTempRoot $ \tmp -> do
      createDirectoryIfMissing True (instanceRoot tmp)
      BS.writeFile (instanceRoot tmp </> "binding.json") bindingText
      BS.writeFile (instanceRoot tmp </> "history.jsonl") inspectionHistory
      result <- inspectInstance tmp 44 31 7
      let field name = case result of
            Object members -> lookup name members
            _ -> Nothing
      field "record_count" `shouldBe` Just (Int 5)
      field "activities"
        `shouldBe` Just
          ( Object
              [ ("requested", Int 2)
              , ("completed", Int 0)
              , ("failed", Int 1)
              , ("firing_failed", Int 1)
              ,
                ( "unresolved"
                , Array
                    [ Object
                        [ ("occurrence", Int 4)
                        , ("transition", String "execute.review")
                        , ("activity", String "review")
                        , ("operation", String "review:four")
                        ]
                    ]
                )
              ]
          )
      let encoded = either (error . show) id (dumps compact result)
      ("must-not-escape" `BS.isInfixOf` encoded) `shouldBe` False
      ("credential-bearing" `BS.isInfixOf` encoded) `shouldBe` False

    it "test_instance_inspection_rejects_unsafe_binding_and_emitted_fields" . withTempRoot $ \tmp -> do
      createDirectoryIfMissing True (instanceRoot tmp)
      writeJson (tmp </> "binding-target.json") binding7
      createSymbolicLink (tmp </> "binding-target.json") (instanceRoot tmp </> "binding.json")
      BS.writeFile (instanceRoot tmp </> "history.jsonl") "{\"record\": \"InstanceCreated\", \"instant\": 0}\n"
      inspectInstance tmp 44 31 7 `shouldRaiseValue` "bounded regular file"
      removeFile (instanceRoot tmp </> "binding.json")
      BS.writeFile (instanceRoot tmp </> "binding.json") bindingText
      BS.writeFile
        (instanceRoot tmp </> "history.jsonl")
        "{\"record\": \"ActivityRequested\", \"occurrence\": 1, \"instant\": 1, \"transition\": {\"secret\": \"must-not-escape\"}, \"activity\": \"review\", \"input\": {\"work\": {\"operation\": \"review:one\"}}}\n"
      inspectInstance tmp 44 31 7
        `shouldThrow` \(ValueError message) -> "Activity identifiers are malformed" `T.isInfixOf` message && not ("must-not-escape" `T.isInfixOf` message)

    it "test_instance_inspection_rejects_a_symlinked_instance_directory" . withTempRoot $ \tmp -> do
      createDirectory (tmp </> "target")
      createDirectoryIfMissing True (tmp </> "applications" </> "44" </> "31")
      createDirectoryLink (tmp </> "target") (tmp </> "applications" </> "44" </> "31" </> "7")
      inspectInstance tmp 44 31 7 `shouldRaiseValue` "not a real directory"

  describe "serve (uvicorn.run)" $ forM_ [("SIGTERM", sigTERM, [sigTERM]), ("SIGINT", sigINT, [])] $ \(signalName, signal, again) ->
    it ("composes the real agent, serves h11's status line to HTTP/1.0, and stops on " <> signalName) . withTempRoot $ \tmp -> do
      repo <- repoRoot
      privateKey <- BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
      withFakeGitHub registrationRoutes $ \githubPort _ -> do
        side <- prepareSide (tmp </> "serve") privateKey
        port <- bracket Warp.openFreePort (close . snd) (pure . fst)
        probed <- newEmptyMVar
        reraised <- newIORef []
        silent <- discard tmp
        let probe = do
              raw <- RawHttp.exchange port "GET /healthz HTTP/1.0\r\nhost: testserver\r\n\r\n"
              putMVar probed (parseResponse raw)
              raiseSignal signal
            cli =
              (testEnvironment (Map.insert "HAMSTERDAN_PORT" (show port) side.configured) silent)
                { clientOptions = do
                    exchange' <- newPlainExchangeAt "127.0.0.1" githubPort
                    pure ClientOptions {exchange = exchange', clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
                , onServing = \_ -> void (forkIO probe)
                , reraise = \raised -> modifyIORef reraised (<> [raised])
                }
        -- uvicorn raises the captured signal again once shut down: SIGTERM
        -- then ends the reference at once, by SIGTERM; SIGINT meets
        -- asyncio.run's handler, and the command ends normally. The
        -- recording reraise returns, as the default action does for PID 1
        -- of a container: uvicorn.run returns, and the command ends with
        -- status 0 (scripts/container-smoke checks that under docker stop).
        runCli cli ["serve"] `shouldReturn` ExitSuccess
        readIORef reraised `shouldReturn` again
        hClose silent
        -- uvicorn's lines, stdout and stderr alike written to the one
        -- handle (the differential case below compares them with the
        -- reference's).
        logged <- TE.decodeUtf8 <$> BS.readFile (tmp </> "discarded.txt")
        T.lines (normalizeLog [port] logged)
          `shouldBe` [ "INFO:     Started server process [PID]"
                     , "INFO:     Waiting for application startup."
                     , "INFO:     Application startup complete."
                     , "INFO:     Uvicorn running on http://127.0.0.1:PORT (Press CTRL+C to quit)"
                     , "INFO:     127.0.0.1:CLIENT - \"GET /healthz HTTP/1.0\" 200 OK"
                     , "INFO:     Shutting down"
                     , "INFO:     Waiting for application shutdown."
                     , "INFO:     Application shutdown complete."
                     , "INFO:     Finished server process [PID]"
                     ]
        response <- takeMVar probed
        response.statusLine `shouldBe` "HTTP/1.1 200 OK"
        lookup "connection" [(BC.map toLower name, value) | (name, value) <- response.headers] `shouldBe` Just "close"
        -- The owned runtime and the route store exist and were released.
        doesFileExist (lookupState side </> "agent-routes.sqlite3") `shouldReturn` True
        doesFileExist (lookupState side </> "pi-a2" </> "installation") `shouldReturn` True

  describe "serve against the reference (uvicorn's log lines)" $ do
    let forwardedEnvironment side port =
          Map.insert "FORWARDED_ALLOW_IPS" "10.0.0.0/8, 127.0.0.1,::1 , unix:/tmp/x" (Map.insert "HAMSTERDAN_PORT" (show port) side.configured)
        withSides tmp action = do
          repo <- repoRoot
          privateKey <- BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
          withFakeGitHub registrationRoutes $ \githubPort _ -> do
            referenceSide <- prepareSide (tmp </> "reference") privateKey
            portSide <- prepareSide (tmp </> "port") privateKey
            action githubPort referenceSide portSide
    it "logs startup, an access line per response and shutdown as the reference does" . withTempRoot $ \tmp ->
      withSides tmp $ \githubPort referenceSide portSide -> do
        referencePort <- freePort
        reference <- serveReference tmp githubPort (forwardedEnvironment referenceSide referencePort) serveRequests
        ourPort <- freePort
        ours <- servePort tmp githubPort (forwardedEnvironment portSide ourPort) serveRequests
        -- The reference ends by SIGTERM, raised again after the shutdown.
        reference.code `shouldBe` (-15)
        length (T.lines reference.out) `shouldBe` length serveRequestBytes
        normalizedOutcome [ourPort] ours `shouldBe` normalizedOutcome [referencePort] reference
    it "logs a bind failure, shuts the lifespan down and exits 3 as the reference does" . withTempRoot $ \tmp ->
      withSides tmp $ \githubPort referenceSide portSide ->
        bracket occupiedPort (close . snd) $ \(busy, _) -> do
          reference <- serveReference tmp githubPort (forwardedEnvironment referenceSide busy) (\_ -> pure ())
          ours <- servePort tmp githubPort (forwardedEnvironment portSide busy) (\_ -> pure ())
          reference.code `shouldBe` 3
          normalizedOutcome [busy] ours `shouldBe` normalizedOutcome [busy] reference
    it "answers a failing route 500 and logs its exception as the reference does" . withTempRoot $ \tmp ->
      withSides tmp $ \githubPort referenceSide portSide -> do
        -- With the inbox table renamed away under the running server,
        -- @/healthz@'s inbox count raises sqlite3's OperationalError.
        let failing side port = do
              sqlExec (lookupState side </> "webhooks.sqlite3") "ALTER TABLE inbox RENAME TO inbox_gone" []
              void (RawHttp.exchange port (RawHttp.rawRequest "GET" "/healthz" [] ""))
        referencePort <- freePort
        reference <- serveReference tmp githubPort (forwardedEnvironment referenceSide referencePort) (failing referenceSide)
        ourPort <- freePort
        ours <- servePort tmp githubPort (forwardedEnvironment portSide ourPort) (failing portSide)
        reference.code `shouldBe` (-15)
        reference.out `shouldSatisfy` T.isInfixOf "\"GET /healthz HTTP/1.1\" 500 Internal Server Error"
        reference.err `shouldSatisfy` T.isInfixOf "ERROR:    Exception in ASGI application\n"
        normalizedOutcome [ourPort] ours `shouldBe` normalizedOutcome [referencePort] reference
    it "logs a lifespan startup failure and exits 3 as the reference does" . withTempRoot $ \tmp -> do
      repo <- repoRoot
      privateKey <- BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
      -- A GitHub that knows no App: the startup registration check fails.
      withFakeGitHub (\_ _ -> Nothing) $ \githubPort _ -> do
        referenceSide <- prepareSide (tmp </> "reference") privateKey
        portSide <- prepareSide (tmp </> "port") privateKey
        referencePort <- freePort
        reference <- serveReference tmp githubPort (forwardedEnvironment referenceSide referencePort) (\_ -> pure ())
        ourPort <- freePort
        ours <- servePort tmp githubPort (forwardedEnvironment portSide ourPort) (\_ -> pure ())
        reference.code `shouldBe` 3
        normalizedOutcome [ourPort] ours `shouldBe` normalizedOutcome [referencePort] reference

  describe "the command line against the reference (python -m hamsterdan.host)" $
    it "prints, exits, changes state and calls GitHub exactly as the reference" . withTempRoot $ \tmp -> do
      repo <- repoRoot
      privateKey <- BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
      withFakeGitHub registrationRoutes $ \githubPort calls -> do
        referenceRoot <- prepareSide (tmp </> "reference") privateKey
        portRoot <- prepareSide (tmp </> "port") privateKey
        let referenceCases = cases referenceRoot githubPort
            portCases = cases portRoot githubPort
        references <- runReference tmp referenceCases
        referenceCalls <- map comparableCall <$> takeCalls calls
        ours <- forM portCases (runPort tmp)
        portCalls <- map comparableCall <$> takeCalls calls
        length references `shouldBe` length ours
        -- The agent composition is real on both sides: the commands that
        -- open the service succeed over the Pi package fixture, and every
        -- Pi refusal is the reference's own usage error.
        let outcomes = zip referenceCases references
            succeeded = [o | (c, o) <- outcomes, take 1 c.argv `elem` [["inbox"], ["validate"], ["requeue"]], o.code == 0]
            piRefusals = [o | (c, o) <- outcomes, any (`Map.member` c.env) ["HAMSTERDAN_PI_API_KEY_FILE"] || not (Map.member "HAMSTERDAN_PI_PROVIDER" c.env && Map.member "HAMSTERDAN_PI_API_KEY" c.env) && Map.member "HAMSTERDAN_STATE_PATH" c.env, o.code == 2]
        length succeeded `shouldSatisfy` (>= 4)
        length piRefusals `shouldSatisfy` (>= 3)
        -- FORCE_COLOR colors the help and both usage errors, even with
        -- TERM=dumb; NO_COLOR refuses.
        length [o | o <- references, "\ESC[" `T.isInfixOf` (o.out <> o.err)] `shouldBe` 6
        forM_ (zip3 referenceCases references ours) $ \(theCase, expected, actual) ->
          unless (expected == actual) $
            expectationFailure
              ( "argv "
                  <> show theCase.argv
                  <> " env "
                  <> show (Map.keys theCase.env)
                  <> "\n  reference: "
                  <> show expected
                  <> "\n  port:      "
                  <> show actual
              )
        when (null referenceCalls) $ expectationFailure "the reference made no GitHub calls"
        portCalls `shouldBe` referenceCalls

-- ---------------------------------------------------------------------------
-- The differential cases

data Case = Case
  { argv :: [Text]
  , env :: Map String String
  , github :: Maybe Int
  }

data Outcome = Outcome
  { code :: Int
  , out :: Text
  , err :: Text
  }
  deriving stock (Eq, Show)

-- | A state root (with an installations file and a bound instance) and
-- the configuration environment over it.
data Side = Side
  { configured :: Map String String
  -- ^ The service state (V5, with one parked delivery).
  , inspection :: Map String String
  -- ^ The same configuration over a separate state root holding
  -- Instances to inspect (including a pre-V5 binding, which the service
  -- would refuse to open).
  }

prepareSide :: FilePath -> ByteString -> IO Side
prepareSide base privateKey = do
  let state = base </> "state"
      installations = base </> "installations.toml"
  createDirectoryIfMissing True base
  BS.writeFile installations "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\"31:owner/one\", \"32:owner/two\"]\n"
  setFileMode installations 0o600
  (cli, node, package) <- piPackageFixture base
  let configured =
        Map.fromList
          [ ("HAMSTERDAN_STATE_PATH", state)
          , ("HAMSTERDAN_GITHUB_APP_ID", "17")
          , ("HAMSTERDAN_GITHUB_APP_SLUG", "hamsterdan-test")
          , ("HAMSTERDAN_GITHUB_CLIENT_ID", "Iv1.test")
          , ("HAMSTERDAN_GITHUB_INSTALLATIONS_FILE", installations)
          , ("HAMSTERDAN_GITHUB_PRIVATE_KEY", BC.unpack privateKey)
          , ("HAMSTERDAN_GITHUB_WEBHOOK_SECRET", "hook-secret")
          , ("HAMSTERDAN_PI_PROVIDER", "anthropic")
          , ("HAMSTERDAN_PI_MODEL", "claude-sonnet-4-5")
          , ("HAMSTERDAN_PI_API_KEY", "synthetic-direct-authority")
          , ("HAMSTERDAN_PI_CLI_PATH", cli)
          , ("HAMSTERDAN_PI_NODE_PATH", node)
          , ("HAMSTERDAN_PI_PACKAGE_ROOT", package)
          , ("COLUMNS", "80")
          ]
  -- The custody database with one parked delivery, made by the port and
  -- read by both sides.
  config <- fromEnvironment configured
  clients <- newFakeClients
  service <- openHostService config (serviceOptions objectRunner noAgentCustody) {Host.clients = Just (hostClientsOf clients)}
  _ <- receiveSigned service envelope "d4f2c3b1-8a6e-4f0d-9c7b-1e2a3b4c5d6e" "pull_request"
  Host.close service
  sqlExec
    (state </> "webhooks.sqlite3")
    "UPDATE inbox SET status='failed',attempts=3,error_class='RuntimeError',reason='synthetic failure' WHERE delivery_id=?"
    [S.SQLText "d4f2c3b1-8a6e-4f0d-9c7b-1e2a3b4c5d6e"]
  let inspected = base </> "inspected"
  createDirectoryIfMissing True (instanceRoot inspected)
  BS.writeFile (instanceRoot inspected </> "binding.json") bindingText
  BS.writeFile (instanceRoot inspected </> "history.jsonl") inspectionHistory
  let empty = inspected </> "applications" </> "44" </> "31" </> "8"
  createDirectoryIfMissing True empty
  BS.writeFile (empty </> "binding.json") "{\"instance_id\": \"github:44:31:pr:8\", \"repository\": \"owner/one\", \"pull_request\": 8}"
  BS.writeFile (empty </> "history.jsonl") "{\"record\": \"InstanceCreated\", \"instant\": 1.5}\n\n"
  let floats = inspected </> "applications" </> "44" </> "31" </> "9"
  createDirectoryIfMissing True floats
  BS.writeFile (floats </> "binding.json") "{\"instance_id\": \"github:44:31:pr:9\", \"repository\": \"owner/one\", \"pull_request\": 9, \"topology\": \"v5\"}"
  BS.writeFile (floats </> "history.jsonl") "{\"record\": \"InstanceCreated\", \"instant\": 1}\r\n{\"record\": \"ActivityCompleted\", \"occurrence\": 2, \"instant\": 1.0}\r{\"record\": \"Other\", \"instant\": 2.25, \"occurrence\": true}\n"
  -- A History holding lone surrogate escapes, which @json.loads@ keeps.
  let surrogates = inspected </> "applications" </> "44" </> "31" </> "11"
  createDirectoryIfMissing True surrogates
  BS.writeFile (surrogates </> "binding.json") "{\"instance_id\": \"github:44:31:pr:11\", \"repository\": \"owner/one\", \"pull_request\": 11, \"topology\": \"v5\"}"
  BS.writeFile (surrogates </> "history.jsonl") "{\"record\": \"InstanceStarted\", \"instant\": 1, \"note\": \"\\ud800\"}\n{\"record\": \"ActivityRequested\", \"occurrence\": 2, \"instant\": 2, \"transition\": \"execute.x\", \"activity\": \"x\", \"input\": {\"work\": {\"operation\": \"op\", \"\\udfff\\ud800x\": \"\\ud83d\"}}}\n"
  -- An @ActivityRequested@ whose operation holds one: @_identifier@'s
  -- @value.encode()@ refuses it.
  let unencodable = inspected </> "applications" </> "44" </> "31" </> "12"
  createDirectoryIfMissing True unencodable
  BS.writeFile (unencodable </> "binding.json") "{\"instance_id\": \"github:44:31:pr:12\", \"repository\": \"owner/one\", \"pull_request\": 12, \"topology\": \"v5\"}"
  BS.writeFile (unencodable </> "history.jsonl") "{\"record\": \"ActivityRequested\", \"occurrence\": 2, \"instant\": 2, \"transition\": \"execute.x\", \"activity\": \"x\", \"input\": {\"work\": {\"operation\": \"op\\ud800\"}}}\n"
  -- Integer instants on either side of CPython's int-to-float overflow
  -- threshold, 2^1024 - 2^970: the first rounds to DBL_MAX, the second
  -- raises @OverflowError@.
  forM_ [(13, 2 ^ (1024 :: Int) - 2 ^ (970 :: Int) - 1), (14, 2 ^ (1024 :: Int) - 2 ^ (970 :: Int))] $ \(pr, instant) -> do
    let huge = inspected </> "applications" </> "44" </> "31" </> show (pr :: Int)
    createDirectoryIfMissing True huge
    BS.writeFile (huge </> "binding.json") (BC.pack ("{\"instance_id\": \"github:44:31:pr:" <> show pr <> "\", \"repository\": \"owner/one\", \"pull_request\": " <> show pr <> ", \"topology\": \"v5\"}"))
    BS.writeFile (huge </> "history.jsonl") (BC.pack ("{\"record\": \"InstanceCreated\", \"instant\": " <> show (instant :: Integer) <> "}\n"))
  pure Side {configured, inspection = Map.insert "HAMSTERDAN_STATE_PATH" inspected configured}

cases :: Side -> Int -> [Case]
cases side githubPort =
  -- Parsing, usage and help, before any configuration is read.
  [Case args (Map.fromList [("COLUMNS", "80")]) Nothing | args <- parsing]
    <> [Case ["-h"] (Map.fromList [("COLUMNS", columns)]) Nothing | columns <- widths]
    <> [Case ["bogus"] (Map.fromList [("COLUMNS", columns)]) Nothing | columns <- widths]
    -- Colors (@_colorize@; the runner's @-I@ ignores @PYTHON_COLORS@): help,
    -- a parse error and an error after parsing.
    <> [ Case args (Map.fromList (("COLUMNS", "80") : colors)) Nothing
       | args <- [["-h"], ["bogus"], ["requeue"]]
       , colors <- [[("FORCE_COLOR", "1")], [("FORCE_COLOR", "1"), ("NO_COLOR", "1")], [("FORCE_COLOR", "1"), ("TERM", "dumb")]]
       ]
    <> [ Case ["serve"] (Map.fromList [("HAMSTERDAN_PORT", "x")]) Nothing
       , Case ["serve"] (Map.fromList [("HAMSTERDAN_PORT", "")]) Nothing
       , Case ["-h"] (Map.fromList [("HAMSTERDAN_PORT", " 9_000 "), ("HAMSTERDAN_HOST", "")]) Nothing
       ]
    -- Configuration failures.
    <> [ Case ["validate"] (Map.delete key side.configured) Nothing
       | key <- ["HAMSTERDAN_STATE_PATH", "HAMSTERDAN_GITHUB_APP_ID", "HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE"]
       ]
    <> [Case ["validate"] (Map.insert "HAMSTERDAN_GITHUB_APP_ID" "0" side.configured) Nothing]
    -- inspect-instance.
    <> [ Case ["inspect-instance", "--installation", "44", "--repository", "31", "--pr", pr] side.inspection Nothing
       | pr <- ["7", "8", "9", "10", "11", "12", "13", "14", "-7", "0"]
       ]
    <> [Case ["--inst", "4_4", "--repo", "31", "--pr", " 7 ", "inspect-instance"] side.inspection Nothing]
    <> [Case ["validate"] side.inspection Nothing]
    -- The Pi installation and the agent composition, refused before
    -- the service exists.
    <> [ Case ["validate"] (Map.delete key side.configured) Nothing
       | key <- ["HAMSTERDAN_PI_PROVIDER", "HAMSTERDAN_PI_MODEL", "HAMSTERDAN_PI_API_KEY", "HAMSTERDAN_PI_CLI_PATH", "HAMSTERDAN_PI_NODE_PATH", "HAMSTERDAN_PI_PACKAGE_ROOT"]
       ]
    <> [ Case ["inbox"] (Map.insert key value side.configured) Nothing
       | (key, value) <-
           [ ("HAMSTERDAN_PI_MODEL", "claude-unqualified")
           , ("HAMSTERDAN_PI_PROVIDER", "openai")
           , ("HAMSTERDAN_PI_API_KEY", "")
           , ("HAMSTERDAN_PI_API_KEY", "key with spaces")
           , ("HAMSTERDAN_PI_API_KEY_FILE", "/run/secrets/pi")
           , ("HAMSTERDAN_PI_CLI_PATH", "relative/cli.js")
           , ("HAMSTERDAN_AGENT_MODE", "legacy-amp")
           , ("HAMSTERDAN_AGENT_ISOLATION_REQUIRED", "1")
           ]
       ]
    -- Startup refusals before the service exists.
    <> [ Case ["inbox"] (Map.insert "HAMSTERDAN_READINESS_TOPOLOGY" "" side.configured) Nothing
       , Case ["inbox"] (Map.insert "HAMSTERDAN_REMINDER_SECONDS" "abc" side.configured) (Just githubPort)
       , Case ["inbox"] (Map.insert "HAMSTERDAN_QUALIFICATION_FAULT" "{}" side.configured) (Just githubPort)
       ]
    -- The inbox and requeue against the parked delivery.
    <> [ Case ["inbox"] (Map.insert "HAMSTERDAN_REMINDER_SECONDS" " 1_0.5e1 " side.configured) (Just githubPort)
       , Case ["requeue", "--delivery", "D4F2C3B1-8A6E-4F0D-9C7B-1E2A3B4C5D6E"] side.configured (Just githubPort)
       , Case ["requeue", "--delivery", "d4f2c3b1-8a6e-4f0d-9c7b-1e2a3b4c5d6e"] side.configured (Just githubPort)
       , Case ["requeue", "--delivery", "d4f2c3b1-8a6e-4f0d-9c7b-1e2a3b4c5d6e"] side.configured (Just githubPort)
       , Case ["inbox"] side.configured (Just githubPort)
       ]
    -- The registration against the fake GitHub.
    <> [ Case ["validate"] side.configured (Just githubPort)
       , Case ["validate"] (Map.insert "HAMSTERDAN_GITHUB_CLIENT_ID" "Iv1.other" side.configured) (Just githubPort)
       ]
  where
    widths = ["80", "40", "20", "1", "200", "0", "abc", "-5", " 6_0 "]
    parsing =
      [ []
      , ["-h"]
      , ["--help"]
      , ["-hx"]
      , ["-hh"]
      , ["-hd"]
      , ["-h=1"]
      , ["--help=1"]
      , ["--help="]
      , ["--he"]
      , ["--h"]
      , ["requeue"]
      , ["requeue", "--delivery="]
      , ["inspect-instance"]
      , ["inspect-instance", "--installation", "1", "--repository", "2"]
      , ["bogus"]
      , ["Serve"]
      , ["serve", "extra"]
      , ["serve", "validate"]
      , ["--installation", "abc", "validate"]
      , ["--pr"]
      , ["--foo", "serve"]
      , ["--p", "4", "serve"]
      , ["--port=x", "serve"]
      , ["-x", "serve"]
      , ["serve", "--", "validate"]
      , ["--delivery"]
      , ["--", "--", "serve"]
      , ["-", "serve"]
      , ["", "serve"]
      , ["--=x"]
      , ["-1"]
      , ["-1x", "serve"]
      , ["serve", "-h"]
      , ["bogus", "-h"]
      , ["-h", "bogus"]
      , ["--pr", "--host", "x", "serve"]
      , ["--pr", "--", "5", "serve"]
      , ["--pr=", "serve"]
      , ["--host"]
      , ["--delivery", "x", "--delivery"]
      , ["--a b", "serve"]
      , ["-a b"]
      , ["--d\233j\224", "serve"]
      , ["--pr", "1e3", "serve"]
      , ["--pr", "\1635", "--installation", "\1636", "--repository", "7", "inspect-instance", "extra"]
      , ["--repository=5=6", "serve"]
      ]

-- | Run every case through the reference in one process.
runReference :: FilePath -> [Case] -> IO [Outcome]
runReference tmp theCases = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-host" </> "differential" </> "cli_reference.py"
      input =
        Array
          [ Object
              [ ("argv", Array (map String c.argv))
              , ("env", Object [(T.pack k, String (T.pack v)) | (k, v) <- Map.toList c.env])
              , ("github_port", maybe Null (Int . toInteger) c.github)
              ]
          | c <- theCases
          ]
      payload = either (error . show) id (dumps compact input)
      config = setWorkingDir tmp (setStdin (byteStringInput (BL.fromStrict payload)) (proc executable ["-I", "-B", script]))
  (status, stdoutBytes, stderrBytes) <- readProcess config
  unless (status == ExitSuccess) $
    expectationFailure ("the reference driver failed: " <> BC.unpack (BL.toStrict stderrBytes))
  case parseJson surrogateRefusingLoads (BL.toStrict stdoutBytes) of
    Right (Array results) -> pure (map outcomeOf results)
    other -> expectationFailure ("unreadable reference results: " <> show other) >> pure []
  where
    outcomeOf = \case
      Object members ->
        Outcome
          { code = case lookup "code" members of
              Just (Int n) -> fromInteger n
              Just Null -> 0
              _ -> -1
          , out = textOf (lookup "stdout" members)
          , err = textOf (lookup "stderr" members)
          }
      _ -> Outcome (-1) "" ""
    textOf = \case
      Just (String text) -> text
      _ -> ""

-- | Run one case through the port, with the reference driver's seams.
runPort :: FilePath -> Case -> IO Outcome
runPort tmp theCase = do
  let outPath = tmp </> "stdout.txt"
      errPath = tmp </> "stderr.txt"
  status <-
    withFile outPath WriteMode $ \outHandle ->
      withFile errPath WriteMode $ \errHandle -> do
        let base = testEnvironment theCase.env outHandle
        runCli
          base
            { errors = errHandle
            , clientOptions = case theCase.github of
                Just port -> do
                  exchange <- newPlainExchangeAt "127.0.0.1" port
                  pure ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
                Nothing -> throwIO (userError "this case must not reach GitHub")
            }
          theCase.argv
  outText <- TE.decodeUtf8 <$> BS.readFile outPath
  errText <- TE.decodeUtf8 <$> BS.readFile errPath
  pure
    Outcome
      { code = case status of
          ExitSuccess -> 0
          ExitFailure n -> n
      , out = outText
      , err = errText
      }

-- | The command line over an environment map, with the production agent
-- composition (the Pi installation, routes, receiver and the Pi A2 runtime
-- over the case's package fixture) and @COLUMNS@ (else 80, as for a pipe).
-- The process environment is left alone: the case's map stands for it.
testEnvironment :: Map String String -> Handle -> CliEnvironment
testEnvironment environment handle =
  CliEnvironment
    { environment
    , forgetSecrets = pure ()
    , loadConfig = fromEnvironment environment
    , clientOptions = throwIO (userError "no GitHub in this case")
    , composeAgent = \owned ->
        composeHostAgent
          productionAgentSeams
          owned
          [ (T.pack name, T.pack value)
          | (name, value) <- Map.toList environment
          , name `notElem` ["HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"]
          ]
          (pure ())
    , columns = pure (fromMaybe 80 (environmentColumns environment))
    , output = handle
    , errors = handle
    , onServing = \_ -> pure ()
    , reraise = \_ -> pure ()
    }

-- ---------------------------------------------------------------------------
-- Serving against the reference

-- | The requests both servers answer in the serve comparison, one
-- connection each: methods, versions, redirects, a refused webhook,
-- quoting of the logged path, and @X-Forwarded-For@ / @X-Forwarded-Proto@
-- from a trusted peer.
serveRequestBytes :: [ByteString]
serveRequestBytes =
  [ RawHttp.rawRequest "GET" "/healthz" [] ""
  , "GET /healthz HTTP/1.0\r\nhost: testserver\r\n\r\n"
  , RawHttp.rawRequest "HEAD" "/healthz" [] ""
  , RawHttp.rawRequest "POST" "/healthz" [] ""
  , RawHttp.rawRequest "GET" "/healthz/?a=b%20c" [] ""
  , RawHttp.rawRequest "GET" "/healthz?x=1" [] ""
  , RawHttp.rawRequest "GET" "/caf%C3%A9/x%2Fy%zz%FF?q=%20" [] ""
  , RawHttp.rawRequest "POST" "/github/webhooks" [] "{}"
  , RawHttp.rawRequest "GET" "/nope" [("x-forwarded-for", "203.0.113.9, 10.1.2.3")] ""
  , RawHttp.rawRequest "GET" "/nope" [("x-forwarded-for", "[2001:db8::1]:4711")] ""
  , RawHttp.rawRequest "GET" "/nope" [("x-forwarded-for", "198.51.100.7:+8_0")] ""
  , RawHttp.rawRequest "GET" "/nope" [("x-forwarded-for", "unix:/tmp/x"), ("X-Forwarded-For", "")] ""
  , RawHttp.rawRequest "GET" "/nope" [("x-forwarded-for", "unix:/tmp/x, 10.9.9.9")] ""
  , RawHttp.rawRequest "GET" "/healthz/" [("x-forwarded-proto", " https ")] ""
  ]

serveRequests :: Int -> IO ()
serveRequests port = mapM_ (void . RawHttp.exchange port) serveRequestBytes

freePort :: IO Int
freePort = bracket Warp.openFreePort (close . snd) (pure . fst)

-- | A port another socket listens on.
occupiedPort :: IO (Int, Socket)
occupiedPort = do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 1
  port <- socketPort listener
  pure (fromIntegral port, listener)

-- | @python -m hamsterdan.host serve@ (@differential/serve_reference.py@)
-- with the given environment, its stdout and stderr to files: once it says
-- it is running, the requests, then SIGTERM to its exact process.
serveReference :: FilePath -> Int -> Map String String -> (Int -> IO ()) -> IO Outcome
serveReference tmp githubPort environment requests = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-host" </> "differential" </> "serve_reference.py"
      outPath = tmp </> "reference-serve-stdout.txt"
      errPath = tmp </> "reference-serve-stderr.txt"
      port = maybe 8000 read (Map.lookup "HAMSTERDAN_PORT" environment)
      payload =
        either (error . show) id $
          dumps
            compact
            ( Object
                [ ("env", Object [(T.pack k, String (T.pack v)) | (k, v) <- Map.toList environment])
                , ("github_port", Int (toInteger githubPort))
                ]
            )
  -- The driver points its own stdout and stderr at the files, so the test
  -- holds no handle on them (GHC locks a file open for writing) and reads
  -- them while it runs.
  BS.writeFile outPath ""
  BS.writeFile errPath ""
  let config =
        setStdin (byteStringInput (BL.fromStrict payload))
          . setStdout nullStream
          . setStderr nullStream
          $ proc executable ["-I", "-B", script, outPath, errPath]
  status <- withProcessTerm config $ \server -> do
    let waitRunning = do
          logged <- BS.readFile errPath
          exited <- getExitCode server
          if "Uvicorn running on" `BS.isInfixOf` logged
            then pure True
            else case exited of
              Just _ -> pure False
              Nothing -> threadDelay 50000 >> waitRunning
    running <- timeout 120000000 waitRunning
    case running of
      Just True -> do
        requests port
        getPid server >>= mapM_ (signalProcess sigTERM)
      Just False -> pure ()
      Nothing -> expectationFailure "the reference server did not start"
    waitExitCode server
  outcomeFiles status outPath errPath

-- | The port's @serve@ with the given environment, its stdout and stderr
-- to files: once it listens, the requests, then SIGTERM. A SIGTERM it
-- raises again is reported as the reference's death by that signal.
servePort :: FilePath -> Int -> Map String String -> (Int -> IO ()) -> IO Outcome
servePort tmp githubPort environment requests = do
  let outPath = tmp </> "port-serve-stdout.txt"
      errPath = tmp </> "port-serve-stderr.txt"
  reraised <- newIORef []
  status <-
    withFile outPath WriteMode $ \outHandle ->
      withFile errPath WriteMode $ \errHandle ->
        runCli
          (testEnvironment environment outHandle)
            { errors = errHandle
            , clientOptions = do
                exchange' <- newPlainExchangeAt "127.0.0.1" githubPort
                pure ClientOptions {exchange = exchange', clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
            , onServing = \port -> void (forkIO (requests port `finally` raiseSignal sigTERM))
            , reraise = \raised -> modifyIORef reraised (<> [raised])
            }
          ["serve"]
  raised <- readIORef reraised
  outcomeFiles (if raised == [sigTERM] then ExitFailure (-15) else status) outPath errPath

outcomeFiles :: ExitCode -> FilePath -> FilePath -> IO Outcome
outcomeFiles status outPath errPath = do
  outText <- TE.decodeUtf8 <$> BS.readFile outPath
  errText <- TE.decodeUtf8 <$> BS.readFile errPath
  pure Outcome {code = case status of ExitSuccess -> 0; ExitFailure n -> n, out = outText, err = errText}

normalizedOutcome :: [Int] -> Outcome -> Outcome
normalizedOutcome ports outcome = outcome {out = normalizeLog ports outcome.out, err = normalizeLog ports outcome.err}

-- | uvicorn's log text with what varies from run to run replaced: the
-- process id, the server's port, and the client's port; and each logged
-- traceback reduced to its header and last line, with the blank lines after
-- it (the port logs only those, host DIVERGENCES item 2).
normalizeLog :: [Int] -> Text -> Text
normalizeLog ports = T.intercalate "\n" . map line . tracebacks . T.splitOn "\n"
  where
    tracebacks = \case
      header : rest
        | "Traceback (most recent call last):" `T.isSuffixOf` header ->
            let (block, others) = break record rest
                (blank, frames) = span T.null (reverse block)
                lastLine = take 1 frames
             in header : lastLine <> blank <> tracebacks others
      l : rest -> l : tracebacks rest
      [] -> []
    record l = any (`T.isPrefixOf` l) ["INFO:", "ERROR:", "WARNING:"]
    line = client . flip (foldr server) ports . pid
    pid l = case T.breakOn "server process [" l of
      (prefix, rest)
        | not (T.null rest) -> prefix <> "server process [PID" <> T.dropWhile (/= ']') rest
        | otherwise -> l
    server port =
      T.replace ("127.0.0.1:" <> T.pack (show port) <> " ") "127.0.0.1:PORT "
        . T.replace ("'127.0.0.1', " <> T.pack (show port) <> ")") "'127.0.0.1', PORT)"
    client l = case T.stripPrefix "INFO:     127.0.0.1:" l of
      Just rest -> "INFO:     127.0.0.1:CLIENT" <> T.dropWhile isDigit rest
      Nothing -> l

discard :: FilePath -> IO Handle
discard tmp = do
  let path = tmp </> "discarded.txt"
  BS.writeFile path ""
  openFile path AppendMode

-- | The side's service state root.
lookupState :: Side -> FilePath
lookupState side = fromMaybe "" (Map.lookup "HAMSTERDAN_STATE_PATH" side.configured)
