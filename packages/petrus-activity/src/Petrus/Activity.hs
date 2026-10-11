-- | Petri- and history-agnostic activity execution values and contract
-- (@petrus.motus.activity@).
--
-- These are the values the Impetus kernel freezes into History — an
-- impure firing's 'ActivityInvocation' with its resolved 'ExecutionPolicy',
-- and a terminal 'ActivityFailure' — plus the declaration and definition
-- shapes Dispatch and Workers execute. They live below the kernel so that
-- Motus (Dispatch, Workers) can build on them without depending on any Petri
-- net machinery.
--
-- Every value is constructed through a validating function that enforces
-- exactly the reference's @__post_init__@ rules, with its messages. What the
-- reference checks with @isinstance@ (a bool where an int belongs, a
-- non-string name) is enforced by the Haskell types instead.
module Petrus.Activity
  ( -- * Numbers
    module Petrus.Activity.Number
  , maxDurationSeconds
    -- * Retry policy
  , RetryPolicy
  , RetryPolicyFields (..)
  , retryPolicy
  , defaultRetryPolicy
  , retryPolicyFields
  , retryPolicyJson
  , retryDelay
    -- * Execution policy
  , ExecutionPolicy
  , ExecutionPolicyFields (..)
  , executionPolicy
  , defaultExecutionPolicy
  , policyFields
  , policyJson
  , policyFromMembers
  , policyRetryPolicy
    -- * Invocations
  , ActivityInvocation (..)
  , activityInvocation
  , invocation
  , invocationJson
  , InvocationJsonError (..)
  , invocationFromJson
  , invocationRefusal
    -- * Failures
  , ActivityFailure
  , ActivityFailureFields (..)
  , activityFailure
  , simpleFailure
  , failureFields
  , failureJson
  , ActivityError (..)
  , activityError
    -- * Declarations and definitions
  , ActivityDeclaration
  , activityDeclaration
  , declarationName
  , declarationHeartbeatTimeout
  , declarationJson
  , PayloadConverter (..)
  , jsonPayloadConverter
  , ActivityExecutionContext (..)
  , ActivityDefinition (..)
  , defineActivity
  , callActivity
    -- * Heartbeats
  , heartbeatDetailsLimit
  , snapshotHeartbeatDetails
  ) where

import Control.DeepSeq (NFData (..))
import Control.Exception (Exception, throwIO)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity.Number
import Petrus.Json
import Petrus.Json.PythonText (pythonStrRepr)

-- | Largest accepted duration: provider-neutral and safe for milliseconds
-- and datetimes.
maxDurationSeconds :: Double
maxDurationSeconds = 1000000000

-- | @math.isfinite(value)@, including the @OverflowError@ CPython raises
-- for an int too large to convert to a float (at least 2^1024 - 2^970, the
-- first integer that rounds past the largest double).
finite :: Number -> Either Text Bool
finite = \case
  IntNumber i
    | abs i >= floatOverflow -> Left "int too large to convert to float"
    | otherwise -> Right True
  number -> Right (isFinite number)
  where
    floatOverflow = 2 ^ (1024 :: Int) - 2 ^ (970 :: Int) :: Integer

-- | @repr(int)@, including the @ValueError@ CPython raises for an integer of
-- more than 4300 digits.
intRepr :: Integer -> Either Text Text
intRepr i
  | length digits > maxIntStrDigits = Left (T.pack (intReprDigitsError maxIntStrDigits))
  | otherwise = Right (T.pack (show i))
  where
    digits = show (abs i)

-- | A JSON member for an optional number.
optionalNumber :: Maybe Number -> Json
optionalNumber = maybe Null numberJson

-- ---------------------------------------------------------------------------
-- Retry policy

-- | The fields of a 'RetryPolicy' in the reference's order. Durations are
-- seconds.
data RetryPolicyFields = RetryPolicyFields
  { retryInitialInterval :: Number
  , retryCoefficient :: Number
  , retryMaxInterval :: Number
  , retryMaxAttempts :: Integer
  , retryJitter :: Number
  }
  deriving stock (Eq, Show)

-- | A provider-neutral deterministic retry policy; only constructible
-- through 'retryPolicy'.
newtype RetryPolicy = RetryPolicy RetryPolicyFields
  deriving stock (Eq, Show)

retryPolicyFields :: RetryPolicy -> RetryPolicyFields
retryPolicyFields (RetryPolicy fields) = fields

-- | @RetryPolicy()@.
defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy (RetryPolicyFields 0 2 60 1 0)

-- | Validate as @RetryPolicy.__post_init__@ does.
retryPolicy :: RetryPolicyFields -> Either Text RetryPolicy
retryPolicy fields = do
  forM_
    [ ("initial_interval", fields.retryInitialInterval)
    , ("coefficient", fields.retryCoefficient)
    , ("max_interval", fields.retryMaxInterval)
    , ("jitter", fields.retryJitter)
    ]
    $ \(name, value) -> do
      ok <- finite value
      unless (ok && value >= 0) $
        Left ("RetryPolicy " <> name <> " must be a non-negative number")
  forM_ [("initial_interval", fields.retryInitialInterval), ("max_interval", fields.retryMaxInterval)] $ \(name, value) ->
    when (numberValue value > maxDurationSeconds) $
      Left ("RetryPolicy " <> name <> " must be at most 1000000000 seconds for provider-neutral duration safety")
  when (fields.retryCoefficient < 1) $ Left "RetryPolicy coefficient must be >= 1"
  when (fields.retryMaxAttempts < 1) $ Left "RetryPolicy max_attempts must be an integer >= 1"
  when (fields.retryJitter /= 0) $ Left "RetryPolicy jitter is unsupported; only deterministic jitter=0 is accepted"
  Right (RetryPolicy fields)

-- | @dataclasses.asdict(policy)@: the members in the reference's field
-- order.
retryPolicyJson :: RetryPolicy -> Json
retryPolicyJson (RetryPolicy f) =
  Object
    [ ("initial_interval", numberJson f.retryInitialInterval)
    , ("coefficient", numberJson f.retryCoefficient)
    , ("max_interval", numberJson f.retryMaxInterval)
    , ("max_attempts", Int f.retryMaxAttempts)
    , ("jitter", numberJson f.retryJitter)
    ]

-- | The delay following the numbered failed attempt (@RetryPolicy.delay@),
-- computed with the reference's float operations so the value is
-- bit-identical.
retryDelay :: RetryPolicy -> Integer -> Either Text Number
retryDelay (RetryPolicy f) failedAttempt
  | failedAttempt < 1 = Left "RetryPolicy delay requires a failed attempt number >= 1"
  | f.retryInitialInterval == 0 || f.retryMaxInterval == 0 = Right 0
  | f.retryInitialInterval >= f.retryMaxInterval = Right f.retryMaxInterval
  | f.retryCoefficient == 1 = Right f.retryInitialInterval
  | otherwise =
      let power = failedAttempt - 1
          initial = numberValue f.retryInitialInterval
          maximal = numberValue f.retryMaxInterval
          coefficientValue = numberValue f.retryCoefficient
          saturation = ceiling ((log maximal - log initial) / log coefficientValue) :: Integer
       in if power >= saturation
            then Right f.retryMaxInterval
            else
              let grown = exp (log initial + fromInteger power * log coefficientValue)
               in Right (if FloatNumber grown < f.retryMaxInterval then FloatNumber grown else f.retryMaxInterval)

-- ---------------------------------------------------------------------------
-- Execution policy

-- | The fields of an 'ExecutionPolicy', in the reference's declaration order
-- (also History's member order).
data ExecutionPolicyFields = ExecutionPolicyFields
  { attempts :: Integer
  , heartbeatTimeout :: Integer
  , initialInterval :: Number
  , coefficient :: Number
  , maxInterval :: Number
  , jitter :: Number
  , startToClose :: Maybe Number
  , scheduleToClose :: Maybe Number
  }
  deriving stock (Eq, Show)

-- | Resolved retry, heartbeat, and aggregate/per-attempt deadlines; only
-- constructible through 'executionPolicy'.
newtype ExecutionPolicy = ExecutionPolicy ExecutionPolicyFields
  deriving stock (Eq, Show)

instance NFData ExecutionPolicyFields where
  rnf (ExecutionPolicyFields attempts' heartbeat initial coefficient' maxInterval' jitter' startToClose' scheduleToClose') =
    rnf attempts' `seq` rnf heartbeat `seq` rnf initial `seq` rnf coefficient' `seq` rnf maxInterval'
      `seq` rnf jitter' `seq` rnf startToClose' `seq` rnf scheduleToClose'

instance NFData ExecutionPolicy where
  rnf (ExecutionPolicy fields) = rnf fields

policyFields :: ExecutionPolicy -> ExecutionPolicyFields
policyFields (ExecutionPolicy fields) = fields

-- | @ExecutionPolicy()@.
defaultExecutionPolicy :: ExecutionPolicy
defaultExecutionPolicy = ExecutionPolicy (ExecutionPolicyFields 1 30 0 2 60 0 Nothing Nothing)

-- | Validate as @ExecutionPolicy.__post_init__@ (and the @RetryPolicy@ it
-- constructs) do, in the reference's order.
executionPolicy :: ExecutionPolicyFields -> Either Text ExecutionPolicy
executionPolicy fields = do
  when (fields.attempts < 1) $ do
    -- The f-string's repr() is evaluated first, and refuses past 4300 digits.
    spelled <- intRepr fields.attempts
    Left
      ( "ExecutionPolicy requires attempts >= 1, got "
          <> spelled
          <> ": an invocation that may never execute is a wedge, not a policy"
      )
  when (fields.heartbeatTimeout <= 0) $ Left "ExecutionPolicy heartbeat_timeout must be a positive integer"
  when (fromInteger fields.heartbeatTimeout > maxDurationSeconds) $
    Left "ExecutionPolicy heartbeat_timeout must be at most 1000000000 seconds for provider-neutral duration safety"
  _ <- retryPolicy (retryFields fields)
  forM_ [("start_to_close", fields.startToClose), ("schedule_to_close", fields.scheduleToClose)] $ \(name, value) ->
    forM_ value $ \number -> do
      ok <- finite number
      unless (ok && number > 0) $
        Left ("ExecutionPolicy " <> name <> " must be a positive number or None")
      when (numberValue number > maxDurationSeconds) $
        Left ("ExecutionPolicy " <> name <> " must be at most 1000000000 seconds for provider-neutral duration safety")
  Right (ExecutionPolicy fields)

-- | @dataclasses.asdict(policy)@: the members in the reference's field
-- order (History's @policy@ object).
policyJson :: ExecutionPolicy -> Json
policyJson (ExecutionPolicy f) =
  Object
    [ ("attempts", Int f.attempts)
    , ("heartbeat_timeout", Int f.heartbeatTimeout)
    , ("initial_interval", numberJson f.initialInterval)
    , ("coefficient", numberJson f.coefficient)
    , ("max_interval", numberJson f.maxInterval)
    , ("jitter", numberJson f.jitter)
    , ("start_to_close", optionalNumber f.startToClose)
    , ("schedule_to_close", optionalNumber f.scheduleToClose)
    ]

retryFields :: ExecutionPolicyFields -> RetryPolicyFields
retryFields f = RetryPolicyFields f.initialInterval f.coefficient f.maxInterval f.attempts f.jitter

-- | @policy.retry_policy@.
policyRetryPolicy :: ExecutionPolicy -> RetryPolicy
policyRetryPolicy (ExecutionPolicy f) = RetryPolicy (retryFields f)

-- ---------------------------------------------------------------------------
-- Invocations

-- | The stable, Petri-agnostic instruction offered to Dispatch.
data ActivityInvocation = ActivityInvocation
  { activity :: Text
  , input :: Json
  , policy :: ExecutionPolicy
  , correlation :: Maybe Text
  , idempotency :: Maybe Text
  }
  deriving stock (Eq, Show)

instance NFData ActivityInvocation where
  rnf (ActivityInvocation activity' input' policy' correlation' idempotency') =
    rnf activity' `seq` rnf input' `seq` rnf policy' `seq` rnf correlation' `seq` rnf idempotency'

-- | Validate an invocation as @ActivityInvocation.__post_init__@ does.
activityInvocation :: ActivityInvocation -> Either Text ActivityInvocation
activityInvocation value = do
  when (T.null value.activity) $ Left "ActivityInvocation requires a non-empty string activity name, got ''"
  forM_ [("correlation", value.correlation), ("idempotency", value.idempotency)] $ \(name, field) ->
    when (field == Just "") $
      Left
        ( "ActivityInvocation "
            <> name
            <> " must be a non-empty string, or None for the writer to derive at begin, got ''"
        )
  Right value

-- | @ActivityInvocation(activity, input=input)@: the default policy and
-- writer-derived identities.
invocation :: Text -> Json -> ActivityInvocation
invocation name payload = ActivityInvocation name payload defaultExecutionPolicy Nothing Nothing

-- | Why a JSON value is not an encoded invocation, by the first check that
-- failed. The shape checks are the Dispatches' own, each spelled in its own
-- words; the rest are the value constructors' refusals ('invocationRefusal').
data InvocationJsonError
  = -- | Not an object with exactly @activity@, @input@, @policy@,
    -- @correlation@ and @idempotency@.
    InvocationFieldsNotExact
  | -- | The policy is not an object with exactly the legacy
    -- (@attempts@, @heartbeat_timeout@) or the eight current fields.
    PolicyFieldsNotExact
  | -- | @attempts@ or @heartbeat_timeout@ is not an integer.
    PolicyFieldsNotIntegers
  | -- | @ExecutionPolicy(**policy)@ refused, with its message.
    PolicyRefused Text
  | -- | The activity name is not a non-empty string.
    ActivityNameRefused Json
  | -- | @correlation@ or @idempotency@ (the label) is neither null nor a
    -- non-empty string.
    IdentityRefused Text Json
  deriving stock (Eq, Show)

-- | The inverse of 'invocationJson', as the Local and Absurd Dispatches
-- decode a stored invocation: the exact five fields, a legacy or current
-- policy with integer @attempts@ and @heartbeat_timeout@, then
-- @ActivityInvocation(activity, input=..., policy=ExecutionPolicy(**policy),
-- correlation=..., idempotency=...)@ in the reference's evaluation order.
invocationFromJson :: Json -> Either InvocationJsonError ActivityInvocation
invocationFromJson value = do
  members <- case value of
    Object ms | sort (map fst ms) == sort invocationFields -> Right ms
    _ -> Left InvocationFieldsNotExact
  let field key = maybe Null id (lookup key members)
  policyMembers <- case field "policy" of
    Object ms | sort (map fst ms) `elem` [sort legacyPolicyFields, sort currentPolicyFields] -> Right ms
    _ -> Left PolicyFieldsNotExact
  policy' <- case (lookup "attempts" policyMembers, lookup "heartbeat_timeout" policyMembers) of
    (Just (Int _), Just (Int _)) -> either (Left . PolicyRefused) Right (policyFromMembers policyMembers)
    _ -> Left PolicyFieldsNotIntegers
  activity' <- case field "activity" of
    String a | not (T.null a) -> Right a
    other -> Left (ActivityNameRefused other)
  let identity label = case field label of
        Null -> Right Nothing
        String v | not (T.null v) -> Right (Just v)
        other -> Left (IdentityRefused label other)
  correlation' <- identity "correlation"
  idempotency' <- identity "idempotency"
  Right ActivityInvocation {activity = activity', input = field "input", policy = policy', correlation = correlation', idempotency = idempotency'}
  where
    invocationFields = ["activity", "input", "policy", "correlation", "idempotency"]

-- | The value constructors' refusal text for an 'InvocationJsonError', given
-- a Python @repr@ of JSON values (the shape errors have no constructor text
-- and are spelled by each Dispatch).
invocationRefusal :: (Json -> Text) -> InvocationJsonError -> Maybe Text
invocationRefusal repr = \case
  PolicyRefused message -> Just message
  ActivityNameRefused other -> Just ("ActivityInvocation requires a non-empty string activity name, got " <> repr other)
  IdentityRefused label other ->
    Just ("ActivityInvocation " <> label <> " must be a non-empty string, or None for the writer to derive at begin, got " <> repr other)
  _ -> Nothing

legacyPolicyFields, currentPolicyFields :: [Text]
legacyPolicyFields = ["attempts", "heartbeat_timeout"]
currentPolicyFields =
  legacyPolicyFields <> ["initial_interval", "coefficient", "max_interval", "jitter", "start_to_close", "schedule_to_close"]

-- | @ExecutionPolicy(**policy)@ over a decoded policy object whose shape the
-- caller has checked (exactly the legacy or current fields, integer
-- @attempts@ and @heartbeat_timeout@). An absent current field takes its
-- default; a value that is not a number fails the constructor's own range
-- check, with its message (a NaN stands in for it).
policyFromMembers :: [(Text, Json)] -> Either Text ExecutionPolicy
policyFromMembers members = do
  let integer key = case lookup key members of
        Just (Int i) -> Right i
        _ -> Left ("ExecutionPolicy " <> key <> " must be an integer")
      notANumber = FloatNumber (0 / 0)
      number fallback key = maybe fallback (maybe notANumber id . numberFromJson) (lookup key members)
      optional key = case lookup key members of
        Nothing -> Nothing
        Just Null -> Nothing
        Just raw -> Just (maybe notANumber id (numberFromJson raw))
      defaults = policyFields defaultExecutionPolicy
  attempts' <- integer "attempts"
  heartbeat' <- integer "heartbeat_timeout"
  executionPolicy
    ExecutionPolicyFields
      { attempts = attempts'
      , heartbeatTimeout = heartbeat'
      , initialInterval = number defaults.initialInterval "initial_interval"
      , coefficient = number defaults.coefficient "coefficient"
      , maxInterval = number defaults.maxInterval "max_interval"
      , jitter = number defaults.jitter "jitter"
      , startToClose = optional "start_to_close"
      , scheduleToClose = optional "schedule_to_close"
      }

-- | @dataclasses.asdict(invocation)@: activity, input, policy, correlation,
-- idempotency.
invocationJson :: ActivityInvocation -> Json
invocationJson value =
  Object
    [ ("activity", String value.activity)
    , ("input", value.input)
    , ("policy", policyJson value.policy)
    , ("correlation", maybe Null String value.correlation)
    , ("idempotency", maybe Null String value.idempotency)
    ]

-- ---------------------------------------------------------------------------
-- Failures

-- | The fields of a classified terminal failure.
data ActivityFailureFields = ActivityFailureFields
  { failureError :: Text
  , failureKind :: Text
  , failureDetails :: Json
  , failureRetryable :: Bool
  , failureRetryAfter :: Maybe Number
  }
  deriving stock (Eq, Show)

-- | Safe, durable classified terminal failure value; constructed through
-- 'activityFailure'.
newtype ActivityFailure = ActivityFailure ActivityFailureFields
  deriving stock (Eq, Show)

failureFields :: ActivityFailure -> ActivityFailureFields
failureFields (ActivityFailure fields) = fields

-- | Validate a failure as @ActivityFailure.__post_init__@ does.
activityFailure :: ActivityFailureFields -> Either Text ActivityFailure
activityFailure fields = do
  when (T.null fields.failureError || T.length fields.failureError > 4096) $
    Left "ActivityFailure error must be a non-empty string of at most 4096 characters"
  when (T.null fields.failureKind || T.length fields.failureKind > 128) $
    Left "ActivityFailure kind must be a non-empty string of at most 128 characters"
  forM_ fields.failureRetryAfter $ \number -> do
    ok <- finite number
    unless (ok && number >= 0) $
      Left "ActivityFailure retry_after must be a non-negative number or None"
    when (numberValue number > maxDurationSeconds) $
      Left "ActivityFailure retry_after must be at most 1000000000 seconds for provider-neutral duration safety"
  case dumps compactUnicode fields.failureDetails of
    Left problem -> Left ("Activity failure details must be JSON-faithful: " <> T.pack (encodeErrorMessage problem))
    Right encoded ->
      when (BS.length encoded > 16384) $
        Left "Activity failure details must be JSON-faithful: Activity failure details exceed the 16384-byte limit"
  Right (ActivityFailure fields)

-- | Compact separators without ASCII escaping — the reference's byte
-- measure for failure details and heartbeat details.
compactUnicode :: EncodeOptions
compactUnicode = compact

-- | @ActivityFailure(error)@: the default kind, no details, not retryable.
simpleFailure :: Text -> Either Text ActivityFailure
simpleFailure message = activityFailure (ActivityFailureFields message "ActivityError" Null False Nothing)

-- | The failure's durable wire object.
failureJson :: ActivityFailure -> Json
failureJson (ActivityFailure fields) =
  Object
    [ ("error", String fields.failureError)
    , ("kind", String fields.failureKind)
    , ("details", fields.failureDetails)
    , ("retryable", Bool fields.failureRetryable)
    , ("retry_after", optionalNumber fields.failureRetryAfter)
    ]

-- | The exception an Activity throws to classify a safe operational
-- failure.
newtype ActivityError = ActivityError ActivityFailure
  deriving stock (Show)

instance Exception ActivityError

-- | Throw a classified failure, refusing an invalid one as the reference's
-- constructor would.
activityError :: ActivityFailureFields -> IO a
activityError fields = either (ioError . userError . T.unpack) (throwIO . ActivityError) (activityFailure fields)

-- ---------------------------------------------------------------------------
-- Declarations and definitions

-- | Engine-side Activity metadata, separate from Worker implementation code.
data ActivityDeclaration = ActivityDeclaration Text (Maybe Integer)
  deriving stock (Eq, Show)

-- | Validate as @ActivityDeclaration.__post_init__@ does.
activityDeclaration :: Text -> Maybe Integer -> Either Text ActivityDeclaration
activityDeclaration name heartbeat = do
  when (T.null name) $ Left "ActivityDeclaration requires a non-empty string name"
  forM_ heartbeat $ \h -> when (h <= 0) $ Left "ActivityDeclaration heartbeat_timeout must be a positive integer or None"
  Right (ActivityDeclaration name heartbeat)

declarationName :: ActivityDeclaration -> Text
declarationName (ActivityDeclaration name _) = name

declarationHeartbeatTimeout :: ActivityDeclaration -> Maybe Integer
declarationHeartbeatTimeout (ActivityDeclaration _ heartbeat) = heartbeat

-- | @dataclasses.asdict(declaration)@: name, heartbeat_timeout.
declarationJson :: ActivityDeclaration -> Json
declarationJson (ActivityDeclaration name heartbeat) =
  Object [("name", String name), ("heartbeat_timeout", maybe Null Int heartbeat)]

-- | Convert Activity payloads between canonical values and typed values.
-- The reference's converters are keyed by Python type annotations; here a
-- typed definition supplies its own conversions and a converter only
-- canonicalizes the JSON on both sides.
data PayloadConverter = PayloadConverter
  { decodePayload :: Json -> Either Text Json
  , encodePayload :: Json -> Either Text Json
  }

-- | @JsonPayloadConverter@: preserve a detached JSON-faithful value. The
-- reference's @json.loads(json.dumps(value, allow_nan=False))@ refuses what
-- @dumps@ refuses (a non-finite float, an integer past 4300 digits), with
-- @dumps@'s message; what it accepts comes back unchanged.
jsonPayloadConverter :: PayloadConverter
jsonPayloadConverter = PayloadConverter canonical canonical
  where
    canonical value = case dumps defaultDumps {allowNan = False} value of
      Left problem -> Left ("Activity payload is not JSON-faithful: " <> T.pack (encodeErrorMessage problem))
      Right _ -> Right value

-- | What an executing Activity sees of its Attempt.
data ActivityExecutionContext = ActivityExecutionContext
  { attemptId :: Text
  , epoch :: Text
  , claimant :: Text
  , instance' :: Maybe Text
  , latestDetails :: IO Json
  , heartbeat :: Maybe Json -> IO Json
  }

-- | A function adapted to the Activity protocol: a declaration, the exact
-- parameter names its payload must carry, and the implementation over the
-- decoded parameters.
data ActivityDefinition = ActivityDefinition
  { declaration :: ActivityDeclaration
  , converter :: PayloadConverter
  , parameters :: [Text]
  , function :: [(Text, Json)] -> ActivityExecutionContext -> IO Json
  }

-- | Declare an Activity implementation (the reference's @activity@
-- decorator).
defineActivity :: ActivityDeclaration -> [Text] -> ([(Text, Json)] -> ActivityExecutionContext -> IO Json) -> ActivityDefinition
defineActivity declaration parameters = ActivityDefinition declaration jsonPayloadConverter parameters

-- | Execute one invocation: the name must match, and the payload must be a
-- mapping with exactly the declared parameters.
callActivity :: ActivityDefinition -> ActivityInvocation -> ActivityExecutionContext -> IO (Either Text Json)
callActivity definition inv context
  | inv.activity /= name =
      pure (Left ("Activity " <> pythonStrRepr name <> " cannot execute invocation for " <> pythonStrRepr inv.activity))
  | otherwise = case inv.input of
      Object members -> do
        let expected = sort definition.parameters
            supplied = sort (map fst members)
        if expected /= supplied
          then
            pure
              ( Left
                  ( "Activity "
                      <> pythonStrRepr name
                      <> " requires parameters "
                      <> pyList expected
                      <> ", got "
                      <> pyList supplied
                  )
              )
          else case mapM (\p -> (p,) <$> definition.converter.decodePayload (maybe Null id (lookup p members))) definition.parameters of
            Left err -> pure (Left err)
            Right arguments -> definition.converter.encodePayload <$> definition.function arguments context
      other ->
        pure (Left ("Activity " <> pythonStrRepr name <> " parameter payload must be a mapping, got " <> jsonTypeName other))
  where
    name = declarationName definition.declaration
    pyList items = "[" <> T.intercalate ", " (map pythonStrRepr items) <> "]"

-- ---------------------------------------------------------------------------
-- Heartbeats

-- | The encoded byte limit of heartbeat details.
heartbeatDetailsLimit :: Int
heartbeatDetailsLimit = 65536

-- | The exact, detached JSON value accepted at the heartbeat door.
snapshotHeartbeatDetails :: Json -> Either Text Json
snapshotHeartbeatDetails value = do
  -- The reference's normalize pass refuses a non-finite float anywhere
  -- before json.dumps runs; json.dumps then refuses an integer past 4300
  -- digits with its own ValueError, unwrapped.
  unless (allFinite value) $ Left "heartbeat details require finite JSON numbers"
  encoded <- either (Left . T.pack . encodeErrorMessage) Right (dumps compactUnicode value)
  when (BS.length encoded > heartbeatDetailsLimit) $
    Left
      ( "heartbeat details encode to "
          <> T.pack (show (BS.length encoded))
          <> " UTF-8 bytes; limit is "
          <> T.pack (show heartbeatDetailsLimit)
      )
  Right value
