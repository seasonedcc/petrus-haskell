-- | The agent composition @hamsterdan.host.__main__@ performs before it
-- opens the service: the Pi installation from the environment, the
-- Agenticus route composition, the durable route store, the workspace
-- receiver and the owned Pi A2 runtime, and the runner selected by an
-- exact READY probe. The host owns what it composed: the service releases
-- it ('AgentCustody'), or startup cleanup does when the service never
-- opened ('OwnedAgent').
module Hamsterdan.Host.Agents
  ( -- * Ownership before the service exists
    OwnedAgent (..)
  , newOwnedAgent
  , closeOwnedAgent

    -- * Composition
  , AgentSeams (..)
  , productionAgentSeams
  , composeHostAgent
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (void)
import Data.IORef
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Hamsterdan.Agents.Pi (PiWorkspaceProvider, piA2Runtime)
import Hamsterdan.Agents.Protocol (AgentRunner)
import Hamsterdan.Host.AgentRuntime (closeOwnedResources, composeAgentRuntimeWith)
import Hamsterdan.Host.Agenticus
  ( activateRoutes
  , claimRoute
  , closeRoutes
  , composeAgent
  , composeAgentRunner
  , composedAgentRunner
  , openAgentRouteStore
  , settleRoutes
  )
import Hamsterdan.Host.PiA2 (OwnedPiA2 (..), PiA2Hooks, composeOwnedPiA2With, defaultPiA2Hooks, installationFromEnvironment)
import Hamsterdan.Host.PiWorkspace (GitPiWorkspaceProvider, gitPiWorkspaceProvider, newGitPiWorkspaceProvider)
import Hamsterdan.Host.Service (AgentCustody (..))
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimeHost, closeHost, probeHost)
import System.FilePath ((</>))

-- | The independently owned startup resources (@pi_runtime@ and
-- @route_store@ of @main()@), each recorded as soon as it exists.
data OwnedAgent = OwnedAgent
  { runtime :: IORef (Maybe (IO ()))
  , routes :: IORef (Maybe (IO ()))
  }

newOwnedAgent :: IO OwnedAgent
newOwnedAgent = OwnedAgent <$> newIORef Nothing <*> newIORef Nothing

-- | @_close_owned_resources(service, pi_runtime, route_store)@: the
-- service's own release when it opened, otherwise the runtime and the
-- routes.
closeOwnedAgent :: Maybe (IO ()) -> OwnedAgent -> IO ()
closeOwnedAgent service owned = do
  runtime <- readIORef owned.runtime
  routes <- readIORef owned.routes
  closeOwnedResources service runtime routes

-- | What tests and the state interop replace: the Pi A2 composition hooks
-- (the scripted runtime), the workspace receiver handed to the runner, and
-- the runner selection.
data AgentSeams = AgentSeams
  { hooks :: PiA2Hooks
  , workspaces :: GitPiWorkspaceProvider -> PiWorkspaceProvider
  , selectRunner :: PiA2RuntimeHost -> PiWorkspaceProvider -> IO AgentRunner
  }

-- | The production composition: the real Pi A2 runtime, the receiver as
-- is, and @compose_agent_runner@ (Pi only after an exact READY probe).
productionAgentSeams :: AgentSeams
productionAgentSeams =
  AgentSeams
    { hooks = defaultPiA2Hooks
    , workspaces = gitPiWorkspaceProvider
    , selectRunner = \host provider ->
        composedAgentRunner <$> composeAgentRunner (Just (probeHost host, piA2Runtime host, provider))
    }

-- | The agent half of @main()@ between @preflight_v5_state@ and
-- @HostService(...)@:
--
-- > installation = PiA2InstallationConfig.from_environment(os.environ, state_path=...)
-- > os.environ.pop("HAMSTERDAN_PI_API_KEY", None)
-- > agent = compose_agent(os.environ, provider=..., model=...)
-- > route_store = AgentRouteStore(state / "agent-routes.sqlite3")
-- > route_store.activate(agent, state / "applications")
-- > pi_runtime, pi_workspaces = _compose_agent_runtime(state, installation)
-- > runner = compose_agent_runner(pi_runtime=..., pi_workspaces=...)
--
-- The environment is the process's; @forgetKey@ is the @pop@. The custody
-- claims each operation's route, settles terminal operations, and closes
-- the runtime then the routes, attempting both.
composeHostAgent :: AgentSeams -> OwnedAgent -> [(Text, Text)] -> IO () -> FilePath -> IO (AgentRunner, AgentCustody)
composeHostAgent seams owned environment forgetKey statePath = do
  installation <- installationFromEnvironment environment (Just statePath)
  forgetKey
  let remaining = filter ((/= "HAMSTERDAN_PI_API_KEY") . fst) environment
  agent <- composeAgent (Just remaining) (Just installation.provider) (Just installation.model)
  store <- openAgentRouteStore (statePath </> "agent-routes.sqlite3")
  writeIORef owned.routes (Just (closeRoutes store))
  activateRoutes store agent (statePath </> "applications")
  (host, receiver) <-
    composeAgentRuntimeWith
      newGitPiWorkspaceProvider
      (\state selected -> (.host) <$> composeOwnedPiA2With seams.hooks state (Just selected))
      statePath
      installation
  writeIORef owned.runtime (Just (void (closeHost host)))
  runner <- seams.selectRunner host (seams.workspaces receiver)
  let custody =
        AgentCustody
          { claim = \operation -> void (claimRoute store operation agent)
          , settleOperations = settleRoutes store . Set.toList
          , close = closeBoth [void (closeHost host), closeRoutes store]
          }
  pure (runner, custody)
  where
    -- The service closes the runtime and the routes as two resources:
    -- both are attempted and the first failure is the one raised.
    closeBoth actions = do
      failures <- traverse attempt actions
      case [e | Left e <- failures] of
        first : _ -> throwIO first
        [] -> pure ()
    attempt :: IO () -> IO (Either SomeException ())
    attempt action = do
      outcome <- try action
      case outcome of
        Left e | isJust (fromException @SomeAsyncException e) -> throwIO e
        other -> pure other

