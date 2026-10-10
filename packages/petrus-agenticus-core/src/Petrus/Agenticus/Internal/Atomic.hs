{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | A compare-and-swap update for the Hands shared state.
--
-- 'Data.IORef.atomicModifyIORef'' swaps in an unevaluated thunk and forces it
-- only after the swap, so under contention the other capabilities read that
-- thunk and block on its blackhole while the winner evaluates it; with eight
-- callers that serialises every call through cross-capability wake-ups.
-- Here the new state is evaluated to weak head normal form first and
-- installed only if the state is unchanged (pointer equality), retrying
-- otherwise, so a reader never meets a thunk under evaluation.
module Petrus.Agenticus.Internal.Atomic
  ( modifyStrict
  )
where

import GHC.Exts (casMutVar#, readMutVar#)
import GHC.IO (IO (..))
import GHC.IORef (IORef (..))
import GHC.STRef (STRef (..))

-- | Atomically replace the state with the first component of the function's
-- result (evaluated before it is published) and return the second.
modifyStrict :: IORef a -> (a -> (a, b)) -> IO b
modifyStrict (IORef (STRef var)) f = IO loop
  where
    loop s0 = case readMutVar# var s0 of
      (# s1, old #) -> case f old of
        (!new, result) -> case casMutVar# var old new s1 of
          (# s2, 0#, _ #) -> (# s2, result #)
          (# s2, _, _ #) -> loop s2
{-# INLINE modifyStrict #-}
