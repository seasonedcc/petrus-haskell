-- | Byte-level comparison with the upstream server: the same raw requests
-- go to @petrus.simulation_http@ (run by @test/reference_simulation.py@
-- from the pinned upstream) and to this package, over the same fixed
-- build, and the full responses must be identical except for the @Server@
-- and @Date@ lines.
module WireSpec (spec, corpus, generatedBodies, randoms) where

import Control.Exception (throwIO)
import Control.Monad (forM)
import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (nub, sort, unfoldr)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Petrus.Json
import Petrus.Simulation (simulationProfile)
import Petrus.Simulation.Http
import Petrus.Simulation.Http qualified as Http
import Petrus.TestSupport.Python (readLine, withPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import Test.Hspec

spec :: Spec
spec = describe "byte-identical to the upstream server" $ do
  it ("with the real simulation (" <> show (length corpus + length generatedBodies) <> " requests)") $
    withReference "real" $ \python ->
      withHaskell (simulationServerConfig "127.0.0.1" 0 origin) $ \haskell -> do
        statuses <- forM (corpus ++ map simulationRequest generatedBodies) (compareOn python haskell)
        -- every outcome but 429 (overlap) and 503 (shutdown), many successes;
        -- 0 is a bare HTTP/0.9 body
        nub (sort statuses) `shouldBe` [0, 200, 204, 400, 403, 404, 405, 409, 411, 413, 415, 422, 500]
        length (filter (== 200) statuses) `shouldSatisfy` (>= 50)
  it "with a failing producer (500 without details)" $
    withReference "failing" $ \python ->
      withHaskell (simulationServerConfig "127.0.0.1" 0 origin) {Http.runner = \_ _ _ -> throwIO (userError "secret")} $ \haskell ->
        mapM_ (compareOn python haskell) (take 40 corpus ++ map simulationRequest (take 40 generatedBodies))
  where
    compareOn python haskell request = do
      theirs <- normalize <$> exchange python request
      ours <- normalize <$> exchange haskell request
      (request, BS.null theirs, ours) `shouldBe` (request, False, theirs)
      pure (parseReply theirs).status

withHaskell :: SimulationServerConfig -> (Int -> IO a) -> IO a
withHaskell config action = withSimulationServer config (fst buildScenario) (\server -> serverPort (simulationHttp server) >>= action)

withReference :: String -> (Int -> IO x) -> IO x
withReference mode action = do
  root <- repoRoot
  script <- T.pack <$> readFile (root <> "/packages/petrus-simulation/test/reference_simulation.py")
  withPython script [mode] $ \process -> do
    port <- readLine process
    action (read (BC.unpack port))

originBytes :: ByteString
originBytes = TE.encodeUtf8 origin

-- | The fixed build's definition, compact.
definition :: Json
definition = case simulationProfile (fst buildScenario) of
  Right profile | Just value <- lookupMember "definition" profile -> value
  other -> error ("no profile: " <> show other)

encode :: Json -> ByteString
encode = either (error . show) id . dumps compact

simulationRequest :: ByteString -> ByteString
simulationRequest body = framed "POST" "/v1/simulations" [("Content-Type", "application/json")] body

-- | A request with the allowed Origin, the given headers, and a
-- Content-Length for the body.
framed :: ByteString -> ByteString -> [(ByteString, ByteString)] -> ByteString -> ByteString
framed method target headers body =
  method
    <> " "
    <> target
    <> " HTTP/1.1\r\nHost: test\r\nOrigin: "
    <> originBytes
    <> "\r\n"
    <> BS.concat [name <> ": " <> value <> "\r\n" | (name, value) <- headers]
    <> "Content-Length: "
    <> BC.pack (show (BS.length body))
    <> "\r\n\r\n"
    <> body

bare :: ByteString -> ByteString -> [ByteString] -> ByteString
bare method target lines' = method <> " " <> target <> " HTTP/1.1\r\n" <> BS.concat [l <> "\r\n" | l <- lines'] <> "\r\n"

body' :: Json -> Json -> Json -> ByteString
body' expected marking maxActions =
  encode (Object [("expected_definition", expected), ("initial_marking", marking), ("max_actions", maxActions)])

scenarioMarking :: Json
scenarioMarking =
  Array
    [ Object
        [ ("place", String "pending")
        , ("tokens", Array [Object [("color", String "SimulationItem"), ("data", Object [("id", String "demo-1"), ("priority", Int 2), ("typed", Bool True)])]])
        ]
    ]

-- | Hand-written requests: every route, method, framing rule, decoder rule
-- and outcome.
corpus :: [ByteString]
corpus =
  [ bare method target ["Host: test", "Origin: " <> originBytes]
  | method <- ["GET", "OPTIONS", "POST", "HEAD", "PUT", "PATCH", "DELETE", "TRACE", "CONNECT", "FROBNICATE", "get"]
  , target <- ["/v1/simulation-profile", "/v1/simulations", "/unknown", "/v1/simulation-profile?x", "//v1/simulations"]
  ]
    ++ [ bare "GET" "/v1/simulation-profile" headers
       | headers <-
           [ []
           , ["Origin: http://other.test"]
           , ["Origin: HTTP://localhost:5173"]
           , ["Origin: http://localhost:5173/"]
           , ["Origin: " <> originBytes, "Origin: " <> originBytes]
           , ["Origin:  " <> originBytes <> "  "]
           , ["origin: " <> originBytes]
           , ["Origin:" <> originBytes]
           , ["Origin: null"]
           ]
       ]
    ++ [ bare "GET" target ["Origin: " <> originBytes]
       | target <-
           [ "http://test/v1/simulation-profile"
           , "http://[x]/v1/simulation-profile"
           , "/v1/simulation-profile#x"
           , "/v1/simulation-profile?"
           , "*"
           , "v1/simulation-profile"
           , "/v1/simulation-profile/"
           , "/V1/simulation-profile"
           , "/v1/simulation-profile%20"
           , "/v1/simulations?x=1"
           ]
       ]
    ++ [ "GET /v1/simulation-profile\r\n"
       , "GET /v1/simulation-profile HTTP/1.0\r\nOrigin: " <> originBytes <> "\r\n\r\n"
       , "GET /v1/simulation-profile HTTP/2.0\r\nOrigin: " <> originBytes <> "\r\n\r\n"
       , "GARBAGE\r\n\r\n"
       , "GET /v1/simulation-profile HTTP/1.1\r\nOrigin: " <> originBytes <> "\r\n\r\nGET /v1/simulation-profile HTTP/1.1\r\nOrigin: " <> originBytes <> "\r\n\r\n"
       ]
    ++ [ "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\n" <> headers <> "\r\n" <> payload
       | (headers, payload) <-
           [ ("", "")
           , ("Content-Type: application/json\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 1, 2\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 999999999999999999999999\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 0\r\nContent-Encoding: gzip\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 0\r\nContent-Encoding: identity\r\n", "")
           , ("Content-Type: application/json\r\nContent-Type: application/json\r\nContent-Length: 0\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 0\r\nExpect: 100-continue\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 1\r\nExpect: x\r\n", "x")
           , ("Content-Type: application/json\r\nContent-Length: 0\r\nContent-Length: 0\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 2\r\n", "{")
           , ("Content-Type: application/json\r\nContent-Length: 1048576\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length: 1048577\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length: 0001048577\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length: 00\r\n", "")
           , ("Content-Type: application/json\r\nContent-Length: 02\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length:  2\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length:\t2\r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length: 2 \r\n", "{}")
           , ("Content-Type: application/json\r\nContent-Length:\r\n", "")
           ]
       ]
    ++ [ "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\nContent-Type: application/json\r\nContent-Length:" <> lexeme <> "\r\n\r\n"
       | lexeme <- ["+1", "-1", "1 0", "1 ", "1, 1", "1048577", "999999999999999999999999999", "\x31\xa0", "0x1", "1e3", "\xd9\xa3", "\xef\xbc\x91"]
       ]
    ++ [ framed "POST" "/v1/simulations" [("Content-Type", media)] "{}"
       | media <-
           [ "application/json; charset=utf-8"
           , "application/json;charset=UTF-8"
           , "APPLICATION/JSON"
           , " application/json "
           , "application/json ; charset=utf-8"
           , "application/json; charset=latin-1"
           , "application/json; charset=utf-8; x=1"
           , "application/json;"
           , "application/json; charset=\"utf-8\""
           , "text/plain"
           , "application/json\xa0"
           , "application/json\x85"
           , "\x1c\&application/json"
           , "application/jsonx"
           ]
       ]
    ++ map
      simulationRequest
      ( [ "{"
        , "\xff"
        , "[]"
        , "null"
        , "{}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":NaN}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":Infinity}"
        , "{\"expected_definition\":{},\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":true}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1,\"x\":{\"a\":1,\"a\":2}}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1e400}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":\"\\ud800\"}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1,\"extra\":{\"nested\":\"\\udc00\\ud800\"}}"
        , "{\"expected_definition\":{},\"initial_marking\":[]}"
        , "{\"expected_definition\": 1, \"initial_marking\": [], \"max_actions\": 1}"
        , "{\"expected_definition\": 1.0, \"initial_marking\": [], \"max_actions\": 1}"
        , "{\"expected_definition\": true, \"initial_marking\": [], \"max_actions\": 1}"
        , "{\"expected_definition\": [], \"initial_marking\": [], \"max_actions\": 1}"
        , " {\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1} "
        , "\xef\xbb\xbf{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}"
        , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}x"
        , BC.replicate 1200 '[' <> "0" <> BC.replicate 1200 ']'
        , "{\"x\":" <> BC.replicate 1200 '[' <> "0" <> BC.replicate 1200 ']' <> "}"
        ]
          ++ [ body' definition marking (Int 1)
             | marking <-
                 [ Null
                 , Object []
                 , Array [Null]
                 , Array [Object [("place", String "pending")]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [token Null Null]), ("x", Null)]]
                 , Array [Object [("place", Int 1), ("tokens", Array [token Null Null])]]
                 , Array [Object [("place", String ""), ("tokens", Array [token Null Null])]]
                 , Array [Object [("place", String "a b"), ("tokens", Array [token Null Null])]]
                 , Array [Object [("place", String "/pending"), ("tokens", Array [token Null Null])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [])]]
                 , Array [Object [("place", String "pending"), ("tokens", Null)]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [Null])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [Object [("color", Null)]])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [Object [("color", Null), ("data", Null), ("x", Null)]])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [token (Int 1) Null])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [token (String "") Null])]]
                 , Array [Object [("place", String "pending"), ("tokens", Array [token (Bool True) Null])]]
                 , Array [entry "pending" [token item (priority 1)], entry "done" [token item Null]]
                 , Array [entry "pending" [token item (priority 1)], entry "pending" [token item Null]]
                 , Array [entry "pending" [token item (priority 1)], entry "done" [token item Null]]
                 , Array [entry "pending" [token item (priority 1)], entry "foreign" [token Null Null]]
                 , Array [entry "foreign" [token Null Null]]
                 , Array [entry "pending" [token (String "Other") (priority 1)]]
                 , Array [entry "pending" [token Null (priority 1)]]
                 , Array [entry "pending" (replicate 513 (token item (priority 1)))]
                 , Array [entry "pending" [token item (String (T.replicate 1000001 "x"))]]
                 , Array [entry "pending" [token item (priority 0)]]
                 , Array [entry "pending" [token item Null]]
                 , Array [entry "pending" [token item (String "x")]]
                 , Array [entry "pending" [token item (Object [("priority", String "high")])]]
                 , Array [entry "pending" [token item (Object [("priority", Float 1.5)])]]
                 , Array [entry "pending" [token item (Object [("priority", Int 1), ("\233", String "\128512")])]]
                 , Array [entry "done" [token item (priority 1)]]
                 , Array [entry "pending" [token item (priority 1), token item (priority 2), token item (priority 0)]]
                 , scenarioMarking
                 ]
             ]
          ++ [body' definition scenarioMarking value | value <- [Int 0, Int (-1), Int 257, Int 256, Int 2, Int 32, Float 1.0, Bool False, String "1", Null, Array []]]
          ++ [ body' expected (Array []) (Int 1)
             | expected <- [Object [], setWeight (Float 1.0), setWeight (Bool True), setWeight (Int 2), reorderedDefinition]
             ]
      )
  where
    token color data' = Object [("color", color), ("data", data')]
    entry place tokens = Object [("place", String place), ("tokens", Array tokens)]
    item = String "SimulationItem"
    priority n = Object [("priority", Int n)]
    setWeight replacement = case definition of
      Object members -> Object [(k, if k == "arcs" then firstWeight replacement v else v) | (k, v) <- members]
      other -> other
    firstWeight replacement = \case
      Array (Object first : rest) -> Array (Object [(k, if k == "weight" then replacement else v) | (k, v) <- first] : rest)
      other -> other
    reorderedDefinition = case definition of
      Object members -> Object (reverse members)
      other -> other

-- | 300 generated simulation bodies over the decoder's and the runner's
-- pieces: markings of the fixed build's places with typed, mistyped and
-- untyped tokens of many data shapes, in and out of order, and every kind of
-- @max_actions@.
generatedBodies :: [ByteString]
generatedBodies = take 300 (go (randoms 11))
  where
    places = ["pending", "done", "foreign", "a", "zzz"]
    colors = [String "SimulationItem", String "SimulationItem", String "SimulationItem", Null, String "Other"]
    datas =
      [ Object [("priority", Int 1)]
      , Object [("priority", Int 2), ("id", String "x")]
      , Object [("priority", Int 0)]
      , Object [("priority", Float 3.5)]
      , Object [("priority", Int 100000000000000000000)]
      , Object [("priority", String "1")]
      , Object []
      , Null
      , Int 7
      , String "\233t\233"
      , Array [Int 1, Null, Bool False]
      , Object [("priority", Int 1), ("nested", Object [("deep", Array [Object [("k", Float (-0.0))]])])]
      ]
    maxActionsChoices = [Int 1, Int 2, Int 3, Int 5, Int 32, Int 256, Int 0, Int 257, Float 2.0]
    pick xs r = xs !! fromIntegral (r `mod` fromIntegral (length xs))
    go (r0 : r1 : r2 : rs) =
      let entryCount = fromIntegral (r0 `mod` 3)
          (chosen, rest) = takeEntries entryCount rs
          maxActions = pick maxActionsChoices r1
          expected = if r2 `mod` 23 == 0 then Object [] else definition
       in body' expected (Array chosen) maxActions : go rest
    go _ = []
    takeEntries :: Int -> [Word64] -> ([Json], [Word64])
    takeEntries 0 rs = ([], rs)
    takeEntries n (p : k : rs) =
      let tokenCount = fromIntegral (k `mod` 4)
          (tokens, rest) = takeTokens tokenCount rs
          (others, rest') = takeEntries (n - 1) rest
          placed = Object [("place", String (pick places p)), ("tokens", Array tokens)]
       in (placed : others, rest')
    takeEntries _ rs = ([], rs)
    takeTokens :: Int -> [Word64] -> ([Json], [Word64])
    takeTokens 0 rs = ([], rs)
    takeTokens n (c : d : rs) =
      let (others, rest) = takeTokens (n - 1) rs
       in (Object [("color", pick colors c), ("data", pick datas d)] : others, rest)
    takeTokens _ rs = ([], rs)

randoms :: Word64 -> [Word64]
randoms = unfoldr (\s -> let s' = s + 0x9E3779B97F4A7C15 in Just (mix s', s'))
  where
    mix z0 =
      let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
          z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
       in z2 `xor` (z2 `shiftR` 31)
