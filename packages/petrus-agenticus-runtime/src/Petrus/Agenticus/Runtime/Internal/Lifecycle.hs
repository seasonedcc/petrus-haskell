-- | The operation lifecycle every provider host shares (@_Operation@'s
-- monitor, @_cancelled@, @_publishing@, @_result@, and the cleanup it
-- records once).
--
-- An operation is 'Running' until either cancellation is requested
-- ('CancelRequested') or the worker claims publication ('Publishing'); the
-- two exclude each other. The worker then 'Settled' it exactly once. Close
-- is legal after settlement or after cancellation was requested, waits a
-- host-specific grace for the worker to exit, and records one immutable
-- cleanup evidence.
--
-- Hosts differ only in their texts, their grace, what a requested
-- cancellation does, and how they derive cleanup evidence; each is a
-- parameter here.
module Petrus.Agenticus.Runtime.Internal.Lifecycle
  ( Phase (..)
  , Lifecycle
  , LifecycleTexts (..)
  , newLifecycle
  , startWorker
  , guarded
  , current
  , cancelRequested
  , inspect
  , claim
  , settle
  , settleAs
  , receipt
  , isClosed
  , waitSettled
  , requestCancel
  , closeWith
  , settledEvidence
  , micros
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (finally, mask_, throwIO)
import Control.Monad (forM_, unless, void, when)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Runtime.Operation
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import System.Timeout (timeout)

data Phase
  = Running
  | CancelRequested
  | Publishing
  | -- | The settlement, and the cleanup disposition the worker proved.
    Settled RuntimeTurnSettlement RuntimeCleanupDisposition

data LifecycleTexts = LifecycleTexts
  { invalidTimeout :: Text
  -- ^ @ValueError@ for a wait bound that is not positive and finite.
  , notSettled :: Text
  -- ^ @TimeoutError@ when the wait bound expires.
  }

data Lifecycle = Lifecycle
  { operationId :: Text
  , texts :: LifecycleTexts
  , monitor :: MVar ()
  , phase :: TVar Phase
  , worker :: TVar (Maybe ThreadId)
  , exited :: TVar Bool
  , cleanup :: TVar (Maybe RuntimeOperationCleanup)
  }

-- | Handle identity.
instance Eq Lifecycle where
  a == b = a.phase == b.phase

newLifecycle :: LifecycleTexts -> Text -> IO Lifecycle
newLifecycle texts operationId =
  Lifecycle operationId texts
    <$> newMVar ()
    <*> newTVarIO Running
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO Nothing

-- | Run the worker on its own thread. A finished thread's id is dropped: a
-- retained 'ThreadId' keeps the thread's stack alive for as long as the
-- operation is remembered.
startWorker :: Lifecycle -> IO () -> IO ()
startWorker l body = mask_ $ do
  thread <- forkIOWithUnmask $ \unmask ->
    unmask body `finally` atomically (writeTVar l.exited True >> writeTVar l.worker Nothing)
  atomically $ do
    done <- readTVar l.exited
    unless done (writeTVar l.worker (Just thread))

guarded :: Lifecycle -> IO a -> IO a
guarded l action = withMVar l.monitor (const action)

-- | @not self._cancelled@ while the worker runs: whether its result may
-- still be published.
current :: Lifecycle -> IO Bool
current l =
  readTVarIO l.phase >>= \case
    Running -> pure True
    Publishing -> pure True
    _ -> pure False

cancelRequested :: Lifecycle -> IO Bool
cancelRequested l =
  readTVarIO l.phase >>= \case
    CancelRequested -> pure True
    _ -> pure False

-- | Under the monitor: @"cancelled"@ once cancellation was requested,
-- otherwise the host's publication check.
inspect :: Lifecycle -> IO (Maybe Text) -> IO (Maybe Text)
inspect l publicationCheck = guarded l (unguardedInspect l publicationCheck)

unguardedInspect :: Lifecycle -> IO (Maybe Text) -> IO (Maybe Text)
unguardedInspect l publicationCheck = do
  cancelled <- cancelRequested l
  if cancelled then pure (Just "cancelled") else publicationCheck

-- | @_Operation.claim@'s final step: 'inspect', and on success enter
-- 'Publishing' (after which cancellation is too late).
claim :: Lifecycle -> IO (Maybe Text) -> IO (Maybe Text)
claim l publicationCheck =
  guarded l $
    unguardedInspect l publicationCheck >>= \case
      Just refusal -> pure (Just refusal)
      Nothing -> atomically (writeTVar l.phase Publishing) >> pure Nothing

-- | Settle under the monitor; a requested cancellation turns any other
-- outcome into the given cancelled settlement.
settle :: Lifecycle -> IO RuntimeTurnSettlement -> (RuntimeTurnSettlement, RuntimeCleanupDisposition) -> IO ()
settle l cancelled (settlement, disposition) =
  guarded l $ do
    wasCancelled <- cancelRequested l
    settlement' <-
      if wasCancelled && settlement.outcome /= TurnCancelled
        then cancelled
        else pure settlement
    atomically (writeTVar l.phase (Settled settlement' disposition))

-- | Settle as given (the host derives its cleanup evidence itself).
settleAs :: Lifecycle -> RuntimeTurnSettlement -> IO ()
settleAs l settlement = atomically (writeTVar l.phase (Settled settlement RuntimeCleanupUnverified))

receipt :: Lifecycle -> IO (Maybe RuntimeTurnSettlement)
receipt l =
  readTVarIO l.phase >>= \case
    Settled settlement _ -> pure (Just settlement)
    _ -> pure Nothing

isClosed :: Lifecycle -> IO Bool
isClosed l = isJust <$> readTVarIO l.cleanup

-- | @wait(timeout)@.
waitSettled :: Lifecycle -> Maybe Double -> IO RuntimeTurnSettlement
waitSettled l bound = do
  forM_ bound $ \t ->
    when (isNaN t || isInfinite t || t <= 0) $ throwIO (valueError l.texts.invalidTimeout)
  closedAlready <- isClosed l
  when closedAlready $ throwIO (runtimeProtocolError "operation-closed")
  expired <- maybe (newTVarIO False) (registerDelay . micros) bound
  settled <-
    atomically $
      ( readTVar l.phase >>= \case
          Settled settlement _ -> pure (Just settlement)
          _ -> retry
      )
        `orElse` (readTVar expired >>= \e -> if e then pure Nothing else retry)
  maybe (throwAgenticus TimeoutError l.texts.notSettled) pure settled

-- | @cancel(reason)@ after the host validated the reason: run the host's
-- cancellation (outside the monitor) only when this call requested it.
requestCancel :: Lifecycle -> IO () -> IO CancellationDisposition
requestCancel l onRequest = do
  disposition <-
    guarded l . atomically $
      readTVar l.phase >>= \case
        Running -> writeTVar l.phase CancelRequested >> pure CancellationRequested
        CancelRequested -> pure CancellationAlreadyRequested
        _ -> pure CancellationTooLate
  when (disposition == CancellationRequested) onRequest
  pure disposition

-- | @close()@: legal after settlement or a cancellation request; wait up
-- to @grace@ seconds for the worker (never for the calling thread itself),
-- then record the evidence the host derives from whether it exited.
closeWith :: Lifecycle -> Double -> (Bool -> IO (RuntimeCleanupDisposition, Text)) -> IO RuntimeOperationCleanup
closeWith l grace evidence = do
  existing <- guarded l $ do
    existing <- readTVarIO l.cleanup
    closable <-
      readTVarIO l.phase >>= \case
        Settled {} -> pure True
        CancelRequested -> pure True
        _ -> pure False
    when (isNothing existing && not closable) $ throwIO (runtimeProtocolError "operation-active")
    pure existing
  case existing of
    Just recorded -> pure recorded
    Nothing -> do
      thread <- readTVarIO l.worker
      self <- myThreadId
      unless (thread == Just self) $
        void (timeout (micros grace) (atomically (readTVar l.exited >>= check)))
      done <- readTVarIO l.exited
      (disposition, code) <- evidence done
      recorded <- throwLeft (mkRuntimeOperationCleanup l.operationId disposition code False)
      atomically $
        readTVar l.cleanup >>= \case
          Just earlier -> pure earlier
          Nothing -> writeTVar l.cleanup (Just recorded) >> pure recorded

-- | The evidence of a worker that proved its disposition at settlement; a
-- worker that has not exited is unverified.
settledEvidence :: Lifecycle -> Bool -> IO (RuntimeCleanupDisposition, Text)
settledEvidence l done = do
  settled <- readTVarIO l.phase
  let disposition = case settled of
        Settled _ proven | done -> proven
        _ -> RuntimeCleanupUnverified
  pure . (disposition,) $ case disposition of
    RuntimeCleanupNotCreated -> "client-not-created"
    RuntimeCleanupClean -> "client-closed"
    RuntimeCleanupUnverified -> "cleanup-uncertain"

-- | Seconds to 'threadDelay' microseconds.
micros :: Double -> Int
micros seconds = max 0 (round (seconds * 1000000))
