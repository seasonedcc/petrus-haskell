{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The HTTP seam under the GitHub client, and the httpx behaviors above
-- it that decide what a caller observes.
--
-- An 'Exchange' sends one request and hands the raw response (status,
-- header bytes, a chunk reader) to a continuation; 'realExchange' is the
-- production one over @http-client@ and @http-client-tls@, and tests
-- substitute a scripted one. Everything that turns raw bytes into what the
-- reference sees — header decoding, @Content-Encoding@ decoding, the
-- exception families — lives here so a fake exchange exercises it too.
module Hamsterdan.GitHub.Http
  ( -- * The seam
    HttpRequest (..)
  , RawResponse (..)
  , Exchange (..)
  , realExchange
  , newRealExchange

    -- * Failures
  , ClientError (..)
  , ClientErrorKind (..)
  , transportFailure
  , githubFailure
  , valueFailure
  , runtimeFailure
  , uncaught

    -- * httpx response handling
  , Headers
  , decodeHeaders
  , mergeHeaders
  , asciiHeaders
  , lookupHeader
  , BodyReader
  , contentDecoder
  , readAll
  , readBounded
  ) where

import Control.Exception (Exception, SomeException, bracket, fromException, throwIO, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Codec.Compression.Zlib.Internal qualified as Z
import Network.HTTP.Client qualified as Client
import Network.HTTP.Client.TLS qualified as TLS
import Network.HTTP.Types qualified as HttpTypes
import Hamsterdan.GitHub.Python qualified as Py

-- | One request as httpx puts it on the wire: lowercase header names in
-- httpx's order (including @host@ and, with a body, @content-length@).
data HttpRequest = HttpRequest
  { method :: Text
  , target :: Text
  -- ^ The raw path and query (@url.raw_path@), always beginning with @/@.
  , url :: Text
  -- ^ @str(request.url)@.
  , headers :: [(Text, Text)]
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | A response as the network delivered it.
data RawResponse = RawResponse
  { status :: Int
  , headers :: [(ByteString, ByteString)]
  , readChunk :: IO ByteString
  -- ^ The next raw (still content-encoded) chunk; empty at the end.
  }

-- | Send one request and use its response; the response is released when
-- the continuation returns.
newtype Exchange = Exchange
  { exchange :: forall a. HttpRequest -> (RawResponse -> IO a) -> IO a
  }

-- | Which @except@ clauses of the reference a failure falls into.
data ClientErrorKind
  = -- | @httpx.TransportError@ (detail @http_transport@).
    TransportKind
  | -- | Another @httpx.HTTPError@, such as @DecodingError@.
    HttpKind
  | -- | @githubkit.exception.GitHubException@.
    GitHubKind
  | -- | A @ValueError@ (including pydantic's @ValidationError@ and
    -- @UnicodeEncodeError@).
    ValueKind
  | -- | A @RuntimeError@.
    RuntimeKind
  | -- | An @OSError@.
    OsKind
  | -- | Anything the transport does not catch (such as httpx's
    -- @InvalidURL@).
    UncaughtKind
  deriving stock (Eq, Show)

-- | A failure inside the client stack, carrying the CPython class name the
-- reference would raise.
data ClientError = ClientError
  { kind :: ClientErrorKind
  , pythonClass :: Text
  , detail :: Text
  }
  deriving stock (Eq, Show)

instance Exception ClientError

transportFailure, githubFailure, valueFailure, runtimeFailure, uncaught :: Text -> Text -> ClientError
transportFailure = ClientError TransportKind
githubFailure = ClientError GitHubKind
valueFailure = ClientError ValueKind
runtimeFailure = ClientError RuntimeKind
uncaught = ClientError UncaughtKind

-- | Lowercase names and decoded values, in order.
type Headers = [(Text, Text)]

-- | httpx's header decoding: ASCII when every name and value is ASCII,
-- else UTF-8 when all decode, else ISO-8859-1; names lowercased.
decodeHeaders :: [(ByteString, ByteString)] -> Headers
decodeHeaders raw =
  let decodeWith f = traverse (\(k, v) -> (,) <$> f (lowerBytes k) <*> f v) raw
      ascii b = if BS.all (< 0x80) b then Just (TE.decodeLatin1 b) else Nothing
      utf8 b = either (const Nothing) Just (TE.decodeUtf8' b)
      latin1 = Just . TE.decodeLatin1
   in case decodeWith ascii of
        Just headers -> headers
        Nothing -> maybe (maybe [] id (decodeWith latin1)) id (decodeWith utf8)
  where
    lowerBytes = BS.map (\b -> if b >= 65 && b <= 90 then b + 32 else b)

-- | @headers.items()@ as hishel rebuilds them: one entry per name (values
-- of repeated names joined with @", "@, at the first one's position),
-- without @transfer-encoding@.
mergeHeaders :: Headers -> Headers
mergeHeaders = filter ((/= "transfer-encoding") . fst) . foldl' add []
  where
    add acc (name, value) = case break ((== name) . fst) acc of
      (before, (_, existing) : after) -> before <> ((name, existing <> ", " <> value) : after)
      _ -> acc <> [(name, value)]

-- | httpx re-encodes hishel's string headers as ASCII; anything else is a
-- @UnicodeEncodeError@.
asciiHeaders :: Headers -> IO Headers
asciiHeaders headers = do
  unless (all (\(k, v) -> T.all (< '\x80') k && T.all (< '\x80') v) headers) $
    throwIO (valueFailure "UnicodeEncodeError" "'ascii' codec can't encode a header")
  pure headers

lookupHeader :: Text -> Headers -> Maybe Text
lookupHeader name = lookup (T.toLower name)

-- | A decoded body reader: the next chunk, empty at the end.
type BodyReader = IO ByteString

data Stage = Stage
  { feed :: ByteString -> IO ByteString
  , flush :: IO ByteString
  }

-- | httpx's content decoding for a response's @Content-Encoding@ values:
-- @gzip@ and @deflate@ (zlib-wrapped, falling back to raw on the first
-- chunk), @identity@, and every other value ignored; several are undone
-- in reverse order. A malformed stream is @httpx.DecodingError@;
-- truncation and trailing bytes are not errors, as with @zlib.decompressobj@.
contentDecoder :: Headers -> IO ByteString -> IO BodyReader
contentDecoder headers raw = do
  let values =
        [ T.toLower (Py.strip part)
        | (name, value) <- headers
        , name == "content-encoding"
        , part <- T.splitOn "," value
        ]
  stages <- traverse stage (reverse [v | v <- values, v `elem` ["identity", "gzip", "deflate"]])
  if null stages
    then pure raw
    else do
      finished <- newIORef False
      let feedAll chunk = foldl (\acc s -> acc >>= s.feed) (pure chunk) stages
          flushAll = foldl (\acc s -> do data' <- acc; fed <- s.feed data'; rest <- s.flush; pure (fed <> rest)) (pure "") stages
          next = do
            done <- readIORef finished
            if done
              then pure ""
              else do
                chunk <- raw
                if BS.null chunk
                  then do
                    writeIORef finished True
                    flushAll
                  else do
                    out <- feedAll chunk
                    if BS.null out then next else pure out
      pure next
  where
    stage = \case
      "gzip" -> zlibStage Z.gzipFormat False
      "deflate" -> zlibStage Z.zlibFormat True
      _ -> pure Stage {feed = pure, flush = pure ""}

data ZState = Running (Z.DecompressStream IO) | Ended

zlibStage :: Z.Format -> Bool -> IO Stage
zlibStage format fallback = do
  state <- newIORef . Running =<< pure (Z.decompressIO format Z.defaultDecompressParams)
  firstAttempt <- newIORef True
  let feedChunk chunk = do
        wasFirst <- readIORef firstAttempt
        writeIORef firstAttempt False
        current <- readIORef state
        case current of
          Ended -> pure ""
          Running stream -> do
            outcome <- run stream chunk
            case outcome of
              Right (out, next) -> writeIORef state next >> pure out
              Left message
                | wasFirst && fallback -> do
                    writeIORef state (Running (Z.decompressIO Z.rawFormat Z.defaultDecompressParams))
                    feedChunk chunk
                | otherwise -> throwIO (ClientError HttpKind "DecodingError" message)
      flushStream = do
        current <- readIORef state
        writeIORef state Ended
        case current of
          Ended -> pure ""
          Running stream -> either (const "") fst <$> finish stream
  pure Stage {feed = feedChunk, flush = flushStream}
  where
    -- Feed one chunk and collect output until more input is needed.
    run stream chunk = go stream (Just chunk) []
    go stream pendingInput acc = case stream of
      Z.DecompressInputRequired supply -> case pendingInput of
        Just input -> supply input >>= \s -> go s Nothing acc
        Nothing -> pure (Right (BS.concat (reverse acc), Running stream))
      Z.DecompressOutputAvailable out next -> next >>= \s -> go s pendingInput (out : acc)
      Z.DecompressStreamEnd _ -> pure (Right (BS.concat (reverse acc), Ended))
      Z.DecompressStreamError err -> pure (Left (T.pack (show err)))
    -- Signal end of input; a truncated stream yields what it has.
    finish stream = case stream of
      Z.DecompressInputRequired supply -> supply BS.empty >>= collect []
      other -> collect [] other
    collect acc = \case
      Z.DecompressOutputAvailable out next -> next >>= collect (out : acc)
      Z.DecompressStreamEnd _ -> pure (Right (BS.concat (reverse acc), Ended))
      Z.DecompressStreamError _ -> pure (Right (BS.concat (reverse acc), Ended))
      Z.DecompressInputRequired _ -> pure (Right (BS.concat (reverse acc), Ended))

-- | Read a body to its end.
readAll :: BodyReader -> IO ByteString
readAll reader = BS.concat <$> go []
  where
    go acc = do
      chunk <- reader
      if BS.null chunk then pure (reverse acc) else go (chunk : acc)

-- | Read a body, failing with the given action as soon as more than the
-- limit has arrived.
readBounded :: Int -> IO () -> BodyReader -> IO ByteString
readBounded limit exceeded reader = go 0 []
  where
    go size acc = do
      chunk <- reader
      if BS.null chunk
        then pure (BS.concat (reverse acc))
        else do
          let size' = size + BS.length chunk
          if size' > limit then exceeded >> pure "" else go size' (chunk : acc)

-- | The production exchange: TLS to @api.github.com:443@, no proxy, no
-- redirects, no timeout, raw (undecoded) bodies.
newRealExchange :: IO Exchange
newRealExchange = do
  manager <- TLS.newTlsManagerWith (Client.managerSetProxy Client.noProxy TLS.tlsManagerSettings)
  pure (realExchange manager)

realExchange :: Client.Manager -> Exchange
realExchange manager = Exchange $ \request continue -> do
  let wire =
        Client.defaultRequest
          { Client.method = TE.encodeUtf8 request.method
          , Client.secure = True
          , Client.host = "api.github.com"
          , Client.port = 443
          , Client.path = TE.encodeUtf8 (fst (T.breakOn "?" request.target))
          , Client.queryString = TE.encodeUtf8 (snd (T.breakOn "?" request.target))
          , Client.requestHeaders =
              [ (CI.mk (TE.encodeUtf8 name), TE.encodeUtf8 value)
              | (name, value) <- request.headers
              , name `notElem` ["host", "content-length"]
              ]
          , Client.requestBody = Client.RequestBodyBS request.body
          , Client.redirectCount = 0
          , Client.decompress = const False
          , Client.responseTimeout = Client.responseTimeoutNone
          }
  bracket (guarded (Client.responseOpen wire manager)) Client.responseClose $ \response ->
    continue
      RawResponse
        { status = HttpTypes.statusCode (Client.responseStatus response)
        , headers = [(CI.original name, value) | (name, value) <- Client.responseHeaders response]
        , readChunk = guarded (Client.brRead (Client.responseBody response))
        }
  where
    guarded :: IO a -> IO a
    guarded action =
      try action >>= \case
        Right value -> pure value
        Left (failure :: SomeException)
          | Just (_ :: Client.HttpException) <- fromException failure ->
              throwIO (transportFailure "TransportError" (T.pack (show failure)))
          | otherwise -> throwIO failure
