-- | History replay and live watching backed by Petrus observation protocol 1.
--
-- The viewer replays runtime history through the Temporal HTTP API: it lists
-- workflows (@GET …/namespaces/{ns}/workflows@) and runs two workflow
-- queries, @get_schema@ (a flat net) and @get_state@ (a @RuntimeState@ with
-- one marking per history step), polling @get_state@ every two seconds while
-- live. This module serves that same protocol from Petrus Engines exposed
-- through @upstream/petrus/spec/observation-protocol-v1.md@ (any producer:
-- the Python reference, or a Haskell Engine served by
-- @petrus-observation-http@; @HistorySpec@ runs both), so the unchanged
-- browser UI replays and watches Petrus instances.
--
-- Mapping (one Temporal "workflow" per observed Engine instance):
--
-- * workflow id = the observation @instance@; type = definition @name@;
--   status = @COMPLETED@/@TERMINATED@/@FAILED@ (stuck)/@RUNNING@;
-- * @get_schema@ = the Net document's definition as a flat viewer net:
--   places/transitions keyed by dotted path, arcs with @consume@ → @normal@,
--   @read@ → @read@, @inhibit@ → @inhibitor@, the Layout as the root
--   view-state layout;
-- * @get_state@ = the Timeline path from the root to the head: each entry
--   becomes one state whose marking counts tokens per place; @fired@ is the
--   transition the entry's History record belongs to; colored tokens,
--   provenance, and the record are kept in @context@. Every id is emitted
--   with the @<net>.@ prefix the viewer's @normalizeRuntimeState@ strips, so
--   paths that happen to start with the net name survive normalization.
module Petrus.Viewer.History.Observation
  ( ObservationSources
  , newObservationSources
  , observationApp
  , documentToRuntimeState
  , documentToWorkflowSchema
  , snapshotToExecution
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.HTTP.Types.URI (urlDecode)
import Network.Wai qualified as W
import Petrus.Viewer.Json
import Petrus.Viewer.Http (lbsResponse)

-- | Configured observation base URLs and the instance → URL map learned
-- from their snapshots.
data ObservationSources = ObservationSources
  { sourceUrls :: [Text]
  , instances :: IORef (Map Text Text)
  }

newObservationSources :: [Text] -> IO ObservationSources
newObservationSources urls = ObservationSources (map (T.dropWhileEnd (== '/')) urls) <$> newIORef Map.empty

getJson :: HC.Manager -> Text -> IO (Either Text JsValue)
getJson mgr url = do
  r <- try @SomeException $ do
    req <- HC.parseRequest (T.unpack url)
    resp <- HC.httpLbs req mgr
    pure (H.statusCode (HC.responseStatus resp), BL.toStrict (HC.responseBody resp))
  pure $ case r of
    Left e -> Left (T.pack (show e))
    Right (200, body) -> either (Left . jsStringText) Right (parseJs (decodeLenient body))
    Right (code, body) -> Left ("HTTP " <> T.pack (show code) <> ": " <> TE.decodeUtf8Lenient (B.take 500 body))

-- | Serve the Temporal HTTP API subset under the given path prefix. Returns
-- 'Nothing' for paths it does not own (the caller falls back to the
-- Temporal proxy, if any).
observationApp :: ObservationSources -> HC.Manager -> B.ByteString -> W.Request -> Maybe (IO W.Response)
observationApp src mgr prefix req =
  case B.stripPrefix prefix (W.rawPathInfo req) of
    Nothing -> Nothing
    Just rest -> case filter (not . T.null) (T.splitOn "/" (TE.decodeUtf8Lenient (urlDecode False rest))) of
      ["api", "v1", "namespaces", _ns, "workflows"]
        | W.requestMethod req == "GET" -> Just listWorkflows
      ["api", "v1", "namespaces", _ns, "workflows", wf, "query", q]
        | W.requestMethod req == "POST" && q `elem` ["get_state", "get_schema"] -> Just (query wf q)
      _ -> Nothing
  where
    json st v = lbsResponse st [("Content-Type", "application/json")] (encodeJsLazy v)
    temporalError st code msg = json st (obj [("code", int code), ("message", str msg), ("details", arr [])])

    listWorkflows = do
      execs <- forM (sourceUrls src) $ \base -> do
        r <- getJson mgr (base <> "/v1/snapshot")
        case r of
          Right snap
            | Just inst <- snapInstance snap -> do
                modifyIORef' (instances src) (Map.insert inst base)
                pure (Just (snapshotToExecution snap))
          _ -> pure Nothing
      pure (json H.status200 (obj [("executions", arr (mapMaybe id execs))]))

    query wf q = do
      known <- Map.lookup wf <$> readIORef (instances src)
      base <- case known of
        Just b -> pure (Just b)
        Nothing -> do
          -- learn instance ids on demand (the UI may query without listing)
          found <- forM (sourceUrls src) $ \b -> do
            r <- getJson mgr (b <> "/v1/snapshot")
            pure $ case r of
              Right snap | snapInstance snap == Just wf -> Just b
              _ -> Nothing
          let hit = case [b | Just b <- found] of
                (b : _) -> Just b
                [] -> Nothing
          mapM_ (\b -> modifyIORef' (instances src) (Map.insert wf b)) hit
          pure hit
      case base of
        Nothing -> pure (temporalError H.status404 5 ("workflow not found for ID: " <> wf))
        Just b -> do
          r <- getJson mgr (b <> "/v1/document")
          pure $ case r >>= (if q == "get_state" then documentToRuntimeState else documentToWorkflowSchema) of
            Left e -> temporalError H.status500 13 e
            Right v -> json H.status200 (obj [("queryResult", arr [v])])

snapInstance :: JsValue -> Maybe Text
snapInstance v = asObject v >>= lookupKey "instance" >>= asText

-- | One Temporal @WorkflowExecutionInfo@-shaped entry for a snapshot.
snapshotToExecution :: JsValue -> JsValue
snapshotToExecution snap =
  obj
    [ ("execution", obj [("workflowId", str inst), ("runId", str "")])
    , ("type", obj [("name", str name)])
    , ("status", str ("WORKFLOW_EXECUTION_STATUS_" <> temporalStatus status))
    , ("taskQueue", str "")
    , ("startTime", str "")
    ]
  where
    o = fromMaybe emptyObject (asObject snap)
    inst = fromMaybe "" (lookupKey "instance" o >>= asText)
    name = fromMaybe "" (lookupKey "definition" o >>= asObject >>= lookupKey "name" >>= asText)
    status = fromMaybe "running" (lookupKey "current" o >>= asObject >>= lookupKey "status" >>= asText)

temporalStatus :: Text -> Text
temporalStatus = \case
  "completed" -> "COMPLETED"
  "terminated" -> "TERMINATED"
  "stuck" -> "FAILED"
  _ -> "RUNNING"

isTerminalStatus :: Text -> Bool
isTerminalStatus s = s `elem` ["completed", "terminated", "stuck"]

field :: Text -> JsValue -> Maybe JsValue
field k v = asObject v >>= lookupKey k

definitionOf :: JsValue -> Either Text JsValue
definitionOf doc = case field "definition" doc >>= field "definition" of
  Just d -> Right d
  Nothing -> Left "Net document has no definition"

netName :: JsValue -> Text
netName d = fromMaybe "" (field "name" d >>= asText)

listOf :: Maybe JsValue -> [JsValue]
listOf = \case
  Just (JsArr xs) -> xs
  _ -> []

-- | @get_state@: the head's Timeline path as a viewer @RuntimeState@.
documentToRuntimeState :: JsValue -> Either Text JsValue
documentToRuntimeState doc = do
  d <- definitionOf doc
  lineage <- maybe (Left "Net document has no Timeline") Right (field "lineage" doc)
  let name = netName d
      prefixed p = name <> "." <> p
      entries = listOf (field "entries" lineage)
      byId = Map.fromList [(i, e) | e <- entries, Just i <- [field "id" e >>= asNumber]]
      headId = fromMaybe (fromIntegral (length entries - 1)) (field "head" lineage >>= asNumber)
      ancestry i acc = case Map.lookup i byId of
        Nothing -> acc
        Just e -> case field "parent" e >>= asNumber of
          Just p | p < i -> ancestry p (e : acc)
          _ -> e : acc
      path = ancestry headId []
      occurrenceTransitions =
        Map.fromList
          [ (occ, t)
          | e <- path
          , Just r <- [field "metadata" e >>= field "history_record"]
          , Just t <- [field "transition" r >>= asText]
          , Just occ <- [field "occurrence" r >>= asNumber]
          ]
      firedOf e = do
        r <- field "metadata" e >>= field "history_record"
        case field "transition" r >>= asText of
          Just t -> Just t
          Nothing -> field "occurrence" r >>= asNumber >>= (`Map.lookup` occurrenceTransitions)
      countsOf e =
        obj
          [ (prefixed place, int (length (listOf (field "tokens" pe))))
          | pe <- listOf (field "marking" e)
          , Just place <- [field "place" pe >>= asText]
          ]
      tokensOf e =
        obj
          [ (place, fromMaybe (arr []) (field "tokens" pe))
          | pe <- listOf (field "marking" e)
          , Just place <- [field "place" pe >>= asText]
          ]
      stateOf e =
        obj
          [ ("fired", maybe JsNull (str . prefixed) (firedOf e))
          , ("marking", countsOf e)
          , ( "context"
            , obj
                [ ("entry", fromMaybe JsNull (field "id" e))
                , ("provenance", fromMaybe JsNull (field "provenance" e))
                , ("tokens", tokensOf e)
                , ("metadata", fromMaybe (obj []) (field "metadata" e))
                ]
            )
          , ("enabled", arr [])
          ]
      lastEntry = case path of
        [] -> Nothing
        _ -> Just (last path)
      headStatus = lastEntry >>= field "metadata" >>= field "observation" >>= field "status" >>= asText
      terminal = maybe False isTerminalStatus headStatus
  pure $
    obj
      [ ("terminal", JsBool terminal)
      , ("terminal_place", JsNull)
      , ("marking", maybe (obj []) countsOf lastEntry)
      , ( "history"
        , obj
            [ ("net", str name)
            , ("net_version", JsNull)
            , ("states", arr (map stateOf path))
            , ("current", int (max 0 (length path - 1)))
            ]
        )
      ]

-- | @get_schema@: the document's definition and Layout as a viewer net.
documentToWorkflowSchema :: JsValue -> Either Text JsValue
documentToWorkflowSchema doc = do
  d <- definitionOf doc
  let name = netName d
      places =
        [ (p, obj (maybe [] (\c -> [("metadata", obj [("color", c)])]) (nonNull (field "color" pl))))
        | pl <- listOf (field "places" d)
        , Just p <- [field "path" pl >>= asText]
        ]
      transitions =
        [ (t, obj (handler tr ++ guard tr ++ timers tr))
        | tr <- listOf (field "transitions" d)
        , Just t <- [field "path" tr >>= asText]
        ]
      handler tr = maybe [] (\h -> [("handler", str h)]) (field "handler" tr >>= declarationText)
      guard tr = case mapMaybe declarationText (listOf (field "guards" tr)) of
        [] -> []
        gs -> [("guard", str (T.intercalate " && " gs))]
      timers tr = case listOf (field "timers" tr) of
        [] -> []
        ts -> [("metadata", obj [("timers", arr ts)])]
      arcs =
        [ obj
            ( [ ("source", fromMaybe JsNull (field "source" a))
              , ("target", fromMaybe JsNull (field "target" a))
              , ("kind", str (arcKind (field "mode" a >>= asText)))
              , ("weight", fromMaybe (int 1) (field "weight" a))
              ]
                ++ [("metadata", obj (mapMaybe (\k -> (k,) <$> field k a) ["position", "color", "filter"]))]
            )
        | a <- listOf (field "arcs" d)
        ]
      layout =
        obj
          [ (n, arr [x, y])
          | node <- listOf (field "view" doc >>= field "nodes")
          , Just n <- [field "node" node >>= asText]
          , Just x <- [field "x" node]
          , Just y <- [field "y" node]
          ]
      viewStates = case field "view" doc of
        Just _ -> [("view_states", obj [(name, obj [("layout", layout)])])]
        Nothing -> []
  pure $
    obj
      ( [ ("net", str name)
        , ("places", obj places)
        , ("transitions", obj transitions)
        , ("arcs", arr arcs)
        ]
          ++ viewStates
      )
  where
    nonNull = \case
      Just JsNull -> Nothing
      other -> other
    arcKind = \case
      Just "read" -> "read"
      Just "inhibit" -> "inhibitor"
      _ -> "normal"
    declarationText decl = case field "kind" decl >>= asText of
      Just "symbol" -> field "name" decl >>= asText
      Just "cel" -> field "expression" decl >>= asText
      Just "anonymous" -> Just "anonymous"
      _ -> Nothing
