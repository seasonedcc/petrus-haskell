-- | IANA time zones, as @zoneinfo.ZoneInfo@ resolves and applies them for
-- cel-python's @get*@ accessors (@pendulum.timezone@ is @ZoneInfo@ under
-- another name).
--
-- The zones are the pinned reference's @tzdata@ package (2026.3, IANA
-- 2026c), embedded by @gen/gen-tz-tables.py@ in "Petrus.Cel.Tz.Tables", so
-- an answer never depends on the host's tz database. A key resolves as
-- ZoneInfo resolves it with an empty @TZPATH@:
--
-- * @_tzpath._validate_tzfile_path@ refuses absolute keys, keys that
--   @posixpath.normpath@ would shorten, and keys that leave the base
--   directory, with its three @ValueError@s;
-- * @_common.load_tzdata@ imports the key's directories as the dotted
--   package @tzdata.zoneinfo.<dirs>@, so a dot in a directory component
--   separates packages too, and @__init__@ names the package's own module
--   (whose resources are the package directory's); a missing package, a
--   directory as the resource, and a name the file system cannot encode are
--   @ZoneInfoNotFoundError@; a NUL in the resource name is @ValueError@;
-- * a resource that is not a TZif file raises @load_data@'s @ValueError@.
--
-- A zone converts a UTC instant as CPython's C @zoneinfo_fromutc@ does: the
-- first non-DST offset before the first transition, the offset of the last
-- transition at or before the instant, and past the last transition the TZ
-- string rule, evaluated in the instant's UTC year.
module Petrus.Cel.Tz
  ( Zone
  , lookupZone
  , zoneUtcOffset
  , tzdataVersion
  ) where

import Data.Array (Array, listArray, (!))
import Data.Array.Unboxed (UArray)
import Data.Array.Unboxed qualified as U
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Cel.Python (ExcClass (..), PyErr (..))
import Petrus.Cel.Tz.Tables qualified as Tables
import Petrus.Posix.Path qualified as Path

-- | One zone: what C @_zoneinfo@ keeps of a TZif file for @fromutc@.
data Zone = Zone
  { zoneBefore :: Int
  -- ^ @ttinfo_before@'s offset, in seconds
  , zoneTimes :: UArray Int Int
  -- ^ the transitions, in Unix seconds, ascending
  , zoneOffsets :: UArray Int Int
  -- ^ the offset each transition starts
  , zoneAfter :: After
  }

-- | @tzrule_after@.
data After
  = AfterFixed Int
  | -- | standard and DST offsets, DST start and end (local time)
    AfterRule Int Int Rule Rule

-- | A TZ string transition: @Jn@ (julian, 1-based, never February 29th)
-- or @n@ (0-based) with its time, or @Mm.w.d@ with its time.
data Rule
  = DayRule Bool Int Int
  | DateRule Int Int Int Int

-- | The IANA release and the @tzdata@ package version embedded.
tzdataVersion :: (Text, Text)
tzdataVersion = let (iana, package) = Tables.tzdataVersion in (T.pack iana, T.pack package)

-- | @ZoneInfo(key)@ with an empty @TZPATH@: the zone, 'Nothing' for
-- @ZoneInfoNotFoundError@ (pendulum's @InvalidTimezone@), or the
-- @ValueError@ ZoneInfo raises.
lookupZone :: Text -> Either PyErr (Maybe Zone)
lookupZone key = do
  validateKey key
  let components = T.splitOn "/" key
      parts = concatMap (T.splitOn ".") (init components)
  case packageDirectory parts of
    Nothing -> Right Nothing
    Just directory -> resource (directory `under` last components)

-- | @_tzpath._validate_tzfile_path@.
validateKey :: Text -> Either PyErr ()
validateKey key
  | "/" `T.isPrefixOf` key = invalid "ZoneInfo keys may not be absolute paths, got: "
  | T.length normal /= T.length key = invalid "ZoneInfo keys must be normalized relative paths, got: "
  | not ("_/" `T.isPrefixOf` normpath ("_/" <> normal)) = invalid "ZoneInfo keys must refer to subdirectories of TZPATH, got: "
  | otherwise = Right ()
  where
    normal = normpath key
    invalid message = Left (PyErr ValueError (message <> key))

-- | @posixpath.normpath@ of a key.
normpath :: Text -> Text
normpath = T.pack . Path.normpath . T.unpack

-- | The directory @importlib.resources.files@ gives for the package
-- @tzdata.zoneinfo.<parts>@, or 'Nothing' when the import fails.
packageDirectory :: [Text] -> Maybe Text
packageDirectory = go ""
  where
    go directory = \case
      [] -> Just directory
      -- The package's @__init__.py@, imported as a module of its own: its
      -- resources are the package directory's, and it has no submodules.
      ["__init__"] -> Just directory
      part : rest
        | Set.member (directory `under` part) directories -> go (directory `under` part) rest
        | otherwise -> Nothing

under :: Text -> Text -> Text
under "" name = name
under directory name = directory <> "/" <> name

-- | Open the resource at a path of the package, as @load_tzdata@ does.
resource :: Text -> Either PyErr (Maybe Zone)
resource path
  -- @os.fsencode@ cannot spell a surrogate outside U+DC80..U+DCFF
  -- (@UnicodeEncodeError@), and it encodes before it looks for a NUL. The
  -- surrogates inside that range spell bytes no tzdata file name has.
  | T.any (\c -> c >= '\xD800' && c <= '\xDFFF' && not (c >= '\xDC80' && c <= '\xDCFF')) name = Right Nothing
  | T.any (== '\0') name = Left (PyErr ValueError "embedded null byte")
  | otherwise = case Map.lookup path resources of
      Just (Right zone) -> Right (Just zone)
      Just (Left message) -> Left (PyErr ValueError message)
      Nothing -> Right Nothing
  where
    name = snd (T.breakOnEnd "/" path)

directories :: Set.Set Text
directories = Set.fromList (map T.pack (words Tables.tzDirectories))
{-# NOINLINE directories #-}

-- | Every resource file; a zone is decoded on its first use.
resources :: Map.Map Text (Either Text Zone)
resources =
  Map.fromList
    [ entry
    | word <- words Tables.tzResources
    , entry <- case break (`elem` ("=!" :: String)) word of
        (path, '=' : n) -> [(T.pack path, Right (zones ! int n))]
        (path, '!' : n) -> [(T.pack path, Left (T.pack (Tables.tzErrors !! int n)))]
        _ -> malformed word
    ]
{-# NOINLINE resources #-}

zones :: Array Int Zone
zones =
  let entries = splitOn ';' Tables.tzZones
   in listArray (0, length entries - 1) (map decodeZone entries)
{-# NOINLINE zones #-}

decodeZone :: String -> Zone
decodeZone entry = case splitOn '|' entry of
  [before, after, offsets, transitions] ->
    let table = listArray' (map int (filter (not . null) (splitOn ',' offsets)))
        steps = [(int delta, int index) | step <- words transitions, (delta, ':' : index) <- [break (== ':') step]]
        times = scanl1 (+) (map fst steps)
     in Zone
          { zoneBefore = int before
          , zoneTimes = listArray' times
          , zoneOffsets = listArray' [table U.! i | (_, i) <- steps]
          , zoneAfter = decodeAfter after
          }
  _ -> malformed entry
  where
    listArray' :: [Int] -> UArray Int Int
    listArray' xs = U.listArray (0, length xs - 1) xs

decodeAfter :: String -> After
decodeAfter = \case
  'F' : offset -> AfterFixed (int offset)
  'R' : rule
    | [std, dst, start, end] <- splitOn ',' rule -> AfterRule (int std) (int dst) (decodeRule start) (decodeRule end)
  other -> malformed other

decodeRule :: String -> Rule
decodeRule text = case break (== '@') text of
  ('J' : day, '@' : time) -> DayRule True (int day) (int time)
  ('N' : day, '@' : time) -> DayRule False (int day) (int time)
  ('M' : date, '@' : time)
    | [m, w, d] <- splitOn '.' date -> DateRule (int m) (int w) (int d) (int time)
  _ -> malformed text

-- | 'error' on a malformed entry: the tables are compiled-in constants.
int :: String -> Int
int s = case reads s of
  [(v, "")] -> v
  _ -> malformed s

malformed :: String -> a
malformed s = error ("Petrus.Cel.Tz: bad table entry " <> show (take 80 s))

splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
  (a, _ : rest) -> a : splitOn sep rest
  (a, []) -> [a]

-- | The zone's UTC offset, in seconds, at a Unix time in seconds: C
-- @zoneinfo_fromutc@'s choice of @ttinfo@.
zoneUtcOffset :: Zone -> Int -> Int
zoneUtcOffset zone ts
  | count >= 1 && ts < zoneTimes zone U.! 0 = zoneBefore zone
  | count == 0 || ts > zoneTimes zone U.! (count - 1) = afterOffset (zoneAfter zone) ts
  | otherwise = zoneOffsets zone U.! (bisectRight 0 count - 1)
  where
    count = snd (U.bounds (zoneTimes zone)) + 1
    -- The first index whose transition is after @ts@.
    bisectRight lo hi
      | lo >= hi = lo
      | otherwise =
          let mid = (lo + hi) `div` 2
           in if ts < zoneTimes zone U.! mid then bisectRight lo mid else bisectRight (mid + 1) hi

-- | @find_tzrule_ttinfo_fromutc@: the rule's transitions are local times,
-- standard time before the start and DST before the end.
afterOffset :: After -> Int -> Int
afterOffset (AfterFixed offset) _ = offset
afterOffset (AfterRule std dst start end) ts =
  let year = utcYear ts
      from = ruleEpoch start year - std
      to = ruleEpoch end year - dst
      isDst
        | from < to = from <= ts && ts < to
        | otherwise = not (to <= ts && ts < from)
   in if isDst then dst else std

-- | @_DayOffset.year_to_epoch@ / @_CalendarOffset.year_to_epoch@.
ruleEpoch :: Rule -> Int -> Int
ruleEpoch rule year = case rule of
  DayRule julian day time ->
    let day' = if julian && day >= 59 && leap then day + 1 else day
     in (daysBeforeYear + day') * 86400 + time
  DateRule month week weekday time ->
    let firstDay = (daysBeforeYear + daysBeforeMonth month + leapShift month + 1 + 3) `mod` 7
        candidate = (weekday - (firstDay + 1)) `mod` 7 + 1 + (week - 1) * 7
        monthDay = if candidate > monthLength month then candidate - 7 else candidate
     in (daysBeforeYear + daysBeforeMonth month + leapShift month + monthDay) * 86400 + time
  where
    leap = (year `mod` 4 == 0 && year `mod` 100 /= 0) || year `mod` 400 == 0
    -- @_post_epoch_days_before_year@: 1970 gives -1.
    daysBeforeYear = let y = year - 1 in y * 365 + y `div` 4 - y `div` 100 + y `div` 400 - 719163
    daysBeforeMonth m = [-1, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334] !! m
    leapShift m = if m > 2 && leap then 1 else 0
    monthLength m
      | m == 2 = if leap then 29 else 28
      | m `elem` [4, 6, 9, 11] = 30
      | otherwise = 31

-- | The UTC year of a Unix time.
utcYear :: Int -> Int
utcYear ts =
  -- Howard Hinnant's civil_from_days.
  let z = ts `div` 86400 + 719468
      era = z `div` 146097
      doe = z - era * 146097
      yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
      doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
      mp = (5 * doy + 2) `div` 153
      month = if mp < 10 then mp + 3 else mp - 9
   in yoe + era * 400 + (if month <= 2 then 1 else 0)
