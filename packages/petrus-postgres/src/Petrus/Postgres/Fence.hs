-- | The PostgreSQL authority fence: one session-level advisory lock per
-- net-instance identity, so two writer processes never operate the same
-- history (upstream's private @PostgresAuthorityFence@).
--
-- The lock belongs to the database session: closing or losing the
-- connection releases it, so a live coordinator must treat the
-- connection's failure as terminal. The key is the first eight bytes of
-- @sha256("impetus-authority\\0" <> utf8 instance)@ read as a signed
-- big-endian 64-bit integer, identical to upstream's @_fence_key@, so
-- Haskell and Python writers exclude each other.
module Petrus.Postgres.Fence
  ( -- * Keys
    fenceKey

    -- * The fence
  , AuthorityFence
  , fenceInstance
  , fenceKeyOf
  , acquireAuthorityFence
  , releaseAuthorityFence
  , fenceHeld
  , withAuthorityFence

    -- * Errors
  , FenceError (..)
  , fenceErrorMessage
  ) where

import Control.Exception (Exception (..), bracket, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Repr (pythonReprText)
import Petrus.Postgres.Connection (Connection, PostgresError, execute_, queryFirst)
import Petrus.Postgres.Param (intParam)

-- | Why a fence could not be taken.
data FenceError
  = -- | The instance id was empty (upstream's @ValueError@).
    EmptyFenceInstance
  | -- | Another session holds the lock for this instance (upstream's
    -- @RuntimeError@).
    FenceHeld Text
  deriving stock (Eq, Show)

instance Exception FenceError where
  displayException = T.unpack . fenceErrorMessage

-- | Upstream's exact messages.
fenceErrorMessage :: FenceError -> Text
fenceErrorMessage = \case
  EmptyFenceInstance -> "authority fence requires a non-empty string instance id, got ''"
  FenceHeld instanceId ->
    "authority fence for instance "
      <> T.pack (pythonReprText instanceId)
      <> " is already held: refusing a second canonical writer"

-- | Upstream's @_fence_key@.
fenceKey :: Text -> Either FenceError Int64
fenceKey instanceId
  | T.null instanceId = Left EmptyFenceInstance
  | otherwise = Right (BS.foldl' (\acc w -> acc `shiftL` 8 .|. fromIntegral w) 0 (BS.take 8 digest))
  where
    digest = SHA256.hash ("impetus-authority\0" <> TE.encodeUtf8 instanceId)

-- | A held fence.
data AuthorityFence = AuthorityFence
  { fenceConnection :: Connection
  , fenceInstance :: Text
  -- ^ The instance id the fence guards.
  , fenceKeyOf :: Int64
  -- ^ The advisory-lock key.
  , heldRef :: IORef Bool
  }

-- | @PostgresAuthorityFence(connection, instance)@: @SELECT
-- pg_try_advisory_lock(%s)@ on the given connection, failing with
-- 'FenceHeld' when another session holds it. On a join-mode connection
-- this opens the transaction, as upstream's does; the lock itself is
-- session-level and survives the transaction's end.
acquireAuthorityFence :: Connection -> Text -> IO AuthorityFence
acquireAuthorityFence connection instanceId = do
  key <- either throwIO pure (fenceKey instanceId)
  row <- queryFirst connection "SELECT pg_try_advisory_lock(%s)" [intParam key]
  unless (row == Just [Just "t"]) (throwIO (FenceHeld instanceId))
  held <- newIORef True
  pure AuthorityFence {fenceConnection = connection, fenceInstance = instanceId, fenceKeyOf = key, heldRef = held}

-- | @close()@: @SELECT pg_advisory_unlock(%s)@ once; a database error is
-- ignored (a dead connection already released every session lock).
-- Idempotent.
releaseAuthorityFence :: AuthorityFence -> IO ()
releaseAuthorityFence fence = do
  held <- readIORef (heldRef fence)
  when held $ do
    _ <- try @PostgresError (execute_ (fenceConnection fence) "SELECT pg_advisory_unlock(%s)" [intParam (fenceKeyOf fence)])
    writeIORef (heldRef fence) False

-- | Whether 'releaseAuthorityFence' has not run yet.
fenceHeld :: AuthorityFence -> IO Bool
fenceHeld = readIORef . heldRef

-- | Acquire, run, release.
withAuthorityFence :: Connection -> Text -> (AuthorityFence -> IO a) -> IO a
withAuthorityFence connection instanceId =
  bracket (acquireAuthorityFence connection instanceId) releaseAuthorityFence
