-- | State interop with the reference host, both ways.
--
-- The same journey runs through the Python host
-- (@differential/state_reference.py@) and through this one, over the real
-- V5 application, the @V5Provider@ GitHub double of @test_service.py@, and
-- the clear-review runner. It runs in two phases, each in its own process
-- (a host closed and reopened on the same state directory): phase one opens
-- the PR's Instance; phase two moves the head, delivers again, sweeps, and
-- converges. All four pairings run: Python then Python, Haskell then
-- Haskell, Python then Haskell, Haskell then Python.
--
-- Every pairing must produce the same provider calls, the same comments,
-- the same agent calls, the same custody and subject reports, and the same
-- state directory: every file under it (History, @binding.json@, and the
-- @webhooks@, @routes@, @runnable@, @timers@, @review-requests@ and
-- @activity-dispatch@ databases, schema text and rows) as the reference
-- reads it back, with only the Worker claimant's random identity and
-- wall-clock instants normalized.
--
-- The agent journey is the same two phases with the real agent in place of
-- the clear-review runner: each host composes it the way @serve@ does
-- (the Pi installation from the environment, @compose_agent@, the
-- @agent-routes.sqlite3@ store, the workspace receiver, the owned Pi A2
-- runtime under @pi-a2/@, and the Pi native runner), over Petrus's
-- deterministic scripted Pi runtime, with the workspace cloned from a local
-- repository whose commits are the PR's base and heads. Each phase is one
-- full review turn (clone, review inputs, prompt, scripted turn, result
-- validation, runtime bodies and operation ledger, route settlement), and
-- the second phase resumes the agent state the first left, in either
-- language. The comparison now covers @agent-routes.sqlite3@ and
-- everything under @pi-a2/@ too; only the runtime host's random lifecycle
-- identity is normalized besides the above, and every pairing runs on the
-- same absolute state path (the working-directory binding is a digest of
-- it).
module InteropSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX (getPOSIXTime)
import FakeGitHub (Recorded (..), comparableCall, takeCalls, withFakeGitHubIO)
import Hamsterdan.Agents.Pi (defaultPiRunnerOptions, newPiNativeRunner, piA2Runtime, piAgentRunner)
import Hamsterdan.Agents.Pi qualified as Pi
import Hamsterdan.Agents.Protocol (AgentRunner (..), Invocation (..), ReviewRequest (..))
import Hamsterdan.GitHub.Client (AppCredentials (..), ClientOptions (..), newAppClients)
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agents (AgentSeams (..), composeHostAgent, newOwnedAgent, productionAgentSeams)
import Hamsterdan.Host.Cli (inspectInstance)
import Hamsterdan.Host.PiWorkspace (gitPiWorkspaceProvider)
import Hamsterdan.Host.Scripted (clearReviewText, deterministicRepository, localClone, scriptedPiA2Hooks)
import Hamsterdan.Host.Python (ValueError (..))
import Hamsterdan.Host.Service (HostService (..), ServiceOptions (..), gitHubHostClients, noAgentCustody, openHostService, serviceOptions, v5ApplicationFactory)
import Hamsterdan.Host.Service qualified as Host
import Petrus.Json (Json (..), compact, defaultDumps, dumps, dumpsText, parseJson, pythonLoads)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (renameDirectory)
import System.FilePath ((</>))
import System.Process.Typed
import Test.Hspec
import TestSupport (withTempRoot)
import V5Doubles

-- | One step of a journey (the @steps@ of @state_reference.py drive@).
data Step
  = Activate
  | Deliver Text Text ByteString
  | Head Text
  | Converge
  | Sweep Text
  | Report [Text]

stepJson :: Step -> Json
stepJson = \case
  Activate -> Object [("op", String "activate")]
  Deliver delivery event body ->
    Object [("op", String "deliver"), ("delivery", String delivery), ("event", String event), ("body", String (TE.decodeUtf8 body))]
  Head sha -> Object [("op", String "head"), ("head", String sha)]
  Converge -> Object [("op", String "converge")]
  Sweep trigger -> Object [("op", String "sweep"), ("trigger", String trigger)]
  Report deliveries -> Object [("op", String "report"), ("deliveries", Array (map String deliveries))]

-- | Where the provider stands when a phase starts: the head and the
-- comments already on the PR.
data ProviderState = ProviderState Text [Json]

firstHead, secondHead :: Text
firstHead = T.replicate 40 "a"
secondHead = T.replicate 40 "c"

d1, d2, d3 :: Text
d1 = "11111111-1111-4111-8111-111111111111"
d2 = "22222222-2222-4222-8222-222222222222"
d3 = "33333333-3333-4333-8333-333333333333"

synchronize :: ByteString
synchronize =
  "{\"action\": \"synchronize\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"pull_request\": {\"number\": 7}}"

workflowRequested :: ByteString
workflowRequested =
  "{\"action\": \"requested\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"workflow_run\": {\"pull_requests\": [{\"number\": 7}]}}"

phaseOne :: [Step]
phaseOne = [Activate, Deliver d1 "pull_request" synchronize, Converge, Report [d1]]

phaseTwo :: [Step]
phaseTwo = phaseTwoAt secondHead

-- | Phase two, moving the head to the given commit.
phaseTwoAt :: Text -> [Step]
phaseTwoAt moved =
  [ Report [d1]
  , Head moved
  , Deliver d2 "pull_request" synchronize
  , Converge
  , Deliver d3 "workflow_run" workflowRequested
  , Converge
  , Sweep "startup"
  , Converge
  , Sweep "periodic"
  , Converge
  , Report [d1, d2, d3]
  ]

data Side = Python | Haskell
  deriving stock (Eq, Show)

-- | What the host talks to: the @V5Provider@ double behind the GitHub
-- transport, or the real client stack against the fake GitHub on a local
-- port (with the App's PEM).
data Network = Doubles | GitHubAt Int Text

-- | The real agent over the scripted Pi runtime: the local repository the
-- workspace is cloned from, the PR's base commit in it, and the output of
-- each scripted turn of the phase.
data Agent = Agent
  { repository :: FilePath
  , base :: Text
  , turns :: [Text]
  }

-- | Absolute Pi installation paths: @from_environment@ requires them, and
-- the scripted runtime never runs them.
installationPaths :: [(Text, Text)]
installationPaths =
  [ ("HAMSTERDAN_PI_CLI_PATH", "/opt/pi/cli.js")
  , ("HAMSTERDAN_PI_NODE_PATH", "/opt/pi/node")
  , ("HAMSTERDAN_PI_PACKAGE_ROOT", "/opt/pi/package")
  ]

-- | What @serve@ reads from the environment for the agent.
agentEnvironment :: [(Text, Text)]
agentEnvironment =
  [ ("HAMSTERDAN_PI_PROVIDER", "anthropic")
  , ("HAMSTERDAN_PI_MODEL", "claude-sonnet-4-5")
  , ("HAMSTERDAN_PI_API_KEY", "synthetic-direct-authority")
  ]
    <> installationPaths

-- | Run one phase on a state directory with one implementation.
drive :: Side -> Network -> Maybe Agent -> FilePath -> ProviderState -> [Step] -> IO Json
drive Python = pythonDrive
drive Haskell = haskellDrive

-- | The phase's outcome, and where it left the provider.
providerAfter :: Json -> ProviderState
providerAfter (Object members)
  | Just (String sha) <- lookup "head" members
  , Just (Array comments) <- lookup "comments" members =
      ProviderState sha comments
providerAfter other = error ("no provider state in " <> show other)

spec :: Spec
spec = describe "state interop with the reference host" $ do
  it "resumes each other's state: every pairing of the two phases agrees with Python, file by file" . withTempRoot $ \tmp -> do
    let start = ProviderState firstHead []
        run first second = do
          let root = tmp </> (show first <> "-" <> show second)
          one <- drive first Doubles Nothing root start phaseOne
          afterOne <- referenceDump root
          two <- drive second Doubles Nothing root (providerAfter one) phaseTwo
          afterTwo <- referenceDump root
          pure (one, afterOne, two, afterTwo)
    (pOne, pDumpOne, pTwo, pDumpTwo) <- run Python Python
    -- The journey does real work in both phases: the first opens the
    -- Instance, reviews the first head and posts the dashboard; the second
    -- reviews the moved head on the state the first left behind.
    calls pOne `shouldSatisfy` (not . null)
    calls pTwo `shouldSatisfy` (not . null)
    reviewedHeads pOne `shouldBe` [firstHead]
    reviewedHeads pTwo `shouldBe` [secondHead]
    finalStatuses pTwo `shouldBe` [(d, String "terminal") | d <- [d1, d2, d3]]
    forM_ [(Haskell, Haskell), (Python, Haskell), (Haskell, Python)] $ \(first, second) -> do
      (one, dumpOne, two, dumpTwo) <- run first second
      let label = show first <> " then " <> show second
      sameJson (label <> ": phase one") pOne one
      sameJson (label <> ": state after phase one") pDumpOne dumpOne
      sameJson (label <> ": phase two") pTwo two
      sameJson (label <> ": state after phase two") pDumpTwo dumpTwo

  it "resumes each other's agent state: a scripted Pi review turn per phase through the composed agent, every pairing" . withTempRoot $ \tmp -> do
    (base, firstCommit, secondCommit) <- deterministicRepository (tmp </> "repository")
    let agent epoch commit = Agent (tmp </> "repository") base [clearReview epoch commit base]
        -- One state path for every pairing, each moved aside when done.
        root = tmp </> "state"
        run first second = do
          one <- drive first Doubles (Just (agent 1 firstCommit)) root (ProviderState firstCommit []) phaseOne
          afterOne <- referenceDump root
          two <- drive second Doubles (Just (agent 2 secondCommit)) root (providerAfter one) (phaseTwoAt secondCommit)
          afterTwo <- referenceDump root
          renameDirectory root (tmp </> (show first <> "-" <> show second))
          pure (one, afterOne, two, afterTwo)
    (pOne, pDumpOne, pTwo, pDumpTwo) <- run Python Python
    -- Each phase is one real agent turn whose clear result reaches the
    -- dashboard, and the agent state is on disk for the next phase.
    reviewedHeads pOne `shouldBe` [firstCommit]
    reviewedHeads pTwo `shouldBe` [secondCommit]
    dashboard pOne `shouldSatisfy` T.isInfixOf "clear \x00b7 0 findings"
    dashboard pTwo `shouldSatisfy` T.isInfixOf "clear \x00b7 0 findings"
    finalStatuses pTwo `shouldBe` [(d, String "terminal") | d <- [d1, d2, d3]]
    forM_ ["agent-routes.sqlite3", "pi-a2/installation", "pi-a2/runtime-host/bodies.sqlite3", "pi-a2/runtime-host/operations.sqlite3"] $ \file ->
      fileNames pDumpTwo `shouldContain` [file]
    forM_ [(Haskell, Haskell), (Python, Haskell), (Haskell, Python)] $ \(first, second) -> do
      (one, dumpOne, two, dumpTwo) <- run first second
      let label = "agent journey, " <> show first <> " then " <> show second
      sameJson (label <> ": phase one") pOne one
      sameJson (label <> ": state after phase one") pDumpOne dumpOne
      sameJson (label <> ": phase two") pTwo two
      sameJson (label <> ": state after phase two") pDumpTwo dumpTwo

  it "makes the same GitHub requests as the reference, header for header and body for body" . withTempRoot $ \tmp -> do
    repo <- repoRoot
    pem <- TE.decodeUtf8 <$> BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
    let journey side = do
          state <- FakeState <$> newIORef firstHead <*> newIORef []
          withFakeGitHubIO (v5GitHub state) $ \port recorded -> do
            let root = tmp </> ("github-" <> show side)
                network = GitHubAt port pem
                untouched = ProviderState firstHead []
            one <- drive side network Nothing root untouched phaseOne
            callsOne <- takeCalls recorded
            writeIORef state.fakeHead secondHead
            two <- drive side network Nothing root untouched phaseTwo
            callsTwo <- takeCalls recorded
            dumped <- referenceDump root
            comments <- readIORef state.fakeComments
            pure (one, callsOne, two, callsTwo, dumped, comments)
    (pOne, pCallsOne, pTwo, pCallsTwo, pDump, pComments) <- journey Python
    -- The reference's journey through the real client stack does the work:
    -- an installation token, the PR reads, the dashboard comment.
    map (\call -> (call.method, call.target)) pCallsOne
      `shouldContain` [("POST", "/app/installations/44/access_tokens"), ("GET", "/repos/owner/one/pulls/7")]
    length pComments `shouldBe` 1
    reviewedHeads pTwo `shouldBe` [secondHead]
    (hOne, hCallsOne, hTwo, hCallsTwo, hDump, hComments) <- journey Haskell
    sameJson "GitHub requests in phase one" (requests pCallsOne) (requests hCallsOne)
    sameJson "GitHub requests in phase two" (requests pCallsTwo) (requests hCallsTwo)
    sameJson "phase one" pOne hOne
    sameJson "phase two" pTwo hTwo
    sameJson "state" pDump hDump
    sameJson "comments on the PR" (Array (map Object pComments)) (Array (map Object hComments))
  where
    requests = Array . map (request . comparableCall)
    request call =
      Object
        [ ("method", String (TE.decodeUtf8 call.method))
        , ("target", String (TE.decodeUtf8 call.target))
        , ("headers", Array [Array [String (TE.decodeUtf8 n), String (TE.decodeUtf8 v)] | (n, v) <- call.headers])
        , ("body", String (TE.decodeUtf8With lenientDecode call.body))
        ]
    calls = \case
      Object members | Just (Array items) <- lookup "calls" members -> items
      _ -> []
    reviewedHeads = \case
      Object members | Just (Array items) <- lookup "reviews" members -> [sha | Array (_ : String sha : _) <- items]
      _ -> []
    dashboard = \case
      Object members | Just (Array (Object comment : _)) <- lookup "comments" members, Just (String body) <- lookup "body" comment -> body
      _ -> ""
    fileNames = \case
      Object members -> map fst members
      _ -> []
    finalStatuses = \case
      Object members
        | Just (Array reports) <- lookup "reports" members
        , Object final : _ <- reverse reports
        , Just (Object statuses) <- lookup "status" final ->
            statuses
      _ -> []

-- | Equal JSON, reported as the first differing lines of the canonical
-- (sorted, indented) spelling.
sameJson :: String -> Json -> Json -> IO ()
sameJson label expected actual = do
  let canonical value = T.lines (either (error . show) id (dumpsText defaultDumps {sortKeys = True, indent = Just 1, ensureAscii = False} value))
      left = canonical expected
      right = canonical actual
  unless (left == right) $ do
    let width = max (length left) (length right)
        pad xs = map Just xs <> replicate (width - length xs) Nothing
        differing = [(n, a, b) | (n, a, b) <- zip3 [1 :: Int ..] (pad left) (pad right), a /= b]
    expectationFailure
      ( label
          <> " differs from the reference at "
          <> show (length differing)
          <> " lines; first:\n"
          <> unlines [show n <> "\n  reference: " <> excerpt a b <> "\n  haskell:   " <> excerpt b a | (n, a, b) <- take 12 differing]
      )
  where
    -- A long line around its first difference.
    excerpt mine theirs = case (mine, theirs) of
      (Just x, Just y) | T.length x > 400 ->
        let at = length (takeWhile id (zipWith (==) (T.unpack x) (T.unpack y)))
         in show at <> ": " <> show (T.take 400 (T.drop (max 0 (at - 150)) x))
      _ -> show mine

-- ---------------------------------------------------------------------------
-- The reference

reference :: [String] -> ByteString -> IO ByteString
reference arguments input = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-host" </> "differential" </> "state_reference.py"
      config = setStdin (byteStringInput (BL.fromStrict input)) (proc executable (["-I", "-B", script] <> arguments))
  (status, out, err) <- readProcess config
  unless (status == ExitSuccess) $
    expectationFailure ("the reference state driver failed: " <> BC.unpack (BL.toStrict err))
  -- The Petrus Worker reports each processed Activity on stdout; the
  -- driver's document is the last line.
  pure (lastLine (BL.toStrict out))
  where
    lastLine bytes = case reverse (filter (not . BC.null) (BC.lines bytes)) of
      line : _ -> line
      [] -> ""

parsed :: ByteString -> IO Json
parsed bytes = case parseJson pythonLoads bytes of
  Right value -> pure value
  Left problem -> expectationFailure ("unreadable reference output: " <> problem) >> pure Null

pythonDrive :: Network -> Maybe Agent -> FilePath -> ProviderState -> [Step] -> IO Json
pythonDrive network agent root (ProviderState sha comments) steps = do
  let github = case network of
        Doubles -> []
        GitHubAt port pem -> [("github_port", Int (toInteger port)), ("private_key", String pem)]
      agentMembers = case agent of
        Nothing -> []
        Just selected ->
          [ ("base", String selected.base)
          , ( "agent"
            , Object
                ( [ ("turns", Array (map String selected.turns))
                  , ("repository", String (T.pack selected.repository))
                  ]
                    <> [(short, String value) | (name, value) <- installationPaths, Just short <- [lookup name shortNames]]
                )
            )
          ]
      shortNames = [("HAMSTERDAN_PI_CLI_PATH", "cli"), ("HAMSTERDAN_PI_NODE_PATH", "node"), ("HAMSTERDAN_PI_PACKAGE_ROOT", "package")]
      document = Object ([("head", String sha), ("comments", Array comments), ("steps", Array (map stepJson steps))] <> github <> agentMembers)
  reference ["drive", root] (either (error . show) id (dumps compact document)) >>= parsed

-- | @state_reference.py dump@: the state directory as the reference reads it.
referenceDump :: FilePath -> IO Json
referenceDump root = reference ["dump", root] "" >>= parsed

-- ---------------------------------------------------------------------------
-- The fake GitHub

data FakeState = FakeState
  { fakeHead :: IORef Text
  , fakeComments :: IORef [[(Text, Json)]]
  }

-- | @V5Provider@'s answers over HTTP, plus installation 44's token.
v5GitHub :: FakeState -> Recorded -> IO (Maybe (Int, [(ByteString, ByteString)], ByteString))
v5GitHub state call = do
  headSha <- readIORef state.fakeHead
  let path = TE.decodeUtf8 call.target
      json status value = pure (Just (status, [], either (error . show) id (dumps compact value)))
  case (call.method, path) of
    ("POST", "/app/installations/44/access_tokens") ->
      json 201 (Object [("token", String "ghs_installation44"), ("expires_at", String "2099-01-01T00:00:00Z"), ("repository_selection", String "selected")])
    ("GET", "/repos/owner/one/pulls/7") -> json 200 (pullRequest headSha)
    ("GET", "/repos/owner/one/git/ref/heads/main") -> json 200 (Object [("object", Object [("sha", String baseSha)])])
    ("GET", p)
      | p == "/repos/owner/one/compare/" <> baseSha <> "..." <> headSha ->
          json 200 (Object [("status", String "ahead"), ("behind_by", Int 0)])
    ("GET", "/repos/owner/one/pulls/7/requested_reviewers") -> json 200 (Object [("users", Array [])])
    ("GET", "/repos/owner/one/pulls/7/reviews?per_page=100") -> json 200 (Array [])
    ("GET", p)
      | "/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?" `T.isPrefixOf` p ->
          json 200 (Object [("total_count", Int 0), ("workflow_runs", Array [])])
    ("POST", "/graphql") -> json 200 noReviewThreads
    ("GET", "/repos/owner/one/issues/7/comments?per_page=100") -> readIORef state.fakeComments >>= json 200 . Array . map Object
    ("POST", "/repos/owner/one/issues/7/comments") | Just members <- body -> do
      n <- length <$> readIORef state.fakeComments
      let comment = newComment (toInteger n + 1) members
      modifyIORef' state.fakeComments (<> [comment])
      json 201 (Object comment)
    ("PATCH", p)
      | Just identifierText <- T.stripPrefix "/repos/owner/one/issues/comments/" p
      , Just members <- body -> do
          let identifier = Int (read (T.unpack identifierText))
          modifyIORef' state.fakeComments (map (editComment identifier members))
          found <- find (\comment -> lookup "id" comment == Just identifier) <$> readIORef state.fakeComments
          maybe (pure Nothing) (json 200 . Object) found
    _ -> pure Nothing
  where
    body = case parseJson pythonLoads call.body of
      Right (Object members) -> Just members
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- The same journey through this host

haskellDrive :: Network -> Maybe Agent -> FilePath -> ProviderState -> [Step] -> IO Json
haskellDrive network agent root (ProviderState sha initialComments) steps = do
  provider <- newProviderOn (maybe baseSha (.base) agent) sha [members | Object members <- initialComments]
  reviews <- newIORef []
  (runner, custody) <- case agent of
    Nothing -> pure (clearRunner reviews, noAgentCustody)
    Just selected -> do
      owned <- newOwnedAgent
      (composed, custody) <- composeHostAgent (scriptedAgent selected) owned agentEnvironment (pure ()) root
      pure (recordingRunner reviews composed, custody)
  (config, clients) <- case network of
    Doubles -> pure (doublesConfig root "private-key-secret", doubleClients (providerTransport provider))
    GitHubAt port pem -> do
      exchange <- newPlainExchangeAt "127.0.0.1" port
      appClients <-
        newAppClients
          AppCredentials {appId = 17, clientId = "Iv1.client-secret-looking", privateKey = pem}
          ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
      pure (doublesConfig root pem, gitHubHostClients appClients)
  host <-
    openHostService
      config
      (serviceOptions runner custody)
        { clients = Just clients
        , applicationFactory = v5ApplicationFactory
        }
  reports <- newIORef []
  let report value = modifyIORef' reports (<> [value])
      step = \case
        Activate -> activate host
        Deliver delivery event body -> do
          receipt <- Custody.receive host.custody (signedHeaders body delivery event) body
          waiting <- filter (\item -> item.deliveryId == delivery) <$> Custody.pending host.custody 100 Nothing
          report (Object [("pending", Int (toInteger (length waiting))), ("receipt", String (dispositionName receipt.disposition))])
          case waiting of
            item : _ -> Host.process host item
            [] -> pure ()
        Head next -> writeIORef provider.head next
        Converge -> converge (1 :: Int)
        Sweep trigger -> do
          swept <- Host.sweep host trigger
          report (Object [("swept", Int (toInteger swept))])
        Report deliveries -> do
          statuses <- traverse (\delivery -> (delivery,) . maybe Null (String . Custody.inboxStatusText) <$> Custody.status host.custody delivery) deliveries
          counts <- Custody.counts host.custody
          subject <- Host.subjectState host 44 31 7
          inspected <-
            try (inspectInstance root 44 31 7) >>= \case
              Right value -> pure value
              Left (ValueError message) -> pure (Object [("refused", String message)])
          report $
            Object
              [ ("status", Object statuses)
              , ("counts", Object [(k, Int (toInteger v)) | (k, v) <- Map.toList counts])
              , ("subject", maybe Null id subject)
              , ("inspect", inspected)
              ]
      converge rounds = do
        unless (rounds <= 50) $ expectationFailure "the host did not converge"
        processed <- Host.pump host 20
        unless (processed == 0) $ converge (rounds + 1)
  mapM_ step steps `onFailure` Host.close host
  Host.close host
  finalHead <- readIORef provider.head
  finalCalls <- readIORef provider.calls
  finalComments <- readIORef provider.comments
  finalReviews <- readIORef reviews
  finalReports <- readIORef reports
  pure $
    Object
      [ ("calls", Array finalCalls)
      , ("head", String finalHead)
      , ("comments", Array (map Object finalComments))
      , ("reviews", Array finalReviews)
      , ("reports", Array finalReports)
      ]
  where
    onFailure action cleanup = do
      outcome <- try @SomeException action
      either (\problem -> cleanup >> throwIO problem) pure outcome

-- | 'composeHostAgent' with the substitutions of @state_reference.py@'s
-- @compose_real_agent@ ("Hamsterdan.Host.Scripted"), and its runner's
-- @poll_interval=AUTHORITY_POLL_SECONDS@.
scriptedAgent :: Agent -> AgentSeams
scriptedAgent selected =
  productionAgentSeams
    { hooks = scriptedPiA2Hooks selected.turns
    , workspaces = localClone selected.repository . gitPiWorkspaceProvider
    , selectRunner = \host provider ->
        either (throwIO . userError . T.unpack) (pure . piAgentRunner) $
          newPiNativeRunner (piA2Runtime host) provider defaultPiRunnerOptions {Pi.pollInterval = authorityPollSeconds}
    }

-- | How long the runner waits for a turn to settle before it asks the host
-- again whether the attempt is current (@AUTHORITY_POLL_SECONDS@ of
-- @state_reference.py@). Every such check reads the provider's authority
-- (the PR, the base ref, rules, protection), and at the production 0.1 s
-- their number grows with how long the scripted turn takes on the machine,
-- in either language: a slow reference turn once made four more provider
-- calls than the Haskell host. Waiting returns as soon as the turn settles,
-- so a bound no turn here approaches leaves the checks every turn makes,
-- and the provider calls depend on the steps alone.
authorityPollSeconds :: Double
authorityPollSeconds = 3600

-- | The agent runner, recording each review as the clear-review runner does.
recordingRunner :: IORef [Json] -> AgentRunner -> AgentRunner
recordingRunner reviews runner =
  AgentRunner
    { review = \url request invocation -> do
        modifyIORef' reviews (<> [Array [String url, String request.head, String invocation.operation, Int invocation.attempt]])
        runner.review url request invocation
    , converse = runner.converse
    , code = runner.code
    }

-- | A clear review of PR 7 at the given incarnation (the request's epoch)
-- and head: the scripted Pi turn's final text.
clearReview :: Integer -> Text -> Text -> Text
clearReview = clearReviewText "owner/one" 7
