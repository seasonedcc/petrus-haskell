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
import Hamsterdan.GitHub.Client (AppCredentials (..), ClientOptions (..), newAppClients)
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Cli (inspectInstance)
import Hamsterdan.Host.Python (ValueError (..))
import Hamsterdan.Host.Service (HostService (..), ServiceOptions (..), gitHubHostClients, noAgentCustody, openHostService, serviceOptions, v5ApplicationFactory)
import Hamsterdan.Host.Service qualified as Host
import Petrus.Json (Json (..), compact, defaultDumps, dumps, dumpsText, parseJson, pythonLoads)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
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
phaseTwo =
  [ Report [d1]
  , Head secondHead
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

-- | Run one phase on a state directory with one implementation.
drive :: Side -> Network -> FilePath -> ProviderState -> [Step] -> IO Json
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
          one <- drive first Doubles root start phaseOne
          afterOne <- referenceDump root
          two <- drive second Doubles root (providerAfter one) phaseTwo
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

  it "makes the same GitHub requests as the reference, header for header and body for body" . withTempRoot $ \tmp -> do
    repo <- repoRoot
    pem <- TE.decodeUtf8 <$> BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
    let journey side = do
          state <- FakeState <$> newIORef firstHead <*> newIORef []
          withFakeGitHubIO (v5GitHub state) $ \port recorded -> do
            let root = tmp </> ("github-" <> show side)
                network = GitHubAt port pem
                untouched = ProviderState firstHead []
            one <- drive side network root untouched phaseOne
            callsOne <- takeCalls recorded
            writeIORef state.fakeHead secondHead
            two <- drive side network root untouched phaseTwo
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
          <> unlines [show n <> "\n  reference: " <> show a <> "\n  haskell:   " <> show b | (n, a, b) <- take 12 differing]
      )

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

pythonDrive :: Network -> FilePath -> ProviderState -> [Step] -> IO Json
pythonDrive network root (ProviderState sha comments) steps = do
  let github = case network of
        Doubles -> []
        GitHubAt port pem -> [("github_port", Int (toInteger port)), ("private_key", String pem)]
      document = Object ([("head", String sha), ("comments", Array comments), ("steps", Array (map stepJson steps))] <> github)
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

haskellDrive :: Network -> FilePath -> ProviderState -> [Step] -> IO Json
haskellDrive network root (ProviderState sha initialComments) steps = do
  provider <- newProvider sha [members | Object members <- initialComments]
  reviews <- newIORef []
  let runner = clearRunner reviews
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
      (serviceOptions runner noAgentCustody)
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
          statuses <- traverse (\delivery -> (delivery,) . maybe Null String <$> Custody.status host.custody delivery) deliveries
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
