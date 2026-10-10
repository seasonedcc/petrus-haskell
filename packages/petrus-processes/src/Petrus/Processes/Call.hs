{-# LANGUAGE DataKinds #-}

-- | Call payloads and Envelope-v1 construction helpers (a port of
-- @petrus.processes.call@, spec/processes.md §3–§5).
module Petrus.Processes.Call
  ( -- * Payloads (§3)
    CallRequest
  , callRequest
  , callRequestToData
  , callRequestFromData
  , requestKind
  , CallResult
  , callResult
  , callResultToData
  , callResultFromData
  , resultKind
  , CallError
  , callError
  , callErrorToData
  , callErrorFromData
  , errorKind
  , CallReply (..)
    -- * Envelopes (§4)
  , requestEnvelope
  , resultEnvelope
  , errorEnvelope
  , requestDeliveryId
  , replyDeliveryId
    -- * Validation (§5)
  , requestFromEnvelope
  , replyFromEnvelope
  ) where

import Data.Bits (shiftR)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Records (HasField (..))
import Petrus.Fabric.Error
import Petrus.Fabric.Model
import Petrus.Json (Json (..), lookupMember)

requestKind, resultKind, errorKind :: Text
requestKind = "process.call.request"
resultKind = "process.call.result"
errorKind = "process.call.error"

textMember :: Text -> Json -> Either FabricError Text
textMember name = \case
  String s -> fabricText name s
  _ -> Left (InvalidValue (name <> " must be a non-empty string of at most 1024 UTF-8 bytes"))

-- @_exact(data, kind, fields)@.
exact :: Text -> [Text] -> Json -> Either FabricError (Map.Map Text Json)
exact kind fields value = do
  let message = "payload requires exact version-1 " <> kind <> " fields"
  m <- exactObject fields message value
  case (m Map.! "version", m Map.! "kind") of
    (Int 1, String k) | k == kind -> Right m
    _ -> Left (InvalidValue message)

-- ---------------------------------------------------------------------------
-- Payloads

-- | @process.call.request@ (§3.1).
data CallRequest = CallRequest {crCallId :: Text, crOperation :: Text, crInput :: Json}
  deriving stock (Eq, Show)

instance HasField "callId" CallRequest Text where getField r = r.crCallId
instance HasField "operation" CallRequest Text where getField r = r.crOperation
instance HasField "input" CallRequest Json where getField r = r.crInput

callRequest :: Text -> Text -> Json -> Either FabricError CallRequest
callRequest callId operation input = do
  callId' <- fabricText "call_id" callId
  operation' <- fabricText "operation" operation
  _ <- jsonObject "input" input
  CallRequest callId' operation' <$> jsonCopy "input" input

callRequestToData :: CallRequest -> Json
callRequestToData r =
  Object
    [ ("version", Int 1)
    , ("kind", String requestKind)
    , ("call_id", String r.crCallId)
    , ("operation", String r.crOperation)
    , ("input", r.crInput)
    ]

callRequestFromData :: Json -> Either FabricError CallRequest
callRequestFromData value = do
  m <- exact requestKind ["version", "kind", "call_id", "operation", "input"] value
  _ <- jsonObject "input" (m Map.! "input")
  callId <- textMember "call_id" (m Map.! "call_id")
  operation <- textMember "operation" (m Map.! "operation")
  callRequest callId operation (m Map.! "input")

-- | @process.call.result@ (§3.2): any JSON result.
data CallResult = CallResult {rsCallId :: Text, rsResult :: Json}
  deriving stock (Eq, Show)

instance HasField "callId" CallResult Text where getField r = r.rsCallId
instance HasField "result" CallResult Json where getField r = r.rsResult

callResult :: Text -> Json -> Either FabricError CallResult
callResult callId result = CallResult <$> fabricText "call_id" callId <*> jsonCopy "result" result

callResultToData :: CallResult -> Json
callResultToData r =
  Object [("version", Int 1), ("kind", String resultKind), ("call_id", String r.rsCallId), ("result", r.rsResult)]

callResultFromData :: Json -> Either FabricError CallResult
callResultFromData value = do
  m <- exact resultKind ["version", "kind", "call_id", "result"] value
  callId <- textMember "call_id" (m Map.! "call_id")
  callResult callId (m Map.! "result")

-- | @process.call.error@ (§3.3). @details@ defaults to @null@ in the
-- reference; pass 'Null'.
data CallError = CallError {ceCallId :: Text, ceCode :: Text, ceMessage :: Text, ceDetails :: Json}
  deriving stock (Eq, Show)

instance HasField "callId" CallError Text where getField r = r.ceCallId
instance HasField "code" CallError Text where getField r = r.ceCode
instance HasField "message" CallError Text where getField r = r.ceMessage
instance HasField "details" CallError Json where getField r = r.ceDetails

callError :: Text -> Text -> Text -> Json -> Either FabricError CallError
callError callId code message details =
  CallError
    <$> fabricText "call_id" callId
    <*> fabricText "code" code
    <*> fabricText "message" message
    <*> jsonCopy "details" details

callErrorToData :: CallError -> Json
callErrorToData r =
  Object
    [ ("version", Int 1)
    , ("kind", String errorKind)
    , ("call_id", String r.ceCallId)
    , ("code", String r.ceCode)
    , ("message", String r.ceMessage)
    , ("details", r.ceDetails)
    ]

callErrorFromData :: Json -> Either FabricError CallError
callErrorFromData value = do
  m <- exact errorKind ["version", "kind", "call_id", "code", "message", "details"] value
  callId <- textMember "call_id" (m Map.! "call_id")
  code <- textMember "code" (m Map.! "code")
  message <- textMember "message" (m Map.! "message")
  callError callId code message (m Map.! "details")

-- | A decoded reply.
data CallReply = ReplyResult CallResult | ReplyError CallError
  deriving stock (Eq, Show)

replyCallId :: CallReply -> Text
replyCallId = \case
  ReplyResult r -> r.rsCallId
  ReplyError e -> e.ceCallId

-- ---------------------------------------------------------------------------
-- Identities

-- | @process-call-v1-request-@ + SHA-256 hex of the call id (§4.1).
requestDeliveryId :: Text -> Text
requestDeliveryId callId = "process-call-v1-request-" <> sha256Hex (TE.encodeUtf8 callId)

-- | @process-call-v1-reply-@ + SHA-256 hex of the caller's UTF-8 length as a
-- big-endian u32, the caller, and the call id (§4.2).
replyDeliveryId :: Text -> Text -> Text
replyDeliveryId caller callId =
  let bytes = TE.encodeUtf8 caller
      n = BS.length bytes
      prefix = BS.pack [fromIntegral (n `shiftR` 24), fromIntegral (n `shiftR` 16), fromIntegral (n `shiftR` 8), fromIntegral n]
   in "process-call-v1-reply-" <> sha256Hex (BS.concat [prefix, bytes, TE.encodeUtf8 callId])

-- Python's @delivery_id or default@: an empty override is the default.
override :: Maybe Text -> Text -> Text
override given fallback = case given of
  Just d | not (T.null d) -> d
  _ -> fallback

-- ---------------------------------------------------------------------------
-- Envelopes

-- | @request_envelope(request=, sender=, recipient=, source=, reply_route=,
-- delivery_id=None)@.
requestEnvelope :: CallRequest -> Text -> Text -> Text -> ReplyRoute -> Maybe Text -> Either FabricError Envelope
requestEnvelope request sender recipient source route deliveryId
  | route.instanceId /= sender = Left (InvalidValue "call reply_route must belong to the sender process")
  | otherwise =
      envelope
        (override deliveryId (requestDeliveryId request.crCallId))
        sender
        recipient
        source
        request.crCallId
        (callRequestToData request)
        (Just route)

requiredRoute :: Envelope -> Either FabricError ReplyRoute
requiredRoute request = maybe (Left (InvalidValue "call request must carry a reply route")) Right request.replyRoute

reply :: Text -> Text -> Json -> Envelope -> Text -> Maybe Text -> Either FabricError Envelope
reply what callId payload request sender deliveryId = do
  call <- requestFromEnvelope request
  route <- requiredRoute request
  if callId /= call.crCallId || sender /= request.recipient
    then Left (InvalidValue ("call " <> what <> " must correlate to a request with a reply route"))
    else
      envelope
        (override deliveryId (replyDeliveryId request.sender callId))
        sender
        route.instanceId
        route.source
        callId
        payload
        Nothing

-- | @result_envelope(result=, request=, sender=, delivery_id=None)@.
resultEnvelope :: CallResult -> Envelope -> Text -> Maybe Text -> Either FabricError Envelope
resultEnvelope result = reply "result" result.rsCallId (callResultToData result)

-- | @error_envelope(error=, request=, sender=, delivery_id=None)@.
errorEnvelope :: CallError -> Envelope -> Text -> Maybe Text -> Either FabricError Envelope
errorEnvelope err = reply "error" err.ceCallId (callErrorToData err)

-- ---------------------------------------------------------------------------
-- Validation

-- | @request_from_envelope(envelope)@ (§5.1).
requestFromEnvelope :: Envelope -> Either FabricError CallRequest
requestFromEnvelope e = do
  request <- callRequestFromData e.payload
  if request.crCallId /= e.correlation
    then Left (InvalidValue "call request payload must match the envelope correlation")
    else Right ()
  route <- requiredRoute e
  if route.instanceId /= e.sender
    then Left (InvalidValue "call request must reply to its sender process")
    else Right request

-- | @reply_from_envelope(envelope, request=)@ (§5.2): decode a reply and bind
-- it to the request's callee, reply route, and correlation.
replyFromEnvelope :: Envelope -> Envelope -> Either FabricError CallReply
replyFromEnvelope e request = do
  call <- requestFromEnvelope request
  route <- requiredRoute request
  decoded <- case lookupMember "kind" e.payload of
    Just (String k)
      | k == resultKind -> ReplyResult <$> callResultFromData e.payload
      | k == errorKind -> ReplyError <$> callErrorFromData e.payload
    _ -> Left (InvalidValue "call reply payload must be a process.call.result or process.call.error")
  if replyCallId decoded /= call.crCallId || e.correlation /= call.crCallId
    then Left (InvalidValue "call reply payload and envelope must match the request correlation")
    else Right ()
  if e.sender /= request.recipient || e.recipient /= request.sender || e.source /= route.source
    then Left (InvalidValue "call reply must come from the request callee through the requested reply route")
    else Right ()
  case e.replyRoute of
    Just _ -> Left (InvalidValue "call reply must not carry another reply route")
    Nothing -> Right decoded
