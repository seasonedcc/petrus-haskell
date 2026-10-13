-- | Timestamps and timing values formatted the way the Node code prints
-- them (@new Date().toISOString()@, @+(ms).toFixed(1)@).
module Petrus.Viewer.Log
  ( isoTimestamp
  , monotonicMs
  , fixed1
  , Logger
  , newAsyncLogger
  , newConsoleLogger
  , newStdoutLogger
  , logLine
  ) where

import Control.Concurrent (forkOn, yield)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forever, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.ByteString.Internal qualified as BI
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Storable (pokeByteOff)
import GHC.Clock (getMonotonicTimeNSec)
import Petrus.Posix.File qualified as Posix
import System.IO (Handle, hFlush, stdout)
import System.Posix.Files (getFdStatus, isCharacterDevice, isRegularFile)
import System.Posix.Types (Fd (..))

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
  pure . BI.unsafeCreate 24 $ \ptr -> do
    let digits :: Int -> Int -> Int -> IO ()
        digits off n = go (off + n - 1) n
          where
            go :: Int -> Int -> Int -> IO ()
            go _ 0 _ = pure ()
            go i k v = pokeByteOff ptr i (fromIntegral (48 + v `mod` 10) :: Word8) >> go (i - 1) (k - 1) (v `div` 10)
        sep :: Int -> Char -> IO ()
        sep off ch = pokeByteOff ptr off (fromIntegral (fromEnum ch) :: Word8)
    digits 0 4 (fromIntegral y)
    sep 4 '-'
    digits 5 2 mo
    sep 7 '-'
    digits 8 2 d
    sep 10 'T'
    digits 11 2 h
    sep 13 ':'
    digits 14 2 mi
    sep 16 ':'
    digits 17 2 sec
    sep 19 '.'
    digits 20 3 ms
    sep 23 'Z'

-- | @performance.now()@-style monotonic milliseconds.
monotonicMs :: IO Double
monotonicMs = (\ns -> fromIntegral ns / 1e6) <$> getMonotonicTimeNSec

-- | @+(x).toFixed(1)@ (round half away from zero on the decimal value).
fixed1 :: Double -> Double
fixed1 x = fromIntegral (round (x * 10) :: Integer) / 10

-- | A line logger safe to share between threads.
data Logger
  = -- | lines are written by a background thread, batched
    AsyncLogger (TQueue ByteString)
  | -- | each line is one @write@ to the descriptor, from the logging thread
    DirectLogger CInt (MVar ())

-- | 'logLine' only enqueues; a background thread writes whatever has
-- accumulated in one call and flushes. Lines keep their order. For hot
-- paths (the relay logs every request and response), where a write and
-- flush per line under a lock would serialize the server. The writer runs
-- on the given capability (that of the threads that log the most).
newAsyncLogger :: Int -> Handle -> IO Logger
newAsyncLogger cap h = do
  q <- newTQueueIO
  void . forkOn cap . forever $ do
    -- let the threads that woke us (and are doing the real work) go first
    yield
    ls <- atomically $ do
      x <- readTQueue q
      xs <- flushTQueue q
      pure (x : xs)
    -- a closed or broken stream drops lines instead of killing the logger
    void (try @SomeException (B.hPut h (B.concat (concatMap (\l -> [l, "\n"]) ls)) >> hFlush h))
  pure (AsyncLogger q)

-- | A log on a standard stream (@h@, descriptor @fd@), written the way
-- Node's @console.log@ / @console.error@ write it. Node writes
-- synchronously to files and terminals, and asynchronously to pipes
-- (macOS) and sockets: to a file or a character device (a terminal,
-- @/dev/null@) each line is one @write@ from the thread that logs it
-- (petrus-posix's safe 'Petrus.Posix.File.writeAll': a system call and no
-- hand-off to a writer thread; an unsafe call measured 2-6% faster on the
-- logging relay, which stays ahead of Node without it, bench/RESULTS.md,
-- "Low-level code, measured"); to anything else
-- the lines go through 'newAsyncLogger', so a slow reader never stalls the
-- caller.
newConsoleLogger :: Int -> Handle -> CInt -> IO Logger
newConsoleLogger cap h fd = do
  status <- try @SomeException (getFdStatus (fromIntegral fd))
  case status of
    Right st
      | isRegularFile st || isCharacterDevice st -> do
          -- lines already buffered in the Handle go first
          hFlush h
          DirectLogger fd <$> newMVar ()
    _ -> newAsyncLogger cap h

-- | The relay timing log on standard output ('newConsoleLogger'; the
-- relay's loop logs every request and response).
newStdoutLogger :: Int -> IO Logger
newStdoutLogger cap = newConsoleLogger cap stdout 1

logLine :: Logger -> ByteString -> IO ()
logLine (AsyncLogger q) line = atomically (writeTQueue q line)
-- A closed or broken stream drops the line, as the async logger does.
logLine (DirectLogger fd lock) line =
  withMVar lock $ \() -> void (try @IOException (Posix.writeAll (Fd fd) (line <> "\n")))
