-- | The v2 wire protocol: constants, the request and response envelopes,
-- the Attempt, invocation and failure objects, and every validation with
-- the reference's exact message (@petrus/motus/transport/zeromq.py@).
--
-- Everything here is pure. Messages are UTF-8 JSON with recursively sorted
-- keys and compact separators ('encodeMessage'); any valid JSON spelling is
-- accepted on input ('decodeMessage'), with CPython's error text for
-- malformed input.
module Petrus.Motus.Transport.ZeroMQ.Wire
  ( -- * Constants
    protocolVersion
  , maxMessageBytes
  , highWaterMark
  , maxClients
  , maxIdentityBytes
  , maxQueueCount
  , maxErrorBytes
  , zapDomain
    -- * Refusals
  , WireError (..)
  , wireErrorMessage
  , throwWire
  , fromWire
    -- * Names, endpoints and timeouts
  , name
  , nameText
  , wireName
  , wireNameText
  , endpointName
  , timeoutSeconds
  , dedupe
    -- * Objects
  , exact
  , encodeAttempt
  , decodeAttempt
  , encodeInvocation
  , decodeInvocation
  , encodeFailure
  , decodeFailure
  , classifiedFailure
  , faithful
    -- * Messages
  , encodeMessage
  , decodeMessage
  , ResponseFailure (..)
  , decodeResponse
  , errorMessage
  , pyStrip
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Bits ((.&.))
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity
import Petrus.Json
import Petrus.Motus.Dispatch (ActivityAttempt (..), AttemptFailure (..), activityAttempt)
import Petrus.Json.Python (decodeUtf8Python, pythonStrListRepr)
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Motus.PythonException (PythonException (..), pythonExceptionRepr)
import Petrus.Motus.Transport.ZeroMQ.Errors

-- ---------------------------------------------------------------------------
-- Constants

-- | @_VERSION@.
protocolVersion :: Integer
protocolVersion = 2

-- | @_MAX_MESSAGE_BYTES@ (1 MiB).
maxMessageBytes :: Int
maxMessageBytes = 1048576

-- | @_HWM@: send and receive high-water marks on both sides.
highWaterMark :: Int
highWaterMark = 4

-- | @_MAX_CLIENTS@: the server's provider cache bound.
maxClients :: Int
maxClients = 1000

-- | @_MAX_IDENTITY_BYTES@.
maxIdentityBytes :: Int
maxIdentityBytes = 256

-- | @_MAX_QUEUE_COUNT@.
maxQueueCount :: Int
maxQueueCount = 32

-- | @_MAX_ERROR_BYTES@.
maxErrorBytes :: Int
maxErrorBytes = 1024

-- | @_ZAP_DOMAIN@.
zapDomain :: Text
zapDomain = "impetus.dispatch.worker.v2"

-- ---------------------------------------------------------------------------
-- Refusals

-- | A refused value: the reference's @ValueError@, or (once) @TypeError@.
data WireError
  = WireValue Text
  | WireType Text
  deriving stock (Eq, Show)

wireErrorMessage :: WireError -> Text
wireErrorMessage = \case
  WireValue m -> m
  WireType m -> m

-- | Throw the refusal as 'ValueError' or 'TypeError'.
throwWire :: WireError -> IO a
throwWire = \case
  WireValue m -> throwIO (ValueError m)
  WireType m -> throwIO (TypeError m)

-- | Run a decoder, throwing its refusal.
fromWire :: Either WireError a -> IO a
fromWire = either throwWire pure

value :: Text -> Either WireError a
value = Left . WireValue

-- ---------------------------------------------------------------------------
-- Names, endpoints and timeouts

-- | @_name(value, noun)@.
name :: Text -> Json -> Either WireError Text
name noun = \case
  String s -> nameText noun s
  _ -> value ("ZeroMQ Dispatch " <> noun <> " must be a non-empty string without NUL")

nameText :: Text -> Text -> Either WireError Text
nameText noun s
  | T.null s || T.any (== '\NUL') s = value ("ZeroMQ Dispatch " <> noun <> " must be a non-empty string without NUL")
  | otherwise = Right s

-- | @_wire_name(value, noun)@: a name of at most 256 UTF-8 bytes.
wireName :: Text -> Json -> Either WireError Text
wireName noun v = name noun v >>= wireNameText noun

wireNameText :: Text -> Text -> Either WireError Text
wireNameText noun s = do
  spelling <- nameText noun s
  when (BS.length (TE.encodeUtf8 spelling) > maxIdentityBytes) $
    value ("ZeroMQ Dispatch " <> noun <> " exceeds the " <> T.pack (show maxIdentityBytes) <> "-byte protocol limit")
  Right spelling

-- | @_endpoint(value, bind=...)@.
endpointName :: Bool -> Text -> Either WireError Text
endpointName binding endpoint
  | T.null endpoint || T.any (== '\NUL') endpoint = value "ZeroMQ endpoint must be a non-empty string without NUL"
  | not ("ipc://" `T.isPrefixOf` endpoint || "tcp://" `T.isPrefixOf` endpoint) =
      value "ZeroMQ Dispatch Transport supports only ipc:// and tcp:// endpoints"
  | not binding && "tcp://" `T.isPrefixOf` endpoint && snd (T.breakOnEnd ":" endpoint) `elem` ["*", "0"] =
      value "ZeroMQ Worker requires a connectable TCP endpoint, not a wildcard bind endpoint"
  | otherwise = Right endpoint

-- | @_timeout(value, noun)@.
timeoutSeconds :: Text -> Double -> Either WireError Double
timeoutSeconds noun seconds
  | isNaN seconds || isInfinite seconds || seconds < 0 = value ("ZeroMQ " <> noun <> " must be a finite non-negative number")
  | otherwise = Right seconds

-- | @tuple(dict.fromkeys(items))@.
dedupe :: [Text] -> [Text]
dedupe = nub

-- ---------------------------------------------------------------------------
-- Objects

-- | @_exact(value, fields, noun)@: an object with exactly these keys.
exact :: Text -> [Text] -> Json -> Either WireError [(Text, Json)]
exact noun fields = \case
  Object members | sort (nub (map fst members)) == sort fields -> Right members
  _ -> value (noun <> " requires exactly " <> pythonStrListRepr (sort fields))

member :: Text -> [(Text, Json)] -> Json
member key members = maybe Null id (lookup key members)

-- | @_encode_attempt@.
encodeAttempt :: ActivityAttempt -> Json
encodeAttempt attempt =
  Object
    [ ("attempt_id", String attempt.attemptId)
    , ("epoch", String attempt.epoch)
    , ("claimant", String attempt.claimant)
    , ("queue", String attempt.queue)
    , ("invocation", encodeInvocation attempt.invocation)
    , ("latest_details", attempt.latestDetails)
    , ("instance", maybe Null String attempt.instance')
    ]

-- | @_decode_attempt@.
decodeAttempt :: Json -> Either WireError ActivityAttempt
decodeAttempt raw = do
  members <- exact "Activity Attempt" ["attempt_id", "epoch", "claimant", "queue", "invocation", "latest_details", "instance"] raw
  instance' <- case member "instance" members of
    Null -> Right Nothing
    other -> Just <$> name "attempt instance" other
  attempt <- name "attempt id" (member "attempt_id" members)
  epoch <- name "attempt epoch" (member "epoch" members)
  claimant <- name "attempt claimant" (member "claimant" members)
  queue <- name "attempt queue" (member "queue" members)
  inv <- decodeInvocation (member "invocation" members)
  either value Right (activityAttempt attempt epoch claimant queue inv (member "latest_details" members) instance')

-- | @_encode_invocation@: the policy always carries the eight current
-- fields.
encodeInvocation :: ActivityInvocation -> Json
encodeInvocation = invocationJson

-- | @_decode_invocation@: exactly five fields, a legacy (two-field) or
-- current (eight-field) policy, integer attempts and heartbeat timeout, the
-- names, then the value constructors' own validation
-- ('policyFromMembers', 'activityInvocation'). The order of the checks, and
-- so which refusal wins, is the transport's own.
decodeInvocation :: Json -> Either WireError ActivityInvocation
decodeInvocation raw = do
  members <- exact "Activity invocation" ["activity", "input", "policy", "correlation", "idempotency"] raw
  let legacy = ["attempts", "heartbeat_timeout"]
      current = legacy ++ ["initial_interval", "coefficient", "max_interval", "jitter", "start_to_close", "schedule_to_close"]
  policyMembers <- case member "policy" members of
    Object ms | sort (nub (map fst ms)) `elem` [sort legacy, sort current] -> Right ms
    _ -> value "execution policy requires exact legacy or current fields"
  forM_ ["attempts", "heartbeat_timeout"] $ \field -> case lookup field policyMembers of
    Just (Int _) -> Right ()
    _ -> value ("execution policy " <> field <> " must be an integer")
  activity' <- name "Activity name" (member "activity" members)
  correlation' <- optionalName "Activity correlation" (member "correlation" members)
  idempotency' <- optionalName "Activity idempotency" (member "idempotency" members)
  policy' <- either value Right (policyFromMembers policyMembers)
  either value Right $
    activityInvocation
      ActivityInvocation
        { activity = activity'
        , input = member "input" members
        , policy = policy'
        , correlation = correlation'
        , idempotency = idempotency'
        }
  where
    optionalName noun = \case
      Null -> Right Nothing
      other -> Just <$> name noun other

-- | @_encode_failure@.
encodeFailure :: ActivityFailure -> Json
encodeFailure failure =
  Object
    [ ("type", String "activity_failure")
    , ("error", String fields.failureError)
    , ("kind", String fields.failureKind)
    , ("details", fields.failureDetails)
    , ("retryable", Bool fields.failureRetryable)
    , ("retry_after", maybe Null numberJson fields.failureRetryAfter)
    ]
  where
    fields = failureFields failure

-- | @_decode_failure@, then @ActivityFailure(...)@ in the reference's
-- check order (error, kind, retryable, retry_after, details); a
-- non-boolean @retryable@ is the reference's @TypeError@.
decodeFailure :: Json -> Either WireError ActivityFailure
decodeFailure raw = do
  members <- exact "failure" ["type", "error", "kind", "details", "retryable", "retry_after"] raw
  unless (member "type" members == String "activity_failure") $ value "unsupported failure payload type"
  let text key = case member key members of
        String s -> s
        _ -> ""
      base = ActivityFailureFields (text "error") (text "kind") Null False Nothing
  _ <- either value Right (activityFailure base)
  retryable <- case member "retryable" members of
    Bool b -> Right b
    _ -> Left (WireType "ActivityFailure retryable must be bool")
  let retryAfter = case member "retry_after" members of
        Null -> Nothing
        other -> Just (maybe (FloatNumber (0 / 0)) id (numberFromJson other))
  either value Right (activityFailure base {failureDetails = member "details" members, failureRetryable = retryable, failureRetryAfter = retryAfter})

-- | @_classified_failure@: a message becomes a retryable @ActivityError@;
-- an exception its retryable @repr@ with the exception's type name.
classifiedFailure :: AttemptFailure -> Either WireError ActivityFailure
classifiedFailure = \case
  FailureClassified failure -> Right failure
  FailureMessage message -> either value Right (activityFailure (ActivityFailureFields message "ActivityError" Null True Nothing))
  FailureException err ->
    let python = zeromqPythonException err
     in either value Right (activityFailure (ActivityFailureFields (pythonExceptionRepr python) python.className Null True Nothing))

-- | @_faithful(value, noun)@: the value as it round-trips through
-- @json.dumps(allow_nan=False, ensure_ascii=False)@ and @json.loads@.
faithful :: Text -> Json -> Either WireError Json
faithful noun v = case dumps defaultDumps {allowNan = False, ensureAscii = False} v of
  Left problem -> value (noun <> " must be JSON-faithful: " <> T.pack (encodeErrorMessage problem))
  Right bytes -> either (value . ((noun <> " must be JSON-faithful: ") <>) . T.pack) Right (parseJson surrogateRefusingLoads bytes)

-- ---------------------------------------------------------------------------
-- Messages

-- | @_encode_message@: sorted keys, compact, UTF-8, at most 1 MiB.
encodeMessage :: Json -> Either WireError ByteString
encodeMessage v = case dumps compact {sortKeys = True} v of
  Left problem -> value (T.pack (encodeErrorMessage problem))
  Right bytes
    | BS.length bytes > maxMessageBytes -> value "ZeroMQ Dispatch message exceeds the maximum size"
    | otherwise -> Right bytes

-- | @_decode_message@: a JSON object, with CPython's decode error text.
-- "Petrus.Json" admits the document; only a refusal is re-scanned for the
-- message CPython raises: a @UnicodeDecodeError@ or @JSONDecodeError@ is
-- reported with the transport's prefix, @int()@'s digit-limit
-- @ValueError@ without it.
decodeMessage :: ByteString -> Either WireError [(Text, Json)]
decodeMessage bytes = case decodeUtf8Python bytes of
  Left problem -> invalidJson problem
  Right text -> case parseJson surrogateRefusingLoads bytes of
    Right (Object members) -> Right members
    Right _ -> value "ZeroMQ Dispatch message must be a JSON object"
    Left problem -> case Scanner.loads Scanner.defaultHooks text of
      Left (Scanner.DecodeError message position) -> invalidJson (Scanner.decodeErrorText text message position)
      Left (Scanner.HookError digitLimit) -> value digitLimit
      Right _ -> invalidJson (T.pack problem)
  where
    invalidJson problem = value ("invalid ZeroMQ Dispatch JSON message: " <> problem)

-- | How a response refuses the request: the reference's @ValueError@
-- (decode errors and @refused@ replies) or @RuntimeError@.
data ResponseFailure
  = ResponseValue Text
  | ResponseRuntime Text
  deriving stock (Eq, Show)

-- | @_decode_response(payload, request_id)@: the success value, or the
-- refusal.
decodeResponse :: Text -> ByteString -> Either ResponseFailure Json
decodeResponse requestId payload = do
  response <- asValue (decodeMessage payload)
  let versionOk = case member "version" response of
        Int 2 -> True
        Float 2.0 -> True
        _ -> False
      sameRequest = case member "request_id" response of
        String received -> received == requestId
        _ -> False
  let okIsTrue = case member "ok" response of
        Bool True -> True
        _ -> False
  if okIsTrue
    then do
      members <- asValue (exact "successful response" ["version", "request_id", "ok", "value"] (Object response))
      unless (versionOk && sameRequest) $ Left (ResponseRuntime "ZeroMQ Dispatch response version or request identity mismatch")
      Right (member "value" members)
    else do
      members <- asValue (exact "refused response" ["version", "request_id", "ok", "error"] (Object response))
      problem <- asValue (exact "refused response error" ["kind", "message"] (member "error" members))
      unless (versionOk && sameRequest) $ Left (ResponseRuntime "ZeroMQ Dispatch refusal version or request identity mismatch")
      case (member "ok" members, member "kind" problem, member "message" problem) of
        (Bool False, String kind, String message)
          | kind == "refused" -> Left (ResponseValue ("ZeroMQ Dispatch refused request: " <> message))
          | kind `elem` ["protocol", "service"] -> Left (ResponseRuntime ("ZeroMQ Dispatch " <> kind <> " error: " <> message))
        _ -> Left (ResponseRuntime "ZeroMQ Dispatch returned an invalid refusal")
  where
    asValue = either (Left . ResponseValue . wireErrorMessage) Right

-- | @_error_message(error)@: @str(error).strip()@, or the type name when
-- that is empty, truncated to 1024 UTF-8 bytes (an incomplete trailing
-- character becomes U+FFFD, as @decode(errors="replace")@ does).
errorMessage :: Text -> Text -> Text
errorMessage typeName message =
  let stripped = pyStrip message
      chosen = if T.null stripped then typeName else stripped
      encoded = TE.encodeUtf8 chosen
   in if BS.length encoded <= maxErrorBytes
        then chosen
        else
          let cut = BS.take maxErrorBytes encoded
              -- The start of the last character in the cut.
              lead = last (0 : [i | i <- [max 0 (maxErrorBytes - 4) .. maxErrorBytes - 1], BS.index cut i .&. 0xC0 /= 0x80])
              width b
                | b < 0x80 = 1
                | b < 0xE0 = 2
                | b < 0xF0 = 3
                | otherwise = 4 :: Int
              complete = lead + width (BS.index cut lead) <= maxErrorBytes
           in if complete
                then TE.decodeUtf8 cut
                else TE.decodeUtf8 (BS.take lead cut) <> "\xFFFD"

-- | @str.strip()@: CPython's whitespace set.
pyStrip :: Text -> Text
pyStrip = T.dropAround isPythonSpace
  where
    isPythonSpace c =
      c `elem` ("\t\n\v\f\r\x1c\x1d\x1e\x1f \x85\xa0\x1680\x2028\x2029\x202f\x205f\x3000" :: String)
        || (c >= '\x2000' && c <= '\x200a')
