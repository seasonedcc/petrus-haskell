{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The generated-schedule campaigns: Hedgehog state machines porting the
-- reference's Hypothesis @RuleBasedStateMachine@s in
-- @tests/dst/test_generated_delivery_world.py@ and
-- @tests/dst/test_generated_runtime_world.py@.
--
-- The mapping is rule for rule. A @\@rule@ is a 'Command' whose generator
-- draws the rule's strategies; a @\@precondition@ is the generator's
-- 'Nothing' and a 'Require' over a pure model that mirrors exactly the
-- machine state the preconditions and @data.draw@ read. The rule bodies,
-- @\@invariant@, @\@initialize@, and @teardown@ run against the real World
-- as the reference's do:
--
-- * an @\@initialize@ rule is drawn in the same 'forAll' and runs first;
--   Hypothesis counts it as one of @stateful_step_count@ steps, so the
--   sequential part draws exactly the remaining steps;
-- * the invariant runs after every step, and before the first one only when
--   the machine has no initialize rule (Hypothesis skips invariants while
--   initialize rules are pending);
-- * @teardown@ drains, finishes, replays the artifact through a fresh
--   profile and checker, and records the campaign case;
-- * @event(label)@ is Hedgehog's 'label'.
--
-- The World and its scratch directory are created after 'forAll', so a
-- shrink re-runs the whole example from a fresh World, as a Hypothesis
-- example does.
module Petrus.Testing.Dst.Campaign.Machines
  ( campaignProperty
  , checkCampaign
  , checkCampaignProfile
  , renderFailure
  ) where

import Barbies (FunctorB, TraversableB)
import Control.Exception (finally)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (traverse_)
import Data.IORef
import Data.Kind (Type)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Hedgehog
  ( Callback (..)
  , Command (..)
  , Gen
  , PropertyT
  , evalIO
  , executeSequential
  , failure
  , footnote
  , forAll
  , label
  , property
  , withTests
  , (===)
  )
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Internal.Config (UseColor (..))
import Hedgehog.Internal.Property (Property (..))
import Hedgehog.Internal.Report (Report (..), Result (..), renderResult)
import Hedgehog.Internal.Runner (checkReport)
import Hedgehog.Internal.Seed qualified as Seed
import Hedgehog.Range qualified as Range
import Petrus.Json (Json (..))
import Petrus.Testing.Dst hiding (Command)
import Petrus.Testing.Dst.Campaign
import Petrus.Testing.Dst.Campaign.Support (listOf, member, text)
import Petrus.Testing.Dst.Engine.Delivery qualified as Delivery
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as Runtime
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)

-- ---------------------------------------------------------------------------
-- Running a profile

-- | The profile's property under its campaign settings, with its examples
-- under @scratch@.
campaignProperty :: CampaignSettings -> FilePath -> Opened -> Property
campaignProperty settings scratch opened =
  withTests (fromIntegral settings.maxExamples) $ case settings.profile.name of
    "delivery-broad" -> deliveryProperty Broad settings scratch opened
    "delivery-focused" -> deliveryProperty Focused settings scratch opened
    "runtime-broad" -> broadRuntimeProperty settings scratch opened
    _ -> focusedRuntimeProperty settings scratch opened

-- | @run_state_machine_as_test(Machine, settings=campaign_settings(name))@:
-- run the profile's examples from its settings' seed.
checkCampaign :: CampaignSettings -> IO (Report Result)
checkCampaign settings =
  withSystemTempDirectory "petrus-dst-campaign-profile-" $ \scratch -> do
    opened <- newIORef (pure ())
    let p = campaignProperty settings scratch opened
    checkReport p.propertyConfig 0 (Seed.from (fromInteger settings.seed)) p.propertyTest (const (pure ()))
      `finally` closeOpened opened

-- | The @campaign-profile NAME@ child: settings from the environment, the
-- profile's examples, and a failure report on standard error.
checkCampaignProfile :: Text -> IO Bool
checkCampaignProfile name = do
  settings <- campaignSettings name
  report <- checkCampaign settings
  case report.reportStatus of
    OK -> pure True
    _ -> do
      renderFailure name report >>= hPutStrLn stderr
      pure False

renderFailure :: Text -> Report Result -> IO String
renderFailure name = renderResult DisableColor (Just (fromString (T.unpack name)))

-- ---------------------------------------------------------------------------
-- Shared World plumbing

-- | The live World of one example.
type Live g = IORef (Maybe (World IO g))

-- | Run a World action against the example's World; a 'DstFailure' fails
-- the example, as the reference's raised exception fails its rule.
inWorld :: Live g -> WorldT IO g a -> PropertyT IO a
inWorld live body = do
  current <- liftIO (readIORef live)
  world <- maybe (footnote "no live DST World" >> failure) pure current
  (result, world') <- liftIO (World.runWorldT body world)
  liftIO (writeIORef live (Just world'))
  case result of
    Left f -> do
      footnote (T.unpack (failureClass f <> ": " <> failureMessage f))
      failure
    Right a -> pure a

-- | The close action of the current example's World. The reference's
-- @teardown@ closes its World in a @finally@; a Hedgehog example that fails
-- stops before its teardown, so the next example, or the end of the run,
-- closes it instead.
type Opened = IORef (IO ())

closeOpened :: Opened -> IO ()
closeOpened opened = do
  close <- readIORef opened
  writeIORef opened (pure ())
  close

-- | @world.close()@.
closeLive :: Live g -> IO ()
closeLive live = do
  readIORef live >>= traverse_ (void . World.runWorldT World.close)
  writeIORef live Nothing

startWorld :: Live g -> WorldConfig IO g -> PropertyT IO ()
startWorld live cfg = do
  constructed <- evalIO (World.newWorld cfg)
  case constructed of
    Left f -> footnote (T.unpack (failureMessage f)) >> failure
    Right w -> liftIO (writeIORef live (Just w))

event :: (Hedgehog.MonadTest m) => Text -> m ()
event = label . fromString . T.unpack

-- | @(entry["identity"], entry["value"]) for entry in canonical@.
canonicalPairs :: Json -> [(Json, Json)]
canonicalPairs value = [(member "identity" e, member "value" e) | e <- listOf "canonical_deliveries" value]

modelPairs :: [(Text, Integer)] -> [(Json, Json)]
modelPairs accepted = [(String k, Int v) | (k, v) <- accepted]

-- | @dict[k] = v@ (in place when present, else appended).
assign :: Text -> Integer -> [(Text, Integer)] -> [(Text, Integer)]
assign k v xs
  | any ((== k) . fst) xs = [(k', if k' == k then v else v') | (k', v') <- xs]
  | otherwise = xs <> [(k, v)]

-- | The common fresh-registry replay of a teardown.
replayExactly :: Registry IO -> AnyArtifact -> Text -> PropertyT IO ()
replayExactly registry artifact disposition = do
  replayed <- evalIO (replay registry artifact)
  result <- case replayed of
    Left f -> footnote (T.unpack (failureClass f <> ": " <> failureMessage f)) >> failure
    Right r -> pure (toJson r)
  let value = toJson artifact
  member "outcome" result === String "pass"
  member "disposition" result === String disposition
  member "operations" result === Int (toInteger (length (listOf "operations" value)))
  member "journal_digest" result === member "journal_digest" (member "expected" value)

registryOf :: Profile IO g -> [Checker] -> PropertyT IO (Registry IO)
registryOf profile checkers =
  either (\f -> footnote (T.unpack (failureMessage f)) >> failure) pure $ do
    withProfile <- registerProfile profile emptyRegistry
    foldr (\c r -> r >>= registerChecker c) (Right withProfile) checkers

-- | A fresh example directory under the run's scratch directory.
exampleRoot :: FilePath -> String -> PropertyT IO FilePath
exampleRoot scratch prefix = evalIO (createTempDirectory scratch prefix)

-- ---------------------------------------------------------------------------
-- test_generated_delivery_world.py

-- | @GENERATED_WORLD_BUDGET@.
generatedWorldBudget :: SomeBudget
generatedWorldBudget =
  SomeBudget
    Budget
      { actions = 64
      , queuedCommands = 1
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 16
      , predicatePolls = 1
      , artifactBytes = 262144
      }

data DeliveryKind = Broad | Focused
  deriving stock (Eq)

-- | The model of @_DeliveryScheduleMachine@'s precondition state.
data DeliveryModel (v :: Type -> Type) = DeliveryModel
  { modelAccepted :: [(Text, Integer)]
  , modelPoisoned :: Bool
  , modelNext :: Int
  }
  deriving stock (Eq, Show)

-- | One delivery-machine rule with its draws.
data DeliveryStep (v :: Type -> Type)
  = Deliver Text Integer
  | ExactRedelivery Text
  | ConflictingRedelivery Text
  | DistinctDelivery Integer
  | CrashAndReload Text
  deriving stock (Show, Generic)
  deriving anyclass (FunctorB, TraversableB)

-- | The live state of one delivery example (@self._*@).
data DeliveryEnv = DeliveryEnv
  { live :: Live Delivery.DeliveryGeneration
  , timeline :: IORef Timeline
  , accepted :: IORef [(Text, Integer)]
  , poisoned :: IORef Bool
  , coverage :: IORef (Set Text)
  , nextIdentity :: IORef Int
  }

deliveryProperty :: DeliveryKind -> CampaignSettings -> FilePath -> Opened -> Property
deliveryProperty kind settings scratch opened = property $ do
  envRef <- liftIO (newIORef Nothing)
  let steps = settings.statefulStepCount
      commands = deliveryCommands kind envRef
  (initial, actions) <- forAll $ case kind of
    Broad -> (Nothing,) <$> Gen.sequential (Range.singleton steps) (deliveryInitial Nothing) commands
    Focused -> do
      value <- Gen.integral (Range.constantFrom 0 (-1) 1)
      (Just value,) <$> Gen.sequential (Range.singleton (steps - 1)) (deliveryInitial (Just value)) commands
  -- __init__
  liftIO (closeOpened opened)
  root <- exampleRoot scratch "petrus-generated-delivery-"
  profile <- evalIO (Delivery.deliveryEngineProfile (root <> "/author-history.jsonl"))
  live <- liftIO (newIORef Nothing)
  liftIO (writeIORef opened (closeLive live))
  startWorld live WorldConfig {profile = profile.profile, budget = generatedWorldBudget, checkers = [Delivery.deliveryAuthorityChecker], seed = Nothing, progress = Nothing}
  timeline <- inWorld live World.timeline
  env <- liftIO $ DeliveryEnv live <$> newIORef timeline <*> newIORef [] <*> newIORef False <*> newIORef Set.empty <*> newIORef 0
  liftIO (writeIORef envRef (Just env))
  case initial of
    Nothing -> deliveryInvariant env
    Just value -> do
      -- establish_targeted_boundary_coverage
      deliver env "focused-event-1" value
      deliver env "focused-event-1" value
      deliver env "focused-event-1" (value + 1)
      crashReload env "focused-generated-conflict"
      deliveryInvariant env
  executeSequential (deliveryInitial initial) actions
  -- teardown
  poisoned <- liftIO (readIORef env.poisoned)
  when poisoned (crashReload env "generated-conflict-recovery")
  current <- liftIO (readIORef env.timeline)
  inWorld live (Timeline.finish current ExternalWait)
  artifact <- inWorld live (World.artifact "generated-identified-delivery-world-v3")
  covered <- liftIO (readIORef env.coverage)
  let required = if kind == Focused then focusedCoverage else Set.empty
  unless (required `Set.isSubsetOf` covered) $ do
    footnote ("missing coverage " <> show (Set.toList (required `Set.difference` covered)))
    failure
  replayProfile <- evalIO (Delivery.deliveryEngineProfile (root <> "/replay-history.jsonl"))
  registry <- registryOf replayProfile.profile [Delivery.deliveryAuthorityChecker]
  replayExactly registry artifact "external_wait"
  evalIO (recordCampaignCase settings.profile.name artifact)
  liftIO (closeLive live)
  where
    focusedCoverage =
      Set.fromList ["delivery:applied", "delivery:idempotent", "delivery:refused_expected", "lifecycle:crash", "lifecycle:reload"]

-- | The model after @__init__@ and, for the focused machine, its
-- initialize rule.
deliveryInitial :: Maybe Integer -> DeliveryModel v
deliveryInitial = \case
  Nothing -> DeliveryModel [] False 0
  Just value -> DeliveryModel [("focused-event-1", value)] False 0

deliveryCommands :: DeliveryKind -> IORef (Maybe DeliveryEnv) -> [Command Gen (PropertyT IO) DeliveryModel]
deliveryCommands kind envRef = case kind of
  Broad ->
    [ rule (\m -> not m.modelPoisoned) $ \_ ->
        Deliver <$> Gen.element ["broad-event-1", "broad-event-2", "broad-event-3"] <*> Gen.integral (Range.constantFrom 0 (-1) 1)
    , rule (\m -> not m.modelPoisoned) $ \_ -> pure (CrashAndReload "broad-generated-delivery-boundary")
    , rule (\m -> m.modelPoisoned) $ \_ -> pure (CrashAndReload "broad-generated-conflict")
    ]
  Focused ->
    [ rule (\m -> not m.modelPoisoned) $ \m -> ExactRedelivery <$> Gen.element (map fst m.modelAccepted)
    , rule (\m -> not m.modelPoisoned) $ \m -> ConflictingRedelivery <$> Gen.element (map fst m.modelAccepted)
    , rule (\m -> not m.modelPoisoned) $ \_ -> DistinctDelivery <$> Gen.integral (Range.constantFrom 0 (-2) 2)
    , rule (\m -> not m.modelPoisoned) $ \_ -> pure (CrashAndReload "focused-generated-delivery-boundary")
    , rule (\m -> m.modelPoisoned) $ \_ -> pure (CrashAndReload "focused-generated-conflict")
    ]
  where
    rule :: (forall v. DeliveryModel v -> Bool) -> (DeliveryModel Symbolic' -> Gen (DeliveryStep Symbolic')) -> Command Gen (PropertyT IO) DeliveryModel
    rule precondition draw =
      Command
        (\m -> if precondition m then Just (draw m) else Nothing)
        (executeDeliveryStep envRef)
        [ Require (\m _ -> precondition m)
        , Update (\m step _ -> updateDelivery m step)
        , Ensure (\_ after _ (accepted, poisoned) -> do
            accepted === after.modelAccepted
            poisoned === after.modelPoisoned)
        ]

type Symbolic' = Hedgehog.Symbolic

-- | The model's view of a rule.
updateDelivery :: DeliveryModel v -> DeliveryStep v' -> DeliveryModel v
updateDelivery m = \case
  Deliver identity value -> modelDeliver identity value m
  ExactRedelivery identity -> maybe m (\v -> modelDeliver identity v m) (lookup identity m.modelAccepted)
  ConflictingRedelivery identity -> maybe m (\v -> modelDeliver identity (v + 1) m) (lookup identity m.modelAccepted)
  DistinctDelivery value ->
    let n = m.modelNext + 1
     in modelDeliver ("focused-new-" <> T.pack (show n)) value m {modelNext = n}
  CrashAndReload _ -> m {modelPoisoned = False}

modelDeliver :: Text -> Integer -> DeliveryModel v -> DeliveryModel v
modelDeliver identity value m = case lookup identity m.modelAccepted of
  Nothing -> m {modelAccepted = m.modelAccepted <> [(identity, value)]}
  Just v | v == value -> m
  Just _ -> m {modelPoisoned = True}

executeDeliveryStep :: IORef (Maybe DeliveryEnv) -> DeliveryStep Hedgehog.Concrete -> PropertyT IO ([(Text, Integer)], Bool)
executeDeliveryStep envRef step = do
  env <- liftIO (readIORef envRef) >>= maybe (footnote "no delivery machine" >> failure) pure
  accepted <- liftIO (readIORef env.accepted)
  case step of
    Deliver identity value -> deliver env identity value
    ExactRedelivery identity -> deliver env identity (valueOf identity accepted)
    ConflictingRedelivery identity -> deliver env identity (valueOf identity accepted + 1)
    DistinctDelivery value -> do
      n <- liftIO (modifyIORef' env.nextIdentity (+ 1) >> readIORef env.nextIdentity)
      deliver env ("focused-new-" <> T.pack (show n)) value
    CrashAndReload cut -> crashReload env cut
  deliveryInvariant env
  liftIO ((,) <$> readIORef env.accepted <*> readIORef env.poisoned)
  where
    valueOf identity = maybe 0 id . lookup identity

-- | @_deliver(identity, value)@.
deliver :: DeliveryEnv -> Text -> Integer -> PropertyT IO ()
deliver env identity value = do
  accepted <- liftIO (readIORef env.accepted)
  expected <- case lookup identity accepted of
    Nothing -> do
      liftIO (writeIORef env.accepted (assign identity value accepted))
      pure Applied
    Just v | v == value -> pure Idempotent
    Just _ -> do
      liftIO (writeIORef env.poisoned True)
      pure RefusedExpected
  timeline <- liftIO (readIORef env.timeline)
  result <- inWorld env.live (Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int value)]))
  result.disposition === expected
  let name = "delivery:" <> actionDispositionText expected
  liftIO (modifyIORef' env.coverage (Set.insert name))
  event name

-- | @_crash_reload(cut)@.
crashReload :: DeliveryEnv -> Text -> PropertyT IO ()
crashReload env cut = do
  timeline <- liftIO (readIORef env.timeline)
  inWorld env.live (Timeline.crash timeline cut)
  next <- inWorld env.live World.restart
  timeline' <- inWorld env.live World.timeline
  liftIO (writeIORef env.timeline timeline' >> writeIORef env.poisoned False)
  Hedgehog.assert (next > timeline.generation)
  liftIO (modifyIORef' env.coverage (Set.union (Set.fromList ["lifecycle:crash", "lifecycle:reload"])))
  event "lifecycle:crash-reload"

-- | @detached_history_agrees_with_the_external_authority_model@.
deliveryInvariant :: DeliveryEnv -> PropertyT IO ()
deliveryInvariant env = do
  timeline <- liftIO (readIORef env.timeline)
  observation <- inWorld env.live (Timeline.observe timeline "engine.delivery-authority")
  accepted <- liftIO (readIORef env.accepted)
  canonicalPairs observation.value === modelPairs accepted
  member "marking_values" observation.value === Array (map (Int . snd) accepted)

-- ---------------------------------------------------------------------------
-- test_generated_runtime_world.py

-- | The live state of one runtime example (@self._*@).
data RuntimeEnv = RuntimeEnv
  { live :: Live Runtime.RuntimeGeneration
  , profile :: IORef (Maybe Runtime.GeneratedRuntimeProfile)
  , timeline :: IORef (Maybe Timeline)
  , accepted :: IORef [(Text, Integer)]
  , activities :: IORef Int
  , reset :: IORef Bool
  , root :: FilePath
  }

newRuntimeEnv :: FilePath -> IO RuntimeEnv
newRuntimeEnv root =
  RuntimeEnv
    <$> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef False
    <*> pure root

-- | @_install(world, profile)@.
install :: RuntimeEnv -> Runtime.GeneratedRuntimeProfile -> PropertyT IO ()
install env profile = do
  liftIO (writeIORef env.profile (Just profile))
  timeline <- inWorld env.live World.timeline
  liftIO (writeIORef env.timeline (Just timeline))

currentTimeline :: RuntimeEnv -> PropertyT IO Timeline
currentTimeline env = liftIO (readIORef env.timeline) >>= maybe (footnote "no live Timeline" >> failure) pure

currentProfile :: RuntimeEnv -> PropertyT IO Runtime.GeneratedRuntimeProfile
currentProfile env = liftIO (readIORef env.profile) >>= maybe (footnote "no runtime profile" >> failure) pure

drops :: RuntimeEnv -> PropertyT IO Int
drops env = currentProfile env >>= \p -> liftIO (readIORef p.drops)

-- | @_drain()@.
drain :: RuntimeEnv -> PropertyT IO ()
drain env = inWorld env.live Runtime.drainAll

-- | @_crash_reload(cut)@.
runtimeCrashReload :: RuntimeEnv -> Text -> PropertyT IO ()
runtimeCrashReload env cut = do
  timeline <- currentTimeline env
  inWorld env.live (Timeline.crash timeline cut)
  generation <- inWorld env.live World.restart
  timeline' <- inWorld env.live World.timeline
  liftIO (writeIORef env.timeline (Just timeline'))
  Hedgehog.assert (generation > timeline.generation)

-- | @detached_delivery_authority_remains_exact@.
runtimeInvariant :: RuntimeEnv -> PropertyT IO ()
runtimeInvariant env =
  liftIO (readIORef env.timeline) >>= \case
    Nothing -> pure ()
    Just timeline -> do
      observation <- inWorld env.live (Timeline.observe timeline "generated-runtime-state")
      accepted <- liftIO (readIORef env.accepted)
      canonicalPairs observation.value === modelPairs accepted

-- | @teardown()@ of @_ReplayableRuntimeMachine@.
runtimeTeardown :: CampaignSettings -> RuntimeEnv -> PropertyT IO ()
runtimeTeardown settings env = do
  drain env
  timeline <- currentTimeline env
  inWorld env.live (Timeline.finish timeline ExternalWait)
  artifact <- inWorld env.live (World.artifact "generated-runtime-state-machine-v4")
  replayProfile <- evalIO (Runtime.generatedRuntimeProfile (env.root <> "/replay-history.jsonl") (env.root <> "/replay-dispatch.db"))
  registry <- registryOf replayProfile.profile [Runtime.generatedRuntimeChecker]
  replayExactly registry artifact "external_wait"
  evalIO (recordCampaignCase settings.profile.name artifact)
  liftIO (closeLive env.live)

inspect :: RuntimeEnv -> PropertyT IO ()
inspect env = do
  timeline <- currentTimeline env
  observation <- inWorld env.live (Timeline.observe timeline "generated-runtime-state")
  Hedgehog.assert (member "status" observation.value `elem` map String ["awaiting", "running", "completed"])

runtimeWorld :: Runtime.GeneratedRuntimeProfile -> WorldConfig IO Runtime.RuntimeGeneration
runtimeWorld profile =
  WorldConfig {profile = profile.profile, budget = Runtime.worldBudget, checkers = [Runtime.generatedRuntimeChecker], seed = Nothing, progress = Nothing}

-- | The precondition state of @FocusedRuntimeScheduleMachine@: the
-- profile's drop count.
newtype FocusedModel (v :: Type -> Type) = FocusedModel {focusedDrops :: Int}
  deriving stock (Eq, Show)

data FocusedStep (v :: Type -> Type) = ReloadQuiescentRuntime | InspectDetachedRuntime
  deriving stock (Show, Generic)
  deriving anyclass (FunctorB, TraversableB)

focusedRuntimeProperty :: CampaignSettings -> FilePath -> Opened -> Property
focusedRuntimeProperty settings scratch opened = property $ do
  envRef <- liftIO (newIORef Nothing)
  -- The story's two crashes have dropped two generations when the
  -- generated rules start.
  let initialModel = FocusedModel 2
      commands =
        [ Command
            (\m -> if m.focusedDrops < 4 then Just (pure ReloadQuiescentRuntime) else Nothing)
            (focusedStep envRef)
            [ Require (\m _ -> m.focusedDrops < 4)
            , Update (\m _ _ -> FocusedModel (m.focusedDrops + 1))
            , Ensure (\_ after _ real -> real === after.focusedDrops)
            ]
        , Command
            (\_ -> Just (pure InspectDetachedRuntime))
            (focusedStep envRef)
            [Ensure (\_ after _ real -> real === after.focusedDrops)]
        ]
  (spine, actions) <- forAll $ do
    first <- Gen.integral (Range.constantFrom 0 (-3) 3)
    second <- Gen.integral (Range.constantFrom 0 (-3) 3)
    retryError <- Gen.element ["worker unavailable", "lease interrupted"]
    (,) (first, second, retryError) <$> Gen.sequential (Range.singleton (settings.statefulStepCount - 1)) initialModel commands
  liftIO (closeOpened opened)
  root <- exampleRoot scratch "petrus-generated-runtime-"
  env <- liftIO (newRuntimeEnv root)
  liftIO (writeIORef envRef (Just env))
  liftIO (writeIORef opened (closeLive env.live))
  -- establish_cross_layer_spine
  let (first, second, retryError) = spine
  profile <- evalIO (Runtime.generatedRuntimeProfile (root <> "/author-history.jsonl") (root <> "/author-dispatch.db"))
  startWorld env.live (runtimeWorld profile)
  inWorld
    env.live
    ( Runtime.executeGeneratedRuntimeStory
        Runtime.defaultStoryOptions {Runtime.firstValue = first, Runtime.secondValue = second, Runtime.retryError = retryError, Runtime.finish = False}
    )
  install env profile
  liftIO (writeIORef env.accepted [("generated-event-1", first), ("generated-event-2", second)])
  event "runtime:two-fault-cross-layer-spine"
  runtimeInvariant env
  spineDrops <- drops env
  spineDrops === initialModel.focusedDrops
  executeSequential initialModel actions
  runtimeTeardown settings env

focusedStep :: IORef (Maybe RuntimeEnv) -> FocusedStep Hedgehog.Concrete -> PropertyT IO Int
focusedStep envRef step = do
  env <- liftIO (readIORef envRef) >>= maybe (footnote "no runtime machine" >> failure) pure
  case step of
    ReloadQuiescentRuntime -> do
      runtimeCrashReload env "focused_generated_quiescent_cut"
      drain env
      event "runtime:extra-crash-reload"
    InspectDetachedRuntime -> inspect env
  runtimeInvariant env
  drops env

-- | The precondition state of @BroadRuntimeScheduleMachine@.
data BroadModel (v :: Type -> Type) = BroadModel
  { broadActivities :: Int
  , broadReset :: Bool
  , broadAccepted :: [(Text, Integer)]
  , broadDrops :: Int
  }
  deriving stock (Eq, Show)

-- | @run_one_external_activity@'s draws.
data Activity = Activity
  { value :: Integer
  , dispatchFault :: Bool
  , crashAfterRequest :: Bool
  , retry :: Bool
  , projectionFault :: Bool
  , resetBeforeTerminal :: Bool
  }
  deriving stock (Show)

-- | One broad-machine rule with its draws.
data BroadStep (v :: Type -> Type)
  = RunOneExternalActivity Activity
  | CrashBetweenExternalFacts
  | RedeliverExternalFact Text
  | InspectRuntimeWithoutAdvancingIt
  deriving stock (Show, Generic)
  deriving anyclass (FunctorB, TraversableB)

-- | @WORLD_BUDGET.reloads@.
worldReloads :: Int
worldReloads = 4

broadRuntimeProperty :: CampaignSettings -> FilePath -> Opened -> Property
broadRuntimeProperty settings scratch opened = property $ do
  envRef <- liftIO (newIORef Nothing)
  let initialModel = BroadModel 0 False [] 0
      ensure = Ensure (\_ after _ real -> real === after.broadDrops)
      commands =
        [ Command
            (\m -> if m.broadActivities < 2 then Just activity else Nothing)
            (broadStep envRef)
            [Require (\m _ -> m.broadActivities < 2), Update (\m step _ -> updateBroad m step), ensure]
        , Command
            (\m -> if m.broadDrops == 0 then Just (pure CrashBetweenExternalFacts) else Nothing)
            (broadStep envRef)
            [Require (\m _ -> m.broadDrops == 0), Update (\m step _ -> updateBroad m step), ensure]
        , Command
            (\m -> if not (null m.broadAccepted) && not m.broadReset then Just (RedeliverExternalFact <$> Gen.element (map fst m.broadAccepted)) else Nothing)
            (broadStep envRef)
            [Require (\m _ -> not (null m.broadAccepted) && not m.broadReset), ensure]
        , Command (\_ -> Just (pure InspectRuntimeWithoutAdvancingIt)) (broadStep envRef) [ensure]
        ]
      activity =
        fmap RunOneExternalActivity $
          Activity
            <$> Gen.integral (Range.constantFrom 0 (-2) 2)
          <*> Gen.bool
          <*> Gen.bool
          <*> Gen.bool
          <*> Gen.bool
          <*> Gen.bool
  actions <- forAll (Gen.sequential (Range.singleton (settings.statefulStepCount - 1)) initialModel commands)
  liftIO (closeOpened opened)
  -- __init__
  root <- exampleRoot scratch "petrus-generated-runtime-"
  env <- liftIO (newRuntimeEnv root)
  liftIO (writeIORef envRef (Just env))
  liftIO (writeIORef opened (closeLive env.live))
  profile <- evalIO (Runtime.generatedRuntimeProfile (root <> "/author-history.jsonl") (root <> "/author-dispatch.db"))
  startWorld env.live (runtimeWorld profile)
  install env profile
  -- open_runtime_scope
  timeline <- currentTimeline env
  _ <- inWorld env.live (Timeline.command timeline "scope.open" (Object [("name", String Runtime.scopeName)]))
  runtimeInvariant env
  executeSequential initialModel actions
  runtimeTeardown settings env

-- | The model's view of a broad rule.
updateBroad :: BroadModel v -> BroadStep v' -> BroadModel v
updateBroad m = \case
  RunOneExternalActivity Activity {value, dispatchFault, crashAfterRequest, projectionFault, resetBeforeTerminal} ->
    let identity = "broad-runtime-event-" <> T.pack (show (m.broadActivities + 1))
        d1 = if dispatchFault && m.broadDrops < worldReloads then m.broadDrops + 1 else m.broadDrops
        d2 = if crashAfterRequest && d1 < worldReloads then d1 + 1 else d1
        useReset = resetBeforeTerminal && not m.broadReset
        d3 = if projectionFault && not useReset && d2 < worldReloads then d2 + 1 else d2
     in m {broadActivities = m.broadActivities + 1, broadReset = m.broadReset || useReset, broadAccepted = assign identity value m.broadAccepted, broadDrops = d3}
  CrashBetweenExternalFacts -> m {broadDrops = m.broadDrops + 1}
  RedeliverExternalFact _ -> m
  InspectRuntimeWithoutAdvancingIt -> m

broadStep :: IORef (Maybe RuntimeEnv) -> BroadStep Hedgehog.Concrete -> PropertyT IO Int
broadStep envRef step = do
  env <- liftIO (readIORef envRef) >>= maybe (footnote "no runtime machine" >> failure) pure
  case step of
    RunOneExternalActivity Activity {value, dispatchFault, crashAfterRequest, retry, projectionFault, resetBeforeTerminal} ->
      runOneExternalActivity env value dispatchFault crashAfterRequest retry projectionFault resetBeforeTerminal
    CrashBetweenExternalFacts -> do
      runtimeCrashReload env "broad_generated_quiescent_cut"
      drain env
      event "runtime:quiescent-crash"
    RedeliverExternalFact identity -> do
      timeline <- currentTimeline env
      accepted <- liftIO (readIORef env.accepted)
      value <- maybe (footnote "unknown redelivery identity" >> failure) pure (lookup identity accepted)
      result <- inWorld env.live (Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int value)]))
      result.disposition === Idempotent
      drain env
    InspectRuntimeWithoutAdvancingIt -> inspect env
  runtimeInvariant env
  drops env

-- | @run_one_external_activity@.
runOneExternalActivity :: RuntimeEnv -> Integer -> Bool -> Bool -> Bool -> Bool -> Bool -> PropertyT IO ()
runOneExternalActivity env value dispatchFault crashAfterRequest retry projectionFault resetBeforeTerminal = do
  profile <- currentProfile env
  activities <- liftIO (readIORef env.activities)
  let identity = "broad-runtime-event-" <> T.pack (show (activities + 1))
      requestCount = activities
      acceptedCount attempts = length [() | a <- attempts, member "accepted" a == Bool True]
  acceptedDispatches <- acceptedCount <$> liftIO (readIORef profile.dispatchAttempts)
  workFiringsBefore <- workFiringCount env

  dropsNow <- drops env
  let useDispatchFault = dispatchFault && dropsNow < worldReloads
  timeline <- currentTimeline env
  when useDispatchFault $
    inWorld
      env.live
      ( Timeline.activateFault
          timeline
          (Timeline.fault "dispatch.refuse" "activity_requested")
            { Timeline.disposition = Refuse
            , Timeline.payload = Object [("message", String ("broad dispatch refusal " <> T.pack (show (activities + 1))))]
            }
      )
  _ <- inWorld env.live (Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int value)]))
  liftIO (modifyIORef' env.accepted (assign identity value))

  when useDispatchFault $ do
    refused <- inWorld env.live World.step
    refused.result.disposition === RefusedExpected
    runtimeCrashReload env "broad_generated_dispatch_refusal"
    event "runtime:fault-dispatch"

  timeline1 <- currentTimeline env
  _ <-
    inWorld env.live $
      Timeline.runUntil timeline1 "generated-runtime-state" $ \o ->
        length (listOf "requested_invocations" o.value) == requestCount + 1
          && acceptedCount (listOf "dispatch_attempts" o.value) >= acceptedDispatches + 1
  dropsAfterRequest <- drops env
  when (crashAfterRequest && dropsAfterRequest < worldReloads) $ do
    runtimeCrashReload env "broad_generated_requested_cut"
    _ <- inWorld env.live World.step
    event "runtime:cut-after-request"

  timeline2 <- currentTimeline env
  first <- inWorld env.live (Timeline.command timeline2 "worker.claim" (Object []))
  member "epoch" (member "attempt" first.value) === Int 1
  when retry $ do
    _ <- inWorld env.live (Timeline.command timeline2 "worker.fail" (Object [("attempt", Int 1), ("error", String "broad generated retry")]))
    second <- inWorld env.live (Timeline.command timeline2 "worker.claim" (Object []))
    member "epoch" (member "attempt" second.value) === Int 2
    event "runtime:worker-retry"

  wasReset <- liftIO (readIORef env.reset)
  let useReset = resetBeforeTerminal && not wasReset
  when useReset $ do
    _ <- inWorld env.live (Timeline.command timeline2 "scope.reset" (Object [("name", String Runtime.scopeName)]))
    liftIO (writeIORef env.reset True)
  _ <- inWorld env.live (Timeline.command timeline2 "worker.complete" (Object [("result", Object [("value", Int value)])]))

  dropsBeforeProjection <- drops env
  let useProjectionFault = projectionFault && not useReset && dropsBeforeProjection < worldReloads
  if useProjectionFault
    then do
      inWorld
        env.live
        ( Timeline.activateFault
            timeline2
            (Timeline.fault "history.refuse" "projection_committed")
              { Timeline.disposition = Refuse
              , Timeline.payload = Object [("message", String ("broad projection refusal " <> T.pack (show (activities + 1))))]
              }
        )
      refused <- inWorld env.live (Timeline.command timeline2 "engine.drive" (Object []))
      refused.disposition === RefusedExpected
      runtimeCrashReload env "broad_generated_projection_refusal"
      event "runtime:fault-projection"
    else void (inWorld env.live (Timeline.command timeline2 "engine.drive" (Object [])))

  timeline3 <- currentTimeline env
  if useReset
    then do
      let expectedOccurrence = member "occurrence" (member "attempt" first.value)
      terminal <- inWorld env.live (Timeline.observe timeline3 "generated-runtime-state")
      Hedgehog.assert (expectedOccurrence `elem` listOf "quarantined_occurrences" terminal.value)
      event "runtime:late-terminal-quarantine"
    else
      void . inWorld env.live $
        Timeline.runUntil timeline3 "generated-runtime-state" (\o -> workFirings o.value == workFiringsBefore + 1)

  liftIO (modifyIORef' env.activities (+ 1))
  drain env
  event "runtime:activity-converged"

workFiringCount :: RuntimeEnv -> PropertyT IO Int
workFiringCount env = do
  timeline <- currentTimeline env
  workFirings . (.value) <$> inWorld env.live (Timeline.observe timeline "generated-runtime-state")

-- | @_observed_work_firings@.
workFirings :: Json -> Int
workFirings value = length [() | f <- listOf "firing_completed" value, text (member "transition" f) == "work"]
