{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The HTTP cache GitHubKit puts under every request: hishel 1.3's
-- RFC 9111 'SpecificationPolicy' as a private cache, over an in-memory
-- store shared by every client of one process.
--
-- Hamsterdan's requests always carry @Cache-Control: no-cache@, so the
-- cache never answers on its own; what it does is decide the conditional
-- headers of a repeated @GET@ (@If-None-Match@, @If-Modified-Since@), turn
-- a matching @304@ into the stored response with refreshed headers, and
-- hide entries whose body was not read to its end. Those are observable on
-- the wire and in results, so they are reproduced here step for step,
-- including the failures hishel raises on unparseable dates.
module Hamsterdan.GitHub.Cache
  ( -- * Store
    CacheStore
  , newCacheStore

    -- * Messages
  , CacheRequest (..)
  , CacheResponse (..)
  , Sender

    -- * The policy
  , cachedSend

    -- * Pieces (exported for tests)
  , CacheControl (..)
  , NoCache (..)
  , parseCacheControl
  , parseDate
  , parsedateTz
  , headerGet
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM, forM_)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (DecimalNumber), generalCategory, ord)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorianValid, toModifiedJulianDay)
import Hamsterdan.GitHub.Http (ClientError (..), Headers, runtimeFailure, valueFailure)
import Hamsterdan.Python qualified as Py

-- | A request as hishel sees it: the method, @str(url)@ and the request
-- headers (lowercase names, one value each).
data CacheRequest = CacheRequest
  { method :: Text
  , url :: Text
  , requestHeaders :: Headers
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | A response as hishel sees it: raw (still content-encoded) chunks.
data CacheResponse = CacheResponse
  { status :: Int
  , responseHeaders :: Headers
  , chunks :: IO ByteString
  -- ^ The next raw chunk; empty at the end.
  }

-- | hishel's @request_sender@: send one request and use its response
-- inside the continuation.
type Sender = forall a. CacheRequest -> (CacheResponse -> IO a) -> IO a

data Entry = Entry
  { storedRequest :: CacheRequest
  , storedStatus :: Int
  , storedHeaders :: Headers
  , content :: [ByteString]
  , complete :: Bool
  , deleted :: Bool
  }

data StoreState = StoreState
  { nextId :: Int
  , keys :: Map Text [Int]
  -- ^ Entry ids per cache key, in insertion order.
  , entries :: Map Int Entry
  }

-- | GitHubKit's @SyncMemoryStorage@: in memory, never expiring, shared by
-- every client built over the same cache strategy.
newtype CacheStore = CacheStore (IORef StoreState)

newCacheStore :: IO CacheStore
newCacheStore = CacheStore <$> newIORef (StoreState 0 Map.empty Map.empty)

-- | @headers.get(name)@.
headerGet :: Text -> Headers -> Maybe Text
headerGet name = lookup (T.toLower name)

has :: Text -> Headers -> Bool
has name = isJust . headerGet name

cacheKey :: Text -> Text
cacheKey url = T.pack (show (hashWith SHA256 (TE.encodeUtf8 url)))

-- | @storage.get_entries(key)@: the complete, live entries in insertion
-- order.
liveEntries :: CacheStore -> Text -> IO [(Int, Entry)]
liveEntries (CacheStore ref) key = do
  state <- readIORef ref
  pure
    [ (entryId, entry)
    | entryId <- Map.findWithDefault [] key state.keys
    , Just entry <- [Map.lookup entryId state.entries]
    , entry.complete
    , not entry.deleted
    ]

modifyEntry :: CacheStore -> Int -> (Entry -> Entry) -> IO ()
modifyEntry (CacheStore ref) entryId change =
  atomicModifyIORef' ref (\state -> (state {entries = Map.adjust change entryId state.entries}, ()))

-- | @storage.create_entry@: the entry exists at once but is only visible
-- once its body has been read to the end; the returned reader records the
-- chunks and completes it.
createEntry :: CacheStore -> Text -> CacheRequest -> CacheResponse -> IO CacheResponse
createEntry store@(CacheStore ref) key request response = do
  entryId <- atomicModifyIORef' ref $ \state ->
    let entryId = state.nextId
        entry = Entry {storedRequest = request, storedStatus = response.status, storedHeaders = response.responseHeaders, content = [], complete = False, deleted = False}
     in ( state
            { nextId = entryId + 1
            , keys = Map.insertWith (\new old -> old <> new) key [entryId] state.keys
            , entries = Map.insert entryId entry state.entries
            }
        , entryId
        )
  collected <- newIORef []
  finished <- newIORef False
  let next = do
        done <- readIORef finished
        if done
          then pure ""
          else do
            chunk <- response.chunks
            if BS.null chunk
              then do
                writeIORef finished True
                chunksSoFar <- readIORef collected
                modifyEntry store entryId (\entry -> entry {content = reverse chunksSoFar, complete = True})
                pure ""
              else do
                atomicModifyIORef' collected (\acc -> (chunk : acc, ()))
                pure chunk
  pure response {chunks = next}

-- | Replay a stored body.
replay :: [ByteString] -> IO (IO ByteString)
replay stored = do
  remaining <- newIORef stored
  pure $ atomicModifyIORef' remaining $ \case
    [] -> ([], "")
    chunk : rest -> (rest, chunk)

-- | @SyncCacheProxy._handle_request_respecting_spec@ with
-- @SpecificationPolicy(CacheOptions(shared=False))@.
--
-- The clock is @time.time()@, which orders entries without a @Date@.
cachedSend :: CacheStore -> IO Double -> Sender -> CacheRequest -> (CacheResponse -> IO a) -> IO a
cachedSend store clock send request continue = do
  let key = cacheKey request.url
  stored <- liveEntries store key
  if T.toUpper request.method `notElem` ["GET", "HEAD", "OPTIONS", "TRACE"]
    then send request (\response -> cacheMiss store key request request response >>= continue)
    else do
      let candidates = [(entryId, entry) | (entryId, entry) <- stored, entry.storedRequest.url == request.url, entry.storedRequest.method == request.method]
      -- Every candidate needs revalidation (the request says no-cache),
      -- but hishel still computes each one's freshness first, and that can
      -- fail.
      forM_ candidates $ \(_, entry) -> do
        _ <- either throwIO pure (freshnessLifetime clock entry.storedHeaders)
        either throwIO pure (ageCheck entry.storedHeaders)
      now <- clock
      keyed <- forM candidates $ \candidate@(_, entry) -> do
        stamp <- either throwIO pure (dateKey now entry.storedHeaders)
        pure (stamp, candidate)
      let revalidating = map snd (sortOn (Down . fst) keyed)
      case revalidating of
        [] -> send request (\response -> cacheMiss store key request request response >>= continue)
        (_, newest) : _ -> do
          let conditions =
                [("if-none-match", etag) | Just etag <- [headerGet "etag" newest.storedHeaders]]
                  <> [("if-modified-since", modified) | Just modified <- [headerGet "last-modified" newest.storedHeaders], not (T.null modified)]
              conditional = request {requestHeaders = foldl (\hs (k, v) -> setHeader k v hs) request.requestHeaders conditions}
          send conditional $ \response ->
            revalidated store key request revalidating response >>= \case
              Just answer -> continue answer
              -- No stored response matched the 304: a cache miss that
              -- sends the original request again.
              Nothing -> send request (\again -> cacheMiss store key request request again >>= continue)

setHeader :: Text -> Text -> Headers -> Headers
setHeader name value headers = case break ((== name) . fst) headers of
  (before, _ : after) -> before <> ((name, value) : after)
  _ -> headers <> [(name, value)]

-- | @NeedRevalidation.next@; 'Nothing' is the @CacheMiss@ that follows a
-- 304 matching no stored response.
revalidated :: CacheStore -> Text -> CacheRequest -> [(Int, Entry)] -> CacheResponse -> IO (Maybe CacheResponse)
revalidated store key original revalidating response
  | response.status == 304 = freshen store key revalidating response
  | response.status `div` 100 == 2 || response.status `div` 100 == 5 = do
      let decision = missDecision original response
      invalidate store (map fst (init revalidating))
      Just <$> apply store key original decision response
  | otherwise =
      let (_, lastEntry) = last revalidating
       in Just <$> apply store key original (missDecision lastEntry.storedRequest response) response

invalidate :: CacheStore -> [Int] -> IO ()
invalidate store ids = forM_ ids $ \entryId -> modifyEntry store entryId (\entry -> entry {deleted = True})

-- | @NeedRevalidation.freshening_stored_responses@.
freshen :: CacheStore -> Text -> [(Int, Entry)] -> CacheResponse -> IO (Maybe CacheResponse)
freshen store _ revalidating response = do
  let partitionBy p = (filter (p . snd) revalidating, filter (not . p . snd) revalidating)
      (matched, unmatched) = case headerGet "etag" response.responseHeaders of
        Just etag
          | not ("W/" `T.isPrefixOf` etag) ->
              partitionBy (\entry -> maybe False (\stored -> opaque stored == etag) (headerGet "etag" entry.storedHeaders))
        _ -> case headerGet "last-modified" response.responseHeaders of
          Just modified
            | not (T.null modified) ->
                partitionBy (\entry -> headerGet "last-modified" entry.storedHeaders == Just modified)
          _ -> case revalidating of
            [single] -> ([single], [])
            _ -> ([], revalidating)
  refreshed <- forM matched $ \(entryId, entry) -> do
    let merged = refreshHeaders entry.storedHeaders response.responseHeaders
    pure (entryId, entry {storedHeaders = merged})
  invalidate store (map fst unmatched)
  case refreshed of
    [] -> pure Nothing
    _ -> do
      forM_ refreshed $ \(entryId, entry) -> modifyEntry store entryId (\current -> current {storedHeaders = entry.storedHeaders})
      let (_, chosen) = last refreshed
      reader <- replay chosen.content
      pure (Just CacheResponse {status = chosen.storedStatus, responseHeaders = chosen.storedHeaders, chunks = reader})
  where
    opaque value =
      let stripped = Py.strip value
       in if "W/" `T.isPrefixOf` stripped || "w/" `T.isPrefixOf` stripped then T.drop 2 stripped else stripped

-- | @refresh_response_headers@.
refreshHeaders :: Headers -> Headers -> Headers
refreshHeaders stored revalidation =
  let incoming = [(k, v) | (k, v) <- revalidation, k `notElem` ["content-encoding", "content-type", "content-range"]]
   in excludeUnstorable (foldl (\hs (k, v) -> setHeader k v hs) stored incoming)

-- | What @CacheMiss.next@ decided.
data MissDecision = Store Headers | DoNotStore

-- | @CacheMiss(request).next(response)@'s storability test.
missDecision :: CacheRequest -> CacheResponse -> MissDecision
missDecision request response =
  let control = parseCacheControl (headerGet "cache-control" response.responseHeaders)
      storable =
        T.toUpper request.method `elem` ["GET", "HEAD"]
          && response.status `div` 100 /= 1
          && response.status `notElem` [206, 304]
          && not control.noStore
          && ( control.public
                || privateTruthy control.private
                || has "expires" response.responseHeaders
                || isJust control.maxAge
                || response.status `elem` [200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501]
             )
   in if storable then Store (excludeUnstorable response.responseHeaders) else DoNotStore
  where
    privateTruthy = \case
      Flag b -> b
      Fields fields -> not (null fields)

apply :: CacheStore -> Text -> CacheRequest -> MissDecision -> CacheResponse -> IO CacheResponse
apply store key original decision response = case decision of
  DoNotStore -> pure response
  Store headers -> createEntry store key original response {responseHeaders = headers}

cacheMiss :: CacheStore -> Text -> CacheRequest -> CacheRequest -> CacheResponse -> IO CacheResponse
cacheMiss store key original judged response = apply store key original (missDecision judged response) response

-- | @exclude_unstorable_headers@ for a private cache.
excludeUnstorable :: Headers -> Headers
excludeUnstorable headers =
  let control = parseCacheControl (headerGet "cache-control" headers)
      extra = case control.noCache of
        Fields fields -> map T.toLower fields
        Flag _ -> []
      excluded = ["connection", "keep-alive", "te", "transfer-encoding", "upgrade", "proxy-connection", "proxy-authenticate", "proxy-authentication-info", "proxy-authorization"] <> extra
   in [(k, v) | (k, v) <- headers, T.toLower k `notElem` excluded]

-- | @get_freshness_lifetime@ for a private cache; only its failures matter
-- here, since every entry is revalidated.
freshnessLifetime :: IO Double -> Headers -> Either ClientError ()
freshnessLifetime _ headers =
  let control = parseCacheControl (headerGet "cache-control" headers)
   in if isJust control.maxAge
        then Right ()
        else case headerGet "expires" headers of
          Just expires -> do
            parsed <- parseDate expires
            case parsed of
              Nothing -> Left (runtimeFailure "RuntimeError" "Cannot parse Expires header")
              Just _ -> () <$ traverse parseDate (headerGet "date" headers)
          Nothing -> case headerGet "last-modified" headers of
            Just modified | not (T.null modified) -> () <$ parseDate modified
            _ -> Right ()

-- | @get_age@'s failures.
ageCheck :: Headers -> Either ClientError ()
ageCheck headers = () <$ traverse parseDate (headerGet "date" headers)

-- | @_date_key@: the parsed @Date@, or now.
dateKey :: Double -> Headers -> Either ClientError Integer
dateKey now headers = do
  let fallback = truncate now :: Integer
  parsed <- parseDate (fromMaybe (T.pack (show fallback)) (headerGet "date" headers))
  pure $ case parsed of
    Just stamp | stamp /= 0 -> stamp
    _ -> fallback

-- | hishel's @parse_date@: @email.utils.parsedate_tz@ then
-- @calendar.timegm@ of its first six fields (the zone is ignored).
-- 'Left' is the @ValueError@ @timegm@ raises for a year outside 1–9999.
parseDate :: Text -> Either ClientError (Maybe Integer)
parseDate value = case parsedateTz value of
  Nothing -> Right Nothing
  Just (year, month, day, hour, minute, second) ->
    case if year < 1 || year > 9999 then Nothing else fromGregorianValid year month 1 of
      Nothing -> Left (valueFailure "ValueError" ("year must be in 1..9999, not " <> T.pack (show year)))
      Just first ->
        let days = toModifiedJulianDay first - 40587 + day - 1
         in Right (Just (((days * 24 + hour) * 60 + minute) * 60 + second))

-- | @email._parseaddr._parsedate_tz@'s date and time fields.
parsedateTz :: Text -> Maybe (Integer, Int, Integer, Integer, Integer, Integer)
parsedateTz input = do
  let tokens0 = splitWords input
  first : rest0 <- Just tokens0
  let tokens1
        | "," `T.isSuffixOf` first || T.toLower first `elem` dayNames = rest0
        | otherwise = case T.breakOnEnd "," first of
            (before, after) | not (T.null before) -> after : rest0
            _ -> first : rest0
      tokens2 = case tokens1 of
        [a, b, c] -> case T.splitOn "-" a of
          stuff@[_, _, _] -> stuff <> [b, c]
          _ -> tokens1
        _ -> tokens1
      tokens3 = case tokens2 of
        [a, b, c, s] ->
          let i = case T.findIndex (== '+') s of
                Just n -> n
                Nothing -> fromMaybe (-1) (T.findIndex (== '-') s)
           in if i > 0 then [a, b, c, T.take i s, T.drop i s] else [a, b, c, s, ""]
        _ -> tokens2
  dd0 : mm0 : yy0 : tm0 : tz0 : _ <- Just tokens3
  if T.null dd0 || T.null mm0 || T.null yy0 then Nothing else Just ()
  (dd1, mmName) <-
    let lowered = T.toLower mm0
     in if lowered `elem` monthNames
          then Just (dd0, lowered)
          else if T.toLower dd0 `elem` monthNames then Just (lowered, T.toLower dd0) else Nothing
  let monthIndex = length (takeWhile (/= mmName) monthNames) + 1
      month = if monthIndex > 12 then monthIndex - 12 else monthIndex
      dd2 = if "," `T.isSuffixOf` dd1 then T.dropEnd 1 dd1 else dd1
      (yy1, tm1) = case T.findIndex (== ':') yy0 of
        Just i | i > 0 -> (tm0, yy0)
        _ -> (yy0, tm0)
  yy2 <-
    if "," `T.isSuffixOf` yy1
      then let trimmed = T.dropEnd 1 yy1 in if T.null trimmed then Nothing else Just trimmed
      else Just yy1
  let (yy3, _tz) = case T.uncons yy2 of
        Just (c, _) | not (pyIsDigit c) -> (tz0, yy2)
        _ -> (yy2, tz0)
      tm2 = if "," `T.isSuffixOf` tm1 then T.dropEnd 1 tm1 else tm1
  (thh, tmm, tss) <- case T.splitOn ":" tm2 of
    [h, m] -> Just (h, m, "0")
    [h, m, s] -> Just (h, m, s)
    [single] | T.any (== '.') single -> case T.splitOn "." single of
      [h, m] -> Just (h, m, "0")
      [h, m, s] -> Just (h, m, s)
      _ -> Nothing
    _ -> Nothing
  year0 <- Py.pyIntBase 10 yy3
  day <- Py.pyIntBase 10 dd2
  hour <- Py.pyIntBase 10 thh
  minute <- Py.pyIntBase 10 tmm
  second <- Py.pyIntBase 10 tss
  let year
        | year0 < 100 = if year0 > 68 then year0 + 1900 else year0 + 2000
        | otherwise = year0
  Just (year, month, day, hour, minute, second)
  where
    splitWords = filter (not . T.null) . T.split Py.isSpace
    dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    monthNames =
      [ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
      , "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"
      ]

-- | @str.isdigit()@ for one character: decimal digits plus the common
-- superscript, subscript and circled digits (Numeric_Type=Digit).
pyIsDigit :: Char -> Bool
pyIsDigit c =
  generalCategory c == DecimalNumber
    || c `elem` ['\xb2', '\xb3', '\xb9', '\x2070']
    || (c >= '\x2074' && c <= '\x2079')
    || (c >= '\x2080' && c <= '\x2089')
    || (c >= '\x2460' && c <= '\x2468')
    || (c >= '\x2474' && c <= '\x247c')
    || (c >= '\x2488' && c <= '\x2490')
    || (c >= '\x24f5' && c <= '\x24fd')
    || c == '\x24ea'
    || c == '\x24ff'
    || (c >= '\x2776' && c <= '\x277e')
    || (c >= '\x2780' && c <= '\x2788')
    || (c >= '\x278a' && c <= '\x2792')
    || (c >= '\x1369' && c <= '\x1371')
    || c == '\x19da'

-- | A @no-cache@ or @private@ directive: absent/bare, or with field names.
data NoCache = Flag Bool | Fields [Text]
  deriving stock (Eq, Show)

-- | The directives hishel's policy consults.
data CacheControl = CacheControl
  { maxAge :: Maybe Integer
  , noStore :: Bool
  , public :: Bool
  , noCache :: NoCache
  , private :: NoCache
  }
  deriving stock (Eq, Show)

-- | hishel's @parse_cache_control@.
parseCacheControl :: Maybe Text -> CacheControl
parseCacheControl = \case
  Nothing -> empty
  Just value -> go empty value
  where
    empty = CacheControl {maxAge = Nothing, noStore = False, public = False, noCache = Flag False, private = Flag False}
    go cc text0 =
      let text1 = T.dropWhile (`elem` [' ', '\t', ',']) text0
       in if T.null text1
            then cc
            else
              let (tokenText, afterToken) = T.span isToken text1
               in if T.null tokenText
                    then go cc (T.drop 1 text1)
                    else
                      let token = T.toLower tokenText
                          fields = token == "no-cache" || token == "private"
                          afterSpace = T.dropWhile (`elem` [' ', '\t']) afterToken
                       in case T.uncons afterSpace of
                            Just ('=', valueStart0) ->
                              let valueStart = T.dropWhile (`elem` [' ', '\t']) valueStart0
                               in case T.uncons valueStart of
                                    Nothing -> cc
                                    Just ('"', _) -> case httpUnquote valueStart of
                                      Nothing -> go cc (T.drop 1 valueStart)
                                      Just (result, rest) -> go (withValue cc token result) rest
                                    Just _ ->
                                      let stops = if fields then [' ', '\t'] else [' ', '\t', ',']
                                          (raw, rest) = T.break (`elem` stops) valueStart
                                          result = if "," `T.isSuffixOf` raw then T.dropEnd 1 raw else raw
                                       in go (withValue cc token result) rest
                            _ -> go (withoutValue cc token) afterSpace
    isToken c = c <= '\x7f' && c > '\x1f' && c /= '\x7f' && c `notElem` ("()<>@,;:\\\"/[]?={} \t" :: String)
    withValue cc token value = case token of
      "max-age" -> cc {maxAge = intValue value}
      "no-cache" -> cc {noCache = Fields (fieldNames value)}
      "private" -> cc {private = Fields (fieldNames value)}
      _ -> cc
    withoutValue cc token = case token of
      "no-cache" -> cc {noCache = Flag True}
      "private" -> cc {private = Flag True}
      "no-store" -> cc {noStore = True}
      "public" -> cc {public = True}
      _ -> cc
    intValue value = case Py.pyIntBase 10 value of
      Just n | n >= 0 -> Just (min n 2147483647)
      _ -> Nothing
    fieldNames value =
      [ T.intercalate "-" (map capitalize (T.splitOn "-" field))
      | field <- map Py.strip (T.splitOn "," value)
      , not (T.null field)
      ]
    capitalize word = case T.uncons word of
      Nothing -> ""
      Just (c, rest) -> T.toTitle (T.singleton c) <> T.toLower rest

-- | @http_unquote@: the unquoted value and the rest after the closing
-- quote.
httpUnquote :: Text -> Maybe (Text, Text)
httpUnquote raw = go (T.drop 1 raw) []
  where
    go text acc = case T.uncons text of
      Nothing -> Nothing
      Just ('"', rest) -> Just (T.pack (reverse acc), rest)
      Just ('\\', rest) -> case T.uncons rest of
        Nothing -> Nothing
        Just (c, rest') -> go rest' (pair c : acc)
      Just (c, rest) -> go rest ((if qdText c then c else '?') : acc)
    pair c = let b = ord c in if b == 0x09 || b == 0x20 || (b >= 0x21 && b <= 0x7e) || b >= 0x80 then c else '?'
    qdText c =
      let b = ord c
       in b == 0x09 || b == 0x20 || b == 0x21 || (b >= 0x23 && b <= 0x5b) || (b >= 0x5d && b <= 0x7e) || b >= 0x80

