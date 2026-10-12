{-# LANGUAGE ScopedTypeVariables #-}

-- | The nets and scenarios of the telemetry differential, the twins of
-- @differential/telemetry_scenarios.py@, plus the nets the upstream
-- instrumentation tests build (@_fork_net@, @_source_net@) and the bench's
-- chain.
--
-- Every scenario is an @IO ()@ that drives the Haskell Instance, Engine, or
-- JSONL store exactly as its Python twin drives the reference. The caller
-- runs it under 'Petrus.Telemetry.capture' and compares what was emitted.
module Petrus.Telemetry.Scenarios
  ( -- * Nets
    p
  , x
  , forkNet
  , namedForkNet
  , sourceNet
  , twoSourceNet
  , handledNet
  , timerNet
  , chainNet
  , scopedActivityNet
    -- * Implementations
  , boom
  , charge
  , chargeTo
    -- * Helpers
  , ok
  , okI
  , newEngine
  , untilRest
    -- * Scenarios
  , scenarios
  ) where

import Control.Exception (SomeException, throw, try)
import Foreign.C.Error (eNOENT, errnoToIOError)
import Control.Monad (forM_, void, when)
import Data.Maybe (isJust)
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailureFields (..), activityFailure, failureFields, invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario (orderActivities, orderIdentity, orderNet, orderOptions)
import Petrus.Engine.TestSupport (inlineOf, symbols)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (withScratch)
import Petrus.Impetus.Binding
import Petrus.Impetus.HistoryStore (HistoryStore, inMemoryHistoryStore)
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, nextMaturation, selection)
import Petrus.Impetus.Selection (SelectionPolicy, first, selectionPipeline)
import Petrus.Impetus.TestSupport (mustNet, np, tok, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (cancelledInstructions, completeOccurrence, failOccurrence, inMemoryDispatch, newInMemoryDispatch, pending)
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Nets

p :: Text -> NetPath
p = np

-- | @Token("X")@.
x :: Token
x = tok "X"

named :: Maybe Text -> [Place] -> [Transition] -> [Arc] -> Net
named name ps ts as = mustNet (NetSpec ps ts as Nothing name)

-- | @a -> t -> {b, c}@.
forkNet :: Net
forkNet = namedForkNet Nothing

namedForkNet :: Maybe Text -> Net
namedForkNet name =
  named name [place (p "a"), place (p "b"), place (p "c")] [transition (p "t")] [arc (p "a") (p "t"), arc (p "t") (p "b"), arc (p "t") (p "c")]

-- | @s (source) -> b@.
sourceNet :: Net
sourceNet = named Nothing [place (p "b")] [transition (p "s")] [arc (p "s") (p "b")]

-- | @s -> b, u -> b@.
twoSourceNet :: Net
twoSourceNet =
  named Nothing [place (p "b")] [transition (p "s"), transition (p "u")] [arc (p "s") (p "b"), arc (p "u") (p "b")]

-- | @a -> t[handler] -> b@.
handledNet :: Text -> Net
handledNet handler =
  named Nothing [place (p "a"), place (p "b")] [Transition (p "t") (Just (HandlerSymbol handler)) [] []] [arc (p "a") (p "t"), arc (p "t") (p "b")]

-- | @a -> t (Delay 10) -> b@.
timerNet :: Net
timerNet = named Nothing [place (p "a"), place (p "b")] [Transition (p "t") Nothing [] [Delay 10]] [arc (p "a") (p "t"), arc (p "t") (p "b")]

-- | @p0 -> t0 -> p1 -> … -> p{length}@.
chainNet :: Int -> Net
chainNet len =
  named
    Nothing
    [place (p ("p" <> tshow i)) | i <- [0 .. len]]
    [transition (p ("t" <> tshow i)) | i <- [0 .. len - 1]]
    (concat [[arc (p ("p" <> tshow i)) (p ("t" <> tshow i)), arc (p ("t" <> tshow i)) (p ("p" <> tshow (i + 1)))] | i <- [0 .. len - 1]])

-- | @s (source) -> q -> work[charge] -> done@.
scopedActivityNet :: Net
scopedActivityNet =
  named
    Nothing
    [place (p "q"), place (p "done")]
    [transition (p "s"), Transition (p "work") (Just (HandlerSymbol "charge")) [] []]
    [arc (p "s") (p "q"), arc (p "q") (p "work"), arc (p "work") (p "done")]

tshow :: Int -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Implementations

-- | @def boom(binding, outputs): raise RuntimeError("handler broke")@, in
-- the reference's recorded failure spelling.
boom :: Handler
boom _ _ = Left "RuntimeError('handler broke')"

-- | The reference script's @Charge()@: prepare @charge_card@ with the
-- token's data, project the result to @b@.
charge :: ActivityHandler
charge = chargeTo "b"

chargeTo :: Text -> ActivityHandler
chargeTo target =
  ActivityHandler
    { prepare = \b -> case bindingTokens b of
        t : _ -> invocation "charge_card" (Object [("token", t.payload)])
        [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(p target, [tokD "Receipt" result])])
    , projectFailure = Nothing
    }

-- ---------------------------------------------------------------------------
-- Helpers

-- | A door the scenario expects to succeed.
ok :: Show e => IO (Either e a) -> IO a
ok action =
  action >>= \case
    Right a -> pure a
    Left e -> fail ("expected success, got " <> show e)

okI :: IO (Either InstanceError a) -> IO a
okI = ok

-- | A door the scenario expects to refuse or raise.
refused :: forall a. Show a => IO (Either InstanceError a) -> IO ()
refused action =
  (try action :: IO (Either SomeException (Either InstanceError a))) >>= \case
    Right (Right a) -> fail ("expected a refusal, got " <> show a)
    _ -> pure ()

raises :: forall a. IO a -> IO ()
raises action =
  (try action :: IO (Either SomeException a)) >>= \case
    Left _ -> pure ()
    Right _ -> fail "expected an exception"

config :: Text -> Marking -> InstanceConfig
config identity m = defaultInstanceConfig {initialMarking = m, suppliedIdentity = Just identity}

instanceOf :: Net -> InstanceConfig -> IO Instance
instanceOf net cfg = okI (newInstance net cfg)

-- | @Engine.create@ over an in-memory History unless a store is given.
newEngine :: Net -> Text -> Maybe HistoryStore -> Dispatch -> (Engine.EngineOptions -> Engine.EngineOptions) -> IO Engine.Engine
newEngine net identity store port options = do
  history <- maybe inMemoryHistoryStore pure store
  Engine.create net identity history port (options Engine.defaultEngineOptions)

-- | @while engine.advance().ready: pass@.
untilRest :: Engine.Engine -> IO ()
untilRest engine = do
  outcome <- Engine.advance engine
  when outcome.ready (untilRest engine)

inMemory :: IO Dispatch
inMemory = inMemoryDispatch <$> newInMemoryDispatch

accepted :: DeliveryAnswer AcceptedDelivery -> IO AcceptedDelivery
accepted = \case
  DeliveryAccepted a -> pure a
  other -> fail ("expected an accepted delivery, got " <> show other)

-- ---------------------------------------------------------------------------
-- Scenarios (in the generator's order)

scenarios :: [(Text, IO ())]
scenarios =
  [ ("instance_created", instanceCreated)
  , ("step_and_run", stepAndRun)
  , ("failing_handler", failingHandler)
  , ("delivery_lifecycle", deliveryLifecycle)
  , ("seal_and_wake", sealAndWake)
  , ("resume", resumeScenario)
  , ("activity_seam", activitySeam)
  , ("jsonl_commits", jsonlCommits)
  , ("engine_advance", engineAdvance)
  , ("engine_failing_handler", engineFailingHandler)
  , ("engine_handler_oserror", engineHandlerOsError)
  , ("engine_policy_refusal", enginePolicyRefusal)
  , ("engine_gauges", engineGauges)
  , ("engine_declined", engineDeclined)
  , ("engine_orders", engineOrders)
  , ("engine_sensor", engineSensor)
  , ("engine_activities", engineActivities)
  , ("engine_reconcile", engineReconcile)
  , ("engine_cancellation", engineCancellation)
  , ("engine_reconcile_pure", engineReconcilePure)
  , ("engine_clock_not_due", engineClockNotDue)
  , ("engine_failure_projection", engineFailureProjection)
  , ("engine_failing_source_projection", engineFailingSourceProjection)
  , ("engine_debug_level", engineDebugLevel)
  , ("level_off", engineOrders >> jsonlCommits)
  ]

engineDebugLevel :: IO ()
engineDebugLevel = do
  port <- inMemory
  newEngine forkNet "debug" Nothing port (\o -> o {Engine.marking = markingFromList [(p "a", [x])]}) >>= untilRest

instanceCreated :: IO ()
instanceCreated = do
  void (instanceOf forkNet (config "i-1" (markingFromList [(p "a", [x])])) {constructionInstant = 5})
  void (instanceOf (namedForkNet (Just "order-fulfillment")) (config "i-2" emptyMarking) {constructionInstant = FloatNumber 2.5})
  void (instanceOf sourceNet (config "i-3" (markingFromList [(p "b", [x, tokD "Y" (Object [("n", Int 1)])])])))

stepAndRun :: IO ()
stepAndRun = do
  inst <- instanceOf forkNet (config "i-1" (markingFromList [(p "a", [x, x])]))
  void (okI (step inst (Just 7)))
  void (okI (step inst (Just (FloatNumber 7.5))))
  fruitless <- okI (step inst Nothing)
  when (isJust fruitless) (fail "the third step should be fruitless")
  chain <- instanceOf (chainNet 3) (config "chain-1" (markingFromList [(p "p0", [x, x])]))
  void (okI (run chain))

failingHandler :: IO ()
failingHandler = do
  inst <- instanceOf (handledNet "boom") (config "i-1" (markingFromList [(p "a", [black])])) {handlerImplementations = symbols [("boom", PureHandler boom)]}
  refused (step inst (Just 3))

deliveryLifecycle :: IO ()
deliveryLifecycle = do
  inst <- instanceOf twoSourceNet (config "i-1" emptyMarking)
  one <- okI (acceptDelivery inst (p "s") [x] "evt-1" Nothing (Just 1)) >>= accepted
  void (okI (completeDelivery inst one (Just 2)))
  void (okI (acceptDelivery inst (p "s") [x] "evt-1" Nothing Nothing))
  refused (acceptDelivery inst (p "s") [tok "Y"] "evt-1" Nothing Nothing)
  let pair = [x, tokD "Z" (Object [("k", String "é")])]
  two <- okI (acceptDelivery inst (p "u") pair "evt-2" Nothing (Just 4)) >>= accepted
  void (okI (acceptDelivery inst (p "u") pair "evt-2" Nothing Nothing))
  void (okI (completeDelivery inst two Nothing))
  void (okI (acceptDelivery inst (p "u") [x] "evt-3" (Just (ScopeName "job")) Nothing))
  void (okI (acceptDelivery inst (p "u") [x] "evt-3" (Just (ScopeName "job")) Nothing))
  refused (acceptDelivery inst (p "s") [x] "evt-3" (Just (ScopeName "job")) Nothing)

sealAndWake :: IO ()
sealAndWake = do
  inst <- instanceOf twoSourceNet (config "i-1" emptyMarking)
  okI (seal inst (p "s") (Just 3))
  okI (seal inst (p "u") Nothing)
  timed <- instanceOf timerNet (config "i-2" (markingFromList [(p "a", [black, black])]))
  early <- okI (wake timed 5)
  when (early /= Nothing) (fail "an early wake should mature nothing")
  void (okI (wake timed 10))
  void (okI (step timed Nothing))
  void (okI (wake timed (FloatNumber 20.5)))

resumeScenario :: IO ()
resumeScenario = do
  inst <- instanceOf forkNet (config "i-1" (markingFromList [(p "a", [x])])) {constructionInstant = 4}
  void (okI (run inst))
  void (okI (resume forkNet (instanceHistory inst) defaultInstanceConfig))
  let handlers' = symbols [("charge", ActivityBound charge)]
  flying <- instanceOf (handledNet "charge") (config "i-2" (markingFromList [(p "a", [x, x])])) {handlerImplementations = handlers'}
  candidates flying >>= \case
    b : _ -> void (okI (begin flying b (Just 6)))
    [] -> fail "no candidate"
  resumed <- okI (resume (handledNet "charge") (instanceHistory flying) defaultInstanceConfig {handlerImplementations = handlers'})
  candidates resumed >>= \case
    b : _ -> void (okI (begin resumed b (Just 8)))
    [] -> fail "no candidate"

activitySeam :: IO ()
activitySeam = do
  inst <-
    instanceOf (handledNet "charge") (config "i-1" (markingFromList [(p "a", [x, x, x])])) {handlerImplementations = symbols [("charge", ActivityBound charge)]}
  let next = candidates inst >>= \case
        b : _ -> pure b
        [] -> fail "no candidate"
      okResult = Object [("ok", Bool True)]
  firstOne <- next >>= \b -> okI (begin inst b (Just 1))
  void (okI (recordActivityCompletion inst firstOne okResult (Just 2)))
  void (okI (recordActivityCompletion inst firstOne okResult (Just 3)))
  void (okI (complete inst firstOne Nothing (Just 4)))
  void (okI (recordActivityCompletion inst firstOne okResult Nothing))
  second <- next >>= \b -> okI (begin inst b Nothing)
  okI (failFiring inst second (FailureText "card declined") (Just 5))
  third <- next >>= \b -> okI (begin inst b Nothing)
  failure <- ok (pure (activityFailure (ActivityFailureFields "gateway down" "Timeout" Null False Nothing)))
  void (okI (recordActivityFailure inst third failure (Just 6)))
  void (okI (recordActivityFailure inst third failure Nothing))
  okI (failFiring inst third (FailureValue failure) (Just 7))

jsonlCommits :: IO ()
jsonlCommits = withScratch $ \dir -> do
  let path = dir </> "history.jsonl"
  store <- openJsonlHistoryStore path
  inst <-
    instanceOf
      forkNet
      (config "jsonl-1" (markingFromList [(p "a", [tokD "X" (Object [("note", String "café ☕")]), x])])) {historyStore = Just store}
  void (okI (run inst))
  reopened <- openJsonlHistoryStore path
  void (okI (resume forkNet reopened defaultInstanceConfig))
  sourcedStore <- openJsonlHistoryStore (dir </> "s.jsonl")
  sourced <- instanceOf sourceNet (config "jsonl-2" emptyMarking) {historyStore = Just sourcedStore}
  one <- okI (acceptDelivery sourced (p "s") [tokD "Y" (Object [("emoji", String "😀")])] "e-1" Nothing Nothing) >>= accepted
  void (okI (completeDelivery sourced one Nothing))
  okI (seal sourced (p "s") Nothing)

engineAdvance :: IO ()
engineAdvance = do
  port <- inMemory
  engine <- newEngine forkNet "span" Nothing port (\o -> o {Engine.marking = markingFromList [(p "a", [x])]})
  void (Engine.advance engine)
  void (Engine.advance engine)
  port' <- inMemory
  named' <-
    newEngine (namedForkNet (Just "order-fulfillment")) "order-7" Nothing port' (\o -> o {Engine.marking = markingFromList [(p "a", [x, x])], Engine.at = 3})
  untilRest named'

engineFailingHandler :: IO ()
engineFailingHandler = do
  port <- inMemory
  engine <-
    newEngine
      (handledNet "boom")
      "failed-span"
      Nothing
      port
      (\o -> o {Engine.marking = markingFromList [(p "a", [black])], Engine.handlers = symbols [("boom", PureHandler boom)]})
  raises (Engine.advance engine)

-- | A handler failing with an @errno@-carrying 'IOException': the drive
-- span's @error_type@ and @firing_failed.error@ name CPython's subclass for
-- it (@FileNotFoundError(2, 'No such file or directory')@).
engineHandlerOsError :: IO ()
engineHandlerOsError = do
  port <- inMemory
  let missing :: Handler
      missing _ _ = throw (errnoToIOError "open" eNOENT Nothing Nothing)
  engine <-
    newEngine
      (handledNet "missing")
      "oserror-span"
      Nothing
      port
      (\o -> o {Engine.marking = markingFromList [(p "a", [black])], Engine.handlers = symbols [("missing", PureHandler missing)]})
  raises (Engine.advance engine)

-- | The coordinator's own refusal escaping the drive span: a @ValueError@.
enginePolicyRefusal :: IO ()
enginePolicyRefusal = do
  port <- inMemory
  engine <-
    newEngine
      forkNet
      "refused-policy"
      Nothing
      port
      (\o -> o {Engine.marking = markingFromList [(p "a", [x])], Engine.policy = \_ -> pure (Engine.AdvanceTime 99)})
  raises (Engine.advance engine)

engineGauges :: IO ()
engineGauges = do
  port <- inMemory
  engine <- newEngine forkNet "gauges" Nothing port (\o -> o {Engine.marking = markingFromList [(p "a", [x, x])]})
  untilRest engine

engineDeclined :: IO ()
engineDeclined = do
  port <- inMemory
  let declining = selectionPipeline [const False] [] first :: SelectionPolicy ()
  engine <-
    newEngine
      forkNet
      "declined"
      Nothing
      port
      (\o -> o {Engine.marking = markingFromList [(p "a", [x, x])], Engine.selection = Engine.EngineSelection declining ()})
  void (Engine.advance engine)

engineOrders :: IO ()
engineOrders = do
  store <- inMemoryHistoryStore
  port <- orderActivities
  prepared <- newIORef 0
  engine <- Engine.create orderNet orderIdentity store port (orderOptions prepared)
  let order k = tokD "Order" (Object [("id", String ("o-" <> tshow k)), ("amount", Int (fromIntegral k))])
  forM_ [1, 2 :: Int] $ \k -> Engine.deliver engine (p "intake") [order k] ("evt_" <> tshow k) Nothing
  void (Engine.deliver engine (p "intake") [order 1] "evt_1" Nothing)
  Engine.seal engine (p "intake")
  untilRest engine

engineSensor :: IO ()
engineSensor = do
  let deliveryOf identity tokens = either (fail . T.unpack) pure (Engine.delivery (p "s") tokens identity Nothing)
  first' <- deliveryOf "sensed-1" [x]
  second <- deliveryOf "sensed-2" [tok "Y"]
  pendingBatches <- newIORef [[first', second]]
  let sensor =
        atomicModifyIORef' pendingBatches $ \case
          b : rest -> (rest, b)
          [] -> ([], [])
  port <- inMemory
  engine <- newEngine sourceNet "sensed" Nothing port (\o -> o {Engine.sensor = Just sensor})
  untilRest engine

engineActivities :: IO ()
engineActivities = do
  pool <- newInMemoryDispatch
  engine <-
    newEngine
      (handledNet "charge")
      "acts"
      Nothing
      (inMemoryDispatch pool)
      (\o -> o {Engine.marking = markingFromList [(p "a", [x, x])], Engine.handlers = symbols [("charge", ActivityBound charge)]})
  untilRest engine
  pending pool >>= \case
    [(o, _)] -> completeOccurrence pool o (Object [("status", String "captured")])
    other -> fail ("expected one pending occurrence, got " <> show (map fst other))
  untilRest engine
  pending pool >>= \case
    [(o, _)] -> failOccurrence pool o "card declined"
    other -> fail ("expected one pending occurrence, got " <> show (map fst other))
  raises (untilRest engine)

engineReconcile :: IO ()
engineReconcile = withScratch $ \dir -> do
  let path = dir </> "history.jsonl"
      options o = o {Engine.handlers = symbols [("charge", ActivityBound charge)]}
  store <- openJsonlHistoryStore path
  port <- inMemory
  crashed <- newEngine (handledNet "charge") "reconcile" (Just store) port (\o -> (options o) {Engine.marking = markingFromList [(p "a", [x])]})
  untilRest crashed
  reopened <- openJsonlHistoryStore path
  inline <- inlineOf [("charge_card", \_ _ -> pure (Object [("status", String "captured")]))]
  loaded <- Engine.load (handledNet "charge") "reconcile" reopened inline (options Engine.defaultEngineOptions)
  untilRest loaded

engineCancellation :: IO ()
engineCancellation = do
  pool <- newInMemoryDispatch
  engine <-
    newEngine scopedActivityNet "scoped" Nothing (inMemoryDispatch pool) (\o -> o {Engine.handlers = symbols [("charge", ActivityBound (chargeTo "done"))]})
  scope <- Engine.openScope engine "job"
  void (Engine.deliver engine (p "s") [x] "job-1" (Just (ScopeGeneration scope)))
  untilRest engine
  n <- length <$> pending pool
  when (n /= 1) (fail "expected one pending Activity")
  void (Engine.closeScope engine scope)
  untilRest engine
  fenced <- IntMap.keys <$> cancelledInstructions pool
  case fenced of
    [o] -> completeOccurrence pool o (Object [("status", String "late")])
    other -> fail ("expected one fenced occurrence, got " <> show other)
  untilRest engine
  second <- Engine.openScope engine "job"
  void (Engine.deliver engine (p "s") [x] "job-2" (Just (ScopeGeneration second)))
  untilRest engine
  void (Engine.resetScope engine second)
  untilRest engine

-- | The reference script's @double@: both outputs of the first token to b.
double :: Handler
double b _ = case bindingTokens b of
  t : _ -> Right (handlerTokens [(p "b", [t, t])])
  [] -> Left "IndexError('tuple index out of range')"

engineReconcilePure :: IO ()
engineReconcilePure = do
  history <- inMemoryHistoryStore
  let handlers' = symbols [("double", PureHandler double)]
  inst <-
    instanceOf
      (handledNet "double")
      (config "pure" (markingFromList [(p "a", [x, x])])) {handlerImplementations = handlers', historyStore = Just history}
  candidates inst >>= \case
    b : _ -> void (okI (begin inst b (Just 2)))
    [] -> fail "no candidate"
  port <- inMemory
  loaded <- Engine.load (handledNet "double") "pure" history port Engine.defaultEngineOptions {Engine.handlers = handlers'}
  untilRest loaded

engineClockNotDue :: IO ()
engineClockNotDue = do
  port <- inMemory
  let neverDue = Engine.Clock {Engine.now = pure 1, Engine.observe = \_ -> pure Nothing}
  engine <-
    newEngine timerNet "not-due" Nothing port (\o -> o {Engine.marking = markingFromList [(p "a", [black])], Engine.clock = Just neverDue})
  void (Engine.advance engine)
  void (Engine.advance engine)

engineFailureProjection :: IO ()
engineFailureProjection = withScratch $ \dir -> do
  pool <- newInMemoryDispatch
  store <- openJsonlHistoryStore (dir </> "history.jsonl")
  let declined failure = tokD "Declined" (Object [("error", String (failureFields failure).failureError)])
      projecting = charge {projectFailure = Just (\_ failure -> Right (handlerTokens [(p "b", [declined failure])]))}
  engine <-
    newEngine
      (handledNet "charge")
      "projects"
      (Just store)
      (inMemoryDispatch pool)
      (\o -> o {Engine.marking = markingFromList [(p "a", [x])], Engine.handlers = symbols [("charge", ActivityBound projecting)]})
  untilRest engine
  pending pool >>= \case
    [(o, _)] -> failOccurrence pool o "card declined"
    other -> fail ("expected one pending occurrence, got " <> show (map fst other))
  untilRest engine

engineFailingSourceProjection :: IO ()
engineFailingSourceProjection = do
  let net = named Nothing [place (p "b")] [Transition (p "s") (Just (HandlerSymbol "boom")) [] []] [arc (p "s") (p "b")]
  port <- inMemory
  engine <- newEngine net "bad-source" Nothing port (\o -> o {Engine.handlers = symbols [("boom", PureHandler boom)]})
  raises (Engine.deliver engine (p "s") [x] "evt-1" Nothing)
