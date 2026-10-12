{-# LANGUAGE MultiWayIf #-}

-- | The byte streams @tarfile.open(mode="r:*")@ reads an archive through:
-- the bytes themselves, or what CPython's @gzip@, @bz2@, @lzma@ and
-- @compression.zstd@ file objects decompress from them.
--
-- A stream is produced lazily, chunk by chunk, so reading the members of
-- a compressed archive holds its headers, never its decompressed data
-- (as @tarfile@, which reads and seeks through the decompressing file
-- object). A 'Source' can be read again from the start, which is how
-- @tarfile@ seeks backwards in a compressed file.
module Petrus.Motus.Execution.Archive.Stream
  ( -- * Streams
    Chunks (..)
  , Ending (..)
  , Source (..)
  , restart
  , seekChunks
  , collect
  , compressedFileEnded
    -- * Sources
  , plainSource
  , chunkedSource
  , gzipSource
  , bzip2Source
  , xzSource
  , zstdSource
    -- * Refused at once
  , bzip2Refuses
  , lzmaRefuses
  , zstdRefuses
  ) where

import Codec.Compression.Lzma qualified as LZ
import Codec.Compression.Zlib.Internal qualified as Z
import Codec.Compression.Zstd.FFI qualified as ZS
import Control.Monad.ST.Lazy (ST, runST)
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek, poke)
import System.IO.Unsafe (unsafeInterleaveIO, unsafePerformIO)

-- | Decompressed bytes, then how the stream ended.
data Chunks = Chunk !ByteString ~Chunks | Done !Ending

-- | How a stream ended, as the file object reading it reports it.
data Ending
  = -- | Cleanly: reads past the end return no bytes.
    Clean
  | -- | The compressed input ended inside a stream: a read past the bytes
    -- produced raises CPython's @EOFError@.
    Truncated
  | -- | The decompressor refused the data of the first stream
    -- (@OSError@, @LZMAError@, @ZstdError@). CPython raises it from the
    -- @decompress@ call that reaches it, which can be ahead of the bytes
    -- a read asked for.
    Corrupt
  | -- | The decompressor refused the data of a later stream after it had
    -- produced some bytes; CPython raises it from a read that needs them.
    CorruptLater
  deriving stock (Eq, Show)

-- | An archive's bytes and how to read them. 'restart' decodes them from
-- the start each time it is called.
data Source = Source
  { decode :: ByteString -> Chunks
  , input :: ByteString
  , sliced :: Bool
  -- ^ Whether the stream's chunks are slices of 'input', so slices of
  -- them keep nothing alive that the caller does not already hold.
  }

-- | The stream from its first byte.
restart :: Source -> Chunks
restart source = decode source (input source)

-- | An uncompressed archive: its bytes, in one chunk.
plainSource :: ByteString -> Source
plainSource bytes = Source {decode = one, input = bytes, sliced = True}
  where
    one b = if B.null b then Done Clean else Chunk b (Done Clean)

-- | An uncompressed archive in chunks of the given size, to exercise
-- reads that cross chunk boundaries.
chunkedSource :: Int -> ByteString -> Source
chunkedSource size bytes = Source {decode = pieces, input = bytes, sliced = False}
  where
    pieces b
      | B.null b = Done Clean
      | otherwise = let (piece, rest) = B.splitAt (max 1 size) b in Chunk piece (pieces rest)

-- | @gzip.GzipFile@. Bad data ends the stream cleanly after the bytes
-- produced before it (DIVERGENCES.md).
gzipSource :: ByteString -> Source
gzipSource bytes = Source {decode = gunzip, input = bytes, sliced = False}
  where
    gunzip compressed =
      Z.foldDecompressStreamWithInput
        Chunk
        (const (Done Clean))
        ( \case
            Z.TruncatedInput -> Done Truncated
            _ -> Done Clean
        )
        (Z.decompressST Z.gzipFormat Z.defaultDecompressParams)
        (BL.fromStrict compressed)

-- | @bz2.BZ2File@.
bzip2Source :: ByteString -> Source
bzip2Source bytes = Source {decode = streams bunzip, input = bytes, sliced = False}

-- | @lzma.LZMAFile@ with @FORMAT_AUTO@: @.xz@ or @.lzma@ streams.
xzSource :: ByteString -> Source
xzSource bytes = Source {decode = streams unxz, input = bytes, sliced = False}

-- | @compression.zstd.ZstdFile@.
zstdSource :: ByteString -> Source
zstdSource bytes = Source {decode = streams unzstd, input = bytes, sliced = False}

-- ---------------------------------------------------------------------------
-- Refused at once

-- Bytes a decoder refuses before producing anything, which the opening
-- reports as "not a ... file" whether the refusal is bad data or input
-- that ends too soon. Telling them by their first bytes spares setting a
-- decoder up for every uncompressed archive @r:*@ opens.

-- | Not @BZh@ and a block-size digit, the stream header libbz2 checks
-- first.
bzip2Refuses :: ByteString -> Bool
bzip2Refuses bytes =
  not ("BZh" `B.isPrefixOf` bytes && B.length bytes > 3 && B.index bytes 3 >= 0x31 && B.index bytes 3 <= 0x39)

-- | Not a Zstandard frame or skippable frame magic number.
zstdRefuses :: ByteString -> Bool
zstdRefuses bytes =
  not
    ( "\x28\xb5\x2f\xfd" `B.isPrefixOf` bytes
        || (B.length bytes >= 4 && B.index bytes 0 .&. 0xf0 == 0x50 && B.take 3 (B.drop 1 bytes) == "\x2a\x4d\x18")
    )

-- | A @.lzma@ header liblzma's auto decoder refuses: not an @.xz@ (0xFD)
-- or lzip (@L@) start, and properties, dictionary size or uncompressed
-- size its picky @.lzma@ decoder rejects, in the order it reads them.
lzmaRefuses :: ByteString -> Bool
lzmaRefuses bytes
  | B.null bytes = False
  | first == 0xfd || first == 0x4c = False
  | props > 224 || lc + lp > 4 = True
  | B.length bytes < 5 = False
  | not dictionaryOk = True
  | B.length bytes < 13 = False
  | otherwise = size /= maxBound && size >= 2 ^ (38 :: Int)
  where
    first = B.index bytes 0
    props = fromIntegral first :: Int
    lc = props `mod` 9
    lp = (props `div` 9) `mod` 5
    littleEndian from count =
      foldr (\i acc -> acc * 256 + fromIntegral (B.index bytes (from + i))) 0 [0 .. count - 1] :: Integer
    dictionary = fromIntegral (littleEndian 1 4) :: Word32
    dictionaryOk =
      dictionary == maxBound
        || let d0 = dictionary - 1
               d1 = d0 .|. (d0 `shiftR` 2)
               d2 = d1 .|. (d1 `shiftR` 3)
               d3 = d2 .|. (d2 `shiftR` 4)
               d4 = d3 .|. (d3 `shiftR` 8)
               d5 = d4 .|. (d4 `shiftR` 16)
            in d5 + 1 == dictionary
    size = fromIntegral (littleEndian 5 8) :: Word64

-- ---------------------------------------------------------------------------
-- Reading

-- | The stream from the chunk holding @pos@: forward from the current
-- chunk, or from the start for a backward seek (a compressed file object
-- seeks backwards by decompressing again).
seekChunks :: Source -> Chunks -> Integer -> Integer -> (Chunks, Integer)
seekChunks source chunks at pos
  | pos < at = forward (restart source) 0
  | otherwise = forward chunks at
  where
    forward (Chunk bytes rest) start
      | pos >= start + len = forward rest (start + len)
      where
        len = fromIntegral (B.length bytes)
    forward other start = (other, start)

-- | Up to @n@ bytes from @offset@ into the stream, and how the stream
-- ended if it ended first.
collect :: Chunks -> Integer -> Integer -> ([ByteString], Maybe Ending)
collect _ _ n | n <= 0 = ([], Nothing)
collect (Done ending) _ _ = ([], Just ending)
collect (Chunk bytes rest) offset n =
  let available = fromIntegral (B.length bytes) - offset
      taken = min n available
      piece = B.take (fromIntegral taken) (B.drop (fromIntegral offset) bytes)
      (more, ending) = collect rest 0 (n - taken)
   in if taken <= 0 then collect rest (offset - fromIntegral (B.length bytes)) n else (piece : more, ending)

-- | The @EOFError@ CPython's decompressing file objects raise for a read
-- past the bytes a truncated stream produced.
compressedFileEnded :: String
compressedFileEnded = "Compressed file ended before the end-of-stream marker was reached"

-- ---------------------------------------------------------------------------
-- One compressed stream

-- | One decompressor's run over the rest of the input.
data Run
  = Out !ByteString ~Run
  | -- | The stream ended; the input it did not use.
    Ended ByteString
  | -- | The decompressor failed: after the end of its input ('Truncated'),
    -- or on the data ('Corrupt').
    Broke !Ending

-- | @DecompressReader@: streams back to back. After a stream ends, the
-- rest of the input starts the next one; a next stream that fails before
-- producing anything is trailing data, ignored, unless it was only cut
-- short (CPython's first @decompress@ call on it raises for bad data but
-- not for missing data, which raises @EOFError@ on the next read).
streams :: (ByteString -> Run) -> ByteString -> Chunks
streams run = firstStream . run
  where
    firstStream = \case
      Out bytes rest -> Chunk bytes (firstStream rest)
      Ended rest -> next rest
      Broke ending -> Done ending
    next rest
      | B.null rest = Done Clean
      | otherwise = later False (run rest)
    later produced = \case
      Out bytes rest -> Chunk bytes (later True rest)
      Ended rest -> next rest
      Broke Corrupt
        | produced -> Done CorruptLater
        | otherwise -> Done Clean
      Broke ending -> Done ending

data BzStream

foreign import ccall unsafe "petrus_bz2_open"
  c_bz2Open :: IO (Ptr BzStream)

foreign import ccall unsafe "&petrus_bz2_close"
  p_bz2Close :: FunPtr (Ptr BzStream -> IO ())

foreign import ccall unsafe "petrus_bz2_step"
  c_bz2Step :: Ptr BzStream -> Ptr Word8 -> CUInt -> Ptr Word8 -> CUInt -> Ptr CUInt -> Ptr CUInt -> IO CInt

-- | One bzip2 stream (@BZ2Decompressor@), over libbz2 directly: the
-- bzlib package's decoder drops the bytes in its partly filled output
-- buffer when the input ends early, and @BZ2File@ returns them.
bunzip :: ByteString -> Run
{-# NOINLINE bunzip #-}
bunzip compressed = unsafePerformIO $ do
  stream <- c_bz2Open
  if stream == nullPtr
    then pure (Broke Corrupt)
    else newForeignPtr p_bz2Close stream >>= \context -> step context 0
  where
    total = B.length compressed
    outSize = 65536 :: Int
    step :: ForeignPtr BzStream -> Int -> IO Run
    step context consumed = do
      out <- BI.mallocByteString outSize
      (result, used, produced) <-
        withForeignPtr context $ \stream ->
          BU.unsafeUseAsCString compressed $ \source ->
            withForeignPtr out $ \target ->
              alloca $ \usedPtr -> alloca $ \producedPtr -> do
                result <-
                  c_bz2Step
                    stream
                    (castPtr source `plusPtr` consumed)
                    (fromIntegral (total - consumed))
                    target
                    (fromIntegral outSize)
                    usedPtr
                    producedPtr
                used <- peek usedPtr
                produced <- peek producedPtr
                pure (result, fromIntegral used, fromIntegral produced)
      let consumed' = consumed + used
          bytes
            | produced == outSize = BI.BS out produced
            | otherwise = B.copy (BI.BS out produced)
          emit rest
            | produced > 0 = Out bytes <$> unsafeInterleaveIO rest
            | otherwise = rest
      if
        | result < 0 -> pure (Broke Corrupt)
        | result == bzStreamEnd -> emit (pure (Ended (B.drop consumed' compressed)))
        | produced == outSize -> emit (step context consumed')
        | consumed' >= total -> emit (pure (Broke Truncated))
        | used == 0 && produced == 0 -> pure (Broke Corrupt)
        | otherwise -> emit (step context consumed')
    bzStreamEnd = 4

-- | One @.xz@ or @.lzma@ stream through liblzma's auto decoder, as
-- @LZMADecompressor(FORMAT_AUTO)@ opens it (one stream; no memory limit).
unxz :: ByteString -> Run
unxz compressed = runST (LZ.decompressST params >>= \s -> go s Nothing)
  where
    params =
      LZ.defaultDecompressParams
        { LZ.decompressAutoDecoder = True
        , LZ.decompressConcatenated = False
        }
    -- Whether the whole input and then its end were supplied.
    go :: LZ.DecompressStream (ST s) -> Maybe Bool -> ST s Run
    go step supplied = case step of
      LZ.DecompressInputRequired supply -> case supplied of
        Nothing | not (B.null compressed) -> supply compressed >>= \s -> go s (Just False)
        _ -> supply B.empty >>= \s -> go s (Just True)
      LZ.DecompressOutputAvailable bytes nextStep -> Out bytes <$> (nextStep >>= \s -> go s supplied)
      LZ.DecompressStreamEnd rest -> pure (Ended rest)
      LZ.DecompressStreamError _
        | supplied == Just True -> pure (Broke Truncated)
        | otherwise -> pure (Broke Corrupt)

-- | One Zstandard frame (@ZstdDecompressor@ stops at the end of a frame).
unzstd :: ByteString -> Run
{-# NOINLINE unzstd #-}
unzstd compressed = unsafePerformIO $ do
  stream <- ZS.createDStream
  if stream == nullPtr
    then pure (Broke Corrupt)
    else do
      context <- newForeignPtr ZS.p_freeDStream stream
      initialized <- ZS.initDStream stream
      if ZS.isError initialized then pure (Broke Corrupt) else step context 0
  where
    total = B.length compressed
    outSize = fromIntegral ZS.dstreamOutSize :: Int
    step :: ForeignPtr ZS.DStream -> Int -> IO Run
    step context consumed = do
      out <- BI.mallocByteString outSize
      (result, used, produced) <-
        withForeignPtr context $ \stream ->
          BU.unsafeUseAsCString compressed $ \source ->
            withForeignPtr out $ \target ->
              alloca $ \inBuffer -> alloca $ \outBuffer -> do
                poke inBuffer (ZS.Buffer (source `plusPtr` consumed) (fromIntegral (total - consumed)) 0)
                poke outBuffer (ZS.Buffer target (fromIntegral outSize) 0)
                result <- ZS.decompressStream stream outBuffer inBuffer
                used <- ZS.bufPos <$> peek inBuffer
                produced <- ZS.bufPos <$> peek outBuffer
                pure (result, fromIntegral used, fromIntegral produced)
      let consumed' = consumed + used
          bytes
            | produced == outSize = BI.BS out produced
            | otherwise = B.copy (BI.BS out produced)
          emit rest
            | produced > 0 = Out bytes <$> unsafeInterleaveIO rest
            | otherwise = rest
      if
        | ZS.isError result -> pure (Broke Corrupt)
        | result == 0 -> emit (pure (Ended (B.drop consumed' compressed)))
        | produced == outSize -> emit (step context consumed')
        | consumed' >= total -> emit (pure (Broke Truncated))
        | used == 0 && produced == 0 -> pure (Broke Corrupt)
        | otherwise -> emit (step context consumed')
