-- | Parity: @tests/integration/test_activity_seam.py@ — the
-- activity-invocation seam [DR 2026-07-14 activity-invocation-runtime-seam].
--
-- An impure transition binds an 'ActivityHandler': @prepare@ produces one
-- Petri-agnostic invocation before anything is appended, the begin batch
-- freezes it as @ActivityRequested@, the terminal result freezes as
-- @ActivityCompleted@ (its own append, before projection), and @project@
-- maps the frozen result into the completion boundary.
--
-- __What changes in translation.__
--
-- * @Engine@ and @InlineDispatch@ live in other packages. Where an upstream
--   test drives the seam through them, this spec drives the Instance doors
--   directly with 'advanceUntilRest', a test-local inline driver (begin, run
--   the activity in Haskell, record the terminal fact, complete or fail).
--   Cases whose subject is the Engine or Dispatch itself are listed as not
--   at parity in the ledger.
-- * @JsonlHistoryStore@ is out of scope. The kill windows are pinned over
--   'reloaded': the History's records encoded to their wire bytes, parsed,
--   decoded, and loaded into a fresh store — the same durable round trip a
--   process restart over a JSONL file performs.
-- * Python handlers count their own @prepare@/@project@ calls to betray
--   re-runs. Here both are pure functions, so a re-run is unobservable by
--   design; the specs assert the observable effect instead (the projected
--   marking, the records), use a poisoned @prepare@ wherever "never
--   re-prepares" is the point, and count the activity's executions (which
--   are IO in the inline driver).
-- * A Python handler mutated in place to model "the fix, redeployed" is a
--   fresh 'resume' over the same History with the fixed handler.
module Petrus.Impetus.ActivitySeamSpec (spec) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Codec (decodeRecord, encodeRecord, schemaVersion)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (Admission (..), CommitMode (..), HistoryStore, inMemoryHistoryStore, mirroredHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, netOf, np, obj, tok, tokD)
import Petrus.Json (Json (..), compact, dumps, lookupMember, parseJson, strictLoads)
import Test.Hspec hiding (before)

-- ---------------------------------------------------------------------------
-- Fixtures

a', b', t', gate :: NetPath
a' = np "a"
b' = np "b"
t' = np "t"
gate = np "gate"

payment :: Token
payment = tokD "Payment" (obj [("amount", Int 100)])

receipt :: Text -> Token
receipt s = tokD "Receipt" (obj [("status", String s)])

-- | @Transition(path, handler=symbol)@ (constructed positionally: a record
-- update of @handler@ would be ambiguous here).
handled :: NetPath -> Maybe Text -> Transition
handled at symbol = Transition at (HandlerSymbol <$> symbol) [] []

-- | An arc with mode and color.
arcWith :: NetPath -> NetPath -> ArcMode -> Int -> Maybe Color -> Arc
arcWith from to mode' weight' color' = Arc from to mode' weight' color' Nothing

colored :: Color -> NetPath -> NetPath -> Arc
colored c from to = arcWith from to Consume 1 (Just c)

-- | a -> t (activity-handled) -> b.
activityNet :: Maybe Text -> Net
activityNet handler = netOf [place a', place b'] [handled t' handler] [arc a' t', arc t' b']

-- | Python's @data[key]@ on a JSON object, failing as a @KeyError@ would.
member :: Text -> Json -> Either Text Json
member key value = maybe (Left ("KeyError(" <> pyQuote key <> ")")) Right (lookupMember key value)

pyQuote :: Text -> Text
pyQuote s = "'" <> s <> "'"

-- | The reference ActivityHandler (@ChargeCard@): prepare typed input off
-- the binding, project the frozen provider result.
chargeCardWith :: Maybe Text -> Maybe Text -> ActivityHandler
chargeCardWith correlation' idempotency' =
  ActivityHandler
    { prepare = \b -> case bindingTokens b of
        [p] -> do
          amount <- member "amount" p.payload
          Right (ActivityInvocation "charge_card" (obj [("amount", amount)]) defaultExecutionPolicy correlation' idempotency')
        _ -> Left "ValueError('too many values to unpack')"
    , project = \_ result -> do
        s <- member "status" result
        Right (handlerTokens [(b', [Token (Just "Receipt") (obj [("status", s)])])])
    , projectFailure = Nothing
    }

chargeCard :: ActivityHandler
chargeCard = chargeCardWith Nothing Nothing

-- | @PoisonedPrepare@: a prepare that must never run again.
poisonedPrepare :: ActivityHandler
poisonedPrepare = chargeCard {prepare = \_ -> Left "AssertionError('resume re-ran prepare')"}

-- | A handler whose projection raises (@raise KeyError("statuss")@).
brokenProjection :: ActivityHandler
brokenProjection = chargeCard {project = \_ _ -> Left "KeyError('statuss')"}

-- | @FailureProjectingCharge@: opts into failure projection.
failureProjectingCharge :: Bool -> ActivityHandler
failureProjectingCharge broken =
  chargeCard
    { projectFailure = Just $ \_ failure ->
        if broken
          then Left "RuntimeError('failure projection crashed')"
          else
            let x = failureFields failure
             in Right
                  ( handlerTokens
                      [(b', [tokD "ActivityFailure" (obj [("kind", String x.failureKind), ("details", x.failureDetails)])])]
                  )
    }

handlersOf :: [(Text, BoundHandler)] -> Map.Map ImplementationRef BoundHandler
handlersOf xs = Map.fromList [(Symbol k, h) | (k, h) <- xs]

configFor :: ActivityHandler -> InstanceConfig
configFor h = defaultInstanceConfig {handlerImplementations = handlersOf [("charge", ActivityBound h)]}

-- | @_instance(handler, marking, history)@.
seamInstance :: ActivityHandler -> Maybe HistoryStore -> IO Instance
seamInstance h store =
  newInstance
    (activityNet (Just "charge"))
    (configFor h) {initialMarking = markingFromList [(a', [payment])], historyStore = store}
    >>= expectRight

-- | @_begun(handler, history)@.
begun :: ActivityHandler -> Maybe HistoryStore -> IO (Instance, FiringOccurrence)
begun h store = do
  inst <- seamInstance h store
  o <- beginHead inst Nothing
  pure (inst, o)

beginHead :: Instance -> Maybe Instant -> IO FiringOccurrence
beginHead inst at = do
  bindings <- candidates inst
  case bindings of
    b : _ -> begin inst b at >>= expectRight
    [] -> expectationFailure "no candidate" >> error "unreachable"

-- | A pure instance over @_activity_net(handler=None)@.
pureInstance :: IO Instance
pureInstance =
  newInstance (activityNet Nothing) defaultInstanceConfig {initialMarking = markingFromList [(a', [payment])]} >>= expectRight

-- | @Instance.resume(_activity_net(), history, handlers={"charge": h})@.
resumeWith :: ActivityHandler -> HistoryStore -> IO Instance
resumeWith h store = resume (activityNet (Just "charge")) store (configFor h) >>= expectRight

historyOf :: Instance -> IO [Record]
historyOf inst = Store.records (instanceHistory inst)

lastN :: Int -> [a] -> [a]
lastN n xs = drop (length xs - n) xs

countWhere :: (Record -> Bool) -> [Record] -> Int
countWhere p = length . filter p

isCompletedRecord, isFailedRecord, isFiringCompleted, isFiringFailed :: Record -> Bool
isCompletedRecord = \case RActivityCompleted _ -> True; _ -> False
isFailedRecord = \case RActivityFailed _ -> True; _ -> False
isFiringCompleted = \case RFiringCompleted _ -> True; _ -> False
isFiringFailed = \case RFiringFailed _ -> True; _ -> False

activityCompletedRecords :: [Record] -> [ActivityCompleted]
activityCompletedRecords rs = [r | RActivityCompleted r <- rs]

-- | @ActivityFailed(T, error, occurrence=o, instant=i)@ with the defaults.
activityFailedRecord :: Text -> Int -> Instant -> Record
activityFailedRecord err o i = RActivityFailed (ActivityFailed t' err "ActivityError" Null False Nothing o i)

failureOf :: Text -> Text -> Json -> Bool -> Maybe Number -> ActivityFailure
failureOf err kind' details' retryable' retryAfter' =
  either (error . T.unpack) id (activityFailure (ActivityFailureFields err kind' details' retryable' retryAfter'))

simple :: Text -> ActivityFailure
simple err = failureOf err "ActivityError" Null False Nothing

-- | The door refused with exactly this message (the reference's
-- @ValueError@).
refusedWith :: HasCallStack => Either InstanceError a -> Text -> Expectation
refusedWith result message = case result of
  Left (Refused m) -> m `shouldBe` message
  Left other -> expectationFailure ("expected Refused " <> show message <> ", got " <> show other)
  Right _ -> expectationFailure ("expected Refused " <> show message <> ", the door succeeded")

-- | The handler (prepare, project) raised with exactly this text.
raisedWith :: HasCallStack => Either InstanceError a -> Text -> Expectation
raisedWith result message = case result of
  Left (HandlerRaised m) -> m `shouldBe` message
  Left other -> expectationFailure ("expected HandlerRaised " <> show message <> ", got " <> show other)
  Right _ -> expectationFailure ("expected HandlerRaised " <> show message <> ", the door succeeded")

shouldReplayRefuse :: (HasCallStack, Show a) => Either Text a -> Text -> Expectation
shouldReplayRefuse result message = case result of
  Left m -> m `shouldBe` message
  Right v -> expectationFailure ("expected replay divergence " <> show message <> ", got " <> show v)

-- | The durable round trip a JSONL History gives a restarted process: each
-- record encoded to wire bytes, parsed, decoded, and loaded into a fresh
-- store (the original store is abandoned — the kill).
reloaded :: HistoryStore -> IO HistoryStore
reloaded store = do
  rs <- Store.records store
  decoded <- forM rs $ \r -> do
    bytes <- either (fail . show) pure (dumps compact (encodeRecord r))
    value <- either fail pure (parseJson strictLoads bytes)
    either (fail . T.unpack) pure (decodeRecord value)
  mirroredHistoryStore BackendOwned (Seq.fromList decoded) (pure . map (const Entered))

-- | @_BatchRecordingHistory@: an in-memory store that records every
-- committed batch.
batchRecordingStore :: IO (HistoryStore, IORef [[Record]])
batchRecordingStore = do
  batches <- newIORef []
  store <- mirroredHistoryStore BackendOwned Seq.empty $ \batch -> do
    modifyIORef' batches (++ [batch])
    pure (map (const Entered) batch)
  pure (store, batches)

-- | A store pre-loaded with records (@InMemoryHistoryStore().extend(...)@).
storeOf :: [Record] -> IO HistoryStore
storeOf rs = do
  store <- inMemoryHistoryStore
  store.extend rs
  pure store

-- ---------------------------------------------------------------------------
-- The inline driver (Engine + InlineDispatch emulated)

-- | An execution adapter: run the named activity to a terminal outcome.
type Dispatch = ActivityInvocation -> IO (Either ActivityFailure Json)

-- | A test-local stand-in for @Engine.advance@ over @InlineDispatch@: begin
-- the scheduler's head candidate; a pure occurrence completes with its
-- handler's result; an impure one runs its activity, freezes the terminal
-- fact, and completes (projecting it) — or, on exhausted execution, fails
-- the firing and stops with the Engine's "failed terminally" refusal.
advanceUntilRest :: Instance -> Dispatch -> IO (Either InstanceError [FiringOutcome])
advanceUntilRest inst dispatch = go []
  where
    go acc =
      candidates inst >>= \case
        [] -> pure (Right (reverse acc))
        b : _ ->
          fire b >>= \case
            Left err -> pure (Left err)
            Right outcome -> go (outcome : acc)
    fire b = runExceptT $ do
      o <- ExceptT (begin inst b Nothing)
      case (o.invocation, boundHandler inst b.transition) of
        (Nothing, PureHandler h) -> do
          envelope <- either (throwE . HandlerRaised) pure (h b (outputs (instanceNet inst) b.transition))
          ExceptT (complete inst o (Just envelope) Nothing)
        (Nothing, ActivityBound _) -> throwE (RuntimeRefused "an ActivityHandler occurrence began without an invocation")
        (Just inv, _) ->
          liftIO (dispatch inv) >>= \case
            Right result -> do
              _ <- ExceptT (recordActivityCompletion inst o result Nothing)
              ExceptT (complete inst o Nothing Nothing)
            Left failure -> do
              ExceptT (failFiring inst o (FailureValue failure) Nothing)
              throwE
                ( RuntimeRefused
                    ( "firing occurrence " <> T.pack (show o.occurrence) <> " failed terminally: "
                        <> (failureFields failure).failureError
                    )
                )

-- | An activity answering with one fixed result.
answering :: Json -> Dispatch
answering result _ = pure (Right result)

-- ---------------------------------------------------------------------------
-- Typed payloads (the reference's dataclasses and payload converters)

newtype PaymentInput = PaymentInput Integer
  deriving stock (Eq, Show)

data ReceiptOutput = ReceiptOutput Text Integer
  deriving stock (Eq, Show)

newtype AccountInput = AccountInput Text
  deriving stock (Eq, Show)

newtype LimitInput = LimitInput Integer
  deriving stock (Eq, Show)

newtype CheckedOutput = CheckedOutput Bool
  deriving stock (Eq, Show)

newtype CustomInput = CustomInput Integer
  deriving stock (Eq, Show)

newtype CustomOutput = CustomOutput Integer
  deriving stock (Eq, Show)

intMember :: Text -> Json -> Either Text Integer
intMember key value =
  member key value >>= \case
    Int n -> Right n
    other -> Left ("TypeError(" <> T.pack (show other) <> ")")

textMember :: Text -> Json -> Either Text Text
textMember key value =
  member key value >>= \case
    String s -> Right s
    other -> Left ("TypeError(" <> T.pack (show other) <> ")")

-- | The dataclass converter ignores members the dataclass does not declare
-- (the reference decodes @{"amount": 100, "currency": "USD"}@ to
-- @PaymentInput(100)@).
instance Typed PaymentInput where
  typedColor = "PaymentInput"
  toPayload (PaymentInput n) = obj [("amount", Int n)]
  fromPayload v = PaymentInput <$> intMember "amount" v

instance Typed ReceiptOutput where
  typedColor = "ReceiptOutput"
  toPayload (ReceiptOutput s n) = obj [("status", String s), ("amount", Int n)]
  fromPayload v = ReceiptOutput <$> textMember "status" v <*> intMember "amount" v

instance Typed AccountInput where
  typedColor = "AccountInput"
  toPayload (AccountInput s) = obj [("account", String s)]
  fromPayload v = AccountInput <$> textMember "account" v

instance Typed LimitInput where
  typedColor = "LimitInput"
  toPayload (LimitInput n) = obj [("maximum", Int n)]
  fromPayload v = LimitInput <$> intMember "maximum" v

instance Typed CheckedOutput where
  typedColor = "CheckedOutput"
  toPayload (CheckedOutput accepted) = obj [("accepted", Bool accepted)]
  fromPayload v =
    member "accepted" v >>= \case
      Bool accepted -> Right (CheckedOutput accepted)
      other -> Left ("TypeError(" <> T.pack (show other) <> ")")

-- | The user converter of @test_a_typed_activity_uses_a_user_payload_converter@:
-- @CustomInput(int(value))@ in, @{"doubled": value.doubled}@ out.
instance Typed CustomInput where
  typedColor = "CustomInput"
  toPayload (CustomInput n) = String (T.pack (show n))
  fromPayload = \case
    String s | [(n, "")] <- reads (T.unpack s) -> Right (CustomInput n)
    other -> Left ("ValueError(" <> T.pack (show other) <> ")")

instance Typed CustomOutput where
  typedColor = "CustomOutput"
  toPayload (CustomOutput n) = obj [("doubled", Int n)]
  fromPayload v = CustomOutput <$> intMember "doubled" v

-- | One named argument of an invocation, decoded.
argument :: forall p. Typed p => Text -> ActivityInvocation -> Either Text p
argument name inv = maybe (Left ("missing parameter " <> name)) (fromPayload @p) (lookupMember name inv.input)

-- | The activity's terminal outcome: a decode failure is an activity failure.
typedOutcome :: Typed r => Either Text r -> Either ActivityFailure Json
typedOutcome = either (Left . simple) (Right . toPayload)

-- | Derive (or fail the spec) a handler from a typed signature.
derived :: HasCallStack => Net -> NetPath -> Text -> [(Text, Color)] -> Color -> IO ActivityHandler
derived net at name parameters result = expectRight (derivedActivityHandler net at name parameters result)

derivedInstance :: Net -> Text -> ActivityHandler -> [(NetPath, [Token])] -> Maybe HistoryStore -> IO Instance
derivedInstance net symbol h initial store =
  newInstance
    net
    defaultInstanceConfig
      { initialMarking = markingFromList initial
      , handlerImplementations = handlersOf [(symbol, ActivityBound h)]
      , historyStore = store
      }
    >>= expectRight

derivationRefused :: HasCallStack => Either Text ActivityHandler -> Text -> Expectation
derivationRefused result message = case result of
  Left m -> m `shouldBe` message
  Right _ -> expectationFailure ("expected the derivation to refuse with " <> show message)

-- ---------------------------------------------------------------------------
-- Activity value fixtures

policyWith :: (ExecutionPolicyFields -> ExecutionPolicyFields) -> Either Text ExecutionPolicy
policyWith f = executionPolicy (f (policyFields defaultExecutionPolicy))

retryWith :: (RetryPolicyFields -> RetryPolicyFields) -> Either Text RetryPolicy
retryWith f = retryPolicy (f (retryPolicyFields defaultRetryPolicy))

mustRetry :: Either Text RetryPolicy -> RetryPolicy
mustRetry = either (error . T.unpack) id

failureWithRetryAfter :: Number -> Either Text ActivityFailure
failureWithRetryAfter n = activityFailure (ActivityFailureFields "failed" "ActivityError" Null False (Just n))

-- | @_begin_records(with_request=...)@.
beginRecords :: Bool -> [Record]
beginRecords withRequest =
  [ RCandidateSelected (CandidateSelected t' 1 1)
  , RFiringBegun (FiringBegun t' 1 Nothing 1)
  , RTokensConsumed (TokensConsumed a' [payment] 1 [] Nothing 1)
  ]
    ++ [requestRecord | withRequest]

requestRecord :: Record
requestRecord =
  RActivityRequested (ActivityRequested t' "charge_card" Null defaultExecutionPolicy "occurrence-1" "occurrence-1" 1 Nothing 1)

-- | @activity_construction_records()@.
activityConstructionRecords :: IO [Record]
activityConstructionRecords = seamInstance chargeCard Nothing >>= historyOf

spec :: Spec
spec = describe "Activity invocation seam" $ do
  publicSurface
  derivedHandlers
  activityValues
  purity
  beginFreezes
  recordCompletion
  endedAcknowledgement
  terminalReplayDivergence
  completeProjects
  appendBoundaries
  failDoor
  stepRefuses
  engineDrives
  killWindows
  terminalFailureProjection
  replayGuards
  canonicalPayloads
  k6AcrossResume
  beginBatchOrder

publicSurface :: Spec
publicSurface = describe "the public surface" $ do
  -- test_canonical_activity_and_history_codec_imports_are_public
  it "exposes the canonical activity values and the History codec" $ do
    (failureFields (simple "boom")).failureError `shouldBe` "boom"
    (invocation "work" Null).policy `shouldBe` defaultExecutionPolicy
    store <- inMemoryHistoryStore
    Store.size store `shouldReturn` 0
    schemaVersion `shouldBe` 5
    decodeRecord (encodeRecord requestRecord) `shouldBe` Right requestRecord

derivedHandlers :: Spec
derivedHandlers = describe "DerivedActivityHandler" $ do
  -- test_a_typed_activity_derives_its_ordinary_handler_from_the_net_shape
  it "derives its ordinary handler from the net shape" $ do
    let source = np "typed.source"
        target = np "typed.target"
        work = np "typed.work"
        net =
          netOf
            [coloredPlace source "PaymentInput", coloredPlace target "ReceiptOutput"]
            [handled work (Just "typed_work")]
            [arc source work, arc work target]
    received <- newIORef []
    let typedWork inv = do
          let decoded = argument @PaymentInput "payment" inv
          forM_ decoded $ \p -> modifyIORef' received (++ [p])
          pure (typedOutcome ((\(PaymentInput n) -> ReceiptOutput "captured" n) <$> decoded))
    h <- derived net work "typed_work" [("payment", "PaymentInput")] "ReceiptOutput"
    store <- inMemoryHistoryStore
    inst <-
      derivedInstance
        net
        "typed_work"
        h
        [(source, [tokD "PaymentInput" (obj [("amount", Int 100), ("currency", String "USD")])])]
        (Just store)
    _ <- advanceUntilRest inst typedWork >>= expectRight
    readIORef received `shouldReturn` [PaymentInput 100]
    rs <- Store.records store
    [r.input | RActivityRequested r <- rs] `shouldBe` [obj [("payment", obj [("amount", Int 100), ("currency", String "USD")])]]
    [r.result | RActivityCompleted r <- rs] `shouldBe` [obj [("status", String "captured"), ("amount", Int 100)]]
    marking inst
      `shouldReturn` markingFromList [(target, [tokD "ReceiptOutput" (obj [("status", String "captured"), ("amount", Int 100)])])]

  -- test_a_derived_handler_passes_unique_consume_and_read_selections_as_typed_arguments
  it "passes unique consume and read selections as typed arguments" $ do
    let account = np "account"
        limit = np "limit"
        target = np "checked"
        check = np "check"
        net =
          netOf
            [place account, place limit, place target]
            [handled check (Just "check")]
            [ colored "AccountInput" account check
            , arcWith limit check Read 1 (Just "LimitInput")
            , colored "CheckedOutput" check target
            ]
    received <- newIORef []
    let checkActivity inv = do
          let decoded = (,) <$> argument @AccountInput "subject" inv <*> argument @LimitInput "policy" inv
          forM_ decoded $ \pair -> modifyIORef' received (++ [pair])
          pure (typedOutcome ((\(_, LimitInput maximal) -> CheckedOutput (maximal >= 10)) <$> decoded))
    h <- derived net check "check" [("subject", "AccountInput"), ("policy", "LimitInput")] "CheckedOutput"
    inst <-
      derivedInstance
        net
        "check"
        h
        [ (account, [tokD "AccountInput" (obj [("account", String "A-1")])])
        , (limit, [tokD "LimitInput" (obj [("maximum", Int 10)])])
        ]
        Nothing
    _ <- advanceUntilRest inst checkActivity >>= expectRight
    readIORef received `shouldReturn` [(AccountInput "A-1", LimitInput 10)]
    marking inst
      `shouldReturn` markingFromList
        [ (limit, [tokD "LimitInput" (obj [("maximum", Int 10)])])
        , (target, [tokD "CheckedOutput" (obj [("accepted", Bool True)])])
        ]

  -- test_a_derived_handler_distinguishes_two_typed_arcs_from_the_same_place
  it "distinguishes two typed arcs from the same place" $ do
    let source = np "inputs"
        target = np "checked"
        check = np "check"
        net =
          netOf
            [place source, place target]
            [handled check (Just "check")]
            [colored "AccountInput" source check, colored "LimitInput" source check, colored "CheckedOutput" check target]
    received <- newIORef []
    let checkActivity inv = do
          let decoded = (,) <$> argument @AccountInput "subject" inv <*> argument @LimitInput "policy" inv
          forM_ decoded $ \pair -> modifyIORef' received (++ [pair])
          pure (typedOutcome ((\(_, LimitInput maximal) -> CheckedOutput (maximal >= 10)) <$> decoded))
    h <- derived net check "check" [("subject", "AccountInput"), ("policy", "LimitInput")] "CheckedOutput"
    inst <-
      derivedInstance
        net
        "check"
        h
        [(source, [tokD "AccountInput" (obj [("account", String "A-1")]), tokD "LimitInput" (obj [("maximum", Int 10)])])]
        Nothing
    _ <- advanceUntilRest inst checkActivity >>= expectRight
    readIORef received `shouldReturn` [(AccountInput "A-1", LimitInput 10)]
    marking inst `shouldReturn` markingFromList [(target, [tokD "CheckedOutput" (obj [("accepted", Bool True)])])]

  -- test_a_derived_handler_projects_once_per_matching_output_arc
  it "projects once per matching output arc" $ do
    let source = np "payment"
        target = np "receipts"
        charge = np "charge"
        net =
          netOf
            [place source, place target]
            [handled charge (Just "charge")]
            [colored "PaymentInput" source charge, colored "ReceiptOutput" charge target, colored "ReceiptOutput" charge target]
        chargeActivity inv =
          pure (typedOutcome ((\(PaymentInput n) -> ReceiptOutput "captured" n) <$> argument @PaymentInput "payment" inv))
    h <- derived net charge "charge" [("payment", "PaymentInput")] "ReceiptOutput"
    inst <- derivedInstance net "charge" h [(source, [tokD "PaymentInput" (obj [("amount", Int 100)])])] Nothing
    _ <- advanceUntilRest inst chargeActivity >>= expectRight
    let produced = tokD "ReceiptOutput" (obj [("status", String "captured"), ("amount", Int 100)])
    marking inst `shouldReturn` markingFromList [(target, [produced, produced])]

  -- test_a_derived_handler_refuses_a_typed_input_arc_no_activity_parameter_receives
  it "refuses a typed input arc no activity parameter receives" $ do
    let paymentPlace = np "payment"
        limit = np "limit"
        target = np "receipt"
        charge = np "charge"
        net =
          netOf
            [place paymentPlace, place limit, place target]
            [handled charge (Just "charge")]
            [colored "PaymentInput" paymentPlace charge, colored "LimitInput" limit charge, colored "ReceiptOutput" charge target]
    derivedActivityHandler net charge "charge" [("subject", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for charge: typed input arc limit -> charge (LimitInput) matches no Activity parameter"

  -- test_activity_declaration_does_not_silently_replace_an_explicit_empty_name
  it "an Activity declaration does not silently replace an explicit empty name" $
    activityDeclaration "" Nothing `shouldBe` Left "ActivityDeclaration requires a non-empty string name"

  -- test_a_derived_handler_refuses_ambiguous_same_color_input_arcs
  it "refuses ambiguous same-color input arcs" $ do
    let first' = np "first"
        second' = np "second"
        target = np "receipt"
        charge = np "charge"
        net =
          netOf
            [place first', place second', place target]
            [handled charge (Just "charge")]
            [colored "PaymentInput" first' charge, colored "PaymentInput" second' charge, colored "ReceiptOutput" charge target]
    derivedActivityHandler net charge "charge" [("subject", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for charge: parameter 'subject' (PaymentInput) requires exactly one matching input arc, found 2"

  -- test_a_derived_handler_refuses_to_supply_one_typed_arc_to_two_parameters
  it "refuses to supply one typed arc to two parameters" $ do
    let source = np "payment"
        target = np "receipt"
        compare' = np "compare"
        net =
          netOf
            [place source, place target]
            [handled compare' (Just "compare")]
            [colored "PaymentInput" source compare', colored "ReceiptOutput" compare' target]
    derivedActivityHandler net compare' "compare" [("first", "PaymentInput"), ("second", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for compare: parameter 'second' (PaymentInput) matches input arc payment -> compare already used by parameter 'first'"

  -- test_a_derived_handler_refuses_a_return_type_with_no_matching_output_arc
  it "refuses a return type with no matching output arc" $ do
    let source = np "payment"
        target = np "other"
        charge = np "charge"
        net =
          netOf
            [place source, place target]
            [handled charge (Just "charge")]
            [colored "PaymentInput" source charge, colored "OtherOutput" charge target]
    derivedActivityHandler net charge "charge" [("subject", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for charge: return type ReceiptOutput matches no output arc"

  -- test_a_derived_handler_refuses_an_output_arc_the_return_type_cannot_supply
  it "refuses an output arc the return type cannot supply" $ do
    let source = np "payment"
        receiptPlace = np "receipt"
        other = np "other"
        charge = np "charge"
        net =
          netOf
            [place source, place receiptPlace, place other]
            [handled charge (Just "charge")]
            [ colored "PaymentInput" source charge
            , colored "ReceiptOutput" charge receiptPlace
            , colored "OtherOutput" charge other
            ]
    derivedActivityHandler net charge "charge" [("subject", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for charge: output arc charge -> other (OtherOutput) matches no Activity return"

  -- test_a_derived_handler_refuses_a_weighted_input_until_collection_parameters_are_supported
  it "refuses a weighted input until collection parameters are supported" $ do
    let source = np "payments"
        target = np "receipt"
        charge = np "charge"
        net =
          netOf
            [place source, place target]
            [handled charge (Just "charge")]
            [arcWith source charge Consume 2 (Just "PaymentInput"), colored "ReceiptOutput" charge target]
    derivedActivityHandler net charge "charge" [("subject", "PaymentInput")] "ReceiptOutput"
      `derivationRefused` "cannot derive Activity handler for charge: parameter 'subject' (PaymentInput) matches weight-2 arc payments -> charge; collection parameters are not supported"

  -- test_a_typed_activity_uses_a_user_payload_converter_without_changing_the_runtime
  it "uses a user payload converter without changing the runtime" $ do
    let source = np "custom.input"
        target = np "custom.output"
        work = np "custom.work"
        net =
          netOf
            [place source, place target]
            [handled work (Just "custom_work")]
            [colored "CustomInput" source work, colored "CustomOutput" work target]
    received <- newIORef []
    let customWork inv = do
          let decoded = argument @CustomInput "item" inv
          forM_ decoded $ \item -> modifyIORef' received (++ [item])
          pure (typedOutcome ((\(CustomInput n) -> CustomOutput (n * 2)) <$> decoded))
    h <- derived net work "custom_work" [("item", "CustomInput")] "CustomOutput"
    inst <- derivedInstance net "custom_work" h [(source, [tokD "CustomInput" (String "7")])] Nothing
    _ <- advanceUntilRest inst customWork >>= expectRight
    readIORef received `shouldReturn` [CustomInput 7]
    marking inst `shouldReturn` markingFromList [(target, [tokD "CustomOutput" (obj [("doubled", Int 14)])])]

activityValues :: Spec
activityValues = describe "the seam's value objects" $ do
  describe "ExecutionPolicy" $ do
    -- TestExecutionPolicy.test_the_default_is_maximally_conservative
    it "the default is maximally conservative" $
      policyWith (\f -> f {attempts = 1}) `shouldBe` Right defaultExecutionPolicy

    -- TestExecutionPolicy.test_invalid_attempt_counts_are_rejected_before_a_policy_can_be_serialized
    it "invalid attempt counts are rejected before a policy can be serialized" $
      -- The reference's @attempts=True@ case is unrepresentable: attempts is an Integer.
      policyWith (\f -> f {attempts = 0})
        `shouldBe` Left "ExecutionPolicy requires attempts >= 1, got 0: an invocation that may never execute is a wedge, not a policy"

    -- TestExecutionPolicy.test_non_finite_retry_and_deadline_values_are_rejected_at_the_value_door
    it "non-finite retry and deadline values are rejected at the value door" $
      forM_ [0 / 0, 1 / 0, -1 / 0 :: Double] $ \value -> do
        retryWith (\f -> f {retryInitialInterval = FloatNumber value})
          `shouldBe` Left "RetryPolicy initial_interval must be a non-negative number"
        policyWith (\f -> f {startToClose = Just (FloatNumber value)})
          `shouldBe` Left "ExecutionPolicy start_to_close must be a positive number or None"
        failureWithRetryAfter (FloatNumber value)
          `shouldBe` Left "ActivityFailure retry_after must be a non-negative number or None"

    -- TestExecutionPolicy.test_backoff_saturates_without_overflow_and_jitter_is_not_claimed
    it "backoff saturates without overflow and jitter is not claimed" $ do
      let policy = mustRetry (retryPolicy (RetryPolicyFields 1 10 60 10000 0))
      retryDelay policy 10000 `shouldBe` Right 60
      retryWith (\f -> f {retryJitter = FloatNumber 0.1})
        `shouldBe` Left "RetryPolicy jitter is unsupported; only deterministic jitter=0 is accepted"
      retryDelay policy 0 `shouldBe` Left "RetryPolicy delay requires a failed attempt number >= 1"
      retryDelay policy (10 ^ (1000 :: Integer)) `shouldBe` Right 60

    -- TestExecutionPolicy.test_backoff_handles_extreme_finite_values_without_ratio_or_power_overflow
    it "backoff handles extreme finite values without ratio or power overflow" $ do
      let delayOf i c m attempt = retryDelay (mustRetry (retryWith (\f -> f {retryInitialInterval = i, retryCoefficient = c, retryMaxInterval = m}))) attempt
      delayOf (FloatNumber 1e9) 2 (FloatNumber 1e8) 1 `shouldBe` Right (FloatNumber 1e8)
      delayOf (FloatNumber 1e-308) 1 (FloatNumber 1e9) (10 ^ (9 :: Integer)) `shouldBe` Right (FloatNumber 1e-308)
      delayOf (FloatNumber 1e-308) (FloatNumber 1e308) (FloatNumber 1e9) 3 `shouldBe` Right (FloatNumber 1e9)
      fmap (<= FloatNumber 1e9) (delayOf (FloatNumber 1e-308) 10 (FloatNumber 1e9) 316) `shouldBe` Right True

    -- TestExecutionPolicy.test_provider_neutral_durations_refuse_values_over_one_billion_seconds
    it "provider-neutral durations refuse values over one billion seconds" $ do
      let billion = 1000000001
      retryWith (\f -> f {retryInitialInterval = billion})
        `shouldBe` Left "RetryPolicy initial_interval must be at most 1000000000 seconds for provider-neutral duration safety"
      retryWith (\f -> f {retryMaxInterval = billion})
        `shouldBe` Left "RetryPolicy max_interval must be at most 1000000000 seconds for provider-neutral duration safety"
      policyWith (\f -> f {heartbeatTimeout = 1000000001})
        `shouldBe` Left "ExecutionPolicy heartbeat_timeout must be at most 1000000000 seconds for provider-neutral duration safety"
      policyWith (\f -> f {startToClose = Just billion})
        `shouldBe` Left "ExecutionPolicy start_to_close must be at most 1000000000 seconds for provider-neutral duration safety"
      policyWith (\f -> f {scheduleToClose = Just billion})
        `shouldBe` Left "ExecutionPolicy schedule_to_close must be at most 1000000000 seconds for provider-neutral duration safety"
      failureWithRetryAfter billion
        `shouldBe` Left "ActivityFailure retry_after must be at most 1000000000 seconds for provider-neutral duration safety"

  describe "ActivityInvocation" $ do
    -- TestActivityInvocation.test_defaults_are_the_conservative_resolution
    it "defaults are the conservative resolution" $ do
      let inv = invocation "charge_card" Null
      Right inv.policy `shouldBe` policyWith (\f -> f {attempts = 1})
      inv.correlation `shouldBe` Nothing
      inv.idempotency `shouldBe` Nothing

    -- TestActivityInvocation.test_an_empty_activity_name_is_rejected
    it "an empty activity name is rejected" $
      activityInvocation (invocation "" Null) `shouldBe` Left "ActivityInvocation requires a non-empty string activity name, got ''"

    -- TestActivityInvocation.test_an_empty_supplied_identity_is_rejected
    it "an empty supplied identity is rejected" $ do
      activityInvocation (ActivityInvocation "charge_card" Null defaultExecutionPolicy (Just "") Nothing)
        `shouldBe` Left "ActivityInvocation correlation must be a non-empty string, or None for the writer to derive at begin, got ''"
      activityInvocation (ActivityInvocation "charge_card" Null defaultExecutionPolicy Nothing (Just ""))
        `shouldBe` Left "ActivityInvocation idempotency must be a non-empty string, or None for the writer to derive at begin, got ''"

purity :: Spec
purity = describe "purity is the binding's classification" $ do
  -- TestPurityClassification.test_a_plain_callable_bound_to_a_symbol_is_a_pure_projection
  it "a plain callable bound to a symbol is a pure projection" $ do
    let shape b _ = Right (handlerTokens [(b', bindingTokens b)])
    inst <-
      newInstance
        (activityNet (Just "shape"))
        defaultInstanceConfig
          { initialMarking = markingFromList [(a', [payment])]
          , handlerImplementations = handlersOf [("shape", PureHandler shape)]
          }
        >>= expectRight
    [firing] <- run inst >>= expectRight
    firing.records
      `shouldBe` [ RFiringBegun (FiringBegun t' 1 Nothing 0)
                 , RTokensConsumed (TokensConsumed a' [payment] 1 [] Nothing 0)
                 , RTokensProduced (TokensProduced b' [payment] 1 [] Nothing 0)
                 , RFiringCompleted (FiringCompleted t' 1 0)
                 ]

  -- TestPurityClassification.test_a_source_transition_must_not_bind_an_activity_handler
  it "a source transition must not bind an ActivityHandler" $ do
    let source = np "src"
        net = netOf [place b'] [handled source (Just "charge")] [arc source b']
    result <- newInstance net (configFor chargeCard)
    result
      `refusedWith` "handler declaration transition:/src#handler binds an ActivityHandler to source transition src: a source transition locally and atomically projects its delivered fact — recoverable impure work belongs in a downstream handled transition [DR 2026-07-14 source-delivery-projection-and-identity]"

beginFreezes :: Spec
beginFreezes = describe "begin freezes the request" $ do
  -- TestBeginFreezesTheRequest.test_the_begin_batch_carries_the_activity_request_after_the_reads
  it "the begin batch carries the activity request after the reads" $ do
    let config = tokD "Config" (obj [("mode", String "strict")])
        readingCharge = chargeCard {prepare = \_ -> Right (invocation "charge_card" (obj [("amount", Int 100)]))}
        net =
          netOf
            [place a', place gate, place b']
            [handled t' (Just "charge")]
            [arc a' t', arcWith gate t' Read 1 Nothing, arc t' b']
    inst <-
      newInstance net (configFor readingCharge) {initialMarking = markingFromList [(a', [payment]), (gate, [config])]}
        >>= expectRight
    o <- beginHead inst (Just 3)
    rs <- historyOf inst
    lastN 5 rs
      `shouldBe` [ RCandidateSelected (CandidateSelected t' 1 3)
                 , RFiringBegun (FiringBegun t' 1 Nothing 3)
                 , RTokensConsumed (TokensConsumed a' [payment] 1 [] Nothing 3)
                 , RTokensRead (TokensRead gate [config] 1 [] Nothing 3)
                 , RActivityRequested
                     ( ActivityRequested
                         t'
                         "charge_card"
                         (obj [("amount", Int 100)])
                         defaultExecutionPolicy
                         "occurrence-1"
                         "occurrence-1"
                         1
                         Nothing
                         3
                     )
                 ]
    o.invocation
      `shouldBe` Just
        (ActivityInvocation "charge_card" (obj [("amount", Int 100)]) defaultExecutionPolicy (Just "occurrence-1") (Just "occurrence-1"))

  -- TestBeginFreezesTheRequest.test_a_pure_occurrence_carries_no_invocation
  it "a pure occurrence carries no invocation" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    o.invocation `shouldBe` Nothing

  -- TestBeginFreezesTheRequest.test_supplied_identities_travel_verbatim
  it "supplied identities travel verbatim" $ do
    (inst, o) <- begun (chargeCardWith (Just "order-77") (Just "key-9")) Nothing
    rs <- historyOf inst
    [(r.correlation, r.idempotency) | RActivityRequested r <- rs] `shouldBe` [("order-77", "key-9")]
    ((.correlation) <$> o.invocation, (.idempotency) <$> o.invocation) `shouldBe` (Just (Just "order-77"), Just (Just "key-9"))

  -- TestBeginFreezesTheRequest.test_a_failing_prepare_appends_nothing_and_burns_no_id
  it "a failing prepare appends nothing and burns no id" $ do
    -- Python mutates the handler between calls ("once broken"); a pure
    -- prepare cannot, so the failure is chosen by the binding instead: the
    -- head candidate's token makes prepare raise, the next one does not.
    let unprepared = tokD "Payment" (obj [("broken", Bool True)])
        onceBroken =
          chargeCard
            { prepare = \b ->
                if bindingTokens b == [unprepared] then Left "RuntimeError('prepare exploded')" else chargeCard.prepare b
            }
    inst <-
      newInstance (activityNet (Just "charge")) (configFor onceBroken) {initialMarking = markingFromList [(a', [unprepared, payment])]}
        >>= expectRight
    before <- historyOf inst
    [brokenBinding, workingBinding] <- candidates inst
    bindingTokens brokenBinding `shouldBe` [unprepared]
    failed <- begin inst brokenBinding Nothing
    failed `raisedWith` "RuntimeError('prepare exploded')"
    historyOf inst `shouldReturn` before
    inFlight inst `shouldReturn` []
    o <- begin inst workingBinding (Just 1) >>= expectRight
    o.occurrence `shouldBe` 1 -- the failed prepare burned no id

  -- TestBeginFreezesTheRequest.test_a_supplied_identity_in_the_reserved_namespace_is_refused
  it "a supplied identity in the reserved namespace is refused" $
    forM_
      [ (chargeCardWith (Just "occurrence-2") Nothing, "correlation")
      , (chargeCardWith Nothing (Just "occurrence-2"), "idempotency")
      ]
      $ \(h, name) -> do
        inst <- seamInstance h Nothing
        before <- historyOf inst
        [b] <- candidates inst
        result <- begin inst b Nothing
        result
          `refusedWith` ( "cannot begin firing t: " <> name
                            <> " 'occurrence-2' uses the writer-reserved 'occurrence-' prefix — the derived self-identity namespace; supply an identity outside it, or None for the writer to derive"
                        )
        historyOf inst `shouldReturn` before

recordCompletion :: Spec
recordCompletion = describe "record_activity_completion" $ do
  -- TestRecordActivityCompletion.test_the_result_freezes_as_its_own_append_before_projection
  it "the result freezes as its own append before projection" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) (Just 5) >>= expectRight
    rs <- historyOf inst
    last rs `shouldBe` RActivityCompleted (ActivityCompleted t' (obj [("status", String "captured")]) 1 5)
    inFlight inst `shouldReturn` [o] -- frozen, not yet projected

  -- TestRecordActivityCompletion.test_a_pure_occurrence_takes_no_activity_completion
  it "a pure occurrence takes no activity completion" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    result <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): a pure firing runs no activity — complete() takes its handler's result directly"

  -- TestRecordActivityCompletion.test_an_identical_re_record_is_acknowledged_without_a_second_append
  it "an identical re-record is acknowledged without a second append" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    before <- historyOf inst
    recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    rs <- historyOf inst
    rs `shouldBe` before
    activityCompletedRecords rs `shouldBe` [ActivityCompleted t' (obj [("status", String "captured")]) 1 0]

  -- TestRecordActivityCompletion.test_a_different_late_result_is_an_operational_conflict
  it "a different late result is an operational conflict" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    result <- recordActivityCompletion inst o (obj [("status", String "declined")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): a terminal activity fact already exists with a different result — an operational conflict, not a redelivery"

  -- TestRecordActivityCompletion.test_nested_boolean_and_integer_results_are_distinct
  it "nested boolean and integer results are distinct" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("nested", Array [obj [("value", Bool True)]])]) Nothing >>= expectRight
    result <- recordActivityCompletion inst o (obj [("nested", Array [obj [("value", Int 1)]])]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): a terminal activity fact already exists with a different result — an operational conflict, not a redelivery"

  -- TestRecordActivityCompletion.test_an_ended_pure_occurrence_still_reads_as_already_ended
  it "an ended pure occurrence still reads as already ended" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    _ <- complete inst o (Just (handlerTokens [(b', [payment])])) Nothing >>= expectRight
    result <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): not in flight — this instance's occurrence 1 already ended"

endedAcknowledgement :: Spec
endedAcknowledgement = describe "ended-occurrence acknowledgement" $ do
  -- TestEndedOccurrenceAcknowledgement.test_an_identical_late_re_record_returns_the_prior_acknowledgement_quietly
  it "an identical late re-record returns the prior acknowledgement quietly" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    _ <- complete inst o Nothing Nothing >>= expectRight
    before <- historyOf inst
    recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf inst `shouldReturn` before
    inFlight inst `shouldReturn` []

  -- TestEndedOccurrenceAcknowledgement.test_the_late_acknowledgement_compares_canonical_values
  it "the late acknowledgement compares canonical values" $ do
    -- Json has one sequence type: the reference's tuple-form redelivery is
    -- the same Array here, so the acknowledgement is what is pinned.
    let result = obj [("status", String "captured"), ("codes", Array [Int 1, Int 2])]
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o result Nothing >>= expectRight
    _ <- complete inst o Nothing Nothing >>= expectRight
    before <- historyOf inst
    recordActivityCompletion inst o result Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf inst `shouldReturn` before

  -- TestEndedOccurrenceAcknowledgement.test_a_different_late_result_after_the_end_is_an_operational_conflict
  it "a different late result after the end is an operational conflict" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    _ <- complete inst o Nothing Nothing >>= expectRight
    result <- recordActivityCompletion inst o (obj [("status", String "declined")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): the occurrence ended with a different result — an operational conflict, not a redelivery"

  -- TestEndedOccurrenceAcknowledgement.test_a_late_result_after_a_terminal_failure_is_an_operational_conflict
  it "a late result after a terminal failure is an operational conflict" $ do
    (inst, o) <- begun chargeCard Nothing
    failFiring inst o (FailureText "provider down") Nothing >>= expectRight
    result <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): the occurrence ended in terminal activity failure ('provider down') — a failed occurrence cannot retroactively succeed, and a different late result is an operational conflict [DR 2026-07-14 source-delivery-projection-and-identity]"

  -- TestEndedOccurrenceAcknowledgement.test_the_terminal_result_index_rebuilds_at_resume
  it "the terminal result index rebuilds at resume" $ do
    store <- inMemoryHistoryStore
    (inst, o) <- begun chargeCard (Just store)
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    _ <- complete inst o Nothing Nothing >>= expectRight
    resumed <- reloaded store >>= resumeWith chargeCard -- the kill
    before <- historyOf resumed
    recordActivityCompletion resumed o (obj [("status", String "captured")]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf resumed `shouldReturn` before
    result <- recordActivityCompletion resumed o (obj [("status", String "declined")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): the occurrence ended with a different result — an operational conflict, not a redelivery"

  -- TestEndedOccurrenceAcknowledgement.test_replay_terminal_activity_projects_only_ended_occurrences
  it "replay_terminal_activity projects only ended occurrences" $ do
    let completed =
          [ RCandidateSelected (CandidateSelected t' 1 0)
          , RFiringBegun (FiringBegun t' 1 Nothing 0)
          , RActivityRequested (ActivityRequested t' "charge_card" Null defaultExecutionPolicy "occurrence-1" "occurrence-1" 1 Nothing 0)
          , RActivityCompleted (ActivityCompleted t' (obj [("status", String "captured")]) 1 0)
          ]
    replayTerminalActivity completed `shouldBe` Right IntMap.empty -- frozen but in flight
    replayTerminalActivity (completed ++ [RFiringCompleted (FiringCompleted t' 1 0)])
      `shouldBe` Right (IntMap.fromList [(1, TerminalResult (obj [("status", String "captured")]))])
    let failed =
          [ RCandidateSelected (CandidateSelected t' 1 0)
          , RFiringBegun (FiringBegun t' 1 Nothing 0)
          , activityFailedRecord "provider down" 1 0
          , RFiringFailed (FiringFailed t' "provider down" 1 0)
          ]
    replayTerminalActivity failed `shouldBe` Right (IntMap.fromList [(1, TerminalFailure (simple "provider down"))])

terminalReplayDivergence :: Spec
terminalReplayDivergence = describe "terminal activity replay divergence" $ do
  let captured = RActivityCompleted (ActivityCompleted t' (obj [("status", String "captured")]) 1 0)
      declined = RActivityCompleted (ActivityCompleted t' (obj [("status", String "declined")]) 1 0)
      down = activityFailedRecord "provider down" 1 0
      stillDown = activityFailedRecord "still down" 1 0
  -- TestTerminalActivityReplayDivergence.test_a_second_terminal_activity_fact_is_replay_divergence
  it "a second terminal activity fact is replay divergence" $
    forM_ [(captured, down), (down, captured), (down, stillDown), (captured, declined)] $ \(first', second') ->
      replayTerminalActivity
        [ RCandidateSelected (CandidateSelected t' 1 0)
        , RFiringBegun (FiringBegun t' 1 Nothing 0)
        , first'
        , second'
        , RFiringFailed (FiringFailed t' "provider down" 1 0)
        ]
        `shouldReplayRefuse` "replay divergence: a second terminal activity fact for firing occurrence 1 (t) — the first one wins, the writer appends no second"

  -- TestTerminalActivityReplayDivergence.test_a_terminal_activity_fact_after_the_firing_ended_is_replay_divergence
  it "a terminal activity fact after the firing ended is replay divergence" $
    replayTerminalActivity
      [ RCandidateSelected (CandidateSelected t' 1 0)
      , RFiringBegun (FiringBegun t' 1 Nothing 0)
      , RFiringCompleted (FiringCompleted t' 1 0)
      , captured
      ]
      `shouldReplayRefuse` "replay divergence: a terminal activity fact for firing occurrence 1 (t) after its firing ended — the live writer freezes the activity fact before the terminal boundary"

  -- TestTerminalActivityReplayDivergence.test_an_activity_failure_after_a_frozen_completion_is_replay_divergence
  it "an activity failure after a frozen completion is replay divergence" $
    replayInFlight
      [ RCandidateSelected (CandidateSelected t' 1 0)
      , RFiringBegun (FiringBegun t' 1 Nothing 0)
      , RActivityRequested (ActivityRequested t' "charge_card" Null defaultExecutionPolicy "occurrence-1" "occurrence-1" 1 Nothing 0)
      , captured
      , down
      ]
      `shouldReplayRefuse` "replay divergence: a second terminal activity fact for firing occurrence 1 (t)"

completeProjects :: Spec
completeProjects = describe "complete projects the frozen result" $ do
  -- TestCompleteProjectsTheFrozenResult.test_complete_projects_the_frozen_result_and_commits_the_boundary
  it "complete projects the frozen result and commits the boundary" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    firing <- complete inst o Nothing Nothing >>= expectRight
    -- handler.projected == 1: one projection, one receipt.
    marking inst `shouldReturn` markingFromList [(b', [receipt "captured"])]
    rs <- historyOf inst
    lastN 2 rs
      `shouldBe` [ RTokensProduced (TokensProduced b' [receipt "captured"] 1 [] Nothing 0)
                 , RFiringCompleted (FiringCompleted t' 1 0)
                 ]
    firing.occurrence `shouldBe` o.occurrence
    inFlight inst `shouldReturn` []

  -- TestCompleteProjectsTheFrozenResult.test_complete_without_a_frozen_result_fails_loud
  it "complete without a frozen result fails loud" $ do
    (inst, o) <- begun chargeCard Nothing
    result <- complete inst o Nothing Nothing
    result `refusedWith` "cannot complete firing occurrence 1 (t): no terminal activity fact is recorded — record_activity_completion first"
    inFlight inst `shouldReturn` [o]

  -- TestCompleteProjectsTheFrozenResult.test_complete_on_an_impure_occurrence_takes_no_result_argument
  it "complete on an impure occurrence takes no result argument" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    result <- complete inst o (Just (handlerTokens [(b', [tok "Receipt"])])) Nothing
    result
      `refusedWith` "cannot complete firing occurrence 1 (t): an impure firing projects its frozen activity result — complete() takes no result; record_activity_completion supplies it"

  -- TestCompleteProjectsTheFrozenResult.test_a_pure_complete_requires_its_handlers_result
  it "a pure complete requires its handler's result" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    result <- complete inst o Nothing Nothing
    result `refusedWith` "cannot complete firing occurrence 1 (t): a pure firing completes with its handler's result"

  -- TestCompleteProjectsTheFrozenResult.test_a_projection_bug_is_fixed_in_code_and_retried_from_the_same_frozen_result
  it "a projection bug is fixed in code and retried from the same frozen result" $ do
    -- The live handler cannot be mutated in place; "the fix, redeployed" is
    -- a resume over the same History with the fixed handler.
    store <- inMemoryHistoryStore
    (inst, o) <- begun brokenProjection (Just store)
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    result <- complete inst o Nothing Nothing
    result `raisedWith` "KeyError('statuss')"
    inFlight inst `shouldReturn` [o]
    fixed <- resumeWith chargeCard store
    inFlight fixed `shouldReturn` [o]
    _ <- complete fixed o Nothing Nothing >>= expectRight
    marking fixed `shouldReturn` markingFromList [(b', [receipt "captured"])]
    rs <- historyOf fixed
    activityCompletedRecords rs `shouldBe` [ActivityCompleted t' (obj [("status", String "captured")]) 1 0]

appendBoundaries :: Spec
appendBoundaries = describe "append boundaries" $
  -- test_activity_success_preserves_the_three_distinct_append_boundaries
  it "activity success preserves the three distinct append boundaries" $ do
    (store, batches) <- batchRecordingStore
    let source = np "source"
        effectfulCharge =
          chargeCard
            { project = \b result -> do
                envelope <- chargeCard.project b result
                Right envelope {opens = [DeliveryRegistration source "new"], closes = [DeliveryRegistration source "default"]}
            }
        net =
          netOf
            [place a', place b', place gate]
            [handled t' (Just "charge"), transition source]
            [arc a' t', arcWith gate t' Read 1 Nothing, arc t' b']
    inst <-
      newInstance
        net
        (configFor effectfulCharge)
          { initialMarking = markingFromList [(a', [payment]), (gate, [black])]
          , historyStore = Just store
          }
        >>= expectRight
    o <- beginHead inst Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) (Just 2) >>= expectRight
    _ <- complete inst o Nothing (Just 3) >>= expectRight
    committed <- readIORef batches
    map (map recordName) (lastN 3 committed)
      `shouldBe` [ ["CandidateSelected", "FiringBegun", "TokensConsumed", "TokensRead", "ActivityRequested"]
                 , ["ActivityCompleted"]
                 , ["TokensProduced", "DeliveryRegistrationClosed", "DeliveryRegistrationOpened", "FiringCompleted"]
                 ]

failDoor :: Spec
failDoor = describe "fail: exhausted execution" $ do
  -- TestFail.test_an_impure_failure_commits_activity_failed_and_firing_failed_in_one_batch
  it "an impure failure commits ActivityFailed and FiringFailed" $ do
    (store, batches) <- batchRecordingStore
    (inst, o) <- begun chargeCard (Just store)
    failFiring inst o (FailureText "TimeoutError('provider gone')") (Just 4) >>= expectRight
    rs <- historyOf inst
    lastN 2 rs
      `shouldBe` [ activityFailedRecord "TimeoutError('provider gone')" 1 4
                 , RFiringFailed (FiringFailed t' "TimeoutError('provider gone')" 1 4)
                 ]
    map length . lastN 2 <$> readIORef batches `shouldReturn` [1, 1]
    inFlight inst `shouldReturn` []

  -- TestFail.test_a_pure_failure_stays_firing_failed_alone
  it "a pure failure stays FiringFailed alone" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    failFiring inst o (FailureText "boom") Nothing >>= expectRight
    rs <- historyOf inst
    countWhere isFailedRecord rs `shouldBe` 0
    last rs `shouldSatisfy` isFiringFailed

  -- TestFail.test_a_pure_firing_rejects_activity_failure_freeze
  it "a pure firing rejects activity failure freeze" $ do
    inst <- pureInstance
    o <- beginHead inst Nothing
    result <- recordActivityFailure inst o (simple "boom") Nothing
    result `refusedWith` "cannot record an activity failure for a pure firing — it runs no activity"

  -- TestFail.test_fail_refuses_a_completed_activity
  it "fail refuses a completed activity" $ do
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) Nothing >>= expectRight
    result <- failFiring inst o (FailureText "operator gave up") Nothing
    result
      `refusedWith` "cannot fail firing occurrence 1 (t): its activity already completed — the frozen result stands; fix the projection and retry complete() [DR 2026-07-14 activity-invocation-runtime-seam, Deferred]"
    inFlight inst `shouldReturn` [o]

stepRefuses :: Spec
stepRefuses = describe "the inline drivers refuse what they cannot run" $
  -- TestStepRefusesActivityTransitions.test_step_fails_loud_naming_the_adapter_it_lacks
  it "step fails loud naming the adapter it lacks" $ do
    inst <- seamInstance chargeCard Nothing
    before <- historyOf inst
    result <- step inst Nothing
    result
      `refusedWith` "cannot step firing t: it binds an ActivityHandler, and this inline driver holds no Dispatch — drive it through Engine"
    historyOf inst `shouldReturn` before
    inFlight inst `shouldReturn` []

engineDrives :: Spec
engineDrives = describe "an inline driver drives the whole seam (Engine emulated)" $ do
  let open dispatch h = do
        store <- inMemoryHistoryStore
        inst <- seamInstance h (Just store)
        result <- advanceUntilRest inst dispatch
        rs <- Store.records store
        pure (inst, result, rs)

  -- TestEngineDrivesActivities.test_an_activity_firing_records_the_canonical_lifecycle
  it "an activity firing records the canonical lifecycle" $ do
    (_, result, rs) <- open (answering (obj [("status", String "captured")])) chargeCard
    [firing] <- expectRight result
    map recordName rs
      `shouldBe` [ "InstanceCreated"
                 , "TokensInitialized"
                 , "CandidateSelected"
                 , "FiringBegun"
                 , "TokensConsumed"
                 , "ActivityRequested"
                 , "ActivityCompleted"
                 , "TokensProduced"
                 , "FiringCompleted"
                 ]
    firing.transition `shouldBe` t'

  -- TestEngineDrivesActivities.test_a_typed_decline_is_a_business_result_never_a_firing_failure
  it "a typed decline is a business result, never a firing failure" $ do
    let declinedPlace = np "declined"
        receipts = np "receipts"
        routeCharge =
          chargeCard
            { project = \_ result -> do
                s <- member "status" result
                let captured = s == String "captured"
                    token' = Token (Just (if captured then "Receipt" else "Decline")) (obj [("status", s)])
                Right (handlerTokens [(if captured then receipts else declinedPlace, [token'])])
            }
        net =
          netOf
            [place a', place receipts, place declinedPlace]
            [handled t' (Just "charge")]
            [arc a' t', colored "Receipt" t' receipts, colored "Decline" t' declinedPlace]
    store <- inMemoryHistoryStore
    inst <-
      newInstance net (configFor routeCharge) {initialMarking = markingFromList [(a', [payment])], historyStore = Just store}
        >>= expectRight
    _ <- advanceUntilRest inst (answering (obj [("status", String "declined")])) >>= expectRight
    marking inst `shouldReturn` markingFromList [(declinedPlace, [tokD "Decline" (obj [("status", String "declined")])])]
    rs <- Store.records store
    countWhere isCompletedRecord rs `shouldSatisfy` (> 0)
    countWhere (\r -> isFailedRecord r || isFiringFailed r) rs `shouldBe` 0

  -- TestEngineDrivesActivities.test_an_exhausted_adapter_is_activity_failed_plus_firing_failed_and_no_business_token
  it "an exhausted adapter is ActivityFailed plus FiringFailed and no business token" $ do
    let gone _ = pure (Left (failureOf "provider gone" "TimeoutError" Null True Nothing))
    (_, result, rs) <- open gone chargeCard
    case result of
      Left (RuntimeRefused m) -> m `shouldSatisfy` T.isInfixOf "failed terminally"
      other -> expectationFailure ("expected the driver's terminal-failure refusal, got " <> show (length <$> other))
    lastN 2 rs `shouldSatisfy` \case
      [RActivityFailed _, RFiringFailed _] -> True
      _ -> False
    replayInFlight rs `shouldBe` Right []

  -- TestEngineDrivesActivities.test_a_projection_error_leaves_the_occurrence_projection_pending
  it "a projection error leaves the occurrence projection-pending" $ do
    (_, result, rs) <- open (answering (obj [("status", String "captured")])) brokenProjection
    result `raisedWith` "KeyError('statuss')"
    length <$> replayInFlight rs `shouldBe` Right 1
    countWhere isCompletedRecord rs `shouldSatisfy` (> 0)
    countWhere (\r -> isFailedRecord r || isFiringFailed r) rs `shouldBe` 0

killWindows :: Spec
killWindows = describe "the kill windows, over the durable record" $ do
  -- History ends after the begin batch: ActivityRequested, no terminal fact.
  let crashedAfterBegin = do
        store <- inMemoryHistoryStore
        inst <- seamInstance chargeCard (Just store)
        o <- beginHead inst (Just 2)
        durable <- reloaded store -- the process dies before dispatch acknowledged anything
        pure (durable, o)
      -- History ends after ActivityCompleted.
      crashedAfterFreeze = do
        store <- inMemoryHistoryStore
        inst <- seamInstance chargeCard (Just store)
        o <- beginHead inst (Just 2)
        _ <- recordActivityCompletion inst o (obj [("status", String "captured")]) (Just 3) >>= expectRight
        reloaded store -- the process dies before projection committed

  -- TestKillWindowOne.test_resume_rebuilds_the_occurrence_with_its_invocation_and_never_re_prepares
  it "window one: resume rebuilds the occurrence with its invocation and never re-prepares" $ do
    (durable, o) <- crashedAfterBegin
    resumed <- resumeWith poisonedPrepare durable
    [rebuilt] <- inFlight resumed
    rebuilt `shouldBe` o
    rebuilt.invocation
      `shouldBe` Just
        (ActivityInvocation "charge_card" (obj [("amount", Int 100)]) defaultExecutionPolicy (Just "occurrence-1") (Just "occurrence-1"))

  -- TestKillWindowOne.test_the_rebuilt_invocation_is_redispatchable_to_completion
  it "window one: the rebuilt invocation is redispatchable to completion" $ do
    (durable, _) <- crashedAfterBegin
    -- handler.prepared == 0 is pinned by the poisoned prepare: the record
    -- supplied the invocation.
    resumed <- resumeWith poisonedPrepare {project = chargeCard.project} durable
    [rebuilt] <- inFlight resumed
    Just inv <- pure rebuilt.invocation
    Right result <- answering (obj [("status", String "captured")]) inv
    _ <- recordActivityCompletion resumed rebuilt result (Just 9) >>= expectRight
    _ <- complete resumed rebuilt Nothing (Just 9) >>= expectRight
    marking resumed `shouldReturn` markingFromList [(b', [receipt "captured"])]

  -- TestKillWindowTwo.test_resume_is_projection_pending_and_the_activity_is_never_re_invoked
  it "window two: resume is projection-pending and the activity is never re-invoked" $ do
    durable <- crashedAfterFreeze
    invocations <- newIORef (0 :: Int)
    let counting _ = modifyIORef' invocations (+ 1) >> pure (Right (obj [("status", String "captured")]))
    resumed <- resumeWith poisonedPrepare {project = chargeCard.project} durable
    [rebuilt] <- inFlight resumed
    projectionPending resumed `shouldReturn` [rebuilt]
    -- The driver would consult `counting` only for an occurrence with no
    -- frozen fact; this one is projection only.
    pendingActivityOutcomes resumed >>= (`shouldSatisfy` IntMap.member rebuilt.occurrence)
    firing <- complete resumed rebuilt Nothing (Just 9) >>= expectRight
    _ <- advanceUntilRest resumed counting >>= expectRight
    readIORef invocations `shouldReturn` 0 -- the frozen result was projected; the activity never ran again
    firing.occurrence `shouldBe` 1
    marking resumed `shouldReturn` markingFromList [(b', [receipt "captured"])]

  -- TestKillWindowTwo.test_a_projection_bug_fixed_and_retried_completes_from_the_same_frozen_result
  it "window two: a projection bug fixed and retried completes from the same frozen result" $ do
    durable <- crashedAfterFreeze
    broken <- resumeWith brokenProjection durable
    [rebuilt] <- inFlight broken
    result <- complete broken rebuilt Nothing Nothing
    result `raisedWith` "KeyError('statuss')"
    -- Fix the code, redeploy (a fresh resume over the same durable record),
    -- retry projection alone.
    fixed <- reloaded durable >>= resumeWith chargeCard
    [rebuilt'] <- inFlight fixed
    _ <- complete fixed rebuilt' Nothing (Just 9) >>= expectRight
    marking fixed `shouldReturn` markingFromList [(b', [receipt "captured"])]
    rs <- historyOf fixed
    activityCompletedRecords rs `shouldBe` [ActivityCompleted t' (obj [("status", String "captured")]) 1 3]

terminalFailureProjection :: Spec
terminalFailureProjection = describe "terminal failure projection" $ do
  -- TestTerminalFailureProjection.test_opt_in_failure_projection_routes_one_typed_terminal_token
  it "opt-in failure projection routes one typed terminal token" $ do
    (inst, o) <- begun (failureProjectingCharge False) Nothing
    let failure = failureOf "request rejected" "InvalidRequest" (obj [("field", String "account")]) False Nothing
    _ <- recordActivityFailure inst o failure (Just 2) >>= expectRight
    firing <- complete inst o Nothing (Just 3) >>= expectRight
    -- handler.failures == [failure]: the projected token carries exactly
    -- that failure's kind and details.
    firing.occurrence `shouldBe` 1
    marking inst
      `shouldReturn` markingFromList
        [(b', [tokD "ActivityFailure" (obj [("kind", String "InvalidRequest"), ("details", obj [("field", String "account")])])])]
    rs <- historyOf inst
    countWhere isFailedRecord rs `shouldBe` 1
    countWhere isFiringCompleted rs `shouldBe` 1
    countWhere isFiringFailed rs `shouldBe` 0

  -- TestTerminalFailureProjection.test_equal_failure_redelivery_acknowledges_and_conflicts_are_refused
  it "equal failure redelivery acknowledges and conflicts are refused" $ do
    (inst, o) <- begun (failureProjectingCharge False) Nothing
    let failure = failureOf "down" "Unavailable" (obj [("region", String "west")]) True (Just 3)
    _ <- recordActivityFailure inst o failure Nothing >>= expectRight
    before <- historyOf inst
    recordActivityFailure inst o failure Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf inst `shouldReturn` before
    conflicting <- recordActivityFailure inst o (failureOf "different" "ActivityError" Null False Nothing) Nothing
    conflicting `refusedWith` "conflicting terminal activity report"
    late <- recordActivityCompletion inst o (obj [("status", String "late-success")]) Nothing
    late
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): a terminal activity fact already exists with a failure — a failed occurrence cannot retroactively succeed"

  -- TestTerminalFailureProjection.test_nested_boolean_and_integer_failure_details_are_distinct
  it "nested boolean and integer failure details are distinct" $ do
    (inst, o) <- begun (failureProjectingCharge False) Nothing
    _ <- recordActivityFailure inst o (failureOf "down" "ActivityError" (obj [("nested", Array [Bool True])]) False Nothing) Nothing >>= expectRight
    let integral = failureOf "down" "ActivityError" (obj [("nested", Array [Int 1])]) False Nothing
    conflicting <- recordActivityFailure inst o integral Nothing
    conflicting `refusedWith` "conflicting terminal activity report"
    failed <- failFiring inst o (FailureValue integral) Nothing
    failed
      `refusedWith` "cannot fail firing occurrence 1 (t): its activity already completed — the frozen result stands; fix the projection and retry complete() [DR 2026-07-14 activity-invocation-runtime-seam, Deferred]"

  -- TestTerminalFailureProjection.test_failure_projection_crash_reloads_the_frozen_failure_without_another_attempt
  it "a failure projection crash reloads the frozen failure without another attempt" $ do
    store <- inMemoryHistoryStore
    (inst, o) <- begun (failureProjectingCharge True) (Just store)
    let failure = failureOf "down" "Unavailable" (obj [("checkpoint", Int 2)]) True (Just 5)
    _ <- recordActivityFailure inst o failure (Just 3) >>= expectRight
    crashed <- complete inst o Nothing (Just 4)
    crashed `raisedWith` "RuntimeError('failure projection crashed')"
    resumed <- reloaded store >>= resumeWith (failureProjectingCharge False) {prepare = poisonedPrepare.prepare}
    [rebuilt] <- inFlight resumed
    pendingActivityOutcomes resumed `shouldReturn` IntMap.fromList [(1, TerminalFailure failure)]
    _ <- complete resumed rebuilt Nothing (Just 5) >>= expectRight
    rs <- historyOf resumed
    countWhere isFailedRecord rs `shouldBe` 1
    marking resumed
      `shouldReturn` markingFromList
        [(b', [tokD "ActivityFailure" (obj [("kind", String "Unavailable"), ("details", obj [("checkpoint", Int 2)])])])]

  -- TestTerminalFailureProjection.test_legacy_fail_and_halt_recovers_after_the_failure_freeze
  it "legacy fail-and-halt recovers after the failure freeze" $ do
    store <- inMemoryHistoryStore
    (inst, o) <- begun chargeCard (Just store)
    let failure = failureOf "down" "Unavailable" Null True Nothing
    _ <- recordActivityFailure inst o failure (Just 3) >>= expectRight
    resumed <- reloaded store >>= resumeWith chargeCard
    [rebuilt] <- inFlight resumed
    failFiring resumed rebuilt (FailureValue failure) (Just 4) >>= expectRight
    rs <- historyOf resumed
    countWhere isFailedRecord rs `shouldBe` 1
    countWhere isFiringFailed rs `shouldBe` 1
    inFlight resumed `shouldReturn` []

  -- TestTerminalFailureProjection.test_ended_failure_replay_preserves_classification_for_late_acknowledgement
  it "ended failure replay preserves classification for late acknowledgement" $ do
    store <- inMemoryHistoryStore
    (inst, o) <- begun chargeCard (Just store)
    let failure = failureOf "down" "Unavailable" (obj [("region", String "west")]) True (Just 7)
    _ <- recordActivityFailure inst o failure Nothing >>= expectRight
    failFiring inst o (FailureValue failure) Nothing >>= expectRight
    resumed <- reloaded store >>= resumeWith chargeCard
    before <- historyOf resumed
    recordActivityFailure resumed o failure Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf resumed `shouldReturn` before
    conflicting <- recordActivityFailure resumed o (simple "different") Nothing
    conflicting `refusedWith` "conflicting terminal activity report"

replayGuards :: Spec
replayGuards = describe "activity replay guards" $ do
  -- TestActivityReplayGuards.test_an_activity_request_with_no_begun_boundary_is_replay_divergence
  it "an activity request with no begun boundary is replay divergence" $
    replayInFlight (drop 3 (beginRecords True))
      `shouldReplayRefuse` "replay divergence: activity 'charge_card' requested for firing occurrence 1 with no begun boundary — the request joins the begin batch"

  -- TestActivityReplayGuards.test_a_second_activity_request_for_one_occurrence_is_replay_divergence
  it "a second activity request for one occurrence is replay divergence" $
    replayInFlight (beginRecords True ++ drop 3 (beginRecords True))
      `shouldReplayRefuse` "replay divergence: firing occurrence 1 (t) requested a second activity — one impure handler maps to exactly one activity"

  -- TestActivityReplayGuards.test_an_activity_completion_for_a_pure_occurrence_is_replay_divergence
  it "an activity completion for a pure occurrence is replay divergence" $
    replayInFlight (beginRecords False ++ [RActivityCompleted (ActivityCompleted t' (String "r") 1 2)])
      `shouldReplayRefuse` "replay divergence: activity completed for firing occurrence 1 (t) but no activity was requested in its begin batch"

  -- TestActivityReplayGuards.test_an_activity_failure_for_a_pure_occurrence_is_replay_divergence
  it "an activity failure for a pure occurrence is replay divergence" $
    replayInFlight (beginRecords False ++ [activityFailedRecord "boom" 1 2])
      `shouldReplayRefuse` "replay divergence: activity failed for firing occurrence 1 (t) but no activity was requested in its begin batch"

  -- TestActivityReplayGuards.test_a_second_terminal_activity_fact_is_replay_divergence
  it "a second terminal activity fact is replay divergence" $
    replayInFlight
      ( beginRecords True
          ++ [RActivityCompleted (ActivityCompleted t' (String "r") 1 2), RActivityCompleted (ActivityCompleted t' (String "r") 1 3)]
      )
      `shouldReplayRefuse` "replay divergence: a second terminal activity fact for firing occurrence 1 (t) — the first one wins, the writer appends no second"

  -- TestActivityReplayGuards.test_an_activity_completion_alone_is_not_a_torn_batch
  it "an activity completion alone is not a torn batch" $ do
    let rs = beginRecords True ++ [RActivityCompleted (ActivityCompleted t' (obj [("status", String "ok")]) 1 2)]
    [o] <- expectRight (replayInFlight rs)
    o.invocation `shouldSatisfy` (/= Nothing)
    replayProjectionPending rs `shouldBe` Right (IntMap.fromList [(1, TerminalResult (obj [("status", String "ok")]))])

  -- TestActivityReplayGuards.test_an_activity_failure_without_its_firing_boundary_is_projection_pending
  it "an activity failure without its firing boundary is projection-pending" $
    replayProjectionPending (beginRecords True ++ [activityFailedRecord "boom" 1 2])
      `shouldBe` Right (IntMap.fromList [(1, TerminalFailure (simple "boom"))])

  -- TestActivityReplayGuards.test_resume_rejects_an_activity_request_on_a_purely_bound_transition
  it "resume rejects an activity request on a purely bound transition" $ do
    construction <- activityConstructionRecords
    store <- storeOf (construction ++ beginRecords True)
    result <-
      resume
        (activityNet (Just "charge"))
        store
        defaultInstanceConfig {handlerImplementations = handlersOf [("charge", PureHandler (\_ _ -> Right (handlerTokens [])))]}
    result
      `refusedWith` "cannot resume firing occurrence 1 (t): its begin batch froze an activity request, but the transition is not bound to an ActivityHandler — projection needs the handler that prepared it"

  -- TestActivityReplayGuards.test_resume_rejects_an_activity_bound_occurrence_with_no_recorded_request
  it "resume rejects an activity-bound occurrence with no recorded request" $ do
    construction <- activityConstructionRecords
    store <- storeOf (construction ++ beginRecords False)
    result <- resume (activityNet (Just "charge")) store (configFor chargeCard)
    result
      `refusedWith` "cannot resume firing occurrence 1 (t): the transition binds an ActivityHandler, but the begin batch froze no ActivityRequested — the live writer always freezes the request at begin"

canonicalPayloads :: Spec
canonicalPayloads = describe "canonical payload snapshots at the writer" $ do
  -- TestCanonicalPayloadSnapshot.test_a_tuple_result_freezes_canonical_and_its_re_record_acknowledges
  it "a sequence result freezes canonical and its re-record acknowledges" $ do
    -- The reference's tuple spelling has no Json counterpart: the list form
    -- is the only spelling, and the re-record acknowledges against it.
    (inst, o) <- begun chargeCard Nothing
    _ <- recordActivityCompletion inst o (obj [("codes", Array [Int 1, Int 2])]) Nothing >>= expectRight
    before <- historyOf inst
    recordActivityCompletion inst o (obj [("codes", Array [Int 1, Int 2])]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    rs <- historyOf inst
    rs `shouldBe` before
    last rs `shouldBe` RActivityCompleted (ActivityCompleted t' (obj [("codes", Array [Int 1, Int 2])]) 1 0)

  -- TestCanonicalPayloadSnapshot.test_a_net_object_as_input_fails_loud_at_begin_appending_nothing
  it "a non-JSON-faithful input fails loud at begin, appending nothing" $ do
    -- A Token cannot be a Json value; the door's reachable refusal is a
    -- non-finite number, with the same message prefix.
    let leakyPrepare = chargeCard {prepare = \_ -> Right (invocation "charge_card" (obj [("amount", Float (0 / 0))]))}
    inst <- seamInstance leakyPrepare Nothing
    before <- historyOf inst
    [b] <- candidates inst
    result <- begin inst b Nothing
    result
      `refusedWith` "cannot begin firing t: invalid activity input: the payload must be JSON-faithful — objects, arrays, strings, numbers, booleans, null — and never net state; Out of range float values are not JSON compliant: nan"
    historyOf inst `shouldReturn` before
    inFlight inst `shouldReturn` []

  -- TestCanonicalPayloadSnapshot.test_a_net_object_as_result_fails_loud_at_the_record_appending_nothing
  it "a non-JSON-faithful result fails loud at the record, appending nothing" $ do
    (inst, o) <- begun chargeCard Nothing
    before <- historyOf inst
    result <- recordActivityCompletion inst o (obj [("x", Float (1 / 0))]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): invalid activity result: the payload must be JSON-faithful — objects, arrays, strings, numbers, booleans, null — and never net state; Out of range float values are not JSON compliant: inf"
    historyOf inst `shouldReturn` before
    nothingFroze <- complete inst o Nothing Nothing
    nothingFroze `refusedWith` "cannot complete firing occurrence 1 (t): no terminal activity fact is recorded — record_activity_completion first"

k6AcrossResume :: Spec
k6AcrossResume = describe "K6 across resume" $ do
  let resumedAfterFreeze result = do
        store <- inMemoryHistoryStore
        inst <- seamInstance chargeCard (Just store)
        o <- beginHead inst (Just 2)
        _ <- recordActivityCompletion inst o result (Just 3) >>= expectRight
        reloaded store >>= resumeWith chargeCard -- crash after the freeze

  -- TestK6AcrossResume.test_a_resumed_writer_acknowledges_an_identical_re_record_without_appending
  it "a resumed writer acknowledges an identical re-record without appending" $ do
    resumed <- resumedAfterFreeze (obj [("status", String "captured")])
    [rebuilt] <- inFlight resumed
    before <- historyOf resumed
    recordActivityCompletion resumed rebuilt (obj [("status", String "captured")]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf resumed `shouldReturn` before
    _ <- complete resumed rebuilt Nothing Nothing >>= expectRight
    marking resumed `shouldReturn` markingFromList [(b', [receipt "captured"])]

  -- TestK6AcrossResume.test_a_tuple_form_redelivery_acknowledges_against_the_decoded_frozen_result
  it "a sequence redelivery acknowledges against the decoded frozen result" $ do
    resumed <- resumedAfterFreeze (obj [("codes", Array [Int 1, Int 2])])
    [rebuilt] <- inFlight resumed
    before <- historyOf resumed
    recordActivityCompletion resumed rebuilt (obj [("codes", Array [Int 1, Int 2])]) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    historyOf resumed `shouldReturn` before

  -- TestK6AcrossResume.test_a_different_late_result_still_conflicts_across_the_resume
  it "a different late result still conflicts across the resume" $ do
    resumed <- resumedAfterFreeze (obj [("status", String "captured")])
    [rebuilt] <- inFlight resumed
    result <- recordActivityCompletion resumed rebuilt (obj [("status", String "declined")]) Nothing
    result
      `refusedWith` "cannot record an activity completion for firing occurrence 1 (t): a terminal activity fact already exists with a different result — an operational conflict, not a redelivery"

beginBatchOrder :: Spec
beginBatchOrder = describe "begin batch order parity" $ do
  let disordered = "replay divergence: firing occurrence 1 (t) carries a disordered begin batch — the live writer accounts consumes, then reads, then freezes at most one activity request"
  -- TestBeginBatchOrderParity.test_a_read_before_a_consume_is_replay_divergence
  it "a read before a consume is replay divergence" $
    replayInFlight
      [ RCandidateSelected (CandidateSelected t' 1 1)
      , RFiringBegun (FiringBegun t' 1 Nothing 1)
      , RTokensRead (TokensRead gate [tok "Config"] 1 [] Nothing 1)
      , RTokensConsumed (TokensConsumed a' [payment] 1 [] Nothing 1)
      ]
      `shouldReplayRefuse` disordered

  -- TestBeginBatchOrderParity.test_an_activity_request_before_a_read_is_replay_divergence
  it "an activity request before a read is replay divergence" $
    replayInFlight
      [ RCandidateSelected (CandidateSelected t' 1 1)
      , RFiringBegun (FiringBegun t' 1 Nothing 1)
      , RTokensConsumed (TokensConsumed a' [payment] 1 [] Nothing 1)
      , requestRecord
      , RTokensRead (TokensRead gate [tok "Config"] 1 [] Nothing 1)
      ]
      `shouldReplayRefuse` disordered
