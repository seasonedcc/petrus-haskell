-- | The agent resources @hamsterdan.host.__main__@ owns at startup: the
-- Pi workspace receiver and the owned Pi A2 runtime
-- (@_compose_agent_runtime@), and their fail-closed release
-- (@_close_owned_resources@).
module Hamsterdan.Host.AgentRuntime
  ( composeAgentRuntimeWith
  , closeOwnedResources
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Hamsterdan.Host.PiA2 (PiA2InstallationConfig)
import Petrus.Motus.Worker (RuntimeError (..))
import System.FilePath ((</>))

-- | @_compose_agent_runtime(state_path, installation)@ over the two
-- constructors the reference test monkeypatches (@GitPiWorkspaceProvider@
-- and @compose_owned_pi_a2@): the workspace receiver below
-- @state/pi-workspaces@ first, then the owned runtime, so a receiver
-- failure never leaves a runtime behind.
composeAgentRuntimeWith
  :: (FilePath -> IO workspaces)
  -> (FilePath -> PiA2InstallationConfig -> IO runtime)
  -> FilePath
  -> PiA2InstallationConfig
  -> IO (runtime, workspaces)
composeAgentRuntimeWith workspaceProvider composeOwned statePath installation = do
  workspaces <- workspaceProvider (statePath </> "pi-workspaces")
  runtime <- composeOwned statePath installation
  pure (runtime, workspaces)

-- | @_close_owned_resources(service, runtime, routes)@: the service alone
-- when it exists (it owns the rest), otherwise the runtime and the route
-- store; every resource is attempted and the first failure becomes
-- @RuntimeError("host resource cleanup is unverified")@.
closeOwnedResources :: Maybe (IO ()) -> Maybe (IO ()) -> Maybe (IO ()) -> IO ()
closeOwnedResources service runtime routes = do
  let resources = maybe (catMaybes [runtime, routes]) pure service
  failure <- newIORef Nothing
  forM_ resources $ \resource -> do
    outcome <- try @SomeException resource
    case outcome of
      Left e
        | isJust (fromException @SomeAsyncException e) -> throwIO e
        | otherwise -> modifyIORef' failure (Just . fromMaybe e)
      Right () -> pure ()
  readIORef failure >>= \case
    Just _ -> throwIO (RuntimeError "host resource cleanup is unverified")
    Nothing -> pure ()
