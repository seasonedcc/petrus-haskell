{-# LANGUAGE CApiFFI #-}

-- | CPython @repr@ spellings for Motus diagnostics (presentation only).
module Petrus.Motus.Internal.Repr
  ( pyStr
  , pyStrList
  , exceptionMessage
  , uuid4
  , pyRepr
  ) where

import Control.Exception (SomeException (..), displayException)
import Data.Char (isPrint, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Control.Monad (when)
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BSI
import Data.Word (Word8)
import Foreign.C.Error (throwErrno)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr)
import Numeric (showHex)
import Petrus.Json (Json (..), pythonFloatRepr)

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

-- | The exception's message without a trailing call stack: the analogue of
-- @str(error)@.
exceptionMessage :: SomeException -> Text
exceptionMessage (SomeException e) = fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))

foreign import capi unsafe "sys/random.h getentropy" c_getentropy :: Ptr Word8 -> CSize -> IO CInt

-- | A random (version 4) UUID, spelled as @str(uuid.uuid4())@. Its 16
-- bytes come from the operating system's random source through
-- @getentropy@, as @os.urandom@ draws them.
uuid4 :: IO Text
uuid4 = do
  bytes <- BSI.create 16 $ \buffer -> do
    rc <- c_getentropy buffer 16
    when (rc /= 0) (throwErrno "getentropy")
  let octets = zipWith adjust [0 :: Int ..] (BS.unpack bytes)
      adjust i b
        | i == 6 = (b .&. 0x0f) .|. 0x40
        | i == 8 = (b .&. 0x3f) .|. 0x80
        | otherwise = b
      digit n = "0123456789abcdef" !! fromIntegral n
      hex b = [digit (b `shiftR` 4), digit (b .&. 0x0f)]
      dash i = if i `elem` [4, 6, 8, 10 :: Int] then ('-' :) else id
  pure (T.pack (foldr (\(i, b) rest -> dash i (hex b ++ rest)) [] (zip [0 ..] octets)))

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
