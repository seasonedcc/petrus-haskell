-- | The agent relay at @/ws/agent@: port of tests/bridgeVitePlugin.test.mjs
-- plus the routing function on its own.
module RelaySpec (spec) where

import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (showHex)
import Petrus.Viewer.Json
import Petrus.Viewer.Json.Canonical (canonicalObject)
import Petrus.Viewer.Relay
import Petrus.Viewer.Server (ServerHandle (..))
import Test.Hspec
import Test.QuickCheck
import TestSupport

-- | The full JSON.parse / JSON.stringify path, without the fast path.
slowRoute :: RelayKind -> B.ByteString -> Maybe Routed
slowRoute k raw = either (const Nothing) (relayMessage k (jsString "7")) (parseJs raw)

-- | What a routing decision shows to the relay.
observe :: Maybe Routed -> Maybe (BL.ByteString, Bool, Maybe JsValue, [Maybe JsValue])
observe = fmap $ \r ->
  ( routedBytes r
  , routedTargeted r
  , routedTarget r
  , map (routedLookup r . jsString) ["protocol", "kind", "requestId", "action", "ok", "clientId", "peerId", "targetClientId", "a", "0"]
  )

-- | A JSON object text, spelled as JSON.stringify prints it or (when not
-- canonical) with the spellings JSON.parse accepts but JSON.stringify never
-- prints: whitespace, other escapes, number forms, duplicate and
-- array-index keys.
data Wire = Wire Bool B.ByteString

instance Show Wire where
  show (Wire c b) = (if c then "canonical " else "free ") <> show b

instance Arbitrary Wire where
  arbitrary = do
    canonical <- arbitrary
    b <- sized (\n -> object canonical (min 3 (n `div` 10)))
    pure (Wire canonical (BL.toStrict (BB.toLazyByteString b)))
    where
      object canonical depth = do
        keys <-
          if canonical
            then take 6 . nub <$> listOf (elements plainKeys)
            else resize 6 (listOf (elements (plainKeys ++ ["0", "1", "10", "01", "4294967295", "clientId"])))
        vals <- mapM (const (value canonical depth)) keys
        ks <- mapM (string canonical) keys
        sep <- mapM (const (ws canonical)) [0 .. 4 * length keys + 2 :: Int]
        let members = [s1 <> k <> s2 <> ":" <> s3 <> v <> s4 | (k, v, (s1, s2, s3, s4)) <- zip3 ks vals (quads sep)]
        pure ("{" <> commaSep members <> "}")
      quads (a : b : c : d : r) = (a, b, c, d) : quads r
      quads _ = repeat ("", "", "", "")
      commaSep [] = mempty
      commaSep (x : xs) = x <> foldMap ("," <>) xs
      plainKeys = ["a", "b", "clientId", "peerId", "targetClientId", "targetPeerId", "protocol", "kind", "requestId", "action", "ok", "\233", "", "x/y"]
      ws canonical = if canonical then pure "" else elements ["", "", "", " ", "\n\t "]
      value canonical depth =
        frequency $
          [ (2, elements ["null", "true", "false"])
          , (3, number canonical)
          , (4, string canonical =<< text)
          , (1, pure "\"petrus-agent\"")
          , (1, elements ["\"request\"", "\"response\"", "\"1\"", "\"2\"", "\"\"", "0", "1"])
          ]
            ++ ( if depth > 0
                   then
                     [ (1, object canonical (depth - 1))
                     , (1, (\xs -> "[" <> commaSep xs <> "]") <$> resize 4 (listOf (value canonical (depth - 1))))
                     ]
                   else []
               )
      number canonical =
        if canonical
          then oneof [BB.intDec <$> arbitrary, elements ["0.5", "1e+21", "-1.25", "123456789012345680000", "5e-7"]]
          else elements ["1.0", "1e2", "-0", "0.50", "1E21", "12345678901234567890", "1e-7", "007"]
      text = T.pack <$> listOf (frequency [(4, choose ('a', 'z')), (2, elements "\"\\/\n\t\b\f\r\x1f\x7f\233\x2028"), (1, elements "\x1F600\xFFFF")])
      string :: Bool -> T.Text -> Gen BB.Builder
      string canonical t = do
        parts <- mapM (char canonical) (T.unpack t)
        lone <- if canonical then elements ["", "", "\\ud800", "\\udfff"] else elements ["", "\\uD800", "\\ud800\\udc00", "\\u00e9"]
        pure ("\"" <> mconcat parts <> lone <> "\"")
      char canonical c =
        let canon = BB.byteString (TE.encodeUtf8 (stringifyChar c))
         in if canonical
              then pure canon
              else
                frequency
                  [ (4, pure canon)
                  , (1, pure (escapeU (fromEnum c)))
                  , (1, pure (if c == '/' then "\\/" else canon))
                  ]
      escapeU n
        | n >= 0x10000 = let m = n - 0x10000 in hex4 (0xD800 + m `div` 0x400) <> hex4 (0xDC00 + m `mod` 0x400)
        | otherwise = hex4 n
      hex4 n = BB.string7 ("\\u" <> pad (showHex n ""))
      pad s = replicate (4 - length s) '0' <> s

-- | One character as JSON.stringify writes it inside a string literal.
stringifyChar :: Char -> T.Text
stringifyChar = \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\r' -> "\\r"
  '\t' -> "\\t"
  '\b' -> "\\b"
  '\f' -> "\\f"
  c
    | c < ' ' -> T.pack ("\\u00" <> (if fromEnum c < 16 then "0" else "") <> showHex (fromEnum c) "")
    | otherwise -> T.singleton c

routed :: RelayKind -> BL.ByteString -> Maybe BL.ByteString
routed k raw = either (const Nothing) (fmap routedBytes . relayMessage k (jsString "7")) (parseJ raw)

agent :: (Int -> IO a) -> IO a
agent act = withViewer id (act . handlePort)

connect :: Int -> (WsClient -> JsValue -> IO a) -> IO a
connect port act = withWs port "/ws/agent" $ \c -> recvJson c >>= act c

spec :: Spec
spec = do
  describe "relayMessage" $ do
    it "stamps the sender id, overwriting a spoofed one in place" $ do
      routed AgentRelay "{\"action\":\"x\"}" `shouldBe` Just "{\"action\":\"x\",\"clientId\":\"7\"}"
      routed AgentRelay "{\"clientId\":\"fake\",\"a\":1}" `shouldBe` Just "{\"clientId\":\"7\",\"a\":1}"
      routed CollabRelay "{\"type\":\"cursor\"}" `shouldBe` Just "{\"type\":\"cursor\",\"peerId\":\"7\"}"
    it "re-serializes with JSON.stringify semantics" $
      routed AgentRelay "{ \"b\" : 1.50, \"1\": [1e21, \"\\u00e9\"] }" `shouldBe` Just "{\"1\":[1e+21,\"\xc3\xa9\"],\"b\":1.5,\"clientId\":\"7\"}"
    it "drops what Node drops: non-objects on the agent relay, primitives on collab" $ do
      routed AgentRelay "[1,2]" `shouldBe` Nothing
      routed AgentRelay "42" `shouldBe` Nothing
      routed AgentRelay "null" `shouldBe` Nothing
      routed CollabRelay "null" `shouldBe` Nothing
      routed CollabRelay "\"s\"" `shouldBe` Nothing
    it "relays arrays on collab unchanged (the id property is not serialized)" $
      routed CollabRelay "[1, {\"a\":2}]" `shouldBe` Just "[1,{\"a\":2}]"
    it "marks targeted messages" $ do
      let r = either (const Nothing) (relayMessage AgentRelay (jsString "7")) (parseJ "{\"targetClientId\":\"2\"}")
      fmap routedTargeted r `shouldBe` Just True
      fmap (isJust . routedTarget) r `shouldBe` Just True

  describe "routeRaw (fast path for JSON.stringify-shaped text)" $ do
    it "splices the id in place or at the end" $ do
      let fast k raw = routedBytes <$> routeRaw k (jsString "7") raw
      fast AgentRelay "{}" `shouldBe` Just "{\"clientId\":\"7\"}"
      fast AgentRelay "{\"a\":[1,{\"b\":null}]}" `shouldBe` Just "{\"a\":[1,{\"b\":null}],\"clientId\":\"7\"}"
      fast AgentRelay "{\"clientId\":{\"x\":1},\"a\":1}" `shouldBe` Just "{\"clientId\":\"7\",\"a\":1}"
      fast CollabRelay "{\"type\":\"cursor\",\"x\":1.5}" `shouldBe` Just "{\"type\":\"cursor\",\"x\":1.5,\"peerId\":\"7\"}"
    it "accepts only text that JSON.stringify(JSON.parse(text)) reproduces" $ do
      canonicalObject "{\"a\":\"\\u001f\\ud800\\n\"}" `shouldSatisfy` isJust
      mapM_
        (\t -> canonicalObject t `shouldBe` Nothing)
        [ "{\"a\": 1}"
        , "{\"a\":1.0}"
        , "{\"a\":-0}"
        , "{\"a\":\"\\/\"}"
        , "{\"a\":\"\\u00E9\"}"
        , "{\"a\":\"\\u0041\"}"
        , "{\"a\":\"\\ud83d\\ude00\"}"
        , "{\"a\":1,\"a\":2}"
        , "{\"b\":{\"1\":0}}"
        , "{\"a\":1} "
        , "{\"a\":1,}"
        , "[1]"
        ]
    it "routes every text exactly like the full parse and stringify" $
      property $ \(Wire canonical raw) ->
        let fastPath = isJust (canonicalObject raw)
         in classify fastPath "fast path" $
              counterexample "canonical text not accepted" (not canonical || fastPath)
                .&&. conjoin [observe (routeRaw k (jsString "7") raw) === observe (slowRoute k raw) | k <- [AgentRelay, CollabRelay]]

  describe "/ws/agent (tests/bridgeVitePlugin.test.mjs)" $ do
    it "sends welcome with clientId on connect" $ agent $ \port ->
      connect port $ \_ welcome -> do
        textField "type" welcome `shouldBe` Just "welcome"
        textField "clientId" welcome `shouldSatisfy` isJust

    it "relays messages between clients" $ agent $ \port ->
      connect port $ \c1 w1 -> connect port $ \c2 _ -> do
        _ <- drainFor 50 c1
        _ <- drainFor 50 c2
        sendText c1 "{\"action\":\"test.ping\"}"
        m <- recvJson c2
        textField "action" m `shouldBe` Just "test.ping"
        textField "clientId" m `shouldBe` textField "clientId" w1

    it "supports targeted messages" $ agent $ \port ->
      connect port $ \c1 _ -> connect port $ \c2 w2 -> connect port $ \c3 _ -> do
        mapM_ (drainFor 50) [c1, c2, c3]
        let target = maybe "" (encodeJsLazy . JsStr . jsString) (textField "clientId" w2)
        sendText c1 ("{\"action\":\"targeted\",\"targetClientId\":" <> target <> "}")
        m <- recvJson c2
        textField "action" m `shouldBe` Just "targeted"
        others <- drainFor 100 c3
        filter ((== Just "targeted") . textField "action") others `shouldBe` []

    it "overwrites spoofed clientId" $ agent $ \port ->
      connect port $ \c1 w1 -> connect port $ \c2 _ -> do
        _ <- drainFor 50 c1
        _ <- drainFor 50 c2
        sendText c1 "{\"action\":\"spoof\",\"clientId\":\"fake\"}"
        m <- recvJson c2
        textField "clientId" m `shouldBe` textField "clientId" w1

    it "ignores non-object JSON" $ agent $ \port ->
      connect port $ \c1 _ -> do
        mapM_ (sendText c1) ["42", "null", "[1,2]", "not json"]
        connect port $ \_ w2 -> textField "type" w2 `shouldBe` Just "welcome"

    it "broadcasts client_count on join and leave + client_count on close" $ agent $ \port ->
      connect port $ \c1 _ -> do
        first <- recvJson c1
        textField "type" first `shouldBe` Just "client_count"
        field "count" first `shouldBe` Just (int 1)
        leaverId <- connect port $ \c2 w2 -> do
          joined <- recvJson c1
          field "count" joined `shouldBe` Just (int 2)
          closeWs c2
          pure (textField "clientId" w2)
        leave <- recvJson c1
        textField "type" leave `shouldBe` Just "leave"
        textField "clientId" leave `shouldBe` leaverId
        count <- recvJson c1
        field "count" count `shouldBe` Just (int 1)

    it "delivers the newcomer's welcome before any count" $ agent $ \port ->
      connect port $ \_ welcome -> textField "type" welcome `shouldBe` Just "welcome"
