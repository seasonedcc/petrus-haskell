-- | WebSocket client endpoints: parsing @ws://@ URLs and connecting the way
-- the @ws@ package does (every resolved address is tried in order, so
-- @localhost@ reaches servers bound to either @::1@ or @127.0.0.1@).
module Petrus.Viewer.WsUrl
  ( WsTarget (..)
  , parseWsUrl
  , runWsClient
  ) where

import Control.Exception (SomeException, bracketOnError, throwIO, try)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket qualified as S
import Network.WebSockets qualified as WS
import Petrus.Viewer.Url

data WsTarget = WsTarget
  { wsHost :: String
  -- ^ host name or address, without IPv6 brackets
  , wsPort :: Int
  , wsResource :: String
  -- ^ path plus query, as sent in the request line
  , wsHostHeader :: String
  }
  deriving stock (Eq, Show)

-- | Parse a @ws:@ (or @http:@) URL. @wss:@ is rejected: the local bridge is
-- always plain text.
parseWsUrl :: Text -> Either Text WsTarget
parseWsUrl t = case parseUrl t of
  Nothing -> Left ("Invalid URL: " <> t)
  Just u
    | urlScheme u `notElem` ["ws", "http"] ->
        Left ("Unsupported WebSocket URL scheme: " <> T.pack (urlScheme u) <> ":")
    | otherwise -> case urlHost u of
        Nothing -> Left ("Invalid URL: " <> t)
        Just h ->
          let port = maybe 80 id (urlPort u)
              bare = case h of
                '[' : rest -> takeWhile (/= ']') rest
                _ -> h
              path = T.unpack (urlPathname u) ++ maybe "" ('?' :) (urlQuery u)
           in Right
                WsTarget
                  { wsHost = bare
                  , wsPort = port
                  , wsResource = if null path then "/" else path
                  , wsHostHeader = h ++ maybe "" (\p -> ':' : show p) (urlPort u)
                  }

-- | Connect and run a client application.
runWsClient :: WsTarget -> WS.ConnectionOptions -> WS.ClientApp a -> IO a
runWsClient target opts app = do
  let hints = S.defaultHints {S.addrSocketType = S.Stream}
  addrs <- S.getAddrInfo (Just hints) (Just (wsHost target)) (Just (show (wsPort target)))
  sock <- firstConnect addrs
  r <- try @SomeException (WS.runClientWithSocket sock (wsHostHeader target) (wsResource target) opts [] app)
  S.close sock
  either throwIO pure r
  where
    firstConnect = \case
      [] -> ioError (userError "connect ECONNREFUSED")
      [a] -> open a
      (a : rest) -> do
        r <- try @SomeException (open a)
        either (const (firstConnect rest)) pure r
    open a =
      bracketOnError (S.socket (S.addrFamily a) S.Stream S.defaultProtocol) S.close $ \s -> do
        S.setSocketOption s S.NoDelay 1
        S.connect s (S.addrAddress a)
        pure s
