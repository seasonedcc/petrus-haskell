-- | Execute named Activities inline and buffer dispatched terminal outcomes
-- (the reference's @InlineDispatch@).
--
-- 'runInline' is the reference's @__call__@: it executes the invocation's
-- named Activity with the resolved policy's attempts, retrying immediately
-- (never sleeping for backoff) while the classified failure is retryable,
-- the schedule-to-close budget has not expired, and attempts remain; then it
-- rethrows the original exception. 'inlineDispatch' is the 'Dispatch' view:
-- a dispatch runs the Activity at once and buffers its outcome for the next
-- 'collect', so acknowledgement and completion stay different events.
module Petrus.Motus.Dispatch.Inline
  ( Activity
  , InlineDispatch
  , newInlineDispatch
  , inlineActivities
  , runInline
  , inlineDispatch
  , inlineCancelled
  , classifyInlineFailure
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Motus.Internal.Repr
import Petrus.Motus.PythonException (PythonException (..), pythonException)

-- | An Activity implementation: the whole invocation and the Attempt's
-- execution context in, a JSON result out. Throw 'ActivityError' to classify
-- a failure; any other exception is classified as retryable.
type Activity = ActivityInvocation -> ActivityExecutionContext -> IO Json

-- | An inline Dispatch: a snapshotted Activity registry plus the buffered
-- outcomes and installed cancellation fences.
data InlineDispatch = InlineDispatch
  { activities :: Map Text Activity
  , completed :: IORef [(Int, ActivityOutcome)]
  -- ^ Newest first.
  , cancelled :: IORef (Map Int CancellationInstruction)
  }

-- | An adapter over a snapshot of the registry.
newInlineDispatch :: Map Text Activity -> IO InlineDispatch
newInlineDispatch registry = InlineDispatch registry <$> newIORef [] <*> newIORef Map.empty

-- | The registry the adapter implements.
inlineActivities :: InlineDispatch -> Map Text Activity
inlineActivities adapter = adapter.activities

-- | The installed cancellation fences.
inlineCancelled :: InlineDispatch -> IO (Map Int CancellationInstruction)
inlineCancelled adapter = readIORef adapter.cancelled

-- | Execute one invocation inline (the reference's @__call__@).
runInline :: InlineDispatch -> ActivityInvocation -> IO Json
runInline adapter inv = case Map.lookup inv.activity adapter.activities of
  Nothing ->
    dispatchError
      ( "no activity implementation for "
          <> pyStr inv.activity
          <> ": this InlineDispatch implements "
          <> pyStrList (Map.keys adapter.activities)
      )
  Just implementation -> do
    started <- getMonotonicTime
    let fields = policyFields inv.policy
        budget = fields.attempts
        go attempt = do
          context <- inlineContext attempt
          try (implementation inv context >>= \result -> result `seq` pure result) >>= \case
            Right result -> pure result
            Left err
              | isAsync err -> throwIO err
              | otherwise -> do
                  failure <- classifyInlineFailure err
                  now <- getMonotonicTime
                  let expired = case fields.scheduleToClose of
                        Nothing -> False
                        Just limit -> now - started >= numberValue limit
                  if not (failureFields failure).failureRetryable || expired || attempt == budget
                    then throwIO err
                    else go (attempt + 1)
    go 1

-- | The synthetic Attempt context of one inline attempt: identity
-- @inline-N@ / epoch @N@ / claimant @inline@, no instance, and detached
-- heartbeat details starting at null.
inlineContext :: Integer -> IO ActivityExecutionContext
inlineContext attempt = do
  details <- newIORef Null
  let heartbeat = \case
        Nothing -> readIORef details
        Just value -> case snapshotHeartbeatDetails value of
          Left err -> dispatchError err
          Right snapshot -> writeIORef details snapshot >> pure snapshot
  pure
    ActivityExecutionContext
      { attemptId = "inline-" <> T.pack (show attempt)
      , epoch = T.pack (show attempt)
      , claimant = "inline"
      , instance' = Nothing
      , latestDetails = readIORef details
      , heartbeat
      }

-- | Classify an Activity's exception: an 'ActivityError' carries its
-- failure; anything else is a retryable failure named after the exception's
-- Python class ('pythonException'), with its message (or the class name when
-- the message is empty), as @str(exc) or type(exc).__name__@ does.
classifyInlineFailure :: SomeException -> IO ActivityFailure
classifyInlineFailure err = case fromException err of
  Just (ActivityError failure) -> pure failure
  Nothing ->
    let PythonException {className = kind, message} = pythonException err
        fields =
          ActivityFailureFields
            { failureError = if T.null message then kind else message
            , failureKind = kind
            , failureDetails = Null
            , failureRetryable = True
            , failureRetryAfter = Nothing
            }
     in either dispatchError pure (activityFailure fields)

isAsync :: SomeException -> Bool
isAsync err = isJust (fromException err :: Maybe SomeAsyncException)

-- | The 'Dispatch' view: execute at dispatch, buffer for 'collect'.
inlineDispatch :: InlineDispatch -> Dispatch
inlineDispatch adapter =
  Dispatch
    { dispatch = \occurrence inv -> do
        fences <- readIORef adapter.cancelled
        case Map.lookup occurrence fences of
          Just fence
            | fence.invocation /= inv ->
                dispatchError ("cancellation conflict for occurrence " <> T.pack (show occurrence))
            | otherwise -> pure ()
          Nothing -> do
            outcome <-
              try (runInline adapter inv) >>= \case
                Right result -> pure (Succeeded result)
                Left err
                  | isAsync err -> throwIO err
                  | otherwise -> Failed <$> classifyInlineFailure err
            modifyIORef' adapter.completed ((occurrence, outcome) :)
    , collect = atomicModifyIORef' adapter.completed (\buffered -> ([], reverse buffered))
    , cancel = Just $ \instruction -> do
        fences <- readIORef adapter.cancelled
        case Map.lookup instruction.occurrence fences of
          Just prior
            | prior /= instruction ->
                dispatchError ("cancellation conflict for occurrence " <> T.pack (show instruction.occurrence))
            | otherwise -> pure Acknowledged
          Nothing -> do
            writeIORef adapter.cancelled (Map.insert instruction.occurrence instruction fences)
            buffered <- readIORef adapter.completed
            pure $
              if any ((== instruction.occurrence) . fst) buffered
                then Terminal
                else Tombstoned
    }
