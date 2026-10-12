{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | Waiting for a descriptor to become readable, as CPython's socket
-- timeouts and psycopg's wait do: in @poll(2)@ on the calling OS thread.
--
-- The callers (the Postgres client and the Gondolin control socket) wait
-- on every round trip. Parking on GHC's IO manager instead costs an event
-- round trip of several microseconds per wake-up, which psycopg and CPython
-- do not pay. The wait is an @interruptible@ foreign call, which an
-- asynchronous exception interrupts. Under the non-threaded runtime, where
-- such a call would stop every Haskell thread, it parks on the IO manager
-- instead (some benchmark executables here are not threaded).
module Petrus.Posix.Poll
  ( waitReadable
  ) where

import Control.Concurrent (rtsSupportsBoundThreads, threadWaitRead)
import Control.Exception (throwIO)
import Data.Maybe (isJust)
import Foreign.C.Error (Errno (..), eINTR, errnoToIOError)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTime)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

foreign import ccall interruptible "petrus_posix.h petrus_wait_readable"
  c_wait_readable :: CInt -> CInt -> IO CInt

-- | Wait until the descriptor is readable ('True'; an error or hang-up
-- counts, for the next read to report) or the given number of seconds
-- elapses ('False'). 'Nothing' waits without limit. A failing @poll@ raises
-- its @OSError@.
--
-- Each @poll@ lasts at most 50 ms, and the wait loops until the deadline.
-- The runtime interrupts a blocked foreign call with one signal, and a
-- signal that arrives just before the thread enters @poll@ is lost; the
-- bound is how late a cancellation can then be, instead of never.
waitReadable :: Fd -> Maybe Double -> IO Bool
waitReadable descriptor limit
  | rtsSupportsBoundThreads = pollReadable descriptor limit
  | otherwise = case limit of
      Nothing -> True <$ threadWaitRead descriptor
      Just seconds -> isJust <$> timeout (max 1 (ceiling (seconds * 1e6))) (threadWaitRead descriptor)

pollReadable :: Fd -> Maybe Double -> IO Bool
pollReadable (Fd fd) limit = do
  deadline <- traverse (\seconds -> (+ seconds) <$> getMonotonicTime) limit
  let loop = do
        slice <- case deadline of
          Nothing -> pure pollBound
          Just end -> do
            now <- getMonotonicTime
            pure (min pollBound (max 0 (ceiling ((end - now) * 1000))))
        rc <- c_wait_readable fd slice
        if
          | rc > 0 -> pure True
          | rc < 0 && Errno (negate rc) /= eINTR -> throwIO (errnoToIOError "poll" (Errno (negate rc)) Nothing Nothing)
          | otherwise -> case deadline of
              Nothing -> loop
              Just end -> do
                now <- getMonotonicTime
                if now >= end then pure False else loop
  loop

-- | The longest single @poll@, in milliseconds.
pollBound :: CInt
pollBound = 50
