-- | WebSocket framing for the relays (RFC 6455, server side), with the
-- checks and close codes of the @ws@ library's @Receiver@ (8.x), which is
-- what the Node relays run on: client frames must be masked, RSV bits must
-- be clear (no extension is negotiated), control frames must be final and
-- at most 125 bytes, a message may not exceed the size limit (1009), and
-- unknown or out-of-place opcodes are protocol errors (1002).
module Petrus.Viewer.Relay.Frame
  ( Header (..)
  , HeaderResult (..)
  , parseHeader
  , unmaskInto
  , unmaskedCopy
  , encodeFrame
  , frameHeader
  , validCloseCode
  , closePayload
  , opContinuation
  , opText
  , opBinary
  , opClose
  , opPing
  , opPong
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.Word (Word16, Word8)
import Foreign.C.Types (CLong (..))
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (pokeByteOff)
import System.IO.Unsafe (unsafeDupablePerformIO)

opContinuation, opText, opBinary, opClose, opPing, opPong :: Word8
opContinuation = 0
opText = 1
opBinary = 2
opClose = 8
opPing = 9
opPong = 10

-- | A parsed frame header (the payload follows it).
data Header = Header
  { hFin :: Bool
  , hOpcode :: Word8
  , hLength :: Int
  -- ^ payload length
  , hKeyOffset :: Int
  -- ^ where the 4-byte masking key starts
  , hSize :: Int
  -- ^ header size, masking key included
  }
  deriving stock (Eq, Show)

data HeaderResult
  = NeedMore
  | -- | close the connection with this code (what @ws@ sends)
    Refuse Word16
  | Parsed Header
  deriving stock (Eq, Show)

-- | Parse the frame header at the start of the input, given whether a
-- fragmented message is in progress, the payload bytes of that message so
-- far, and the message size limit. Checks run in @ws@'s order, each as
-- soon as the bytes it needs are there.
parseHeader :: Bool -> Int -> Int -> ByteString -> HeaderResult
parseHeader fragmented soFar limit buf
  | n < 2 = NeedMore
  | b0 .&. 0x30 /= 0 = Refuse 1002 -- RSV2 and RSV3 must be clear
  | b0 .&. 0x40 /= 0 = Refuse 1002 -- RSV1 must be clear
  | op == opContinuation && not fragmented = Refuse 1002
  | (op == opText || op == opBinary) && fragmented = Refuse 1002
  | op >= 8 && op <= 10 && not fin = Refuse 1002
  | op >= 8 && op <= 10 && (len7 > 125 || (op == opClose && len7 == 1)) = Refuse 1002
  | op > 2 && (op < 8 || op > 10) = Refuse 1002
  | b1 .&. 0x80 == 0 = Refuse 1002 -- MASK must be set
  | len7 == 126 =
      if n < 4 then NeedMore else withLength (be 2 2) 4
  | len7 == 127 =
      if n < 10
        then NeedMore
        else
          let hi = be 2 4
           in if hi > 2 ^ (21 :: Int) - 1 then Refuse 1009 else withLength (hi * 2 ^ (32 :: Int) + be 6 4) 10
  | otherwise = withLength len7 2
  where
    n = B.length buf
    b0 = BU.unsafeIndex buf 0
    b1 = BU.unsafeIndex buf 1
    fin = b0 .&. 0x80 /= 0
    op = b0 .&. 0x0f
    len7 = fromIntegral (b1 .&. 0x7f) :: Int
    be :: Int -> Int -> Int
    be off k = B.foldl' (\acc w -> acc `shiftL` 8 .|. fromIntegral w) 0 (BU.unsafeTake k (BU.unsafeDrop off buf))
    withLength len off
      | op < 8 && len > 0 && soFar + len > limit = Refuse 1009
      | otherwise = Parsed (Header fin op len off (off + 4))

foreign import ccall unsafe "prelay_unmask"
  c_unmask :: Ptr Word8 -> Ptr Word8 -> CLong -> Ptr Word8 -> CLong -> IO ()

-- | Unmask @len@ bytes at @src@ into @dst@ (which may be @src@).
unmaskInto :: Ptr Word8 -> Ptr Word8 -> Int -> Ptr Word8 -> IO ()
unmaskInto dst src len key = c_unmask dst src (fromIntegral len) key 0

-- | The unmasked payload of a complete frame at the start of the buffer.
unmaskedCopy :: Header -> ByteString -> ByteString
unmaskedCopy h buf =
  let BI.BS fp _ = buf
   in unsafeDupablePerformIO . withForeignPtr fp $ \p ->
        BI.create (hLength h) $ \dst ->
          unmaskInto dst (p `plusPtr` hSize h) (hLength h) (p `plusPtr` hKeyOffset h)

-- | The header of an unmasked, final server frame.
frameHeader :: Word8 -> Int -> ByteString
frameHeader op len
  | len < 126 = BI.unsafeCreate 2 $ \p -> pokeByteOff p 0 b0 >> pokeByteOff p 1 (fromIntegral len :: Word8)
  | len < 65536 = BI.unsafeCreate 4 $ \p -> do
      pokeByteOff p 0 b0
      pokeByteOff p 1 (126 :: Word8)
      pokeByteOff p 2 (fromIntegral (len `shiftR` 8) :: Word8)
      pokeByteOff p 3 (fromIntegral len :: Word8)
  | otherwise = BI.unsafeCreate 10 $ \p -> do
      pokeByteOff p 0 b0
      pokeByteOff p 1 (127 :: Word8)
      mapM_ (\i -> pokeByteOff p (2 + i) (fromIntegral (len `shiftR` (8 * (7 - i))) :: Word8)) [0 .. 7]
  where
    b0 = 0x80 .|. op

-- | A whole server frame as its header and payload.
encodeFrame :: Word8 -> ByteString -> [ByteString]
encodeFrame op payload = [frameHeader op (B.length payload), payload]

-- | Close codes a peer may send (@ws@'s @isValidStatusCode@).
validCloseCode :: Int -> Bool
validCloseCode c = (c >= 1000 && c <= 1014 && c /= 1004 && c /= 1005 && c /= 1006) || (c >= 3000 && c <= 4999)

-- | The payload of a close frame with a code and no reason.
closePayload :: Word16 -> ByteString
closePayload c = B.pack [fromIntegral (c `shiftR` 8), fromIntegral c]
