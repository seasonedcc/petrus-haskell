-- | The Dispatch port: Petri-agnostic Activity custody
-- (@petrus.motus.dispatch@).
--
-- = The port
--
-- The Engine's coordinator hands every impure firing's frozen
-- 'ActivityInvocation' to a 'Dispatch' and later collects terminal outcomes
-- from it. Acknowledgement and completion are different events: 'dispatch'
-- only takes custody, and an outcome becomes visible only through a later
-- 'collect'. The reference's @Dispatch@ and @CancellableDispatch@ protocols
-- become one record whose 'cancel' field is the optional recoverable
-- cancellation extension: 'Nothing' is a Dispatch that does not implement it
-- (the reference's @isinstance(dispatch, CancellableDispatch)@ is false).
--
-- = Contract every implementation keeps
--
-- * @dispatch occurrence invocation@ takes custody of exactly one logical
--   invocation per occurrence. Re-dispatching the same occurrence with the
--   same invocation after a crash is the outbox redispatch the coordinator
--   performs on load; a durable provider must make it idempotent. A
--   dispatch for an occurrence whose cancellation fence is installed is
--   dropped when the invocation matches and refused otherwise.
-- * @collect@ drains terminal outcomes in arrival order. Each occurrence is
--   answered at most once per dispatch; the coordinator refuses an answer for
--   an occurrence it never dispatched.
-- * @cancel instruction@ installs a recoverable fence after the canonical
--   cancellation commit and reports the custody it found
--   ('CancellationDisposition'). Repeating an identical instruction is
--   'Acknowledged'; a different instruction for the same occurrence is a
--   conflict.
-- * Errors are thrown as exceptions. The Engine treats any exception from a
--   Dispatch call made inside a writing door as poisoning.
--
-- = Durable providers
--
-- A durable provider (the local SQLite Dispatch, ZeroMQ, Absurd) returns a
-- 'Dispatch' built over its own connection, plus — through the Engine's
-- provider seam (@Petrus.Engine.Provider@) — its transaction hooks and its
-- wake-up hint. 'Dispatch' deliberately has no lifecycle or wait fields:
-- those belong to the provider's resources, which the Engine composes, so an
-- in-process adapter never has to pretend to own a transaction. Workers use
-- the separate custody surface 'WorkerDispatch' over 'ActivityAttempt's.
module Petrus.Motus.Dispatch
  ( -- * The port
    Dispatch (..)
  , ActivityOutcome (..)
  , outcomeFailure
  , isCancellable
    -- * Recoverable cancellation
  , CancellationInstruction
  , cancellationInstruction
  , CancellationDisposition (..)
  , dispositionText
    -- * Worker custody
  , ActivityAttempt
  , activityAttempt
  , AttemptFailure (..)
  , WorkerDispatch (..)
    -- * Errors
  , DispatchError (..)
  , dispatchError
  ) where

import Control.Exception (Exception (..), SomeException, throwIO)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Activity
import Petrus.Json (Json)
import Petrus.Json.Python.Exception (IsPythonException (..), pythonExceptionFromException, pythonExceptionToException, raised)

-- ---------------------------------------------------------------------------
-- The port

-- | A terminal Activity outcome as Dispatch reports it: a JSON result, or a
-- classified failure. (The reference's @collect@ yields @(occurrence,
-- object)@ pairs and tells failures apart with @isinstance@.)
data ActivityOutcome
  = Succeeded Json
  | Failed ActivityFailure
  deriving stock (Eq, Show)

-- | The failure, when the outcome is one.
outcomeFailure :: ActivityOutcome -> Maybe ActivityFailure
outcomeFailure = \case
  Failed failure -> Just failure
  Succeeded _ -> Nothing

-- | Asynchronous Activity custody and completion collection.
data Dispatch = Dispatch
  { dispatch :: Int -> ActivityInvocation -> IO ()
  -- ^ Take custody of one occurrence's invocation (acknowledgement only).
  , collect :: IO [(Int, ActivityOutcome)]
  -- ^ Drain terminal outcomes in arrival order.
  , cancel :: Maybe (CancellationInstruction -> IO CancellationDisposition)
  -- ^ The optional recoverable cancellation extension.
  }

-- | Whether the Dispatch implements recoverable cancellation.
isCancellable :: Dispatch -> Bool
isCancellable d = isJust d.cancel

-- ---------------------------------------------------------------------------
-- Cancellation

-- | Recoverable fence for one exact logical invocation after canonical
-- commit; only constructible through 'cancellationInstruction'.
data CancellationInstruction = CancellationInstruction
  { _occurrence :: Int
  , _invocation :: ActivityInvocation
  , _historyPosition :: Int
  }
  deriving stock (Eq, Show)

instance HasField "occurrence" CancellationInstruction Int where
  getField r = r._occurrence

instance HasField "invocation" CancellationInstruction ActivityInvocation where
  getField r = r._invocation

instance HasField "historyPosition" CancellationInstruction Int where
  getField r = r._historyPosition

-- | Validate as @CancellationInstruction.__post_init__@ does.
cancellationInstruction :: Int -> ActivityInvocation -> Int -> Either Text CancellationInstruction
cancellationInstruction occurrence inv position
  | occurrence < 1 = Left "Cancellation Instruction occurrence must be a positive integer"
  | position < 1 = Left "Cancellation Instruction history_position must be a positive integer"
  | otherwise = Right (CancellationInstruction occurrence inv position)

-- | Operational custody found when a cancellation fence was installed.
data CancellationDisposition
  = Tombstoned
  | Retired
  | Fenced
  | Terminal
  | Acknowledged
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The disposition's wire spelling (the reference's @StrEnum@ value).
dispositionText :: CancellationDisposition -> Text
dispositionText = \case
  Tombstoned -> "tombstoned"
  Retired -> "retired"
  Fenced -> "fenced"
  Terminal -> "terminal"
  Acknowledged -> "acknowledged"

-- ---------------------------------------------------------------------------
-- Worker custody

-- | A detached, provider-neutral fenced claim on one Activity invocation;
-- only constructible through 'activityAttempt'.
data ActivityAttempt = ActivityAttempt
  { _attemptId :: Text
  , _epoch :: Text
  , _claimant :: Text
  , _queue :: Text
  , _invocation :: ActivityInvocation
  , _latestDetails :: Json
  , _instance' :: Maybe Text
  }
  deriving stock (Eq, Show)

instance HasField "attemptId" ActivityAttempt Text where
  getField r = r._attemptId

instance HasField "epoch" ActivityAttempt Text where
  getField r = r._epoch

instance HasField "claimant" ActivityAttempt Text where
  getField r = r._claimant

instance HasField "queue" ActivityAttempt Text where
  getField r = r._queue

instance HasField "invocation" ActivityAttempt ActivityInvocation where
  getField r = r._invocation

instance HasField "latestDetails" ActivityAttempt Json where
  getField r = r._latestDetails

instance HasField "instance'" ActivityAttempt (Maybe Text) where
  getField r = r._instance'

-- | Validate as @ActivityAttempt.__post_init__@ does: a present instance is
-- non-empty, and the latest heartbeat details are snapshotted.
activityAttempt :: Text -> Text -> Text -> Text -> ActivityInvocation -> Json -> Maybe Text -> Either Text ActivityAttempt
activityAttempt attempt epoch claimant queue inv details instance'
  | instance' == Just "" = Left "Activity Attempt instance must be a non-empty string or None"
  | otherwise = do
      snapshot <- snapshotHeartbeatDetails details
      Right (ActivityAttempt attempt epoch claimant queue inv snapshot instance')

-- | What a Worker reports when an Attempt fails: a message, an exception it
-- caught, or an already classified failure (the reference's
-- @str | Exception | ActivityFailure@).
data AttemptFailure
  = FailureMessage Text
  | FailureException SomeException
  | FailureClassified ActivityFailure
  deriving stock (Show)

-- | The provider-neutral synchronous custody surface consumed by a Worker.
data WorkerDispatch = WorkerDispatch
  { claim :: IO (Maybe ActivityAttempt)
  , heartbeat :: ActivityAttempt -> Maybe Json -> IO Json
  -- ^ 'Nothing' is the reference's omitted @details@.
  , complete :: ActivityAttempt -> Json -> IO ()
  , fail :: ActivityAttempt -> AttemptFailure -> IO ()
  , wait :: Double -> IO Bool
  , close :: IO ()
  }

-- ---------------------------------------------------------------------------
-- Errors

-- | A Dispatch refusal: the reference's @ValueError@ from an adapter.
newtype DispatchError = DispatchError Text
  deriving stock (Eq, Show)

instance Exception DispatchError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (DispatchError message) = T.unpack message

instance IsPythonException DispatchError where
  toPythonException (DispatchError message) = raised "ValueError" message

-- | Throw a 'DispatchError'.
dispatchError :: Text -> IO a
dispatchError = throwIO . DispatchError
