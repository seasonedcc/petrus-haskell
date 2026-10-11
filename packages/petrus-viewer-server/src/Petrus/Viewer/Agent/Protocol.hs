-- | The petrus-agent wire protocol (@src/agent/protocol.ts@), typed.
--
-- Messages travel as JSON objects through the agent relay. 'parseAgentMessage'
-- is a port of the TypeScript @parseAgentMessage@: it accepts and rejects the
-- same inputs, resolves the same legacy aliases, and fails with the same
-- error texts. The parsed message keeps the normalized wire object
-- ('messageObject') so re-serializing it yields what the TypeScript
-- implementation would send (@{...input, kind, requestId, action, params}@).
module Petrus.Viewer.Agent.Protocol
  ( -- * Vocabulary
    protocolName
  , protocolVersion
  , RequestAction (..)
  , requestActionName
  , requestActionFromName
  , EventName (..)
  , eventNameText
  , eventNameFromText
  , ErrorCode (..)
  , errorCodeText
  , errorCodeFromText
    -- * Messages
  , AgentMessage (..)
  , AgentRequest (..)
  , AgentResponse (..)
  , AgentEvent (..)
  , AgentError (..)
  , messageObject
  , parseAgentMessage
  , parseAgentMessageBytes
    -- * Constructors
  , createRequest
  , createSuccessResponse
  , createErrorResponse
  , createEvent
  ) where

import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Viewer.Json

protocolName :: Text
protocolName = "petrus-agent"

protocolVersion :: Int
protocolVersion = 1

data RequestAction
  = AgentHandshake
  | DocumentOpen
  | DocumentInspect
  | CanvasInspect
  | SelectionInspect
  | MutationPreview
  | MutationApply
  | SimulationInspect
  | SimulationCommand
  | TraceImport
  | SubscriptionOpen
  | SubscriptionClose
  | SchemaUndo
  | SchemaRedo
  deriving stock (Eq, Ord, Show, Enum, Bounded)

requestActionName :: RequestAction -> Text
requestActionName = \case
  AgentHandshake -> "agent.handshake"
  DocumentOpen -> "document.open"
  DocumentInspect -> "document.inspect"
  CanvasInspect -> "canvas.inspect"
  SelectionInspect -> "selection.inspect"
  MutationPreview -> "mutation.preview"
  MutationApply -> "mutation.apply"
  SimulationInspect -> "simulation.inspect"
  SimulationCommand -> "simulation.command"
  TraceImport -> "trace.import"
  SubscriptionOpen -> "subscription.open"
  SubscriptionClose -> "subscription.close"
  SchemaUndo -> "schema.undo"
  SchemaRedo -> "schema.redo"

-- | Resolve a wire action name, including the legacy aliases.
requestActionFromName :: Text -> Maybe RequestAction
requestActionFromName n = lookup (alias n) [(requestActionName a, a) | a <- [minBound .. maxBound]]
  where
    alias = \case
      "net.inspect" -> "document.inspect"
      "runtime.inspect" -> "simulation.inspect"
      "runtime.command" -> "simulation.command"
      "temporal.import" -> "trace.import"
      other -> other

data EventName
  = AgentReady
  | DocumentChanged
  | CanvasChanged
  | SelectionChanged
  | SimulationChanged
  | PreviewInvalidated
  | SubscriptionClosed
  deriving stock (Eq, Ord, Show, Enum, Bounded)

eventNameText :: EventName -> Text
eventNameText = \case
  AgentReady -> "agent.ready"
  DocumentChanged -> "document.changed"
  CanvasChanged -> "canvas.changed"
  SelectionChanged -> "selection.changed"
  SimulationChanged -> "simulation.changed"
  PreviewInvalidated -> "preview.invalidated"
  SubscriptionClosed -> "subscription.closed"

eventNameFromText :: Text -> Maybe EventName
eventNameFromText n = lookup (alias n) [(eventNameText e, e) | e <- [minBound .. maxBound]]
  where
    alias = \case
      "bridge.connected" -> "agent.ready"
      "document.updated" -> "document.changed"
      "runtime.updated" -> "simulation.changed"
      other -> other

data ErrorCode
  = InvalidMessage
  | UnsupportedVersion
  | UnknownAction
  | InvalidPayload
  | Conflict
  | Forbidden
  | NotFound
  deriving stock (Eq, Ord, Show, Enum, Bounded)

errorCodeText :: ErrorCode -> Text
errorCodeText = \case
  InvalidMessage -> "invalid-message"
  UnsupportedVersion -> "unsupported-version"
  UnknownAction -> "unknown-action"
  InvalidPayload -> "invalid-payload"
  Conflict -> "conflict"
  Forbidden -> "forbidden"
  NotFound -> "not-found"

errorCodeFromText :: Text -> Maybe ErrorCode
errorCodeFromText t = lookup t [(errorCodeText c, c) | c <- [minBound .. maxBound]]

data AgentError = AgentError
  { errorCode :: ErrorCode
  , errorMessage :: Text
  , errorDetails :: Maybe JsValue
  }
  deriving stock (Eq, Show)

-- | A validated agent message. Each kind carries the normalized wire
-- object it was parsed from (or built as).
data AgentMessage
  = MsgRequest AgentRequest
  | MsgResponse AgentResponse
  | MsgEvent AgentEvent
  deriving stock (Eq, Show)

data AgentRequest = AgentRequest
  { requestId :: Text
  , requestAction :: RequestAction
  , requestParams :: JsObject
  , requestWire :: JsObject
  }
  deriving stock (Eq, Show)

data AgentResponse = AgentResponse
  { responseRequestId :: Text
  , responseAction :: RequestAction
  , responseOutcome :: Either AgentError JsObject
  , responseWire :: JsObject
  }
  deriving stock (Eq, Show)

data AgentEvent = AgentEvent
  { eventName :: EventName
  , eventPayload :: JsObject
  , eventWire :: JsObject
  }
  deriving stock (Eq, Show)

messageObject :: AgentMessage -> JsObject
messageObject = \case
  MsgRequest r -> requestWire r
  MsgResponse r -> responseWire r
  MsgEvent e -> eventWire e

envelope :: Text -> [(Text, JsValue)]
envelope k = [("protocol", str protocolName), ("version", int protocolVersion), ("kind", str k)]

createRequest :: Text -> RequestAction -> JsObject -> AgentMessage
createRequest rid a params =
  MsgRequest . AgentRequest rid a params $
    objectFromList' (envelope "request" ++ [("requestId", str rid), ("action", str (requestActionName a)), ("params", JsObj params)])

createSuccessResponse :: Text -> RequestAction -> JsObject -> AgentMessage
createSuccessResponse rid a result =
  MsgResponse . AgentResponse rid a (Right result) $
    objectFromList'
      ( envelope "response"
          ++ [("ok", JsBool True), ("requestId", str rid), ("action", str (requestActionName a)), ("result", JsObj result)]
      )

createErrorResponse :: Text -> RequestAction -> AgentError -> AgentMessage
createErrorResponse rid a e =
  MsgResponse . AgentResponse rid a (Left e) $
    objectFromList'
      ( envelope "response"
          ++ [("requestId", str rid), ("action", str (requestActionName a)), ("ok", JsBool False), ("error", errorValue e)]
      )

createEvent :: EventName -> JsObject -> AgentMessage
createEvent e payload =
  MsgEvent . AgentEvent e payload $
    objectFromList' (envelope "event" ++ [("event", str (eventNameText e)), ("payload", JsObj payload)])

objectFromList' :: [(Text, JsValue)] -> JsObject
objectFromList' kvs = objectFromList [(jsString k, v) | (k, v) <- kvs]

errorValue :: AgentError -> JsValue
errorValue e =
  obj
    ( [("code", str (errorCodeText (errorCode e))), ("message", str (errorMessage e))]
        ++ maybe [] (\d -> [("details", d)]) (errorDetails e)
    )

------------------------------------------------------------------------------
-- Parsing

type P = Either Text

-- | Parse raw JSON text (as received from the relay) and validate it.
parseAgentMessageBytes :: ByteString -> P AgentMessage
parseAgentMessageBytes b = either (Left . jsStringText) parseAgentMessage (parseJs (decodeLenient b))

-- | @parseAgentMessage@: validate and normalize a decoded message.
parseAgentMessage :: JsValue -> P AgentMessage
parseAgentMessage input = do
  object <- asRecord input "Agent message must be an object"
  let versionField = case lookupKey "version" object of
        Just v | v /= JsNull -> Just v
        _ -> lookupKey "protocolVersion" object
  version <- readNumber versionField "Agent message version must be a number"
  let normalized = insertKey "version" (JsNum version) object
  -- assertAgentEnvelope
  unless (lookupKey "protocol" normalized == Just (str protocolName)) $
    Left ("Unsupported agent protocol: " <> stringOf (lookupKey "protocol" normalized))
  kind <- case lookupKey "kind" normalized of
    Just (JsStr s) -> Right (jsStringText s)
    _ -> Left "Agent message kind must be a string"
  let supported = jsNumberValue version == fromIntegral protocolVersion
      assertVersion =
        unless supported (Left ("Unsupported agent version: " <> jsToString (JsNum version)))
  case kind of
    "request" -> normalizeRequest normalized assertVersion
    "response" -> normalizeResponse normalized assertVersion
    "event" -> assertVersion >> normalizeEvent normalized
    other -> Left ("Unsupported agent message kind: " <> other)

-- | JavaScript @String(x)@ for a possibly-missing field.
stringOf :: Maybe JsValue -> Text
stringOf = maybe "undefined" jsToString

field :: Text -> JsObject -> Maybe JsValue
field = lookupKey

asRecord :: JsValue -> Text -> P JsObject
asRecord v msg = maybe (Left msg) Right (asObject v)

asRecordM :: Maybe JsValue -> Text -> P JsObject
asRecordM v msg = maybe (Left msg) (`asRecord` msg) v

readString :: Maybe JsValue -> Text -> P Text
readString v msg = case v of
  Just (JsStr s) -> Right (jsStringText s)
  _ -> Left msg

readNumber :: Maybe JsValue -> Text -> P JsNumber
readNumber v msg = case v of
  Just (JsNum n) | let d = jsNumberValue n, not (isNaN d || isInfinite d) -> Right n
  _ -> Left msg

readBoolean :: Maybe JsValue -> Text -> P Bool
readBoolean v msg = case v of
  Just (JsBool b) -> Right b
  _ -> Left msg

-- | @x != null@ in JavaScript: present and not null.
present :: Maybe JsValue -> Maybe JsValue
present = \case
  Just JsNull -> Nothing
  other -> other

readOptionalBoolean :: Maybe JsValue -> Text -> P ()
readOptionalBoolean v msg = case present v of
  Nothing -> Right ()
  Just (JsBool _) -> Right ()
  Just _ -> Left msg

isArray :: Maybe JsValue -> Maybe [JsValue]
isArray = \case
  Just (JsArr xs) -> Just xs
  _ -> Nothing

normalizeRequest :: JsObject -> P () -> P AgentMessage
normalizeRequest input assertVersion = do
  rid <- readString (field "requestId" input) "Agent requestId must be a string"
  actionName <- readString (field "action" input) "Agent request action must be a string"
  action <- maybe (Left ("Unknown agent request action: " <> actionName)) Right (requestActionFromName actionName)
  params <- asRecord (maybe (obj []) (\case JsNull -> obj []; v -> v) (field "params" input)) "Agent params must be an object"
  when (action /= AgentHandshake) assertVersion
  case action of
    AgentHandshake -> ensureHandshakeRequest params
    DocumentInspect -> ensureDocumentInspectRequest params
    CanvasInspect -> ensureCanvasInspectRequest params
    SelectionInspect -> ensureEmptyObject params "selection.inspect params must be an object"
    MutationPreview -> ensureMutationPreviewRequest params
    MutationApply -> ensureMutationApplyRequest params
    SimulationInspect -> ensureEmptyObject params "simulation.inspect params must be an object"
    SimulationCommand -> ensureSimulationCommand params
    TraceImport -> ensureTraceImportRequest params
    SubscriptionOpen -> ensureSubscriptionOpenRequest params
    SubscriptionClose -> ensureSubscriptionCloseRequest params
    SchemaUndo -> pure ()
    SchemaRedo -> pure ()
    DocumentOpen -> ensureDocumentOpenRequest params
  let out =
        foldl
          (\o (k, v) -> insertKey k v o)
          input
          [("kind", str "request"), ("requestId", str rid), ("action", str (requestActionName action)), ("params", JsObj params)]
  pure (MsgRequest (AgentRequest rid action params out))

normalizeResponse :: JsObject -> P () -> P AgentMessage
normalizeResponse input assertVersion = do
  rid <- readString (field "requestId" input) "Agent response requestId must be a string"
  actionName <- readString (field "action" input) "Agent response action must be a string"
  action <- maybe (Left ("Unknown agent request action: " <> actionName)) Right (requestActionFromName actionName)
  when (action /= AgentHandshake) assertVersion
  ok <- readBoolean (field "ok" input) "Agent response ok flag must be a boolean"
  let base o =
        foldl
          (\acc (k, v) -> insertKey k v acc)
          input
          ([("kind", str "response"), ("requestId", str rid), ("action", str (requestActionName action)), ("ok", JsBool ok)] ++ o)
  if not ok
    then do
      err <- asRecordM (field "error" input) "Agent error response must include an error object"
      codeText <- readString (field "code" err) "Agent error code must be a string"
      code <- maybe (Left ("Unknown agent error code: " <> codeText)) Right (errorCodeFromText codeText)
      message <- readString (field "message" err) "Agent error message must be a string"
      let e = AgentError code message (present (field "details" err))
      pure (MsgResponse (AgentResponse rid action (Left e) (base [("error", errorValue e)])))
    else do
      unless (isJust (field "result" input)) (Left "Successful agent responses must include a result payload")
      result <- asRecordM (field "result" input) "Agent response result must be an object"
      ensureResponseResult action result
      pure (MsgResponse (AgentResponse rid action (Right result) (base [("result", JsObj result)])))

normalizeEvent :: JsObject -> P AgentMessage
normalizeEvent input = do
  nameText <- readString (field "event" input) "Agent event name must be a string"
  name <- maybe (Left ("Unknown agent event: " <> nameText)) Right (eventNameFromText nameText)
  unless (isJust (field "payload" input)) (Left "Agent events must include a payload")
  payload <- asRecordM (field "payload" input) "Agent event payload must be an object"
  ensureEventPayload name payload
  let out =
        foldl
          (\o (k, v) -> insertKey k v o)
          input
          [("kind", str "event"), ("event", str (eventNameText name)), ("payload", JsObj payload)]
  pure (MsgEvent (AgentEvent name payload out))

ensureResponseResult :: RequestAction -> JsObject -> P ()
ensureResponseResult action r = case action of
  AgentHandshake -> do
    s "sessionId" "Handshake result sessionId must be a string"
    s "mode" "Handshake result mode must be a string"
    a "capabilities" "Handshake result capabilities must be an array"
  DocumentInspect -> o "snapshot" "Document inspect result snapshot must be an object"
  CanvasInspect -> o "canvas" "Canvas inspect result canvas must be an object"
  SelectionInspect -> o "selection" "Selection inspect result selection must be an object"
  MutationPreview -> do
    s "previewId" "Mutation preview result previewId must be a string"
    s "summary" "Mutation preview result summary must be a string"
    s "mode" "Mutation preview result mode must be a string"
    a "operations" "Mutation preview result operations must be an array"
    a "warnings" "Mutation preview result warnings must be an array"
  MutationApply -> do
    s "previewId" "Mutation apply result previewId must be a string"
    s "revision" "Mutation apply result revision must be a string"
  SimulationInspect -> do
    s "revision" "Simulation inspect result revision must be a string"
    s "mode" "Simulation inspect result mode must be a string"
    unless (isJust (field "state" r)) (Left "Simulation inspect result must include state")
  SimulationCommand -> do
    s "revision" "Simulation command result revision must be a string"
    o "command" "Simulation command result command must be an object"
  TraceImport -> do
    s "source" "Trace import result source must be a string"
    s "revision" "Trace import result revision must be a string"
    () <$ readNumber (field "importedStates" r) "Trace import result importedStates must be a number"
    s "mode" "Trace import result mode must be a string"
  SubscriptionOpen -> do
    s "subscriptionId" "Subscription open result subscriptionId must be a string"
    s "channel" "Subscription open result channel must be a string"
  SubscriptionClose -> do
    unless (field "closed" r == Just (JsBool True)) (Left "Subscription close result closed must be true")
    s "subscriptionId" "Subscription close result subscriptionId must be a string"
  DocumentOpen -> s "netName" "Document open result netName must be a string"
  SchemaUndo -> s "revision" "Schema undo/redo result revision must be a string"
  SchemaRedo -> s "revision" "Schema undo/redo result revision must be a string"
  where
    s k msg = () <$ readString (field k r) msg
    o k msg = () <$ asRecordM (field k r) msg
    a k msg = maybe (Left msg) (const (Right ())) (isArray (field k r))

ensureEventPayload :: EventName -> JsObject -> P ()
ensureEventPayload event p = case event of
  AgentReady -> do
    s "sessionId" "agent.ready payload sessionId must be a string"
    s "mode" "agent.ready payload mode must be a string"
    maybe (Left "agent.ready payload capabilities must be an array") (const (Right ())) (isArray (field "capabilities" p))
  DocumentChanged -> do
    s "revision" "document.changed payload revision must be a string"
    s "mode" "document.changed payload mode must be a string"
    s "reason" "document.changed payload reason must be a string"
  CanvasChanged -> s "revision" "canvas.changed payload revision must be a string"
  SelectionChanged -> do
    s "revision" "selection.changed payload revision must be a string"
    () <$ asRecordM (field "selection" p) "selection.changed payload selection must be an object"
  SimulationChanged -> do
    s "revision" "simulation.changed payload revision must be a string"
    s "mode" "simulation.changed payload mode must be a string"
  PreviewInvalidated -> do
    s "previewId" "preview.invalidated payload previewId must be a string"
    s "reason" "preview.invalidated payload reason must be a string"
  SubscriptionClosed -> do
    s "subscriptionId" "subscription.closed payload subscriptionId must be a string"
    s "channel" "subscription.closed payload channel must be a string"
    s "reason" "subscription.closed payload reason must be a string"
  where
    s k msg = () <$ readString (field k p) msg

ensureHandshakeRequest :: JsObject -> P ()
ensureHandshakeRequest input = do
  role <- readString (field "clientRole" input) "Handshake clientRole must be a string"
  unless (role == "browser" || role == "sidecar") (Left ("Unsupported handshake clientRole: " <> role))
  case isArray (field "supportedVersions" input) of
    Just xs | all isNum xs -> pure ()
    _ -> Left "Handshake supportedVersions must be an array of numbers"
  forM_ (present (field "sessionId" input)) $ \v -> readString (Just v) "Handshake sessionId must be a string"
  where
    isNum = \case
      JsNum _ -> True
      _ -> False

ensureDocumentInspectRequest :: JsObject -> P ()
ensureDocumentInspectRequest input =
  forM_ ["includeSchema", "includeViewState", "includeRuntime", "includeRefViewStates"] $ \k ->
    readOptionalBoolean (field k input) (k <> " must be a boolean")

ensureCanvasInspectRequest :: JsObject -> P ()
ensureCanvasInspectRequest input =
  forM_ ["includeNodes", "includeEdges", "includeViewport"] $ \k ->
    readOptionalBoolean (field k input) (k <> " must be a boolean")

ensureMutationPreviewRequest :: JsObject -> P ()
ensureMutationPreviewRequest input = do
  forM_ (present (field "baseRevision" input)) $ \v ->
    readString (Just v) "Mutation preview baseRevision must be a string or null"
  forM_ (present (field "reason" input)) $ \v -> readString (Just v) "Mutation preview reason must be a string"
  case isArray (field "operations" input) of
    Just ops@(_ : _) ->
      forM_ (zip [0 :: Int ..] ops) $ \(i, op) ->
        asRecord op ("Mutation operation " <> showT i <> " must be an object") >>= ensureMutationOperation
    _ -> Left "Mutation preview operations must be a non-empty array"

ensureMutationApplyRequest :: JsObject -> P ()
ensureMutationApplyRequest input = do
  _ <- readString (field "previewId" input) "Mutation apply previewId must be a string"
  forM_ (present (field "operations" input)) $ \case
    JsArr ops ->
      forM_ (zip [0 :: Int ..] ops) $ \(i, op) ->
        asRecord op ("Mutation apply operation " <> showT i <> " must be an object") >>= ensureMutationOperation
    _ -> Left "Mutation apply operations must be an array when provided"

showT :: Int -> Text
showT = T.pack . show

ensureMutationOperation :: JsObject -> P ()
ensureMutationOperation input = do
  kind <- readString (field "kind" input) "Mutation operation kind must be a string"
  let s k msg = () <$ readString (field k input) msg
      optS k msg = forM_ (present (field k input)) $ \v -> readString (Just v) msg
      optN k msg = forM_ (present (field k input)) $ \v -> readNumber (Just v) msg
      stringArray k msg = case isArray (field k input) of
        Just xs | all isStr xs -> pure ()
        _ -> Left msg
      isStr = \case
        JsStr _ -> True
        _ -> False
      addNode prefix = do
        s "nodeId" (prefix <> " nodeId must be a string")
        pos <- asRecordM (field "position" input) (prefix <> " position must be an object")
        ensurePoint pos (prefix <> " position must be numeric")
        optS "parentSubnet" (prefix <> " parentSubnet must be a string or null")
        optS "label" (prefix <> " label must be a string")
  case kind of
    "add-place" -> do
      addNode "add-place"
      optN "initialTokens" "add-place initialTokens must be a number"
    "add-transition" -> addNode "add-transition"
    "add-arc" -> do
      s "source" "add-arc source must be a string"
      s "target" "add-arc target must be a string"
      forM_ (present (field "arcKind" input)) $ \v -> ensureArcKind v "add-arc arcKind must be a valid arc kind"
      optN "weight" "add-arc weight must be a number"
    "move-nodes" -> do
      positions <- asRecordM (field "positions" input) "move-nodes positions must be an object"
      forM_ (objectToList positions) $ \(k, point) -> do
        let nodeId = jsStringText k
        when (T.null nodeId) (Left "move-nodes positions must use non-empty node ids")
        p <- asRecord point ("move-nodes point for " <> nodeId <> " must be an object")
        ensurePoint p ("move-nodes point for " <> nodeId <> " must be numeric")
    "rename-node" -> do
      s "nodeId" "rename-node nodeId must be a string"
      s "nextNodeId" "rename-node nextNodeId must be a string"
    "delete-selection" -> do
      stringArray "nodeIds" "delete-selection nodeIds must be an array of strings"
      forM_ (present (field "edge" input)) $ \v ->
        asRecord v "delete-selection edge must be an object or null" >>= ensureSelectedEdgeRef
    "auto-layout" -> pure ()
    "focus-nodes" -> stringArray "nodeIds" "focus-nodes nodeIds must be an array of strings"
    "set-focused-subnet" -> s "path" "set-focused-subnet path must be a string"
    "set-guard" -> do
      s "nodeId" "set-guard nodeId must be a string"
      s "guard" "set-guard guard must be a string"
    "set-handler" -> do
      s "nodeId" "set-handler nodeId must be a string"
      unless (field "handler" input == Just JsNull) $
        s "handler" "set-handler handler must be a string or null"
    "set-timer" -> do
      s "nodeId" "set-timer nodeId must be a string"
      () <$ readBoolean (field "timer" input) "set-timer timer must be a boolean"
    "set-place-interface" -> do
      s "nodeId" "set-place-interface nodeId must be a string"
      unless (field "iface" input == Just JsNull) $ do
        iface <- readString (field "iface" input) "set-place-interface iface must be a string or null"
        unless (iface `elem` ["input", "output", "awaiting"]) $
          Left "set-place-interface iface must be 'input', 'output', 'awaiting', or null"
    other -> Left ("Unknown mutation operation kind: " <> other)

ensureSimulationCommand :: JsObject -> P ()
ensureSimulationCommand input = do
  kind <- readString (field "kind" input) "Simulation command kind must be a string"
  case kind of
    "step-forward" -> pure ()
    "step-back" -> pure ()
    "fire-transition" -> () <$ readString (field "transitionId" input) "fire-transition transitionId must be a string"
    "load-scenario" -> do
      marking <- asRecordM (field "marking" input) "load-scenario marking must be an object"
      forM_ (objectToList marking) $ \(k, tokens) -> do
        let placeId = jsStringText k
        when (T.null placeId) (Left "load-scenario marking keys must be non-empty")
        readNumber (Just tokens) ("load-scenario token count for " <> placeId <> " must be a number")
      forM_ (present (field "context" input)) $ \v -> asRecord v "load-scenario context must be an object"
    other -> Left ("Unknown simulation command kind: " <> other)

ensureTraceImportRequest :: JsObject -> P ()
ensureTraceImportRequest input = do
  source <- readString (field "source" input) "trace.import source must be a string"
  unless (source == "temporal") (Left ("Unsupported trace source: " <> source))
  forM_ (present (field "workflowId" input)) $ \v -> readString (Just v) "trace.import workflowId must be a string"
  forM_ (present (field "runId" input)) $ \v -> readString (Just v) "trace.import runId must be a string"

ensureSubscriptionOpenRequest :: JsObject -> P ()
ensureSubscriptionOpenRequest input = do
  channel <- readString (field "channel" input) "subscription.open channel must be a string"
  unless (channel `elem` ["document", "canvas", "selection", "simulation"]) $
    Left ("Unsupported subscription channel: " <> channel)

ensureSubscriptionCloseRequest :: JsObject -> P ()
ensureSubscriptionCloseRequest input =
  () <$ readString (field "subscriptionId" input) "subscription.close subscriptionId must be a string"

ensureDocumentOpenRequest :: JsObject -> P ()
ensureDocumentOpenRequest input = do
  _ <- readString (field "content" input) "document.open content must be a string"
  forM_ (present (field "filePath" input)) $ \v -> readString (Just v) "document.open filePath must be a string"

ensureSelectedEdgeRef :: JsObject -> P ()
ensureSelectedEdgeRef input = do
  _ <- readString (field "source" input) "Selected edge source must be a string"
  _ <- readString (field "target" input) "Selected edge target must be a string"
  ensureArcKind (maybe JsNull id (field "kind" input)) "Selected edge kind must be a valid arc kind"
  _ <- readNumber (field "weight" input) "Selected edge weight must be a number"
  forM_ (present (field "selectedWaypointIndex" input)) $ \v ->
    readNumber (Just v) "Selected edge waypoint index must be a number"

ensurePoint :: JsObject -> Text -> P ()
ensurePoint input prefix = do
  _ <- readNumber (field "x" input) (prefix <> ": x")
  () <$ readNumber (field "y" input) (prefix <> ": y")

ensureArcKind :: JsValue -> Text -> P ()
ensureArcKind v msg
  | v `elem` [str "normal", str "inhibitor", str "read"] = Right ()
  | otherwise = Left msg

ensureEmptyObject :: JsObject -> Text -> P ()
ensureEmptyObject o msg = when (objectSize o > 0) (Left msg)
