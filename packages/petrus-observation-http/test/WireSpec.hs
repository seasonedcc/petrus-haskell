-- | Byte-level comparison with the upstream server: the same raw requests
-- go to @petrus.engine.observation_http@ (run by
-- @test/reference_observation.py@ from the pinned upstream) and to this
-- package, over an Engine built the same way, and the full responses must
-- be identical except for the @Server@ and @Date@ lines.
module WireSpec (spec, corpus, generatedQueries) where

import Control.Exception (throwIO)
import Control.Monad (forM_)
import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (unfoldr)
import Data.Text qualified as T
import Data.Word (Word64)
import Petrus.Engine (EngineError (..))
import Petrus.Engine qualified as Engine
import Petrus.Observation.Http
import Petrus.TestSupport.Python (readLine, withPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import Test.Hspec

spec :: Spec
spec = describe "byte-identical to the upstream server" $ do
  forM_ ["fresh", "advanced", "closed"] $ \mode ->
    it ("over an Engine that is " <> mode <> " (" <> show (length corpus + length generatedQueries) <> " requests)") $
      withReference mode $ \python -> do
        engine <- makeEngine
        case mode of
          "advanced" -> () <$ Engine.advance engine
          "closed" -> Engine.close engine
          _ -> pure ()
        withObservation engine $ \haskell ->
          forM_ (corpus ++ map historyRequest generatedQueries) $ \raw -> do
            theirs <- normalize <$> exchange python raw
            ours <- normalize <$> exchange haskell raw
            (raw, BS.null theirs, ours) `shouldBe` (raw, False, theirs)
        Engine.close engine
  it "over read doors that fail (500, 503, 500)" $
    withReference "broken" $ \python ->
      withObservationDoors broken $ \haskell ->
        forM_ corpus $ \raw -> do
          theirs <- normalize <$> exchange python raw
          ours <- normalize <$> exchange haskell raw
          (raw, BS.null theirs, ours) `shouldBe` (raw, False, theirs)
  where
    -- KeyError, RecursionError (a RuntimeError) and TypeError upstream.
    broken =
      ObservationDoors
        { snapshotDoor = throwIO (userError "snapshot")
        , documentDoor = throwIO (EngineRuntimeError "document")
        , historyDoor = \_ _ -> throwIO (EngineTypeError "history")
        }

withReference :: String -> (Int -> IO x) -> IO x
withReference mode action = do
  root <- repoRoot
  script <- T.pack <$> readFile (root <> "/packages/petrus-observation-http/test/reference_observation.py")
  withPython script [mode] $ \process -> do
    port <- readLine process
    action (read (BC.unpack port))

historyRequest :: ByteString -> ByteString
historyRequest query = "GET /v1/history?" <> query <> " HTTP/1.0\r\n\r\n"

get :: ByteString -> ByteString
get target = "GET " <> target <> " HTTP/1.0\r\n\r\n"

-- | Hand-written requests: every route, method and refusal.
corpus :: [ByteString]
corpus =
  map get targets
    ++ [method <> " " <> target <> " HTTP/1.0\r\n\r\n" | method <- methods, target <- ["/v1/snapshot", "/nowhere", "/v1/history?bad"]]
    ++ [ "GET /v1/snapshot\r\n"
       , "GET /v1/snapshot HTTP/1.1\r\nHost: example\r\nConnection: keep-alive\r\n\r\n"
       , "GET /v1/snapshot HTTP/2.0\r\n\r\n"
       , "GARBAGE\r\n\r\n"
       , "POST /v1/snapshot HTTP/1.0\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}"
       , "GET /v1/snapshot HTTP/1.0\r\nOrigin: http://elsewhere\r\n\r\n"
       ]
  where
    methods = ["GET", "OPTIONS", "POST", "PUT", "PATCH", "DELETE", "HEAD", "TRACE", "CONNECT", "get", "BREW"]
    targets =
      [ "/v1/snapshot"
      , "/v1/document"
      , "/v1/history?after=0&limit=100"
      , "/v1/history?after=1&limit=1"
      , "/v1/history?limit=1000&after=0"
      , "/v1/history?after=0&limit=0"
      , "/v1/history?after=2&limit=5"
      , "/v1/history?after=3&limit=5"
      , "/v1/history?after=999&limit=1"
      , "/v1/history?after=00&limit=0001"
      , "//v1/snapshot"
      , "///v1/document"
      , "/v1/snapshot?"
      , "/v1/snapshot?x"
      , "/v1/snapshot?x=1"
      , "/v1/snapshot#fragment"
      , "/v1/snapshot?#"
      , "/v1/document?a=1"
      , "/v1/document#?a=1"
      , "http://example.com/v1/snapshot"
      , "HTTP://example.com:99999/v1/document"
      , "http://user:pw@[::1]:80/v1/snapshot"
      , "http://[::1/v1/snapshot"
      , "http://::1]/v1/snapshot"
      , "http://[127.0.0.1]/v1/snapshot"
      , "http://[v1.x]/v1/snapshot"
      , "http://[vz.x]/v1/snapshot"
      , "http://[zz]/v1/snapshot"
      , "http://a[::1]/v1/snapshot"
      , "http://[::1]x/v1/snapshot"
      , "http://\xff\xe9/v1/snapshot"
      , "//example.com/v1/snapshot"
      , "v1/snapshot"
      , "*"
      , "/"
      , "/unknown"
      , "/v1/snapshot/"
      , "/V1/snapshot"
      , "/v1/history"
      , "/v1/history?"
      , "/v1/history?after=0&limit=1&"
      , "/v1/history?&after=0&limit=1"
      , "/v1/history?after=0;limit=1"
      , "/v1/history?after=%30&limit=%31"
      , "/v1/history?after=0&lim%69t=1"
      , "/v1/history?after=0&limit=1&="
      , "/v1/history?=1"
      , "/v1/history?after=\xe9&limit=1"
      , "/v1/history?after=%C3%A9&limit=1"
      , "/v1/history?after=%FF&limit=1"
      , "/v1/history?%FF=1"
      , "/v1/history?caf%C3%A9=1"
      , "/v1/history?after=0&limit=1#x"
      , "/v1/history?after=0+&limit=1"
      , "/v1/history?after=%D9%A3&limit=1"
      , "/v1/history?after=0&limit=1001"
      , "/v1/history?after=0&limit=99999999999999999999999"
      , "/v1/history?after=" <> BC.replicate 4300 '0' <> "&limit=1"
      , "/v1/history?after=" <> BC.replicate 4301 '0' <> "&limit=1"
      , "/v1/history?after=0&limit=" <> BC.replicate 4301 '1'
      , "/v1/history?after=" <> BC.replicate 4301 '9' <> "&limit=" <> BC.replicate 4301 '1'
      , "/v1/history?after=99999999999999999999999&limit=1"
      ]

-- | 400 generated @/v1/history@ queries over the grammar's pieces.
generatedQueries :: [ByteString]
generatedQueries = take 400 (go (randoms 7))
  where
    pieces =
      [ "after", "limit", "after=", "limit=", "=", "&", "&&", "0", "1", "7", "00", "1000", "1001", "+", "%20", "%2B", "%30"
      , "%", "%zz", "%C3%A9", "%FF", "-", ".", "extra", "x=1", "after=0", "limit=1", "after=1", "limit=2", "#", "?", ";", "\xe9"
      ]
    go (r : rs) =
      let n = fromIntegral (r `mod` 7) + 1
          (chosen, rest) = splitAt n rs
       in BS.concat (map (\x -> pieces !! fromIntegral (x `mod` fromIntegral (length pieces))) chosen) : go rest
    go [] = []

randoms :: Word64 -> [Word64]
randoms = unfoldr (\s -> let s' = s + 0x9E3779B97F4A7C15 in Just (mix s', s'))
  where
    mix z0 =
      let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
          z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
       in z2 `xor` (z2 `shiftR` 31)
