{-# LANGUAGE AllowAmbiguousTypes #-}

-- | @type(error).__name__@: the reference class a caught exception stands
-- for, as the host records it in History (an @ActivityError@'s kind), in
-- the webhook inbox (@inbox.error_class@), in the status document
-- (@error_classes@) and in its log lines.
--
-- The list is closed: every exception type the Hamsterdan packages the host
-- runs on declare is named here with its reference class (or is one of
-- 'unlistedExceptionTypes', which never reach a catch that names them), and
-- the host's test suite fails on any declared type missing from both. A
-- failure from outside Hamsterdan and Petrus (a library's own exception)
-- keeps its Haskell type name; the reference has no counterpart for it.
module Hamsterdan.Host.ExceptionClass
  ( exceptionClass
  , listedExceptionTypes
  , unlistedExceptionTypes
  ) where

import Control.Exception
  ( ArithException
  , ArrayException
  , ErrorCall
  , Exception (..)
  , IOException
  , SomeException (..)
  )
import Data.Foldable (asum)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Proxy (..), TypeRep, typeOf, typeRep)
import Hamsterdan.Agents.Pi (PiWorkspaceError (..))
import Hamsterdan.Agents.Protocol (AgentProtocolError)
import Hamsterdan.GitHub.Config (ConfigurationError)
import Hamsterdan.GitHub.Http (ClientError (..))
import Hamsterdan.GitHub.Models
  ( BoundaryKind (..)
  , ContractRefused
  , GitHubBoundaryError (..)
  , InvalidRequest
  , PublicationCollision
  , PublicationRejected
  , RerunRefused
  )
import Hamsterdan.GitHub.Routing (InventoryMismatch)
import Hamsterdan.GitHub.Webhooks (WebhookRejected)
import Hamsterdan.Host.Agenticus (AgentCompositionError)
import Hamsterdan.Host.Errors (UnstagedCustodyError)
import Hamsterdan.Host.GitPublish (GitPublishError)
import Petrus.Activity (ActivityError)
import Petrus.Agenticus.Error (AgenticusError (..), errorClassName)
import Petrus.Json.Python (PythonException (..))
import Petrus.Json.Python.Exception (asPythonException)
import Petrus.Json.Python.OsError (ioExceptionClass)
import Petrus.Sqlite.Connection (SQLError (..), pythonSqliteClass)

-- | @type(error).__name__@ of a caught exception.
exceptionClass :: SomeException -> Text
exceptionClass e@(SomeException inner) =
  fromMaybe (T.pack (show (typeOf inner))) (asum [name e | Listed _ name <- classes])

-- | One listed type and how its value names its reference class.
data Listed = Listed TypeRep (SomeException -> Maybe Text)

listed :: forall e. (Exception e) => (e -> Text) -> Listed
listed name = Listed (typeRep (Proxy @e)) (fmap name . fromException)

named :: forall e. (Exception e) => Text -> Listed
named name = listed @e (const name)

classes :: [Listed]
classes =
  [ -- Every member of the Python exception hierarchy (a Petrus port's
    -- refusal too), by the class it stands for.
    Listed (typeRep (Proxy @PythonException)) (fmap (.name) . asPythonException)
  , -- A driver failure that did not pass through "Hamsterdan.Sqlite".
    listed @SQLError (pythonSqliteClass . (.sqlError))
  , listed @GitHubBoundaryError $ \failure -> case failure.kind of
      Boundary -> "GitHubBoundaryError"
      ObjectWrite -> "GitHubObjectWriteError"
  , named @UnstagedCustodyError "UnstagedCustodyError"
  , listed @ClientError (.pythonClass)
  , named @RerunRefused "RerunRefusedError"
  , named @ContractRefused "RuntimeError"
  , named @InvalidRequest "ValueError"
  , named @PublicationCollision "ValueError"
  , named @PublicationRejected "ValueError"
  , named @InventoryMismatch "ValueError"
  , named @ConfigurationError "ConfigurationError"
  , named @WebhookRejected "WebhookRejected"
  , named @ActivityError "ActivityError"
  , named @AgentCompositionError "AgentCompositionError"
  , named @AgentProtocolError "AgentProtocolError"
  , listed @PiWorkspaceError $ \case
      PiWorkspaceError _ -> "PiWorkspaceError"
      PiWorkspaceCleanupError _ -> "PiWorkspaceCleanupError"
  , listed @AgenticusError (\failure -> errorClassName failure.errorClass)
  , named @GitPublishError "GitPublishError"
  , -- A failed system call: the OSError subclass CPython raises for its
    -- errno (FileNotFoundError, PermissionError, ...).
    listed @IOException ioExceptionClass
  , -- Failures only Haskell raises: the nearest built-in class.
    named @ErrorCall "RuntimeError"
  , named @ArithException "ArithmeticError"
  , named @ArrayException "IndexError"
  ]

-- | The types 'exceptionClass' names.
listedExceptionTypes :: [TypeRep]
listedExceptionTypes = [rep | Listed rep _ <- classes]

-- | Exception types the Hamsterdan packages declare that never reach
-- 'exceptionClass', by name, with the reason.
unlistedExceptionTypes :: [(Text, Text)]
unlistedExceptionTypes =
  [ ("BaseException", "a BaseException-only class: no `except Exception` (catchPython) catches it")
  , ("MalformedRoot", "the preflight walk's internal ValueError, caught and re-raised as RuntimeError inside it")
  , ("Escape", "the Gateway's jump to its own except clause, caught where it is raised")
  ]
