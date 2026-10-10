-- | Shared helpers: an in-process viewer server, WebSocket clients with an
-- inbox, HTTP requests, and JSON field access.
module TestSupport
  ( withViewer
  , WsClient
  , withWs
  , sendText
  , recvJson
  , recvWithin
  , drainFor
  , closeWs
  , HttpResult (..)
  , httpRequest
  , httpRequestWith
  , field
  , textField
  , parseJ
  , fixturePath
  ) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.WebSockets qualified as WS
import Petrus.Viewer.Json
import Petrus.Viewer.Server
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)

-- | Run the viewer server on a free loopback port.
withViewer :: (ServerConfig -> ServerConfig) -> (ServerHandle -> IO a) -> IO a
withViewer f =
  withServer (f defaultServerConfig {serverPort = 0, serverStrictPort = True, serverRelayPerf = False})

data WsClient = WsClient
  { wsConn :: WS.Connection
  , wsInbox :: TQueue BL.ByteString
  }

-- | Connect to @ws://127.0.0.1:port/path@ and collect every text message.
withWs :: Int -> String -> (WsClient -> IO a) -> IO a
withWs port path act =
  WS.runClient "127.0.0.1" port path $ \conn -> do
    inbox <- newTQueueIO
    let reader = forever (WS.receiveData conn >>= atomically . writeTQueue inbox)
    withAsync (void (try @SomeException reader)) $ \_ -> act (WsClient conn inbox)

sendText :: WsClient -> BL.ByteString -> IO ()
sendText c = WS.sendTextData (wsConn c)

closeWs :: WsClient -> IO ()
closeWs c = void (try @SomeException (WS.sendClose (wsConn c) ("" :: Text)))

-- | The next message within @ms@ milliseconds, parsed.
recvWithin :: Int -> WsClient -> IO (Maybe JsValue)
recvWithin ms c = do
  r <- timeout (ms * 1000) (atomically (readTQueue (wsInbox c)))
  pure (r >>= either (const Nothing) Just . parseJ)

-- | The next message (2 s timeout fails the test).
recvJson :: WsClient -> IO JsValue
recvJson c =
  recvWithin 2000 c >>= \case
    Just v -> pure v
    Nothing -> expectationFailure "timed out waiting for a WebSocket message" >> pure JsNull

-- | Every message that arrives within @ms@ milliseconds.
drainFor :: Int -> WsClient -> IO [JsValue]
drainFor ms c = do
  deadline <- registerDelay (ms * 1000)
  let loop acc = do
        next <-
          atomically $
            (Just <$> readTQueue (wsInbox c))
              `orElse` (readTVar deadline >>= check >> pure Nothing)
        case next of
          Just m -> loop (m : acc)
          Nothing -> pure (reverse acc)
  msgs <- loop []
  pure [v | Right v <- map parseJ msgs]

data HttpResult = HttpResult
  { httpStatus :: Int
  , httpBody :: BL.ByteString
  , httpHeaders :: [H.Header]
  }

httpRequest :: B.ByteString -> String -> Maybe BL.ByteString -> IO HttpResult
httpRequest = httpRequestWith []

-- | 'httpRequest' with extra request headers.
httpRequestWith :: [H.Header] -> B.ByteString -> String -> Maybe BL.ByteString -> IO HttpResult
httpRequestWith extra method url body = do
  mgr <- HC.newManager HC.defaultManagerSettings
  req0 <- HC.parseRequest url
  let req =
        req0
          { HC.method = method
          , HC.requestBody = maybe (HC.RequestBodyLBS "") HC.RequestBodyLBS body
          , HC.requestHeaders = [("Content-Type", "application/json") | Just _ <- [body]] ++ extra
          }
  resp <- HC.httpLbs req mgr
  pure (HttpResult (H.statusCode (HC.responseStatus resp)) (HC.responseBody resp) (HC.responseHeaders resp))

parseJ :: BL.ByteString -> Either String JsValue
parseJ = parseJs . decodeLenient . BL.toStrict

field :: Text -> JsValue -> Maybe JsValue
field k v = asObject v >>= lookupKey k

textField :: Text -> JsValue -> Maybe Text
textField k v = field k v >>= asText

fixturePath :: FilePath -> FilePath
fixturePath name = "test" </> "fixtures" </> name
