{-# LANGUAGE BangPatterns #-}

-- | Number spellings: correctly rounded decimal-to-double conversion shared
-- by both JSON parsers, and pydantic's lax @str -> int@ and @str -> float@
-- coercions (@str_as_int@ and @str_as_float@ in pydantic-core's
-- @input/shared.rs@, over jiter's integer grammar and Rust's
-- @f64::from_str@).
module Petrus.EngineFile.Number
  ( decimalToDouble
  , IntParse (..)
  , strAsInt
  , strAsFloat
  , rustTrim
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- | The double nearest to @[-]digits[.digits][e[+-]digits]@, ties to even.
-- The caller has checked the grammar; this only reads the pieces.
decimalToDouble :: Bool -> ByteString -> ByteString -> Integer -> Double
decimalToDouble negative intDigits fracDigits exponent10 =
  (if negative then negate else id) magnitude
  where
    digits = BS.dropWhile (== 48) (intDigits <> fracDigits)
    scale = exponent10 - fromIntegral (BS.length fracDigits)
    nDigits = fromIntegral (BS.length digits) :: Integer
    mantissa = BC.foldl' (\acc c -> acc * 10 + fromIntegral (fromEnum c - 48)) 0 digits :: Integer
    magnitude
      | BS.null digits = 0
      | scale + nDigits > 311 = 1 / 0
      | scale + nDigits < -330 = 0
      | mantissa < 9007199254740992 && scale >= 0 && scale <= 22 =
          fromInteger mantissa * (10 ^ (fromInteger scale :: Int))
      | mantissa < 9007199254740992 && scale < 0 && scale >= -22 =
          fromInteger mantissa / (10 ^ (fromInteger (negate scale) :: Int))
      | scale >= 0 = fromRational (fromInteger (mantissa * 10 ^ scale))
      | otherwise = fromRational (fromInteger mantissa / fromInteger (10 ^ negate scale))

-- | The result of a lax integer coercion.
data IntParse
  = IntOk !Integer
  | -- | @int_parsing@
    IntBadString
  | -- | @int_parsing_size@
    IntTooLarge
  deriving stock (Eq, Show)

-- | pydantic's @str_as_int@.
strAsInt :: Text -> IntParse
strAsInt s = case jiterInt (TE.encodeUtf8 s) of
  Right i -> IntOk i
  Left True -> IntTooLarge
  Left False -> case cleanIntStr s of
    Nothing -> IntBadString
    Just cleaned -> either (const IntBadString) IntOk (jiterInt (TE.encodeUtf8 cleaned))

-- | jiter's @NumberInt::try_from(bytes)@: the whole input must be one JSON
-- integer. @Left True@ is @NumberOutOfRange@ (more than 4300 characters).
jiterInt :: ByteString -> Either Bool Integer
jiterInt bytes = case BS.uncons bytes of
  Nothing -> Left False
  Just (first, rest0) ->
    let (negative, body) = if first == 45 then (True, rest0) else (False, bytes)
     in case BS.uncons body of
          Just (48, after)
            | BS.null after -> Right 0
            | otherwise -> Left False
          Just (d, _)
            | d >= 49 && d <= 57 ->
                let ds = BS.takeWhile isDigitW body
                    n = BS.length ds + (if negative then 1 else 0)
                 in if BS.length ds > 18 && n > 4300
                      then Left True
                      else
                        if BS.length ds /= BS.length body
                          then Left False
                          else
                            let v = BC.foldl' (\acc c -> acc * 10 + fromIntegral (fromEnum c - 48)) 0 ds
                             in Right (if negative then negate v else v)
          _ -> Left False
  where
    isDigitW w = w >= 48 && w <= 57

-- | pydantic's @clean_int_str@.
cleanIntStr :: Text -> Maybe Text
cleanIntStr original = do
  let lenBefore = T.length original
      s0 = rustTrim original
  s1 <- case T.stripPrefix "+" s0 of
    Just suffix
      | "-" `T.isPrefixOf` suffix -> Nothing
      | otherwise -> Just suffix
    Nothing -> Just s0
  (negative, s2) <- case T.stripPrefix "-" s1 of
    Just suffix
      | "-" `T.isPrefixOf` suffix || "+" `T.isPrefixOf` suffix -> Nothing
      | otherwise -> Just (True, suffix)
    Nothing -> Just (False, s1)
  s3 <- stripLeadingZeros s2
  let s4 = case T.breakOn "." s3 of
        (whole, dotRest)
          | Just decimals <- T.stripPrefix "." dotRest
          , not (T.null decimals)
          , T.all (== '0') decimals ->
              whole
        _ -> s3
      sign t = if negative then "-" <> t else t
  case stripUnderscores s4 of
    Just stripped -> Just (sign stripped)
    Nothing
      | lenBefore == T.length s4 -> Nothing
      | otherwise -> Just (sign s4)

-- Byte lengths in the reference; every comparison above is between a string
-- and a suffix of it, so character counts decide the same way.

stripLeadingZeros :: Text -> Maybe Text
stripLeadingZeros s = case T.uncons s of
  Just ('0', _) -> go 1 (T.drop 1 s)
  Just (c, _)
    | (c >= '1' && c <= '9') || c == '-' -> Just s
  _ -> Nothing
  where
    go :: Int -> Text -> Maybe Text
    go i rest = case T.uncons rest of
      Nothing -> Just (T.takeEnd 1 s)
      Just (c, rest')
        | c == '0' || c == '_' -> go (i + 1) rest'
        | (c >= '1' && c <= '9') || c == '-' -> Just (T.drop i s)
        | c == '.' -> Just (T.drop (i - 1) s)
        | otherwise -> Nothing

stripUnderscores :: Text -> Maybe Text
stripUnderscores s
  | "_" `T.isPrefixOf` s || "_" `T.isSuffixOf` s || not ("_" `T.isInfixOf` s) || "__" `T.isInfixOf` s = Nothing
  | otherwise = Just (T.filter (/= '_') s)

-- | pydantic's @str_as_float@: Rust's @str::trim@ then @f64::from_str@,
-- else the underscore-stripped spelling (untrimmed).
strAsFloat :: Text -> Maybe Double
strAsFloat s = case rustParseF64 (rustTrim s) of
  Just d -> Just d
  Nothing -> stripUnderscores s >>= rustParseF64

-- | Rust's @str::trim@: strip Unicode @White_Space@ from both ends.
rustTrim :: Text -> Text
rustTrim = T.dropAround isRustWhitespace

isRustWhitespace :: Char -> Bool
isRustWhitespace c =
  c `elem` ("\t\n\v\f\r \x85\xA0\x1680\x2028\x2029\x202F\x205F\x3000" :: String)
    || (c >= '\x2000' && c <= '\x200A')

-- | Rust's @f64::from_str@.
rustParseF64 :: Text -> Maybe Double
rustParseF64 t = do
  let (negative, body) = case T.uncons t of
        Just ('-', rest) -> (True, rest)
        Just ('+', rest) -> (False, rest)
        _ -> (False, t)
      lower = T.map toLower body
      signed d = if negative then negate d else d
  if lower == "inf" || lower == "infinity"
    then Just (signed (1 / 0))
    else
      if lower == "nan"
        then Just (if negative then negate nan else nan)
        else decimal negative body
  where
    nan = 0 / 0 :: Double
    decimal negative body = do
      let (intPart, r1) = T.span isAsciiDigit body
      (fracPart, r2) <- case T.uncons r1 of
        Just ('.', r) -> Just (T.span isAsciiDigit r)
        _ -> Just ("", r1)
      if T.null intPart && T.null fracPart then Nothing else Just ()
      expo <- case T.uncons r2 of
        Nothing -> Just 0
        Just (e, r)
          | e == 'e' || e == 'E' -> do
              let (eneg, ds) = case T.uncons r of
                    Just ('-', x) -> (True, x)
                    Just ('+', x) -> (False, x)
                    _ -> (False, r)
              if T.null ds || not (T.all isAsciiDigit ds) then Nothing else Just ()
              let v = clampExp (T.unpack ds)
              Just (if eneg then negate v else v)
          | otherwise -> Nothing
      Just (decimalToDouble negative (TE.encodeUtf8 intPart) (TE.encodeUtf8 fracPart) expo)
    isAsciiDigit c = c >= '0' && c <= '9' && isDigit c

-- An exponent's value, saturated far beyond any finite double's range.
clampExp :: String -> Integer
clampExp ds =
  let trimmed = dropWhile (== '0') ds
   in if length trimmed > 12 then 10 ^ (12 :: Int) else read ('0' : trimmed)
