-- | Validation primitives shared by every Agenticus value, replicated
-- bit-for-bit from the upstream helpers (@_text@, @_positive_integer@,
-- @_exact_object@, @_capabilities@).
--
-- Upstream repeats these helpers per module with module-specific error
-- messages, so this module exposes the /predicates/ and small decoding
-- combinators; each value module supplies its exact message.
module Petrus.Agenticus.Internal.Validate
  ( -- * Python text semantics
    pyIsSpace
  , pyStrip
  , isTrimmed
  , utf8Length
  , encodeRefusal
  , hasControl
  , hasControlOrDel
  , codePointLength
    -- * Bounded identity text (@_text@)
  , maxTextBytes
  , isBoundedText
  , boundedText
    -- * Integers
  , isPositive
    -- * JSON decoding
  , Fields
  , exactObject
  , member
  , jsonString
  , jsonInt
  , jsonBool
  , jsonArray
  , jsonObject
  , isJsonInt
    -- * Capability key sets
  , capabilitySet
    -- * Misc
  , require
  , sha256Hex
  , canonicalBytes
  , sortedUnique
  , hasDuplicates
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (ord)
import Data.List (sort)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (showHex)
import Petrus.Agenticus.Error
import Petrus.Json (Json (..))
import Petrus.Json qualified as J

-- | Python's @str.isspace@ (the characters @str.strip()@ removes).
pyIsSpace :: Char -> Bool
pyIsSpace c =
  c `elem` ("\t\n\v\f\r \x1c\x1d\x1e\x1f\x85\xa0\x1680\x2028\x2029\x202f\x205f\x3000" :: String)
    || (c >= '\x2000' && c <= '\x200a')

-- | Python's @str.strip()@.
pyStrip :: Text -> Text
pyStrip = T.dropAround pyIsSpace

-- | @value == value.strip()@.
isTrimmed :: Text -> Bool
isTrimmed value = case (T.uncons value, T.unsnoc value) of
  (Just (first, _), Just (_, lastChar)) -> not (pyIsSpace first || pyIsSpace lastChar)
  _ -> True

-- | @len(value.encode())@.
utf8Length :: Text -> Int
utf8Length = B.length . TE.encodeUtf8

-- | The failure of @value.encode()@, if any. Only a string that holds a
-- lone surrogate fails (a WTF-8 'Text', "Petrus.Json.Wtf8", which a parser
-- builds from a @"\\ud800"@ escape as CPython's @json.loads@ does).
-- CPython raises @UnicodeEncodeError@, a @ValueError@; the port keeps the
-- 'ValueError' class, which is what every @except@ on the way tests for,
-- and CPython's message.
encodeRefusal :: Text -> Maybe AgenticusError
encodeRefusal value
  | not (J.hasLoneSurrogate value) = Nothing
  | otherwise = Just (valueError ("'utf-8' codec can't encode " <> spot <> ": surrogates not allowed"))
  where
    surrogate (_, c) = ord c >= 0xD800 && ord c <= 0xDFFF
    run = takeWhile surrogate (dropWhile (not . surrogate) (zip [0 :: Int ..] (T.unpack value)))
    spot = case run of
      [(i, c)] -> "character '\\u" <> T.pack (showHex (ord c) "") <> "' in position " <> T.pack (show i)
      (i, _) : rest -> "characters in position " <> T.pack (show i) <> "-" <> T.pack (show (i + length rest))
      [] -> "" -- unreachable: the value holds a surrogate

-- | @any(ord(c) < 32 for c in value)@.
hasControl :: Text -> Bool
hasControl = T.any (\c -> ord c < 32)

-- | Control characters including DEL (@0x7f@).
hasControlOrDel :: Text -> Bool
hasControlOrDel = T.any (\c -> ord c < 32 || c == '\x7f')

-- | @len(value)@ (code points).
codePointLength :: Text -> Int
codePointLength = T.length

maxTextBytes :: Int
maxTextBytes = 256

-- | The @_text@ predicate: non-empty, trimmed, at most @limit@ UTF-8 bytes,
-- no code point below 32 (DEL is allowed).
isBoundedText :: Int -> Text -> Bool
isBoundedText limit value =
  not (T.null value) && isTrimmed value && utf8Length value <= limit && not (hasControl value)

-- | Validate with the 256-byte bound, failing with a @ValueError@ carrying
-- the given message.
boundedText :: Text -> Text -> Either AgenticusError Text
boundedText message value
  | isBoundedText maxTextBytes value = Right value
  | otherwise = Left (valueError message)

-- | @type(v) is int and v > 0@ for an already-typed integer.
isPositive :: Integer -> Bool
isPositive = (> 0)

-- | The members of an exactly-shaped JSON object.
type Fields = [(Text, Json)]

-- | @_exact_object@: the value is an object whose key set equals @fields@.
exactObject :: [Text] -> AgenticusError -> Json -> Either AgenticusError Fields
exactObject fields failure = \case
  Object members
    | Set.fromList (map fst members) == Set.fromList fields -> Right members
  _ -> Left failure

-- | A member known to be present (after 'exactObject').
member :: Text -> Fields -> Json
member key fields = maybe Null id (lookup key fields)

jsonString :: Json -> Maybe Text
jsonString = \case
  String t -> Just t
  _ -> Nothing

-- | @type(v) is int@ (booleans and floats are not integers).
jsonInt :: Json -> Maybe Integer
jsonInt = \case
  Int i -> Just i
  _ -> Nothing

isJsonInt :: Json -> Bool
isJsonInt = \case
  Int _ -> True
  _ -> False

jsonBool :: Json -> Maybe Bool
jsonBool = \case
  Bool b -> Just b
  _ -> Nothing

jsonArray :: Json -> Maybe [Json]
jsonArray = \case
  Array items -> Just items
  _ -> Nothing

jsonObject :: Json -> Maybe Fields
jsonObject = \case
  Object members -> Just members
  _ -> Nothing

-- | @_capabilities@ over already-decoded text: every item validated, no
-- duplicates.  @itemMessage@ is the @ValueError@ text for an invalid item,
-- @duplicateMessage@ the one for duplicates.
capabilitySet :: Text -> Text -> [Text] -> Either AgenticusError (Set Text)
capabilitySet itemMessage duplicateMessage items = do
  checked <- traverse (boundedText itemMessage) items
  let set = Set.fromList checked
  if Set.size set /= length checked then Left (valueError duplicateMessage) else Right set

require :: Bool -> AgenticusError -> Either AgenticusError ()
require ok failure = if ok then Right () else Left failure

-- | Lowercase hex SHA-256.
sha256Hex :: ByteString -> Text
sha256Hex bytes = TE.decodeLatin1 (convertToBase Base16 (hash bytes :: Digest SHA256))

-- | @json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()@
-- for values known to be finite.
canonicalBytes :: Json -> ByteString
canonicalBytes value = case J.dumps J.compact {J.sortKeys = True} value of
  Right bytes -> bytes
  Left _ -> error "canonicalBytes: non-finite number"

sortedUnique :: Ord a => [a] -> [a]
sortedUnique = Set.toAscList . Set.fromList

hasDuplicates :: Ord a => [a] -> Bool
hasDuplicates xs = length (sort xs) /= Set.size (Set.fromList xs)
