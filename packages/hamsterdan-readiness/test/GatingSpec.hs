{-# LANGUAGE AllowAmbiguousTypes #-}

-- | @tests/unit/readiness/net_v5/test_gating.py@ (3 functions, 5 cases:
-- the expired-claim scenario is parametrized over the three publication
-- gates): durable execution policy and crash projection for the V5
-- publication gates, over the JSONL History store and the SQLite Local
-- dispatch, exactly as the reference runs them.
module GatingSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, void)
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as SQL
import Harness
import Hamsterdan.Contracts.Codec (Contract, dump, renderDecodeError, validate)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.Readiness.NetV5.Topology (seedMarking)
import Petrus.Activity (ActivityFailureFields (..), ActivityInvocation (..), ExecutionPolicyFields (..), activityFailure, policyFields)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (loadJsonlHistory, openJsonlHistoryStore)
import Petrus.Impetus.History.Records (ActivityFailed (..), ActivityRequested (..), FiringCompleted (..), FiringFailed (..), Record (..))
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Petrinet (Marking, NetPath, Token (..), consume, deposit, emptyMarking, netPath, placeTokens)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt (..), AttemptFailure (..))
import Petrus.Motus.Dispatch.Local qualified as Local
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

instanceId, queue :: Text
instanceId = "test:v5-publication-recovery"
queue = "v5-publication:test"

publicationQueues :: [(Text, Text)]
publicationQueues = [("reply_gate", queue), ("dash_gate", queue), ("announce_gate", queue)]

-- | @Model(**fields)@ through the contract.
model :: forall a. (Contract a) => Json -> a
model raw = either (error . T.unpack . renderDecodeError) id (validate @a raw)

dumped :: forall a. (Contract a) => Json -> Json
dumped = dump . model @a

path :: Text -> NetPath
path = either (error . T.unpack) id . netPath

-- | The three publication requests the reference parametrizes over.
data Work
  = Reply Text Text
  | Dash [Text] Text [Text] Text
  | Announce Json

workDump :: Work -> Json
workDump = \case
  Reply wid body -> dumped @C.ReplyReq (obj [("id", str wid), ("text", str body)])
  Dash entries digest desired desiredDigest ->
    dumped @C.DashReq
      (obj [("entries", texts entries), ("digest", str digest), ("desired_entries", texts desired), ("desired_digest", str desiredDigest)])
  Announce fields -> dumped @C.AnnounceReq fields

workColor :: Work -> Text
workColor = \case
  Reply {} -> "ReplyReq"
  Dash {} -> "DashReq"
  Announce _ -> "AnnounceReq"

operation :: Work -> Text
operation = \case
  Reply wid _ -> "reply:" <> wid
  Dash _ digest _ _ -> "dash:" <> digest
  Announce fields -> case fields `at` "op" of
    String op -> op
    other -> error (show other)

announceWork :: Work
announceWork =
  Announce (obj [("op", str "ready:head-1:i3"), ("incarnation", int 3), ("head", str "head-1"), ("base", str "base-1"), ("policy", str "policy-1")])

-- | @{**data, key: value, ...}@: existing keys keep their position.
updated :: Json -> [(Text, Json)] -> Json
updated (Object members) changes =
  Object ([(k, maybe v id (lookup k changes)) | (k, v) <- members] ++ [c | c@(k, _) <- changes, k `notElem` map fst members])
updated other _ = error (show other)

only :: Marking -> Text -> Token
only m place = case toList (placeTokens (path place) m) of
  [token] -> token
  other -> error ("expected one token at " <> T.unpack place <> ": " <> show other)

emptied :: Text -> Marking -> Marking
emptied place m = either (error . T.unpack) id (consume (path place) (toList (placeTokens (path place) m)) m)

replaced :: Text -> Text -> Json -> Marking -> Marking
replaced place color payload m = deposit (path place) (Token (Just color) payload) (emptied place m)

startedMarking :: Marking
startedMarking = emptied "startup.pending" (either (error . T.unpack) id (seedMarking instanceId))

fixture :: Work -> Marking
fixture work = deposit (path place) (Token (Just (workColor work)) (workDump work)) prepared
 where
  (prepared, place) = case work of
    Reply wid body ->
      let memory = (only startedMarking "conv.memory").payload
       in (replaced "conv.memory" "ConvMemory" (updated memory [("pending", obj [(wid, str body)])]) startedMarking, "conv.reply_req")
    Dash {} -> (emptied "dash.memory" startedMarking, "dash.pub_req")
    Announce _ ->
      let snapshot = (only startedMarking "ready.snap").payload
       in (replaced "ready.snap" "Snapshot" (updated snapshot [("announcing", workDump work)]) startedMarking, "ready.announce_req")

-- | @_open(root, create=..., marking=...)@.
open :: FilePath -> Maybe Marking -> IO Engine.Engine
open root seeded = do
  ref <- newIORef freshWorld
  store <- openJsonlHistoryStore (root </> "history.jsonl")
  custody <- Local.openLocalDispatch (root </> "dispatch.sqlite3") instanceId Local.defaultLocalDispatchOptions {Local.activityQueues = publicationQueues}
  let opts = (engineOptions (gateDefinitions ref) (maybe emptyMarking id seeded)) {Engine.policy = Engine.throughputPolicy}
  case seeded of
    Just _ -> Engine.create builtNet.net instanceId store (Local.toDispatch custody) opts
    Nothing -> Engine.load builtNet.net instanceId store (Local.toDispatch custody) opts

openWorker :: FilePath -> IO Local.LocalWorkerDispatch
openWorker root = do
  custody <- Local.openLocalDispatch (root </> "dispatch.sqlite3") "worker" Local.defaultLocalDispatchOptions
  Local.worker custody [queue] Nothing

requestsOf :: Engine.Engine -> (ActivityRequested -> Bool) -> IO [ActivityRequested]
requestsOf engine wanted = (\rs -> [r | RActivityRequested r <- rs, wanted r]) <$> Engine.records engine

requests :: Engine.Engine -> Text -> Work -> IO [ActivityRequested]
requests engine activity work = requestsOf engine (\r -> r.activity == activity && r.input == obj [("work", workDump work)])

advanceUntil :: Engine.Engine -> IO Bool -> IO ()
advanceUntil engine condition = go (100 :: Int)
 where
  go 0 = expectationFailure "V5 Engine did not reach the expected state in 100 advances"
  go n = condition >>= \done -> if done then pure () else Engine.advance engine >> go (n - 1)

retained :: Engine.Engine -> Work -> IO Bool
retained engine work = do
  m <- Engine.marking engine
  pure $ case work of
    Reply wid body -> (only m "conv.memory").payload `at` "blocked" == obj [(wid, str body)]
    Dash entries digest _ _ -> case toList (placeTokens (path "dash.memory") m) of
      [memory] -> memory.payload `at` "blocked" == obj [("entries", texts entries), ("digest", str digest)]
      _ -> False
    Announce _ -> (only m "ready.snap").payload `at` "blocked" == workDump work

expire :: FilePath -> Int -> IO ()
expire root occurrence = do
  db <- SQL.open (T.pack (root </> "dispatch.sqlite3"))
  statement <- SQL.prepare db "UPDATE impetus_local_dispatch_tasks SET deadline=0,attempt_deadline=0 WHERE instance=? AND occurrence=?"
  SQL.bind statement [SQL.SQLText instanceId, SQL.SQLInteger (fromIntegral occurrence)]
  void (SQL.step statement)
  SQL.finalize statement
  SQL.close db

spec :: Spec
spec = describe "gating" $ do
  describe "expired publication claim projects blocked and only explicit recovery reissues" $
    forM_
      [ ("reply_gate", Reply "comment-7" "exact reply", "reply:comment-7")
      , ("dash_gate", Dash ["attempted"] "digest-attempted" ["attempted", "newer"] "digest-newer", "dash:digest-attempted")
      , ("announce_gate", announceWork, "ready:head-1:i3")
      ]
      $ \(activity, work, recoverOp) -> it (T.unpack activity) $ withSystemTempDirectory "hamsterdan-gating" $ \root -> do
        engine <- open root (Just (fixture work))
        advanceUntil engine (not . null <$> requests engine activity work)
        [firstRequest] <- requests engine activity work
        let op = operation work
        worker <- openWorker root
        Just attempt <- Local.claim worker
        attempt.epoch `shouldBe` "1"
        (policyFields attempt.invocation.policy).attempts `shouldBe` 1
        (firstRequest.correlation, firstRequest.idempotency) `shouldBe` (op, op)
        (attempt.invocation.correlation, attempt.invocation.idempotency) `shouldBe` (Just op, Just op)
        attempt.invocation.input `shouldBe` obj [("work", workDump work)]
        expire root firstRequest.occurrence
        (fmap (const ()) <$> Local.claim worker) `shouldReturn` Nothing
        Local.close worker
        Engine.close engine

        restarted <- open root Nothing
        advanceUntil restarted (retained restarted work)
        records <- Engine.records restarted
        let failures = [f | RActivityFailed f <- records]
        length failures `shouldBe` 1
        [(f.occurrence, f.kind) | f <- failures] `shouldBe` [(firstRequest.occurrence, "DeadlineExceeded")]
        or [c.occurrence == firstRequest.occurrence | RFiringCompleted c <- records] `shouldBe` True
        or [f.occurrence == firstRequest.occurrence | RFiringFailed f <- records] `shouldBe` False
        requests restarted activity work `shouldReturn` [firstRequest]
        Engine.close restarted

        stable <- open root Nothing
        recordsBefore <- Engine.records stable
        void (Engine.advance stable)
        Engine.records stable `shouldReturn` recordsBefore
        requests stable activity work `shouldReturn` [firstRequest]
        let identity = "recover-" <> activity
            seen = dumped @C.CommentSeen (obj [("id", str identity), ("kind", str "recover_publication"), ("arg", str recoverOp), ("authorized", Bool True)])
        void (Engine.deliver stable (path "on_comment") [Token (Just "CommentSeen") seen] identity Nothing)
        let activityRequests = requestsOf stable (\r -> r.activity == activity && r.correlation == op)
        advanceUntil stable ((== 2) . length <$> activityRequests)
        [original, recovered] <- activityRequests
        original `shouldBe` firstRequest
        recovered.occurrence `shouldNotBe` original.occurrence
        case work of
          Dash entries digest _ _ -> do
            let originalWork = original.input `at` "work"
                recoveredWork = recovered.input `at` "work"
            forM_ ["entries", "digest", "desired_entries", "desired_digest", "landed"] $ \field ->
              recoveredWork `at` field `shouldBe` originalWork `at` field
            recoveredWork `at` "blocked" `shouldBe` obj [("entries", texts entries), ("digest", str digest)]
            recoveredWork `at` "faulted" `shouldBe` obj []
          _ -> do
            recovered.input `shouldBe` original.input
            original.input `shouldBe` obj [("work", workDump work)]
        (recovered.correlation, recovered.idempotency) `shouldBe` (op, op)
        Engine.close stable

  it "unknown publication failure stays projection pending and fails loudly" $ withSystemTempDirectory "hamsterdan-gating" $ \root -> do
    engine <- open root (Just (fixture announceWork))
    advanceUntil engine (not . null <$> requests engine "announce_gate" announceWork)
    [firstRequest] <- requests engine "announce_gate" announceWork
    worker <- openWorker root
    Just attempt <- Local.claim worker
    failure <- either (fail . T.unpack) pure (activityFailure (ActivityFailureFields "unclassified provider terminal" "UnexpectedFailure" Null False Nothing))
    Local.fail worker attempt (FailureClassified failure)
    Local.close worker
    Engine.close engine

    restarted <- open root Nothing
    outcome <- try @SomeException (Engine.advance restarted)
    case outcome of
      Left err -> do
        let message = T.pack (displayException err)
        message `shouldSatisfy` T.isInfixOf "UnexpectedFailure"
        snd (T.breakOn "UnexpectedFailure" message) `shouldSatisfy` T.isInfixOf "cannot be projected"
      Right _ -> expectationFailure "advance projected an unclassified failure"
    _ <- try @SomeException (Engine.close restarted)

    history <- toList <$> loadJsonlHistory (root </> "history.jsonl")
    length [() | RActivityFailed f <- history, f.occurrence == firstRequest.occurrence] `shouldBe` 1
    or [f.occurrence == firstRequest.occurrence | RFiringFailed f <- history] `shouldBe` False

  it "restart settles a legacy unlanded announcement moved without posting" $ withSystemTempDirectory "hamsterdan-gating" $ \root -> do
    let legacy = obj [("op", str "ready:h1:i1"), ("incarnation", int 1), ("head", str "h1"), ("base", str "b1"), ("policy", str "p1")]
        snapshot = (only startedMarking "ready.snap").payload
        retainedSnap =
          without ["strict_base", "base_current"] $
            updated
              snapshot
              [ ("incarnation", int 1)
              , ("phase", str "running")
              , ("head", str "h1")
              , ("base", str "b1")
              , ("policy", str "p1")
              , ("mergeable", Bool True)
              , ("checks", str "success")
              , ("review", str "clear")
              , ("approval", Bool True)
              , ("announcing", legacy)
              ]
        seeded = deposit (path "ready.announce_req") (Token (Just "AnnounceReq") legacy) (replaced "ready.snap" "Snapshot" retainedSnap startedMarking)
    first <- open root (Just seeded)
    let announceRequests engine = requestsOf engine (\r -> r.activity == "announce_gate")
    advanceUntil first (not . null <$> announceRequests first)
    [firstRequest] <- announceRequests first
    firstRequest.input `shouldBe` obj [("work", legacy)]
    Engine.close first

    ref <-
      newIORef
        freshWorld
          { branchHead = "h1"
          , baseHead = "b1"
          , policy = "p1"
          , authority = Authority {incarnation = 1, phase = "running", head = "h1", base = "b1", policy = "p1"}
          }
    let definitions = gateDefinitions ref
    restarted <- open root Nothing
    worker <- openWorker root
    Just attempt <- Local.claim worker
    attempt.invocation.input `shouldBe` obj [("work", legacy)]
    result <- callDefinition (definitions Map.! "announce_gate") attempt.invocation
    Local.complete worker attempt result
    Local.close worker
    let settledNow = do
          m <- Engine.marking restarted
          pure $ case toList (placeTokens (path "ready.snap") m) of
            (token : _) -> token.payload `at` "announcing" == obj []
            [] -> False
    advanceUntil restarted settledNow
    settled <- (`only` "ready.snap") <$> Engine.marking restarted
    ((.comments) <$> readIORef ref) `shouldReturn` []
    settled.payload `at` "base_current" `shouldBe` Bool False
    settled.payload `at` "candidate" `shouldBe` Bool False
    Engine.close restarted
