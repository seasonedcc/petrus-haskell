-- | The MCP stdio server (server/mcp.mjs semantics).
--
-- The golden test replays a JSON-RPC session (test/fixtures/mcp-requests.json:
-- every tool, validation failures, unknown methods, a garbage line, protocol
-- version negotiation) through the built @petrus-mcp@ executable, bridged to a
-- fake browser over this package's relay, and compares stdout byte for byte
-- with the transcript the upstream Node server produced for the same session
-- against the same fake browser (test/fixtures/mcp-transcript-node.txt;
-- the port, working directory and screenshot timestamp are normalized).
module McpSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (forM_, forever, void)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Viewer.Json
import Petrus.Viewer.Mcp.Server (Tool (..), tools)
import Petrus.Viewer.Server (ServerHandle (..))
import System.Directory (canonicalizePath, createDirectory)
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import System.Timeout (timeout)
import Test.Hspec
import TestSupport

-- | Answers agent requests like the fake browser of the Node capture.
fakeBrowser :: WsClient -> IO ()
fakeBrowser c = forever $ do
  next <- recvWithin 60000 c
  case next of
    Just m
      | textField "protocol" m == Just "petrus-agent"
      , textField "kind" m == Just "request" -> sendText c (encodeJsLazy (answer m))
    _ -> pure ()
  where
    answer m =
      let action = textField "action" m
          (ok, payload) = case action of
            Just "simulation.inspect" ->
              ( True
              , obj
                  [ ("mode", str "edit")
                  , ("revision", str "rev-1")
                  , ("isTerminal", JsBool False)
                  , ( "state"
                    , obj
                        [ ("net", str "test")
                        , ( "states"
                          , arr
                              [ obj [("fired", JsNull), ("marking", obj [("p1", int 1), ("p2", int 0)]), ("context", obj [])]
                              , obj [("fired", str "t1"), ("marking", obj [("p1", int 0), ("p2", num 1.5), ("10", int 2)]), ("context", obj [])]
                              ]
                          )
                        , ("current", int 1)
                        ]
                    )
                  ]
              )
            Just "canvas.screenshot" -> (True, obj [("base64", str "iVBORw0KGgo=")])
            Just "document.open" -> (True, obj [("netName", str "opened")])
            Just "schema.undo" -> (False, obj [("code", str "conflict"), ("message", str "Nothing to undo")])
            _ ->
              ( True
              , obj
                  [ ("echo", maybe JsNull id (field "params" m))
                  , ("action", maybe JsNull str action)
                  , ("unicode", str "\233\x2028\128512")
                  , ("num", arr [num 1.5, num 1e21, num 0.1, num (-0.0), num 123456789012])
                  ]
              )
       in obj
            ( [ ("protocol", str "petrus-agent")
              , ("version", int 1)
              , ("kind", str "response")
              , ("requestId", maybe JsNull id (field "requestId" m))
              , ("action", maybe JsNull str action)
              , ("ok", JsBool ok)
              , ("targetClientId", maybe JsNull id (field "clientId" m))
              ]
                ++ [(if ok then "result" else "error", payload)]
            )

-- | Replace every @prefix<digits>@ with @prefix<STAMP>@.
normalizeStamp :: Text -> Text -> Text
normalizeStamp prefix t = case T.breakOn prefix t of
  (pre, rest)
    | T.null rest -> pre
    | otherwise ->
        let afterPrefix = T.drop (T.length prefix) rest
            digits = T.takeWhile isDigit afterPrefix
            stamp = if T.null digits then "" else "<STAMP>"
         in pre <> prefix <> stamp <> normalizeStamp prefix (T.drop (T.length digits) afterPrefix)

-- | Run the recorded session through @petrus-mcp@; its stdout, normalized.
runSession :: IO Text
runSession = withSystemTempDirectory "petrus-mcp-golden-" $ \tmp -> do
  cwd <- canonicalizePath tmp
  createDirectory (cwd </> "examples")
  B.writeFile (cwd </> "examples" </> "sample-net.json") "{\"fileVersion\":\"2\",\"net\":\"sample\",\"arcs\":[],\"places\":{},\"transitions\":{}}\n"
  B.writeFile (cwd </> "package.json") "{\"name\":\"fixture\"}\n"
  B.writeFile (cwd </> "index.html") "<!doctype html>\n<html><body></body></html>\n"
  reqsRaw <- B.readFile (fixturePath "mcp-requests.json")
  reqs <- case parseJs reqsRaw of
    Right (JsArr xs) -> pure xs
    other -> fail ("bad mcp-requests.json: " <> show other)
  withViewer id $ \h -> do
    let port = handlePort h
    withWs port "/ws/agent" $ \browser -> do
      _ <- recvJson browser -- welcome
      withAsync (fakeBrowser browser) $ \_ -> do
        env0 <- getEnvironment
        let env =
              [ (k, v)
              | (k, v) <- env0
              , k `notElem` ["PETRUS_AGENT_URL", "PETRUS_MCP_REQUEST_TIMEOUT_MS", "PETRUS_HISTORY_URL", "PETRUS_PERF"]
              ]
                ++ [ ("PETRUS_AGENT_URL", "ws://localhost:" <> show port <> "/ws/agent")
                   , ("PETRUS_MCP_REQUEST_TIMEOUT_MS", "300")
                   ]
            cp = (proc "petrus-mcp" []) {cwd = Just cwd, env = Just env, std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
        bracket (createProcess cp) cleanupProcess $ \case
          (Just hin, Just hout, Just herr, _) -> do
            hSetBuffering hin LineBuffering
            out <- newTQueueIO
            let pump = forever (BC.hGetLine hout >>= atomically . writeTQueue out)
                drainErr = forever (void (BC.hGetLine herr))
            withAsync pump $ \_ -> withAsync drainErr $ \_ -> do
              lines' <- newTVarIO []
              forM_ reqs $ \r -> do
                let line = case r of
                      JsStr s -> jsStringBytes s
                      v -> encodeJs v
                B.hPut hin (line <> "\n")
                hFlush hin
                case field "id" r of
                  Just _ -> do
                    got <- timeout 10000000 (atomically (readTQueue out))
                    case got of
                      Just l -> atomically (modifyTVar' lines' (l :))
                      Nothing -> expectationFailure ("no response to " <> BC.unpack line)
                  Nothing -> do
                    threadDelay 200000
                    extra <- atomically (flushTQueue out)
                    atomically (modifyTVar' lines' (reverse extra ++))
              ls <- reverse <$> readTVarIO lines'
              let raw = TE.decodeUtf8 (B.concat [l <> "\n" | l <- ls])
              pure
                ( normalizeStamp "canvas-"
                    . T.replace (T.pack cwd) "<CWD>"
                    . T.replace (":" <> T.pack (show port) <> "/") ":<PORT>/"
                    $ raw
                )
          _ -> fail "petrus-mcp pipes"

spec :: Spec
spec = describe "petrus-mcp" $ do
  it "exposes the 16 upstream tools in order" $
    map toolName tools
      `shouldBe` [ "petrus_status"
                 , "petrus_inspect_document"
                 , "petrus_inspect_canvas"
                 , "petrus_inspect_selection"
                 , "petrus_inspect_simulation"
                 , "petrus_preview_mutation"
                 , "petrus_apply_mutation"
                 , "petrus_undo"
                 , "petrus_redo"
                 , "petrus_simulation_command"
                 , "petrus_scenario_save"
                 , "petrus_scenario_compare"
                 , "petrus_trace_import"
                 , "petrus_trace_scenarios"
                 , "petrus_screenshot"
                 , "petrus_open_file"
                 ]

  it "reproduces the upstream Node transcript byte for byte" $ do
    expected <- TE.decodeUtf8 <$> B.readFile (fixturePath "mcp-transcript-node.txt")
    actual <- runSession
    let pairs = zip3 [1 :: Int ..] (T.lines expected) (T.lines actual)
    forM_ pairs $ \(i, e, a) ->
      if e == a then pure () else expectationFailure ("line " <> show i <> " differs\nnode:    " <> T.unpack e <> "\nhaskell: " <> T.unpack a)
    length (T.lines actual) `shouldBe` length (T.lines expected)
    BL.length (BL.fromStrict (TE.encodeUtf8 actual)) `shouldSatisfy` (> 0)
