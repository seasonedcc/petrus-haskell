-- | Host-supplied key operations for opaque Agent Connection state
-- (@petrus.agenticus.connection.key@).
--
-- Agenticus never holds key material: the host hands it a 'KeyOperations'
-- record that seals, opens, and cryptographically erases state.  Plaintext
-- crosses the boundary only as 'ScrubbedBytes', which 'eraseBuffer' zeroes in
-- place (the role upstream's @bytearray@ plays).
module Petrus.Agenticus.Connection.Key
  ( -- * Context
    KeyContext (connectionId, authorityEpoch, stateVersion)
  , mkKeyContext
  , authenticatedData
    -- * Erasure evidence
  , KeyErasureEvidence (connectionId, erased)
  , mkKeyErasureEvidence
    -- * The host boundary
  , KeyOperations (..)
  , keyOperationError
    -- * Erasable buffers
  , ScrubbedBytes
  , eraseBuffer
  ) where

import Data.ByteArray (ScrubbedBytes)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Foreign.Marshal.Utils (fillBytes)
import Petrus.Agenticus.Error

-- | Nonsecret authenticated context for one encrypted state version.
data KeyContext = KeyContext
  { connectionId :: Text
  , authorityEpoch :: Integer
  , stateVersion :: Integer
  }
  deriving stock (Eq, Ord, Show)

mkKeyContext :: Text -> Integer -> Integer -> Either AgenticusError KeyContext
mkKeyContext connectionId authorityEpoch stateVersion
  | T.null connectionId = Left (valueError "key context connection identity must not be empty")
  | authorityEpoch <= 0 = Left (valueError "key context authority epoch must be a positive integer")
  | stateVersion <= 0 = Left (valueError "key context state version must be a positive integer")
  | otherwise = Right KeyContext {connectionId, authorityEpoch, stateVersion}

-- | @petrus-agenticus-connection/v1\\0{connection}\\0{epoch}\\0{version}@,
-- UTF-8 encoded.
authenticatedData :: KeyContext -> ByteString
authenticatedData context =
  TE.encodeUtf8 $
    T.intercalate
      "\0"
      [ "petrus-agenticus-connection/v1"
      , context.connectionId
      , T.pack (show context.authorityEpoch)
      , T.pack (show context.stateVersion)
      ]

-- | Secret-free host evidence that a connection's decrypting key was erased.
data KeyErasureEvidence = KeyErasureEvidence
  { connectionId :: Text
  , erased :: Bool
  }
  deriving stock (Eq, Show)

mkKeyErasureEvidence :: Text -> Bool -> Either AgenticusError KeyErasureEvidence
mkKeyErasureEvidence connectionId erased
  | T.null connectionId = Left (valueError "key erasure connection identity must not be empty")
  | not erased = Left (valueError "key erasure evidence must affirm completed erasure")
  | otherwise = Right KeyErasureEvidence {connectionId, erased}

-- | The pluggable host boundary that never hands key material to Agenticus.
data KeyOperations = KeyOperations
  { seal :: KeyContext -> ScrubbedBytes -> IO ByteString
  -- ^ Encrypt and authenticate one opaque state buffer.
  , open :: KeyContext -> ByteString -> IO ScrubbedBytes
  -- ^ Return one erasable plaintext buffer after integrity verification.
  , erase :: Text -> IO KeyErasureEvidence
  -- ^ Cryptographically erase authority for every retained ciphertext.
  }

-- | A host key operation failed without exposing key or plaintext material.
keyOperationError :: Text -> AgenticusError
keyOperationError = AgenticusError KeyOperationError

-- | Zero a plaintext buffer in place (upstream's @_erase_buffer@).  Every
-- holder of the buffer observes the zeroes afterwards.
eraseBuffer :: ScrubbedBytes -> IO ()
eraseBuffer buffer = BA.withByteArray buffer $ \pointer -> fillBytes pointer 0 (BA.length buffer)
