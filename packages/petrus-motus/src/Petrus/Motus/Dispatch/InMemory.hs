-- | Deterministic in-memory Dispatch whose pending work is pumped explicitly
-- (the reference's @InMemoryDispatch@).
--
-- A dispatch parks the invocation in the pool; the test host (or any
-- driver) later settles it with 'completeOccurrence', 'failOccurrence', or
-- 'settleOccurrence', and the outcome becomes visible through the next
-- 'collect'.
module Petrus.Motus.Dispatch.InMemory
  ( InMemoryDispatch
  , newInMemoryDispatch
  , inMemoryDispatch
  , pending
  , pendingInvocation
  , cancelledInstructions
  , completeOccurrence
  , failOccurrence
  , settleOccurrence
  ) where

import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json)
import Petrus.Motus.Dispatch

data Pool = Pool
  { pendingWork :: IntMap (Int, ActivityInvocation)
  -- ^ Occurrence to (insertion sequence, invocation).
  , nextSequence :: Int
  , completed :: [(Int, ActivityOutcome)]
  -- ^ Newest first.
  , cancelled :: IntMap CancellationInstruction
  }

-- | The pool.
newtype InMemoryDispatch = InMemoryDispatch (IORef Pool)

-- | An empty pool.
newInMemoryDispatch :: IO InMemoryDispatch
newInMemoryDispatch = InMemoryDispatch <$> newIORef (Pool IntMap.empty 0 [] IntMap.empty)

-- | The pending invocations, in dispatch order.
pending :: InMemoryDispatch -> IO [(Int, ActivityInvocation)]
pending (InMemoryDispatch ref) = do
  pool <- readIORef ref
  pure [(occurrence, inv) | (occurrence, (_, inv)) <- sortOn (fst . snd) (IntMap.toList pool.pendingWork)]

-- | One occurrence's pending invocation.
pendingInvocation :: InMemoryDispatch -> Int -> IO (Maybe ActivityInvocation)
pendingInvocation (InMemoryDispatch ref) occurrence = fmap snd . IntMap.lookup occurrence . (.pendingWork) <$> readIORef ref

-- | The installed cancellation fences.
cancelledInstructions :: InMemoryDispatch -> IO (IntMap CancellationInstruction)
cancelledInstructions (InMemoryDispatch ref) = (.cancelled) <$> readIORef ref

-- | Complete a pending occurrence with a result (@pool.complete@).
completeOccurrence :: InMemoryDispatch -> Int -> Json -> IO ()
completeOccurrence pool occurrence = settleOccurrence pool occurrence . Succeeded

-- | Fail a pending occurrence with @ActivityFailure(error)@ (@pool.fail@).
failOccurrence :: InMemoryDispatch -> Int -> Text -> IO ()
failOccurrence pool occurrence message =
  either dispatchError (settleOccurrence pool occurrence . Failed) (simpleFailure message)

-- | Settle a pending occurrence with any outcome. An occurrence whose
-- cancellation fence is installed may be settled without being pending.
settleOccurrence :: InMemoryDispatch -> Int -> ActivityOutcome -> IO ()
settleOccurrence (InMemoryDispatch ref) occurrence outcome = do
  pool <- readIORef ref
  let fenced = IntMap.member occurrence pool.cancelled
  if not fenced && not (IntMap.member occurrence pool.pendingWork)
    then
      dispatchError
        ("occurrence " <> T.pack (show occurrence) <> " is not pending in this pool: dispatch it before completing it")
    else
      writeIORef
        ref
        pool
          { pendingWork = if fenced then pool.pendingWork else IntMap.delete occurrence pool.pendingWork
          , completed = (occurrence, outcome) : pool.completed
          }

-- | The 'Dispatch' view of the pool.
inMemoryDispatch :: InMemoryDispatch -> Dispatch
inMemoryDispatch (InMemoryDispatch ref) =
  Dispatch
    { dispatch = \occurrence inv -> do
        pool <- readIORef ref
        case IntMap.lookup occurrence pool.cancelled of
          Just fence
            | fence.invocation /= inv -> conflict occurrence
            | otherwise -> pure ()
          Nothing
            | IntMap.member occurrence pool.pendingWork ->
                dispatchError
                  ( "occurrence "
                      <> T.pack (show occurrence)
                      <> " is already pending in this pool: one dispatch per occurrence"
                  )
            | otherwise ->
                writeIORef
                  ref
                  pool
                    { pendingWork = IntMap.insert occurrence (pool.nextSequence, inv) pool.pendingWork
                    , nextSequence = pool.nextSequence + 1
                    }
    , collect = atomicModifyIORef' ref (\pool -> (pool {completed = []}, reverse pool.completed))
    , cancel = Just $ \instruction -> do
        pool <- readIORef ref
        let occurrence = instruction.occurrence
            fence = pool {cancelled = IntMap.insert occurrence instruction pool.cancelled}
        case IntMap.lookup occurrence pool.cancelled of
          Just prior
            | prior /= instruction -> conflict occurrence
            | otherwise -> pure Acknowledged
          Nothing -> case IntMap.lookup occurrence pool.pendingWork of
            Just (_, inv)
              | inv /= instruction.invocation -> conflict occurrence
              | otherwise -> do
                  writeIORef ref fence {pendingWork = IntMap.delete occurrence pool.pendingWork}
                  pure Retired
            Nothing -> do
              writeIORef ref fence
              pure $
                if any ((== occurrence) . fst) pool.completed
                  then Terminal
                  else Tombstoned
    }
  where
    conflict occurrence = dispatchError ("cancellation conflict for occurrence " <> T.pack (show occurrence))
