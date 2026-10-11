-- | How the host's gates read a caught exception the way the reference's
-- @except@ clauses do.
--
-- The reference classifies provider outcomes by Python exception class:
-- @GitHubBoundaryError@ (and its @UnstagedCustodyError@ subclass), the
-- @RuntimeError@ family, and the @ValueError@ family. A Haskell port
-- raises distinct exception types for the same failures; 'caught' maps
-- each one onto the reference class it stands for, with the reference's
-- @str(error) or repr(error)@ text. Any exception outside those families
-- (a @TypeError@, a @KeyError@, an asynchronous exception) is not caught
-- and propagates, as the reference's would.
module Hamsterdan.Host.Errors
  ( UnstagedCustodyError (..)
  , unstagedMessage
  , Caught (..)
  , caught
  , caughtReason
  , catchGate
  , isBoundary
  , catchBoundary
  ) where

import Control.Exception (Exception (..), SomeException, catch, fromException, throwIO, try)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Models
  ( ContractRefused (..)
  , GitHubBoundaryError (..)
  , InvalidRequest (..)
  , PublicationCollision (..)
  , PublicationRejected (..)
  , RerunRefused (..)
  )
import Hamsterdan.Agents.Protocol (AgentProtocolError (..))
import Hamsterdan.GitHub.Python (PythonFault (..))
import Hamsterdan.Host.Agenticus (AgentCompositionError (..))
import Hamsterdan.Host.GitPublish (GitPublishError (..))
import Petrus.Agenticus.Error (AgenticusError (..), errorClassName, isSubclassOf)
import Petrus.Agenticus.Error qualified as AE
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..))

-- | @UnstagedCustodyError(blocker)@: one exact same-PR custody row has not
-- entered canonical History. A @GitHubBoundaryError@ subclass.
newtype UnstagedCustodyError = UnstagedCustodyError {blocker :: Text}
  deriving stock (Eq, Show)

instance Exception UnstagedCustodyError where
  displayException _ = T.unpack unstagedMessage

unstagedMessage :: Text
unstagedMessage = "custodied authority is not staged in the V5 host grant"

-- | A caught exception, by the reference class its handlers test.
data Caught
  = -- | @UnstagedCustodyError@ (also a boundary error).
    CaughtUnstaged Text
  | -- | @GitHubBoundaryError@.
    CaughtBoundary GitHubBoundaryError
  | -- | @RerunRefusedError@ (a @RuntimeError@), with its text.
    CaughtRerunRefused Text
  | -- | Any other @RuntimeError@ or @ValueError@, with its reason.
    CaughtFault Text
  deriving stock (Show)

orRepr :: Text -> Text -> Text
orRepr cls message = if T.null message then cls <> "()" else message

-- | The reference class of a caught exception, or 'Nothing' when the
-- reference's @except (RuntimeError, ValueError)@ would not catch it.
caught :: SomeException -> Maybe Caught
caught err
  | Just (UnstagedCustodyError b) <- fromException err = Just (CaughtUnstaged b)
  | Just (e :: GitHubBoundaryError) <- fromException err = Just (CaughtBoundary e)
  | Just (RerunRefused m) <- fromException err = Just (CaughtRerunRefused (orRepr "RerunRefusedError" m))
  | Just (RuntimeError m) <- fromException err = Just (CaughtFault (orRepr "RuntimeError" m))
  | Just (ValueError m) <- fromException err = Just (CaughtFault (orRepr "ValueError" m))
  | Just (AgentCompositionError m) <- fromException err = Just (CaughtFault (orRepr "AgentCompositionError" m))
  | Just (e :: AgenticusError) <- fromException err
  , any (e.errorClass `isSubclassOf`) [AE.ValueError, AE.RuntimeError] =
      Just (CaughtFault (orRepr (errorClassName e.errorClass) e.errorMessage))
  | Just (ContractRefused m) <- fromException err = Just (CaughtFault (orRepr "RuntimeError" m))
  | Just (e :: GitPublishError) <- fromException err = Just (CaughtFault (orRepr "GitPublishError" e.reason))
  | Just (e :: AgentProtocolError) <- fromException err = Just (CaughtFault (orRepr "AgentProtocolError" e.reason))
  | Just (InvalidRequest m) <- fromException err = Just (CaughtFault (orRepr "ValueError" m))
  | Just PublicationCollision <- fromException err =
      Just (CaughtFault "stable publication operation collided with a different payload")
  | Just (PublicationRejected op) <- fromException err = Just (CaughtFault ("GitHub rejected " <> op))
  | Just (PythonFault cls detail) <- fromException err
  , cls `elem` valueFamily || cls `elem` runtimeFamily =
      Just (CaughtFault (orRepr cls detail))
  | otherwise = Nothing
  where
    valueFamily = ["ValueError", "UnicodeError", "UnicodeDecodeError", "UnicodeEncodeError", "JSONDecodeError"]
    runtimeFamily = ["RuntimeError", "NotImplementedError", "RecursionError"]

-- | @str(error) or repr(error)@ of a caught exception.
caughtReason :: Caught -> Text
caughtReason = \case
  CaughtUnstaged _ -> unstagedMessage
  CaughtBoundary e -> orRepr "GitHubBoundaryError" e.message
  CaughtRerunRefused reason -> reason
  CaughtFault reason -> reason

-- | Run an action, handing a caught exception to the classifier and
-- rethrowing anything the reference would not catch.
catchGate :: IO a -> (Caught -> IO a) -> IO a
catchGate action handler =
  try action >>= \case
    Right value -> pure value
    Left err -> maybe (throwIO err) handler (caught err)

-- | Whether the reference's @except GitHubBoundaryError@ catches this
-- exception (the boundary error itself or @UnstagedCustodyError@).
isBoundary :: SomeException -> Bool
isBoundary err = isJust (fromException @GitHubBoundaryError err) || isJust (fromException @UnstagedCustodyError err)

-- | @try: action except GitHubBoundaryError: handler@, the handler given
-- the action that rethrows the original.
catchBoundary :: IO a -> (IO a -> IO a) -> IO a
catchBoundary action handler =
  action `catch` \err -> if isBoundary err then handler (throwIO err) else throwIO err
