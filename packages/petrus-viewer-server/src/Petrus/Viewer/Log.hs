-- | Timestamps and timing values formatted the way the Node code prints
-- them (@new Date().toISOString()@, @+(ms).toFixed(1)@).
module Petrus.Viewer.Log
  ( isoTimestamp
  , monotonicMs
  , fixed1
  , Logger
  , newLogger
  , logLine
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO (Handle, hFlush)

-- | @new Date().toISOString()@: millisecond precision, UTC, @Z@ suffix.
isoTimestamp :: IO ByteString
isoTimestamp = BC.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%03QZ" <$> getCurrentTime

-- | @performance.now()@-style monotonic milliseconds.
monotonicMs :: IO Double
monotonicMs = (\ns -> fromIntegral ns / 1e6) <$> getMonotonicTimeNSec

-- | @+(x).toFixed(1)@ (round half away from zero on the decimal value).
fixed1 :: Double -> Double
fixed1 x = fromIntegral (round (x * 10) :: Integer) / 10

-- | A line logger safe to share between threads.
data Logger = Logger Handle (MVar ())

newLogger :: Handle -> IO Logger
newLogger h = Logger h <$> newMVar ()

logLine :: Logger -> ByteString -> IO ()
logLine (Logger h lock) line = withMVar lock $ \() -> BC.hPutStrLn h line >> hFlush h
