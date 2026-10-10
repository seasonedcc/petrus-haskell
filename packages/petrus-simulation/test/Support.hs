-- | Shared by the specs and the benchmark: the upstream fixture scenario
-- (@tests/simulation_support.py@), net builders, the atomic export the
-- upstream tests exercise, and a raw HTTP/1.0 client.
module Support
  ( -- * Nets
    a
  , t
  , netOf
  , builtOf
  , buildScenario
  , origin

    -- * Export (@tests/simulation_support.export@)
  , ExportOps (..)
  , defaultExportOps
  , export

    -- * Client
  , Reply (..)
  , exchange
  , exchangeWith
  , parseReply
  , header
  , normalize
  , postRequest
  , getRequest
  , specPath
  ) where

import Control.Exception (IOException, bracket, catch, finally, onException, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.Socket (Family (..), ShutdownCmd (..), SockAddr (..), Socket, SocketType (..), close, connect, defaultProtocol, socket, tupleToHostAddress)
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Simulation (simulate)
import Petrus.TestSupport.Repo (upstreamPath)
import System.Directory (createDirectoryIfMissing, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (Handle, hClose, hFlush, openBinaryTempFile)
import System.Posix.IO (closeFd, handleToFd)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import System.Timeout (timeout)

a, t :: NetPath
a = "a"
t = "t"

netOf :: NetSpec -> Net
netOf spec = either (error . T.unpack) id (mkNet spec)

-- | @BuiltNet(net)@: no implementations.
builtOf :: Net -> BuiltNet
builtOf net = BuiltNet {net, handlers = Map.empty, guards = Map.empty}

-- | @build_scenario()@: the fixed demo build and its initial marking.
buildScenario :: (BuiltNet, Marking)
buildScenario =
  ( builtOf . netOf $
      (netSpec [coloredPlace "pending" "SimulationItem", coloredPlace "done" "SimulationItem"] [finish] [filtered, arc "finish" "done"])
        { name = Just "bounded-simulation-demo"
        , completion = Just (CompletionCel (unsafeCel "size(done) > 0"))
        }
  , markingFromList
      [("pending", [Token (Just "SimulationItem") (Object [("id", String "demo-1"), ("priority", Int 2), ("typed", Bool True)])])]
  )
  where
    finish = (transition "finish") {guards = [GuardCel (unsafeCel "size(pending) > 0")], timers = [Delay (IntNumber 5)]}
    filtered = (arc "pending" "finish") {filter = Just (FilterCel (unsafeCel "priority >= 1"))}

-- | The upstream tests' @ORIGIN@.
origin :: Text
origin = "http://localhost:5173"

-- | A file under @upstream/petrus@.
specPath :: FilePath -> IO FilePath
specPath = upstreamPath

-- ---------------------------------------------------------------------------
-- Export

-- | The file operations @export@ performs, replaceable to inject failures
-- (the upstream tests monkeypatch @os.replace@, @os.fsync@ and the temporary
-- file's @write@).
data ExportOps = ExportOps
  { write :: Handle -> ByteString -> IO ()
  , fsync :: Fd -> IO ()
  , replace :: FilePath -> FilePath -> IO ()
  }

defaultExportOps :: ExportOps
defaultExportOps = ExportOps {write = BS.hPut, fsync = fileSynchronise, replace = renameFile}

-- | @export(destination, max_actions=32)@: simulate the scenario and
-- publish the bytes atomically (a temporary file in the destination's
-- directory, written, flushed, synced, then renamed over the destination;
-- the temporary file is removed on any failure).
export :: ExportOps -> FilePath -> Int -> IO ()
export ops destination maxActions = do
  let (built, marking) = buildScenario
  payload <- simulate built marking maxActions >>= either (throwIO . userError . show) pure
  let directory = takeDirectory destination
  createDirectoryIfMissing True directory
  (temporary, handle) <- openBinaryTempFile directory ("." <> takeFileName destination <> ".tmp")
  let ignore (_ :: IOException) = pure ()
      cleanup = removeFile temporary `catch` ignore
  ( do
      fd <- (ops.write handle payload >> hFlush handle >> handleToFd handle) `onException` (hClose handle `catch` ignore)
      ops.fsync fd `finally` (closeFd fd `catch` ignore)
      ops.replace temporary destination
    )
    `onException` cleanup

-- ---------------------------------------------------------------------------
-- Client

data Reply = Reply
  { status :: Int
  , headers :: [(ByteString, ByteString)]
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | Send raw bytes, half-close, and read the whole response.
exchange :: Int -> ByteString -> IO ByteString
exchange port bytes = exchangeWith port (\sock -> sendAll sock bytes)

exchangeWith :: Int -> (Socket -> IO ()) -> IO ByteString
exchangeWith port send =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    send sock
    Socket.shutdown sock ShutdownSend `catch` \(_ :: IOException) -> pure ()
    let go chunks = do
          chunk <- timeout 20000000 (recv sock 1048576 `catch` \(_ :: IOException) -> pure "")
          case chunk of
            Nothing -> pure (BS.concat (reverse ("<client timeout>" : chunks)))
            Just bytes'
              | BS.null bytes' -> pure (BS.concat (reverse chunks))
              | otherwise -> go (bytes' : chunks)
    go []

parseReply :: ByteString -> Reply
parseReply raw =
  let (head', rest) = BS.breakSubstring "\r\n\r\n" raw
      lines' = splitCrlf head'
      code = case lines' of
        first : _ -> maybe 0 fst (BC.readInt (BC.drop 1 (BC.dropWhile (/= ' ') first)))
        [] -> 0
      fields = [(name, BS.drop 2 value) | line <- drop 1 lines', let (name, value) = BS.breakSubstring ": " line]
   in Reply code fields (BS.drop 4 rest)

header :: ByteString -> Reply -> Maybe ByteString
header name reply = lookup (lower name) [(lower k, v) | (k, v) <- reply.headers]
  where
    lower = BC.map toLower

-- | A raw response without its @Server@ and @Date@ lines.
normalize :: ByteString -> ByteString
normalize raw =
  let (head', rest) = BS.breakSubstring "\r\n\r\n" raw
      kept = filter (\line -> not ("Server: " `BS.isPrefixOf` line || "Date: " `BS.isPrefixOf` line)) (splitCrlf head')
   in BS.intercalate "\r\n" kept <> rest

splitCrlf :: ByteString -> [ByteString]
splitCrlf bytes = case BS.breakSubstring "\r\n" bytes of
  (before, after)
    | BS.null after -> [before]
    | otherwise -> before : splitCrlf (BS.drop 2 after)

-- | What @urllib@ sends for the upstream tests' @request(url, method=…,
-- body=…, origin=…)@ (HTTP/1.1, @Host@, the @Origin@, and the
-- @Content-Type@ and @Content-Length@ of a body).
postRequest :: ByteString -> Maybe Text -> ByteString -> ByteString
postRequest target requestOrigin payload =
  "POST "
    <> target
    <> " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    <> maybe "" (\o -> "Origin: " <> TE.encodeUtf8 o <> "\r\n") requestOrigin
    <> "Content-Type: application/json\r\nContent-Length: "
    <> BC.pack (show (BS.length payload))
    <> "\r\n\r\n"
    <> payload

getRequest :: ByteString -> ByteString -> Maybe Text -> ByteString
getRequest method target requestOrigin =
  method <> " " <> target <> " HTTP/1.1\r\nHost: 127.0.0.1\r\n" <> maybe "" (\o -> "Origin: " <> TE.encodeUtf8 o <> "\r\n") requestOrigin <> "\r\n"
