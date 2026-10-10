-- | Process resource figures as upstream's telemetry reports them
-- (@petrus.telemetry.max_rss_mb@ and @current_rss_mb@).
--
-- @GHC.Stats@ is not a substitute: it reports the Haskell heap, not the
-- resident set the kernel accounts.
module Petrus.Posix.Resource
  ( maxRss
  , maxRssMb
  , pageSize
  , currentRssMb
  , currentRssMbFrom
  , pythonRound
  , roundTenthsOfPowerOfTwo
  ) where

import Control.Exception (IOException, try)
import Data.Bits (bit, shiftR, (.&.))
import Data.ByteString.Char8 qualified as BC
import Data.Int (Int64)
import Data.Ratio ((%))
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..), CLong (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Info (os)

foreign import ccall unsafe "petrus_posix.h petrus_maxrss" c_maxrss :: Ptr Int64 -> IO CInt

foreign import ccall unsafe "petrus_posix.h petrus_page_size" c_page_size :: IO CLong

-- | @resource.getrusage(resource.RUSAGE_SELF).ru_maxrss@: bytes on Darwin,
-- kibibytes on Linux.
maxRss :: IO Integer
maxRss = alloca $ \out -> do
  throwErrnoIfMinus1_ "getrusage" (c_maxrss out)
  toInteger <$> peek out

-- | @max_rss_mb()@: @round(ru_maxrss / (1024**2 if darwin else 1024), 1)@.
maxRssMb :: IO Double
maxRssMb = do
  rss <- alloca $ \out -> do
    throwErrnoIfMinus1_ "getrusage" (c_maxrss out)
    peek out
  pure (roundTenthsOfPowerOfTwo rss maxRssShift)

-- log2 of the ru_maxrss divisor.
maxRssShift :: Int
maxRssShift = if os == "darwin" then 20 else 10
{-# NOINLINE maxRssShift #-}

-- | @round(n / 2**k, 1)@ for an integer @n@. Below 2^53 the quotient is an
-- exact double, so the half-even rounding is done on integers and the result
-- is one correctly rounded division, exactly what CPython computes.
roundTenthsOfPowerOfTwo :: Int64 -> Int -> Double
roundTenthsOfPowerOfTwo n k
  | n >= 0 && n < 2 ^ (53 :: Int) =
      let scaled = n * 10
          q = scaled `shiftR` k
          r = scaled .&. (bit k - 1)
          half = bit (k - 1)
          tenths
            | r > half || (r == half && odd q) = q + 1
            | otherwise = q
       in fromIntegral tenths / 10
  | otherwise = pythonRound 1 (fromRational (toInteger n % (2 ^ k)))

-- | @os.sysconf("SC_PAGE_SIZE")@.
pageSize :: IO Integer
pageSize = toInteger <$> c_page_size

-- | @current_rss_mb()@: resident pages from @/proc/self/statm@ times the page
-- size, in MB rounded to one decimal; 'Nothing' where @/proc@ does not exist
-- (macOS) or the file does not parse.
currentRssMb :: IO (Maybe Double)
currentRssMb = do
  contents <- try (BC.readFile "/proc/self/statm")
  case contents of
    Left (_ :: IOException) -> pure Nothing
    Right statm -> do
      size <- pageSize
      pure (currentRssMbFrom size statm)

-- | The pure part of 'currentRssMb': parse a @statm@ line with the given page
-- size (@int(statm.read().split()[1])@).
currentRssMbFrom :: Integer -> BC.ByteString -> Maybe Double
currentRssMbFrom size statm = case BC.words statm of
  _ : resident : _
    | Just (pages, rest) <- BC.readInteger (BC.dropWhile (== '+') resident)
    , BC.null rest ->
        Just (pythonRound 1 (fromRational ((pages * size) % (1024 * 1024))))
  _ -> Nothing

-- | Python's @round(x, ndigits)@ for a float: the exact binary value is
-- rounded half-to-even at the given decimal place, and the decimal result is
-- converted back to the nearest double. Non-finite values are returned as is.
pythonRound :: Int -> Double -> Double
pythonRound digits x
  | isNaN x || isInfinite x = x
  | otherwise = signed (fromRational rounded)
  where
    rounded
      | digits >= 0 = roundHalfEven (toRational x * scale) % 1 / scale
      | otherwise = toRational (roundHalfEven (toRational x / scale')) * scale'
    -- CPython keeps the sign of a result that rounds to zero.
    signed r = if r == 0 && (x < 0 || isNegativeZero x) then -0.0 else r
    scale = 10 ^ digits :: Rational
    scale' = 10 ^ negate digits :: Rational
    roundHalfEven :: Rational -> Integer
    roundHalfEven = round
