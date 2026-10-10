-- | Timestamps and timing values formatted the way the Node code prints
-- them (@new Date().toISOString()@, @+(ms).toFixed(1)@).
module Petrus.Viewer.Log
  ( isoTimestamp
  , monotonicMs
  , fixed1
  , Logger
  , newLogger
  , newAsyncLogger
  , logLine
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO (Handle, hFlush)

-- | @new Date().toISOString()@: millisecond precision, UTC, @Z@ suffix.
isoTimestamp :: IO ByteString
isoTimestamp = do
  UTCTime day dt <- getCurrentTime
  let (y, mo, d) = toGregorian day
      msOfDay = fromIntegral (diffTimeToPicoseconds dt `div` 1000000000) :: Int
      -- a leap second reads 23:59:60.xxx, like toISOString never does but
      -- formatTime would
      (h, mi, sec, ms)
        | msOfDay >= 86400000 = (23, 59, 60, msOfDay - 86400000)
        | otherwise = (msOfDay `div` 3600000, msOfDay `div` 60000 `mod` 60, msOfDay `div` 1000 `mod` 60, msOfDay `mod` 1000)
      pad n x = let t = show x in replicate (n - length t) '0' ++ t
  pure . BC.pack $
    pad 4 y ++ "-" ++ pad 2 mo ++ "-" ++ pad 2 d ++ "T" ++ pad 2 h ++ ":" ++ pad 2 mi ++ ":" ++ pad 2 sec ++ "." ++ pad 3 ms ++ "Z"

-- | @performance.now()@-style monotonic milliseconds.
monotonicMs :: IO Double
monotonicMs = (\ns -> fromIntegral ns / 1e6) <$> getMonotonicTimeNSec

-- | @+(x).toFixed(1)@ (round half away from zero on the decimal value).
fixed1 :: Double -> Double
fixed1 x = fromIntegral (round (x * 10) :: Integer) / 10

-- | A line logger safe to share between threads.
data Logger
  = SyncLogger Handle (MVar ())
  | -- | lines are written by a background thread, batched
    AsyncLogger (TQueue ByteString)

-- | Each 'logLine' writes and flushes before returning.
newLogger :: Handle -> IO Logger
newLogger h = SyncLogger h <$> newMVar ()

-- | 'logLine' only enqueues; a background thread writes whatever has
-- accumulated in one call and flushes. Lines keep their order. For hot
-- paths (the relay logs every request and response), where a write and
-- flush per line under a lock would serialize the server.
newAsyncLogger :: Handle -> IO Logger
newAsyncLogger h = do
  q <- newTQueueIO
  void . forkIO . forever $ do
    ls <- atomically $ do
      x <- readTQueue q
      xs <- flushTQueue q
      pure (x : xs)
    -- a closed or broken stream drops lines instead of killing the logger
    void (try @SomeException (B.hPut h (B.concat (concatMap (\l -> [l, "\n"]) ls)) >> hFlush h))
  pure (AsyncLogger q)

logLine :: Logger -> ByteString -> IO ()
logLine (SyncLogger h lock) line = withMVar lock $ \() -> BC.hPutStrLn h line >> hFlush h
logLine (AsyncLogger q) line = atomically (writeTQueue q line)
