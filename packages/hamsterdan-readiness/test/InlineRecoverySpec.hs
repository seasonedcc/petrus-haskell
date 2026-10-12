{-# LANGUAGE AllowAmbiguousTypes #-}

-- | @tests/unit/readiness/net_v5/test_inline_recovery.py@ (9 functions, 35
-- cases): restart convergence for the V5 inline effect Activities.
--
-- Canonical History is the invocation outbox: a fresh Engine redispatches
-- the exact frozen request after a lost terminal, and the provider's
-- operation ledger turns redispatch into a lookup. The reference proves
-- the ledger half with the @hamsterdan.host.v5@ gates (V5ReviewGate,
-- V5PublicationGates, V5RerunGate, V5MutationGate); those belong to
-- hamsterdan-host, so the five convergence cases here drive the same
-- restart protocol through a ledger test double around the harness gate
-- and assert the net-side contract (exact redispatch, one effect, a stable
-- reload). The identity-contract cases are ported verbatim.
module InlineRecoverySpec (spec) where

import Control.Exception (Exception, SomeException, displayException, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Harness
import Hamsterdan.Contracts.Codec (Contract, dump, renderDecodeError, validate)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition (..))
import Petrus.Activity
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (loadJsonlHistory, openJsonlHistoryStore)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityFailed (..), ActivityRequested (..), FiringFailed (..), Record (..))
import Petrus.Impetus.Petrinet (Token (..), deposit, emptyMarking, netPath)
import Petrus.Json (Json (..), compact, dumps)
import Petrus.Motus.Dispatch (ActivityOutcome (..), Dispatch (..))
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

instanceId :: Text
instanceId = "test:v5-inline-recovery"

headSha, baseSha :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"

model :: forall a. (Contract a) => Json -> a
model raw = either (error . T.unpack . renderDecodeError) id (validate @a raw)

dumped :: forall a. (Contract a) => Json -> Json
dumped = dump . model @a

reviewMemory :: [(Text, Json)]
reviewMemory =
  [ ("subject", str "github:12:34:pr:7")
  , ("head", str headSha)
  , ("incarnation", int 3)
  , ("status", str "pending")
  , ("reviewed", arr [])
  , ("provisional", arr [])
  , ("findings", arr [])
  , ("lineage", arr [])
  , ("dismissed", arr [])
  , ("pub", obj [("phase", str "idle")])
  ]

-- | One parametrized work item: its activity, input place, contract color,
-- and raw fields (validated through the contract at deposit time, as
-- @dataclasses.replace@ re-validates).
data Work = Work
  { activity :: Text
  , place :: Text
  , color :: Text
  , fields :: [(Text, Json)]
  }

roundWork, publicationWork, rerunWork, reminderWork, mutationWork :: Work
roundWork =
  Work
    "review_agent"
    "review.round"
    "RoundOpen"
    [ ("operation", str ("review:github:12:34:pr:7:" <> headSha <> ":i3"))
    , ("head", str headSha)
    , ("base", str baseSha)
    , ("policy", str "policy-1")
    , ("incarnation", int 3)
    , ("prior_findings", arr [])
    , ("prior_lineage", arr [])
    , ("mem", obj reviewMemory)
    ]
publicationWork =
  Work
    "publish_gate"
    "review.publishable"
    "Publishable"
    [ ("head", str headSha)
    , ("base", str baseSha)
    , ("policy", str "policy-1")
    , ("incarnation", int 3)
    , ("findings", arr [obj [("id", str "f1"), ("note", str "review finding"), ("blocking", Bool True)]])
    , ("effect", str ("findings:" <> headSha <> ":i3"))
    , ("op", str ("findings:" <> headSha <> ":i3"))
    , ("mem", obj [(k, if k == "pub" then obj [("phase", str "pending")] else v) | (k, v) <- reviewMemory])
    ]
rerunWork =
  Work
    "rerun_gate"
    "esc.rerun_req"
    "RerunReq"
    [ ("fingerprint", str "lineage:fingerprint")
    , ("fp", str "fingerprint")
    , ("op", str "rerun:lineage:fingerprint")
    , ("head", str headSha)
    , ("base", str baseSha)
    , ("policy", str "policy-1")
    , ("incarnation", int 3)
    , ("run_id", int 41)
    , ("attempt", int 2)
    , ("mem", obj [("reruns", obj []), ("repairs", obj []), ("rerun_faults", obj []), ("closing", Null)])
    ]
reminderWork = Work "reminder_gate" "rem.pub_req" "RemReq" [("timer_id", str "timer:github:12:34:pr:7:i3:s0")]
mutationWork =
  Work
    "git_gate"
    "mut.work"
    "MutWork"
    [ ("op", str "change")
    , ("op_key", str ("push:comment:9:" <> headSha <> ":i3"))
    , ("head", str headSha)
    , ("base", str baseSha)
    , ("policy", str "policy-1")
    , ("incarnation", int 3)
    , ("lineage", str "")
    , ("kind", str "change")
    , ("instruction", str "rename the config key")
    , ("run_id", int 0)
    , ("attempt", int 0)
    ]

-- | @replace(work, **changes)@.
replaced :: Work -> [(Text, Json)] -> Work
replaced w changes = w {fields = [(k, maybe v id (lookup k changes)) | (k, v) <- w.fields]}

workDump :: Work -> Json
workDump w = case w.color of
  "RoundOpen" -> dumped @C.RoundOpen (obj w.fields)
  "Publishable" -> dumped @C.Publishable (obj w.fields)
  "RerunReq" -> dumped @C.RerunReq (obj w.fields)
  "RemReq" -> dumped @C.RemReq (obj w.fields)
  "MutWork" -> dumped @C.MutWork (obj w.fields)
  other -> error (T.unpack other)

-- | The identity the reference's tests assert as correlation and
-- idempotency.
identityOf :: Work -> Text
identityOf w = case w.color of
  "RoundOpen" -> field "operation"
  "Publishable" -> field "op"
  "RerunReq" -> field "op"
  "RemReq" -> "reminder:" <> field "timer_id"
  _ -> field "op_key"
 where
  field k = case lookup k w.fields of
    Just (String t) -> t
    other -> error (show other)

-- ---------------------------------------------------------------------------
-- The crash-cut dispatch

-- | Test-only cut that cannot be classified as an Activity terminal.
data SimulatedProcessDeath = SimulatedProcessDeath
  deriving stock (Show)

instance Exception SimulatedProcessDeath

-- | The reference's test-local @RuntimeError@: the inline dispatch
-- classifies a failure by its exception type name.
newtype RuntimeError = RuntimeError String

instance Show RuntimeError where
  show (RuntimeError message) = message

instance Exception RuntimeError

data Mode = Hold | Discard | Complete
  deriving stock (Eq)

data Cut = Cut
  { invocations :: IORef [(Int, ActivityInvocation)]
  , crashes :: IORef Int
  }

-- | @CrashCutDispatch(activities, mode)@: execute or retain an invocation,
-- optionally losing its terminal.
crashCut :: Map Text GateDefinition -> Mode -> IO (Dispatch, Cut)
crashCut definitions mode = do
  seen <- newIORef []
  completed <- newIORef []
  crashed <- newIORef 0
  let run occurrence inv = do
        modifyIORef' seen (++ [(occurrence, inv)])
        when (mode /= Hold) $ do
          outcome <- try @SomeException (callDefinition (definitions Map.! inv.activity) inv)
          case outcome of
            Left err
              | "SimulatedProcessDeath" `T.isInfixOf` T.pack (displayException err) -> modifyIORef' crashed (+ 1)
              | otherwise -> throwIO err
            Right result -> when (mode == Complete) $ modifyIORef' completed (++ [(occurrence, Succeeded result)])
      collected = atomicModifyIORef' completed (\values -> ([], values))
  pure (Dispatch {dispatch = run, collect = collected, cancel = Nothing}, Cut seen crashed)

-- | The provider ledger double: the first execution per frozen request runs
-- the harness gate and holds its result; every later call is a lookup.
-- With a pending crash, the first execution dies before its effect.
data Ledger = Ledger
  { held :: Map Text Json
  , effects :: Int
  , calls :: Int
  , crashBeforeEffect :: Bool
  }

ledgered :: IORef Ledger -> GateDefinition -> GateDefinition
ledgered ref definition = withFunction definition lookupFirst
 where
  inner = gateFunction definition
  lookupFirst args ctx = do
    let key = either (error . show) TE.decodeUtf8 (dumps compact (Object args))
    ledger <- atomicModifyIORef' ref (\l -> (l {calls = l.calls + 1}, l))
    case Map.lookup key ledger.held of
      Just result -> pure result
      Nothing
        | ledger.crashBeforeEffect -> do
            modifyIORef' ref (\l -> l {crashBeforeEffect = False})
            throwIO SimulatedProcessDeath
        | otherwise -> do
            result <- inner args ctx
            modifyIORef' ref (\l -> l {held = Map.insert key result l.held, effects = l.effects + 1})
            pure result

gateFunction :: GateDefinition -> [(Text, Json)] -> ActivityExecutionContext -> IO Json
gateFunction (GateDefinition (ActivityDefinition _ _ _ f) _ _) = f

withFunction :: GateDefinition -> ([(Text, Json)] -> ActivityExecutionContext -> IO Json) -> GateDefinition
withFunction (GateDefinition (ActivityDefinition declaration converter parameters _) annotations members) f =
  GateDefinition (ActivityDefinition declaration converter parameters f) annotations members

-- ---------------------------------------------------------------------------
-- Opening, draining, restarting

open :: FilePath -> Map Text GateDefinition -> Dispatch -> Maybe Work -> IO Engine.Engine
open root definitions port seeded = do
  store <- openJsonlHistoryStore (root </> "history.jsonl")
  let initial = case seeded of
        Just w -> deposit (path w.place) (Token (Just w.color) (workDump w)) emptyMarking
        Nothing -> emptyMarking
      opts = (engineOptions definitions initial) {Engine.policy = Engine.throughputPolicy}
  case seeded of
    Just _ -> Engine.create builtNet.net instanceId store port opts
    Nothing -> Engine.load builtNet.net instanceId store port opts
 where
  path = either (error . T.unpack) id . netPath

drain :: Engine.Engine -> IO ()
drain engine = go (100 :: Int)
 where
  go 0 = expectationFailure "V5 inline recovery fixture did not quiesce"
  go n = Engine.advance engine >>= \outcome -> when outcome.ready (go (n - 1))

attemptsOnce :: ExecutionPolicy
attemptsOnce = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 1})

request :: FilePath -> Map Text GateDefinition -> Work -> IO ActivityRequested
request root definitions w = do
  (port, cut) <- crashCut definitions Hold
  engine <- open root definitions port (Just w)
  drain engine
  [requested'] <- (\rs -> [r | RActivityRequested r <- rs, r.activity == w.activity]) <$> Engine.records engine
  [(occurrence, inv)] <- readIORef cut.invocations
  occurrence `shouldBe` requested'.occurrence
  invocationFields inv
    `shouldBe` ActivityInvocationFields
      { activity = w.activity
      , input = obj [("work", workDump w)]
      , policy = attemptsOnce
      , correlation = Just requested'.correlation
      , idempotency = Just requested'.idempotency
      }
  Engine.close engine
  pure requested'

restart :: FilePath -> Map Text GateDefinition -> Mode -> ActivityRequested -> IO (Engine.Engine, Cut)
restart root definitions mode requested' = do
  (port, cut) <- crashCut definitions mode
  engine <- open root definitions port Nothing
  void (Engine.advance engine)
  [(occurrence, inv)] <- readIORef cut.invocations
  occurrence `shouldBe` requested'.occurrence
  inv.input `shouldBe` requested'.input
  inv.policy `shouldBe` requested'.policy
  inv.correlation `shouldBe` Just requested'.correlation
  inv.idempotency `shouldBe` Just requested'.idempotency
  pure (engine, cut)

finishAndProveStable :: FilePath -> Map Text GateDefinition -> ActivityRequested -> IO ()
finishAndProveStable root definitions requested' = do
  (engine, _) <- restart root definitions Complete requested'
  drain engine
  terminalRecords <- Engine.records engine
  length [() | RActivityCompleted c <- terminalRecords, c.occurrence == requested'.occurrence] `shouldBe` 1
  Engine.close engine
  (port, cut) <- crashCut definitions Complete
  stable <- open root definitions port Nothing
  void (Engine.advance stable)
  Engine.records stable `shouldReturn` terminalRecords
  readIORef cut.invocations >>= (`shouldSatisfy` null)
  Engine.close stable

-- | One convergence case: request, two lost terminals, then completion.
converges :: Work -> Bool -> Expectation
converges w crashFirst = withSystemTempDirectory "hamsterdan-inline" $ \root -> do
  world <- newIORef freshWorld
  ledger <- newIORef (Ledger Map.empty 0 0 crashFirst)
  let definitions = Map.adjust (ledgered ledger) w.activity (gateDefinitions world)
  requested' <- request root definitions w
  (requested'.correlation, requested'.idempotency) `shouldBe` (identityOf w, identityOf w)
  (first, firstCut) <- restart root definitions Discard requested'
  readIORef firstCut.crashes `shouldReturn` (if crashFirst then 1 else 0)
  ((.effects) <$> readIORef ledger) `shouldReturn` (if crashFirst then 0 else 1)
  Engine.close first
  (second, _) <- restart root definitions Discard requested'
  ((.effects) <$> readIORef ledger) `shouldReturn` 1
  Engine.close second
  finishAndProveStable root definitions requested'
  ((.effects) <$> readIORef ledger) `shouldReturn` 1
  ((.calls) <$> readIORef ledger) `shouldReturn` 3

-- | The engine refuses the work before dispatch with a message matching.
refusedBeforeDispatch :: Work -> [Text] -> Expectation
refusedBeforeDispatch w needles = withSystemTempDirectory "hamsterdan-inline" $ \root -> do
  world <- newIORef freshWorld
  let definitions = gateDefinitions world
  (port, cut) <- crashCut definitions Hold
  engine <- open root definitions port (Just w)
  outcome <- try @SomeException (drain engine)
  case outcome of
    Left err -> T.pack (displayException err) `shouldSatisfy` (\m -> any (`T.isInfixOf` m) needles)
    Right () -> expectationFailure "the malformed work was accepted"
  readIORef cut.invocations >>= (`shouldSatisfy` null)
  void (try @SomeException (Engine.close engine))

spec :: Spec
spec = describe "inline recovery" $ do
  describe "restart convergence (host gates substituted by a ledger double)" $ do
    it "review agent redispatches one frozen global operation without a second agent execution" $
      converges roundWork False
    it "findings publication reconciles after two lost terminals" $
      converges publicationWork False
    it "rerun reconciles after two lost terminals" $
      converges rerunWork False
    it "reminder reconciles after two lost terminals" $ do
      converges reminderWork False
      identityOf reminderWork `shouldBe` "reminder:timer:github:12:34:pr:7:i3:s0"
    it "mutation replays after a crash before its effect and lands one effect" $
      converges mutationWork True

  it "unexpected inline failure stays a loud activity failure" $ withSystemTempDirectory "hamsterdan-inline" $ \root -> do
    world <- newIORef freshWorld
    let explode _ _ = throwIO (RuntimeError "unexpected provider bug")
        definitions =
          Map.adjust (`withFunction` explode) "review_agent" (gateDefinitions world)
    port <- inlineDispatch <$> newInlineDispatch (Map.map (\d inv _ -> callDefinition d inv) definitions)
    engine <- open root definitions port (Just roundWork)
    outcome <- try @SomeException (drain engine)
    case outcome of
      Left err -> do
        let message = T.pack (displayException err)
        message `shouldSatisfy` T.isInfixOf "failed terminally"
        snd (T.breakOn "failed terminally" message) `shouldSatisfy` T.isInfixOf "unexpected provider bug"
      Right () -> expectationFailure "the inline failure was not loud"
    void (try @SomeException (Engine.close engine))
    records <- loadJsonlHistory (root </> "history.jsonl")
    let requests = [r | RActivityRequested r <- foldr (:) [] records]
        failures = [f | RActivityFailed f <- foldr (:) [] records]
    case (requests, failures) of
      ([requested'], [failed]) -> do
        failed.occurrence `shouldBe` requested'.occurrence
        failed.kind `shouldBe` "RuntimeError"
        or [f.occurrence == requested'.occurrence | RFiringFailed f <- foldr (:) [] records] `shouldBe` True
      other -> expectationFailure ("expected one request and one failure: " <> show (length (fst other), length (snd other)))

  describe "identity contract rejects malformed work before dispatch" $
    forM_
      [ ("review_agent", replaced roundWork [("operation", str "")])
      , ("publish_gate", replaced publicationWork [("op", str "")])
      , ("rerun_gate", replaced rerunWork [("op", str "")])
      , ("reminder_gate", replaced reminderWork [("timer_id", str "")])
      , ("git_gate", replaced mutationWork [("op_key", str "")])
      , ("publish_gate (diverging effect)", replaced publicationWork [("effect", str "findings:different:i3")])
      ]
      $ \(label, w) -> it label (refusedBeforeDispatch w ["identity", "effect"])

  describe "identity contract rejects noncanonical provider identities" $
    forM_ ["has space", "line\nbreak", "r\233view", T.replicate 1025 "x"] $ \identity ->
      forM_
        [ replaced roundWork [("operation", str identity)]
        , replaced publicationWork [("effect", str identity), ("op", str identity)]
        , replaced rerunWork [("op", str identity)]
        , replaced reminderWork [("timer_id", str identity)]
        , replaced mutationWork [("op_key", str identity)]
        ]
        $ \w -> it (T.unpack w.activity <> " " <> show (T.take 12 identity)) (refusedBeforeDispatch w ["identity"])

  describe "comment-backed inline identity honors the provider marker bound" $
    forM_
      [ replaced publicationWork [("effect", str (T.replicate 129 "x")), ("op", str (T.replicate 129 "x"))]
      , replaced rerunWork [("op", str (T.replicate 129 "x"))]
      , replaced reminderWork [("timer_id", str (T.replicate 129 "x"))]
      ]
      $ \w -> it (T.unpack w.activity) (refusedBeforeDispatch w ["identity"])
