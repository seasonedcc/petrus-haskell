{-# LANGUAGE MultiWayIf #-}

-- | The host's process-level, restart and housekeeping benchmarks against
-- the reference, in the shape of the operator and export benchmarks: both
-- sides timed by wall clock (monotonic) in this process, interleaved run
-- by run (the order flips every run), on the same inputs.
--
-- > hamsterdan-host-bench --process [--runs N]     # N runs per row (default 11)
--
-- The state: a state directory made once by the Haskell host over the
-- V5 doubles, with 20 PR Instances of @owner/one@, each driven through 5
-- @synchronize@ deliveries at 5 heads (a review and a dashboard publish or
-- edit per head), so every Instance has a long History. Both hosts resume
-- each other's state directories (the state interop tests), so both sides
-- start every run from a fresh copy of the same bytes; the copy is not
-- timed.
--
-- The GitHub: one fake GitHub REST API on a local port, served from this
-- process ("FakeGitHub"), which both sides' processes call: the App
-- registration of @validate@, and the PR reads and comment writes of the
-- 20 PRs (the V5 provider double of @state_reference.py@ for any PR
-- number). Its state is reset to the template's before every run.
--
-- * __CLI (fresh process)__: @validate@, @inbox@ and @inspect-instance@,
--   each a fresh process: @python -I -B bench/cli_child.py ARGS@ (the
--   reference's @main()@ with @GitHubAppClients@ sent to the fake, as
--   @differential/cli_reference.py@ does) against this binary in its
--   @--cli@ mode (the port's 'runCli' over 'productionEnvironment', with
--   the client sent to the fake). The real agent composition runs on both
--   sides over the Pi package fixture: preflight, agent-route repair (which
--   decodes every History), the service open. Interpreter and runtime
--   start-up are included.
-- * __serve__: from process start to the first @200@ on @GET /healthz@,
--   polled every millisecond over a fresh connection: preflight, route
--   repair, the service open, the startup registration reconciliation
--   against the fake, and the server's bind (the startup sweep runs in the
--   background, as in production).
-- * __socket ingest__: 100 signed @pull_request@ deliveries POSTed to each
--   side's running @serve@ (warp against uvicorn and h11), each over its
--   own connection, as GitHub delivers them, for a repository with no
--   active route (so the worker only acknowledges them).
-- * __in process__: @sweep("periodic")@ over the 20 Instances, loaded (a
--   warm-up sweep first) and unloaded (a freshly opened host loads each
--   Engine from History); one immutable comment publication among 100 bot
--   comments; one native review batch of 8 anchored findings among 100
--   issue and 100 review comments; one GraphQL ref compare-and-swap; and a
--   whole Git publication through the local publication authority of
--   @test_git_publish.py@. The reference runs in one long-lived
--   interpreter (@bench/process_bench.py@), which times each run itself.
--   Setup (state copy, host open and close, repository fixture, patch) is
--   not timed.
--
-- Before timing, every row's first run must agree on both sides: the same
-- exit status and output for the CLI, the same @/healthz@ response, the
-- same sweep count and provider calls, the same publication outcome.
-- Results and the comparison are in RESULTS.md.
module Process (processMain, cliChild) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM, forM_, replicateM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import FakeGitHub (Recorded (..), registrationRoutes, withFakeGitHubIO)
import GHC.Clock (getMonotonicTime)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import GitPublishSpec (LocalAuthority, Repository (..), diffFor, localAuthority, newLocalAuthority, withRepository)
import Hamsterdan.Agents.Pi.Doubles (piPackageFixture)
import Hamsterdan.Agents.Protocol (CodingResult (..))
import Hamsterdan.GitHub.Client (ClientOptions (..))
import Hamsterdan.GitHub.Effects (commentPublisher, immutable, publishFindings)
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.GitHub.Models (FindingPublication, GraphQLTransport (..), PublicationResult (..), Transport (..), WireResponse (..), finding, publicationStatusText)
import Hamsterdan.GitHub.Transport (githubGraphQL)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Cli (CliEnvironment (..), productionEnvironment, runCli)
import Hamsterdan.Host.GitPublish (GitPublishResult (..), hostGitPublisher, publish)
import Hamsterdan.Host.Service (HostService (..), ServiceOptions (..), noAgentCustody, openHostService, serviceOptions, v5ApplicationFactory)
import Hamsterdan.Host.Service qualified as Host
import Network.Socket (close)
import Network.Wai.Handler.Warp qualified as Warp
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import RawHttp qualified
import System.Directory (canonicalizePath, createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, IOMode (..), hClose, hFlush, hGetLine, hPutStrLn, hSetBuffering, openFile, stderr, stdout)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process.Typed
import Text.Printf (printf)
import V5Doubles (activate, clearRunner, doubleClients, doublesConfig, noReviewThreads, signedHeaders)

-- ---------------------------------------------------------------------------
-- The command line of the port, for the CLI rows

-- | @--cli ARGS@: the port's command line with the GitHub client sent to the
-- fake GitHub on @HAMSTERDAN_BENCH_GITHUB_PORT@ (the reference side's
-- @bench/cli_child.py@ does the same to @GitHubAppClients@).
cliChild :: [String] -> IO ()
cliChild arguments = do
  inherited <- Map.fromList <$> getEnvironment
  port <- maybe (fail "HAMSTERDAN_BENCH_GITHUB_PORT is not set") (pure . read) (Map.lookup githubPortVariable inherited)
  let environment = Map.delete githubPortVariable inherited
      cli =
        (productionEnvironment environment)
          { clientOptions = do
              exchange <- newPlainExchangeAt "127.0.0.1" port
              pure ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
          }
  runCli cli (map T.pack arguments) >>= exitWith

githubPortVariable :: String
githubPortVariable = "HAMSTERDAN_BENCH_GITHUB_PORT"

-- ---------------------------------------------------------------------------
-- Sizes and fixtures

pullRequests :: [Integer]
pullRequests = [1 .. 20]

rounds :: [Integer]
rounds = [1 .. 5]

baseSha :: Text
baseSha = T.replicate 40 "b"

-- | The head of PR @n@ after round @k@.
headOf :: Integer -> Integer -> Text
headOf k n = T.pack (printf "%020x%020x" k n)

deliveryOf :: Integer -> Integer -> Text
deliveryOf k n = T.pack (printf "%08x-%04x-4000-8000-000000000000" k n)

synchronizeFor :: Integer -> Integer -> ByteString
synchronizeFor repository number =
  BC.pack
    ( printf
        "{\"action\": \"synchronize\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": %d, \"full_name\": \"owner/%s\"}, \"pull_request\": {\"number\": %d}}"
        repository
        (if repository == 31 then "one" else "three" :: String)
        number
    )

botLogin :: Text
botLogin = "hamsterdan-test[bot]"

-- ---------------------------------------------------------------------------
-- The V5 provider double for any PR number

-- | The PRs' heads and comments (@state_reference.V5Provider@ for every PR
-- of @owner/one@; comment ids are global, as GitHub's are).
data Snapshot = Snapshot
  { heads :: Map Integer Text
  , comments :: Map Integer [[(Text, Json)]]
  }

data Multi = Multi
  { state :: IORef Snapshot
  , calls :: IORef Int
  }

newMulti :: Snapshot -> IO Multi
newMulti snapshot = Multi <$> newIORef snapshot <*> newIORef 0

-- | The answer to a request, or 'Nothing' where @V5Provider@ raises.
multiAnswer :: Multi -> Text -> Text -> Maybe [(Text, Json)] -> IO (Maybe WireResponse)
multiAnswer m method path body = do
  modifyIORef' m.calls (+ 1)
  snapshot <- readIORef m.state
  case method of
    "GET"
      | Just (n, "") <- pullPath path, Just h <- Map.lookup n snapshot.heads -> ok (pullJson n h)
      | path == "/repos/owner/one/git/ref/heads/main" -> ok (Object [("object", Object [("sha", String baseSha)])])
      | path `elem` ["/repos/owner/one/rules/branches/main", "/repos/owner/one/branches/main/protection"] -> pure (Just (WireResponse 404 (Object []) Nothing))
      | Just compared <- T.stripPrefix ("/repos/owner/one/compare/" <> baseSha <> "...") path
      , compared `elem` Map.elems snapshot.heads ->
          ok (Object [("status", String "ahead"), ("behind_by", Int 0)])
      | Just (n, "/requested_reviewers") <- pullPath path, Map.member n snapshot.heads -> ok (Object [("users", Array [])])
      | "/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?" `T.isPrefixOf` path ->
          ok (Object [("total_count", Int 0), ("workflow_runs", Array [])])
    "POST"
      | path == "/graphql" -> ok noReviewThreads
      | Just n <- issuePath path, Map.member n snapshot.heads, Just members <- body -> do
          let identifier = 1 + sum (map length (Map.elems snapshot.comments))
              comment =
                [ ("id", Int (toInteger identifier))
                , ("html_url", String ("https://example.test/comments/" <> T.pack (show identifier)))
                , ("body", maybe (String "") id (lookup "body" members))
                , ("user", Object [("login", String botLogin)])
                ]
          writeIORef m.state snapshot {comments = Map.insertWith (flip (<>)) n [comment] snapshot.comments}
          pure (Just (WireResponse 201 (Object comment) Nothing))
    "PATCH"
      | Just identifierText <- T.stripPrefix "/repos/owner/one/issues/comments/" path
      , Just members <- body -> do
          let identifier = Int (read (T.unpack identifierText))
              edit comment
                | lookup "id" comment == Just identifier = [(k, if k == "body" then maybe (String "") id (lookup "body" members) else v) | (k, v) <- comment]
                | otherwise = comment
              edited = Map.map (map edit) snapshot.comments
          writeIORef m.state snapshot {comments = edited}
          case [comment | comment <- concat (Map.elems edited), lookup "id" comment == Just identifier] of
            comment : _ -> ok (Object comment)
            [] -> pure Nothing
    _ -> pure Nothing
  where
    ok value = pure (Just (WireResponse 200 value Nothing))

multiPages :: Multi -> Text -> IO [[(Text, Json)]]
multiPages m path = do
  modifyIORef' m.calls (+ 1)
  snapshot <- readIORef m.state
  pure $ case T.stripSuffix "/comments?per_page=100" path >>= T.stripPrefix "/repos/owner/one/issues/" of
    Just number | [(n, "")] <- reads (T.unpack number) -> Map.findWithDefault [] n snapshot.comments
    _ -> []

multiTransport :: Multi -> Transport
multiTransport m =
  Transport
    { request = \method path body ->
        multiAnswer m method path body >>= maybe (throwIO (PythonException "AssertionError" [])) pure
    , pages = multiPages m
    }

-- | @/repos/owner/one/pulls/N@ followed by the rest of the path.
pullPath :: Text -> Maybe (Integer, Text)
pullPath path = do
  rest <- T.stripPrefix "/repos/owner/one/pulls/" path
  let (digits, suffix) = T.span (`elem` ['0' .. '9']) rest
  if T.null digits then Nothing else Just (read (T.unpack digits), suffix)

issuePath :: Text -> Maybe Integer
issuePath path = do
  number <- T.stripSuffix "/comments" =<< T.stripPrefix "/repos/owner/one/issues/" path
  case reads (T.unpack number) of
    [(n, "")] -> Just n
    _ -> Nothing

pullJson :: Integer -> Text -> Json
pullJson n headSha =
  Object
    [ ("state", String "open")
    , ("draft", Bool False)
    , ("mergeable", Bool True)
    , ("mergeable_state", String "clean")
    , ("merged", Bool False)
    , ("html_url", String ("https://example.test/owner/one/pull/" <> T.pack (show n)))
    , ("user", Object [("login", String "author")])
    , ("head", Object [("sha", String headSha), ("ref", String "feature"), ("repo", Object [("full_name", String "owner/one")])])
    , ("base", Object [("sha", String baseSha), ("ref", String "main")])
    ]

-- | The provider double over HTTP: the registration answers, then the PR
-- reads and comment writes; anything else is a 404.
fakeRoute :: Multi -> Recorded -> IO (Maybe (Int, [(ByteString, ByteString)], ByteString))
fakeRoute m call = case registrationRoutes call.method call.target of
  Just answer -> pure (Just answer)
  Nothing -> do
    let method = TE.decodeUtf8 call.method
        target = TE.decodeUtf8 call.target
    if method == "GET" && "per_page=100" `T.isInfixOf` target && "/comments?" `T.isInfixOf` target
      then do
        items <- multiPages m target
        pure (Just (200, [], encode (Array (map Object items))))
      else do
        body <- case parseJson pythonLoads call.body of
          Right (Object members) -> pure (Just members)
          _ -> pure Nothing
        answer <- multiAnswer m method target body
        pure (fmap (\response -> (response.status, [], encode response.body)) answer)

encode :: Json -> ByteString
encode value = either (error . show) id (dumps compact value)

-- ---------------------------------------------------------------------------
-- The template state

-- | Drive 20 PRs through 5 heads each on a fresh state directory with the
-- Haskell host over the doubles, and return the provider's final state.
prepareTemplate :: FilePath -> IO Snapshot
prepareTemplate root = do
  m <- newMulti (Snapshot (Map.fromList [(n, headOf 0 n) | n <- pullRequests]) Map.empty)
  quietly $ do
    reviews <- newIORef []
    host <-
      openHostService
        (doublesConfig root "private-key-secret")
        (serviceOptions (clearRunner reviews) noAgentCustody)
          { clients = Just (doubleClients (multiTransport m))
          , applicationFactory = v5ApplicationFactory
          }
    activate host
    forM_ rounds $ \k -> forM_ pullRequests $ \n -> do
      modifyIORef' m.state (\s -> s {heads = Map.insert n (headOf k n) s.heads})
      let body = synchronizeFor 31 n
      receipt <- Custody.receive host.custody (signedHeaders body (deliveryOf k n) "pull_request") body
      unless (receipt.disposition == Custody.Accepted) $ fail "the template delivery was not accepted"
      Custody.pending host.custody 100 Nothing >>= mapM_ (Host.process host)
      let converge = do
            processed <- Host.pump host 20
            unless (processed == 0) converge
      converge
    Host.close host
  readIORef m.state

snapshotJson :: Snapshot -> Json
snapshotJson snapshot =
  Object
    [ ("heads", Object [(T.pack (show n), String h) | (n, h) <- Map.toList snapshot.heads])
    , ("comments", Object [(T.pack (show n), Array (map Object items)) | (n, items) <- Map.toList snapshot.comments])
    ]

-- | Copy the template state to a fresh directory (@cp -R@, as the
-- reference side's @shutil.copytree@ is not part of either side's timing).
freshState :: FilePath -> FilePath -> IO ()
freshState template target = do
  removePathForcibly target
  runProcess_ (proc "cp" ["-R", template, target])

-- | Run with stdout on /dev/null (the Worker's progress lines).
quietly :: IO a -> IO a
quietly action = do
  hFlush stdout
  bracket (hDuplicate stdout) (\saved -> hFlush stdout >> hDuplicateTo saved stdout >> hClose saved >> hSetBuffering stdout LineBuffering) $ \_ -> do
    bracket (openFile "/dev/null" WriteMode) hClose $ \devnull -> hDuplicateTo devnull stdout
    action

-- ---------------------------------------------------------------------------
-- In process, the Haskell side

-- | One timed run of an in-process workload: seconds per operation, and
-- what both sides must agree on.
type Measured = (Double, Text)

-- | Iterations per timed run of the microsecond-scale effect rows.
effectIterations :: Int
effectIterations = 100

haskellRun :: Workspace -> Text -> IO Measured
haskellRun workspace = \case
  "sweep-loaded" -> sweepRun workspace True
  "sweep-unloaded" -> sweepRun workspace False
  "effects-comment" -> do
    publisher <- either throwIO pure (commentPublisher effectsTransport "owner/one" 7 botLogin (\_ _ _ _ _ -> pure ()) Nothing (\_ -> pure ()))
    timedLoop effectIterations (publicationStatusText . (.status) <$> immutable publisher "conversation" "reply:bench" 1 effectHead "the answer" Nothing [])
  "effects-review-batch" -> do
    publisher <- either throwIO pure (commentPublisher effectsTransport "owner/one" 7 botLogin (\_ _ _ _ _ -> pure ()) Nothing (\_ -> pure ()))
    timedLoop effectIterations (T.intercalate "," . map (publicationStatusText . (.status)) <$> publishFindings publisher 1 effectHead batchFindings "review:bench")
  "effects-cas" -> do
    let graphql = githubGraphQL effectsTransport
    timedLoop effectIterations ("ok" <$ graphql.compareAndSwapRef "owner/one" "refs/heads/feature" effectHead (T.replicate 40 "c"))
  "git-publish" -> withRepository $ \repo -> do
    (diff, changed) <- diffFor repo repo.first "hamsterdan/change/diagnostic" "change:diagnostic:1"
    authority <- newLocalAuthority repo.root repo.remote repo.first
    subject <- localAuthority (authority :: LocalAuthority) >>= (`hostGitPublisher` T.pack repo.remote)
    start <- getMonotonicTime
    published <- publish subject (codingResult repo.first diff changed) "change:diagnostic" (T.replicate 64 "d") repo.first repo.first False
    end <- getMonotonicTime
    pure (end - start, "recovered=" <> T.pack (show published.recovered))
  other -> fail ("unknown workload " <> T.unpack other)

timedLoop :: Int -> IO Text -> IO Measured
timedLoop iterations action = do
  start <- getMonotonicTime
  replicateM_ (iterations - 1) (void action)
  check <- action
  end <- getMonotonicTime
  pure ((end - start) / fromIntegral iterations, check)

-- | @sweep("periodic")@ on a host opened over a fresh copy of the
-- template, after a warm-up sweep when @loaded@.
sweepRun :: Workspace -> Bool -> IO Measured
sweepRun workspace loaded = quietly $ do
  let root = workspace.tmp </> "hs-sweep"
  freshState workspace.template root
  m <- newMulti workspace.snapshot
  reviews <- newIORef []
  host <-
    openHostService
      (doublesConfig root "private-key-secret")
      (serviceOptions (clearRunner reviews) noAgentCustody)
        { clients = Just (doubleClients (multiTransport m))
        , applicationFactory = v5ApplicationFactory
        }
  (`finally` Host.close host) $ do
    when loaded (void (Host.sweep host "periodic"))
    before <- readIORef m.calls
    start <- getMonotonicTime
    reconciled <- Host.sweep host "periodic"
    end <- getMonotonicTime
    after <- readIORef m.calls
    pure (end - start, T.pack (show reconciled) <> " reconciled, " <> T.pack (show (after - before)) <> " provider calls")

effectHead :: Text
effectHead = T.replicate 40 "a"

-- | 100 bot comments carrying other operations' finding markers.
existingComments :: Integer -> [[(Text, Json)]]
existingComments offset =
  [ [ ("id", Int (offset + i))
    , ("html_url", String ("https://example.test/comments/" <> T.pack (show (offset + i))))
    , ("user", Object [("login", String botLogin)])
    , ("body", String ("prose " <> T.pack (show i) <> "\n\n<!-- hamsterdan:finding operation=finding:old" <> T.pack (show i) <> " head=" <> effectHead <> " -->"))
    ]
  | i <- [1 .. 100]
  ]

issueComments, reviewComments :: [[(Text, Json)]]
issueComments = existingComments 0
reviewComments = existingComments 1000

-- | The publication double: 100 issue and 100 review comments that never
-- match, a created comment, an accepted review, and the GraphQL
-- repository identity and @updateRefs@ answers.
effectsTransport :: Transport
effectsTransport =
  Transport
    { request = \method path body -> case (method, path) of
        ("POST", "/repos/owner/one/issues/7/comments") ->
          pure
            ( WireResponse
                201
                ( Object
                    [ ("id", Int 5000)
                    , ("html_url", String "https://example.test/comments/5000")
                    , ("body", maybe (String "") id (body >>= lookup "body"))
                    , ("user", Object [("login", String botLogin)])
                    ]
                )
                Nothing
            )
        ("POST", "/repos/owner/one/pulls/7/reviews") ->
          pure (WireResponse 200 (Object [("id", Int 6000), ("html_url", String "https://example.test/reviews/6000")]) Nothing)
        ("POST", "/graphql") -> case body >>= lookup "variables" of
          Just (Object variables)
            | Just (Object input) <- lookup "input" variables
            , Just identifier <- lookup "clientMutationId" input ->
                pure (WireResponse 200 (Object [("data", Object [("updateRefs", Object [("clientMutationId", identifier)])])]) Nothing)
          _ -> pure (WireResponse 200 (Object [("data", Object [("repository", Object [("id", String "R_kgDOBench")])])]) Nothing)
        _ -> throwIO (PythonException "AssertionError" [])
    , pages = \path ->
        pure $
          if
            | path == "/repos/owner/one/issues/7/comments?per_page=100" -> issueComments
            | path == "/repos/owner/one/pulls/7/comments?per_page=100" -> reviewComments
            | otherwise -> []
    }

batchFindings :: [FindingPublication]
batchFindings = [finding ("finding:b" <> T.pack (show i)) ("Finding " <> T.pack (show i) <> " text") "src/app.py" (10 + i) | i <- [1 .. 8 :: Integer]]

codingResult :: Text -> Text -> [Text] -> CodingResult
codingResult head' diff changed =
  CodingResult
    { kind = "change"
    , repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = head'
    , base = head'
    , ref = "hamsterdan/change/diagnostic"
    , status = "changed"
    , reproductionStatus = "not_attempted"
    , diff
    , changedFiles = changed
    , validationEvidence = [[("command", String "credential-free"), ("status", String "passed")]]
    , proposedCommitMessage = "Apply bounded diagnostic change"
    }

-- ---------------------------------------------------------------------------
-- The comparison

data Workspace = Workspace
  { tmp :: FilePath
  , template :: FilePath
  , snapshot :: Snapshot
  , fake :: Multi
  , githubPort :: Int
  , configured :: FilePath -> Map String String
  , python :: FilePath
  , self :: FilePath
  , benchDirectory :: FilePath
  }

processMain :: [String] -> IO ()
processMain arguments = do
  let runs = case arguments of
        ["--runs", n] -> read n
        _ -> 11
  hSetBuffering stdout LineBuffering
  root <- repoRoot
  python <- upstreamPythonExecutable "hamsterdan"
  self <- getExecutablePath
  temporary <- canonicalizePath =<< getTemporaryDirectory
  bracket (createTempDirectory temporary "hamsterdan-host-process-bench") removePathForcibly $ \created -> do
    tmp <- canonicalizePath created
    privateKey <- BS.readFile (root </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
    (cliPath, nodePath, packagePath) <- piPackageFixture tmp
    let installations = tmp </> "installations.toml"
        template = tmp </> "template"
    BS.writeFile installations "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\"31:owner/one\", \"32:owner/two\"]\n"
    setFileMode installations 0o600
    progress "preparing the template state (20 PRs x 5 heads)"
    snapshot <- prepareTemplate template
    writeInspected (tmp </> "inspected")
    histories <- forM pullRequests $ \n -> length . BC.lines <$> BS.readFile (template </> "applications" </> "44" </> "31" </> show n </> "history.jsonl")
    fake <- newMulti snapshot
    withFakeGitHubIO (fakeRoute fake) $ \githubPort _ -> do
      let configured state =
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
              , ("HAMSTERDAN_PI_CLI_PATH", cliPath)
              , ("HAMSTERDAN_PI_NODE_PATH", nodePath)
              , ("HAMSTERDAN_PI_PACKAGE_ROOT", packagePath)
              , (githubPortVariable, show githubPort)
              , ("COLUMNS", "80")
              ]
          workspace =
            Workspace
              { tmp
              , template
              , snapshot
              , fake
              , githubPort
              , configured
              , python
              , self
              , benchDirectory = root </> "packages" </> "hamsterdan-host" </> "bench"
              }
      load <- uptime
      printf "%d runs per row; History lengths %d to %d records; %s\n\n" runs (minimum histories) (maximum histories) load
      putStrLn "| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell |"
      putStrLn "| --- | --- | ---: | ---: | ---: |"
      forM_ cliWorkloads $ \(label, argv) -> do
        progress label
        (hs, py) <- cliCompare workspace runs argv
        row label "CLI (fresh process)" hs py
      progress "serve"
      (hsServe, pyServe) <- serveCompare workspace runs
      row "`serve` start to the first `200` on `/healthz` (20 Instances)" "process" hsServe pyServe
      progress "socket ingest"
      (hsIngest, pyIngest) <- ingestCompare workspace runs
      row "100 signed deliveries POSTed to `serve` (inactive route)" "socket" hsIngest pyIngest
      withCompanion workspace $ \server ->
        forM_ inProcessWorkloads $ \(name, label) -> do
          progress label
          (_, hsCheck) <- haskellRun workspace name
          (_, pyCheck) <- askRun server name
          unless (hsCheck == pyCheck) $
            fail ("the " <> T.unpack name <> " runs differ:\n  haskell " <> T.unpack hsCheck <> "\n  python  " <> T.unpack pyCheck)
          pairs <- forM [1 .. runs] $ \index -> do
            let hsRun = fst <$> haskellRun workspace name
                pyRun = fst <$> askRun server name
            if even index then (,) <$> hsRun <*> pyRun else (\py hs -> (hs, py)) <$> pyRun <*> hsRun
          let (hs, py) = unzip pairs
          row label ("in process; " <> T.unpack hsCheck) hs py
      after <- uptime
      printf "\n%s\n" after

progress :: String -> IO ()
progress message = hPutStrLn stderr ("  " <> message)

uptime :: IO String
uptime = filter (/= '\n') . BC.unpack . BL.toStrict <$> readProcessStdout_ (proc "uptime" [])

inProcessWorkloads :: [(Text, String)]
inProcessWorkloads =
  [ ("sweep-loaded", "`sweep(\"periodic\")` over 20 loaded Instances")
  , ("sweep-unloaded", "`sweep(\"periodic\")` over 20 unloaded Instances (fresh host)")
  , ("effects-comment", "immutable comment publication (100 bot comments)")
  , ("effects-review-batch", "native review batch of 8 findings (100 issue + 100 review comments)")
  , ("effects-cas", "GraphQL ref compare-and-swap")
  , ("git-publish", "Git publication through the local authority")
  ]

cliWorkloads :: [(String, [String])]
cliWorkloads =
  [ ("`validate` (20 Instances)", ["validate"])
  , ("`inbox` (20 Instances)", ["inbox"])
  , ("`inspect-instance` (a 2001-record History)", ["inspect-instance", "--installation", "44", "--repository", "31", "--pr", "7"])
  ]

-- | The state @inspect-instance@ reads: one Instance whose History has
-- 1000 Activities (every tenth failed), in the shape of the inspection
-- cases of @test_service.py@. The V5 Histories of the template are not
-- inspectable: both sides refuse their first Activity request, whose input
-- carries no @work.operation@ ("Activity operation is malformed").
writeInspected :: FilePath -> IO ()
writeInspected state = do
  let instance' = state </> "applications" </> "44" </> "31" </> "7"
  createDirectoryIfMissing True instance'
  BS.writeFile (instance' </> "binding.json") "{\"instance_id\": \"github:44:31:pr:7\", \"repository\": \"owner/one\", \"pull_request\": 7}"
  BS.writeFile (instance' </> "history.jsonl") . BC.unlines $
    "{\"record\": \"InstanceCreated\", \"instant\": 0}"
      : concat
        [ [ BC.pack (printf "{\"record\": \"ActivityRequested\", \"occurrence\": %d, \"instant\": %d, \"transition\": \"execute.review\", \"activity\": \"review\", \"input\": {\"work\": {\"operation\": \"review:%d\", \"payload\": {\"head\": \"%s\"}}}}" i i i (T.unpack (headOf 1 i)))
          , BC.pack (printf "{\"record\": \"%s\", \"occurrence\": %d, \"instant\": %d.5}" (if i `mod` 10 == 0 then "ActivityFailed" else "ActivityCompleted" :: String) i i)
          ]
        | i <- [1 .. 1000 :: Integer]
        ]

-- | The process environment of a side: the inherited one without any
-- @HAMSTERDAN_@ variable, then the configuration over @state@.
sideEnvironment :: Workspace -> FilePath -> IO [(String, String)]
sideEnvironment workspace state = do
  inherited <- getEnvironment
  let configured = workspace.configured state
  pure (Map.toList configured <> [(k, v) | (k, v) <- inherited, not ("HAMSTERDAN_" `isPrefix` k), k `Map.notMember` configured])
  where
    isPrefix prefix value = take (length prefix) value == prefix

data Side = Haskell | Python
  deriving stock (Eq, Show)

sideName :: Side -> String
sideName = \case
  Haskell -> "hs"
  Python -> "py"

command :: Workspace -> Side -> [String] -> (FilePath, [String])
command workspace side argv = case side of
  Haskell -> (workspace.self, ["--cli"] <> argv <> ["+RTS", "-M2G", "-RTS"])
  Python -> (workspace.python, ["-I", "-B", workspace.benchDirectory </> "cli_child.py"] <> argv)

-- | Reset the fake GitHub and the side's state to the template's
-- (@inspect-instance@ reads its own state, which nothing changes).
resetSide :: Workspace -> Side -> IO FilePath
resetSide workspace side = resetSideFor workspace side []

resetSideFor :: Workspace -> Side -> [String] -> IO FilePath
resetSideFor workspace side argv = do
  let directory = workspace.tmp </> ("cli-" <> sideName side)
      state = directory </> "state"
  createDirectoryIfMissing True directory
  if take 1 argv == ["inspect-instance"]
    then pure (workspace.tmp </> "inspected")
    else do
      freshState workspace.template state
      writeIORef workspace.fake.state workspace.snapshot
      pure state

cliCompare :: Workspace -> Int -> [String] -> IO ([Double], [Double])
cliCompare workspace runs argv = do
  let once side = do
        state <- resetSideFor workspace side argv
        environment <- sideEnvironment workspace state
        let (program, arguments) = command workspace side argv
            config = setWorkingDir (workspace.tmp </> ("cli-" <> sideName side)) (setEnv environment (proc program arguments))
        before <- readIORef workspace.fake.calls
        start <- getMonotonicTime
        (status, out, err) <- readProcess config
        end <- getMonotonicTime
        after <- readIORef workspace.fake.calls
        pure (end - start, (status, BL.toStrict out, after - before), BL.toStrict err)
  (_, hsResult, hsErr) <- once Haskell
  (_, pyResult, pyErr) <- once Python
  unless (hsResult == pyResult) $
    fail ("the CLI runs differ for " <> unwords argv <> ":\n  haskell " <> show hsResult <> " " <> show hsErr <> "\n  python  " <> show pyResult <> " " <> show pyErr)
  let (status, _, _) = hsResult
  unless (status == ExitSuccess) $ fail ("the CLI failed for " <> unwords argv <> ": " <> show hsErr)
  pairs <- forM [1 .. runs] $ \index -> do
    let timed side = (\(t, _, _) -> t) <$> once side
    if even index then (,) <$> timed Haskell <*> timed Python else (\py hs -> (hs, py)) <$> timed Python <*> timed Haskell
  pure (unzip pairs)

freePort :: IO Int
freePort = bracket Warp.openFreePort (close . snd) (pure . fst)

-- | A running @serve@ of one side over its own copy of the template.
startServe :: Workspace -> Side -> IO (Process () () (), Int)
startServe workspace side = do
  state <- resetSide workspace side
  port <- freePort
  environment <- sideEnvironment workspace state
  let (program, arguments) = command workspace side ["serve"]
  out <- openFile (workspace.tmp </> ("serve-" <> sideName side <> ".out")) AppendMode
  err <- openFile (workspace.tmp </> ("serve-" <> sideName side <> ".err")) AppendMode
  process <-
    startProcess
      ( setWorkingDir (workspace.tmp </> ("cli-" <> sideName side)) $
          setStdin nullStream $
            setStdout (useHandleClose out) $
              setStderr (useHandleClose err) $
                setEnv (("HAMSTERDAN_PORT", show port) : environment) (proc program arguments)
      )
  pure (process, port)

healthz :: ByteString
healthz = "GET /healthz HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"

-- | Poll @/healthz@ every millisecond until it answers 200 (60 s at most).
waitHealthy :: Process () () () -> Int -> IO ByteString
waitHealthy process port = go (6000 * 10 :: Int)
  where
    go remaining = do
      answer <- try @SomeException (RawHttp.exchange port healthz)
      case answer of
        Right raw | "HTTP/1.1 200 " `BS.isPrefixOf` raw -> pure raw
        _ -> do
          exited <- getExitCode process
          case exited of
            Just code -> fail ("serve exited before it was healthy: " <> show code)
            Nothing
              | remaining <= 0 -> fail "serve was not healthy within 60 s"
              | otherwise -> threadDelay 1000 >> go (remaining - 1)

-- | The response without its date (h11 and warp both send one).
healthBody :: ByteString -> ByteString
healthBody raw = snd (BS.breakSubstring "\r\n\r\n" raw)

serveCompare :: Workspace -> Int -> IO ([Double], [Double])
serveCompare workspace runs = do
  let once side = do
        start <- getMonotonicTime
        (process, port) <- startServe workspace side
        raw <- waitHealthy process port `onFailure` stopProcess process
        end <- getMonotonicTime
        stopProcess process
        pure (end - start, healthBody raw)
  (_, hsBody) <- once Haskell
  (_, pyBody) <- once Python
  unless (hsBody == pyBody) $ fail ("the /healthz answers differ:\n  haskell " <> show hsBody <> "\n  python  " <> show pyBody)
  pairs <- forM [1 .. runs] $ \index -> do
    let timed side = fst <$> once side
    if even index then (,) <$> timed Haskell <*> timed Python else (\py hs -> (hs, py)) <$> timed Python <*> timed Haskell
  pure (unzip pairs)
  where
    onFailure action cleanup = do
      result <- try action
      case result of
        Right value -> pure value
        Left (problem :: SomeException) -> cleanup >> throwIO problem

-- | Wait until the fake GitHub has seen no call for half a second (the
-- startup sweep's reconciliation is over).
waitQuiet :: Workspace -> IO ()
waitQuiet workspace = go (0 :: Int)
  where
    go waited = do
      before <- readIORef workspace.fake.calls
      threadDelay 500000
      after <- readIORef workspace.fake.calls
      unless (before == after || waited >= 60) (go (waited + 1))

ingestCompare :: Workspace -> Int -> IO ([Double], [Double])
ingestCompare workspace runs = do
  counter <- newIORef (0 :: Int)
  bracket (startServe workspace Haskell) (stopProcess . fst) $ \(hsProcess, hsPort) -> do
    _ <- waitHealthy hsProcess hsPort
    waitQuiet workspace
    bracket (startServe workspace Python) (stopProcess . fst) $ \(pyProcess, pyPort) -> do
      _ <- waitHealthy pyProcess pyPort
      waitQuiet workspace
      let batch port = do
            start <- getMonotonicTime
            forM_ [1 .. 100 :: Int] $ \_ -> do
              n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
              raw <- RawHttp.exchange port (delivery (T.pack (printf "%08x-0000-4000-8000-00000000beef" n)))
              unless ("HTTP/1.1 202 " `BS.isPrefixOf` raw) $ fail ("ingest answered " <> show (BS.take 200 raw))
            end <- getMonotonicTime
            pure (end - start)
      pairs <- forM [0 .. runs] $ \index ->
        if even index then (,) <$> batch hsPort <*> batch pyPort else (\py hs -> (hs, py)) <$> batch pyPort <*> batch hsPort
      -- The first pair warms both servers up.
      pure (unzip (drop 1 pairs))
  where
    body = synchronizeFor 33 7
    delivery identifier =
      BS.concat
        ( ["POST /github/webhooks HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n"]
            <> [TE.encodeUtf8 name <> ": " <> TE.encodeUtf8 value <> "\r\n" | (name, value) <- signedHeaders body identifier "pull_request"]
            <> ["\r\n", body]
        )

-- | The reference's in-process side: @bench/process_bench.py@, one run per
-- request.
data Companion = Companion {toServer :: Handle, fromServer :: Handle}

withCompanion :: Workspace -> (Companion -> IO a) -> IO a
withCompanion workspace use = do
  let spec = workspace.tmp </> "process-bench.json"
  BS.writeFile spec . encode $
    Object
      [ ("template", String (T.pack workspace.template))
      , ("scratch", String (T.pack (workspace.tmp </> "py-inprocess")))
      , ("snapshot", snapshotJson workspace.snapshot)
      , ("iterations", Int (toInteger effectIterations))
      ]
  inherited <- getEnvironment
  let config =
        setEnv inherited $
          setStdin createPipe $
            setStdout createPipe $
              proc workspace.python ["-I", "-B", workspace.benchDirectory </> "process_bench.py", spec]
  withProcessWait_ config $ \process -> do
    let server = Companion (getStdin process) (getStdout process)
    hSetBuffering server.toServer LineBuffering
    ready <- hGetLine server.fromServer
    when (ready /= "ready") $ fail ("process_bench.py: " <> ready)
    result <- use server
    hClose server.toServer
    pure result

askRun :: Companion -> Text -> IO Measured
askRun server name = do
  hPutStrLn server.toServer ("run " <> T.unpack name)
  answer <- hGetLine server.fromServer
  case parseJson pythonLoads (BC.pack answer) of
    Right (Object [("check", String check), ("seconds", Float seconds)]) -> pure (seconds, check)
    Right (Object [("check", String check), ("seconds", Int seconds)]) -> pure (fromInteger seconds, check)
    _ -> fail ("process_bench.py answered " <> answer)

row :: String -> String -> [Double] -> [Double] -> IO ()
row label shape hs py =
  printf
    "| %s | %s | %s (%s) | %s (%s) | %.2f× |\n"
    label
    shape
    (duration (median hs))
    (duration (minimum hs))
    (duration (median py))
    (duration (minimum py))
    (median py / median hs)

median :: [Double] -> Double
median xs = let sorted = sort xs in sorted !! (length sorted `div` 2)

duration :: Double -> String
duration seconds
  | seconds >= 1 = printf "%.2f s" seconds
  | seconds >= 1.0e-3 = printf "%.2f ms" (seconds * 1000)
  | otherwise = printf "%.1f µs" (seconds * 1.0e6)
