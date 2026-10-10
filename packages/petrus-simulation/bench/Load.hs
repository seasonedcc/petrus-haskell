{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The interleaved load comparison: one Haskell client drives the Haskell
-- server and the upstream Python server with identical requests, so the
-- client's own cost is the same on both sides.
--
-- Every request opens a fresh loopback connection (both servers serve one
-- request per connection), sends the request, half-closes, reads the
-- response to the end, and closes with a reset (@SO_LINGER@ 0) so that no
-- @TIME_WAIT@ sockets pile up. @clients@ threads run at once; concurrency
-- stays at or below both servers' listen backlog of 5 (CPython's
-- @request_queue_size@), past which macOS drops SYNs and the client waits
-- a full retransmission second, which would measure the kernel instead.
--
-- Each repetition runs every scenario on both servers, alternating which
-- goes first, after a warm-up; the report gives the median over
-- repetitions of the throughput and of the per-request p50 and p99
-- latencies, and the load average around each repetition.
module Load
  ( Scenario (..)
  , Target (..)
  , runLoad
  , loadAverage
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (forM, forM_, replicateM, replicateM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Word (Word64)
import Foreign.C.Types (CDouble (..), CInt (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket
  ( Family (..)
  , ShutdownCmd (..)
  , SockAddr (..)
  , SocketOption (..)
  , SocketType (..)
  , StructLinger (..)
  , close
  , connect
  , defaultProtocol
  , setSockOpt
  , socket
  , tupleToHostAddress
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

data Scenario = Scenario
  { name :: String
  , request :: ByteString
  , clients :: Int
  , requests :: Int
  -- ^ Per measurement, split evenly across the clients.
  , expect :: ByteString -> Bool
  -- ^ Every response must satisfy this, so both servers do the same work.
  }

data Target = Target {label :: String, port :: Int}

foreign import ccall unsafe "stdlib.h getloadavg" c_getloadavg :: Ptr CDouble -> CInt -> IO CInt

-- | The 1-minute load average.
loadAverage :: IO Double
loadAverage = allocaArray 3 $ \buffer -> do
  count <- c_getloadavg buffer 3
  values <- peekArray 3 buffer
  pure (if count >= 1 then realToFrac (head' values) else -1)
  where
    head' = \case
      v : _ -> v
      [] -> -1

roundtrip :: Int -> ByteString -> IO ByteString
roundtrip port' bytes =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    setSockOpt sock Linger (StructLinger 1 0)
    connect sock (SockAddrInet (fromIntegral port') (tupleToHostAddress (127, 0, 0, 1)))
    sendAll sock bytes
    Socket.shutdown sock ShutdownSend
    let go chunks = do
          chunk <- recv sock 65536
          if BS.null chunk then pure (BS.concat (reverse chunks)) else go (chunk : chunks)
    go []

data Measurement = Measurement {throughput :: Double, p50 :: Double, p99 :: Double}

measure :: Target -> Scenario -> IO Measurement
measure target scenario = do
  let perClient = scenario.requests `div` scenario.clients
      one = do
        started <- getMonotonicTimeNSec
        reply <- roundtrip target.port scenario.request
        finished <- getMonotonicTimeNSec
        unless (scenario.expect reply) $
          throwIO (userError (target.label <> " " <> scenario.name <> ": unexpected response " <> show (BS.take 200 reply)))
        pure (finished - started)
  -- warm-up
  replicateM_ (min 50 perClient) one
  latencies <- newIORef ([] :: [Word64])
  started <- getMonotonicTimeNSec
  done <- forM [1 .. scenario.clients] $ \_ -> do
    finished <- newEmptyMVar
    _ <- forkIO $ do
      outcome <- try (replicateM perClient one)
      case outcome of
        Right samples -> atomicModifyIORef' latencies (\xs -> (samples ++ xs, ())) >> putMVar finished Nothing
        Left (e :: SomeException) -> putMVar finished (Just e)
    pure finished
  failures <- forM done takeMVar
  finished <- getMonotonicTimeNSec
  forM_ failures (maybe (pure ()) throwIO)
  samples <- sort <$> readIORef latencies
  let total = length samples
      at q = fromIntegral (samples !! min (total - 1) (floor (q * fromIntegral total :: Double))) / 1000
  pure
    Measurement
      { throughput = fromIntegral total / (fromIntegral (finished - started) / 1e9)
      , p50 = at 0.5
      , p99 = at 0.99
      }

median :: [Double] -> Double
median xs = case sort xs of
  [] -> 0
  sorted -> sorted !! (length sorted `div` 2)

-- | Run every scenario @repetitions@ times on the Haskell and the Python
-- target, interleaved, and print a Markdown report.
runLoad :: Int -> Target -> Target -> [Scenario] -> IO ()
runLoad repetitions haskell python scenarios = do
  rounds <- forM [1 .. repetitions] $ \repetition -> do
    before <- loadAverage
    results <- forM scenarios $ \scenario -> do
      let order = if odd repetition then [haskell, python] else [python, haskell]
      measured <- forM order $ \target -> do
        hPutStrLn stderr ("  " <> target.label <> ": " <> scenario.name <> ", " <> show scenario.clients <> " client(s)")
        (,) target.label <$> measure target scenario
      let pick target = maybe (error "missing") id (lookup target.label measured)
      pure (pick haskell, pick python)
    after <- loadAverage
    printf "repetition %d: load average %.2f -> %.2f\n" repetition before after
    pure (before, after, results)
  let loads = concat [[before, after] | (before, after, _) <- rounds]
  printf "\nload average (1 min) over the run: %.2f to %.2f\n\n" (minimum loads) (maximum loads)
  putStrLn "| Scenario | Clients | Haskell req/s | Haskell p50 / p99 | Python req/s | Python p50 / p99 | Haskell / Python |"
  putStrLn "|---|---:|---:|---:|---:|---:|---:|"
  forM_ (zip [0 :: Int ..] scenarios) $ \(index, scenario) -> do
    let ours = [fst (results !! index) | (_, _, results) <- rounds]
        theirs = [snd (results !! index) | (_, _, results) <- rounds]
        summarize ms = (median (map (.throughput) ms), median (map (.p50) ms), median (map (.p99) ms))
        (ht, h50, h99) = summarize ours
        (pt, p50', p99') = summarize theirs
    printf
      "| %s | %d | %.0f | %s / %s | %.0f | %s / %s | %.2f× |\n"
      scenario.name
      scenario.clients
      ht
      (micros h50)
      (micros h99)
      pt
      (micros p50')
      (micros p99')
      (ht / pt)
  when (repetitions < 1) $ putStrLn "(no repetitions)"
  where
    micros :: Double -> String
    micros value
      | value >= 1000 = printf "%.2f ms" (value / 1000)
      | otherwise = printf "%.0f µs" value
