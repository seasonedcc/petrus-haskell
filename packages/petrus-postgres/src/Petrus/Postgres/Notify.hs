-- | LISTEN/NOTIFY doorbells and upstream's poll cadence.
--
-- Upstream treats NOTIFY as a lossy wake-up hint and never as the
-- guarantee: a waiter re-probes durable state on every wake-up and at
-- least every 'defaultPollInterval' (0.25 s) regardless ('pollWithDoorbell',
-- the shape of Absurd Dispatch's @wait_for_results@). A listening
-- connection must be in autocommit mode, or have committed its @LISTEN@:
-- PostgreSQL delivers notifications between transactions, and a
-- notification sent inside a transaction is delivered only when that
-- transaction commits (never after a rollback).
module Petrus.Postgres.Notify
  ( -- * Notifications
    Notification (..)
  , listen
  , notify
  , waitForNotification
  , pendingNotifications

    -- * Polling
  , defaultPollInterval
  , pollWithDoorbell

    -- * Upstream channels
  , dispatchChannel
  , resultsChannel
  , fabricDeliveryChannel
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Exception (throwIO)
import Data.Text (Text)
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTime)
import Petrus.Postgres.Connection (Connection, execute_)
import Petrus.Postgres.Internal (connectionFailure, decodeLenient, waitReadableFor, withLockedConnection)
import Petrus.Postgres.Param (sql, textParam)

-- | psycopg's @Notify@.
data Notification = Notification
  { notificationChannel :: Text
  , notificationPayload :: Text
  , notificationPid :: Int
  -- ^ The notifying server process ('Petrus.Postgres.Connection.backendPid'
  -- of the sender).
  }
  deriving stock (Eq, Show)

-- | Absurd Dispatch's work doorbell (@DISPATCH_CHANNEL@).
dispatchChannel :: Text
dispatchChannel = "impetus_dispatch"

-- | Absurd Dispatch's results doorbell (@RESULTS_CHANNEL@).
resultsChannel :: Text
resultsChannel = "impetus_results"

-- | The PostgreSQL Fabric's delivery doorbell.
fabricDeliveryChannel :: Text
fabricDeliveryChannel = "impetus_fabric_delivery"

-- | Upstream's @poll_interval@ default: 0.25 seconds.
defaultPollInterval :: Double
defaultPollInterval = 0.25

-- | @connection.execute(f"LISTEN {channel}")@: the channel is spliced in
-- unquoted, as upstream spells it. On a join-mode connection the
-- subscription takes effect when the transaction commits.
listen :: Connection -> Text -> IO ()
listen connection channel = execute_ connection (sql ("LISTEN " <> channel)) []

-- | @connection.execute("SELECT pg_notify(%s, %s)", (channel, payload))@.
-- Delivered when the surrounding transaction commits.
notify :: Connection -> Text -> Text -> IO ()
notify connection channel payload =
  execute_ connection "SELECT pg_notify(%s, %s)" [textParam channel, textParam payload]

-- | Wait up to the given number of seconds for one notification — upstream's
-- @for _ in connection.notifies(timeout=t, stop_after=1)@. Notifications
-- that arrived earlier (including while other statements ran) are returned
-- first, one per call, and none is dropped. A timeout of zero or less
-- still checks once.
waitForNotification :: Connection -> Double -> IO (Maybe Notification)
waitForNotification connection seconds = withLockedConnection connection $ \raw -> do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        consume raw
        PQ.notifies raw >>= \case
          Just n -> pure (Just (fromPQ n))
          Nothing -> do
            now <- getMonotonicTime
            let remaining = deadline - now
            if remaining <= 0
              then pure Nothing
              else do
                _ <- waitReadableFor raw (Just remaining)
                loop
  PQ.notifies raw >>= maybe loop (pure . Just . fromPQ)

-- | Every notification already received, without waiting.
pendingNotifications :: Connection -> IO [Notification]
pendingNotifications connection = withLockedConnection connection $ \raw -> do
  -- libpq reads one packet per PQconsumeInput (the socket is non-blocking),
  -- so read until a round yields nothing new.
  let collect acc =
        PQ.notifies raw >>= \case
          Just n -> collect (fromPQ n : acc)
          Nothing -> pure acc
      rounds acc = do
        consume raw
        acc' <- collect acc
        if length acc' == length acc then pure (reverse acc') else rounds acc'
  rounds []

consume :: PQ.Connection -> IO ()
consume raw = do
  consumed <- PQ.consumeInput raw
  unless consumed (connectionFailure raw "consuming input failed: " >>= throwIO)

fromPQ :: PQ.Notify -> Notification
fromPQ n =
  Notification
    { notificationChannel = decodeLenient (PQ.notifyRelname n)
    , notificationPayload = decodeLenient (PQ.notifyExtra n)
    , notificationPid = fromIntegral (PQ.notifyBePid n)
    }

-- | Absurd Dispatch's @wait_for_results@ loop: run the probe; if it
-- reports readiness return 'True'; if the timeout has elapsed return
-- 'False'; otherwise wait @min pollInterval remaining@ seconds — for a
-- notification on the listening connection when one is given (any
-- notification wakes the loop, which re-probes), or by sleeping — and
-- repeat. The caller issues the @LISTEN@ beforehand.
pollWithDoorbell :: Double -> Maybe Connection -> Double -> IO Bool -> IO Bool
pollWithDoorbell pollInterval listening seconds probe = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        ready <- probe
        if ready
          then pure True
          else do
            remaining <- (deadline -) <$> getMonotonicTime
            if remaining <= 0
              then pure False
              else do
                let interval = min pollInterval remaining
                case listening of
                  Just connection -> () <$ waitForNotification connection interval
                  Nothing -> threadDelay (ceiling (interval * 1e6))
                loop
  loop
