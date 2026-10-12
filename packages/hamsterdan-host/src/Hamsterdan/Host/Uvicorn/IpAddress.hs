-- | The part of CPython's @ipaddress@ that uvicorn's @_TrustedHosts@ uses:
-- @ip_address@ and strict @ip_network@ over a @str@, address equality, and
-- network membership. The parsers are CPython's, strictness included: four
-- decimal octets without leading zeros, IPv6 hextets of one to four hex
-- digits with at most one @::@ and an optional dotted IPv4 tail, an IPv6
-- scope id after @%@ (part of the address's equality, not of membership),
-- and a network's prefix as a decimal length or, for IPv4, a netmask or
-- hostmask.
module Hamsterdan.Host.Uvicorn.IpAddress
  ( IpAddress (..)
  , IpNetwork (..)
  , IpVersion (..)
  , ipAddress
  , ipNetwork
  , inNetwork
  ) where

import Control.Applicative ((<|>))
import Control.Monad (foldM, guard)
import Data.Bits (countTrailingZeros, shiftL, shiftR, xor, (.&.))
import Data.Char (isAscii, isDigit, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Data.List (unsnoc)
import Data.Maybe (listToMaybe)
import Numeric (readHex, showHex)

data IpVersion = V4 | V6
  deriving stock (Eq, Ord, Show)

-- | @IPv4Address@ or @IPv6Address@: equal when the version, the integer
-- and the scope id are.
data IpAddress = IpAddress
  { version :: IpVersion
  , value :: Integer
  , scopeId :: Maybe Text
  }
  deriving stock (Eq, Ord, Show)

-- | @IPv4Network@ or @IPv6Network@: its network address and prefix length.
data IpNetwork = IpNetwork
  { version :: IpVersion
  , address :: Integer
  , prefix :: Int
  }
  deriving stock (Eq, Ord, Show)

bits :: IpVersion -> Int
bits = \case
  V4 -> 32
  V6 -> 128

netmask :: IpVersion -> Int -> Integer
netmask v n = ((1 `shiftL` n) - 1) `shiftL` (bits v - n)

-- | @ip_address(text)@; 'Nothing' where it raises @ValueError@.
ipAddress :: Text -> Maybe IpAddress
ipAddress text =
  (\n -> IpAddress V4 n Nothing) <$> ipv4Address text
    <|> (\(n, scope) -> IpAddress V6 n scope) <$> ipv6Address text

-- | @ip_network(text)@ (strict); 'Nothing' where it raises @ValueError@.
ipNetwork :: Text -> Maybe IpNetwork
ipNetwork text = network V4 <|> network V6
  where
    network v = do
      (addressText, mask) <- case T.splitOn "/" text of
        [a] -> Just (a, Nothing)
        [a, m] -> Just (a, Just m)
        _ -> Nothing
      n <- case v of
        V4 -> ipv4Address addressText
        V6 -> fst <$> ipv6Address addressText
      len <- maybe (Just (bits v)) (prefixOf v) mask
      let m = netmask v len
      -- Host bits set: strict raises.
      guard (n .&. m == n)
      Just (IpNetwork v n len)
    prefixOf v mask = prefixLength v mask <|> (if v == V4 then maskPrefix mask else Nothing)
    -- @_prefix_from_prefix_string@: ASCII digits, within the width.
    prefixLength v mask = do
      guard (not (T.null mask) && T.all (\c -> isAscii c && isDigit c) mask)
      (n, _) <- either (const Nothing) Just (TR.decimal mask)
      guard (n <= toInteger (bits v))
      Just (fromInteger n)
    -- @_prefix_from_ip_string@: a netmask (ones then zeros), else a
    -- hostmask (zeros then ones).
    maskPrefix mask = do
      n <- ipv4Address mask
      onesThenZeros n <|> onesThenZeros (n `xor` 0xFFFFFFFF)
    onesThenZeros n =
      let trailing = if n == 0 then 32 else countTrailingZeros (fromInteger n :: Word)
          len = 32 - trailing
       in if n `shiftR` trailing == (1 `shiftL` len) - 1 then Just len else Nothing

-- | @ip in network@: the same version and the network's bits; a scope id
-- plays no part.
inNetwork :: IpAddress -> IpNetwork -> Bool
inNetwork ip net = ip.version == net.version && ip.value .&. netmask net.version net.prefix == net.address

-- | @IPv4Address._ip_int_from_string@.
ipv4Address :: Text -> Maybe Integer
ipv4Address text = do
  guard (not (T.null text))
  let octets = T.splitOn "." text
  guard (length octets == 4)
  foldM (\total octet -> (\o -> total * 256 + o) <$> parseOctet octet) 0 octets
  where
    parseOctet octet = do
      guard (not (T.null octet) && T.all (\c -> isAscii c && isDigit c) octet)
      guard (T.length octet <= 3)
      guard (octet == "0" || not ("0" `T.isPrefixOf` octet))
      (n, _) <- either (const Nothing) Just (TR.decimal octet)
      guard (n <= 255)
      Just n

-- | @IPv6Address(text)@: the integer and the scope id.
ipv6Address :: Text -> Maybe (Integer, Maybe Text)
ipv6Address text = do
  guard (not ("/" `T.isInfixOf` text))
  let (addressText, rest) = T.breakOn "%" text
  scope <-
    if T.null rest
      then Just Nothing
      else do
        let scope = T.drop 1 rest
        guard (not (T.null scope) && not ("%" `T.isInfixOf` scope))
        Just (Just scope)
  n <- ipv6Int addressText
  Just (n, scope)

-- | @IPv6Address._ip_int_from_string@.
ipv6Int :: Text -> Maybe Integer
ipv6Int text = do
  guard (not (T.null text) && T.length text <= 45)
  let split = splitMax 9 text
  guard (length split >= 3)
  parts <- case unsnoc split of
    Just (front, tailPart)
      | "." `T.isInfixOf` tailPart -> do
          n <- ipv4Address tailPart
          Just (front <> [T.pack (showHex (n `shiftR` 16) ""), T.pack (showHex (n .&. 0xFFFF) "")])
    _ -> Just split
  guard (length parts <= 9)
  let count = length parts
      indexed = zip [0 :: Int ..] parts
      inner = [i | (i, part) <- indexed, i >= 1, i <= count - 2, T.null part]
      firstEmpty = maybe False T.null (listToMaybe parts)
      lastEmpty = maybe False (T.null . snd) (unsnoc parts)
  (hi, lo, skipped) <- case inner of
    [] -> do
      guard (count == 8 && not firstEmpty && not lastEmpty)
      Just (count, 0, 0)
    [skip] -> do
      let hi0 = skip
          lo0 = count - skip - 1
      hi <- if firstEmpty then (hi0 - 1) <$ guard (hi0 - 1 == 0) else Just hi0
      lo <- if lastEmpty then (lo0 - 1) <$ guard (lo0 - 1 == 0) else Just lo0
      let skipped = 8 - (hi + lo)
      guard (skipped >= 1)
      Just (hi, lo, skipped)
    _ -> Nothing
  high <- foldM (\total part -> (\h -> total * 65536 + h) <$> hextet part) 0 (take hi parts)
  let shifted = high `shiftL` (16 * skipped)
  foldM (\total part -> (\h -> total * 65536 + h) <$> hextet part) shifted (drop (count - lo) parts)
  where
    hextet part = do
      guard (not (T.null part) && T.length part <= 4 && T.all isHexDigit part)
      case readHex (T.unpack part) of
        [(n, "")] -> Just n
        _ -> Nothing

-- | @text.split(":", maxsplit=n)@.
splitMax :: Int -> Text -> [Text]
splitMax n text
  | n <= 0 = [text]
  | otherwise = case T.breakOn ":" text of
      (before, rest)
        | T.null rest -> [before]
        | otherwise -> before : splitMax (n - 1) (T.drop 1 rest)
