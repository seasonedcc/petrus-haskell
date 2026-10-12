-- | @/__petrus/open-file@ and @/__petrus/resolve-ref@: port of
-- tests/openFileEndpoint.test.mjs and tests/resolveRefEndpoint.test.mjs.
module EndpointsSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (forM_)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Viewer.Json
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import TestSupport

sampleNet :: BL.ByteString
sampleNet =
  "{\"fileVersion\":\"2\",\"net\":\"test-net\",\"arcs\":[{\"source\":\"p1\",\"target\":\"t1\"}],\"places\":{\"p1\":{\"initial\":1}},\"transitions\":{\"t1\":{}},\"viewState\":{\"layout\":{\"p1\":[0,0],\"t1\":[100,0]}}}"

netNamed :: Text -> BL.ByteString
netNamed n = BL.fromStrict (TE.encodeUtf8 ("{\"fileVersion\":\"2\",\"net\":\"" <> n <> "\",\"arcs\":[],\"places\":{},\"transitions\":{}}"))

withNetFile :: BL.ByteString -> (FilePath -> IO a) -> IO a
withNetFile content act = withSystemTempDirectory "petrus-test-" $ \dir -> do
  let path = dir </> "test-net.json"
  BL.writeFile path content
  act path

-- | The server with an optional initial file; the base URL.
server :: Maybe FilePath -> (String -> IO a) -> IO a
server initial act = withViewer (\c -> c {serverOpenFile = initial}) $ \h ->
  act ("http://localhost:" <> show (handlePort h))

jsonBody :: HttpResult -> JsValue
jsonBody = either (const JsNull) id . parseJ . httpBody

-- | The net name inside a response's @content@ string.
contentNet :: HttpResult -> Maybe Text
contentNet r = textField "content" (jsonBody r) >>= either (const Nothing) (textField "net") . parseJs . TE.encodeUtf8

post :: String -> BL.ByteString -> IO HttpResult
post url body = httpRequest "POST" url (Just body)

resolveBody :: Text -> Text -> BL.ByteString
resolveBody ref base = encodeJsLazy (obj [("ref", str ref), ("basePath", str base)])

spec :: Spec
spec = do
  describe "/__petrus/open-file (tests/openFileEndpoint.test.mjs)" $ do
    it "GET returns 204 when no file is pending" $ server Nothing $ \url ->
      (httpStatus <$> httpRequest "GET" (url <> "/__petrus/open-file") Nothing) `shouldReturn` 204

    it "GET returns file content when initial file is set" $ withNetFile sampleNet $ \path ->
      server (Just path) $ \url -> do
        r <- httpRequest "GET" (url <> "/__petrus/open-file") Nothing
        httpStatus r `shouldBe` 200
        textField "path" (jsonBody r) `shouldBe` Just (T.pack path)
        contentNet r `shouldBe` Just "test-net"

    it "GET consumes the file - second GET returns 204" $ withNetFile sampleNet $ \path ->
      server (Just path) $ \url -> do
        (httpStatus <$> httpRequest "GET" (url <> "/__petrus/open-file") Nothing) `shouldReturn` 200
        (httpStatus <$> httpRequest "GET" (url <> "/__petrus/open-file") Nothing) `shouldReturn` 204

    it "POST sets a new pending file, GET returns it" $ withNetFile sampleNet $ \path ->
      server Nothing $ \url -> do
        p <- post (url <> "/__petrus/open-file") (encodeJsLazy (obj [("path", str (T.pack path))]))
        httpStatus p `shouldBe` 200
        field "ok" (jsonBody p) `shouldBe` Just (JsBool True)
        g <- httpRequest "GET" (url <> "/__petrus/open-file") Nothing
        httpStatus g `shouldBe` 200
        contentNet g `shouldBe` Just "test-net"

    it "POST with nonexistent path returns 400" $ server Nothing $ \url -> do
      r <- post (url <> "/__petrus/open-file") "{\"path\":\"/nonexistent/file.json\"}"
      httpStatus r `shouldBe` 400
      textField "error" (jsonBody r) `shouldBe` Just "File not found"

    it "POST with invalid JSON returns 400" $ server Nothing $ \url ->
      (httpStatus <$> post (url <> "/__petrus/open-file") "not json{{{") `shouldReturn` 400

    it "answers CORS preflight and sets CORS headers" $ server Nothing $ \url -> do
      r <- httpRequest "OPTIONS" (url <> "/__petrus/open-file") Nothing
      httpStatus r `shouldBe` 204
      lookup "Access-Control-Allow-Origin" (httpHeaders r) `shouldBe` Just "*"

    -- Node serves one request at a time; Warp serves these on several
    -- capabilities, and the GET takes the pending file atomically.
    it "serves a pending file to one GET only, however many arrive at once" $ withNetFile sampleNet $ \path ->
      server Nothing $ \url -> forM_ [1 .. 20 :: Int] $ \_ -> do
        (httpStatus <$> post (url <> "/__petrus/open-file") (encodeJsLazy (obj [("path", str (T.pack path))]))) `shouldReturn` 200
        statuses <- mapConcurrently (const (httpStatus <$> httpRequest "GET" (url <> "/__petrus/open-file") Nothing)) [1 .. 16 :: Int]
        length (filter (== 200) statuses) `shouldBe` 1

  describe "/__petrus/resolve-ref (tests/resolveRefEndpoint.test.mjs)" $ do
    it "resolves a relative ref against a file:// basePath" $ withSystemTempDirectory "petrus-ref-test-" $ \dir -> do
      BL.writeFile (dir </> "B.json") (netNamed "B-net")
      server Nothing $ \url -> do
        r <- post (url <> "/__petrus/resolve-ref") (resolveBody "./B.json" (T.pack ("file://" <> dir </> "A.json")))
        httpStatus r `shouldBe` 200
        contentNet r `shouldBe` Just "B-net"
        textField "resolvedPath" (jsonBody r) `shouldSatisfy` isJust

    it "resolves bare relative ref (subdir/B.json)" $ withSystemTempDirectory "petrus-ref-test-" $ \dir -> do
      createDirectory (dir </> "subdir")
      BL.writeFile (dir </> "subdir" </> "B.json") (netNamed "sub-net")
      server Nothing $ \url -> do
        r <- post (url <> "/__petrus/resolve-ref") (resolveBody "subdir/B.json" (T.pack ("file://" <> dir </> "A.json")))
        httpStatus r `shouldBe` 200
        contentNet r `shouldBe` Just "sub-net"

    it "resolves ../ ref" $ withSystemTempDirectory "petrus-ref-test-" $ \dir -> do
      createDirectory (dir </> "sub")
      BL.writeFile (dir </> "C.json") (netNamed "C-net")
      server Nothing $ \url -> do
        r <- post (url <> "/__petrus/resolve-ref") (resolveBody "../C.json" (T.pack ("file://" <> dir </> "sub" </> "A.json")))
        httpStatus r `shouldBe` 200
        contentNet r `shouldBe` Just "C-net"

    it "appends .json if missing" $ withSystemTempDirectory "petrus-ref-test-" $ \dir -> do
      BL.writeFile (dir </> "B.json") (netNamed "B-net")
      server Nothing $ \url -> do
        r <- post (url <> "/__petrus/resolve-ref") (resolveBody "B" (T.pack ("file://" <> dir </> "A.json")))
        httpStatus r `shouldBe` 200
        contentNet r `shouldBe` Just "B-net"

    it "returns 400 for nonexistent local file" $ server Nothing $ \url -> do
      r <- post (url <> "/__petrus/resolve-ref") (resolveBody "missing.json" "file:///tmp/A.json")
      httpStatus r `shouldBe` 400
      textField "error" (jsonBody r) `shouldBe` Just "File not found: /tmp/missing.json"

    it "returns 400 for invalid JSON body" $ server Nothing $ \url -> do
      r <- post (url <> "/__petrus/resolve-ref") "not json{{{"
      httpStatus r `shouldBe` 400
      textField "error" (jsonBody r) `shouldBe` Just "Unexpected token 'o', \"not json{{{\" is not valid JSON"

    it "keeps the lone surrogate V8's message cuts from a pair" $ server Nothing $ \url -> do
      r <- post (url <> "/__petrus/resolve-ref") (BL.fromStrict (TE.encodeUtf8 "[\x1F600]"))
      httpStatus r `shouldBe` 400
      -- recorded from Node 22
      httpBody r `shouldBe` BL.fromStrict (TE.encodeUtf8 "{\"error\":\"Unexpected token '\\ud83d', \\\"[\x1F600]\\\" is not valid JSON\"}")

    it "returns 400 when ref is missing" $ server Nothing $ \url -> do
      r <- post (url <> "/__petrus/resolve-ref") "{\"basePath\":\"file:///tmp/A.json\"}"
      httpStatus r `shouldBe` 400
      textField "error" (jsonBody r) `shouldBe` Just "Missing ref or basePath"

    it "OPTIONS returns 204 (CORS preflight)" $ server Nothing $ \url ->
      (httpStatus <$> httpRequest "OPTIONS" (url <> "/__petrus/resolve-ref") Nothing) `shouldReturn` 204

    it "reports unsupported protocols and invalid URLs like Node" $ server Nothing $ \url -> do
      r1 <- post (url <> "/__petrus/resolve-ref") (resolveBody "x" "mailto:a")
      textField "error" (jsonBody r1) `shouldBe` Just "Invalid URL"
      r2 <- post (url <> "/__petrus/resolve-ref") (resolveBody "ftp://h/x.json" "file:///tmp/A.json")
      textField "error" (jsonBody r2) `shouldBe` Just "Unsupported protocol: ftp:"
      BLC.length (httpBody r2) `shouldSatisfy` (> 0)
