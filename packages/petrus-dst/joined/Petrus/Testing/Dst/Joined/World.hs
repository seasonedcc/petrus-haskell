{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The joined History/Dispatch transaction-fault profiles: a port of the
-- profile classes of the reference's @tests/dst/joined_world.py@,
-- @joined_registration_world.py@, and @joined_seal_world.py@.
--
-- Every profile hosts a real Absurd Engine ("Petrus.Engine.Absurd") over
-- PostgreSQL History and the Absurd Dispatch, with a 'FaultConnection'
-- wrapped around the joined connection, and drives external Absurd
-- Workers ('AbsurdWorkerDispatch') for the terminal paths. The reference
-- builds one profile class per fault through a class hierarchy; here one
-- implementation is selected by 'Family', and each method follows the
-- reference's method resolution for that class exactly.
module Petrus.Testing.Dst.Joined.World
  ( -- * Constants
    instanceId
  , queue
  , sourcePlace
  , inputPlace
  , donePlace
  , projectTransition
  , worldBudget
  , cancellationWorldBudget
    -- * Profiles
  , Family (..)
  , JoinedGeneration (..)
  , JoinedProfile (..)
  , joinedProfile
  , familyIdentity
  ) where

import Control.Exception (SomeException, finally, fromException, throwIO, try)
import Control.Monad (forM, unless, when)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailureFields (..), ActivityInvocation, activityFailure, defaultInvocationFields)
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd (AbsurdEngineOptions (..), absurdSession, defaultAbsurdEngineOptions, openAbsurdEngine)
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Impetus.Binding (HandlerResult (..), handlerTokens, prepareInvocation)
import Petrus.Impetus.History.Records
  ( DeliveryRegistration (..)
  , DeliveryRegistrationClosed (..)
  , DeliveryRegistrationOpened (..)
  , ExternalEventDelivered (..)
  , QuarantineScope (..)
  , Record (..)
  , ScopeOpened (..)
  , ScopeReset (..)
  , ScopedDeliveryDropped (..)
  , ScopedDeliveryQuarantined (..)
  , TokensProduced (..)
  , recordName
  )
import Petrus.Impetus.Instance qualified as Instance
import Petrus.Impetus.Instance
  ( DeliveryDisposition (..)
  , DeliveryScope (..)
  , FiringOutcome (..)
  , ScopeClosure (..)
  , ScopedDeliveryAcknowledgement (..)
  )
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Scope (LifecycleScope, lifecycleScope, scopeGeneration, scopeName)
import Petrus.Json (Json (..), pythonEq)
import Petrus.Motus.Dispatch (ActivityAttempt, AttemptFailure (..))
import Petrus.Motus.Dispatch.Absurd
  ( AbsurdError (..)
  , AbsurdWorkerDispatch
  , AbsurdWorkerOptions (..)
  , defaultAbsurdWorkerOptions
  , openAbsurdWorkerDispatch
  )
import Petrus.Motus.Dispatch.Absurd qualified as Worker
import Petrus.Postgres qualified as Pg
import Petrus.Testing.Dst hiding (dispositionText)
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Testing.Dst.Joined.Identities qualified as Id
import Petrus.Testing.Dst.Joined.Support
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Json.Python.Exception (raised)

-- ---------------------------------------------------------------------------
-- Constants and nets

sourcePlace, inputPlace, donePlace, projectTransition :: NetPath
sourcePlace = path "source"
inputPlace = path "input"
donePlace = path "done"
projectTransition = path "project"

-- | @INSTANCE_ID@.
instanceId :: Text
instanceId = "dst-world-joined-begin-refusal"

-- | @QUEUE@.
queue :: Text
queue = "dst_joined_begin"

budgetOf :: Integer -> SomeBudget
budgetOf actions =
  SomeBudget
    Budget
      { actions
      , queuedCommands = 2
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 1
      , predicatePolls = 8
      , artifactBytes = 262144
      }

-- | @WORLD_BUDGET@.
worldBudget :: SomeBudget
worldBudget = budgetOf 16

-- | @CANCELLATION_WORLD_BUDGET@.
cancellationWorldBudget :: SomeBudget
cancellationWorldBudget = budgetOf 24

netOf :: Text -> [NetPath] -> [Transition] -> [(NetPath, NetPath)] -> Net
netOf name places transitions arcs =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place places
        , transitions
        , arcs = map (uncurry arc) arcs
        , completion = Nothing
        , name = Just name
        }

bridged :: Transition
bridged = (transition projectTransition) {handler = Just (HandlerSymbol "bridge")}

-- | @application_net()@.
applicationNet :: Net
applicationNet = netOf "dst-world-joined-begin-refusal" [inputPlace, donePlace] [bridged] [(inputPlace, projectTransition), (projectTransition, donePlace)]

-- | @lifecycle_application_net()@.
lifecycleApplicationNet :: Net
lifecycleApplicationNet =
  netOf
    "dst-world-joined-cancellation-refusal"
    [inputPlace, donePlace]
    [transition sourcePlace, bridged]
    [(sourcePlace, inputPlace), (inputPlace, projectTransition), (projectTransition, donePlace)]

-- | @delivery_application_net()@.
deliveryApplicationNet :: Net
deliveryApplicationNet = netOf "dst-world-joined-delivery" [donePlace] [transition sourcePlace] [(sourcePlace, donePlace)]

-- | @registration_application_net()@ / @seal_application_net()@.
registrationNet :: Text -> Net
registrationNet name =
  netOf name [inputPlace, donePlace] [bridged, transition sourcePlace] [(inputPlace, projectTransition), (projectTransition, donePlace), (sourcePlace, donePlace)]

-- ---------------------------------------------------------------------------
-- Families

-- | One profile class of the reference.
data Family
  = FBegin
  | FDispatch
  | FBeginAckLoss
  | FDeliveryRefusal
  | FDeliveryAckLoss
  | FProjection
  | FProjectionAckLoss
  | FTerminalRefusal
  | FTerminalAckLoss
  | FFailureRefusal
  | FFailureAckLoss
  | FFailureProjectionRefusal
  | FFailureProjectionAckLoss
  | FCancellation
  | FCancellationAckLoss
  | FResetRefusal
  | FResetAckLoss
  | FCloseRefusal
  | FCloseAckLoss
  | FOpenRefusal
  | FOpenAckLoss
  | FScopedDropRefusal
  | FScopedDropAckLoss
  | FScopedQuarantineRefusal
  | FScopedQuarantineAckLoss
  | FRegistrationRefusal
  | FRegistrationAckLoss
  | FSealRefusal
  | FSealAckLoss
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The class attributes: identity, fault name, target, disposition,
-- refused and recovered observations, refusal field, scope-open tracking,
-- and the armed boundary (@_arm_refusal@).
data Config = Config
  { identity :: ProfileIdentity
  , faultName :: Text
  , faultTarget :: Text
  , faultDisposition :: FaultDisposition
  , refusedObservation :: Text
  , recoveredObservation :: Text
  , refusalField :: Text
  , trackScopeOpen :: Bool
  , arm :: Arm
  }

refuse', lose :: Text
refuse' = "history.commit-refuse"
lose = "history.lose-ack"

configOf :: Family -> Config
configOf = \case
  FBegin -> c Id.profileIdentity refuse' "activity_requested" Refuse "joined-begin-refused" "joined-begin-recovered" "commit_refusals" False CommitRefusal
  FDispatch -> c Id.dispatchProfileIdentity "dispatch.refuse" "activity_requested" Refuse "joined-dispatch-refused" "joined-dispatch-recovered" "dispatch_refusals" False DispatchRefusal
  FBeginAckLoss -> c Id.ackLossProfileIdentity lose "activity_requested_committed" Raise "joined-begin-ack-lost" "joined-begin-ack-recovered" "commit_ack_losses" False CommitAckLoss
  FDeliveryRefusal -> beginLike Id.deliveryRefusalProfileIdentity refuse' "delivery_accepted" Refuse False DeliveryRefusal
  FDeliveryAckLoss -> beginLike Id.deliveryAckLossProfileIdentity lose "delivery_accepted_committed" Raise False DeliveryAckLoss
  FProjection -> projection refuse' Refuse
  FProjectionAckLoss -> c Id.projectionAckLossProfileIdentity lose "projection_committed" Raise "joined-projection-ack-lost" "joined-projection-ack-recovered" "projection_ack_losses" False ProjectionAckLoss
  FTerminalRefusal -> c Id.terminalRefusalProfileIdentity refuse' "activity_completed" Refuse "joined-terminal-refused" "joined-terminal-recovered" "terminal_refusals" False TerminalRefusal
  FTerminalAckLoss -> c Id.terminalAckLossProfileIdentity lose "activity_completed_committed" Raise "joined-terminal-ack-lost" "joined-terminal-ack-recovered" "terminal_ack_losses" False TerminalAckLoss
  FFailureRefusal -> c Id.failureRefusalProfileIdentity refuse' "activity_failed" Refuse "joined-failure-refused" "joined-failure-recovered" "terminal_refusals" False TerminalRefusal
  FFailureAckLoss -> c Id.failureAckLossProfileIdentity lose "activity_failed_committed" Raise "joined-failure-ack-lost" "joined-failure-ack-recovered" "terminal_ack_losses" False TerminalAckLoss
  FFailureProjectionRefusal -> c Id.failureProjectionRefusalProfileIdentity refuse' "firing_failed" Refuse "joined-failure-projection-refused" "joined-failure-projection-recovered" "projection_refusals" False ProjectionRefusal
  FFailureProjectionAckLoss -> c Id.failureProjectionAckLossProfileIdentity lose "firing_failed_committed" Raise "joined-failure-projection-ack-lost" "joined-failure-projection-ack-recovered" "projection_ack_losses" False ProjectionAckLoss
  FCancellation -> c Id.cancellationProfileIdentity refuse' "cancellation_committed" Refuse "joined-cancellation-refused" "joined-cancellation-recovered" "cancellation_refusals" False CancellationRefusal
  FCancellationAckLoss -> c Id.cancellationAckLossProfileIdentity lose "cancellation_committed" Raise "joined-cancellation-ack-lost" "joined-cancellation-ack-recovered" "cancellation_ack_losses" False CancellationAckLoss
  FResetRefusal -> c Id.resetRefusalProfileIdentity refuse' "scope_reset" Refuse "joined-reset-refused" "joined-reset-recovered" "reset_refusals" False ResetRefusal
  FResetAckLoss -> c Id.resetAckLossProfileIdentity lose "scope_reset_committed" Raise "joined-reset-ack-lost" "joined-reset-ack-recovered" "reset_ack_losses" False ResetAckLoss
  FCloseRefusal -> c Id.closeRefusalProfileIdentity refuse' "scope_close" Refuse "joined-close-refused" "joined-close-recovered" "close_refusals" False CloseRefusal
  FCloseAckLoss -> c Id.closeAckLossProfileIdentity lose "scope_close_committed" Raise "joined-close-ack-lost" "joined-close-ack-recovered" "close_ack_losses" False CloseAckLoss
  FOpenRefusal -> c Id.openRefusalProfileIdentity refuse' "scope_open" Refuse "joined-open-refused" "joined-open-recovered" "open_refusals" True OpenRefusal
  FOpenAckLoss -> c Id.openAckLossProfileIdentity lose "scope_open_committed" Raise "joined-open-refused" "joined-open-recovered" "open_refusals" True OpenAckLoss
  FScopedDropRefusal -> beginLike Id.scopedDropRefusalProfileIdentity refuse' "scoped_delivery_dropped" Refuse True ScopedDropRefusal
  FScopedDropAckLoss -> beginLike Id.scopedDropAckLossProfileIdentity lose "scoped_delivery_dropped_committed" Raise True ScopedDropAckLoss
  FScopedQuarantineRefusal -> beginLike Id.scopedQuarantineRefusalProfileIdentity refuse' "scoped_delivery_quarantined" Refuse True ScopedQuarantineRefusal
  FScopedQuarantineAckLoss -> beginLike Id.scopedQuarantineAckLossProfileIdentity lose "scoped_delivery_quarantined_committed" Raise True ScopedQuarantineAckLoss
  FRegistrationRefusal -> c Id.registrationRefusalProfileIdentity refuse' "projection_committed" Refuse "joined-registration-projection-refused" "joined-registration-projection-recovered" "projection_refusals" False ProjectionRefusal
  FRegistrationAckLoss -> c Id.registrationAckLossProfileIdentity lose "projection_committed" Raise "joined-registration-projection-ack-lost" "joined-registration-projection-ack-recovered" "projection_ack_losses" False ProjectionAckLoss
  FSealRefusal -> (projection refuse' Refuse) {identity = Id.sealRefusalProfileIdentity, faultTarget = "source_sealed", arm = SealRefusal}
  FSealAckLoss -> (projection lose Raise) {identity = Id.sealAckLossProfileIdentity, faultTarget = "source_sealed_committed", arm = SealAckLoss}
  where
    c identity faultName faultTarget faultDisposition refusedObservation recoveredObservation refusalField trackScopeOpen arm =
      Config {identity, faultName, faultTarget, faultDisposition, refusedObservation, recoveredObservation, refusalField, trackScopeOpen, arm}
    beginLike identity name target disposition track arm' =
      c identity name target disposition "joined-begin-refused" "joined-begin-recovered" "commit_refusals" track arm'
    projection name disposition =
      c Id.projectionProfileIdentity name "projection_committed" disposition "joined-projection-refused" "joined-projection-recovered" "projection_refusals" False ProjectionRefusal

-- | The profile identity of a family.
familyIdentity :: Family -> ProfileIdentity
familyIdentity f = (configOf f).identity

isDelivery, isProjectionChain, isFailure, isCancellationChain, isClose, isOpen, isScoped, isQuarantine, isRegistration, isSeal :: Family -> Bool
isDelivery = (`elem` [FDeliveryRefusal, FDeliveryAckLoss])
isFailure = (`elem` [FFailureRefusal, FFailureAckLoss, FFailureProjectionRefusal, FFailureProjectionAckLoss])
isRegistration = (`elem` [FRegistrationRefusal, FRegistrationAckLoss])
isSeal = (`elem` [FSealRefusal, FSealAckLoss])
isProjectionChain f =
  f `elem` [FProjection, FProjectionAckLoss, FTerminalRefusal, FTerminalAckLoss] || isFailure f || isRegistration f || isSeal f
isClose = (`elem` [FCloseRefusal, FCloseAckLoss])
isOpen = (`elem` [FOpenRefusal, FOpenAckLoss])
isQuarantine = (`elem` [FScopedQuarantineRefusal, FScopedQuarantineAckLoss])
isScoped f = isQuarantine f || f `elem` [FScopedDropRefusal, FScopedDropAckLoss]
isCancellationChain f =
  f `elem` [FCancellation, FCancellationAckLoss, FResetRefusal, FResetAckLoss] || isClose f || isOpen f || isScoped f

-- ---------------------------------------------------------------------------
-- Generations and profiles

-- | @JoinedGeneration@.
data JoinedGeneration = JoinedGeneration
  { engine :: Engine
  , connection :: FaultConnection
  , worker :: IORef (Maybe AbsurdWorkerDispatch)
  , attempt :: IORef (Maybe ActivityAttempt)
  , poisoned :: IORef Bool
  }

-- | One profile instance and its profile-owned evidence.
data JoinedProfile = JoinedProfile
  { family :: Family
  , profile :: Profile IO JoinedGeneration
  , counters :: IORef (Map Text Integer)
  , transactionAttempts :: IORef [Json]
  , lifecycleAttempts :: IORef [Json]
  , deliveryAttempts :: IORef [Json]
  , scopedDeliveryAttempts :: IORef [Json]
  }

-- | Run a door, returning its refusal instead of raising it.
tryScenario :: Scenario IO a -> Scenario IO (Either ProfileError a)
tryScenario body = catchError (Right <$> body) (pure . Left)

-- | 'ioScenario' where an Absurd Worker's own error reads as the
-- reference's @RuntimeError@.
io :: IO a -> Scenario IO a
io body = ioScenario (body `catchAbsurd` \message -> throwIO (raised "RuntimeError" message))

catchAbsurd :: IO a -> (Text -> IO a) -> IO a
catchAbsurd body handler =
  try body >>= \case
    Right value -> pure value
    Left (e :: SomeException) -> case fromException e of
      Just (AbsurdError message) -> handler message
      Nothing -> throwIO e

-- | @JoinedBeginProfile(dsn)@ and every subclass, by family.
joinedProfile :: Family -> ByteString -> IO JoinedProfile
joinedProfile family dsn = do
  counters <- newIORef Map.empty
  transactionAttempts <- newIORef []
  lifecycleAttempts <- newIORef []
  deliveryAttempts <- newIORef []
  scopedDeliveryAttempts <- newIORef []
  externalWorker <- newIORef Nothing
  externalAttempt <- newIORef Nothing
  let cfg = configOf family
      bump name = modifyIORef' counters (Map.insertWith (+) name 1)
      counter name = Int . fromMaybe 0 . Map.lookup name <$> readIORef counters
      frontier = io (probeFrontier dsn instanceId)
      scheduledDrive = do
        at <- now
        pure ScheduledCommand {instant = at, command = Command {profile = cfg.identity, name = "engine.drive", payload = Object []}}
      applied value scheduled = pure ApplyResult {disposition = Applied, value = Object value, scheduled}
      refusedWith g failure expected = do
        unless (failure.errorType == "OSError" && failure.errorMessage `elem` expected) (throwError failure)
        liftIO (writeIORef g.poisoned True)

      -- _open
      open create = do
        connection <- newFaultConnection cfg.trackScopeOpen transactionAttempts lifecycleAttempts bump
        authority <- Pg.connect dsn False
        listener <- Pg.connect dsn True `onFailure` Pg.close authority
        let session = faultSession connection (absurdSession authority (Just listener))
            net
              | isDelivery family = deliveryApplicationNet
              | isCancellationChain family = lifecycleApplicationNet
              | isRegistration family = registrationNet "dst-world-joined-registration-projection"
              | isSeal family = registrationNet "dst-world-joined-seal"
              | otherwise = applicationNet
            marking
              | create && not (isDelivery family) && not (isCancellationChain family) =
                  markingFromList [(inputPlace, [Token (Just "Input") (Int 3)])]
              | otherwise = Engine.defaultEngineOptions.marking
            options = withBridge bridge Engine.defaultEngineOptions {Engine.marking = marking}
        engine <-
          openAbsurdEngine
            session
            (if create then CreateInstance else LoadInstance)
            net
            instanceId
            defaultAbsurdEngineOptions {defaultQueue = queue}
            options
        JoinedGeneration engine connection <$> newIORef Nothing <*> newIORef Nothing <*> newIORef False

      bridge =
        Bridged
          { prepare = \b -> case bindingTokens b of
              t : _ -> prepareInvocation (defaultInvocationFields "calculate" t.payload)
              [] -> Left "IndexError('tuple index out of range')"
          , project = \_ result ->
              let base = handlerTokens [(donePlace, [Token (Just "Done") result])]
               in Right $
                    if
                      | isRegistration family ->
                          base
                            { closes = [DeliveryRegistration sourcePlace "default"]
                            , opens = [DeliveryRegistration sourcePlace "replacement"]
                            }
                      | isSeal family -> base {opens = [DeliveryRegistration sourcePlace "subscription"]}
                      | otherwise -> base
          , onPrepare = Right () <$ bump "prepare_calls"
          , onProject = pure (Right ())
          }

      -- _configure_faults
      configureFaults g = do
        matched <- faults cfg.faultTarget
        forM matched $ \f -> do
          when (f.name /= cfg.faultName || f.disposition /= cfg.faultDisposition) $
            raise "ValueError" ("unsupported joined-begin fault " <> pythonStrRepr f.name)
          unless (exactKeys ["message"] f.payload) $
            raise "ValueError" (cfg.faultName <> " requires an exact message payload")
          message <- case member "message" f.payload of
            String m -> pure m
            _ -> raise "ValueError" (cfg.faultName <> " message must be a string")
          io (armFault g.connection cfg.arm message)
          pure message

      -- JoinedBeginProfile.apply
      beginApply g = do
        liftIO (bump "drive_calls")
        expected <- configureFaults g
        tryScenario (io (Engine.advance g.engine)) >>= \case
          Left failure -> do
            refusedWith g failure expected
            f <- frontier
            pure ApplyResult {disposition = RefusedExpected, value = Object [("error", String failure.errorMessage), ("frontier", Int f)], scheduled = []}
          Right outcome -> do
            current <- io (engineCurrent g.engine)
            f <- frontier
            applied
              [ ("firings", Array [String (netPathText firing.transition) | firing <- outcome.firings])
              , ("frontier", Int f)
              , ("ready", Bool outcome.ready)
              , ("status", member "status" current)
              , ("waiting", Bool outcome.waiting)
              ]
              []

      -- JoinedDeliveryRefusalProfile.apply
      deliveryApply g c = do
        let identity = textOf (member "identity" c.payload)
            value = member "value" c.payload
        expected <- configureFaults g
        disposition <-
          tryScenario (io (Engine.deliver g.engine sourcePlace [Token (Just "External") value] identity Nothing)) >>= \case
            Left failure -> refusedWith g failure expected >> pure RefusedExpected
            Right (Engine.DeliveryPrior _) -> pure Idempotent
            Right _ -> pure Applied
        let attempt' = Object [("disposition", String (actionDispositionText disposition)), ("identity", String identity), ("value", value)]
        liftIO (modifyIORef' deliveryAttempts (<> [attempt']))
        f <- frontier
        pure ApplyResult {disposition, value = Object [("attempt", attempt'), ("frontier", Int f)], scheduled = []}

      -- JoinedProjectionProfile.apply
      projectionApply g c = case c.name of
        "engine.drive" -> beginApply g
        "worker.claim" -> do
          existing <- liftIO (readIORef g.worker)
          when (isJust' existing) $ raise "RuntimeError" "joined-projection worker already exists"
          w <- io (openWorker "dst-joined-projection")
          io (Worker.claim w) >>= \case
            Nothing -> do
              io (Worker.close w)
              raise "RuntimeError" "joined-projection worker found no pending Activity"
            Just claimed -> do
              liftIO (writeIORef g.worker (Just w) >> writeIORef g.attempt (Just claimed))
              applied [("activity", String claimed.invocation.activity), ("claimed", Bool True)] []
        _ -> do
          (w, claimed) <- claimedBy g.worker g.attempt "worker.complete requires one claimed joined Activity"
          io (Worker.complete w claimed (member "result" c.payload))
          liftIO (writeIORef g.attempt Nothing >> bump "worker_completions")
          applied [("completed", Bool True)] []

      -- JoinedFailureRefusalProfile.apply
      failureApply g c = case c.name of
        "worker.fail" -> do
          (w, claimed) <- claimedBy g.worker g.attempt "worker.fail requires one claimed joined Activity"
          failure <-
            orRaise "ValueError" $
              activityFailure
                ActivityFailureFields
                  { failureError = textOf (member "error" c.payload)
                  , failureKind = "InvalidRequest"
                  , failureDetails = Object [("source", String "dst")]
                  , failureRetryable = False
                  , failureRetryAfter = Nothing
                  }
          io (Worker.fail w claimed (FailureClassified failure))
          liftIO (writeIORef g.attempt Nothing >> bump "worker_failures")
          applied [("failed", Bool True)] []
        "engine.drive" ->
          tryScenario (projectionApply g c) >>= \case
            Right result -> pure result
            Left failure
              | failure.errorType /= "RuntimeError" -> throwError failure
              | otherwise -> do
                  records <- io (withProbe dsn (`probeRecords` instanceId))
                  case reverse records of
                    RFiringFailed _ : RActivityFailed _ : _ -> do
                      liftIO (writeIORef g.poisoned True)
                      pure
                        ApplyResult
                          { disposition = ActionQuarantined
                          , value = Object [("error", String failure.errorMessage), ("frontier", jsonInt (length records))]
                          , scheduled = []
                          }
                    _ -> throwError failure
        _ -> projectionApply g c

      draftScope g = do
        scopes <- io (Engine.activeScopes g.engine)
        maybe (raise "KeyError" "'draft'") pure (Map.lookup "draft" scopes)

      -- JoinedCancellationProfile.apply
      cancellationApply g c = case c.name of
        "engine.drive" -> beginApply g
        "scope.open" -> do
          scope <- io (Engine.openScope g.engine "draft")
          liftIO (bump "scope_opens")
          f <- frontier
          applied [("frontier", Int f), ("generation", Int (scopeGeneration scope))] []
        "source.deliver" -> do
          scope <- draftScope g
          _ <- io (Engine.deliver g.engine sourcePlace [Token (Just "Input") (Int 3)] "draft-input-3" (Just (ScopeGeneration scope)))
          liftIO (bump "source_deliveries")
          f <- frontier
          drive <- scheduledDrive
          applied [("frontier", Int f)] [drive]
        "worker.claim" -> do
          existing <- liftIO (readIORef externalWorker)
          when (isJust' existing) $ raise "RuntimeError" "joined-cancellation Worker already exists"
          w <- io (openWorker "dst-joined-cancellation")
          io (Worker.claim w) >>= \case
            Nothing -> do
              io (Worker.close w)
              raise "RuntimeError" "joined-cancellation Worker found no pending Activity"
            Just claimed -> do
              liftIO $ do
                writeIORef externalWorker (Just w)
                writeIORef externalAttempt (Just claimed)
                bump "worker_claims"
              applied [("activity", String claimed.invocation.activity), ("claimed", Bool True)] []
        "worker.complete-stale" -> do
          (w, claimed) <- claimedBy externalWorker externalAttempt "worker.complete-stale requires one claimed joined Activity"
          outcome <- io (catchAbsurd (Right <$> Worker.complete w claimed (Object [("value", Int 3)])) (pure . Left))
          case outcome of
            Left message
              | "stale Activity Attempt" `T.isInfixOf` message -> do
                  liftIO (bump "stale_worker_refusals" >> writeIORef externalAttempt Nothing)
                  pure ApplyResult {disposition = RefusedExpected, value = Object [("reason", String "stale Activity Attempt")], scheduled = []}
              | otherwise -> raise "RuntimeError" message
            Right () -> raise "AssertionError" "cancelled Absurd custody accepted a stale Worker completion"
        _ -> do
          expected <- configureFaults g
          tryScenario (draftScope g >>= io . Engine.resetScope g.engine) >>= \case
            Left failure -> do
              refusedWith g failure expected
              liftIO (bump "scope_resets")
              f <- frontier
              pure ApplyResult {disposition = RefusedExpected, value = Object [("error", String failure.errorMessage), ("frontier", Int f)], scheduled = []}
            Right opened -> do
              liftIO (bump "scope_resets")
              f <- frontier
              applied [("frontier", Int f), ("generation", Int (scopeGeneration opened))] []

      -- JoinedResetRefusalProfile.apply
      resetApply g c
        | c.name /= "worker.complete" = cancellationApply g c
        | otherwise = do
            (w, claimed) <- claimedBy externalWorker externalAttempt "worker.complete requires one claimed joined Activity"
            io (Worker.complete w claimed (Object [("value", Int 3)]))
            liftIO (writeIORef externalAttempt Nothing >> bump "worker_completions")
            drive <- scheduledDrive
            applied [("completed", Bool True)] [drive]

      -- JoinedCloseRefusalProfile.apply
      closeApply g c
        | c.name /= "scope.close" = resetApply g c
        | otherwise = do
            expected <- configureFaults g
            tryScenario (draftScope g >>= io . Engine.closeScope g.engine) >>= \case
              Left failure -> do
                refusedWith g failure expected
                liftIO (bump "scope_closes")
                f <- frontier
                pure ApplyResult {disposition = RefusedExpected, value = Object [("error", String failure.errorMessage), ("frontier", Int f)], scheduled = []}
              Right closure -> do
                liftIO (bump "scope_closes")
                f <- frontier
                applied
                  [ ("cancelled", Array (map jsonInt closure.cancelled))
                  , ("discarded", Array (map jsonInt closure.discarded))
                  , ("frontier", Int f)
                  ]
                  []

      -- JoinedOpenRefusalProfile.apply
      openApply g = do
        expected <- configureFaults g
        tryScenario (io (Engine.openScope g.engine "draft")) >>= \case
          Left failure -> do
            refusedWith g failure expected
            liftIO (bump "scope_opens")
            f <- frontier
            pure ApplyResult {disposition = RefusedExpected, value = Object [("error", String failure.errorMessage), ("frontier", Int f)], scheduled = []}
          Right scope -> do
            liftIO (bump "scope_opens")
            f <- frontier
            applied [("frontier", Int f), ("generation", Int (scopeGeneration scope))] []

      -- JoinedScopedDropRefusalProfile / JoinedScopedQuarantineRefusalProfile.apply
      scopedApply g c = do
        let quarantine = isQuarantine family
            identity = textOf (member "identity" c.payload)
            value = member "value" c.payload
            generation = case member "scope_generation" c.payload of
              Int n -> n
              _ -> 0
        wasRecorded <- not . null <$> io (if quarantine then canonicalQuarantines else canonicalDrops)
        expected <- configureFaults g
        scope <- orRaise "ValueError" (lifecycleScope "draft" generation)
        (disposition, result) <-
          tryScenario (io (Engine.deliver g.engine sourcePlace [Token (Just "Input") value] identity (Just (ScopeGeneration scope)))) >>= \case
            Left failure -> do
              refusedWith g failure expected
              pure (RefusedExpected, [("error", String failure.errorMessage)])
            Right (Engine.DeliveryScoped ack) -> do
              let wanted = if quarantine then Instance.Quarantined else Dropped
              when (ack.disposition /= wanted) $
                raise "AssertionError" (if quarantine then "future generation was not quarantined" else "stale generation was not dropped")
              pure
                ( if wasRecorded then Idempotent else Applied
                , [("delivery_disposition", String (if quarantine then "quarantined" else "dropped"))]
                )
            Right _ ->
              raise
                "AssertionError"
                ( if quarantine
                    then "future-scope delivery did not return a scoped acknowledgement"
                    else "stale-scope delivery did not return a scoped acknowledgement"
                )
        let attempt' =
              Object
                [ ("disposition", String (actionDispositionText disposition))
                , ("identity", String identity)
                , ("scope_generation", Int generation)
                , ("value", value)
                ]
        liftIO (modifyIORef' scopedDeliveryAttempts (<> [attempt']))
        f <- frontier
        pure ApplyResult {disposition, value = Object (result <> [("attempt", attempt'), ("frontier", Int f)]), scheduled = []}

      -- JoinedSealRefusalProfile.apply
      sealApply g c
        | c.name /= "source.seal" = projectionApply g c
        | otherwise = do
            expected <- configureFaults g
            tryScenario (io (Engine.seal g.engine sourcePlace)) >>= \case
              Left failure -> do
                refusedWith g failure expected
                liftIO (bump "seal_calls")
                f <- frontier
                pure ApplyResult {disposition = RefusedExpected, value = Object [("error", String failure.errorMessage), ("frontier", Int f)], scheduled = []}
              Right () -> do
                liftIO (bump "seal_calls")
                f <- frontier
                applied [("frontier", Int f), ("source", String "source")] []

      apply' g c
        | family `elem` [FBegin, FDispatch, FBeginAckLoss] = beginApply g
        | isDelivery family = deliveryApply g c
        | isFailure family = failureApply g c
        | isSeal family = sealApply g c
        | isProjectionChain family = projectionApply g c
        | isOpen family = openApply g
        | isScoped family =
            if c.name == (if isQuarantine family then "source.deliver-future" else "source.deliver-stale")
              then scopedApply g c
              else cancellationApply g c
        | isClose family = closeApply g c
        | family == FResetRefusal = resetApply g c
        | otherwise = cancellationApply g c

      canonicalDrops = withProbe dsn $ \probe -> do
        records <- probeRecords probe instanceId
        pure
          [ scopedView r.identity (scopeName r.scope) (scopeGeneration r.scope) r.source r.tokens
          | RScopedDeliveryDropped r <- records
          ]
      canonicalQuarantines = withProbe dsn $ \probe -> do
        records <- probeRecords probe instanceId
        pure
          [ scopedView r.identity (scopeName scope) (scopeGeneration scope) r.source r.tokens
          | RScopedDeliveryQuarantined r <- records
          , QuarantineGeneration scope <- [r.scope]
          ]

      -- _observation_state (the union of every class's extensions)
      state g = do
        (records, tasks) <- withProbe dsn $ \probe -> (,) <$> probeRecords probe instanceId <*> probeTasks probe queue
        isPoisoned <- readIORef g.poisoned
        current <- if isPoisoned then pure Null else engineCurrent g.engine
        let status = if isPoisoned then String "poisoned" else member "status" current
        values <- readIORef counters
        transactions <- readIORef transactionAttempts
        lifecycle <- readIORef lifecycleAttempts
        deliveries <- readIORef deliveryAttempts
        scoped <- readIORef scopedDeliveryAttempts
        drops <- if isScoped family then canonicalDrops else pure []
        quarantines <- if isQuarantine family then canonicalQuarantines else pure []
        active <-
          if isOpen family && not isPoisoned
            then Just <$> Engine.activeScopes g.engine
            else pure Nothing
        let counterNames =
              [ "cancellation_ack_losses"
              , "cancellation_refusals"
              , "close_ack_losses"
              , "close_refusals"
              , "closes"
              , "commit_ack_losses"
              , "commit_refusals"
              , "delivery_ack_losses"
              , "delivery_refusals"
              , "dispatch_refusals"
              , "drive_calls"
              , "drops"
              , "open_ack_losses"
              , "open_refusals"
              , "prepare_calls"
              , "projection_ack_losses"
              , "projection_refusals"
              , "reset_ack_losses"
              , "reset_refusals"
              , "scope_closes"
              , "scope_opens"
              , "scope_resets"
              , "scoped_drop_ack_losses"
              , "scoped_drop_refusals"
              , "scoped_quarantine_ack_losses"
              , "scoped_quarantine_refusals"
              , "seal_ack_losses"
              , "seal_calls"
              , "seal_refusals"
              , "source_deliveries"
              , "stale_worker_refusals"
              , "terminal_ack_losses"
              , "terminal_refusals"
              , "worker_claims"
              , "worker_completions"
              , "worker_failures"
              ]
            registrations =
              Array $
                concat
                  [ case r of
                      RDeliveryRegistrationOpened o -> [registrationView "opened" o.key o.occurrence o.source]
                      RDeliveryRegistrationClosed o -> [registrationView "closed" o.key o.occurrence o.source]
                      _ -> []
                  | r <- records
                  ]
        pure $
          [(name, Int (fromMaybe 0 (Map.lookup name values))) | name <- counterNames]
            <> [ ("durable_tasks", tasks)
               , ("frontier", jsonInt (length records))
               , ("record_types", strs (map recordName records))
               , ("status", status)
               , ("transaction_attempts", Array transactions)
               , ("lifecycle_attempts", Array lifecycle)
               , ("delivery_attempts", Array deliveries)
               , ("scoped_delivery_attempts", Array scoped)
               , ( "canonical_deliveries"
                 , Array
                     [ Object
                         [ ("identity", String r.identity)
                         , ("occurrence", jsonInt r.occurrence)
                         , ("value", firstPayload r.tokens)
                         ]
                     | RExternalEventDelivered r <- records
                     ]
                 )
               , ("firing_completed", jsonInt (length [() | RFiringCompleted _ <- records]))
               , ("produced_values", Array [t.payload | RTokensProduced r <- records, r.place == donePlace, t <- r.tokens])
               , ("active_scopes", maybe Null (\scopes -> Object [(n, Int (scopeGeneration s)) | (n, s) <- Map.toAscList scopes]) active)
               , ( "canonical_scopes"
                 , Array
                     [ Object [("generation", Int (scopeGeneration r.scope)), ("name", String (scopeName r.scope))]
                     | RScopeOpened r <- records
                     ]
                 )
               , ("canonical_drops", Array drops)
               , ("canonical_quarantines", Array quarantines)
               , ("lifecycle_records", Array (concatMap lifecycleRecord records))
               , ("canonical_registrations", registrations)
               , ("engine_armed", if isPoisoned then Null else member "armed" current)
               ]

      observe' g request = do
        let authorityLayer = observationLayers family
            select' fields = select fields <$> io (state g)
            flat names unknown params fields = do
              unless (request.name `elem` names) $ raise "ValueError" (unknown <> " " <> pythonStrRepr request.name)
              unless (payloadAbsent request.payload) $ raise "ValueError" params
              select' fields
            beginObserve = do
              unless (request.name `elem` ["engine.joined-commit-authority", cfg.refusedObservation, cfg.recoveredObservation]) $
                raise "ValueError" ("unknown joined-begin observation " <> pythonStrRepr request.name)
              unless (payloadAbsent request.payload) $ raise "ValueError" "joined-begin observations do not accept parameters"
              if request.name == "engine.joined-commit-authority"
                then select' ["durable_tasks", "prepare_calls", "record_types", "transaction_attempts"]
                else
                  select'
                    [ cfg.refusalField
                    , "drops"
                    , "durable_tasks"
                    , "frontier"
                    , "prepare_calls"
                    , "record_types"
                    , "status"
                    , "transaction_attempts"
                    ]
            layered [] = beginObserve
            layered (layer : rest)
              | request.name == layer.authority = do
                  unless (payloadAbsent request.payload) $ raise "ValueError" layer.parameters
                  select' layer.fields
              | otherwise = do
                  value <- layered rest
                  extra <- select layer.extra <$> io (state g)
                  pure (mergeObject value (members extra))
        case flatObservations family of
          Just (names, unknown, params, fields) -> flat names unknown params fields
          Nothing -> layered authorityLayer

      dispose g =
        ( readIORef g.worker >>= \case
            Just w -> Worker.close w
            Nothing -> pure ()
        )
          `finally` Engine.close g.engine

      validate' c = validateCommand family c

      profile =
        Profile
          { identity = cfg.identity
          , validate = validate'
          , validateFault = \f ->
              if f.name /= cfg.faultName
                || f.target /= cfg.faultTarget
                || f.disposition /= cfg.faultDisposition
                || not (exactKeys ["message"] f.payload)
                || not (isString (member "message" f.payload))
                then throwError (ProfileError "ValueError" ("unsupported joined-begin fault for " <> cfg.identity.name))
                else pure f
          , create = do
              g <- io (open True)
              pure GenerationStart {generation = g, scheduled = []}
          , load = do
              g <- io (open False)
              if isDelivery family || isOpen family || isScoped family || isSeal family
                then pure GenerationStart {generation = g, scheduled = []}
                else do
                  drive <- scheduledDrive
                  pure GenerationStart {generation = g, scheduled = [drive]}
          , apply = apply'
          , observe = observe'
          , dropGeneration = \g -> ioDoor (bump "drops" >> dispose g)
          , closeGeneration = \g ->
              ioDoor $ do
                bump "closes"
                if isCancellationChain family
                  then
                    ( readIORef externalWorker >>= \case
                        Just w -> do
                          Worker.close w
                          writeIORef externalWorker Nothing
                          writeIORef externalAttempt Nothing
                        Nothing -> pure ()
                    )
                      `finally` dispose g
                  else dispose g
          , resourceUsage = Nothing
          }
      openWorker workerId =
        openAbsurdWorkerDispatch dsn defaultAbsurdWorkerOptions {queues = [queue], workerId = Just workerId}
  _ <- pure counter
  pure JoinedProfile {family, profile, counters, transactionAttempts, lifecycleAttempts, deliveryAttempts, scopedDeliveryAttempts}
  where
    isString = \case
      String _ -> True
      _ -> False
    isJust' = \case
      Just _ -> True
      Nothing -> False
    members = \case
      Object ms -> ms
      _ -> []
    onFailure body cleanup =
      try body >>= \case
        Right value -> pure value
        Left (e :: SomeException) -> cleanup >> throwIO e

-- | The claimed Worker and attempt, or the reference's @RuntimeError@.
claimedBy :: IORef (Maybe AbsurdWorkerDispatch) -> IORef (Maybe ActivityAttempt) -> Text -> Scenario IO (AbsurdWorkerDispatch, ActivityAttempt)
claimedBy workerRef attemptRef message = do
  w <- liftIO (readIORef workerRef)
  a <- liftIO (readIORef attemptRef)
  case (w, a) of
    (Just w', Just a') -> pure (w', a')
    _ -> raise "RuntimeError" message

textOf :: Json -> Text
textOf = \case
  String s -> s
  _ -> ""

firstPayload :: [Token] -> Json
firstPayload = \case
  t : _ -> t.payload
  [] -> Null

scopedView :: Text -> Text -> Integer -> NetPath -> [Token] -> Json
scopedView identity name generation from tokens =
  Object
    [ ("identity", String identity)
    , ("scope_generation", Int generation)
    , ("scope_name", String name)
    , ("source", String (netPathText from))
    , ("value", firstPayload tokens)
    ]

registrationView :: Text -> Text -> Maybe Int -> NetPath -> Json
registrationView kind key occurrence from =
  Object
    [ ("key", String key)
    , ("kind", String kind)
    , ("occurrence", maybe Null jsonInt occurrence)
    , ("source", String (netPathText from))
    ]

lifecycleRecord :: Record -> [Json]
lifecycleRecord = \case
  RScopeOpened r ->
    [Object [("generation", Int (scopeGeneration r.scope)), ("kind", String "opened"), ("name", String (scopeName r.scope))]]
  RScopeReset r ->
    [ Object
        [ ("closed_generation", Int (scopeGeneration r.closed))
        , ("kind", String "reset")
        , ("name", String (scopeName r.closed))
        , ("opened_generation", Int (scopeGeneration r.opened))
        ]
    ]
  _ -> []

-- ---------------------------------------------------------------------------
-- Observation layers

-- | One @observe@ override of the projection chain: its own authority
-- observation, and the fields it adds to its parent's value otherwise.
data Layer = Layer {authority :: Text, parameters :: Text, fields :: [Text], extra :: [Text]}

projectionLayer, failureLayer, failureProjectionLayer :: Layer
projectionLayer =
  Layer
    "engine.joined-projection-authority"
    "joined-projection authority observation does not accept parameters"
    ["durable_tasks", "prepare_calls", "projection_refusals", "record_types", "transaction_attempts", "worker_completions"]
    ["worker_completions"]
failureLayer =
  Layer
    "engine.joined-failure-authority"
    "joined failure authority observation does not accept parameters"
    ["durable_tasks", "prepare_calls", "record_types", "terminal_refusals", "transaction_attempts", "worker_failures"]
    ["drive_calls", "terminal_refusals", "worker_failures"]
failureProjectionLayer =
  Layer
    "engine.joined-failure-projection-authority"
    "joined failure-projection authority observation does not accept parameters"
    ["durable_tasks", "prepare_calls", "projection_refusals", "record_types", "transaction_attempts", "worker_failures"]
    ["projection_refusals"]

-- | The @observe@ overrides from the most derived class to
-- @JoinedBeginProfile@ (exclusive).
observationLayers :: Family -> [Layer]
observationLayers = \case
  FBeginAckLoss ->
    [ Layer
        "engine.joined-accepted-begin-authority"
        "joined accepted-begin authority observation does not accept parameters"
        ["commit_ack_losses", "durable_tasks", "prepare_calls", "record_types", "transaction_attempts"]
        ["drive_calls"]
    ]
  FProjection -> [projectionLayer]
  FProjectionAckLoss ->
    [ Layer
        "engine.joined-accepted-projection-authority"
        "joined accepted-projection authority observation does not accept parameters"
        ["durable_tasks", "prepare_calls", "projection_ack_losses", "record_types", "transaction_attempts", "worker_completions"]
        ["drive_calls", "projection_ack_losses"]
    , projectionLayer
    ]
  FTerminalRefusal ->
    [ Layer
        "engine.joined-terminal-authority"
        "joined terminal authority observation does not accept parameters"
        ["durable_tasks", "prepare_calls", "record_types", "terminal_refusals", "transaction_attempts", "worker_completions"]
        ["drive_calls", "terminal_refusals"]
    , projectionLayer
    ]
  FTerminalAckLoss ->
    [ Layer
        "engine.joined-accepted-terminal-authority"
        "joined accepted-terminal authority observation does not accept parameters"
        ["durable_tasks", "prepare_calls", "record_types", "terminal_ack_losses", "transaction_attempts", "worker_completions"]
        ["drive_calls", "terminal_ack_losses"]
    , projectionLayer
    ]
  FFailureRefusal -> [failureLayer, projectionLayer]
  FFailureAckLoss ->
    [ Layer
        "engine.joined-accepted-failure-authority"
        "joined accepted-failure authority observation does not accept parameters"
        ["durable_tasks", "prepare_calls", "record_types", "terminal_ack_losses", "transaction_attempts", "worker_failures"]
        ["terminal_ack_losses"]
    , failureLayer
    , projectionLayer
    ]
  FFailureProjectionRefusal -> [failureProjectionLayer, failureLayer, projectionLayer]
  FFailureProjectionAckLoss ->
    [ Layer
        "engine.joined-accepted-failure-projection-authority"
        "joined accepted failure-projection authority observation does not accept parameters"
        ["durable_tasks", "prepare_calls", "projection_ack_losses", "record_types", "transaction_attempts", "worker_failures"]
        ["projection_ack_losses"]
    , failureProjectionLayer
    , failureLayer
    , projectionLayer
    ]
  _ -> []

cancellationFields :: [Text]
cancellationFields =
  [ "cancellation_refusals"
  , "drops"
  , "drive_calls"
  , "durable_tasks"
  , "frontier"
  , "lifecycle_attempts"
  , "prepare_calls"
  , "record_types"
  , "scope_opens"
  , "scope_resets"
  , "source_deliveries"
  , "stale_worker_refusals"
  , "status"
  , "transaction_attempts"
  , "worker_claims"
  ]

-- | The classes whose @observe@ selects one closed field list: names,
-- unknown-name message, parameter message, and fields.
flatObservations :: Family -> Maybe ([Text], Text, Text, [Text])
flatObservations = \case
  FDeliveryRefusal -> delivery ["engine.joined-delivery-authority", "joined-delivery-refused", "joined-delivery-recovered", "joined-delivery-redelivered"]
  FDeliveryAckLoss -> delivery ["engine.joined-delivery-authority", "joined-delivery-ack-lost", "joined-delivery-ack-recovered"]
  FCancellation ->
    cancellation
      ["engine.joined-cancellation-authority", "joined-cancellation-ready", "joined-cancellation-refused", "joined-cancellation-recovered", "joined-late-worker-fenced"]
      []
  FCancellationAckLoss ->
    cancellation
      [ "engine.joined-accepted-cancellation-authority"
      , "joined-cancellation-ack-ready"
      , "joined-cancellation-ack-lost"
      , "joined-cancellation-ack-recovered"
      , "joined-cancellation-ack-worker-fenced"
      ]
      ["cancellation_ack_losses"]
  FResetRefusal ->
    cancellation
      ["engine.joined-reset-refusal-authority", "joined-reset-ready", "joined-reset-refused", "joined-reset-recovered", "joined-reset-terminal-recovered"]
      ["reset_refusals", "worker_completions"]
  FResetAckLoss ->
    cancellation
      ["engine.joined-accepted-reset-authority", "joined-reset-ack-ready", "joined-reset-ack-lost", "joined-reset-ack-recovered", "joined-reset-ack-worker-fenced"]
      ["reset_ack_losses", "reset_refusals"]
  FCloseRefusal ->
    cancellation
      ["engine.joined-close-refusal-authority", "joined-close-ready", "joined-close-refused", "joined-close-recovered", "joined-close-terminal-recovered"]
      ["close_refusals", "scope_closes", "worker_completions"]
  FCloseAckLoss ->
    cancellation
      ["engine.joined-accepted-close-authority", "joined-close-ack-ready", "joined-close-ack-lost", "joined-close-ack-recovered", "joined-close-ack-worker-fenced"]
      ["close_ack_losses", "close_refusals", "scope_closes"]
  FOpenRefusal -> open' ["engine.joined-open-authority", "joined-open-refused", "joined-open-absent", "joined-open-recovered"]
  FOpenAckLoss -> open' ["engine.joined-open-authority", "joined-open-ack-lost", "joined-open-ack-recovered"]
  FScopedDropRefusal ->
    scopedDrop ["engine.joined-scoped-drop-authority", "joined-scoped-drop-refused", "joined-scoped-drop-recovered", "joined-scoped-drop-redelivered"]
  FScopedDropAckLoss ->
    scopedDrop ["engine.joined-accepted-scoped-drop-authority", "joined-scoped-drop-ack-lost", "joined-scoped-drop-ack-recovered"]
  FScopedQuarantineRefusal ->
    scopedQuarantine
      ["engine.joined-scoped-quarantine-authority", "joined-scoped-quarantine-refused", "joined-scoped-quarantine-recovered", "joined-scoped-quarantine-redelivered"]
  FScopedQuarantineAckLoss ->
    scopedQuarantine ["engine.joined-accepted-scoped-quarantine-authority", "joined-scoped-quarantine-ack-lost", "joined-scoped-quarantine-ack-recovered"]
  FRegistrationRefusal ->
    registration ["engine.joined-registration-projection-authority", "joined-registration-projection-refused", "joined-registration-projection-recovered"]
  FRegistrationAckLoss ->
    registration ["engine.joined-registration-projection-authority", "joined-registration-projection-ack-lost", "joined-registration-projection-ack-recovered"]
  FSealRefusal ->
    seal ["engine.joined-seal-authority", "joined-seal-ready", "joined-seal-refused", "joined-seal-reloaded", "joined-seal-recovered"]
  FSealAckLoss -> seal ["engine.joined-seal-authority", "joined-seal-ready", "joined-seal-ack-lost", "joined-seal-ack-recovered"]
  _ -> Nothing
  where
    delivery names =
      Just
        ( names
        , "unknown joined-delivery observation"
        , "joined-delivery observations do not accept parameters"
        , [ "canonical_deliveries"
          , "delivery_ack_losses"
          , "delivery_attempts"
          , "delivery_refusals"
          , "drops"
          , "firing_completed"
          , "frontier"
          , "produced_values"
          , "status"
          , "transaction_attempts"
          ]
        )
    cancellation names extra =
      Just (names, "unknown joined-cancellation observation", "joined-cancellation observations do not accept parameters", cancellationFields <> extra)
    open' names =
      Just
        ( names
        , "unknown joined-cancellation observation"
        , "joined-cancellation observations do not accept parameters"
        , [ "active_scopes"
          , "canonical_scopes"
          , "drops"
          , "frontier"
          , "lifecycle_attempts"
          , "open_ack_losses"
          , "open_refusals"
          , "record_types"
          , "scope_opens"
          , "status"
          ]
        )
    scopedDrop names =
      Just
        ( names
        , "unknown joined scoped-drop observation"
        , "joined scoped-drop observations do not accept parameters"
        , [ "canonical_drops"
          , "drops"
          , "frontier"
          , "lifecycle_attempts"
          , "lifecycle_records"
          , "record_types"
          , "scope_opens"
          , "scope_resets"
          , "scoped_delivery_attempts"
          , "scoped_drop_ack_losses"
          , "scoped_drop_refusals"
          , "status"
          , "transaction_attempts"
          ]
        )
    scopedQuarantine names =
      Just
        ( names
        , "unknown joined scoped-drop observation"
        , "joined scoped-drop observations do not accept parameters"
        , [ "canonical_quarantines"
          , "drops"
          , "frontier"
          , "lifecycle_attempts"
          , "lifecycle_records"
          , "record_types"
          , "scope_opens"
          , "scoped_delivery_attempts"
          , "scoped_quarantine_ack_losses"
          , "scoped_quarantine_refusals"
          , "status"
          , "transaction_attempts"
          ]
        )
    registration names =
      Just
        ( names
        , "unknown joined-registration observation"
        , "joined-registration observations do not accept parameters"
        , [ "canonical_registrations"
          , "drive_calls"
          , "durable_tasks"
          , "engine_armed"
          , "frontier"
          , "prepare_calls"
          , "projection_ack_losses"
          , "projection_refusals"
          , "record_types"
          , "status"
          , "transaction_attempts"
          , "worker_completions"
          ]
        )
    seal names =
      Just
        ( names
        , "unknown joined-seal observation"
        , "joined-seal observations do not accept parameters"
        , [ "canonical_registrations"
          , "drive_calls"
          , "durable_tasks"
          , "engine_armed"
          , "frontier"
          , "lifecycle_attempts"
          , "prepare_calls"
          , "record_types"
          , "seal_ack_losses"
          , "seal_calls"
          , "seal_refusals"
          , "status"
          , "transaction_attempts"
          , "worker_completions"
          ]
        )

-- ---------------------------------------------------------------------------
-- Command validation

-- | Each class's @validate@, following its method resolution.
validateCommand :: Family -> Command -> Door IO Command
validateCommand family c
  | family `elem` [FBegin, FDispatch, FBeginAckLoss] =
      if c.name /= "engine.drive" || not (empty c.payload)
        then refuse "joined-begin profile accepts only engine.drive with an empty payload"
        else pure c
  | isDelivery family = delivery
  | isFailure family = failure
  | isSeal family = if c.name == "source.seal" && empty c.payload then pure c else projection
  | isProjectionChain family = projection
  | isOpen family =
      if c.name == "scope.open" && pythonEq c.payload draft
        then pure c
        else refuse ("unsupported joined-open command " <> pythonStrRepr c.name)
  | isQuarantine family =
      if (c.name == "scope.open" && pythonEq c.payload draft)
        || (c.name == "source.deliver-future" && pythonEq c.payload (scoped "future-draft-3" 2))
        then pure c
        else refuse ("unsupported joined scoped-quarantine command " <> pythonStrRepr c.name)
  | isScoped family =
      if (c.name `elem` ["scope.open", "scope.reset"] && pythonEq c.payload draft)
        || (c.name == "source.deliver-stale" && pythonEq c.payload (scoped "stale-draft-3" 1))
        then pure c
        else refuse ("unsupported joined scoped-drop command " <> pythonStrRepr c.name)
  | family == FCloseAckLoss =
      if c.name == "worker.complete"
        then refuse "joined-close acknowledgement-loss profile does not accept worker.complete"
        else close
  | family == FCloseRefusal = close
  | family == FResetRefusal = reset
  | otherwise = cancellation
  where
    refuse = throwError . ProfileError "ValueError"
    empty = pythonEq (Object [])
    draft = Object [("name", String "draft")]
    scoped identity generation = Object [("identity", String identity), ("scope_generation", Int generation), ("value", Int 3)]
    delivery
      | c.name /= "source.deliver" = refuse ("unknown joined-delivery command " <> pythonStrRepr c.name)
      | not (exactKeys ["identity", "value"] c.payload) = refuse "source.deliver requires exact identity and value fields"
      | not (nonEmptyString (member "identity" c.payload)) = refuse "source.deliver identity must be a non-empty string"
      | not (isInt (member "value" c.payload)) = refuse "source.deliver value must be an integer"
      | otherwise = pure c
    projection
      | c.name `elem` ["engine.drive", "worker.claim"] && empty c.payload = pure c
      | c.name == "worker.complete" && exactKeys ["result"] c.payload = pure c
      | otherwise = refuse ("unsupported joined-projection command " <> pythonStrRepr c.name)
    failure
      | c.name `elem` ["engine.drive", "worker.claim"] && empty c.payload = pure c
      | c.name == "worker.fail" && exactKeys ["error"] c.payload && isStr (member "error" c.payload) = pure c
      | otherwise = refuse ("unsupported joined-failure command " <> pythonStrRepr c.name)
    cancellation
      | c.name `elem` ["engine.drive", "worker.claim", "worker.complete-stale"] && empty c.payload = pure c
      | c.name `elem` ["scope.open", "scope.reset"] && pythonEq c.payload draft = pure c
      | c.name == "source.deliver"
          && isPyObject c.payload
          && pythonEq c.payload (Object [("identity", String "draft-input-3"), ("scope", String "draft"), ("value", Int 3)]) =
          pure c
      | otherwise = refuse ("unsupported joined-cancellation command " <> pythonStrRepr c.name)
    reset
      | c.name == "worker.complete" && empty c.payload = pure c
      | otherwise = cancellation
    close
      | c.name == "scope.close" && pythonEq c.payload draft = pure c
      | otherwise = reset
    nonEmptyString = \case
      String s -> not (T.null s)
      _ -> False
    isStr = \case
      String _ -> True
      _ -> False
    isInt = \case
      Int _ -> True
      _ -> False

-- Keep the imported record field selectors referenced for -Wunused-imports.
_unusedFields :: (ExternalEventDelivered -> Text, ScopeReset -> LifecycleScope, ScopeOpened -> LifecycleScope, TokensProduced -> NetPath, ScopedDeliveryDropped -> Text, ScopedDeliveryQuarantined -> Text, DeliveryRegistrationOpened -> Text, DeliveryRegistrationClosed -> Text, ScopeClosure -> [Int], ScopedDeliveryAcknowledgement -> DeliveryDisposition, FiringOutcome -> NetPath, ActivityInvocation -> Text)
_unusedFields = ((.identity), (.closed), (.scope), (.place), (.identity), (.identity), (.key), (.key), (.cancelled), (.disposition), (.transition), (.activity))
