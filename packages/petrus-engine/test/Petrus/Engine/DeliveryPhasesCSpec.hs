-- | Port of upstream @tests/petrus/engine/test_execution.py@
-- @TestIdentifiedDeliveryPhases@, source lines 2770-3580: delivery-content
-- isolation, carrier validation, projection-failure text, and fresh-Engine
-- reconstruction of accepted deliveries.
--
-- Tests whose subject is a Python object protocol the Haskell types rule
-- out (str/int/registration subclasses, @__deepcopy__@, @object()@
-- identity, a non-'AcceptedDelivery' carrier, a mutable token color) are
-- kept as examples that state the construction-time guarantee and check the
-- remaining observable behavior.
module Petrus.Engine.DeliveryPhasesCSpec (spec) where

import Control.Exception (SomeException, bracket, displayException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore, inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
  ( AcceptedDelivery (..)
  , DeliveryAnswer (..)
  , FiringOccurrence (..)
  , FiringOutcome (..)
  , PriorAcknowledgement (..)
  , acceptedDelivery
  , deliveryIdentityText
  , firingOccurrenceIdInt
  , instanceIdentityText
  )
import Petrus.Impetus.Petrinet hiding (route, token)
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec hiding (after, before)

-- ---------------------------------------------------------------------------
-- Fixtures

a, b, t, src :: NetPath
a = np "a"
b = np "b"
t = np "t"
src = np "src"

-- | @_line_net(handler)@.
lineNet :: Maybe Text -> Net
lineNet handler = netOf [place a, place b] [Transition t (HandlerSymbol <$> handler) [] []] [arc a t, arc t b]

-- | @_ingress_net()@.
ingressNet :: Net
ingressNet = netOf [place a, place b] [transition src, transition t] [arc src a, arc a t, arc t b]

-- | A net whose only transition is the source @src@ (handler optional).
sourceNet :: Maybe Text -> Net
sourceNet handler = netOf [place a] [Transition src (HandlerSymbol <$> handler) [] []] [arc src a]

-- | @Engine.create(net, identity, history=..., dispatch=InMemoryDispatch(), ...)@.
createWith :: Net -> Text -> HistoryStore -> Engine.EngineOptions -> IO Engine.Engine
createWith net identity history options = do
  pool <- newInMemoryDispatch
  Engine.create net identity history (inMemoryDispatch pool) options

-- | @Engine.load(...)@ over an InMemoryDispatch.
loadWith :: Net -> Text -> HistoryStore -> Engine.EngineOptions -> IO Engine.Engine
loadWith net identity history options = do
  pool <- newInMemoryDispatch
  Engine.load net identity history (inMemoryDispatch pool) options

plain :: Engine.EngineOptions
plain = Engine.defaultEngineOptions

withHandlers :: [(Text, BoundHandler)] -> Engine.EngineOptions
withHandlers hs = plain {Engine.handlers = symbols hs}

-- | Accept and expect a fresh acceptance.
accept :: HasCallStack => Engine.Engine -> NetPath -> [Token] -> Text -> IO AcceptedDelivery
accept engine source tokens identity =
  Engine.acceptDelivery engine source tokens identity Nothing >>= \case
    DeliveryAccepted accepted -> pure accepted
    other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other) >> error "unreachable"

-- | @lambda binding, outputs: {A: binding.tokens}@.
passThrough :: BoundHandler
passThrough = PureHandler (\binding _ -> Right (handlerTokens [(a, bindingTokens binding)]))

-- | @AcceptedDelivery(...)@ for a carrier the field constructors admit.
carrier :: HasCallStack => Text -> NetPath -> Text -> Int -> AcceptedDelivery
carrier owner source identity occurrence =
  either (error . T.unpack) id (acceptedDelivery owner source identity occurrence)

-- | @pytest.raises(ValueError, match="f1.*f2...")@: every fragment, in order.
valueErrorMatching :: [Text] -> Selector Engine.EngineError
valueErrorMatching fragments = \case
  Engine.EngineValueError m -> inOrder fragments m
  _ -> False
  where
    inOrder [] _ = True
    inOrder (f : fs) m = case T.breakOn f m of
      (_, rest) | T.null rest -> False
      (_, rest) -> inOrder fs (T.drop (T.length f) rest)

-- | A fresh scratch directory (the reference's @tmp_path@), removed after.
withScratch :: (FilePath -> IO r) -> IO r
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-engine-phases-c"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- | The pinned reference's interpreter and root, provisioned by
-- @scripts/upstream-python@ on first use; fails loudly, never skips, when the
-- reference cannot be provisioned.
withReference :: ((FilePath, FilePath) -> IO ()) -> IO ()
withReference body = do
  python <- pythonExecutable
  root <- upstreamPetrus
  body (python, root)

isDelivered :: Record -> Bool
isDelivered = \case RExternalEventDelivered _ -> True; _ -> False

deliveredRecords :: [Record] -> [ExternalEventDelivered]
deliveredRecords rs = [d | RExternalEventDelivered d <- rs]

event :: Integer -> Json
event n = Object [("event", Int n)]

-- ---------------------------------------------------------------------------
-- Spec

spec :: Spec
spec = describe "TestIdentifiedDeliveryPhases" $ do
  it "resumed source projection cannot mutate the accepted delivery fact" $ withScratch $ \dir -> do
    -- Token data is immutable here: the reference's in-place mutation of the
    -- binding's token becomes a projection that produces the changed value.
    let path = dir </> "resumed-handler-isolated-delivery.jsonl"
        mutate = PureHandler $ \binding _ ->
          Right (handlerTokens [(a, [tok {payload = event 8} | tok <- bindingTokens binding])])
        net = netOf [place a, place b] [Transition src (Just (HandlerSymbol "mutate")) [] [], transition t] [arc src a, arc a t, arc t b]
        token = tokD "X" (event 7)
    created <- openJsonlHistoryStore path >>= \s -> createWith net "resumed-handler-isolated-delivery" s (withHandlers [("mutate", mutate)])
    accepted <- accept created src [token] "event-7"
    Engine.close created
    loaded <- openJsonlHistoryStore path >>= \s -> loadWith net "resumed-handler-isolated-delivery" s (withHandlers [("mutate", mutate)])

    completed <- Engine.completeDelivery loaded accepted

    (recorded : _) <- deliveredRecords <$> Engine.records loaded
    (durable : _) <- deliveredRecords <$> (openJsonlHistoryStore path >>= Store.records)
    recorded.tokens `shouldBe` [token]
    durable.tokens `shouldBe` [token]
    completed.produced `shouldBe` [(a, tokD "X" (event 8))]
    Engine.acceptDelivery loaded src [token] "event-7" Nothing `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)

  it "public observations and completion outcome do not alias accepted content" $ do
    -- Observations are immutable values: no caller can write through them.
    history <- inMemoryHistoryStore
    let token = tokD "X" (event 7)
    engine <- createWith ingressNet "detached-delivery-content" history plain
    accepted <- accept engine src [token] "event-7"
    (recorded : _) <- deliveredRecords <$> Engine.records engine
    recorded.tokens `shouldBe` [token]

    completed <- Engine.completeDelivery engine accepted

    completed.produced `shouldBe` [(a, tokD "X" (event 7))]
    completedRecords <- Engine.records engine
    Engine.acceptDelivery engine src [token] "event-7" Nothing `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
    Engine.records engine `shouldReturn` completedRecords
    Engine.marking engine `shouldReturn` markingFromList [(a, [tokD "X" (event 7)])]

  it "completion detaches its outcome before the terminal batch commits" $ do
    -- N/A by construction for the @__deepcopy__@ hook (values are immutable;
    -- there is no detachment step to order); the committed outcome is checked.
    history <- inMemoryHistoryStore
    let project = PureHandler (\_ _ -> Right (handlerTokens [(a, [tokD "X" (Array [Int 1])])]))
    engine <- createWith (sourceNet (Just "project")) "detach-before-completion-commit" history (withHandlers [("project", project)])
    accepted <- accept engine src [tokD "X" Null] "event-7"

    completed <- Engine.completeDelivery engine accepted

    completed.produced `shouldBe` [(a, tokD "X" (Array [Int 1]))]
    recorded <- Store.records history
    [p.tokens | RTokensProduced p <- recorded] `shouldBe` [[tokD "X" (Array [Int 1])]]
    case reverse recorded of
      RFiringCompleted _ : _ -> pure ()
      other -> expectationFailure ("expected FiringCompleted last, got " <> show (take 1 other))

  it "acceptance refuses mutable token color before history mutation" $ do
    -- N/A by construction: a token color is 'Maybe Text', so a list color
    -- cannot be spelled. The acceptance of a valid color leaves the earlier
    -- History intact up to its own records.
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "invalid-delivery-color" history plain
    before <- Store.records history
    _ <- accept engine src [tokD "X" (event 7)] "event-7"
    after <- Store.records history
    take (length before) after `shouldBe` before

  it "completion validates handler output before copy protocols can normalize it" $ do
    -- N/A by construction: a color is exact 'Text' (no str subclass with a
    -- normalizing copy protocol); a well-formed projected color commits.
    history <- inMemoryHistoryStore
    let project = PureHandler (\_ _ -> Right (handlerTokens [(a, [tokD "X" (Object [("projected", Bool True)])])]))
    engine <- createWith (sourceNet (Just "project")) "hostile-projected-token-color" history (withHandlers [("project", project)])
    accepted <- accept engine src [tokD "Input" Null] "event-7"
    completed <- Engine.completeDelivery engine accepted
    completed.produced `shouldBe` [(a, tokD "X" (Object [("projected", Bool True)]))]

  it "engine creation refuses an empty identity before history mutation" $ do
    history <- inMemoryHistoryStore
    createWith ingressNet "" history plain `shouldThrow` valueError "Instance identity must be a non-empty string"
    Store.records history `shouldReturn` []

  it "engine load refuses an empty recorded identity without history mutation" $ withScratch $ \dir -> do
    let path = dir </> "empty-recorded-identity.jsonl"
    created <- openJsonlHistoryStore path >>= \s -> createWith ingressNet "recorded-identity" s plain
    Engine.close created
    content <- BS.readFile path
    let (first, rest) = BC.break (== '\n') content
        (prefix, suffix) = BS.breakSubstring "\"instance\": \"recorded-identity\"" first
    BS.isInfixOf "\"record\": \"InstanceCreated\"" first `shouldBe` True
    BS.null suffix `shouldBe` False
    let malformed = prefix <> "\"instance\": \"\"" <> BS.drop (BS.length "\"instance\": \"recorded-identity\"") suffix <> rest
    BS.writeFile path malformed

    -- The reference opens the store inside the raises block too: the refusal
    -- may come from the store's decode or from the Engine's load.
    outcome <- try (openJsonlHistoryStore path >>= \s -> loadWith ingressNet "" s plain)
    case outcome of
      Left (e :: SomeException) -> T.pack (displayException e) `shouldSatisfy` T.isInfixOf "Instance identity must be a non-empty string"
      Right _ -> expectationFailure "expected the load to refuse"
    BS.readFile path `shouldReturn` malformed

  it "json lossy delivery content reconstructs after durable reload" $ withScratch $ \dir -> do
    -- A tuple payload is not spellable; the JSON array is the canonical form.
    let path = dir </> "canonical-delivery.jsonl"
        token = tokD "X" (Array [Int 1, Int 2])
    created <- openJsonlHistoryStore path >>= \s -> createWith ingressNet "canonical-delivery-content" s plain
    accepted <- accept created src [token] "event-7"
    Engine.close created

    loaded <- openJsonlHistoryStore path >>= \s -> loadWith ingressNet "canonical-delivery-content" s plain
    reconstructed <- accept loaded src [token] "event-7"
    _ <- Engine.completeDelivery loaded reconstructed

    reconstructed `shouldBe` accepted
    Engine.marking loaded `shouldReturn` markingFromList [(a, [tokD "X" (Array [Int 1, Int 2])])]

  it "completion refuses an ended delivery before mutation" $ do
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "ended-delivery" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    _ <- Engine.completeDelivery engine accepted
    completedRecords <- Store.records history

    Engine.completeDelivery engine accepted
      `shouldThrow` valueErrorMatching ["accepted delivery 'event-7'", "occurrence 1 already ended"]

    Store.records history `shouldReturn` completedRecords

  -- test_completion_refuses_a_non_acceptance_carrier_before_mutation: not ported.
  -- N/A by construction: 'Engine.completeDelivery' takes an
  -- 'AcceptedDelivery'; any other carrier does not type-check.

  describe "projection exception text is nonempty bounded and the original propagates" $
    sequence_
      [ it (route <> "-" <> label) $ projectionFailure route recorded
      | route <- ["direct", "composed", "sensed"]
      , (label, recorded) <-
          [ ("no-arguments", "ProjectionError()")
          , ("long-argument", T.take 4096 ("ProjectionError('" <> T.replicate 5000 "x" <> "')"))
          ]
      ]

  -- test_projection_failure_replaces_object_identity_with_a_stable_type_marker: not ported.
  -- N/A by construction: a Haskell handler failure carries text, never an
  -- object whose identity could leak into the recorded failure.

  -- test_projection_refuses_a_registration_key_subclass_without_corrupting_durable_authority: not ported.
  -- N/A by construction: a registration key is exact 'Text' (no str
  -- subclass can impersonate @"default"@).

  -- test_projection_refuses_a_registration_subclass_before_reading_its_fields: not ported.
  -- N/A by construction: 'DeliveryRegistration' is a closed record type.

  it "completion refuses a foreign acceptance before mutation" $ do
    let token = tokD "X" (Int 7)
    leftHistory <- inMemoryHistoryStore
    left <- createWith ingressNet "left-delivery" leftHistory plain
    accepted <- accept left src [token] "event-7"
    rightHistory <- inMemoryHistoryStore
    right <- createWith ingressNet "right-delivery" rightHistory plain
    rightRecords <- Store.records rightHistory

    Engine.completeDelivery right accepted
      `shouldThrow` valueErrorMatching ["delivery for Instance 'left-delivery'", "Instance 'right-delivery'"]

    Store.records rightHistory `shouldReturn` rightRecords

  it "completion refuses a mismatched acceptance before mutation" $ do
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "mismatched-delivery" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    acceptedRecords <- Store.records history
    let mismatched = carrier (instanceIdentityText accepted.instanceId) accepted.source "other-event" (firingOccurrenceIdInt accepted.occurrence)

    Engine.completeDelivery engine mismatched `shouldThrow` valueError "acceptance does not match firing occurrence 1"

    Store.records history `shouldReturn` acceptedRecords

  it "completion refuses the wrong source occurrence before mutation" $ do
    let otherSource = np "other_source"
        otherOutput = np "other_output"
        net = netOf [place a, place otherOutput] [transition src, transition otherSource] [arc src a, arc otherSource otherOutput]
    history <- inMemoryHistoryStore
    engine <- createWith net "wrong-source-occurrence" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    other <- accept engine otherSource [tokD "Y" (Int 8)] "event-8"
    acceptedRecords <- Store.records history
    let wrong = carrier (instanceIdentityText accepted.instanceId) accepted.source (deliveryIdentityText accepted.identity) (firingOccurrenceIdInt other.occurrence)

    Engine.completeDelivery engine wrong `shouldThrow` valueError "acceptance does not match firing occurrence 2"

    Store.records history `shouldReturn` acceptedRecords

  it "completion refuses a mutated occurrence alias before it can redirect" $ do
    -- N/A by construction for the int subclass (the occurrence is an exact
    -- 'Int' and the carrier is immutable); both acceptances stay in flight.
    history <- inMemoryHistoryStore
    _ <- createWith (sourceNet Nothing) "mutated-acceptance-carrier" history plain >>= \engine -> do
      _ <- accept engine src [tokD "X" (Bool True)] "event-1"
      accept engine src [tokD "X" (Int 1)] "event-2"
    resumed <- loadWith (sourceNet Nothing) "mutated-acceptance-carrier" history plain
    map (.occurrence) <$> Engine.inFlight resumed `shouldReturn` [1, 2]

  -- test_completion_refuses_an_acceptance_subclass_before_it_can_redirect_the_occurrence: not ported.
  -- N/A by construction: 'AcceptedDelivery' is a closed record type with no
  -- overridable field access.

  -- test_acceptance_carrier_refuses_a_boolean_occurrence_before_completion: not ported.
  -- N/A by construction: the occurrence is an 'Int'; a boolean does not
  -- type-check.

  it "acceptance carrier refuses a non string identity before completion" $ do
    -- The list identity is unspellable ('Text'); the empty identity is the
    -- value-level refusal the same constructor rule makes.
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "malformed-identity" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    acceptedRecords <- Store.records history
    case acceptedDelivery (instanceIdentityText accepted.instanceId) accepted.source "" (firingOccurrenceIdInt accepted.occurrence) of
      Left message -> message `shouldSatisfy` T.isInfixOf "identity must be a non-empty string"
      Right malformed -> expectationFailure ("expected a refusal, got " <> show malformed)
    Store.records history `shouldReturn` acceptedRecords

  it "acceptance carrier refuses an instance identity subclass at construction" $ do
    -- A truthy-empty str subclass is unspellable; the empty instance identity
    -- is refused at construction all the same.
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "strict-instance-carrier" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    acceptedRecords <- Store.records history
    case acceptedDelivery "" accepted.source (deliveryIdentityText accepted.identity) (firingOccurrenceIdInt accepted.occurrence) of
      Left message -> message `shouldSatisfy` T.isInfixOf "Instance identity must be a non-empty string"
      Right malformed -> expectationFailure ("expected a refusal, got " <> show malformed)
    Store.records history `shouldReturn` acceptedRecords

  it "acceptance carrier refuses an occurrence subclass at construction" $ do
    -- An int subclass with a lying @__lt__@ is unspellable; the -1 it carries
    -- is refused at construction.
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "strict-occurrence-carrier" history plain
    accepted <- accept engine src [tokD "X" (Int 7)] "event-7"
    acceptedRecords <- Store.records history
    case acceptedDelivery (instanceIdentityText accepted.instanceId) accepted.source (deliveryIdentityText accepted.identity) (-1) of
      Left message -> message `shouldSatisfy` T.isInfixOf "firing occurrence must be a positive integer"
      Right malformed -> expectationFailure ("expected a refusal, got " <> show malformed)
    Store.records history `shouldReturn` acceptedRecords

  it "completion refuses an impure non source occurrence before mutation" $ do
    let work =
          ActivityBound
            ActivityHandler
              { prepare = \binding -> case bindingTokens binding of
                  first : _ -> invocation "work" (Object [("value", first.payload)])
                  [] -> Left "IndexError('tuple index out of range')"
              , project = \_ result -> Right (handlerTokens [(b, [tokD "Worked" result])])
              , projectFailure = Nothing
              }
    history <- inMemoryHistoryStore
    engine <-
      createWith (lineNet (Just "work")) "wrong-occurrence" history
        (withHandlers [("work", work)]) {Engine.marking = markingFromList [(a, [tokD "Work" (Int 3)])]}
    _ <- Engine.advance engine
    begunRecords <- Store.records history
    let wrong = carrier "wrong-occurrence" t "event-7" 1

    Engine.completeDelivery engine wrong `shouldThrow` valueError "occurrence 1 belongs to an impure non-source transition t"

    Store.records history `shouldReturn` begunRecords

  it "fresh engine reconstructs and completes the exact accepted occurrence" $ withScratch $ \dir -> do
    let path = dir </> "reconstructed.jsonl"
        token = tokD "X" (event 7)
    created <- openJsonlHistoryStore path >>= \s -> createWith ingressNet "reconstructed-delivery" s plain
    accepted <- accept created src [token] "event-7"
    Engine.close created

    loaded <- openJsonlHistoryStore path >>= \s -> loadWith ingressNet "reconstructed-delivery" s plain
    reconstructed <- accept loaded src [token] "event-7"
    completed <- Engine.completeDelivery loaded reconstructed

    reconstructed `shouldBe` accepted
    (completed.transition, completed.occurrence) `shouldBe` (src, 1)
    Engine.marking loaded `shouldReturn` markingFromList [(a, [token])]
    recorded <- Engine.records loaded
    [c.occurrence | RFiringCompleted c <- recorded] `shouldBe` [1]

  it "fresh engine completes a persisted acceptance without redelivery" $ withScratch $ \dir -> do
    let path = dir </> "persisted-acceptance.jsonl"
        token = tokD "X" (event 7)
    created <- openJsonlHistoryStore path >>= \s -> createWith ingressNet "persisted-acceptance" s plain
    accepted <- accept created src [token] "event-7"
    Engine.close created

    loaded <- openJsonlHistoryStore path >>= \s -> loadWith ingressNet "persisted-acceptance" s plain
    acceptedRecords <- Engine.records loaded

    completed <- Engine.completeDelivery loaded accepted

    (completed.transition, completed.occurrence) `shouldBe` (src, 1)
    recorded <- Engine.records loaded
    case drop (length acceptedRecords) recorded of
      [RTokensProduced produced, RFiringCompleted finished] -> do
        (produced.place, produced.tokens, produced.occurrence, produced.instant) `shouldBe` (a, [token], 1, 0)
        finished `shouldBe` FiringCompleted src 1 0
      other -> expectationFailure ("expected TokensProduced then FiringCompleted, got " <> show other)
    length (filter isDelivered recorded) `shouldBe` 1
    Engine.inFlight loaded `shouldReturn` []

  it "process interruption after acceptance resumes only that occurrence" $ withReference $ \(python, root) -> withScratch $ \dir -> do
    -- Cross-process: the reference process accepts and dies with os._exit;
    -- this Engine resumes its JSONL History.
    let path = dir </> "interrupted.jsonl"
        program =
          unlines
            [ "import os"
            , "import sys"
            , ""
            , "from petrus.engine import Engine"
            , "from petrus.motus.dispatch import InMemoryDispatch"
            , "from petrus.impetus.history_store import JsonlHistoryStore"
            , "from petrus.impetus.petrinet import Arc, Net, NetPath, Place, Token, Transition"
            , ""
            , "source = NetPath(\"src\")"
            , "output = NetPath(\"a\")"
            , "net = Net(places=[Place(output)], transitions=[Transition(source)], arcs=[Arc(source, output)])"
            , "engine = Engine.create(net, \"interrupted-delivery\", history=JsonlHistoryStore(sys.argv[1]), dispatch=InMemoryDispatch())"
            , "engine.accept_delivery(source, Token(\"X\", {\"event\": 7}), identity=\"event-7\")"
            , "os._exit(23)"
            ]
    (code, _, err) <- readCreateProcessWithExitCode (proc python ["-c", program, path]) {cwd = Just root} ""
    (code, err) `shouldBe` (ExitFailure 23, "")
    let token = tokD "X" (event 7)
    loaded <- openJsonlHistoryStore path >>= \s -> loadWith (sourceNet Nothing) "interrupted-delivery" s plain
    reconstructed <- accept loaded src [token] "event-7"

    completed <- Engine.completeDelivery loaded reconstructed

    (completed.transition, completed.occurrence) `shouldBe` (src, 1)
    Engine.marking loaded `shouldReturn` markingFromList [(a, [token])]
    recorded <- Engine.records loaded
    length (filter isDelivered recorded) `shouldBe` 1
    length [() | RFiringCompleted _ <- recorded] `shouldBe` 1

  it "exact redelivery has finite record and in flight cost" $ do
    history <- inMemoryHistoryStore
    engine <- createWith ingressNet "bounded-redelivery" history plain
    let token = tokD "X" (event 7)
    baseline <- length <$> Engine.records engine
    accepted <- accept engine src [token] "event-7"

    mapM_ (\_ -> Engine.acceptDelivery engine src [token] "event-7" Nothing `shouldReturn` DeliveryAccepted accepted) [1 .. 64 :: Int]

    length <$> Engine.records engine `shouldReturn` baseline + 2
    length <$> Engine.inFlight engine `shouldReturn` 1

    _ <- Engine.completeDelivery engine accepted

    length <$> Engine.records engine `shouldReturn` baseline + 4
    Engine.inFlight engine `shouldReturn` []

-- | One case of the parametrized projection-failure test. A Haskell
-- projection fails with its failure text (the kernel records it verbatim,
-- bounded); the Engine propagates that text as 'Engine.EngineHandlerFailed'
-- rather than an exception object.
projectionFailure :: String -> Text -> IO ()
projectionFailure route recorded = do
  history <- inMemoryHistoryStore
  let token = tokD "X" (event 7)
      failing = failureFor recorded
      explode = PureHandler (\_ _ -> Left failing)
      net = sourceNet (Just "project")
      identity = T.pack route <> "-bounded-projection-failure"
  sensor <-
    if route == "sensed"
      then Just <$> scripted [[mkDelivery src [token] "event-7"]]
      else pure Nothing
  engine <- createWith net identity history (withHandlers [("project", explode)]) {Engine.sensor = sensor}
  let run = case route of
        "direct" -> accept engine src [token] "event-7" >>= \accepted -> () <$ Engine.completeDelivery engine accepted
        "composed" -> () <$ Engine.deliver engine src [token] "event-7" Nothing
        _ -> () <$ Engine.advance engine

  outcome <- try run
  case outcome of
    Left (Engine.EngineHandlerFailed text) -> T.take 4096 text `shouldBe` recorded
    Left other -> expectationFailure ("expected the projection failure, got " <> show other)
    Right () -> expectationFailure "expected the projection failure to propagate"
  recordedHistory <- Store.records history
  case reverse recordedHistory of
    RFiringFailed failed : _ -> failed `shouldBe` FiringFailed src recorded 1 0
    other -> expectationFailure ("expected FiringFailed last, got " <> show (take 1 other))
  resumed <- loadWith net identity history (withHandlers [("project", passThrough)])
  Engine.acceptDelivery resumed src [token] "event-7" Nothing `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)

-- | The handler's raised text: the reference's @ProjectionError(*args)@ —
-- unbounded; the kernel bounds what it records.
failureFor :: Text -> Text
failureFor recorded
  | recorded == "ProjectionError()" = recorded
  | otherwise = "ProjectionError('" <> T.replicate 5000 "x" <> "')"

