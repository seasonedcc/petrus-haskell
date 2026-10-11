-- | The Petrus MCP server (@server/mcp.mjs@): a stdio JSON-RPC server
-- exposing the viewer's agent capabilities as MCP tools.
--
-- Wire behaviour follows the TypeScript MCP SDK (1.29) that the Node server
-- runs on: newline-delimited JSON-RPC, concurrent request handling,
-- @notifications/cancelled@ suppressing the response, the same
-- @initialize@ negotiation, the same @tools/list@ payload, argument
-- validation reported as tool errors, and the same result texts.
module Petrus.Viewer.Mcp.Server
  ( runMcpServer
  , McpServer
  , newMcpServer
  , handleLine
  , tools
  , Tool (..)
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Functor ((<&>))
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Petrus.Viewer.Agent.Protocol (RequestAction (..), requestActionName)
import Petrus.Viewer.Endpoints (readFileNode)
import Petrus.Viewer.Json
import Petrus.Viewer.Log
import Petrus.Viewer.Mcp.Bridge
import Petrus.Viewer.Mcp.History
import Petrus.Viewer.Mcp.Reactor (Reactor, readLines, withReactor)
import Petrus.Viewer.Mcp.Schema
import Petrus.Viewer.UrlCache (normalizePosix)
import System.Directory (createDirectoryIfMissing, doesPathExist, getCurrentDirectory)
import Foreign.C.Types (CInt)
import GHC.IO.Device (IODeviceType (Stream))
import GHC.IO.FD qualified as FD
import GHC.IO.Handle.FD (mkHandleFromFD)
import System.Exit (exitWith, ExitCode (..))
import System.IO
import System.Posix.Files (getFdStatus, isNamedPipe, isSocket)
import System.Posix.IO (FdOption (NonBlockingRead), setFdOption)
import System.Posix.Types (Fd (..))

data Tool = Tool
  { toolName :: Text
  , toolDescription :: Text
  , toolShape :: [(Text, Field)]
  , toolPassthroughArgs :: Bool
  , toolRun :: McpServer -> JsObject -> IO ToolResult
  }

-- | The text of a tool result (already a JSON string) and whether it is
-- an error.
data ToolResult = ToolResult JsString Bool

data McpServer = McpServer
  { bridge :: Bridge
  , historySource :: Maybe HistorySource
  -- ^ where @petrus_trace_import@ fetches runtime state (opt-in)
  , perfL :: PerfLog
  , scenarios :: IORef (Map Text JsValue)
  , inflight :: IORef (Map ByteString Bool)
  -- ^ encoded request id → cancelled
  , out :: MVar Handle
  -- ^ where responses go, one writer at a time
  }

newMcpServer :: BridgeConfig -> Maybe HistorySource -> PerfLog -> Handle -> Reactor -> IO McpServer
newMcpServer cfg hist pl h r = do
  b <- newBridge cfg pl r
  McpServer b hist pl <$> newIORef Map.empty <*> newIORef Map.empty <*> newMVar h

-- | Run on stdin/stdout. As in Node, the bridge is ensured before the MCP
-- transport starts; when it cannot be reached the process fails.
--
-- Standard input is read on the event loop ("Petrus.Viewer.Mcp.Reactor")
-- when it is a pipe or a socket, as when an MCP client spawns the server;
-- a terminal or a file is read through its handle (kqueue does not watch
-- terminals, and epoll no regular files).
runMcpServer :: IO ()
runMcpServer = withReactor $ \reactor -> do
  inputIsStream <- isStream 0
  output <- streamHandle 1 WriteMode stdout "<stdout>"
  hSetBuffering output (BlockBuffering Nothing)
  hSetBinaryMode output True
  cfg <- bridgeConfigFromEnv
  pl <- mkPerfLog
  hist <- historySourceFromEnv
  server <- newMcpServer cfg hist pl output reactor
  t0 <- monotonicMs
  r <- ensureBridge (bridge server)
  case r of
    Left e -> do
      hPutStrLn stderr ("Error: " <> T.unpack e)
      exitWith (ExitFailure 1)
    Right () -> pure ()
  t1 <- monotonicMs
  perfLog pl "bridge-ready" [("ms", num (fixed1 (t1 - t0)))]
  perfLog pl "mcp-server-ready" []
  if inputIsStream
    then do
      ended <- newEmptyMVar
      readLines reactor 0 (handleLine server . stripCR) (putMVar ended ())
      takeMVar ended
    else do
      hSetBinaryMode stdin True
      let loop = do
            eof <- hIsEOF stdin
            unless eof $ do
              line <- BC.hGetLine stdin
              handleLine server (stripCR line)
              loop
      loop
  where
    stripCR l = if not (B.null l) && BC.last l == '\r' then B.init l else l

-- | Whether a standard stream is a pipe or a socket.
isStream :: CInt -> IO Bool
isStream fd =
  try @IOException (getFdStatus (Fd fd)) <&> \case
    Right st -> isNamedPipe st || isSocket st
    Left _ -> False

-- | The standard stream @fd@ for the responses. When it is a pipe or a
-- socket it is put in non-blocking mode, as libuv does with Node's stdio
-- pipes: a write then waits in the I/O manager only when the pipe is full,
-- instead of a readiness poll and a blocking (safe) foreign call each,
-- which with requests in flight hand the capability to another OS thread
-- on every response. Terminals and files keep the standard handle.
streamHandle :: CInt -> IOMode -> Handle -> FilePath -> IO Handle
streamHandle fd mode std name = do
  stream <- isStream fd
  if stream
    then do
      setFdOption (Fd fd) NonBlockingRead True
      (dev, _) <- FD.mkFD fd mode (Just (Stream, 0, 0)) False True
      mkHandleFromFD dev Stream name mode False Nothing
    else pure std

send :: McpServer -> JsValue -> IO ()
send s v = withMVar (out s) $ \h -> do
  B.hPut h (encodeJs v <> "\n")
  hFlush h

-- | Handle one JSON-RPC line.
handleLine :: McpServer -> ByteString -> IO ()
handleLine s line = case parseJs (decodeLenient line) of
  Right (JsObj m)
    | lookupKey "jsonrpc" m == Just (str "2.0") -> dispatch s m
  _ -> pure ()

validId :: JsValue -> Bool
validId = \case
  JsStr _ -> True
  JsNum n -> let d = jsNumberValue n in d == fromIntegral (truncate d :: Integer) && abs d <= 9007199254740991
  _ -> False

dispatch :: McpServer -> JsObject -> IO ()
dispatch s m = case (lookupKey "method" m, lookupKey "id" m) of
  (Just (JsStr method), Just rid)
    | validId rid, paramsOk -> do
        atomicModifyIORef' (inflight s) (\x -> (Map.insert (encodeJs rid) False x, ()))
        void . forkIO $ do
          resp <- handleRequest s (jsStringText method) params
          cancelled <- atomicModifyIORef' (inflight s) (\x -> (Map.delete (encodeJs rid) x, Map.findWithDefault False (encodeJs rid) x))
          unless cancelled $ case resp of
            Right result -> send s (obj [("result", result), ("jsonrpc", str "2.0"), ("id", rid)])
            Left (code, msg) -> send s (obj [("jsonrpc", str "2.0"), ("id", rid), ("error", obj [("code", int code), ("message", str msg)])])
  (Just method, Nothing)
    | method == str "notifications/cancelled" ->
    forM_ (lookupKey "requestId" params) $ \rid ->
      atomicModifyIORef' (inflight s) (\x -> (Map.adjust (const True) (encodeJs rid) x, ()))
  _ -> pure ()
  where
    params = fromMaybe emptyObject (lookupKey "params" m >>= asObject)
    paramsOk = case lookupKey "params" m of
      Nothing -> True
      Just (JsObj _) -> True
      Just _ -> False

latestVersion :: Text
latestVersion = "2025-11-25"

supportedVersions :: [Text]
supportedVersions = [latestVersion, "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

handleRequest :: McpServer -> Text -> JsObject -> IO (Either (Int, Text) JsValue)
handleRequest s method params = case method of
  "initialize" -> pure $ case lookupKey "protocolVersion" params of
    Just (JsStr v) ->
      let requested = jsStringText v
          version = if requested `elem` supportedVersions then requested else latestVersion
       in Right
            ( obj
                [ ("protocolVersion", str version)
                , ("capabilities", obj [("tools", obj [("listChanged", JsBool True)])])
                , ("serverInfo", obj [("name", str "petrus"), ("version", str "1.0.0")])
                ]
            )
    _ -> Left (-32603, invalidRequestParams "protocolVersion" "string" (lookupKey "protocolVersion" params))
  "ping" -> pure (Right (obj []))
  "tools/list" -> pure (Right (obj [("tools", arr (map describe tools))]))
  "tools/call" -> case lookupKey "name" params of
    Just (JsStr nameS) -> do
      let name = jsStringText nameS
      case [t | t <- tools, toolName t == name] of
        [] -> pure (Right (toolResult (errorResult ("MCP error -32602: Tool " <> name <> " not found"))))
        (t : _) -> case validate (SObject (toolShape t) (toolPassthroughArgs t)) (lookupKey "arguments" params) of
          Left issues ->
            pure . Right . toolResult . errorResult $
              "MCP error -32602: Input validation error: Invalid arguments for tool "
                <> name
                <> ": "
                <> issuesText issues
          Right args -> do
            r <- try @SomeException (toolRun t s (fromMaybe emptyObject (asObject args)))
            pure . Right . toolResult $ case r of
              Right res -> res
              Left e -> errorResult (T.pack (show e))
    other -> pure (Left (-32603, invalidRequestParams "name" "string" other))
  _ -> pure (Left (-32601, "Method not found"))
  where
    describe t =
      obj
        [ ("name", str (toolName t))
        , ("description", str (toolDescription t))
        , ("inputSchema", toolInputSchema (toolShape t))
        , ("execution", obj [("taskSupport", str "forbidden")])
        ]

-- | The SDK's message for a request whose params fail its zod schema.
invalidRequestParams :: Text -> Text -> Maybe JsValue -> Text
invalidRequestParams key ex mv =
  issuesText
    [ obj
        [ ("expected", str ex)
        , ("code", str "invalid_type")
        , ("path", arr [str "params", str key])
        , ("message", str ("Invalid input: expected " <> ex <> ", received " <> maybe "undefined" jsTypeName mv))
        ]
    ]

toolResult :: ToolResult -> JsValue
toolResult (ToolResult text isErr) =
  obj ([("content", arr [obj [("type", str "text"), ("text", JsStr text)]])] ++ [("isError", JsBool True) | isErr])

textResult :: Text -> ToolResult
textResult t = ToolResult (jsString t) False

errorResult :: Text -> ToolResult
errorResult t = ToolResult (jsString t) True

-- | A result whose text is @JSON.stringify(v, null, 2)@ (valid UTF-8, so
-- it becomes a JSON string without a round trip through 'Text').
prettyResult :: JsValue -> ToolResult
prettyResult v = ToolResult (jsStringUtf8 (encodePretty v)) False

------------------------------------------------------------------------------
-- Tools

opt, req :: Schema -> Field
opt = optional
req = required

tools :: [Tool]
tools =
  [ Tool
      "petrus_status"
      "Check MCP server health: whether the bridge WebSocket is connected and a browser UI is responding. Fast."
      []
      False
      (\s _ -> statusTool s)
  , bridgeTool
      "petrus_inspect_document"
      "Inspect the live Petrus net schema, view state, simulation state, and selection."
      [ ("includeSchema", opt SBoolean)
      , ("includeViewState", opt SBoolean)
      , ("includeRuntime", opt SBoolean)
      , ("includeRefViewStates", opt SBoolean)
      ]
      DocumentInspect
      id
  , bridgeTool
      "petrus_inspect_canvas"
      "Get canvas geometry: node positions/sizes, edge routes, viewport zoom/pan."
      [("includeNodes", opt SBoolean), ("includeEdges", opt SBoolean), ("includeViewport", opt SBoolean)]
      CanvasInspect
      id
  , bridgeTool
      "petrus_inspect_selection"
      "Get the current selection: selected node IDs, edge, and focused subnet."
      []
      SelectionInspect
      id
  , bridgeTool
      "petrus_inspect_simulation"
      "Get simulation state: marking history, current step, terminal status."
      []
      SimulationInspect
      id
  , bridgeTool
      "petrus_preview_mutation"
      "Preview mutation operations. Returns previewId, summary, warnings. Does NOT apply."
      [("operations", req (SArray (SObject [("kind", req SString)] True))), ("reason", opt SString)]
      MutationPreview
      id
  , bridgeTool
      "petrus_apply_mutation"
      "Apply a previously previewed mutation. Requires previewId from preview."
      [("previewId", req SString)]
      MutationApply
      id
  , bridgeTool "petrus_undo" "Undo the last schema change." [] SchemaUndo id
  , bridgeTool "petrus_redo" "Redo a previously undone schema change." [] SchemaRedo id
  , bridgeTool
      "petrus_simulation_command"
      "Execute a simulation command: fire a transition, step forward/back, or load a scenario."
      [("kind", req SString), ("transitionId", opt SString), ("marking", opt (SRecord SNumber))]
      SimulationCommand
      id
  , Tool
      "petrus_scenario_save"
      "Save the current simulation marking as a named scenario."
      [("name", req SString)]
      False
      scenarioSave
  , Tool
      "petrus_scenario_compare"
      "Compare two saved scenarios by token distributions."
      [("scenarioA", req SString), ("scenarioB", req SString)]
      False
      (\s args -> scenarioCompare s args)
  , bridgeToolIO
      "petrus_trace_import"
      "Import a Temporal workflow trace for visual debugging."
      [("workflowId", req SString), ("runId", opt SString)]
      TraceImport
      traceImportParams
  , Tool
      "petrus_trace_scenarios"
      "Generate replayable scenarios from an imported trace."
      [("prefix", opt SString), ("checkpointSteps", opt (SArray SNumber)), ("includeAllSteps", opt SBoolean)]
      False
      traceScenarios
  , Tool
      "petrus_screenshot"
      "Capture a PNG screenshot of the current Petrus canvas."
      []
      False
      (\s _ -> screenshot s)
  , Tool
      "petrus_open_file"
      "Open a net file in Petrus by path. Reads the file from disk and loads it into the editor."
      [("path", described "Absolute or relative path to a .json net file" (req SString))]
      False
      openFileTool
  ]

elapsedSince :: Double -> IO JsValue
elapsedSince t0 = do
  now <- monotonicMs
  pure (num (fixed1 (now - t0)))

bridgeTool :: Text -> Text -> [(Text, Field)] -> RequestAction -> (JsObject -> JsObject) -> Tool
bridgeTool name description shape action transform =
  bridgeToolIO name description shape action (\_ p -> pure (transform p))

bridgeToolIO :: Text -> Text -> [(Text, Field)] -> RequestAction -> (McpServer -> JsObject -> IO JsObject) -> Tool
bridgeToolIO name description shape action transform =
  Tool name description shape False $ \s params -> do
    let actionT = str (requestActionName action)
    t0 <- monotonicMs
    perfLog (perfL s) "mcp-tool-start" [("tool", str name), ("action", actionT)]
    sent <- transform s params
    r <- sendBridgeRequest (bridge s) (requestActionName action) sent
    case r of
      Left e -> do
        ms <- elapsedSince t0
        perfLog (perfL s) "mcp-tool-error" [("tool", str name), ("action", actionT), ("ms", ms), ("error", str e)]
        pure (errorResult e)
      Right Nothing -> do
        -- JSON.stringify(undefined).length throws before anything is returned
        let e = "Cannot read properties of undefined (reading 'length')"
        ms <- elapsedSince t0
        perfLog (perfL s) "mcp-tool-error" [("tool", str name), ("action", actionT), ("ms", ms), ("error", str e)]
        pure (errorResult e)
      Right (Just result) -> do
        ms <- elapsedSince t0
        let compact = encodeJs result
        perfLog
          (perfL s)
          "mcp-tool-done"
          [("tool", str name), ("action", actionT), ("totalMs", ms), ("resultBytes", int (utf16Len compact))]
        pure (prettyResult result)

-- | @{source: "temporal", ...params}@, plus @runtimeState@ from the
-- configured history source when there is one (see
-- "Petrus.Viewer.Mcp.History"); a failed fetch leaves the request as
-- upstream sends it.
traceImportParams :: McpServer -> JsObject -> IO JsObject
traceImportParams s params = do
  let base = objectFromList ((jsString "source", str "temporal") : objectToList params)
  case (historySource s, lookupKey "workflowId" params >>= asText) of
    (Just src, Just wf) -> do
      r <- fetchRuntimeState src wf
      case r of
        Right state -> pure (insertKey "runtimeState" state base)
        Left e -> do
          perfLog (perfL s) "mcp-history-error" [("workflowId", str wf), ("error", str e)]
          pure base
    _ -> pure base

-- | JavaScript string length of UTF-8 JSON text (UTF-16 code units).
utf16Len :: ByteString -> Int
utf16Len b = B.foldl' (\n w -> n + unitsFor w) 0 b
  where
    unitsFor w
      | w < 0x80 = 1
      | w < 0xC0 = 0
      | w < 0xF0 = 1
      | otherwise = 2

statusTool :: McpServer -> IO ToolResult
statusTool s = do
  st <- bridgeStatus (bridge s)
  ready <- if statusConnected st then hasBrowserUI (bridge s) else pure False
  let result =
        obj
          [ ("mcp_server", str "running")
          , ("bridge_connected", JsBool (statusConnected st))
          , ("browser_ui_ready", JsBool ready)
          , ("bridge_url", maybe JsNull str (statusUrl st))
          , ("client_id", statusClientId st)
          , ( "hint"
            , if not (statusConnected st)
                then str "Vite dev server not running. Start it with: pnpm dev"
                else
                  if not ready
                    then str "Open http://localhost:5173/ in a browser to connect the Petrus UI."
                    else JsNull
            )
          ]
  pure (prettyResult result)

-- | Property access with JavaScript's TypeError on null/undefined.
getProp :: Maybe JsValue -> Text -> Either Text (Maybe JsValue)
getProp base key = case base of
  Nothing -> Left ("Cannot read properties of undefined (reading '" <> key <> "')")
  Just JsNull -> Left ("Cannot read properties of null (reading '" <> key <> "')")
  Just (JsObj o) -> Right (lookupKey key o)
  Just (JsArr xs) -> Right (indexKey xs key)
  Just (JsStr st) | key == "length" -> Right (Just (int (T.length (jsStringText st))))
  Just _ -> Right Nothing
  where
    indexKey xs k = case T.unpack k of
      ds@(_ : _) | all (`elem` ['0' .. '9']) ds, show (read ds :: Integer) == ds -> case drop (read ds) xs of
        (x : _) -> Just x
        [] -> Nothing
      "length" -> Just (int (length xs))
      _ -> Nothing

-- | Optional chaining: @base?.key@.
optProp :: Maybe JsValue -> Text -> Maybe JsValue
optProp base key = case base of
  Nothing -> Nothing
  Just JsNull -> Nothing
  _ -> either (const Nothing) id (getProp base key)

-- | @a ?? b@.
orDefault :: Maybe JsValue -> JsValue -> JsValue
orDefault v d = case v of
  Nothing -> d
  Just JsNull -> d
  Just x -> x

-- | The property key JavaScript uses for a value in @obj[value]@.
keyOf :: JsValue -> Text
keyOf = jsToString

nowIso :: IO Text
nowIso = TE.decodeUtf8 <$> isoTimestamp

saveScenario :: McpServer -> Text -> JsValue -> IO ()
saveScenario s name marking = do
  at <- nowIso
  modifyIORef' (scenarios s) (Map.insert name (obj [("marking", marking), ("savedAt", str at)]))

scenarioSave :: McpServer -> JsObject -> IO ToolResult
scenarioSave s args = do
  let name = maybe "" jsToString (lookupKey "name" args)
  t0 <- monotonicMs
  perfLog (perfL s) "mcp-tool-start" [("tool", str "petrus_scenario_save")]
  r <- sendBridgeRequest (bridge s) "simulation.inspect" emptyObject
  let fail' e = do
        ms <- elapsedSince t0
        perfLog (perfL s) "mcp-tool-error" [("tool", str "petrus_scenario_save"), ("ms", ms), ("error", str e)]
        pure (errorResult e)
  case r of
    Left e -> fail' e
    Right state -> case getProp state "state" of
      Left e -> fail' e
      Right inner -> do
        -- state.state?.states?.[state.state.current]?.marking ?? {}
        let states = optProp inner "states"
            marking = case states of
              Nothing -> Right Nothing
              Just JsNull -> Right Nothing
              Just _ -> do
                current <- getProp inner "current"
                let idx = keyOf (fromMaybe (str "undefined") current)
                Right (optProp (either (const Nothing) id (getProp states idx)) "marking")
        case marking of
          Left e -> fail' e
          Right mk -> do
            saveScenario s name (orDefault mk (obj []))
            ms <- elapsedSince t0
            perfLog (perfL s) "mcp-tool-done" [("tool", str "petrus_scenario_save"), ("totalMs", ms)]
            pure (textResult ("Scenario '" <> name <> "' saved."))

scenarioCompare :: McpServer -> JsObject -> IO ToolResult
scenarioCompare s args = do
  let nameA = maybe "" jsToString (lookupKey "scenarioA" args)
      nameB = maybe "" jsToString (lookupKey "scenarioB" args)
  sc <- readIORef (scenarios s)
  case (Map.lookup nameA sc, Map.lookup nameB sc) of
    (Nothing, _) -> pure (errorResult ("Scenario '" <> nameA <> "' not found."))
    (_, Nothing) -> pure (errorResult ("Scenario '" <> nameB <> "' not found."))
    (Just a, Just b) -> do
      let markingOf v = fromMaybe JsNull (asObject v >>= lookupKey "marking")
          ma = markingOf a
          mb = markingOf b
          keysOf = \case
            JsObj o -> map jsStringText (objectKeys o)
            JsArr xs -> map (T.pack . show) [0 .. length xs - 1]
            JsStr st -> map (T.pack . show) [0 .. T.length (jsStringText st) - 1]
            _ -> []
          allPlaces = nub (keysOf ma ++ keysOf mb)
          valueAt m k = orDefault (either (const Nothing) id (getProp (Just m) k)) (int 0)
          diff =
            [ (place, obj [("from", va), ("to", vb), ("delta", delta va vb)])
            | place <- allPlaces
            , let va = valueAt ma place
            , let vb = valueAt mb place
            , not (strictEq va vb)
            ]
          result =
            obj
              [ ("scenarioA", str nameA)
              , ("scenarioB", str nameB)
              , ("changes", obj diff)
              , ("unchanged", int (length allPlaces - Set.size (Set.fromList (map fst diff))))
              ]
      pure (prettyResult result)
  where
    -- JavaScript === on decoded JSON values: primitives by value, objects
    -- and arrays (always distinct instances here) never equal
    strictEq x y = case (x, y) of
      (JsNum p, JsNum q) -> jsNumberValue p == jsNumberValue q
      (JsObj _, _) -> False
      (JsArr _, _) -> False
      _ -> x == y
    -- vb - va with ToNumber coercion; NaN serializes as null
    delta va vb = case (toNumber va, toNumber vb) of
      (Just p, Just q) -> num (q - p)
      _ -> JsNull
    toNumber = \case
      JsNum n -> Just (jsNumberValue n)
      JsBool True -> Just 1
      JsBool False -> Just 0
      JsNull -> Just 0
      _ -> Nothing

traceScenarios :: McpServer -> JsObject -> IO ToolResult
traceScenarios s args = do
  r <- sendBridgeRequest (bridge s) "simulation.inspect" emptyObject
  case r of
    Left e -> pure (errorResult e)
    Right state -> case getProp state "state" of
      Left e -> pure (errorResult e)
      Right inner -> do
        let states = case optProp inner "states" of
              Just (JsArr xs) -> xs
              _ -> []
        if null states
          then pure (errorResult "No simulation state. Import a trace first.")
          else do
            let pfx = case lookupKey "prefix" args of
                  Just v | truthy v -> jsToString v
                  _ -> "trace"
                n = length states
                markingAt i = getProp (Just (states !! i)) "marking"
            saved <- newIORef []
            let save name i = case markingAt i of
                  Left e -> pure (Left e)
                  Right mk -> do
                    saveScenario s name (orDefault mk (obj []))
                    modifyIORef' saved (++ [name])
                    pure (Right ())
            r1 <- save (pfx <> "-initial") 0
            r2 <- if n > 1 then save (pfx <> "-final") (n - 1) else pure (Right ())
            r3 <- case lookupKey "checkpointSteps" args of
              Just (JsArr steps) -> sequenceUntilError $ flip map steps $ \case
                JsNum stepN
                  | let step = jsNumberValue stepN
                  , step >= 0 && step < fromIntegral n ->
                      if step == fromIntegral (truncate step :: Int)
                        then save (pfx <> "-step-" <> jsToString (JsNum stepN)) (truncate step)
                        else pure (Left "Cannot read properties of undefined (reading 'marking')")
                _ -> pure (Right ())
              _ -> pure (Right ())
            r4 <- case lookupKey "includeAllSteps" args of
              Just v | truthy v -> sequenceUntilError $ flip map [0 .. n - 1] $ \i -> do
                let name = pfx <> "-step-" <> T.pack (show i)
                exists <- Map.member name <$> readIORef (scenarios s)
                if exists then pure (Right ()) else save name i
              _ -> pure (Right ())
            names <- readIORef saved
            pure $ case sequence_ [r1, r2, r3, r4] of
              Left e -> errorResult e
              Right () ->
                textResult ("Generated " <> T.pack (show (length names)) <> " scenarios: " <> T.intercalate ", " names)
  where
    sequenceUntilError [] = pure (Right ())
    sequenceUntilError (a : as) = do
      x <- a
      case x of
        Left e -> pure (Left e)
        Right () -> sequenceUntilError as

screenshot :: McpServer -> IO ToolResult
screenshot s = do
  t0 <- monotonicMs
  perfLog (perfL s) "mcp-tool-start" [("tool", str "petrus_screenshot")]
  r <- sendBridgeRequest (bridge s) "canvas.screenshot" emptyObject
  let fail' e = do
        ms <- elapsedSince t0
        perfLog (perfL s) "mcp-tool-error" [("tool", str "petrus_screenshot"), ("ms", ms), ("error", str e)]
        pure (errorResult e)
  case r of
    Left e -> fail' e
    Right result -> case getProp result "base64" of
      Left e -> fail' e
      Right b64
        | maybe True (not . truthy) b64 -> pure (errorResult "Screenshot returned no data.")
        | otherwise -> do
            bridgeMs <- elapsedSince t0
            let encoded = maybe "" jsToString b64
                dir = "/tmp/petrus-screenshots"
            _ <- try @IOException (createDirectoryIfMissing True dir)
            stamp <- (round . (* 1000)) <$> getPOSIXTime :: IO Integer
            let path = dir <> "/canvas-" <> show stamp <> ".png"
            w0 <- monotonicMs
            wr <- try @IOException (B.writeFile path (B64.decodeLenient (TE.encodeUtf8 encoded)))
            case wr of
              Left e -> fail' (T.pack (show e))
              Right () -> do
                writeMs <- elapsedSince w0
                total <- elapsedSince t0
                perfLog
                  (perfL s)
                  "mcp-tool-done"
                  [ ("tool", str "petrus_screenshot")
                  , ("bridgeMs", bridgeMs)
                  , ("writeMs", writeMs)
                  , ("totalMs", total)
                  , ("base64Bytes", int (T.length encoded))
                  ]
                pure (textResult ("Screenshot saved to " <> T.pack path))

openFileTool :: McpServer -> JsObject -> IO ToolResult
openFileTool s args = do
  let raw = maybe "" jsToString (lookupKey "path" args)
  t0 <- monotonicMs
  perfLog (perfL s) "mcp-tool-start" [("tool", str "petrus_open_file"), ("path", str raw)]
  cwd <- getCurrentDirectory
  let absPath = resolvePath cwd (T.unpack raw)
      absT = T.pack absPath
  exists <- doesPathExist absPath
  if not exists
    then pure (errorResult ("File not found: " <> absT))
    else do
      let fail' e = do
            ms <- elapsedSince t0
            perfLog (perfL s) "mcp-tool-error" [("tool", str "petrus_open_file"), ("ms", ms), ("error", str e)]
            pure (errorResult e)
      r0 <- monotonicMs
      content <- readFileNode absPath
      readMs <- elapsedSince r0
      case content of
        Left e -> fail' e
        Right text -> case parseJs (TE.encodeUtf8 text) of
          Left e -> fail' (T.pack e)
          Right _ -> do
            b0 <- monotonicMs
            r <- sendBridgeRequest (bridge s) "document.open" (objectFromList [(jsString "content", str text), (jsString "filePath", str absT)])
            case r of
              Left e -> fail' e
              Right result -> case getProp result "netName" of
                Left e -> fail' e
                Right netName -> do
                  bridgeMs <- elapsedSince b0
                  total <- elapsedSince t0
                  perfLog
                    (perfL s)
                    "mcp-tool-done"
                    [ ("tool", str "petrus_open_file")
                    , ("readMs", readMs)
                    , ("bridgeMs", bridgeMs)
                    , ("totalMs", total)
                    , ("fileBytes", int (utf16Len (TE.encodeUtf8 text)))
                    ]
                  pure (textResult ("Opened " <> absT <> " (net: " <> maybe "undefined" jsToString netName <> ")"))

-- | Node's @path.resolve(p)@ against a working directory.
resolvePath :: FilePath -> FilePath -> FilePath
resolvePath cwd p =
  let joined = if take 1 p == "/" then p else cwd <> "/" <> p
      n = normalizePosix joined
   in if length n > 1 && last n == '/' then init n else n
