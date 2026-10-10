-- | CPython @repr@ spellings for Motus diagnostics (presentation only).
module Petrus.Motus.Internal.Repr
  ( pyStr
  , pyStrList
  , exceptionTypeName
  , exceptionMessage
  , exceptionRepr
  , uuid4
  , pyRepr
  ) where

import Control.Exception (SomeException (..), displayException)
import Data.Char (isPrint, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (typeOf)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Numeric (showHex)
import Petrus.Json (Json (..), pythonFloatRepr)
import System.IO (IOMode (..), withBinaryFile)

-- | CPython's @repr(str)@.
pyStr :: Text -> Text
pyStr text =
  let useDouble = T.any (== '\'') text && not (T.any (== '"') text)
      quote = if useDouble then '"' else '\''
      escape c
        | c == quote = T.pack ['\\', c]
        | c == '\\' = "\\\\"
        | c == '\n' = "\\n"
        | c == '\r' = "\\r"
        | c == '\t' = "\\t"
        | isPrint c && c /= '\x7f' = T.singleton c
        | ord c < 0x100 = "\\x" <> pad 2 (ord c)
        | ord c < 0x10000 = "\\u" <> pad 4 (ord c)
        | otherwise = "\\U" <> pad 8 (ord c)
      pad width n = let digits = showHex n "" in T.pack (replicate (width - length digits) '0' ++ digits)
   in T.singleton quote <> T.concatMap escape text <> T.singleton quote

-- | @repr@ of a Python list of strings.
pyStrList :: [Text] -> Text
pyStrList items = "[" <> T.intercalate ", " (map pyStr items) <> "]"

-- | The exception's type name: the analogue of @type(error).__name__@.
exceptionTypeName :: SomeException -> Text
exceptionTypeName (SomeException e) = T.pack (show (typeOf e))

-- | The exception's message without a trailing call stack: the analogue of
-- @str(error)@.
exceptionMessage :: SomeException -> Text
exceptionMessage (SomeException e) = fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))

-- | The @repr@ of a caught exception, Python style: @Type('message')@.
exceptionRepr :: SomeException -> Text
exceptionRepr err =
  let message = exceptionMessage err
   in exceptionTypeName err <> "(" <> (if T.null message then "" else pyStr message) <> ")"

-- | A random (version 4) UUID, spelled as @str(uuid.uuid4())@.
uuid4 :: IO Text
uuid4 = do
  bytes <- withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 16)
  let octets = zipWith adjust [0 :: Int ..] (BS.unpack bytes)
      adjust i b
        | i == 6 = (b .&. 0x0f) .|. 0x40
        | i == 8 = (b .&. 0x3f) .|. 0x80
        | otherwise = b
      hex b = let s = showHex b "" in T.pack (if length s == 1 then '0' : s else s)
      chunk from count = T.concat (map hex (take count (drop from octets)))
  pure (T.intercalate "-" [chunk 0 4, chunk 4 2, chunk 6 2, chunk 8 2, chunk 10 6])

-- | @repr@ of a JSON-decoded Python value.
pyRepr :: Json -> Text
pyRepr = \case
  Null -> "None"
  Bool True -> "True"
  Bool False -> "False"
  Int i -> T.pack (show i)
  Float d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)
  String s -> pyStr s
  Array items -> "[" <> T.intercalate ", " (map pyRepr items) <> "]"
  Object members -> "{" <> T.intercalate ", " [pyStr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
