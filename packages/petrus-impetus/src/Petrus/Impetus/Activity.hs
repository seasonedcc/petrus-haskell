-- | The kernel-facing subset of @petrus.motus.activity@.
--
-- The Impetus kernel freezes an impure firing's activity request into
-- History ('ActivityInvocation', 'ExecutionPolicy') and records terminal
-- failures ('ActivityFailure'). Those three values are all the kernel needs
-- from the Motus execution layer, so they live here, in the kernel package,
-- rather than in a separate package: a future @petrus-motus@ package can
-- re-export them without the kernel depending on any execution machinery.
--
-- Numeric policy fields keep the integer/float distinction of their Python
-- spelling ('Number'), because History encodes them verbatim: the default
-- policy's @initial_interval@ is the integer @0@, while a caller's @0.5@ is a
-- float, and the canonical schema-5 spelling differs accordingly.
module Petrus.Impetus.Activity
  ( -- * Numbers
    Number (..)
  , numberJson
  , numberFromJson
  , numberValue
    -- * Execution policy
  , ExecutionPolicy
  , ExecutionPolicyFields (..)
  , executionPolicy
  , defaultExecutionPolicy
  , policyFields
  , maxDurationSeconds
    -- * Invocations
  , ActivityInvocation (..)
  , activityInvocation
  , invocation
    -- * Failures
  , ActivityFailure
  , ActivityFailureFields (..)
  , activityFailure
  , simpleFailure
  , failureFields
  , failureJson
  ) where

import Control.Monad (forM_, when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json

-- | A Python @int | float@ that keeps its spelling. Equality is numeric (as
-- in Python, @0 == 0.0@); 'numberJson' keeps the exact spelling.
data Number = IntNumber Integer | FloatNumber Double
  deriving stock (Show)

instance Eq Number where
  a == b = numberJson a == numberJson b

-- | The JSON spelling of a number.
numberJson :: Number -> Json
numberJson = \case
  IntNumber i -> Int i
  FloatNumber d -> Float d

-- | Read a JSON number (booleans are not numbers here, as in the reference's
-- exact-type checks).
numberFromJson :: Json -> Maybe Number
numberFromJson = \case
  Int i -> Just (IntNumber i)
  Float d -> Just (FloatNumber d)
  _ -> Nothing

-- | The number as a double, for range checks.
numberValue :: Number -> Double
numberValue = \case
  IntNumber i -> fromInteger i
  FloatNumber d -> d

-- | Largest accepted duration: provider-neutral and safe for milliseconds and
-- datetimes.
maxDurationSeconds :: Double
maxDurationSeconds = 1000000000

-- | The fields of an 'ExecutionPolicy', in the reference's declaration order
-- (which is also the History spelling's member order).
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
-- constructible through 'executionPolicy', which enforces the reference's
-- @__post_init__@ rules.
newtype ExecutionPolicy = ExecutionPolicy ExecutionPolicyFields
  deriving stock (Eq, Show)

policyFields :: ExecutionPolicy -> ExecutionPolicyFields
policyFields (ExecutionPolicy fields) = fields

-- | The reference's defaults: @ExecutionPolicy()@.
defaultExecutionPolicy :: ExecutionPolicy
defaultExecutionPolicy =
  ExecutionPolicy
    ExecutionPolicyFields
      { attempts = 1
      , heartbeatTimeout = 30
      , initialInterval = IntNumber 0
      , coefficient = IntNumber 2
      , maxInterval = IntNumber 60
      , jitter = IntNumber 0
      , startToClose = Nothing
      , scheduleToClose = Nothing
      }

-- | Validate policy fields exactly as @ExecutionPolicy.__post_init__@ (and
-- the @RetryPolicy@ it constructs) do.
executionPolicy :: ExecutionPolicyFields -> Either Text ExecutionPolicy
executionPolicy fields = do
  when (fields.attempts < 1) $
    Left
      ( "ExecutionPolicy requires attempts >= 1, got "
          <> T.pack (show fields.attempts)
          <> ": an invocation that may never execute is a wedge, not a policy"
      )
  when (fields.heartbeatTimeout <= 0) $
    Left "ExecutionPolicy heartbeat_timeout must be a positive integer"
  when (fromInteger fields.heartbeatTimeout > maxDurationSeconds) $
    Left
      "ExecutionPolicy heartbeat_timeout must be at most 1000000000 seconds for provider-neutral duration safety"
  -- RetryPolicy(initial_interval, coefficient, max_interval, attempts, jitter)
  forM_
    [ ("initial_interval", fields.initialInterval)
    , ("coefficient", fields.coefficient)
    , ("max_interval", fields.maxInterval)
    , ("jitter", fields.jitter)
    ]
    $ \(name, value) ->
      let v = numberValue value
       in when (isNaN v || isInfinite v || v < 0) $
            Left ("RetryPolicy " <> name <> " must be a non-negative number")
  forM_ [("initial_interval", fields.initialInterval), ("max_interval", fields.maxInterval)] $ \(name, value) ->
    when (numberValue value > maxDurationSeconds) $
      Left
        ( "RetryPolicy "
            <> name
            <> " must be at most 1000000000 seconds for provider-neutral duration safety"
        )
  when (numberValue fields.coefficient < 1) $ Left "RetryPolicy coefficient must be >= 1"
  when (numberValue fields.jitter /= 0) $
    Left "RetryPolicy jitter is unsupported; only deterministic jitter=0 is accepted"
  forM_ [("start_to_close", fields.startToClose), ("schedule_to_close", fields.scheduleToClose)] $ \(name, value) ->
    forM_ value $ \number -> do
      let v = numberValue number
      when (isNaN v || isInfinite v || v <= 0) $
        Left ("ExecutionPolicy " <> name <> " must be a positive number or None")
      when (v > maxDurationSeconds) $
        Left
          ( "ExecutionPolicy "
              <> name
              <> " must be at most 1000000000 seconds for provider-neutral duration safety"
          )
  Right (ExecutionPolicy fields)

-- | The stable, Petri-agnostic instruction offered to Dispatch.
data ActivityInvocation = ActivityInvocation
  { activity :: Text
  , input :: Json
  , policy :: ExecutionPolicy
  , correlation :: Maybe Text
  , idempotency :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Validate an invocation as @ActivityInvocation.__post_init__@ does.
activityInvocation :: ActivityInvocation -> Either Text ActivityInvocation
activityInvocation value = do
  when (T.null value.activity) $
    Left "ActivityInvocation requires a non-empty string activity name, got ''"
  forM_ [("correlation", value.correlation), ("idempotency", value.idempotency)] $ \(name, field) ->
    when (field == Just "") $
      Left
        ( "ActivityInvocation "
            <> name
            <> " must be a non-empty string, or None for the writer to derive at begin, got ''"
        )
  Right value

-- | @ActivityInvocation(activity, input=input)@ with the default policy and
-- writer-derived identities.
invocation :: Text -> Json -> ActivityInvocation
invocation name payload =
  ActivityInvocation
    { activity = name
    , input = payload
    , policy = defaultExecutionPolicy
    , correlation = Nothing
    , idempotency = Nothing
    }

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
-- 'activityFailure', which enforces the reference's bounds.
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
    let v = numberValue number
    when (isNaN v || isInfinite v || v < 0) $
      Left "ActivityFailure retry_after must be a non-negative number or None"
    when (v > maxDurationSeconds) $
      Left
        "ActivityFailure retry_after must be at most 1000000000 seconds for provider-neutral duration safety"
  case dumps compact fields.failureDetails of
    Left _ -> Left "Activity failure details must be JSON-faithful: Out of range float values are not JSON compliant"
    Right encoded ->
      when (BS.length encoded > 16384) $
        Left "Activity failure details must be JSON-faithful: Activity failure details exceed the 16384-byte limit"
  Right (ActivityFailure fields)

-- | @ActivityFailure(error)@: the default kind, no details, not retryable.
simpleFailure :: Text -> Either Text ActivityFailure
simpleFailure message =
  activityFailure
    ActivityFailureFields
      { failureError = message
      , failureKind = "ActivityError"
      , failureDetails = Null
      , failureRetryable = False
      , failureRetryAfter = Nothing
      }

-- | The failure's durable wire object (@{error, kind, details, retryable,
-- retry_after}@), the spelling terminal-report comparisons use.
failureJson :: ActivityFailure -> Json
failureJson (ActivityFailure fields) =
  Object
    [ ("error", String fields.failureError)
    , ("kind", String fields.failureKind)
    , ("details", fields.failureDetails)
    , ("retryable", Bool fields.failureRetryable)
    , ("retry_after", maybe Null numberJson fields.failureRetryAfter)
    ]
