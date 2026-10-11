-- | Python's @datetime.timedelta@ and timezone-aware @datetime.datetime@, as
-- cel-python's @DurationType@ and @TimestampType@ use them, plus the
-- @pendulum.parse@ pipeline behind @timestamp(string)@.
--
-- Every time zone cel-python can attach is a fixed UTC offset (pendulum's
-- @FixedTimezone@, @datetime.timezone@, or UTC), so a 'Datetime' is a local
-- wall-clock reading plus an offset.
--
-- Deviations, all listed in the package's DIVERGENCES.md:
--
-- * @timestamp(\"now\")@ and time-only strings (which pendulum completes
--   with the current date) are impure in cel-python; here they fail with a
--   'ValueError';
-- * the timezone argument of the @get*@ functions accepts UTC-like IANA
--   names and the fixed-offset @Etc/GMT±N@ zones, not zones with daylight
--   saving rules.
module Petrus.Cel.Time
  ( -- * timedelta
    Timedelta (..)
  , checkTimedelta
  , timedeltaRepr
  , timedeltaTotalSeconds
  , timedeltaFromSeconds
  , timedeltaMulRational
  , timedeltaDivInteger
    -- * datetime
  , Datetime (..)
  , datetimeUtcMicros
  , datetimeStr
  , datetimeAdd
  , datetimeDiff
  , datetimeTimestamp
  , datetimeFromFields
  , datetimeFields
  , DatetimeFields (..)
  , isoWeekday
  , dayOfYear
  , inOffset
    -- * Parsing
  , ParsedTimestamp (..)
  , parseTimestamp
  , parseDurationString
  , timezoneOffset
  , maxDurationSeconds
  ) where

import Data.Char (isAsciiLower, isDigit)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (Day (..), fromGregorianValid, isLeapYear, toGregorian)
import Data.Time.Calendar.OrdinalDate (toOrdinalDate)

import Petrus.Cel.Python (ExcClass (..), PyErr (..), parseFloatText)
import Petrus.Json.Python (pythonDecimal, pythonStrRepr)

-- timedelta ---------------------------------------------------------------

-- | A @datetime.timedelta@, as a number of microseconds.
newtype Timedelta = Timedelta Integer
  deriving stock (Eq, Ord, Show)

microsPerSecond, microsPerDay :: Integer
microsPerSecond = 1000000
microsPerDay = 86400 * microsPerSecond

-- | @timedelta@'s range check (@|days| <= 999999999@).
checkTimedelta :: Integer -> Either PyErr Timedelta
checkTimedelta micros =
  let days = micros `div` microsPerDay
   in if abs days > 999999999
        then Left (PyErr OverflowError ("days=" <> T.pack (show days) <> "; must have magnitude <= 999999999"))
        else Right (Timedelta micros)

-- | @repr(timedelta)@: @datetime.timedelta(days=-1, seconds=86399)@.
timedeltaRepr :: Timedelta -> Text
timedeltaRepr (Timedelta micros) =
  let (days, rest) = micros `divMod` microsPerDay
      (seconds, us) = rest `divMod` microsPerSecond
      parts =
        [("days", days) | days /= 0]
          <> [("seconds", seconds) | seconds /= 0]
          <> [("microseconds", us) | us /= 0]
   in "datetime.timedelta("
        <> (if null parts then "0" else T.intercalate ", " [k <> "=" <> T.pack (show v) | (k, v) <- parts])
        <> ")"

-- | @timedelta.total_seconds()@ (a correctly rounded true division).
timedeltaTotalSeconds :: Timedelta -> Double
timedeltaTotalSeconds (Timedelta micros) = fromRational (fromIntegral micros / fromIntegral microsPerSecond)

-- | @timedelta(seconds=x)@ for a float @x@, with CPython's rounding.
timedeltaFromSeconds :: Double -> Either PyErr Timedelta
timedeltaFromSeconds x
  | isNaN x = Left (PyErr ValueError "cannot convert float NaN to integer")
  | isInfinite x = Left (PyErr OverflowError "cannot convert float infinity to integer")
  | otherwise =
      let intPart = truncate x :: Integer
          frac = x - fromIntegral intPart
          scaled = frac * 1e6
          intPart2 = truncate scaled :: Integer
          leftover = scaled - fromIntegral intPart2
          base = intPart * microsPerSecond + intPart2
          whole = roundHalfAway leftover
          adjusted
            | leftover == 0 = 0
            | abs (whole - leftover) == 0.5 =
                let odd' = if odd base then 1 else 0
                 in 2 * roundHalfAway ((leftover + odd') * 0.5) - odd'
            | otherwise = whole
       in checkTimedelta (base + truncate adjusted)
  where
    roundHalfAway :: Double -> Double
    roundHalfAway v = let r = fromIntegral (truncate (abs v + 0.5) :: Integer) in if v < 0 then negate r else r

-- | @timedelta * (n/d)@ with round-half-even (CPython's @_divide_and_round@).
timedeltaMulRational :: Timedelta -> Rational -> Either PyErr Timedelta
timedeltaMulRational (Timedelta micros) r = checkTimedelta (round (fromIntegral micros * r))

-- | @timedelta / int@ with round-half-even.
timedeltaDivInteger :: Timedelta -> Integer -> Either PyErr Timedelta
timedeltaDivInteger _ 0 = Left (PyErr ZeroDivisionError "division by zero")
timedeltaDivInteger (Timedelta micros) n = checkTimedelta (round (fromIntegral micros / fromIntegral n :: Rational))

-- datetime ---------------------------------------------------------------

-- | An aware @datetime@: local microseconds since 0001-01-01T00:00 and the
-- zone's UTC offset in seconds.
data Datetime = Datetime
  { datetimeLocal :: Integer
  , datetimeOffset :: Integer
  }
  deriving stock (Show)

-- | The instant, as microseconds since 0001-01-01T00:00 UTC.
datetimeUtcMicros :: Datetime -> Integer
datetimeUtcMicros (Datetime local offset) = local - offset * microsPerSecond

maxLocal :: Integer
maxLocal = 3652059 * microsPerDay

ordinalEpoch :: Integer
ordinalEpoch = 678576

-- | A day as Python's proleptic ordinal (0001-01-01 is 1).
toOrdinal :: Day -> Integer
toOrdinal (ModifiedJulianDay mjd) = mjd + ordinalEpoch

fromOrdinal :: Integer -> Day
fromOrdinal o = ModifiedJulianDay (o - ordinalEpoch)

-- | The broken-down local fields of a datetime.
data DatetimeFields = DatetimeFields
  { fieldYear :: Integer
  , fieldMonth :: Int
  , fieldDay :: Int
  , fieldHour :: Integer
  , fieldMinute :: Integer
  , fieldSecond :: Integer
  , fieldMicrosecond :: Integer
  , fieldOrdinal :: Integer
  }

datetimeFields :: Datetime -> DatetimeFields
datetimeFields (Datetime local _) =
  let (days, micros) = local `divMod` microsPerDay
      ordinal = days + 1
      (y, m, d) = toGregorian (fromOrdinal ordinal)
      (secs, us) = micros `divMod` microsPerSecond
      (h, rest) = secs `divMod` 3600
      (mi, s) = rest `divMod` 60
   in DatetimeFields y m d h mi s us ordinal

-- | @isoweekday()@: Monday is 1, Sunday 7.
isoWeekday :: DatetimeFields -> Integer
isoWeekday f = let w = fieldOrdinal f `mod` 7 in if w == 0 then 7 else w

-- | Zero-based day of the year.
dayOfYear :: DatetimeFields -> Integer
dayOfYear f = fromIntegral (snd (toOrdinalDate (fromOrdinal (fieldOrdinal f)))) - 1

-- | @astimezone@ to a fixed offset.
inOffset :: Integer -> Datetime -> Either PyErr Datetime
inOffset offset dt = checked (Datetime (datetimeUtcMicros dt + offset * microsPerSecond) offset)

checked :: Datetime -> Either PyErr Datetime
checked dt
  | datetimeLocal dt < 0 || datetimeLocal dt >= maxLocal = Left (PyErr OverflowError "date value out of range")
  | otherwise = Right dt

-- | @TimestampType.__str__@: @strftime('%Y-%m-%dT%H:%M:%S%z')@ with @+0000@
-- shown as @Z@ and other offsets as @+hh:mm@.
datetimeStr :: Datetime -> Text
datetimeStr dt =
  let f = datetimeFields dt
      pad n v = T.justifyRight n '0' (T.pack (show v))
      base =
        pad 4 (fieldYear f) <> "-" <> pad 2 (fieldMonth f) <> "-" <> pad 2 (fieldDay f)
          <> "T" <> pad 2 (fieldHour f) <> ":" <> pad 2 (fieldMinute f) <> ":" <> pad 2 (fieldSecond f)
      offset = datetimeOffset dt
      (sign, magnitude) = if offset < 0 then ("-", negate offset) else ("+", offset)
      (oh, orest) = magnitude `divMod` 3600
      (om, os) = orest `divMod` 60
      z = sign <> pad 2 oh <> pad 2 om <> (if os /= 0 then pad 2 os else "")
   in if z == "+0000" then base <> "Z" else base <> T.dropEnd 2 z <> ":" <> T.takeEnd 2 z

-- | @datetime + timedelta@ (wall-clock arithmetic in the same zone).
datetimeAdd :: Datetime -> Timedelta -> Either PyErr Datetime
datetimeAdd (Datetime local offset) (Timedelta micros) = checked (Datetime (local + micros) offset)

-- | @datetime - datetime@ for aware datetimes.
datetimeDiff :: Datetime -> Datetime -> Either PyErr Timedelta
datetimeDiff a b = checkTimedelta (datetimeUtcMicros a - datetimeUtcMicros b)

-- | @datetime.timestamp()@.
datetimeTimestamp :: Datetime -> Double
datetimeTimestamp dt = timedeltaTotalSeconds (Timedelta (datetimeUtcMicros dt - 719162 * microsPerDay))

-- | @datetime(year, month, day, hour=0, minute=0, second=0, microsecond=0)@
-- at an offset, with Python's validation.
datetimeFromFields :: Integer -> [Integer] -> Either PyErr Datetime
datetimeFromFields offset fields = case fields ++ replicate (7 - length fields) 0 of
  [y, m, d, h, mi, s, us]
    | y < 1 || y > 9999 -> bad ("year " <> T.pack (show y) <> " is out of range")
    | m < 1 || m > 12 -> bad "month must be in 1..12"
    | Nothing <- day -> bad "day is out of range for month"
    | h < 0 || h > 23 -> bad "hour must be in 0..23"
    | mi < 0 || mi > 59 -> bad "minute must be in 0..59"
    | s < 0 || s > 59 -> bad "second must be in 0..59"
    | us < 0 || us > 999999 -> bad "microsecond must be in 0..999999"
    | abs offset >= 86400 -> bad "offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24)"
    | Just dayValue <- day ->
        Right
          ( Datetime
              ((toOrdinal dayValue - 1) * microsPerDay + ((h * 60 + mi) * 60 + s) * microsPerSecond + us)
              offset
          )
    where
      day = fromGregorianValid y (fromIntegral m) (fromIntegral d)
  _ -> bad "function takes at most 8 arguments"
  where
    bad = Left . PyErr ValueError

-- Parsing ----------------------------------------------------------------

-- | What @pendulum.parse(text)@ produced, as @TimestampType@ sees it.
data ParsedTimestamp
  = -- | A date or datetime (naive ones are placed in UTC).
    ParsedDatetime Datetime
  | -- | A duration or an interval: not a datetime, so @TimestampType@ fails
    -- with @AttributeError@/@TypeError@ (\"no such overload\").
    ParsedNotDatetime
  deriving stock (Show)

-- | @pendulum.parse(text)@ restricted to what @TimestampType(str)@ needs.
-- 'Left' carries the exception @TimestampType@ raises.
parseTimestamp :: Text -> Either PyErr ParsedTimestamp
parseTimestamp text
  | text == "now" = Left (PyErr ValueError "timestamp('now') depends on the clock and is not supported")
  | otherwise = case rustIso8601 (T.unpack text) of
      Right r -> fromRust r
      Left () -> case interval of
        Just r -> r
        Nothing -> common
  where
    fromRust = \case
      RDatetime fields offset -> ParsedDatetime <$> datetimeFromFields (fromMaybe 0 offset) fields
      RDate fields -> ParsedDatetime <$> datetimeFromFields 0 fields
      RTime -> Left (PyErr ValueError "time-only timestamps depend on the current date and are not supported")
      RDuration -> Right ParsedNotDatetime
    -- The Rust parser rejected the text (or produced an invalid date, also a
    -- ValueError that pendulum suppresses): try the interval and the
    -- "common" formats.
    interval
      | T.any (== '/') text = case T.splitOn "/" text of
          [a, b]
            | not (T.null a) && not (T.null b)
            , Right _ <- validRust a
            , Right _ <- validRust b ->
                Just (Right ParsedNotDatetime)
          _ -> Nothing
      | otherwise = Nothing
    validRust part = rustIso8601 (T.unpack part)
    common = case parseCommon (T.unpack text) of
      Nothing -> Left (PyErr ValueError ("Unable to parse string [" <> text <> "]"))
      Just r -> r

data RustResult
  = RDatetime [Integer] (Maybe Integer)
  | RDate [Integer]
  | RTime
  | RDuration

-- | pendulum 3.2's Rust @parse_iso8601@ (syntax plus the checks it makes
-- before building Python objects). Invalid calendar dates are reported as
-- failures too, because pendulum suppresses the resulting @ValueError@.
rustIso8601 :: String -> Either () RustResult
rustIso8601 input = case input of
  'P' : _ -> if validDuration (drop 1 input) then Right RDuration else Left ()
  _ -> datetimeAt input >>= \case
    (fields, Nothing) -> case datetimeFromFields 0 fields of
      Right _ -> Right (RDate fields)
      Left _ -> Left ()
    (fields, Just (time, offset))
      | null fields -> Right RTime
      | otherwise -> case datetimeFromFields (fromMaybe 0 offset) (fields <> time) of
          Right _ -> Right (RDatetime (fields <> time) offset)
          Left _ -> Left ()
  where
    digitN n s =
      let (ds, rest) = splitAt n s
       in if length ds == n && all isDigit ds then Just (read ds :: Integer, rest) else Nothing
    sep c = c == ' ' || c == 'T'
    endOrSep = \case
      [] -> True
      c : _ -> sep c
    datetimeAt :: String -> Either () ([Integer], Maybe ([Integer], Maybe Integer))
    datetimeAt s = case s of
      'T' : _ -> do
        (time, offset, rest) <- timeAt False s Nothing
        if null rest then Right ([], Just (time, offset)) else Left ()
      _ -> do
        (yy, r1) <- maybe (Left ()) Right (digitN 2 s)
        case r1 of
          ':' : _ -> do
            (time, offset, rest) <- timeAt True r1 (Just (yy, True))
            if null rest then Right ([], Just (time, offset)) else Left ()
          _ -> do
            (yy2, r2) <- maybe (Left ()) Right (digitN 2 r1)
            let year = yy * 100 + yy2
            (date, extended, r3) <- dateAt year r2
            if null r3
              then Right (date, Nothing)
              else do
                (time, offset, rest) <- timeAt False r3 (Just (0, extended))
                if null rest then Right (date, Just (time, offset)) else Left ()
    dateAt year s = case s of
      '-' : 'W' : r -> do
        (week, r1) <- maybe (Left ()) Right (digitN 2 r)
        (day, r2) <-
          if endOrSep r1
            then Right (1, r1)
            else case r1 of
              '-' : r1' -> maybe (Left ()) Right (digitN 1 r1')
              _ -> Left ()
        ymd <- isoToYmd year week day
        Right (ymd, True, r2)
      '-' : r -> do
        (month, r1) <- maybe (Left ()) Right (digitN 2 r)
        if endOrSep r1
          then Right ([year, month, 1], True, r1)
          else case r1 of
            '-' : r1' -> do
              (day, r2) <- maybe (Left ()) Right (digitN 2 r1')
              Right ([year, month, day], True, r2)
            _ -> do
              (d, r2) <- maybe (Left ()) Right (digitN 1 r1)
              ymd <- ordinalToYmd year (month * 10 + d) False
              Right (ymd, True, r2)
      'W' : r -> do
        (week, r1) <- maybe (Left ()) Right (digitN 2 r)
        (day, r2) <- if endOrSep r1 then Right (1, r1) else maybe (Left ()) Right (digitN 1 r1)
        ymd <- isoToYmd year week day
        Right (ymd, False, r2)
      _ -> do
        (month, r1) <- maybe (Left ()) Right (digitN 2 s)
        (d, r2) <- maybe (Left ()) Right (digitN 1 r1)
        if endOrSep r2
          then do
            ymd <- ordinalToYmd year (d + month * 10) False
            Right (ymd, False, r2)
          else do
            (d2, r3) <- maybe (Left ()) Right (digitN 1 r2)
            Right ([year, month, d * 10 + d2], False, r3)
    -- @timeAt skipHour s state@: state carries the hour (when already read)
    -- and whether the date used the extended format.
    timeAt :: Bool -> String -> Maybe (Integer, Bool) -> Either () ([Integer], Maybe Integer, String)
    timeAt skipHour s state = do
      let extended = maybe False snd state
      (hour, r1) <-
        if skipHour
          then Right (maybe 0 fst state, s)
          else case s of
            c : r | sep c -> maybe (Left ()) Right (digitN 2 r)
            _ -> Left ()
      let offsetStart = \case
            [] -> True
            c : _ -> c `elem` ("Z+-" :: String)
      (minute, second, micro, r2) <-
        if offsetStart r1
          then Right (0, 0, 0, r1)
          else case r1 of
            ':' : r -> do
              (mi, ra) <- maybe (Left ()) Right (digitN 2 r)
              if offsetStart ra
                then Right (mi, 0, 0, ra)
                else case ra of
                  ':' : rb -> do
                    (se, rc) <- maybe (Left ()) Right (digitN 2 rb)
                    (us, rd) <- fraction rc
                    if extended then Right (mi, se, us, rd) else Left ()
                  _ -> Left ()
            _ -> do
              (mi, ra) <- maybe (Left ()) Right (digitN 2 r1)
              (se, us, rd) <-
                if offsetStart ra
                  then Right (0, 0, ra)
                  else do
                    (se, rb) <- maybe (Left ()) Right (digitN 2 ra)
                    (us, rc) <- fraction rb
                    Right (se, us, rc)
              if extended then Left () else Right (mi, se, us, rd)
      (offset, r3) <- case r2 of
        'Z' : r -> Right (Just 0, r)
        c : r | c == '+' || c == '-' -> do
          let signum' = if c == '+' then 1 else -1
          (th, ra) <- maybe (Left ()) Right (digitN 2 r)
          let rb = case ra of ':' : x -> x; x -> x
          (tm, rc) <- if null rb then Right (0, rb) else maybe (Left ()) Right (digitN 2 rb)
          let minutes = signum' * (tm + th * 60)
          if minutes > 24 * 60 then Left () else Right (Just (minutes * 60), rc)
        _ -> Right (Nothing, r2)
      Right ([hour, minute, second, micro], offset, r3)
    fraction s = case s of
      c : r | c == '.' || c == ',' -> case span isDigit r of
        ([], _) -> Left ()
        (ds, rest) -> Right (read (take 6 (ds <> "00000")) :: Integer, rest)
      _ -> Right (0, s)
    isoToYmd year week day
      | week > 53 || (week > 52 && not (isLongYear year)) = Left ()
      | day > 7 = Left ()
      | otherwise = ordinalToYmd year (week * 7 + day - (weekDay year 1 4 + 3)) True
    ordinalToYmd year ordinal allowOutOfBounds
      | ordinal < 1 && not allowOutOfBounds = Left ()
      | otherwise =
          let (y1, o1) = if ordinal < 1 then (year - 1, ordinal + daysInYear (year - 1)) else (year, ordinal)
           in if o1 > daysInYear y1 && not allowOutOfBounds
                then Left ()
                else
                  let (y2, o2) = if o1 > daysInYear y1 then (y1 + 1, o1 - daysInYear y1) else (y1, o1)
                      (gy, gm, gd) = toGregorian (ModifiedJulianDay (toModified y2 + o2 - 1))
                   in Right [gy, fromIntegral gm, fromIntegral gd]
    toModified y = case fromGregorianValid y 1 1 of
      Just (ModifiedJulianDay d) -> d
      Nothing -> 0
    daysInYear y = if isLeapYear y then 366 else 365
    -- pendulum's @week_day@: ISO weekday (Monday 1 .. Sunday 7).
    weekDay y m d = case fromGregorianValid y m d of
      Just day -> let w = toOrdinal day `mod` 7 in if w == 0 then 7 else w
      Nothing -> 0
    isLongYear y = weekDay y 1 1 == 4 || weekDay y 12 31 == 4

-- | pendulum's Rust duration grammar (only validity matters here).
validDuration :: String -> Bool
validDuration = go False False (0 :: Int)
  where
    -- A loose transcription: units in order, at most one fraction (last),
    -- an optional single @T@ separator.
    go _ _ _ [] = True
    go gotT hadFraction n s = case s of
      'T' : rest -> not gotT && go True hadFraction n rest
      c : _ | isDigit c ->
        let (_, r1) = span isDigit s
            (frac, r2) = case r1 of
              d : r | d == '.' || d == ',' -> (True, dropWhile isDigit r)
              _ -> (False, r1)
         in not hadFraction && case r2 of
              u : rest
                | gotT && u `elem` ("HMS" :: String) -> go gotT frac (n + 1) rest
                | not gotT && u `elem` ("YMWD" :: String) && not (frac && u `elem` ("YM" :: String)) -> go gotT frac (n + 1) rest
              _ -> False
      _ -> False

-- | pendulum's @_parse_common@ (the @COMMON@ regex): 'Nothing' when it
-- does not match (a @ParserError@).
parseCommon :: String -> Maybe (Either PyErr ParsedTimestamp)
parseCommon input = case [caps | (rest, caps) <- run common input [], null rest] of
  [] -> Nothing
  caps : _ -> Just (build caps)
  where
    common = optional dateRe <> optional timeRe
    dateRe =
      group "date" $
        group "year" (digits 4 4)
          <> optional
            ( group "monthday"
                ( optional (group "monthsep" (oneOf "/:"))
                    <> group "month" (digits 2 2)
                    <> optional (group "daysep" (oneOf "/:"))
                    <> group "day" (digits 2 2)
                )
            )
    timeRe =
      group "time" $
        optional (group "timesep" (oneOf " "))
          <> group "hour" (digits 1 2)
          <> oneOf ":"
          <> optional (group "minute" (digits 1 2))
          <> optional (oneOf ":" <> group "second" (digits 1 2))
          <> optional (group "subsecondsection" (oneOf ".|," <> group "subsecond" (digits 1 9)))
    build caps =
      let get name = lookup name caps
          int = pyInt
       in case get "time" of
            Nothing -> case get "date" of
              Just _ -> ParsedDatetime <$> datetimeFromFields 0 (dateFields get)
              Nothing -> Left (PyErr ValueError "empty")
            Just _ -> case get "minute" of
              Nothing -> Left (PyErr TypeError "int() argument must be a string, a bytes-like object or a real number, not 'NoneType'")
              Just minute
                | isJust (get "date") ->
                    let micro = maybe 0 (\sub -> int (take 6 (sub <> "000000"))) (get "subsecond")
                        time = [maybe 0 int (get "hour"), int minute, maybe 0 int (get "second"), micro]
                     in ParsedDatetime <$> datetimeFromFields 0 (dateFields get <> time)
                | otherwise -> Left (PyErr ValueError "time-only timestamps depend on the current date and are not supported")
    dateFields get =
      [ maybe 0 pyInt (get "year")
      , maybe 1 pyInt (get "month")
      , maybe 1 pyInt (get "day")
      ]
    pyInt s = foldl' (\acc c -> acc * 10 + fromIntegral (fromMaybe 0 (pythonDecimal c))) 0 s

-- A tiny backtracking matcher with Python @re@'s priorities (greedy
-- quantifiers, left-first alternatives), for pendulum's @COMMON@ regex.
newtype Re = Re (String -> [(String, String)] -> [(String, [(String, String)])])

instance Semigroup Re where
  Re a <> Re b = Re (\s caps -> [r | (s', caps') <- a s caps, r <- b s' caps'])

run :: Re -> String -> [(String, String)] -> [(String, [(String, String)])]
run (Re f) = f

optional :: Re -> Re
optional (Re a) = Re (\s caps -> a s caps <> [(s, caps)])

group :: String -> Re -> Re
group name (Re a) = Re (\s caps -> [(s', (name, take (length s - length s') s) : caps') | (s', caps') <- a s caps])

oneOf :: String -> Re
oneOf cs = Re $ \s caps -> case s of
  c : rest | c `elem` cs -> [(rest, caps)]
  _ -> []

-- | @\\d{lo,hi}@ (Unicode decimal digits), greedy.
digits :: Int -> Int -> Re
digits lo hi = Re $ \s caps ->
  let available = length (takeWhile (isJust . pythonDecimal) (take hi s))
   in [(drop n s, caps) | n <- [available, available - 1 .. lo]]

-- | celpy's @DurationType(str)@: @^[-+]?([0-9]*(\\.[0-9]*)?[a-z]+)+$@, then
-- the sum of each @number unit@ pair.
parseDurationString :: Text -> Either PyErr Timedelta
parseDurationString text = do
  let s = T.unpack text
      body = case s of
        c : rest | c == '+' || c == '-' -> rest
        _ -> s
      sign = if take 1 s == "-" then -1 else 1 :: Double
      bodyNoNewline = if not (null body) && last body == '\n' then init body else body
  if validPattern bodyNoNewline then Right () else Left (PyErr ValueError ("Invalid duration " <> pythonStrRepr text))
  terms <- traverse term (segments body)
  let seconds = sign * fromRational (sum (map toRational terms))
  if abs seconds > fromIntegral maxDurationSeconds || isNaN seconds
    then Left (PyErr ValueError "range error: {seconds}")
    else timedeltaFromSeconds seconds
  where
    validPattern b = not (null b) && go b
      where
        go [] = True
        go str =
          let (_, r1) = span isDigit str
              r2 = case r1 of
                '.' : r -> dropWhile isDigit r
                _ -> r1
              (unit, r3) = span isAsciiLower r2
           in not (null unit) && go r3
    segments [] = []
    segments str =
      let (number, r1) = span (\c -> isDigit c || c == '.') str
          (unit, r2) = span isAsciiLower r1
       in if null unit then segments (drop 1 str) else (number, unit) : segments r2
    term (number, unit) = do
      scale <- maybe (Left (PyErr ValueError ("Invalid duration " <> pythonStrRepr text))) Right (lookup unit scales)
      value <-
        maybe
          (Left (PyErr ValueError ("could not convert string to float: " <> pythonStrRepr (T.pack number))))
          Right
          (if null number then Nothing else parseFloatText (T.pack number))
      Right (value * scale)
    scales :: [(String, Double)]
    scales = [("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600), ("d", 86400)]

-- | @DurationType.MaxSeconds@.
maxDurationSeconds :: Integer
maxDurationSeconds = 315576000000

-- | @TimestampType.tz_parse@: the UTC offset (seconds) of a timezone name or
-- @[+-]hh:mm@ offset; 'Nothing' (or an empty name) is UTC.
timezoneOffset :: Maybe Text -> Either PyErr Integer
timezoneOffset = \case
  Nothing -> Right 0
  Just "" -> Right 0
  Just name
    | name `elem` utcNames -> Right 0
    | Just hours <- etcGmt name -> Right (hours * 3600)
    | Just hours <- lookup name fixedZones -> Right (hours * 3600)
    | otherwise -> offsetPattern name
  where
    utcNames =
      [ "UTC", "Etc/UTC", "GMT", "Etc/GMT", "Universal", "Etc/Universal", "Zulu", "Etc/Zulu", "UCT", "Etc/UCT"
      , "Greenwich", "Etc/Greenwich", "GMT0", "Etc/GMT0", "GMT+0", "GMT-0", "Etc/GMT+0", "Etc/GMT-0"
      ]
    fixedZones = [("EST", -5), ("MST", -7), ("HST", -10)]
    etcGmt name = case T.stripPrefix "Etc/GMT" name of
      Just rest
        | Just n <- T.stripPrefix "+" rest, valid n, read (T.unpack n) <= (12 :: Integer) -> Just (negate (read (T.unpack n)))
        | Just n <- T.stripPrefix "-" rest, valid n, read (T.unpack n) <= (14 :: Integer) -> Just (read (T.unpack n))
      _ -> Nothing
    valid n = not (T.null n) && T.all isDigit n && T.length n <= 2 && T.head n /= '0'
    offsetPattern name =
      let s = T.unpack name
          s' = if not (null s) && last s == '\n' then init s else s
          (sign, rest) = case s' of
            c : r | c == '+' || c == '-' -> (c, r)
            r -> ('+', r)
          decimal c = pythonDecimal c
          value = foldl' (\acc c -> acc * 10 + fromIntegral (fromMaybe 0 (decimal c))) 0
       in case break (== ':') rest of
            (hh, ':' : mm)
              | length hh `elem` [1, 2]
              , all (isJust . decimal) hh
              , length mm == 2
              , all (isJust . decimal) mm ->
                  let minutes = (value hh * 60 + value mm) * (if sign == '-' then -1 else 1)
                   in if abs minutes >= 24 * 60
                        then Left (PyErr ValueError "offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24).")
                        else Right (minutes * 60)
            _ -> Left (PyErr ValueError ("Unparsable timezone: " <> pythonStrRepr name))
