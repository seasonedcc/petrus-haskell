-- | The HTTP surface outside the ported endpoints: serving the built UI
-- (Vite's role), the SPA fallback, and how non-upgrade / unknown WebSocket
-- requests are answered, and how the HTTP front shares connections with
-- Warp.
module ServerSpec (spec) where

import Control.Exception (SomeException, bracket, try)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text (Text)
import Network.Socket qualified as S
import Network.Socket.ByteString qualified as SB
import Network.WebSockets qualified as WS
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec
import TestSupport

withUi :: (String -> IO a) -> IO a
withUi act = withSystemTempDirectory "petrus-ui-" $ \dir -> do
  BL.writeFile (dir </> "index.html") "<!doctype html><title>Petrus</title>"
  createDirectory (dir </> "assets")
  BL.writeFile (dir </> "assets" </> "app.js") "console.log(1)"
  withViewer (\c -> c {serverUiDir = Just dir}) $ \h ->
    act ("http://localhost:" <> show (handlePort h))

spec :: Spec
spec = do
  describe "UI serving" $ do
    it "serves index.html at / and assets with their content types" $ withUi $ \url -> do
      index <- httpRequest "GET" (url <> "/") Nothing
      httpStatus index `shouldBe` 200
      httpBody index `shouldBe` "<!doctype html><title>Petrus</title>"
      lookup "Content-Type" (httpHeaders index) `shouldBe` Just "text/html"
      js <- httpRequest "GET" (url <> "/assets/app.js") Nothing
      httpStatus js `shouldBe` 200
      lookup "Content-Type" (httpHeaders js) `shouldBe` Just "text/javascript"
      lookup "Cache-Control" (httpHeaders js) `shouldBe` Just "no-cache"

    it "falls back to index.html for browser navigations only" $ withUi $ \url -> do
      nav <- httpRequestWith [("Accept", "text/html,application/xhtml+xml")] "GET" (url <> "/some/route") Nothing
      httpStatus nav `shouldBe` 200
      httpBody nav `shouldBe` "<!doctype html><title>Petrus</title>"
      api <- httpRequestWith [("Accept", "application/json")] "GET" (url <> "/missing.json") Nothing
      httpStatus api `shouldBe` 404

    it "refuses path traversal" $ withUi $ \url -> do
      r <- httpRequestWith [("Accept", "application/json")] "GET" (url <> "/assets/%2e%2e/%2e%2e/etc/passwd") Nothing
      httpStatus r `shouldBe` 404

    it "explains a missing UI directory" $ withViewer id $ \h -> do
      r <- httpRequest "GET" ("http://localhost:" <> show (handlePort h) <> "/") Nothing
      httpStatus r `shouldBe` 404
      BL.take 26 (httpBody r) `shouldBe` "Petrus UI not configured: "

  describe "WebSocket paths" $ do
    it "answers plain HTTP on /collab-ws with 426" $ withViewer id $ \h -> do
      r <- httpRequest "GET" ("http://localhost:" <> show (handlePort h) <> "/collab-ws") Nothing
      httpStatus r `shouldBe` 426

    it "rejects upgrades on unknown paths" $ withViewer id $ \h -> do
      r <- try @SomeException (WS.runClient "127.0.0.1" (handlePort h) "/ws/other" (\c -> WS.sendTextData c ("x" :: Text)))
      r `shouldSatisfy` isLeft

    it "accepts upgrades on /ws/agent and /collab-ws (with a query)" $ withViewer id $ \h -> do
      withWs (handlePort h) "/ws/agent" $ \c -> (textField "type" <$> recvJson c) `shouldReturn` Just "welcome"
      withWs (handlePort h) "/collab-ws?room=a" $ \c -> (textField "type" <$> recvJson c) `shouldReturn` Just "welcome"

  describe "HTTP front" $ do
    it "hands a connection to Warp after serving endpoint requests on it" $ withViewer id $ \h ->
      withRaw (handlePort h) $ \s -> do
        -- pipelined: the front answers the first, Warp the second
        SB.sendAll s (get "/__petrus/open-file" <> get "/collab-ws")
        r <- readUntil s ("\r\n\r\nUpgrade Required" `B.isSuffixOf`)
        statusLines r `shouldBe` ["HTTP/1.1 204 No Content", "HTTP/1.1 426 Upgrade Required"]
        -- the same connection keeps working under Warp
        SB.sendAll s (get "/__petrus/open-file")
        r2 <- readUntil s ("\r\n\r\n" `B.isSuffixOf`)
        statusLines r2 `shouldBe` ["HTTP/1.1 204 No Content"]

    it "closes an idle keep-alive connection after Node's 5 s" $ withViewer id $ \h ->
      withRaw (handlePort h) $ \s -> do
        SB.sendAll s (get "/__petrus/open-file")
        r <- readUntil s ("\r\n\r\n" `B.isSuffixOf`)
        ("Keep-Alive: timeout=5" `B.isInfixOf` r) `shouldBe` True
        early <- timeout 4000000 (SB.recv s 4096)
        early `shouldBe` Nothing
        late <- timeout 3000000 (SB.recv s 4096)
        late `shouldBe` Just ""
  where
    get path = "GET " <> path <> " HTTP/1.1\r\nHost: x\r\n\r\n"
    statusLines = filter ("HTTP/1.1 " `B.isPrefixOf`) . map (BC.filter (/= '\r')) . BC.lines

-- | A raw TCP connection to the server.
withRaw :: Int -> (S.Socket -> IO a) -> IO a
withRaw port = bracket open S.close
  where
    open = do
      s <- S.socket S.AF_INET S.Stream S.defaultProtocol
      S.connect s (S.SockAddrInet (fromIntegral port) (S.tupleToHostAddress (127, 0, 0, 1)))
      pure s

-- | Read until the bytes so far satisfy the predicate (2 s at most).
readUntil :: S.Socket -> (B.ByteString -> Bool) -> IO B.ByteString
readUntil s done = go ""
  where
    go acc
      | done acc = pure acc
      | otherwise =
          timeout 2000000 (SB.recv s 65536) >>= \case
            Just chunk | not (B.null chunk) -> go (acc <> chunk)
            _ -> pure acc
