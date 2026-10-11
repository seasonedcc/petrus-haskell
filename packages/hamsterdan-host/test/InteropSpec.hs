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
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol (AgentRunner (..), Invocation (..), ReviewRequest (..), ReviewResult (..))
import Hamsterdan.GitHub.Models (Transport (..), WireResponse (..))
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Cli (inspectInstance)
import Hamsterdan.Host.Python (ValueError (..))
import Hamsterdan.Host.Service (HostService (..), ServiceOptions (..), noAgentCustody, openHostService, serviceOptions, v5ApplicationFactory)
import Hamsterdan.Host.Service qualified as Host
import IngressApplicationSpec (objectRunner)
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Json (Json (..), compact, defaultDumps, dumps, dumpsText, parseJson, pythonLoads)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import ServiceSupport (hostClientsOf, hostConfig, newFakeClients, signed)
import ServiceSupport qualified
import System.FilePath ((</>))
import System.Process.Typed
import Test.Hspec
import TestSupport (withTempRoot)

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

-- | Run one phase on a state directory with one implementation.
drive :: Side -> FilePath -> ProviderState -> [Step] -> IO Json
drive Python root state steps = pythonDrive root state steps
drive Haskell root state steps = haskellDrive root state steps

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
          one <- drive first root start phaseOne
          afterOne <- referenceDump root
          two <- drive second root (providerAfter one) phaseTwo
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
  where
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

pythonDrive :: FilePath -> ProviderState -> [Step] -> IO Json
pythonDrive root (ProviderState sha comments) steps = do
  let document = Object [("head", String sha), ("comments", Array comments), ("steps", Array (map stepJson steps))]
  reference ["drive", root] (either (error . show) id (dumps compact document)) >>= parsed

-- | @state_reference.py dump@: the state directory as the reference reads it.
referenceDump :: FilePath -> IO Json
referenceDump root = reference ["dump", root] "" >>= parsed

-- ---------------------------------------------------------------------------
-- The same journey through this host

data Provider = Provider
  { head :: IORef Text
  , calls :: IORef [Json]
  , comments :: IORef [[(Text, Json)]]
  }

baseSha :: Text
baseSha = T.replicate 40 "b"

-- | @V5Provider@ of @state_reference.py@ (the @test_service.py@ double
-- plus comment edits).
providerTransport :: Provider -> Transport
providerTransport provider =
  Transport
    { request = \method path body -> do
        record [method, path]
        headSha <- readIORef provider.head
        answer headSha method path body
    , pages = \path -> do
        record ["PAGES", path]
        if path == "/repos/owner/one/issues/7/comments?per_page=100"
          then readIORef provider.comments
          else pure []
    }
  where
    record parts = modifyIORef' provider.calls (<> [Array (map String parts)])
    ok value = pure (WireResponse 200 value Nothing)
    answer headSha method path body = case (method, path) of
      ("GET", "/repos/owner/one/pulls/7") ->
        ok $
          Object
            [ ("state", String "open")
            , ("draft", Bool False)
            , ("mergeable", Bool True)
            , ("mergeable_state", String "clean")
            , ("merged", Bool False)
            , ("html_url", String "https://example.test/owner/one/pull/7")
            , ("user", Object [("login", String "author")])
            , ("head", Object [("sha", String headSha), ("ref", String "feature"), ("repo", Object [("full_name", String "owner/one")])])
            , ("base", Object [("sha", String baseSha), ("ref", String "main")])
            ]
      ("GET", "/repos/owner/one/git/ref/heads/main") -> ok (Object [("object", Object [("sha", String baseSha)])])
      ("GET", "/repos/owner/one/rules/branches/main") -> pure (WireResponse 404 (Object []) Nothing)
      ("GET", "/repos/owner/one/branches/main/protection") -> pure (WireResponse 404 (Object []) Nothing)
      ("GET", p)
        | p == "/repos/owner/one/compare/" <> baseSha <> "..." <> headSha ->
            ok (Object [("status", String "ahead"), ("behind_by", Int 0)])
      ("GET", "/repos/owner/one/pulls/7/requested_reviewers") -> ok (Object [("users", Array [])])
      ("GET", p)
        | "/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?" `T.isPrefixOf` p ->
            ok (Object [("total_count", Int 0), ("workflow_runs", Array [])])
      ("POST", "/graphql") ->
        ok $
          Object
            [ ( "data"
              , Object
                  [ ( "repository"
                    , Object
                        [ ( "pullRequest"
                          , Object
                              [ ( "reviewThreads"
                                , Object
                                    [ ("nodes", Array [])
                                    , ("pageInfo", Object [("hasNextPage", Bool False), ("endCursor", Null)])
                                    ]
                                )
                              ]
                          )
                        ]
                    )
                  ]
              )
            ]
      ("POST", "/repos/owner/one/issues/7/comments")
        | Just members <- body -> do
            n <- length <$> readIORef provider.comments
            let identifier = toInteger n + 1
                comment =
                  [ ("id", Int identifier)
                  , ("html_url", String ("https://example.test/comments/" <> T.pack (show identifier)))
                  , ("body", maybe (String "") id (lookup "body" members))
                  , ("user", Object [("login", String "hamsterdan-test[bot]")])
                  ]
            modifyIORef' provider.comments (<> [comment])
            pure (WireResponse 201 (Object comment) Nothing)
      ("PATCH", p)
        | Just identifierText <- T.stripPrefix "/repos/owner/one/issues/comments/" p
        , Just members <- body -> do
            let identifier = Int (read (T.unpack identifierText))
                edited comment
                  | lookup "id" comment == Just identifier =
                      [(k, if k == "body" then maybe (String "") id (lookup "body" members) else v) | (k, v) <- comment]
                  | otherwise = comment
            modifyIORef' provider.comments (map edited)
            found <- find (\comment -> lookup "id" comment == Just identifier) <$> readIORef provider.comments
            case found of
              Just comment -> ok (Object comment)
              Nothing -> throwIO (PythonException "AssertionError" [])
      _ -> throwIO (PythonException "AssertionError" [])

haskellDrive :: FilePath -> ProviderState -> [Step] -> IO Json
haskellDrive root (ProviderState sha initialComments) steps = do
  provider <-
    Provider
      <$> newIORef sha
      <*> newIORef []
      <*> newIORef [members | Object members <- initialComments]
  reviews <- newIORef []
  let runner =
        objectRunner
          { review = \url request inv -> do
              modifyIORef' reviews (<> [Array [String url, String request.head, String inv.operation, Int inv.attempt]])
              pure (ReviewResult request.repository request.pullRequest request.epoch request.head request.base "clear" [] [])
          }
  clients <- newFakeClients
  writeIORef clients.operationTransport (Just (providerTransport provider))
  host <-
    openHostService
      (hostConfig root [(31, "owner/one"), (32, "owner/two")] mempty)
      (serviceOptions runner noAgentCustody)
        { clients = Just (hostClientsOf clients)
        , applicationFactory = v5ApplicationFactory
        }
  reports <- newIORef []
  let report value = modifyIORef' reports (<> [value])
      step = \case
        Activate -> ServiceSupport.activateRepositories host [(31, "owner/one")]
        Deliver delivery event body -> do
          receipt <- Custody.receive host.custody (signed body delivery event) body
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
