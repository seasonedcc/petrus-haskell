{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE BangPatterns #-}

-- | @TransitionDef.delay@: pydantic's lax @timedelta@ coercions (strings
-- through speedate 0.17's @Duration::parse_bytes_with_config@ with
-- microsecond truncation, integers through @int_as_duration@, floats
-- through @float_as_duration@) and the Python @timedelta@ they become.
module Petrus.EngineFile.Duration
  ( Timedelta (..)
  , DurationError (..)
  , durationErrorDoc
  , parseDuration
  , intDuration
  , floatDuration
  , totalSeconds
  ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Text (Text)
import Data.Word (Word8)

-- | A normalized Python @timedelta@: @0 <= seconds < 86400@ and
-- @0 <= microseconds < 10^6@.
data Timedelta = Timedelta
  { days :: !Integer
  , seconds :: !Integer
  , microseconds :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Why a value is not a duration: a speedate @ParseError@, pydantic's NaN
-- refusal, or @timedelta@'s own range check (an @OverflowError@).
data DurationError
  = TooShort
  | ExtraCharacters
  | InvalidCharHour
  | InvalidCharTimeSep
  | InvalidCharMinute
  | InvalidCharSecond
  | OutOfRangeHour
  | OutOfRangeMinute
  | OutOfRangeSecond
  | SecondFractionMissing
  | DurationInvalidNumber
  | DurationTRepeated
  | DurationInvalidFraction
  | DurationInvalidTimeUnit
  | DurationInvalidDateUnit
  | DurationInvalidDays
  | DurationValueTooLarge
  | DurationHourValueTooLarge
  | DurationDaysTooLarge
  | NanNotPermitted
  | -- | @OverflowError@ from @timedelta(days=...)@ with the day count.
    TimedeltaOverflow Integer
  deriving stock (Eq, Show)

-- | The speedate documentation string pydantic puts in the message.
durationErrorDoc :: DurationError -> Text
durationErrorDoc = \case
  TooShort -> "input is too short"
  ExtraCharacters -> "unexpected extra characters at the end of the input"
  InvalidCharHour -> "invalid character in hour"
  InvalidCharTimeSep -> "invalid time separator, expected `:`"
  InvalidCharMinute -> "invalid character in minute"
  InvalidCharSecond -> "invalid character in second"
  OutOfRangeHour -> "hour value is outside expected range of 0-23"
  OutOfRangeMinute -> "minute value is outside expected range of 0-59"
  OutOfRangeSecond -> "second value is outside expected range of 0-59"
  SecondFractionMissing -> "second fraction digits missing after `.`"
  DurationInvalidNumber -> "invalid digit in duration"
  DurationTRepeated -> "`t` character repeated in duration"
  DurationInvalidFraction -> "quantity fraction invalid in duration"
  DurationInvalidTimeUnit -> "quantity invalid in time part of duration"
  DurationInvalidDateUnit -> "quantity invalid in date part of duration"
  DurationInvalidDays -> "\"day\" identifier in duration not correctly formatted"
  DurationValueTooLarge -> "a numeric value in the duration is too large"
  DurationHourValueTooLarge -> "durations may not exceed 999,999,999 hours"
  DurationDaysTooLarge -> "durations may not exceed 999,999,999 days"
  NanNotPermitted -> "NaN values not permitted"
  TimedeltaOverflow _ -> ""

-- | speedate's @Duration@ (all components @u32@).
data Raw = Raw !Bool !Integer !Integer !Integer

u32Max :: Integer
u32Max = 4294967295

checked :: Integer -> Either DurationError Integer
checked n = if n > u32Max then Left DurationValueTooLarge else Right n

-- | @Duration::normalize@ and then @timedelta(sign*day, sign*second,
-- sign*microsecond)@.
finish :: Raw -> Either DurationError Timedelta
finish (Raw positive day0 second0 micro0) = do
  (second1, micro1) <-
    if micro0 >= 1000000
      then (,micro0 `mod` 1000000) <$> checked (second0 + micro0 `div` 1000000)
      else Right (second0, micro0)
  (day2, second2) <-
    if second1 >= 86400
      then (,second1 `mod` 86400) <$> checked (day0 + second1 `div` 86400)
      else Right (day0, second1)
  if day2 > 999999999
    then Left DurationDaysTooLarge
    else do
      let sign = if positive then 1 else -1
          total = sign * ((day2 * 86400 + second2) * 1000000 + micro1)
          (d, rest) = total `divMod` 86400000000
          (s, us) = rest `divMod` 1000000
      if abs d > 999999999 then Left (TimedeltaOverflow d) else Right (Timedelta d s us)

-- | @timedelta.total_seconds()@: microseconds over 10^6, correctly rounded.
totalSeconds :: Timedelta -> Double
totalSeconds t =
  fromRational (toRational ((t.days * 86400 + t.seconds) * 1000000 + t.microseconds) / 1000000)

-- | @int_as_duration@ for an @i64@ (the day count wraps to @u32@, as the
-- reference's @as u32@ does).
intDuration :: Integer -> Either DurationError Timedelta
intDuration total =
  let magnitude = abs total
   in finish (Raw (total >= 0) ((magnitude `div` 86400) `mod` 4294967296) (magnitude `mod` 86400) 0)

-- | @float_as_duration@.
floatDuration :: Double -> Either DurationError Timedelta
floatDuration total
  | isNaN total = Left NanNotPermitted
  | otherwise =
      let positive = total >= 0
          magnitude = abs total
          fraction = if isInfinite magnitude then 0 / 0 else magnitude - fromInteger (truncate magnitude)
          micro = satU32 (roundHalfAway (fraction * 1000000))
          day = satU32 (magnitude / 86400)
          wholeSeconds = satU64 magnitude `mod` 86400
       in finish (Raw positive day wholeSeconds micro)

-- | Rust's @f64::round@.
roundHalfAway :: Double -> Double
roundHalfAway x
  | isNaN x || isInfinite x = x
  | otherwise =
      let t = fromInteger (truncate x) :: Double
          diff = x - t
       in if abs diff >= 0.5 then t + signum x else t

-- | Rust's saturating @as u32@ (NaN to 0).
satU32 :: Double -> Integer
satU32 x
  | isNaN x || x <= 0 = 0
  | isInfinite x = u32Max
  | otherwise = min u32Max (truncate x)

satU64 :: Double -> Integer
satU64 x
  | isNaN x || x <= 0 = 0
  | isInfinite x = 18446744073709551615
  | otherwise = min 18446744073709551615 (truncate x)

-- | @Duration::parse_bytes_with_config@ (microseconds truncated).
parseDuration :: ByteString -> Either DurationError Timedelta
parseDuration input = do
  let (positive, body) = case BS.uncons input of
        Just (45, rest) -> (False, rest)
        Just (43, rest) -> (True, rest)
        _ -> (True, input)
  Raw _ day second micro <- case BS.uncons body of
    Nothing -> Left TooShort
    Just (80, iso) -> isoDuration iso
    Just _
      | BS.any (\b -> b == 100 || b == 68) body || BS.length body < 5 -> daysTime body
      | otherwise -> timeOnly body
  finish (Raw positive day second micro)

isDigitW :: Word8 -> Bool
isDigitW b = b >= 48 && b <= 57

-- | @parse_number@: a @u32@ starting at offset 0.
parseNumber :: ByteString -> Either DurationError (Integer, Int)
parseNumber bytes = case BS.uncons bytes of
  Just (d, _) | isDigitW d -> go (toInteger (d - 48)) 1
  _ -> Left DurationInvalidNumber
  where
    go !value !position = case indexMaybe bytes position of
      Just c
        | isDigitW c -> do
            v <- checked (value * 10)
            v' <- checked (v + toInteger (c - 48))
            go v' (position + 1)
      _ -> Right (value, position)

indexMaybe :: ByteString -> Int -> Maybe Word8
indexMaybe bytes i
  | i >= 0 && i < BS.length bytes = Just (BU.unsafeIndex bytes i)
  | otherwise = Nothing

-- | @parse_number_frac@.
parseNumberFrac :: ByteString -> Either DurationError (Integer, Maybe Double, Int)
parseNumberFrac bytes = do
  (value, position) <- parseNumber bytes
  case indexMaybe bytes position of
    Just c | c == 46 || c == 44 -> Right (go value 0 1 (position + 1))
    _ -> Right (value, Nothing, position)
  where
    go value !decimal !denominator position = case indexMaybe bytes position of
      Just c | isDigitW c -> go value (decimal * 10 + fromIntegral (c - 48)) (denominator * 10) (position + 1)
      _ -> (value, Just (decimal / denominator), position)

-- | @parse_iso_duration@ (after the @P@).
isoDuration :: ByteString -> Either DurationError Raw
isoDuration bytes = go False False 0 0 0 0
  where
    go gotT lastHadFraction position day second micro = case indexMaybe bytes position of
      Nothing
        | position < 2 -> Left TooShort
        | otherwise -> Right (Raw False day second micro)
      Just 84
        | gotT -> Left DurationTRepeated
        | otherwise -> go True lastHadFraction (position + 1) day second micro
      Just _ -> do
        (value, fraction, offset) <- parseNumberFrac (BS.drop position bytes)
        if lastHadFraction then Left DurationInvalidFraction else Right ()
        let hadFraction = lastHadFraction || maybe False (const True) fraction
            position' = position + offset
        if gotT
          then do
            mult <- case indexMaybe bytes position' of
              Just 72 -> Right 3600
              Just 77 -> Right 60
              Just 83 -> Right 1
              _ -> Left DurationInvalidTimeUnit
            product' <- checked (mult * value)
            second1 <- checked (second + product')
            (second2, micro2) <- case fraction of
              Nothing -> Right (second1, micro)
              Just f -> do
                let extra = f * fromInteger mult
                    extraFull = truncDouble extra
                s <- checked (second1 + satU32 extraFull)
                let microExtra = satU32 (roundHalfAway ((extra - extraFull) * 1000000))
                m <- checked (micro + microExtra)
                Right (s, m)
            go gotT hadFraction (position' + 1) day second2 micro2
          else do
            mult <- case indexMaybe bytes position' of
              Just 89 -> Right 365
              Just 77 -> Right 30
              Just 87 -> Right 7
              Just 68 -> Right 1
              _ -> Left DurationInvalidDateUnit
            product' <- checked (value * mult)
            day1 <- checked (day + product')
            (day2, second2, micro2) <- case fraction of
              Nothing -> Right (day1, second, micro)
              Just f -> do
                let extraDays = f * fromInteger mult
                    extraFullDays = truncDouble extraDays
                d <- checked (day1 + satU32 extraFullDays)
                let extraSeconds = (extraDays - extraFullDays) * 86400
                    extraFullSeconds = truncDouble extraSeconds
                s <- checked (second + satU32 extraFullSeconds)
                let m = (micro + satU32 (roundHalfAway ((extraSeconds - extraFullSeconds) * 1000000))) `mod` 4294967296
                Right (d, s, m)
            go gotT hadFraction (position' + 1) day2 second2 micro2

truncDouble :: Double -> Double
truncDouble x
  | isNaN x || isInfinite x = x
  | otherwise = fromInteger (truncate x)

-- | @parse_days_time@.
daysTime :: ByteString -> Either DurationError Raw
daysTime bytes = do
  (day, position) <- case BS.uncons bytes of
    Just _ -> parseNumber bytes
    Nothing -> Left TooShort
  afterD <- case BS.unpack (BS.take 2 (BS.drop position bytes)) of
    (32 : d : _) | d == 100 || d == 68 -> Right (BS.drop (position + 2) bytes)
    (d : _) | d == 100 || d == 68 -> Right (BS.drop (position + 1) bytes)
    _ -> Left DurationInvalidDays
  afterWord <-
    if BS.isPrefixOf "ays" afterD || BS.isPrefixOf "AYS" afterD
      then Right (BS.drop 3 afterD)
      else
        if BS.isPrefixOf "ay" afterD || BS.isPrefixOf "AY" afterD
          then Right (BS.drop 2 afterD)
          else case BS.uncons afterD of
            Just (c, _) | c == 97 || c == 65 -> Left DurationInvalidDays
            _ -> Right afterD
  let remaining
        | BS.isPrefixOf ", " afterWord = BS.drop 2 afterWord
        | BS.isPrefixOf "," afterWord = BS.drop 1 afterWord
        | BS.isPrefixOf " " afterWord = BS.drop 1 afterWord
        | otherwise = afterWord
  if BS.null remaining
    then Right (Raw False day 0 0)
    else do
      Raw _ tDay tSecond tMicro <- timeOnly remaining
      if tDay > 0 then Left DurationHourValueTooLarge else Right (Raw False day tSecond tMicro)

-- | @parse_time@ (truncating extra fraction digits).
timeOnly :: ByteString -> Either DurationError Raw
timeOnly bytes
  | BS.length bytes < 5 = Left TooShort
  | otherwise = case BS.elemIndex 58 bytes of
      Nothing -> Left InvalidCharHour
      Just colon -> do
        let hourPart = BS.take colon bytes
            remaining0 = BS.drop (colon + 1) bytes
        if BS.length hourPart > 10 then Left DurationHourValueTooLarge else Right ()
        hour <-
          if BS.all isDigitW hourPart
            then Right (BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 hourPart)
            else Left InvalidCharHour
        if hour > 2400000000 then Left DurationHourValueTooLarge else Right ()
        let remaining = if 3 + BS.length remaining0 > 15 then BS.take 12 remaining0 else remaining0
            padded = "00:" <> remaining
        (minute, second, micro, position) <- pureTime padded
        if BS.length padded > position then Left ExtraCharacters else Right ()
        let day = hour `div` 24
            hour' = hour `mod` 24
        Right (Raw False day (minute * 60 + second + hour' * 3600) micro)

-- | @PureTime::parse(bytes, 0)@ where the hour is always @00@: minute,
-- second, microsecond and the end position.
pureTime :: ByteString -> Either DurationError (Integer, Integer, Integer, Int)
pureTime bytes
  | BS.length bytes < 5 = Left TooShort
  | otherwise = do
      m1 <- digitAt 3 InvalidCharMinute
      m2 <- digitAt 4 InvalidCharMinute
      let minute = m1 * 10 + m2
      if minute > 59 then Left OutOfRangeMinute else Right ()
      case indexMaybe bytes 5 of
        Just 58 -> do
          s1 <- digitAt 6 InvalidCharSecond
          s2 <- digitAt 7 InvalidCharSecond
          let second = s1 * 10 + s2
          if second > 59 then Left OutOfRangeSecond else Right ()
          case indexMaybe bytes 8 of
            Just c
              | c == 46 || c == 44 -> do
                  let digits = BS.takeWhile isDigitW (BS.drop 9 bytes)
                      count = BS.length digits
                      kept = BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 (BS.take 6 digits)
                      micro = if count < 6 then kept * 10 ^ (6 - count) else kept
                  if count == 0 then Left SecondFractionMissing else Right (minute, second, micro, 9 + count)
            _ -> Right (minute, second, 0, 8)
        _ -> Right (minute, 0, 0, 5)
  where
    digitAt i err = case indexMaybe bytes i of
      Just c | isDigitW c -> Right (toInteger (c - 48))
      _ -> Left err
