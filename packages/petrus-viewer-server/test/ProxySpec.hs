-- | The @/temporal@ proxy passes content codings through as Vite's
-- http-proxy does: the browser's @Accept-Encoding@ reaches the target as
-- sent, and the target's compressed body and its @Content-Encoding@ reach the
-- browser untouched (never decompressed, never unlabelled).
module ProxySpec (spec) where

import Control.Concurrent.STM
import Control.Monad (join)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W
import Network.Wai.Handler.Warp qualified as Warp
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import Test.Hspec
import TestSupport (withViewer)

-- | Opaque bytes standing in for a compressed body: they must arrive as
-- sent, so they are not valid in any coding.
compressed :: BL.ByteString
compressed = BL.pack ([0x1b, 0x8b, 0x00, 0xff, 0x0d, 0x0a] <> [0 .. 255])

-- | A target that answers every request with 'compressed', labelled with the
-- coding the @x-coding@ query names, and records the @Accept-Encoding@ it
-- received (Nothing when there was none).
target :: TVar [Maybe B.ByteString] -> W.Application
target seen req respond = do
  atomically (modifyTVar' seen (lookup "Accept-Encoding" (W.requestHeaders req) :))
  let coding = fromMaybe "identity" (join (lookup "x-coding" (W.queryString req)))
  respond (W.responseLBS H.status200 [("Content-Type", "application/json"), ("Content-Encoding", coding)] compressed)

-- | A request through the proxy with exactly these headers, its body left
-- as it arrives (no decompression in the client either).
fetch :: Int -> String -> [H.Header] -> IO (HC.Response BL.ByteString)
fetch port pathAndQuery headers = do
  mgr <- HC.newManager HC.defaultManagerSettings
  req <- HC.parseRequest ("http://127.0.0.1:" <> show port <> pathAndQuery)
  HC.httpLbs req {HC.requestHeaders = headers <> [("Accept-Encoding", "") | "Accept-Encoding" `notElem` map fst headers], HC.decompress = const False} mgr

spec :: Spec
spec = describe "/temporal proxy content codings" $ do
  it "passes a br or deflate body and its Content-Encoding through untouched" $ do
    seen <- newTVarIO []
    Warp.testWithApplication (pure (target seen)) $ \tport ->
      withViewer (\c -> c {serverTemporalTarget = "http://127.0.0.1:" <> show tport}) $ \h ->
        mapM_
          ( \coding -> do
              resp <- fetch (handlePort h) ("/temporal/api/v1/x?x-coding=" <> coding) [("Accept-Encoding", "gzip, deflate, br, zstd")]
              H.statusCode (HC.responseStatus resp) `shouldBe` 200
              lookup "Content-Encoding" (HC.responseHeaders resp) `shouldBe` Just (BC.pack coding)
              HC.responseBody resp `shouldBe` compressed
          )
          ["br", "deflate", "gzip"]
    readTVarIO seen `shouldReturn` replicate 3 (Just "gzip, deflate, br, zstd")

  it "sends no Accept-Encoding when the browser sent none" $ do
    seen <- newTVarIO []
    Warp.testWithApplication (pure (target seen)) $ \tport ->
      withViewer (\c -> c {serverTemporalTarget = "http://127.0.0.1:" <> show tport}) $ \h -> do
        resp <- fetch (handlePort h) "/temporal/api/v1/x?x-coding=br" []
        HC.responseBody resp `shouldBe` compressed
    readTVarIO seen `shouldReturn` [Nothing]
