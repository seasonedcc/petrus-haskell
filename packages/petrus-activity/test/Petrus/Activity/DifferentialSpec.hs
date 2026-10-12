-- | The Activity value doors against the pinned @petrus.motus.activity@,
-- live (@test/activity_oracle.py@ under @scripts/upstream-python@'s
-- interpreter).
--
-- Every case goes to both sides with the same fields. When the reference
-- accepts, its wire bytes (@json.dumps(asdict(value), ensure_ascii=False,
-- separators=(",", ":"))@, or the operation's result) must equal the bytes
-- petrus-json writes for the Haskell value. The Haskell constructors must
-- then accept the reference's wire as written and spell it back the same,
-- which is the Python-to-Haskell direction. When the reference refuses, the
-- Haskell door must refuse with the same message.
--
-- The corpora are generated from fixed seeds. They lean on the edges: zero,
-- -0.0, subnormals, the one-billion-second bound, NaN and the infinities,
-- integers past 2^53, past the largest double (CPython's @OverflowError@)
-- and past 4300 digits (CPython's @ValueError@), strings at the
-- 4096-character and 128-character bounds, and details at the 16 384-byte
-- and 65 536-byte bounds.
module Petrus.Activity.DifferentialSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity
import Petrus.Json
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Petrus.TestSupport.Repo (repoRoot)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

-- * Transport ------------------------------------------------------------------

-- | What petrus-json writes to the oracle: CPython's default spelling, with
-- integers of any size (the oracle lifts the digit limit while it reads).
transport :: EncodeOptions
transport = defaultDumps {reprDigitLimit = Nothing}

-- | The reference's answer spelling: @ensure_ascii=False@, compact.
wire :: EncodeOptions
wire = defaultDumps {itemSeparator = Just ",", keySeparator = ":", ensureAscii = False, reprDigitLimit = Nothing}

reading :: ParseOptions
reading = pythonLoads {maxIntegerDigits = Nothing}

spell :: EncodeOptions -> Json -> BS.ByteString
spell options = either (error . show) id . dumps options

data Answer = Accepted BS.ByteString | Refused Text Text

answer :: BS.ByteString -> Answer
answer line
  | Just rest <- BS.stripPrefix "{\"ok\":" line, Just value <- BS.stripSuffix "}" rest = Accepted value
  | otherwise = case parseJson reading line of
      Right (Object [("error", Array [String kind, String message])]) -> Refused kind message
      _ -> error ("unreadable oracle answer: " ++ BC.unpack line)

-- | One case: the request, the Haskell door's answer, and the Haskell
-- decoding of the reference's accepted wire, spelled back.
data Case = Case
  { request :: Json
  , ours :: IO (Either Text Json)
  , reread :: Json -> Either Text Json
  }

oracle :: [Json] -> IO [Answer]
oracle requests = do
  root <- repoRoot
  let script = root </> "packages" </> "petrus-activity" </> "test" </> "activity_oracle.py"
      stdin' = BL.toStrict (BL.intercalate "\n" (map (BL.fromStrict . spell transport) requests)) <> "\n"
  result <- runPython "import runpy, sys; runpy.run_path(sys.argv[1], run_name='__main__')" [script] stdin'
  case result.resultExit of
    ExitSuccess | BS.null result.resultStderr -> pure (map answer (filter (not . BS.null) (BC.lines result.resultStdout)))
    _ -> expectationFailure ("activity oracle failed:\n" ++ BC.unpack result.resultStderr) >> pure []

-- | Run a corpus through both sides.
differential :: String -> [Case] -> Spec
differential subject cases = it (subject ++ ": every case accepted and refused as the reference does") $ do
  answers <- oracle (map (.request) cases)
  length answers `shouldBe` length cases
  outcomes <- mapM (uncurry judge) (zip cases answers)
  let problems = [problem | Left problem <- outcomes]
      accepted = length [() | Right True <- outcomes]
      refused = length [() | Right False <- outcomes]
  take 3 problems `shouldBe` []
  -- The corpus reaches both sides of the door.
  (accepted, refused) `shouldSatisfy` (\(a, r) -> a >= length cases `div` 5 && r >= length cases `div` 20)
  where
    judge c reference = do
      mine <- c.ours
      pure $ case (reference, mine) of
        (Accepted bytes, Right value)
          | spell wire value /= bytes -> Left (explain c ("writes " ++ show (spell wire value) ++ ", the reference " ++ show bytes))
          | otherwise -> case parseJson reading bytes of
              Left problem -> Left (explain c ("cannot read the reference's wire: " ++ problem))
              Right theirs -> case c.reread theirs of
                Right respelled | spell wire respelled == bytes -> Right True
                other -> Left (explain c ("reads the reference's wire back as " ++ show other))
        (Refused _ message, Left refusal)
          | message == refusal -> Right False
        (Accepted bytes, Left refusal) -> Left (explain c ("refuses " ++ show refusal ++ ", the reference accepts " ++ show bytes))
        (Refused kind message, Right value) -> Left (explain c ("accepts " ++ show (spell wire value) ++ ", the reference raises " ++ show (kind, message)))
        (Refused kind message, Left refusal) -> Left (explain c ("refuses " ++ show refusal ++ ", the reference raises " ++ show (kind, message)))
    explain c problem = BC.unpack (BS.take 300 (spell transport c.request)) ++ ": Haskell " ++ problem

-- * Reading the wire back --------------------------------------------------------

member :: Text -> Json -> Either Text Json
member key = \case
  Object members -> maybe (Left ("missing " <> key)) Right (lookup key members)
  _ -> Left "not an object"

number :: Json -> Either Text Number
number value = maybe (Left "not a number") Right (numberFromJson value)

integer :: Json -> Either Text Integer
integer = \case
  Int i -> Right i
  _ -> Left "not an integer"

text :: Json -> Either Text Text
text = \case
  String t -> Right t
  _ -> Left "not a string"

optional :: (Json -> Either Text a) -> Json -> Either Text (Maybe a)
optional read' = \case
  Null -> Right Nothing
  value -> Just <$> read' value

retryFieldsOf :: Json -> Either Text RetryPolicyFields
retryFieldsOf v =
  RetryPolicyFields
    <$> (member "initial_interval" v >>= number)
    <*> (member "coefficient" v >>= number)
    <*> (member "max_interval" v >>= number)
    <*> (member "max_attempts" v >>= integer)
    <*> (member "jitter" v >>= number)

policyFieldsOf :: Json -> Either Text ExecutionPolicyFields
policyFieldsOf v =
  ExecutionPolicyFields
    <$> (member "attempts" v >>= integer)
    <*> (member "heartbeat_timeout" v >>= integer)
    <*> (member "initial_interval" v >>= number)
    <*> (member "coefficient" v >>= number)
    <*> (member "max_interval" v >>= number)
    <*> (member "jitter" v >>= number)
    <*> (member "start_to_close" v >>= optional number)
    <*> (member "schedule_to_close" v >>= optional number)

invocationOf :: Json -> Either Text ActivityInvocation
invocationOf v = do
  resolved <- member "policy" v >>= policyFieldsOf >>= executionPolicy
  value <-
    ActivityInvocationFields
      <$> (member "activity" v >>= text)
      <*> member "input" v
      <*> pure resolved
      <*> (member "correlation" v >>= optional text)
      <*> (member "idempotency" v >>= optional text)
  activityInvocation value

failureOf :: Json -> Either Text ActivityFailure
failureOf v = do
  fields <-
    ActivityFailureFields
      <$> (member "error" v >>= text)
      <*> (member "kind" v >>= text)
      <*> member "details" v
      <*> ( member "retryable" v >>= \case
              Bool b -> Right b
              _ -> Left "not a bool"
          )
      <*> (member "retry_after" v >>= optional number)
  activityFailure fields

declarationOf :: Json -> Either Text ActivityDeclaration
declarationOf v = do
  name <- member "name" v >>= text
  beat <- member "heartbeat_timeout" v >>= optional integer
  activityDeclaration name beat

-- * Requests ------------------------------------------------------------------

numberArg :: Number -> Json
numberArg = numberJson

optionalArg :: (a -> Json) -> Maybe a -> Json
optionalArg = maybe Null

retryArgs :: RetryPolicyFields -> [Json]
retryArgs f = [numberArg f.retryInitialInterval, numberArg f.retryCoefficient, numberArg f.retryMaxInterval, Int f.retryMaxAttempts, numberArg f.retryJitter]

policyArgs :: ExecutionPolicyFields -> [Json]
policyArgs f =
  [ Int f.attempts
  , Int f.heartbeatTimeout
  , numberArg f.initialInterval
  , numberArg f.coefficient
  , numberArg f.maxInterval
  , numberArg f.jitter
  , optionalArg numberArg f.startToClose
  , optionalArg numberArg f.scheduleToClose
  ]

retryCase :: RetryPolicyFields -> Case
retryCase f =
  Case
    (Array (String "retry" : retryArgs f))
    (pure (retryPolicyJson <$> retryPolicy f))
    (\v -> retryPolicyJson <$> (retryFieldsOf v >>= retryPolicy))

delayCase :: (RetryPolicyFields, Integer) -> Case
delayCase (f, attempt) =
  Case
    (Array (String "delay" : retryArgs f ++ [Int attempt]))
    (pure (numberJson <$> (retryPolicy f >>= (`retryDelay` attempt))))
    (fmap numberJson . number)

policyCase :: ExecutionPolicyFields -> Case
policyCase f =
  Case
    (Array (String "policy" : policyArgs f))
    (pure (policyJson <$> executionPolicy f))
    (\v -> policyJson <$> (policyFieldsOf v >>= executionPolicy))

invocationCase :: (Text, Json, ExecutionPolicyFields, Maybe Text, Maybe Text) -> Case
invocationCase (name, payload, f, correlation', idempotency') =
  Case
    (Array [String "invocation", String name, payload, Array (policyArgs f), optionalArg String correlation', optionalArg String idempotency'])
    ( pure $ do
        policy' <- executionPolicy f
        invocationJson <$> activityInvocation (ActivityInvocationFields name payload policy' correlation' idempotency')
    )
    (fmap invocationJson . invocationOf)

failureCase :: ActivityFailureFields -> Case
failureCase f =
  Case
    (Array [String "failure", String f.failureError, String f.failureKind, f.failureDetails, Bool f.failureRetryable, optionalArg numberArg f.failureRetryAfter])
    (pure (failureJson <$> activityFailure f))
    (fmap failureJson . failureOf)

declarationCase :: (Text, Maybe Integer) -> Case
declarationCase (name, beat) =
  Case
    (Array [String "declaration", String name, optionalArg Int beat])
    (pure (declarationJson <$> activityDeclaration name beat))
    (fmap declarationJson . declarationOf)

heartbeatCase :: Json -> Case
heartbeatCase value = Case (Array [String "heartbeat", value]) (pure (snapshotHeartbeatDetails value)) snapshotHeartbeatDetails

payloadCase :: Json -> Case
payloadCase value =
  Case (Array [String "payload", value]) (pure (jsonPayloadConverter.decodePayload value)) jsonPayloadConverter.decodePayload

callCase :: (Text, [Text], Text, Json, Maybe Json) -> Case
callCase (name, parameters', activity', payload, result) =
  Case
    (Array [String "call", String name, Array (map String parameters'), String activity', payload, Bool (isJust result), fromMaybe Null result])
    run
    Right
  where
    run = case activityDeclaration name Nothing of
      Left refusal -> pure (Left refusal)
      Right declaration' -> case invocation activity' payload of
        Left refusal -> pure (Left refusal)
        Right inv -> callActivity (defineActivity declaration' parameters' (\arguments _ -> pure (fromMaybe (Object arguments) result))) inv attemptContext
    attemptContext = ActivityExecutionContext "attempt" "1" "claimant" Nothing (pure Null) (const (pure Null))

-- * Generators ------------------------------------------------------------------

seeded :: Int -> Gen a -> a
seeded seed gen = unGen gen (mkQCGen seed) 30

edgeIntegers :: [Integer]
edgeIntegers =
  [ 0, 1, 2, 10, 30, 60, 999999999, 1000000000, 1000000001, 10 ^ (12 :: Int), 2 ^ (53 :: Int), 2 ^ (53 :: Int) + 1, 2 ^ (63 :: Int)
  , 2 ^ (1023 :: Int), overflow - 1, overflow, 2 ^ (1024 :: Int), 10 ^ (400 :: Int), 10 ^ (4299 :: Int), 10 ^ (4300 :: Int)
  ]
  where
    overflow = 2 ^ (1024 :: Int) - 2 ^ (970 :: Int)

richInteger :: Gen Integer
richInteger = frequency [(4, choose (-3, 100)), (3, elements edgeIntegers), (2, negate <$> elements edgeIntegers), (1, arbitrary)]

edgeDoubles :: [Double]
edgeDoubles =
  [ 0, -0.0, 0.1, 0.25, 0.5, 1, 1.5, 2, -0.5, -1, 1.0000000000000002, 1e-308, 5e-324, 2.2250738585072014e-308
  , 1e9, 1000000000.0000001, 999999999.9999999, 1e308, 1.7976931348623157e308, 0 / 0, 1 / 0, -1 / 0
  ]

richDouble :: Gen Double
richDouble = frequency [(3, elements edgeDoubles), (2, choose (0, 100)), (1, choose (0, 2e9)), (1, choose (1, 3)), (1, arbitrary)]

richNumber :: Gen Number
richNumber = oneof [IntNumber <$> richInteger, FloatNumber <$> richDouble]

duration :: Gen Number
duration =
  frequency
    [ (5, IntNumber <$> choose (0, 120))
    , (5, FloatNumber <$> choose (0, 120))
    , (2, elements [FloatNumber 0.001, FloatNumber 1e-308, FloatNumber 5e-324, IntNumber 1000000000, FloatNumber 999999999.5, FloatNumber 0])
    , (2, richNumber)
    ]

coefficient' :: Gen Number
coefficient' =
  frequency
    [ (6, elements [1, FloatNumber 1, FloatNumber 1.5, 2, 3, 10, FloatNumber 1.0000000000000002, FloatNumber 1e308, IntNumber (2 ^ (53 :: Int) + 1), IntNumber (2 ^ (60 :: Int) + 1), IntNumber (2 ^ (1000 :: Int) + 12345)])
    , (4, FloatNumber <$> choose (1, 5))
    , (1, richNumber)
    ]

jitter' :: Gen Number
jitter' = frequency [(8, elements [0, FloatNumber 0, FloatNumber (-0.0)]), (1, richNumber)]

count :: Gen Integer
count = frequency [(8, choose (1, 40)), (2, richInteger)]

retryFields :: Gen RetryPolicyFields
retryFields = RetryPolicyFields <$> duration <*> coefficient' <*> duration <*> count <*> jitter'

failedAttempt :: Gen Integer
failedAttempt = frequency [(6, choose (1, 40)), (1, elements [316, 1000, 10 ^ (9 :: Int), 10 ^ (1000 :: Int), 10 ^ (5000 :: Int), 2 ^ (64 :: Int)]), (1, richInteger)]

heartbeatTimeout' :: Gen Integer
heartbeatTimeout' = frequency [(6, choose (1, 3600)), (2, richInteger)]

maybeOf :: Gen a -> Gen (Maybe a)
maybeOf gen = frequency [(1, pure Nothing), (3, Just <$> gen)]

policyFields' :: Gen ExecutionPolicyFields
policyFields' =
  ExecutionPolicyFields
    <$> count
    <*> heartbeatTimeout'
    <*> duration
    <*> coefficient'
    <*> duration
    <*> jitter'
    <*> maybeOf duration
    <*> maybeOf duration

richChar :: Gen Char
richChar = frequency [(6, choose ('a', 'z')), (2, elements "'\"\\ \n\t\x7f\x80\xa0\xad\x2028\xe9\xdf\x1e9e\x4e2d\x1f600\x1f"), (1, arbitrary)]

name' :: Gen Text
name' =
  frequency
    [ (4, elements ["work", "charge_card", "it's", "say \"hi\"", "\xe9", "\x1f600", "a\nb", "\x7f", "back\\slash", "\x1e9e", "x"])
    , (1, pure "")
    , (3, T.pack <$> resize 12 (listOf1 richChar))
    ]

sized' :: [Int] -> Gen Text
sized' lengths = do
  n <- elements lengths
  T.pack <$> vectorOf n richChar

finiteDouble :: Gen Double
finiteDouble = frequency [(10, choose (-1e6, 1e6)), (3, elements [0, -0.0, 0.1, 1e-308, 5e-324, 1e308, 1.5]), (1, elements [0 / 0, 1 / 0, -1 / 0])]

anyInteger :: Gen Integer
anyInteger =
  frequency
    [ (10, choose (-1000, 1000))
    , (2, arbitrary)
    , (1, elements [2 ^ (53 :: Int) + 1, 10 ^ (30 :: Int), 10 ^ (4299 :: Int), -(10 ^ (4299 :: Int))])
    , (1, elements [10 ^ (4300 :: Int), -(10 ^ (4300 :: Int))])
    ]

jsonValue :: Int -> Gen Json
jsonValue depth =
  frequency $
    [ (2, pure Null)
    , (2, Bool <$> arbitrary)
    , (3, Int <$> anyInteger)
    , (3, Float <$> finiteDouble)
    , (3, String . T.pack <$> resize 10 (listOf richChar))
    ]
      ++ if depth <= 0
        then []
        else
          [ (2, Array <$> resize 4 (listOf (jsonValue (depth - 1))))
          , (2, objectOf ((T.pack <$> resize 6 (listOf richChar))) (jsonValue (depth - 1)))
          ]

objectOf :: Gen Text -> Gen Json -> Gen Json
objectOf key value = do
  keys <- nub <$> resize 4 (listOf key)
  Object <$> mapM (\k -> (k,) <$> value) keys

-- | A string whose encoding lands within a few bytes of a limit, with or
-- without a multi-byte character.
nearLimit :: Int -> Gen Json
nearLimit limit = do
  extra <- choose (-3, 3)
  wide <- arbitrary
  let n = limit - 2 + extra
  pure (String (if wide then T.replicate (n - 2) "x" <> "\xe9" else T.replicate n "x"))

-- * The corpora ------------------------------------------------------------------

retryCorpus :: [Case]
retryCorpus = map retryCase (seeded 11 (vectorOf 2500 retryFields))

delayCorpus :: [Case]
delayCorpus =
  map delayCase $
    seeded 12 (vectorOf 3000 ((,) <$> retryFields <*> failedAttempt))
      ++ [(f, attempt) | f <- extremes, attempt <- [1, 2, 3, 10, 316, 10 ^ (9 :: Int)]]
  where
    -- test_backoff_handles_extreme_finite_values_without_ratio_or_power_overflow
    extremes =
      [ RetryPolicyFields (FloatNumber 1e9) 2 (FloatNumber 1e8) 3 0
      , RetryPolicyFields (FloatNumber 1e-308) 1 (FloatNumber 1e9) 3 0
      , RetryPolicyFields (FloatNumber 1e-308) (FloatNumber 1e308) (FloatNumber 1e9) 3 0
      , RetryPolicyFields (FloatNumber 1e-308) 10 (FloatNumber 1e9) 3 0
      , RetryPolicyFields (FloatNumber 5e-324) (FloatNumber 1.0000000000000002) (FloatNumber 1e9) 3 0
      , RetryPolicyFields 1 10 60 10000 0
      ]

policyCorpus :: [Case]
policyCorpus = map policyCase (seeded 13 (vectorOf 2500 policyFields'))

invocationCorpus :: [Case]
invocationCorpus =
  map invocationCase . seeded 14 . vectorOf 1500 $
    (,,,,)
      <$> name'
      <*> jsonValue 2
      <*> frequency [(4, pure (policyFields defaultExecutionPolicy)), (1, policyFields')]
      <*> maybeOf name'
      <*> maybeOf name'

failureCorpus :: [Case]
failureCorpus =
  map failureCase . seeded 15 . vectorOf 2500 $
    ActivityFailureFields
      <$> frequency [(5, name'), (1, sized' [0, 1, 4095, 4096, 4097])]
      <*> frequency [(5, name'), (1, sized' [0, 1, 127, 128, 129])]
      <*> frequency [(6, jsonValue 3), (1, nearLimit 16384)]
      <*> arbitrary
      <*> maybeOf duration

declarationCorpus :: [Case]
declarationCorpus = map declarationCase (seeded 16 (vectorOf 800 ((,) <$> name' <*> maybeOf heartbeatTimeout')))

heartbeatCorpus :: [Case]
heartbeatCorpus = map heartbeatCase (seeded 17 (vectorOf 2000 (frequency [(8, jsonValue 3), (1, nearLimit 65536)])))

payloadCorpus :: [Case]
payloadCorpus = map payloadCase (seeded 18 (vectorOf 2000 (jsonValue 3)))

callCorpus :: [Case]
callCorpus = map callCase (seeded 19 (vectorOf 2000 call))
  where
    pool = ["a", "b", "c", "\xe9", "it's"]
    call = do
      name <- elements ["add", "work", "it's", "\xe9", ""]
      parameters' <- nub <$> resize 3 (listOf (elements pool))
      activity' <- frequency [(4, pure name), (1, elements ["add", "sub", "say \"hi\"", ""])]
      payload <-
        frequency
          [ (6, Object <$> mapM (\p -> (p,) <$> jsonValue 1) parameters')
          , (3, objectOf (elements pool) (jsonValue 1))
          , (1, jsonValue 1)
          ]
      result <- maybeOf (jsonValue 2)
      pure (name, parameters', activity', payload, result)

spec :: Spec
spec = describe "differential against the pinned petrus.motus.activity" $ do
  differential "RetryPolicy" retryCorpus
  differential "RetryPolicy.delay" delayCorpus
  differential "ExecutionPolicy" policyCorpus
  differential "ActivityInvocation" invocationCorpus
  differential "ActivityFailure" failureCorpus
  differential "ActivityDeclaration" declarationCorpus
  differential "snapshot_heartbeat_details" heartbeatCorpus
  differential "JsonPayloadConverter" payloadCorpus
  differential "ActivityDefinition.__call__" callCorpus
  it "the corpora's requests survive the transport (integers of any size, NaN, every code point)" $ do
    let requests = concatMap (map (.request)) [retryCorpus, delayCorpus, policyCorpus, invocationCorpus, failureCorpus, heartbeatCorpus, payloadCorpus, callCorpus]
    [r | r <- requests, either (const True) (not . exactEq r) (parseJson reading (spell transport r))] `shouldBe` []
    -- And they decode as UTF-8 text (no lone surrogate reaches the oracle).
    all (either (const False) (const True) . TE.decodeUtf8' . spell wire) requests `shouldBe` True
