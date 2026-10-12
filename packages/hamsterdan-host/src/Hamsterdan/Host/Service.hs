{-# LANGUAGE MultiWayIf #-}

-- | Process-owned composition, startup authority reconciliation, and the
-- inbox worker (@host/service.py@).
--
-- One 'HostService' owns a state root: the installation registry
-- (@routes.sqlite3@), the webhook inbox (@webhooks.sqlite3@), the runnable
-- index (@runnable.sqlite3@), the shared durable Activity dispatch
-- (@activity-dispatch.sqlite3@), and one application per PR Instance under
-- @applications/{installation}/{repository}/{pull request}@.
--
-- The reference's constructor seams are explicit here: the application
-- factory ('ApplicationFactory'), the GitHub clients ('HostClients'), the
-- agent route custody ('AgentCustody'), the clock, and the transport
-- factory. Its tests' instance monkeypatches are 'ServiceHooks'.
module Hamsterdan.Host.Service
  ( -- * Qualification faults
    QualificationFault (..)
  , qualificationFault
  , qualificationFaultFromEnvironment
  , faultPublication
  , faultAgent
  , spentOperation

    -- * The application boundary
  , HostApplication (..)
  , ApplicationFactory
  , v5ApplicationFactory
  , hostApplication

    -- * Composition seams
  , HostClients (..)
  , gitHubHostClients
  , AgentCustody (..)
  , noAgentCustody
  , routedRunner

    -- * The service
  , ServiceOptions (..)
  , serviceOptions
  , ServiceHooks (..)
  , defaultServiceHooks
  , HostService (..)
  , InstanceKey (..)
  , Loaded (..)
  , Selected (..)
  , openHostService
  , CustodyOneResult (..)
  , CustodyDisposition (..)
  , custodyDispositionText

    -- * Operations
  , resolveActivity
  , guardDurableActivity
  , reconcileRegistration
  , application
  , applicationKeys
  , loadedApplication
  , sweep
  , process
  , pump
  , processOne
  , runOneActivity
  , subjectState
  , workState
  , reconcileOne
  , projectPending
  , recordPosture
  , activateInstance
  , runDue
  , worker
  , stop
  , isStopped
  , health
  , settleTerminalsForShutdown
  , abort
  , close

    -- * Logging
  , logWarning
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.STM (atomically, readTVar, registerDelay, retry)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (foldM, forM_, unless, void, when)
import Data.IORef
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Functor ((<&>))
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Agents.Protocol (AgentProtocolError (..), AgentRunner (..), CodingRequest (..), Invocation (..), protocolError)
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.GitHub.Auth (registrationInventory)
import Hamsterdan.GitHub.Client (AppClients, installationClient)
import Hamsterdan.GitHub.Config (HostConfig (..), botLogin, revealSecret)
import Hamsterdan.GitHub.Effects (CallPhase (..), callPhaseText)
import Hamsterdan.GitHub.Gateway (GitHubAuthority, githubAuthority)
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models
  ( InstallationInventory (..)
  , InvalidRequest (..)
  , PullRequestSnapshot (..)
  , RegistrationInventory (..)
  , Transport
  , boundary
  )
import Hamsterdan.Python (PythonArg (..), PythonException (..), casefold, pyIntBase, utf8Length)
import Hamsterdan.Python qualified as Py
import Hamsterdan.GitHub.Routing (InstallationRegistry, Route (..), activeCount, activeInstallationCount, closeRegistry, openRegistry)
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Transport (githubGraphQL, githubTransport)
import Hamsterdan.GitHub.Webhooks
  ( CustodyOptions (..)
  , ErrorClass (..)
  , InstanceKey (..)
  , Observation (..)
  , WebhookCustody
  , admitConversation
  , closeCustody
  , openCustody
  )
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agenticus (AgentCompositionError (..))
import Hamsterdan.Host.Binding (InstanceBinding (..), Topology (..), preflightV5State, readInstanceBinding)
import Hamsterdan.Host.ExceptionClass (exceptionClass)
import Hamsterdan.Host.Python
  ( RuntimeError (..)
  , ValueError (..)
  , catchPython
  , mkdirPrivate
  , tryPython
  )
import Hamsterdan.Host.Runnable (RunnableIndex, openRunnableIndexWith)
import Hamsterdan.Host.Runnable qualified as Runnable
import Hamsterdan.Host.V5.Application
  ( ApplicationOptions (..)
  , PrReadinessV5Application
  , applicationOptions
  , gitHubApplicationAuthority
  , inactiveActivityResult
  , openApplication
  )
import Hamsterdan.Host.V5.Application qualified as V5
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition (..), durablePublicationGates)
import Petrus.Activity (ActivityError (..), ActivityFailureFields (..), activityError, callActivity)
import Petrus.Activity.Number (Number (..))
import Petrus.Engine qualified as Engine
import Petrus.Json (Json (..), parseJson, pythonJsonLoads)
import Petrus.Motus.Dispatch.Inline (Activity)
import System.Directory (doesDirectoryExist, doesFileExist, doesPathExist, listDirectory)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Posix.Files qualified as Posix

-- ---------------------------------------------------------------------------
-- Logging

-- | A @hamsterdan.host@ WARNING record. The reference configures no
-- handler for its logger, so Python's last-resort handler writes the bare
-- message to stderr and drops INFO records.
logWarning :: Text -> IO ()
logWarning message = TIO.hPutStrLn stderr message

-- ---------------------------------------------------------------------------
-- Qualification faults

-- | @QualificationFault@: one exact, host-owned, disabled-by-default
-- qualification failure.
data QualificationFault = QualificationFault
  { repository :: Text
  , pullRequest :: Integer
  , point :: FaultPoint
  , kind :: Text
  , operation :: Text
  , spent :: MVar (Bool, Maybe Text)
  -- ^ @_spent@ and @_spent_operation@, under the fault's lock.
  }

-- | Where a fault fires: the configuration's @boundary@ and @phase@. The
-- reference admits exactly these four pairs (an @agent@ fault times out or
-- is malformed; a @comment@ fault fires before or after the call).
data FaultPoint = AgentFault AgentFaultPhase | CommentFault CallPhase
  deriving stock (Eq, Show)

data AgentFaultPhase = FaultTimedOut | FaultMalformed
  deriving stock (Eq, Show)

-- | The point's @(boundary, phase)@ spelling.
faultPointSpelling :: FaultPoint -> (Text, Text)
faultPointSpelling = \case
  AgentFault FaultTimedOut -> ("agent", "timed_out")
  AgentFault FaultMalformed -> ("agent", "malformed")
  CommentFault phase -> ("comment", callPhaseText phase)

-- | Every point, by its spelling.
faultPoints :: [((Text, Text), FaultPoint)]
faultPoints =
  [ (faultPointSpelling point, point)
  | point <- [AgentFault FaultTimedOut, AgentFault FaultMalformed, CommentFault BeforeCall, CommentFault AfterCall]
  ]

qualificationFault :: Text -> Integer -> FaultPoint -> Text -> Text -> IO QualificationFault
qualificationFault repository pullRequest point kind operation =
  QualificationFault repository pullRequest point kind operation <$> newMVar (False, Nothing)

-- | @QualificationFault.from_environment(environment)@ over the value of
-- @HAMSTERDAN_QUALIFICATION_FAULT@, if set.
qualificationFaultFromEnvironment :: Maybe Text -> IO (Maybe QualificationFault)
qualificationFaultFromEnvironment = \case
  Nothing -> pure Nothing
  Just raw -> do
    let malformed :: IO a
        malformed = throwIO (ValueError "qualification fault configuration is malformed")
        size = utf8Length raw
    unless (0 < size && size <= 4096) malformed
    members <- case parseJson pythonJsonLoads (TE.encodeUtf8 raw) of
      Right (Object members) -> pure members
      _ -> malformed
    let names = Set.fromList ["repository", "pull_request", "boundary", "phase", "kind", "operation"]
    unless (Set.fromList (map fst members) == names) malformed
    let member name = fromMaybe Null (lookup name (reverse members))
    case (member "repository", member "pull_request", member "boundary", member "phase", member "kind", member "operation") of
      (String repository, Int pullRequest, String boundary', String phase, String kind, String operation)
        | T.count "/" repository == 1
        , pullRequest > 0
        , Just point <- lookup (boundary', phase) faultPoints
        , not (T.null kind)
        , not (T.null operation) ->
            Just <$> qualificationFault repository pullRequest point kind operation
      _ -> malformed

-- | @_matches@ then @_consume@, atomically: whether this call spends the
-- fault.
consume :: QualificationFault -> Text -> Integer -> FaultPoint -> Text -> Text -> IO Bool
consume fault repository pullRequest point kind operation =
  modifyMVar fault.spent $ \state@(isSpent, _) ->
    if not isSpent
      && (casefold repository, pullRequest, point, kind) == (casefold fault.repository, fault.pullRequest, fault.point, fault.kind)
      && fault.operation `elem` [operation, "next"]
      then do
        let (boundary', phase) = faultPointSpelling point
        logWarning
          ( "qualification_fault boundary="
              <> boundary'
              <> " phase="
              <> phase
              <> " kind="
              <> kind
              <> " operation="
              <> operation
          )
        pure ((True, Just operation), True)
      else pure (state, False)

-- | @publication(phase, repository, pull_request, kind, operation)@: the
-- application's publication fault hook.
faultPublication :: QualificationFault -> CallPhase -> Text -> Integer -> Text -> Text -> IO ()
faultPublication fault phase repository pullRequest kind operation = do
  spends <- consume fault repository pullRequest (CommentFault phase) kind operation
  when spends $ throwIO (boundary "qualified provider outcome was deliberately withheld")

-- | @agent(repository, pull_request, kind, operation)@.
faultAgent :: QualificationFault -> Text -> Integer -> Text -> Text -> IO ()
faultAgent fault repository pullRequest kind operation = case fault.point of
  CommentFault _ -> pure ()
  AgentFault phase -> do
    spends <- consume fault repository pullRequest fault.point kind operation
    when spends $ case phase of
      FaultTimedOut -> throwIO (protocolError "qualified agent execution timed out") {timedOut = True}
      FaultMalformed -> throwIO (protocolError "qualified agent result is malformed")

-- | @_spent_operation@.
spentOperation :: QualificationFault -> IO (Maybe Text)
spentOperation fault = snd <$> readMVar fault.spent

-- ---------------------------------------------------------------------------
-- The application boundary

-- | @ReadinessApplication@: one PR workflow implementation behind durable
-- webhook custody.
data HostApplication = HostApplication
  { processObservation :: Observation -> Maybe AdmittedConversation -> IO ()
  , reconcile :: Text -> IO Bool
  -- ^ 'False' is the reference's literal @False@ (a custody fence).
  , settle :: IO (Maybe Double)
  -- ^ The settled outcome's @next_maturation@.
  , activity :: Text -> IO (Maybe GateDefinition)
  , hasUnresolvedPublication :: IO Bool
  , runDurableActivities :: Int -> IO Int
  , stopDurableActivities :: IO ()
  , detachedState :: IO Json
  , close :: IO ()
  , v5 :: Maybe PrReadinessV5Application
  -- ^ The real V5 application behind this boundary, if it is one.
  }

-- | @application_factory(root, instance, authority, runner, **options)@.
type ApplicationFactory = FilePath -> Text -> GitHubAuthority -> AgentRunner -> ApplicationOptions -> IO HostApplication

-- | The V5 application behind the host protocol.
hostApplication :: PrReadinessV5Application -> HostApplication
hostApplication app =
  HostApplication
    { processObservation = V5.processObservation app
    , reconcile = V5.reconcile app
    , settle = maturation <$> V5.settle app
    , activity = V5.applicationActivity app
    , hasUnresolvedPublication = V5.hasUnresolvedPublication app
    , runDurableActivities = V5.runDurableActivities app
    , stopDurableActivities = V5.stopDurableActivities app
    , detachedState = V5.detachedState app
    , close = V5.closeApplication app
    , v5 = Just app
    }
  where
    maturation outcome = case outcome.nextMaturation of
      Just (IntNumber n) -> Just (fromInteger n)
      Just (FloatNumber d) -> Just d
      Nothing -> Nothing

-- | @PrReadinessV5Application@, the default factory.
v5ApplicationFactory :: ApplicationFactory
v5ApplicationFactory root instanceId authority runner options =
  hostApplication <$> openApplication root instanceId (gitHubApplicationAuthority authority) runner options

-- ---------------------------------------------------------------------------
-- Composition seams

-- | The @GitHubAppClients@ surface the host uses. 'installation' is
-- @transport_factory(clients.installation(installation_id, repository_ids))@
-- with the default transport.
data HostClients = HostClients
  { registrationInventory :: HostConfig -> IO RegistrationInventory
  , installation :: Integer -> [Integer] -> IO Transport
  , close :: IO ()
  }

-- | The production clients over one 'AppClients'.
gitHubHostClients :: AppClients -> HostClients
gitHubHostClients clients =
  HostClients
    { registrationInventory = registrationInventory clients
    , installation = \installationId repositoryIds ->
        either (throwIO . ValueError) (pure . githubTransport) (installationClient clients installationId repositoryIds)
    , close = pure ()
    }

-- | The agent route custody the host owns (@AgentRouteStore@ and the
-- agent runtime): the operation claim before each Attempt, the settlement
-- of terminal operations, and release.
data AgentCustody = AgentCustody
  { claim :: Text -> IO ()
  , settleOperations :: Set Text -> IO ()
  , close :: IO ()
  }

-- | Custody that claims nothing (tests, and hosts without agent routes).
noAgentCustody :: AgentCustody
noAgentCustody = AgentCustody {claim = \_ -> pure (), settleOperations = \_ -> pure (), close = pure ()}

-- | @RoutedAgentRunner(runner, routes, composition, before_call=...)@.
routedRunner :: AgentRunner -> AgentCustody -> Maybe (Text -> Text -> Integer -> IO ()) -> AgentRunner
routedRunner runner custody beforeCall =
  AgentRunner
    { review = \url request inv -> claimed "review" inv >> runner.review url request inv
    , converse = \url request inv -> claimed "conversation" inv >> runner.converse url request inv
    , code = \url request inv -> claimed request.kind inv >> runner.code url request inv
    }
  where
    claimed kind inv = do
      when (inv.attempt < 1) $ throwIO (AgentCompositionError "agent attempt must be a positive integer")
      custody.claim inv.operation
      forM_ beforeCall $ \hook -> hook kind inv.operation inv.attempt

-- ---------------------------------------------------------------------------
-- The service

-- | The constructor's keyword arguments.
data ServiceOptions = ServiceOptions
  { clients :: Maybe HostClients
  -- ^ 'Nothing': @GitHubAppClients(config)@ with the production network.
  , runner :: AgentRunner
  , agents :: AgentCustody
  , applicationFactory :: ApplicationFactory
  , workflowPath :: Text
  , reminderDelay :: Double
  , pollInterval :: Double
  , sweepInterval :: Double
  , qualificationFault :: Maybe QualificationFault
  , clock :: Maybe (IO Double)
  , transportFactory :: Maybe (Transport -> Transport)
  , runnableClock :: Maybe (IO Double)
  -- ^ Test seam: the runnable index's own clock (the reference tests
  -- assign @runnable._clock@).
  , timerClockUs :: Maybe (IO Integer)
  -- ^ Test seam: the applications' timer clock (@time.time_ns@ patches).
  }

serviceOptions :: AgentRunner -> AgentCustody -> ServiceOptions
serviceOptions runner agents =
  ServiceOptions
    { clients = Nothing
    , runner
    , agents
    , applicationFactory = v5ApplicationFactory
    , workflowPath = ".github/workflows/ci.yml"
    , reminderDelay = 259200
    , pollInterval = 0.25
    , sweepInterval = 60
    , qualificationFault = Nothing
    , clock = Nothing
    , transportFactory = Nothing
    , runnableClock = Nothing
    , timerClockUs = Nothing
    }

-- | The reference tests' instance monkeypatches.
data ServiceHooks = ServiceHooks
  { aroundRecordPosture :: Text -> Maybe Double -> IO () -> IO ()
  , aroundAcknowledgeObservation :: Observation -> Maybe Text -> IO () -> IO ()
  , activateOverride :: Maybe (Text -> Maybe Text -> IO Bool)
  , projectPendingOverride :: Maybe (IO Int)
  , runDueOverride :: Maybe (IO Int)
  , reconcileRegistrationOverride :: Maybe (IO Json)
  , workerOverride :: Maybe (IO ())
  }

defaultServiceHooks :: ServiceHooks
defaultServiceHooks =
  ServiceHooks
    { aroundRecordPosture = \_ _ real -> real
    , aroundAcknowledgeObservation = \_ _ real -> real
    , activateOverride = Nothing
    , projectPendingOverride = Nothing
    , runDueOverride = Nothing
    , reconcileRegistrationOverride = Nothing
    , workerOverride = Nothing
    }

data HostService = HostService
  { config :: HostConfig
  , root :: FilePath
  , options :: ServiceOptions
  , clientsRef :: IORef HostClients
  , registry :: InstallationRegistry
  , serviceClock :: IO Double
  , custody :: WebhookCustody
  , installationIds :: IORef (Set Integer)
  , loaded :: IORef (Map InstanceKey Loaded)
  -- ^ The loaded Instances (the reference's @_apps@ and @_locks@).
  , stopped :: TVar Bool
  , closed :: IORef Bool
  , watchVerdicts :: IORef (Map InstanceKey Bool)
  , applicationLock :: MVar ()
  , pumpLock :: MVar ()
  , schedulerErrors :: IORef (Map Text Text)
  , runnable :: RunnableIndex
  , dispatchPath :: FilePath
  , hooks :: IORef ServiceHooks
  }

-- | One loaded PR Instance: its application and the lock that serializes
-- work on it.
data Loaded = Loaded
  { key :: InstanceKey
  , instanceName :: Text
  , app :: HostApplication
  , lock :: MVar ()
  , ordinal :: Int
  -- ^ Its place in load order (the reference's dict order).
  }

-- | The loaded Instances in load order.
loadedInOrder :: HostService -> IO [Loaded]
loadedInOrder service = sortOn (.ordinal) . Map.elems <$> readIORef service.loaded

-- | @self._apps[key]@ (with its lock), raising the reference's @KeyError@
-- when the Instance is not loaded.
loadedAt :: HostService -> InstanceKey -> IO Loaded
loadedAt service key =
  Map.lookup key <$> readIORef service.loaded
    -- @KeyError((installation, repository, pull))@: its @str()@ is the
    -- tuple's repr, which the three arguments spell.
    >>= maybe (throwIO (PythonException "KeyError" (map PyInt (keyMembers key)))) pure

keyMembers :: InstanceKey -> [Integer]
keyMembers key = [key.installation, key.repository, key.pullRequest]

-- | @CustodyOneResult(delivery_id, disposition)@.
data CustodyOneResult = CustodyOneResult
  { deliveryId :: Text
  , disposition :: CustodyDisposition
  }
  deriving stock (Eq, Show)

-- | What @process_one@ did with the delivery it took.
data CustodyDisposition = CustodyCompleted | CustodyDisposed | CustodyRetained | CustodyFailed
  deriving stock (Eq, Show)

-- | The disposition's spelling in the reference.
custodyDispositionText :: CustodyDisposition -> Text
custodyDispositionText = \case
  CustodyCompleted -> "completed"
  CustodyDisposed -> "disposed"
  CustodyRetained -> "retained"
  CustodyFailed -> "failed"

-- | @HostService(config, ...)@.
openHostService :: HostConfig -> ServiceOptions -> IO HostService
openHostService config options = do
  let root = config.statePath
  preflightV5State root
  mkdirPrivate root
  clients <- maybe (defaultClients config) pure options.clients
  registry <- openRegistry (root </> "routes.sqlite3") config.accounts
  let wallClock = realToFrac <$> getPOSIXTime
      serviceClock = fromMaybe wallClock options.clock
  custody <-
    openCustody
      (root </> "webhooks.sqlite3")
      (revealSecret config.webhookSecret)
      (CustodyOptions (Just registry) Custody.maxBodyBytes serviceClock)
      `onException` closeRegistry registry
  runnable <-
    openRunnableIndexWith (root </> "runnable.sqlite3") (fromMaybe serviceClock options.runnableClock)
      `onException` (closeCustody custody >> closeRegistry registry)
  clientsRef <- newIORef clients
  installationIds <- newIORef Set.empty
  loaded <- newIORef Map.empty
  stopped <- newTVarIO False
  closed <- newIORef False
  watchVerdicts <- newIORef Map.empty
  applicationLock <- newMVar ()
  pumpLock <- newMVar ()
  schedulerErrors <- newIORef Map.empty
  hooks <- newIORef defaultServiceHooks
  pure
    HostService
      { config
      , root
      , options
      , clientsRef
      , registry
      , serviceClock
      , custody
      , installationIds
      , loaded
      , stopped
      , closed
      , watchVerdicts
      , applicationLock
      , pumpLock
      , schedulerErrors
      , runnable
      , dispatchPath = root </> "activity-dispatch.sqlite3"
      , hooks
      }
  where
    defaultClients _ = throwIO (ValueError "HostService requires GitHub clients")

-- ---------------------------------------------------------------------------
-- Instance identity

instancePattern :: Text -> Maybe InstanceKey
instancePattern instanceText = case T.splitOn ":" instanceText of
  ["github", a, b, "pr", c] -> InstanceKey <$> positive a <*> positive b <*> positive c
  _ -> Nothing
  where
    positive t = case T.uncons t of
      Just (first, rest)
        | first >= '1' && first <= '9'
        , T.all (\ch -> ch >= '0' && ch <= '9') rest ->
            Just (read (T.unpack t))
      _ -> Nothing

instanceOf :: InstanceKey -> Text
instanceOf key = "github:" <> tshow key.installation <> ":" <> tshow key.repository <> ":pr:" <> tshow key.pullRequest

tshow :: (Show a) => a -> Text
tshow = T.pack . show

applicationRoot :: HostService -> InstanceKey -> FilePath
applicationRoot service key = service.root </> "applications" </> show key.installation </> show key.repository </> show key.pullRequest



-- | @_instance(item)@.
observationInstance :: Observation -> Maybe Text
observationInstance item
  | item.installationId == Null || item.repositoryId == Null || item.pullRequestNumber == Null = Nothing
  | otherwise =
      Just ("github:" <> Py.str item.installationId <> ":" <> Py.str item.repositoryId <> ":pr:" <> Py.str item.pullRequestNumber)

-- | @registry.route(item.installation_id, item.repository_id)@ for
-- provider-given values.
observationRoute :: HostService -> Json -> Json -> IO (Maybe Route)
observationRoute service installationId repositoryId = case (installationId, repositoryId) of
  (Int i, Int r) -> Routing.route service.registry i r
  _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Durable Activity resolution

-- | @_resolve_activity(instance, name)@.
resolveActivity :: HostService -> Text -> Text -> IO (Maybe Activity)
resolveActivity service instanceText name
  | name `notElem` durablePublicationGates = pure Nothing
  | otherwise = case instancePattern instanceText of
      Nothing -> pure (Just invalidPublicationScope)
      Just key -> do
        outcome <- tryPython $ do
          app <- applicationWith service key.installation key.repository key.pullRequest True
          app.activity name
        case outcome of
          Right (Just implementation) -> guardWith service instanceText name implementation True
          _ -> pure (Just invalidPublicationScope)

-- | @_guard_durable_activity(instance, name, implementation)@: the
-- application's scoped durable resolver.
guardDurableActivity :: HostService -> Text -> Text -> GateDefinition -> IO (Maybe Activity)
guardDurableActivity service instanceText name implementation = guardWith service instanceText name implementation False

guardWith :: HostService -> Text -> Text -> GateDefinition -> Bool -> IO (Maybe Activity)
guardWith service instanceText name implementation acquireLock
  | name `notElem` durablePublicationGates = pure Nothing
  | otherwise = case instancePattern instanceText of
      Nothing -> pure (Just invalidPublicationScope)
      Just key -> pure . Just $ \invocation context ->
        let invoke =
              Routing.route service.registry key.installation key.repository >>= \case
                Nothing -> inactiveActivityResult name invocation (Just implementation)
                Just _ -> callActivity implementation.activity invocation context >>= either (throwIO . ValueError) pure
            locked
              | acquireLock = do
                  entry <- loadedAt service key
                  withMVar entry.lock (const invoke)
              | otherwise = invoke
            classified =
              try @ActivityError locked >>= \case
                Left failure -> throwIO failure
                Right value -> pure value
         in ( classified `catchPython` \err -> case err of
                _ ->
                  activityError
                    ActivityFailureFields
                      { failureError = "publication invariant failed"
                      , failureKind = exceptionClass err
                      , failureDetails = Null
                      , failureRetryable = False
                      , failureRetryAfter = Nothing
                      }
            )
              `finally` (service.serviceClock >>= \now -> Runnable.wake service.runnable instanceText now "activity-terminal" name)

-- | @_invalid_publication_scope@.
invalidPublicationScope :: Activity
invalidPublicationScope _ _ =
  activityError
    ActivityFailureFields
      { failureError = "publication scope is unavailable"
      , failureKind = "PublicationScopeError"
      , failureDetails = Null
      , failureRetryable = False
      , failureRetryAfter = Nothing
      }

-- ---------------------------------------------------------------------------
-- Registration

-- | @reconcile_registration()@: the validation evidence.
reconcileRegistration :: HostService -> IO Json
reconcileRegistration service =
  readIORef service.hooks >>= \hooks -> case hooks.reconcileRegistrationOverride of
    Just override -> override
    Nothing -> do
      clients <- readIORef service.clientsRef
      inventory <- clients.registrationInventory service.config
      count <- Routing.reconcile service.registry inventory.installations
      writeIORef service.installationIds (Set.fromList (map (.installationId) inventory.installations))
      pure $
        Object
          [ ("app_id", String (tshow service.config.appId))
          , ("app_slug", String service.config.appSlug)
          , ("reconciled_installations", Int (toInteger (length inventory.installations)))
          , ("admitted_repositories", Int (toInteger count))
          ]

-- ---------------------------------------------------------------------------
-- Applications

-- | @_application(installation_id, repository_id, pull_request_number)@.
application :: HostService -> Integer -> Integer -> Integer -> IO HostApplication
application service i r p = applicationWith service i r p False

-- | The loaded application of one key, if any (@_apps.get(key)@).
loadedApplication :: HostService -> InstanceKey -> IO (Maybe HostApplication)
loadedApplication service key = fmap (.app) . Map.lookup key <$> readIORef service.loaded

-- | The loaded keys in load order.
applicationKeys :: HostService -> IO [InstanceKey]
applicationKeys service = map (.key) <$> loadedInOrder service

applicationWith :: HostService -> Integer -> Integer -> Integer -> Bool -> IO HostApplication
applicationWith service i r p allowInactiveBinding = withMVar service.applicationLock $ \() -> do
  let key = InstanceKey i r p
  loaded <- loadedApplication service key
  case loaded of
    Just app -> pure app
    Nothing -> do
      route <- Routing.route service.registry i r
      when (isNothing route && not allowInactiveBinding) $ throwIO (RuntimeError "route became inactive")
      let instanceText = instanceOf key
          root = applicationRoot service key
      repositoryFullName <- case route of
        Just active -> pure active.repositoryFullName
        Nothing -> do
          let inactive :: IO a
              inactive = throwIO (RuntimeError "inactive route has no strict durable binding")
          rootLink <- isSymlink root
          rootDir <- doesDirectoryExist root
          when (rootLink || not rootDir) inactive
          bindingResult <- tryPython (readInstanceBinding (root </> "binding.json"))
          binding <- either (const inactive) pure bindingResult
          historyLink <- isSymlink (root </> "history.jsonl")
          historyFile <- isRegularFile (root </> "history.jsonl")
          when
            ( binding.topology /= V5
                || binding.legacy
                || binding.instanceId /= instanceText
                || binding.pullRequest /= p
                || historyLink
                || not historyFile
            )
            inactive
          pure binding.repository
      clients <- readIORef service.clientsRef
      operationTransport <- clients.installation i [r]
      let transport = maybe id id service.options.transportFactory operationTransport
      authority <-
        either (\(InvalidRequest m) -> throwIO (ValueError m)) pure $
          githubAuthority transport repositoryFullName p (Just (githubGraphQL transport))
      let fault = service.options.qualificationFault
          runner =
            routedRunner
              service.options.runner
              service.options.agents
              (fmap (\f kind operation _ -> faultAgent f repositoryFullName p kind operation) fault)
          appOptions =
            (applicationOptions service.options.agents.settleOperations (botLogin service.config) ("https://github.com/" <> repositoryFullName <> ".git") (service.root </> "webhooks.sqlite3"))
              { workflowPath = service.options.workflowPath
              , reminderDelay = service.options.reminderDelay
              , publicationFault = faultPublication <$> fault
              , dispatchPath = Just service.dispatchPath
              , durableActivityResolver = Just (guardDurableActivity service)
              , clock = service.options.clock
              , timerClockUs = service.options.timerClockUs
              }
      app <- service.options.applicationFactory root instanceText authority runner appOptions
      lock <- newMVar ()
      modifyIORef' service.loaded $ \entries ->
        Map.insert key Loaded {key, instanceName = instanceText, app, lock, ordinal = Map.size entries} entries
      pure app

isSymlink :: FilePath -> IO Bool
isSymlink path = either (const False) Posix.isSymbolicLink <$> try @SomeException (Posix.getSymbolicLinkStatus path)

isRegularFile :: FilePath -> IO Bool
isRegularFile path = either (const False) Posix.isRegularFile <$> try @SomeException (Posix.getFileStatus path)

-- | @sorted(applications.glob("*/*/*/history.jsonl"))@ with each path's
-- three parent names.
persistedHistories :: HostService -> IO [(FilePath, (FilePath, FilePath, FilePath))]
persistedHistories service = do
  let applications = service.root </> "applications"
  isDir <- doesDirectoryExist applications
  if not isDir
    then pure []
    else do
      found <- fmap concat . forM' applications $ \a ->
        fmap concat . forM' (applications </> a) $ \b ->
          forM' (applications </> a </> b) $ \c -> do
            let history = applications </> a </> b </> c </> "history.jsonl"
            exists <- doesPathExist history
            pure [(history, (a, b, c)) | exists]
      pure (sortOn (\(_, (a, b, c)) -> [a, b, c]) (concat found))
  where
    forM' :: FilePath -> (FilePath -> IO [a]) -> IO [[a]]
    forM' directory body = do
      isDir <- doesDirectoryExist directory
      entries <- if isDir then sort . filter (not . hidden) <$> listDirectoryOrEmpty directory else pure []
      mapM body entries
    hidden name = take 1 name == "."
    listDirectoryOrEmpty directory = either (const []) id <$> try @SomeException (listDirectory directory)

-- | @int(part)@ of each parent name, if all three parse.
historyKey :: (FilePath, FilePath, FilePath) -> Maybe InstanceKey
historyKey (a, b, c) = InstanceKey <$> number a <*> number b <*> number c
  where
    number = pyIntBase 10 . T.pack

-- | @sweep(trigger)@: reconcile durable PR Instances after restarts or
-- missed provider events.
sweep :: HostService -> Text -> IO Int
sweep service trigger = do
  histories <- persistedHistories service
  foldM step 0 histories
  where
    step reconciled (_, parts) = case historyKey parts of
      Nothing -> pure reconciled
      Just key
        | minimum (keyMembers key) <= 0 -> pure reconciled
        | otherwise ->
            ( do
                activated <- activateInstance service (instanceOf key) Nothing (Just trigger)
                pure (reconciled + fromEnum activated)
            )
              `catchPython` \err -> do
                logWarning
                  ( "application_sweep_retry installation_id="
                      <> tshow key.installation
                      <> " repository_id="
                      <> tshow key.repository
                      <> " pull_request_number="
                      <> tshow key.pullRequest
                      <> " error_class="
                      <> exceptionClass err
                  )
                pure reconciled

-- | @process(item)@.
process :: HostService -> Observation -> IO ()
process service item = case observationInstance item of
  Nothing -> void (selectObservation service item)
  Just instanceText -> do
    status <- Custody.status service.custody item.deliveryId
    when (status `elem` [Nothing, Just Custody.InboxPending]) $
      void (activateInstanceWith service instanceText (if isNothing status then Just item else Nothing) Nothing)
        `catchPython` \_ -> pure ()

-- | An observation '_select_observation' admitted, with the Instance its
-- members address.
data Selected = Selected
  { item :: Observation
  , conversation :: Maybe AdmittedConversation
  , instanceName :: Text
  }

-- | @_select_observation(item)@: terminally dispose observations which
-- cannot address a PR Instance.
selectObservation :: HostService -> Observation -> IO (Maybe Selected)
selectObservation service item
  | item.event `elem` ["ping", "installation", "installation_repositories"] = disposed "non-workflow event"
  | otherwise = do
      route <-
        if item.installationId == Null || item.repositoryId == Null
          then pure Nothing
          else observationRoute service item.installationId item.repositoryId
      -- An active route proves the installation and repository; the
      -- Instance then exists exactly when the pull request number does.
      case (route, observationInstance item) of
        (Nothing, _) -> disposed "inactive route"
        (Just _, Nothing) -> disposed "no pull request"
        (Just _, Just instanceName)
          | item.event == "issue_comment" ->
              case admitConversation service.config.appSlug (botLogin service.config) item of
                Nothing -> disposed "comment not addressed"
                Just conversation -> pure (Just Selected {item, conversation = Just conversation, instanceName})
          | otherwise -> pure (Just Selected {item, conversation = Nothing, instanceName})
  where
    disposed reason = Nothing <$ Custody.acknowledge service.custody item.deliveryId reason

-- | @_apply_observation(application, item, conversation)@.
applyObservation :: HostService -> HostApplication -> Observation -> Maybe AdmittedConversation -> IO (Bool, Maybe Text)
applyObservation service app item conversation =
  observationRoute service item.installationId item.repositoryId >>= \case
    Nothing -> pure (False, Just "route inactive before work")
    Just _ -> do
      app.processObservation item conversation
      pure (True, Nothing)

-- | @_acknowledge_observation(item, reason)@.
acknowledgeObservation :: HostService -> Observation -> Maybe Text -> IO ()
acknowledgeObservation service item reason = do
  hooks <- readIORef service.hooks
  hooks.aroundAcknowledgeObservation item reason $
    Custody.acknowledge service.custody item.deliveryId (fromMaybe "processed" reason)

-- | @_retry_observation(item, error)@.
retryObservation :: HostService -> Observation -> SomeException -> IO ()
retryObservation service item err = do
  Custody.retry service.custody item.deliveryId (ErrorClass (exceptionClass err))
  logWarning
    ( "webhook_retry delivery_id="
        <> item.deliveryId
        <> " event="
        <> item.event
        <> " installation_id="
        <> Py.str item.installationId
        <> " repository_id="
        <> Py.str item.repositoryId
        <> " pull_request_number="
        <> Py.str item.pullRequestNumber
        <> " disposition=retry error_class="
        <> exceptionClass err
    )

-- | @worker()@: the startup sweep, then pump and periodic sweeps until
-- 'stop'.
worker :: HostService -> IO ()
worker service =
  readIORef service.hooks >>= \hooks -> case hooks.workerOverride of
    Just override -> override
    Nothing -> do
      void (sweep service "startup")
      start <- getMonotonicTime
      loop (start + service.options.sweepInterval)
  where
    loop nextSweep = do
      halted <- isStopped service
      unless halted $ do
        void (pump service 20)
        haltedAfterPump <- isStopped service
        unless haltedAfterPump $ do
          now <- getMonotonicTime
          nextSweep' <-
            if now >= nextSweep
              then do
                void (sweep service "periodic")
                (+ service.options.sweepInterval) <$> getMonotonicTime
              else pure nextSweep
          waitForStop service service.options.pollInterval
          loop nextSweep'

-- | @asyncio.wait_for(self._stop.wait(), timeout)@.
waitForStop :: HostService -> Double -> IO ()
waitForStop service seconds = do
  timer <- registerDelay (max 0 (round (seconds * 1000000)))
  atomically $ do
    halted <- readTVar service.stopped
    expired <- readTVar timer
    unless (halted || expired) retry

isStopped :: HostService -> IO Bool
isStopped service = readTVarIO service.stopped

-- | @pump(limit)@: stage due authority custody before running durable
-- Activities.
pump :: HostService -> Int -> IO Int
pump service limit = withMVar service.pumpLock $ \() -> do
  hooks <- readIORef service.hooks
  void (fromMaybe (projectPending service) hooks.projectPendingOverride)
  void (fromMaybe (runDue service 100) hooks.runDueOverride)
  halted <- isStopped service
  if halted
    then pure 0
    else do
      loaded <- loadedInOrder service
      processed <-
        foldM
          ( \processed entry ->
              if processed >= limit
                then pure processed
                else do
                  blocked <- Custody.hasPending service.custody entry.key
                  if blocked
                    then pure processed
                    else withMVar entry.lock $ \() -> do
                      completed <- entry.app.runDurableActivities (limit - processed)
                      when (completed > 0) $ entry.app.settle >>= recordPosture service entry.instanceName
                      pure (processed + completed)
          )
          0
          loaded
      forM_ loaded $ \entry -> do
        unresolved <- entry.app.hasUnresolvedPublication
        when unresolved $ do
          now <- service.serviceClock
          Runnable.wake service.runnable entry.instanceName now "dispatch-repair" "unresolved-publication"
      pure processed

-- | @process_one()@: process at most one currently due custodied
-- delivery.
processOne :: HostService -> IO (Maybe CustodyOneResult)
processOne service =
  Custody.pending service.custody 1 Nothing >>= \case
    [] -> pure Nothing
    item : _ ->
      selectObservation service item >>= \case
        Nothing -> Just . CustodyOneResult item.deliveryId <$> custodyDisposition service item False
        Just selected -> do
          completed <-
            activateInstanceWith service selected.instanceName (Just item) Nothing `catchPython` \_ -> pure False
          Just . CustodyOneResult item.deliveryId <$> custodyDisposition service item completed

custodyDisposition :: HostService -> Observation -> Bool -> IO CustodyDisposition
custodyDisposition service item completed =
  Custody.status service.custody item.deliveryId <&> \case
    Just Custody.InboxTerminal -> if completed then CustodyCompleted else CustodyDisposed
    Just Custody.InboxFailed -> CustodyFailed
    _ -> CustodyRetained

-- | @run_one_activity()@: execute at most one immediately claimable
-- durable Activity Attempt.
runOneActivity :: HostService -> IO Int
runOneActivity service = withMVar service.pumpLock $ \() -> do
  halted <- isStopped service
  if halted
    then pure 0
    else loadedInOrder service >>= go
  where
    go = \case
      [] -> pure 0
      entry : rest -> do
        blocked <- Custody.hasPending service.custody entry.key
        if blocked
          then go rest
          else do
            completed <- withMVar entry.lock $ \() -> do
              completed <- entry.app.runDurableActivities 1
              when (completed > 0) $ entry.app.settle >>= recordPosture service entry.instanceName
              pure completed
            if completed > 0 then pure completed else go rest

-- | @subject_state(installation, repository, pull_request)@.
subjectState :: HostService -> Integer -> Integer -> Integer -> IO (Maybe Json)
subjectState service i r p = loadedApplication service (InstanceKey i r p) >>= traverse (.detachedState)

-- | @work_state()@: bounded eligible work without runtime handles.
workState :: HostService -> IO Json
workState service = do
  histories <- persistedHistories service
  loaded <- Map.elems <$> readIORef service.loaded
  pending <- Custody.pending service.custody 1 Nothing
  due <- Runnable.nextDue service.runnable
  unresolved <- anyM (.app.hasUnresolvedPublication) loaded
  let loadedRoots = Set.fromList [applicationRoot service entry.key </> "history.jsonl" | entry <- loaded]
  pure $
    Object
      [ ("pending_custody", Bool (not (null pending)))
      , ("runnable_due", maybe Null Float due)
      , ("unresolved_activity", Bool unresolved)
      , ("unloaded_application", Bool (any (\(path, _) -> path `Set.notMember` loadedRoots) histories))
      ]

anyM :: (a -> IO Bool) -> [a] -> IO Bool
anyM predicate = \case
  [] -> pure False
  x : xs -> predicate x >>= \hit -> if hit then pure True else anyM predicate xs

-- | @reconcile_one(trigger)@: reconcile at most one persisted PR
-- Instance.
reconcileOne :: HostService -> Text -> IO Bool
reconcileOne service trigger = persistedHistories service >>= go
  where
    go = \case
      [] -> pure False
      (_, parts) : rest -> case historyKey parts of
        Nothing -> go rest
        Just key
          | minimum (keyMembers key) <= 0 -> go rest
          | otherwise -> do
              isLoaded <- Map.member key <$> readIORef service.loaded
              if isLoaded
                then go rest
                else do
                  let instanceText = instanceOf key
                  activateInstance service instanceText Nothing (Just trigger) `catchPython` \err -> do
                    modifyIORef' service.schedulerErrors (Map.insert instanceText (exceptionClass err))
                    pure False

-- | @project_pending()@: project canonical due inbox observations into
-- noncanonical wake hints.
projectPending :: HostService -> IO Int
projectPending service = do
  items <- Custody.pending service.custody 1000 Nothing
  foldM step 0 items
  where
    step projected item = case observationInstance item of
      Nothing -> projected <$ process service item
      Just instanceText ->
        observationRoute service item.installationId item.repositoryId >>= \case
          Nothing -> projected <$ process service item
          Just _ -> do
            now <- service.serviceClock
            let identity = if item.event == "issue_comment" then item.deliveryId else "reconcile"
            Runnable.wake service.runnable instanceText now "webhook" identity
            pure (projected + 1)

-- | @_record_posture(instance, outcome)@.
recordPosture :: HostService -> Text -> Maybe Double -> IO ()
recordPosture service instanceText maturation = do
  hooks <- readIORef service.hooks
  hooks.aroundRecordPosture instanceText maturation $
    Runnable.replaceTimer service.runnable instanceText maturation

-- | @_watched(key, selected)@: whether this unbound subject's PR author
-- is watched.
watched :: HostService -> InstanceKey -> [(Observation, Maybe AdmittedConversation)] -> IO Bool
watched service key selected
  | Set.null service.config.watchedAuthors = pure True
  | otherwise = do
      when (any (isJust . snd) selected) $ modifyIORef' service.watchVerdicts (Map.insert key True)
      Map.lookup key <$> readIORef service.watchVerdicts >>= \case
        Just verdict -> pure verdict
        Nothing ->
          Routing.route service.registry key.installation key.repository >>= \case
            Nothing -> pure True
            Just route -> do
              clients <- readIORef service.clientsRef
              operationTransport <- clients.installation key.installation [key.repository]
              let transport = maybe id id service.options.transportFactory operationTransport
              authority <-
                either (\(InvalidRequest m) -> throwIO (ValueError m)) pure $
                  githubAuthority transport route.repositoryFullName key.pullRequest Nothing
              snapshot <- Gateway.pullRequest authority
              let verdict = casefold snapshot.author `Set.member` service.config.watchedAuthors
              modifyIORef' service.watchVerdicts (Map.insert key verdict)
              pure verdict

-- | @_activate_instance(instance, observation=..., reconcile_trigger=...)@
-- through the test override, if any.
activateInstance :: HostService -> Text -> Maybe Observation -> Maybe Text -> IO Bool
activateInstance service instanceText observation trigger =
  readIORef service.hooks >>= \hooks -> case hooks.activateOverride of
    Just override -> override instanceText trigger
    Nothing -> activateInstanceWith service instanceText observation trigger

activateInstanceWith :: HostService -> Text -> Maybe Observation -> Maybe Text -> IO Bool
activateInstanceWith service instanceText observation trigger = case instancePattern instanceText of
  Nothing -> pure False
  Just key -> do
    let (i, r) = (key.installation, key.repository)
    eligible <- case observation of
      Just item -> Custody.eligible service.custody item.deliveryId key
      Nothing -> pure True
    if not eligible
      then pure False
      else do
        candidates <- maybe (Custody.pending service.custody 1000 (Just key)) (pure . pure) observation
        selected <- selectAll candidates
        seen <- newIORef (Set.fromList (map (.deliveryId) candidates))
        allSelected <- newIORef selected
        routeActive <- isJust <$> Routing.route service.registry i r
        bound <- doesFileExist (applicationRoot service key </> "history.jsonl")
        isLoaded <- Map.member key <$> readIORef service.loaded
        if
          | not (null candidates) && null selected && not isLoaded && not bound -> pure False
          | not routeActive && not isLoaded && not bound -> pure False
          | otherwise -> do
              succeeded <- newIORef []
              handled <- newIORef Set.empty
              attempted <- newIORef Set.empty
              let body = do
                    isWatched <-
                      if not (null selected) && not isLoaded && not bound
                        then watched service key selected
                        else pure True
                    if not isWatched
                      then do
                        forM_ selected $ \(item, _) -> Custody.acknowledge service.custody item.deliveryId "author not watched"
                        pure False
                      else do
                        app <- loadedApplication service key >>= maybe (applicationWith service i r key.pullRequest (not routeActive)) pure
                        entry <- loadedAt service key
                        withMVar entry.lock $ \() -> do
                          outcome0 <- if null selected then Just <$> app.settle else pure Nothing
                          activationError <- applyBatches app selected seen allSelected succeeded handled attempted False
                          let (activatedByBatches, failure) = activationError
                          everything <- readIORef allSelected
                          activated <-
                            if isJust trigger && null everything
                              then do
                                pendingNow <- Custody.hasPending service.custody key
                                routeNow <- isJust <$> Routing.route service.registry i r
                                if not pendingNow && routeNow
                                  then do
                                    reconciled <- app.reconcile (fromMaybe "" trigger <> ":" <> keyText key)
                                    pendingAfter <- Custody.hasPending service.custody key
                                    routeAfter <- isJust <$> Routing.route service.registry i r
                                    pure (reconciled && not pendingAfter && routeAfter)
                                  else pure activatedByBatches
                              else pure activatedByBatches
                          outcome <- if activated then Just <$> app.settle else pure outcome0
                          recordPosture service instanceText (outcome >>= id)
                          readIORef succeeded >>= mapM_ (\(item, reason) -> do
                            acknowledgeObservation service item reason
                            modifyIORef' handled (Set.insert item.deliveryId))
                          forM_ failure throwIO
                          pure True
              body `catchPython` \err -> do
                everything <- readIORef allSelected
                tried <- readIORef attempted
                done <- readIORef handled
                let retrySet
                      | not (Set.null tried) = tried
                      | (item, _) : _ <- everything = Set.singleton item.deliveryId
                      | otherwise = Set.empty
                forM_ everything $ \(item, _) ->
                  when (item.deliveryId `Set.member` retrySet && item.deliveryId `Set.notMember` done) $
                    retryObservation service item err
                throwIO err
  where
    keyText key = T.intercalate ":" (map tshow (keyMembers key))
    selectAll items = map (\selected -> (selected.item, selected.conversation)) . catMaybes <$> mapM (selectObservation service) items
    applyBatches app batch seen allSelected succeeded handled attempted activated = do
      (activated', failure) <- applyBatch app batch succeeded handled attempted activated
      case failure of
        Just _ -> pure (activated', failure)
        Nothing ->
          if null batch
            then pure (activated', Nothing)
            else do
              known <- readIORef seen
              arrived <-
                filter ((`Set.notMember` known) . (.deliveryId))
                  <$> Custody.pending service.custody 1000 (instancePattern instanceText)
              if null arrived
                then pure (activated', Nothing)
                else do
                  modifyIORef' seen (Set.union (Set.fromList (map (.deliveryId) arrived)))
                  next <- selectAll arrived
                  modifyIORef' allSelected (<> next)
                  applyBatches app next seen allSelected succeeded handled attempted activated'
    applyBatch app batch succeeded handled attempted activated = case batch of
      [] -> pure (activated, Nothing)
      (item, conversation) : rest -> do
        modifyIORef' attempted (Set.insert item.deliveryId)
        outcome <- tryPython (applyObservation service app item conversation)
        case outcome of
          Right (applied, reason) -> do
            modifyIORef' succeeded (<> [(item, reason)])
            applyBatch app rest succeeded handled attempted (activated || applied)
          Left err -> do
            retryObservation service item err
            modifyIORef' handled (Set.insert item.deliveryId)
            pure (activated, Just err)

-- | @run_due(limit)@.
runDue :: HostService -> Int -> IO Int
runDue service limit = do
  due <- Runnable.takeDue service.runnable limit
  foldM step 0 due
  where
    step processed instanceText =
      ( do
          activated <- activateInstance service instanceText Nothing Nothing
          modifyIORef' service.schedulerErrors (Map.delete instanceText)
          pure (processed + fromEnum activated)
      )
        `catchPython` \err -> do
          let errorClass = exceptionClass err
          modifyIORef' service.schedulerErrors (Map.insert instanceText errorClass)
          now <- service.serviceClock
          Runnable.wake service.runnable instanceText now "scheduler-repair" "run-due-failure"
          logWarning ("scheduler_instance_degraded instance=" <> instanceText <> " error_class=" <> errorClass)
          pure processed

-- | @stop()@.
stop :: HostService -> IO ()
stop service = do
  atomically (writeTVar service.stopped True)
  loaded <- withMVar service.applicationLock $ \() -> Map.elems <$> readIORef service.loaded
  mapM_ (.app.stopDurableActivities) loaded

-- | @health()@: sanitized service health.
health :: HostService -> IO Json
health service = do
  errors <- readIORef service.schedulerErrors
  reconciled <- Set.size <$> readIORef service.installationIds
  activeInstallations <- activeInstallationCount service.registry
  activeRepositories <- activeCount service.registry
  applications <- Map.size <$> readIORef service.loaded
  inbox <- Custody.counts service.custody
  hints <- Runnable.count service.runnable
  pure $
    Object
      [ ("status", String (if Map.null errors then "ok" else "degraded"))
      ,
        ( "installations"
        , Object
            [ ("configured", Int (toInteger (length service.config.accounts)))
            , ("reconciled", Int (toInteger reconciled))
            , ("active", Int (toInteger activeInstallations))
            ]
        )
      , ("active_repositories", Int (toInteger activeRepositories))
      , ("applications", Int (toInteger applications))
      , ("inbox", Object [(name, Int (toInteger n)) | (name, n) <- Map.toList inbox])
      , ("runnable_hints", Int (toInteger hints))
      ,
        ( "scheduler"
        , Object
            [ ("degraded_instances", Int (toInteger (Map.size errors)))
            , ("error_classes", Array (map String (Set.toAscList (Set.fromList (Map.elems errors)))))
            ]
        )
      ]

-- | @settle_terminals_for_shutdown()@.
settleTerminalsForShutdown :: HostService -> IO ()
settleTerminalsForShutdown service = do
  loaded <- loadedInOrder service
  forM_ loaded $ \entry ->
    withMVar entry.lock (\() -> entry.app.settle >>= recordPosture service entry.instanceName)
      `catchPython` \err ->
        logWarning ("shutdown_terminal_settlement_failed instance=" <> entry.instanceName <> " error_class=" <> exceptionClass err)

-- | @abort()@: release this process generation without settling semantic
-- work.
abort :: HostService -> IO ()
abort service = release service False

-- | @close()@: gracefully settle loaded terminals and release owned
-- resources.
close :: HostService -> IO ()
close service = release service True

release :: HostService -> Bool -> IO ()
release service settling = mask $ \_ -> do
  already <- atomicModifyIORef' service.closed (True,)
  unless already $ do
    failure <- newIORef Nothing
    let remember err = modifyIORef' failure (\current -> Just (fromMaybe err current))
    withMVar service.pumpLock $ \() ->
      when settling $
        settleTerminalsForShutdown service `catchPython` remember
    loaded <- loadedInOrder service
    clients <- readIORef service.clientsRef
    let resources =
          [entry.app.close | entry <- loaded]
            <> [ Runnable.close service.runnable
               , closeCustody service.custody
               , closeRegistry service.registry
               , clients.close
               , service.options.agents.close
               ]
    forM_ resources $ \resource -> resource `catchPython` remember
    writeIORef service.loaded Map.empty
    readIORef failure >>= mapM_ throwIO
