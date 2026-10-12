-- | Test oracle (@petrus-viewer-server-test --oracle@): evaluates the Haskell ports of the viewer's server-side
-- library functions so the upstream Node test files (and differential
-- fuzzing against Node) can call them.
--
-- stdin: a JSON array of calls, each @[name, ...args]@.
-- stdout: a JSON array of results, each @{"ok": value}@ or @{"error": message}@.
--
-- Calls: @slugifyUrl url@, @getCacheDir slug@, @cacheRelativePath url@,
-- @cacheFile slug relativePath content@, @normalizeGitHubUrl url@,
-- @resolveUrl input base@, @jsonRoundTrip text@ (@JSON.stringify(JSON.parse(text))@),
-- @relayAgent text@ / @relayCollab text@ (the relay's output for a message
-- from client @"7"@, or null when it is dropped), @parseAgentMessage text@
-- (the normalized message; the upstream protocol tests call it through
-- @upstream-tests/shims/haskell-protocol.mjs@).
module Oracle (runOracle) where

import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Viewer.Agent.Protocol (messageObject, parseAgentMessage)
import Petrus.Viewer.Json
import Petrus.Viewer.Relay (RelayKind (..), Routed (..), relayMessage)
import Petrus.Viewer.Url
import Petrus.Viewer.UrlCache
import Data.ByteString.Lazy qualified as BL

runOracle :: IO ()
runOracle = do
  input <- B.getContents
  case parseJs (decodeLenient input) of
    Right (JsArr calls) -> do
      results <- mapM call calls
      B.putStr (encodeJs (arr results))
    _ -> B.putStr (encodeJs (obj [("error", str "expected a JSON array of calls")]))

ok :: JsValue -> JsValue
ok v = obj [("ok", v)]

err :: Text -> JsValue
err e = obj [("error", str e)]

-- | An error whose message is a JavaScript string (lone surrogates kept).
errJs :: JsString -> JsValue
errJs e = obj [("error", JsStr e)]

call :: JsValue -> IO JsValue
call = \case
  JsArr (JsStr name : args) -> run (jsStringText name) args
  _ -> pure (err "bad call")
  where
    text = \case
      JsStr s -> jsStringText s
      other -> jsToString other
    run name args = case (name, args) of
      ("slugifyUrl", [u]) -> pure (either err (ok . maybe JsNull str) (slugifyUrl (text u)))
      ("getCacheDir", [s]) -> ok . str . T.pack <$> getCacheDir (text s)
      ("cacheRelativePath", [u]) -> pure (either err (ok . str) (cacheRelativePath (text u)))
      ("cacheFile", [s, r, c]) -> ok . str . T.pack <$> cacheFile (text s) (text r) (text c)
      ("normalizeGitHubUrl", [u]) -> pure (ok (str (normalizeGitHubUrl (text u))))
      ("resolveUrl", [i, b]) -> pure (maybe (err "Invalid URL") (ok . str . serializeUrl) (resolveUrl (text i) (text b)))
      ("jsonRoundTrip", [JsStr s]) -> pure (either errJs (ok . str . TE.decodeUtf8 . encodeJs) (parseJs (raw s)))
      ("relayAgent", [JsStr s]) -> pure (relay AgentRelay s)
      ("relayCollab", [JsStr s]) -> pure (relay CollabRelay s)
      ("parseAgentMessage", [JsStr s]) ->
        pure $ case parseJs (raw s) of
          Left e -> errJs e
          Right v -> either err (ok . JsObj . messageObject) (parseAgentMessage v)
      _ -> pure (err ("unknown call " <> name))
    -- the JavaScript string's UTF-8 bytes (lone surrogates become U+FFFD,
    -- as in Buffer.from(string))
    raw = TE.encodeUtf8 . jsStringText
    relay k s = case parseJs (raw s) of
      Left _ -> ok JsNull
      Right v -> case relayMessage k (jsString "7") v of
        Nothing -> ok JsNull
        Just r -> ok (str (TE.decodeUtf8 (BL.toStrict (routedBytes r))))
