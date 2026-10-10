-- | Shared by the specs and the benchmark: the upstream test's Engine, a
-- running server, and a raw HTTP/1.0 client.
module Support
  ( -- * Engines
    a
  , b
  , move
  , observationNet
  , makeEngine

    -- * Servers
  , withObservation
  , withObservationDoors

    -- * Client
  , Reply (..)
  , exchange
  , request
  , requestWith
  , parseReply
  , header
  , normalize
  ) where

import Control.Exception (IOException, bracket, catch)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.Text qualified as T
import Network.Socket
  ( Family (..)
  , ShutdownCmd (..)
  , SockAddr (..)
  , SocketType (..)
  , close
  , connect
  , defaultProtocol
  , socket
  , tupleToHostAddress
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet (Net, NetPath, NetSpec (..), Token (..), arc, markingFromList, mkNet, netSpec, place, transition)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Observation.Http
import System.Timeout (timeout)

a, b, move :: NetPath
a = "a"
b = "b"
move = "move"

-- | @Net([Place(A), Place(B)], [Transition(MOVE)], [Arc(A, MOVE),
-- Arc(MOVE, B)], name="http-observation")@.
observationNet :: Net
observationNet =
  either (error . T.unpack) id $
    mkNet (netSpec [place a, place b] [transition move] [arc a move, arc move b]) {name = Just "http-observation"}

-- | The upstream test's @make_engine()@.
makeEngine :: IO Engine
makeEngine = do
  store <- inMemoryHistoryStore
  port <- inMemoryDispatch <$> newInMemoryDispatch
  Engine.create
    observationNet
    "http-instance"
    store
    port
    Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [Token (Just "value") (Object [("n", Int 1)])])]}

-- | Serve an Engine on an ephemeral port for the duration of an action
-- (upstream's @serving(engine)@).
withObservation :: Engine -> (Int -> IO x) -> IO x
withObservation engine = withObservationDoors (engineDoors engine)

withObservationDoors :: ObservationDoors -> (Int -> IO x) -> IO x
withObservationDoors doors action =
  withRunningServer (observationServerConfig "127.0.0.1" 0) (observationHandler doors) (\server -> serverPort server >>= action)

-- | A parsed response.
data Reply = Reply
  { replyStatus :: Int
  , replyHeaders :: [(ByteString, ByteString)]
  , replyBody :: ByteString
  }
  deriving stock (Eq, Show)

-- | Send raw bytes, half-close, and read the whole response.
exchange :: Int -> ByteString -> IO ByteString
exchange port bytes =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    sendAll sock bytes
    Socket.shutdown sock ShutdownSend `catch` \(_ :: IOException) -> pure ()
    let go chunks = do
          chunk <- timeout 20000000 (recv sock 65536 `catch` \(_ :: IOException) -> pure "")
          case chunk of
            Nothing -> pure (BS.concat (reverse ("<client timeout>" : chunks)))
            Just bytes'
              | BS.null bytes' -> pure (BS.concat (reverse chunks))
              | otherwise -> go (bytes' : chunks)
    go []

-- | @METHOD target HTTP/1.0@ with no headers.
request :: Int -> ByteString -> ByteString -> IO Reply
request port method target = requestWith port (method <> " " <> target <> " HTTP/1.0\r\n\r\n")

requestWith :: Int -> ByteString -> IO Reply
requestWith port bytes = parseReply <$> exchange port bytes

parseReply :: ByteString -> Reply
parseReply raw =
  let (head', rest) = BS.breakSubstring "\r\n\r\n" raw
      lines' = BS.split 10 (BC.filter (/= '\r') head')
      status = case lines' of
        first : _ -> maybe 0 fst (BC.readInt (BC.drop 1 (BC.dropWhile (/= ' ') first)))
        [] -> 0
      fields = [(name, BC.dropWhile (== ' ') (BS.drop 1 value)) | line <- drop 1 lines', let (name, value) = BC.break (== ':') line]
   in Reply status fields (BS.drop 4 rest)

-- | A header's value, compared case-insensitively.
header :: ByteString -> Reply -> Maybe ByteString
header name reply = lookup (lower name) [(lower k, v) | (k, v) <- replyHeaders reply]
  where
    lower = BC.map toLower

-- | A raw response without its @Server@ and @Date@ lines (the server
-- software and the clock).
normalize :: ByteString -> ByteString
normalize raw =
  let (head', rest) = BS.breakSubstring "\r\n\r\n" raw
      kept = filter (\line -> not ("Server: " `BS.isPrefixOf` line || "Date: " `BS.isPrefixOf` line)) (splitCrlf head')
   in BS.intercalate "\r\n" kept <> rest
  where
    splitCrlf bytes = case BS.breakSubstring "\r\n" bytes of
      (before, after)
        | BS.null after -> [before]
        | otherwise -> before : splitCrlf (BS.drop 2 after)
