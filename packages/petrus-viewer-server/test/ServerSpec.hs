-- | The HTTP surface outside the ported endpoints: serving the built UI
-- (Vite's role), the SPA fallback, and how non-upgrade / unknown WebSocket
-- requests are answered.
module ServerSpec (spec) where

import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Network.WebSockets qualified as WS
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
    it "answers plain HTTP on /collab-ws with 426 when collaboration is on" $ withViewer collabOn $ \h -> do
      r <- httpRequest "GET" ("http://localhost:" <> show (handlePort h) <> "/collab-ws") Nothing
      httpStatus r `shouldBe` 426

    it "rejects upgrades on unknown paths" $ withViewer id $ \h -> do
      r <- try @SomeException (WS.runClient "127.0.0.1" (handlePort h) "/ws/other" (\c -> WS.sendTextData c ("x" :: Text)))
      r `shouldSatisfy` isLeft

    it "accepts upgrades on /ws/agent and /collab-ws (with a query)" $ withViewer collabOn $ \h -> do
      withWs (handlePort h) "/ws/agent" $ \c -> (textField "type" <$> recvJson c) `shouldReturn` Just "welcome"
      withWs (handlePort h) "/collab-ws?room=a" $ \c -> (textField "type" <$> recvJson c) `shouldReturn` Just "welcome"

    -- Vite proxies /collab-ws only with --host.
    it "refuses /collab-ws upgrades when collaboration is off (the default)" $ withViewer id $ \h -> do
      isNothing (handleCollabRelay h) `shouldBe` True
      r <- try @SomeException (WS.runClient "127.0.0.1" (handlePort h) "/collab-ws" (\c -> WS.sendTextData c ("x" :: Text)))
      r `shouldSatisfy` isLeft
      withWs (handlePort h) "/ws/agent" $ \c -> (textField "type" <$> recvJson c) `shouldReturn` Just "welcome"

  where
    collabOn c = c {serverCollab = True}
