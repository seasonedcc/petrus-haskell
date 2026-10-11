-- | Port of upstream @tests/petrus/engine/test_execution.py@
-- @TestIdentifiedDeliveryPhases@, the tests at source lines 392-1485: an
-- identified source delivery has separate durable acceptance and
-- completion phases, and load refuses every History that tears or forges
-- them.
--
-- The reference edits JSONL files with @json.loads@ / @json.dumps@; here
-- the same edits go through @petrus-json@ ('dumps' 'defaultDumps' is
-- @json.dumps@'s default spelling). Refusals the reference raises as
-- @ValueError@ arrive either as the Engine's 'Engine.EngineValueError' or,
-- when the JSONL file itself refuses to decode a record, as the store's
-- 'HistoryStoreError' (the reference's @JsonlHistoryStore@ raises
-- @ValueError@ there too).
module Petrus.Engine.DeliveryPhasesASpec (spec) where

import Control.Exception (Exception (..), SomeException, bracket, fromException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (defaultExecutionPolicy, invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport (symbols)
import Petrus.HistoryStore.Jsonl (HistoryStoreError (..), openJsonlHistoryStore)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (AcceptedDelivery (..), DeliveryAnswer (..), DeliveryScope (..), FiringOutcome (..), deliveryIdentityText, firingOccurrenceIdInt)
import Petrus.Impetus.Petrinet hiding (token)
import Petrus.Impetus.Scope (lifecycleScope)
import Petrus.Impetus.TestSupport (netOf, np, tok, tokD)
import Petrus.Json (Json (..), defaultDumps, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec hiding (after, before)

-- ---------------------------------------------------------------------------
-- Fixtures (the reference module's top-level helpers)

a, b, c, t, src :: NetPath
a = np "a"
b = np "b"
c = np "c"
t = np "t"
src = np "src"

-- | @_line_net()@.
lineNet :: Net
lineNet = netOf [place a, place b] [transition t] [arc a t, arc t b]

-- | @_ingress_net()@.
ingressNet :: Net
ingressNet = netOf [place a, place b] [transition src, transition t] [arc src a, arc a t, arc t b]

-- | @InMemoryDispatch()@.
memory :: IO Dispatch
memory = inMemoryDispatch <$> newInMemoryDispatch

options :: Engine.EngineOptions
options = Engine.defaultEngineOptions

createWith :: Net -> Text -> HistoryStore -> Engine.EngineOptions -> IO Engine.Engine
createWith net identity store opts = memory >>= \port -> Engine.create net identity store port opts

create :: Net -> Text -> HistoryStore -> IO Engine.Engine
create net identity store = createWith net identity store options

loadWith :: Net -> Text -> HistoryStore -> Engine.EngineOptions -> IO Engine.Engine
loadWith net identity store opts = memory >>= \port -> Engine.load net identity store port opts

load :: Net -> Text -> HistoryStore -> IO Engine.Engine
load net identity store = loadWith net identity store options

-- | @engine.accept_delivery(source, tokens, identity=identity)@ expected to
-- accept freshly or reconstruct.
acceptOn :: HasCallStack => Engine.Engine -> NetPath -> [Token] -> Text -> IO AcceptedDelivery
acceptOn engine source tokens identity =
  Engine.acceptDelivery engine source tokens identity Nothing >>= \case
    DeliveryAccepted accepted -> pure accepted
    other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other) >> error "unreachable"

jsonl :: FilePath -> IO HistoryStore
jsonl = openJsonlHistoryStore

-- | A fresh scratch directory (pytest's @tmp_path@).
withScratch :: (FilePath -> IO r) -> IO r
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-engine-phases"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- ---------------------------------------------------------------------------
-- JSONL editing (@path.read_text().splitlines()@ and friends)

readLines :: FilePath -> IO [BS.ByteString]
readLines path = filter (not . BS.null) . BC.split '\n' <$> BS.readFile path

writeLines :: FilePath -> [BS.ByteString] -> IO ()
writeLines path lines' = BS.writeFile path (BS.intercalate "\n" lines' <> "\n")

loads :: HasCallStack => BS.ByteString -> Json
loads line = either (error . ("json.loads: " <>)) id (parseJson pythonLoads line)

jsonDumps :: Json -> BS.ByteString
jsonDumps value = either (error . show) id (dumps defaultDumps value)

readRecords :: FilePath -> IO [Json]
readRecords path = map loads <$> readLines path

writeRecords :: FilePath -> [Json] -> IO ()
writeRecords path = writeLines path . map jsonDumps

member :: HasCallStack => Text -> Json -> Json
member key value = fromMaybe (error ("missing member " <> T.unpack key)) (lookupMember key value)

kindOf :: Json -> Json
kindOf = member "record"

setMember :: Text -> Json -> Json -> Json
setMember key new = \case
  Object members -> Object [(k, if k == key then new else v) | (k, v) <- members]
  other -> other

updateMember :: Text -> (Json -> Json) -> Json -> Json
updateMember key f value = setMember key (f (member key value)) value

updateAt :: Int -> (x -> x) -> [x] -> [x]
updateAt i f xs = [if j == i then f x else x | (j, x) <- zip [0 ..] xs]

indexWhere :: HasCallStack => (x -> Bool) -> [x] -> Int
indexWhere p xs = fromMaybe (error "no matching element") (findIndex p xs)

-- ---------------------------------------------------------------------------
-- Refusals

-- | @pytest.raises(ValueError, match=r"f1.*f2.*...")@: the fragments appear
-- in order in a @ValueError@'s message (the Engine's, or the JSONL store's
-- decode refusal).
shouldRefuseMatching :: HasCallStack => IO r -> [Text] -> Expectation
shouldRefuseMatching action fragments =
  try action >>= \case
    Right _ -> expectationFailure "expected a ValueError, but the operation succeeded"
    Left (failure :: SomeException) -> case valueErrorMessage failure of
      Nothing -> expectationFailure ("expected a ValueError, got " <> displayException failure)
      Just message ->
        unless (inOrder fragments message) $
          expectationFailure ("expected a message matching " <> show fragments <> ", got " <> show message)

valueErrorMessage :: SomeException -> Maybe Text
valueErrorMessage failure
  | Just (Engine.EngineValueError message) <- fromException failure = Just message
  | Just (HistoryStoreError message) <- fromException failure = Just message
  | otherwise = Nothing

inOrder :: [Text] -> Text -> Bool
inOrder [] _ = True
inOrder (fragment : rest) message = case T.breakOn fragment message of
  (_, found)
    | T.null found -> False
    | otherwise -> inOrder rest (T.drop (T.length fragment) found)

-- ---------------------------------------------------------------------------
-- Forged-record shorthands (the reference's keyword defaults)

eventDelivered :: NetPath -> [Token] -> Text -> Int -> Record
eventDelivered source tokens identity occurrence = RExternalEventDelivered (ExternalEventDelivered source tokens identity occurrence Nothing 0)

firingBegun :: NetPath -> Int -> Record
firingBegun transition' occurrence = RFiringBegun (FiringBegun transition' occurrence Nothing 0)

firingCompleted :: NetPath -> Int -> Record
firingCompleted transition' occurrence = RFiringCompleted (FiringCompleted transition' occurrence 0)

candidateSelected :: NetPath -> Int -> Record
candidateSelected transition' occurrence = RCandidateSelected (CandidateSelected transition' occurrence 0)

registrationOpened :: NetPath -> Text -> Maybe Int -> Record
registrationOpened source key occurrence = RDeliveryRegistrationOpened (DeliveryRegistrationOpened source key occurrence 0)

tokensProduced :: NetPath -> [Token] -> Int -> Record
tokensProduced at tokens occurrence = RTokensProduced (TokensProduced at tokens occurrence [] Nothing 0)

tokensConsumed :: NetPath -> [Token] -> Int -> Record
tokensConsumed at tokens occurrence = RTokensConsumed (TokensConsumed at tokens occurrence [] Nothing 0)

forged :: DeliveryRegistration
forged = DeliveryRegistration src "forged"

-- | A backend refusal whose rendering itself fails (the reference's
-- @HostileCommitRefusal.__str__@ raises).
newtype HostileCommitRefusal = HostileCommitRefusal Int

instance Show HostileCommitRefusal where
  show _ = error "completion refusal handling must not render the backend exception"

instance Exception HostileCommitRefusal

isFiringCompleted :: Record -> Bool
isFiringCompleted = \case RFiringCompleted _ -> True; _ -> False

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "TestIdentifiedDeliveryPhases" $ do
  it "float instant survives create accept load and exact completion" $ withScratch $ \dir -> do
    let path = dir </> "float-instant-delivery.jsonl"
        token = tokD "X" (Object [("event", Int 7)])
    created <- jsonl path >>= \s -> createWith ingressNet "float-instant-delivery" s options {Engine.at = FloatNumber 0.5}
    accepted <- acceptOn created src [token] "event-7"
    Engine.close created

    loaded <- jsonl path >>= load ingressNet "float-instant-delivery"
    reconstructed <- acceptOn loaded src [token] "event-7"
    completed <- Engine.completeDelivery loaded reconstructed

    reconstructed `shouldBe` accepted
    completed.occurrence `shouldBe` firingOccurrenceIdInt accepted.occurrence
    recorded <- Engine.records loaded
    map recordInstant recorded `shouldSatisfy` all (== FloatNumber 0.5)

  it "accepting a delivery begins without completing its source occurrence" $ do
    history <- inMemoryHistoryStore
    let token = tokD "X" (Object [("event", Int 7)])
    engine <- create ingressNet "accepted-delivery" history

    accepted <- acceptOn engine src [token] "event-7"

    (accepted.source, deliveryIdentityText accepted.identity, firingOccurrenceIdInt accepted.occurrence) `shouldBe` (src, "event-7", 1)
    recorded <- Store.records history
    drop (length recorded - 2) recorded `shouldBe` [eventDelivered src [token] "event-7" 1, firingBegun src 1]
    recorded `shouldSatisfy` all (\case RTokensProduced _ -> False; RFiringCompleted _ -> False; _ -> True)
    Engine.marking engine `shouldReturn` emptyMarking

  it "returned identity composes with exact unfinished redelivery" $ do
    history <- inMemoryHistoryStore
    let token = tokD "X" (Object [("event", Int 7)])
    engine <- create ingressNet "returned-delivery-identity" history
    accepted <- acceptOn engine src [token] "event-7"
    acceptedRecords <- Store.records history

    reconstructed <- acceptOn engine src [token] (deliveryIdentityText accepted.identity)

    reconstructed `shouldBe` accepted
    Store.records history `shouldReturn` acceptedRecords

  it "acceptance is visible from an independently reopened durable store" $ withScratch $ \dir -> do
    let path = dir </> "accepted.jsonl"
        token = tokD "X" (Object [("event", Int 7)])
    engine <- jsonl path >>= create ingressNet "durable-acceptance"

    accepted <- acceptOn engine src [token] "event-7"

    firingOccurrenceIdInt accepted.occurrence `shouldBe` 1
    reopened <- jsonl path >>= Store.records
    drop (length reopened - 2) reopened `shouldBe` [eventDelivered src [token] "event-7" 1, firingBegun src 1]

  it "hostile completion store refusal leaves the accepted occurrence unfinished for fresh retry" $ do
    base <- inMemoryHistoryStore
    refuseCompletion <- newIORef False
    let history =
          HistoryStore
            { snapshot = base.snapshot
            , count = base.count
            , mode = base.mode
            , extend = \batch -> do
                refusing <- readIORef refuseCompletion
                if refusing && any isFiringCompleted batch
                  then writeIORef refuseCompletion False >> throwIO (HostileCommitRefusal 42)
                  else base.extend batch
            }
        token = tokD "X" (Object [("event", Int 7)])
    engine <- create ingressNet "refused-completion" history
    accepted <- acceptOn engine src [token] "event-7"
    acceptedRecords <- Store.records history
    writeIORef refuseCompletion True

    try (Engine.completeDelivery engine accepted) >>= \case
      Left (HostileCommitRefusal raised) -> raised `shouldBe` 42
      Right outcome -> expectationFailure ("expected the store's refusal, got " <> show outcome)

    Store.records history `shouldReturn` acceptedRecords
    Store.records history >>= (`shouldSatisfy` all (\case RFiringFailed _ -> False; _ -> True))
    resumed <- load ingressNet "refused-completion" history
    reconstructed <- acceptOn resumed src [token] "event-7"
    reconstructed `shouldBe` accepted
    completed <- Engine.completeDelivery resumed reconstructed
    completed.occurrence `shouldBe` firingOccurrenceIdInt accepted.occurrence

  -- composed_delivery_requires_stable_identity_before_history_mutation: N/A
  -- by construction — 'Engine.deliver' takes the identity as a required
  -- 'Text' argument, so neither the missing keyword (TypeError) nor
  -- @identity=None@ (ValueError) is expressible.

  it "load refuses a complete line prefix that tears the acceptance batch" $ withScratch $ \dir -> do
    let path = dir </> "torn-acceptance.jsonl"
    engine <- jsonl path >>= create ingressNet "torn-acceptance"
    _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
    Engine.close engine
    lines' <- readLines path
    kindOf (loads (lines' !! (length lines' - 2))) `shouldBe` String "ExternalEventDelivered"
    kindOf (loads (last lines')) `shouldBe` String "FiringBegun"
    writeLines path (init lines')

    (jsonl path >>= load ingressNet "torn-acceptance")
      `shouldRefuseMatching` ["replay divergence", "event-7", "matching FiringBegun"]

  it "load refuses a construction batch truncated after identity" $ withScratch $ \dir -> do
    let path = dir </> "torn-construction-after-identity.jsonl"
    engine <- jsonl path >>= create ingressNet "torn-construction-after-identity"
    Engine.close engine
    identity : _ <- readLines path
    writeLines path [identity]
    torn <- BS.readFile path

    (jsonl path >>= load ingressNet "torn-construction-after-identity")
      `shouldRefuseMatching` ["replay divergence", "construction batch", "source registrations"]

    BS.readFile path `shouldReturn` torn

  it "load refuses a construction batch truncated between source registrations" $ withScratch $ \dir -> do
    let secondSource = np "second-source"
        net = netOf [place a, place b] [transition src, transition secondSource] [arc src a, arc secondSource b]
        path = dir </> "torn-construction-between-registrations.jsonl"
    engine <- jsonl path >>= create net "torn-construction-between-registrations"
    Engine.close engine
    lines' <- readLines path
    map (kindOf . loads) lines'
      `shouldBe` map String ["InstanceCreated", "DeliveryRegistrationOpened", "DeliveryRegistrationOpened"]
    writeLines path (init lines')
    torn <- BS.readFile path

    (jsonl path >>= load net "torn-construction-between-registrations")
      `shouldRefuseMatching` ["replay divergence", "construction batch", "source registrations"]

    BS.readFile path `shouldReturn` torn

  it "load refuses initial token color the live constructor rejects" $ withScratch $ \dir -> do
    let net = netOf [Place a (Just "Expected"), place b] [transition src] [arc src b]
        path = dir </> "invalid-initial-color.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith net "invalid-initial-color" s options {Engine.marking = markingFromList [(a, [tok "Expected"])]}
    Engine.close engine
    records' <- readRecords path
    let initialized = indexWhere ((== String "TokensInitialized") . kindOf) records'
        recolor = updateMember "tokens" $ \case
          Array (first : rest) -> Array (setMember "color" (String "Wrong") first : rest)
          other -> other
    writeRecords path (updateAt initialized recolor records')
    malformed <- BS.readFile path

    (jsonl path >>= load net "invalid-initial-color")
      `shouldRefuseMatching` ["initial marking", "requires color 'Expected'", "got 'Wrong'"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses duplicate initialization for one place" $ withScratch $ \dir -> do
    let path = dir </> "duplicate-initial-place.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith ingressNet "duplicate-initial-place" s options {Engine.marking = markingFromList [(b, [tok "Seed"])]}
    Engine.close engine
    records' <- readRecords path
    let initialized = indexWhere ((== String "TokensInitialized") . kindOf) records'
        (before, after) = splitAt (initialized + 1) records'
    writeRecords path (before <> [records' !! initialized] <> after)
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "duplicate-initial-place")
      `shouldRefuseMatching` ["replay divergence", "place b", "initialized exactly once"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses initialization for an unknown place" $ withScratch $ \dir -> do
    let path = dir </> "unknown-initial-place.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith ingressNet "unknown-initial-place" s options {Engine.marking = markingFromList [(b, [tok "Seed"])]}
    Engine.close engine
    records' <- readRecords path
    let initialized = indexWhere ((== String "TokensInitialized") . kindOf) records'
    writeRecords path (updateAt initialized (setMember "place" (String "unknown")) records')
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "unknown-initial-place")
      `shouldRefuseMatching` ["replay divergence", "unknown place unknown", "initial marking"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses initialization after the construction instant" $ withScratch $ \dir -> do
    let path = dir </> "late-initial-tokens.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith ingressNet "late-initial-tokens" s options {Engine.marking = markingFromList [(b, [tok "Seed"])]}
    Engine.close engine
    records' <- readRecords path
    let initialized = indexWhere ((== String "TokensInitialized") . kindOf) records'
    writeRecords path (updateAt initialized (setMember "instant" (Int 1)) records')
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "late-initial-tokens")
      `shouldRefuseMatching` ["replay divergence", "initial tokens", "instant 1", "construction instant 0"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses initialization after source free construction ended" $ withScratch $ \dir -> do
    let net = netOf [place a] [] []
        path = dir </> "late-source-free-initialization.jsonl"
    engine <- jsonl path >>= create net "late-source-free-initialization"
    _ <- Engine.openScope engine "runtime"
    Engine.close engine
    jsonl path >>= \s -> Store.append s (RTokensInitialized (TokensInitialized a [tok "Forged"] 0 [] Nothing))
    malformed <- BS.readFile path

    (jsonl path >>= load net "late-source-free-initialization")
      `shouldRefuseMatching` ["replay divergence", "TokensInitialized", "outside", "construction"]

    BS.readFile path `shouldReturn` malformed

  -- load_refuses_a_history_record_subclass_before_reading_its_fields: N/A by
  -- construction — 'Record' is a closed sum of plain records; no subclass
  -- can redirect a field read.

  it "load refuses an acceptance recorded after the source was sealed" $ withScratch $ \dir -> do
    let path = dir </> "unarmed-acceptance.jsonl"
    engine <- jsonl path >>= create ingressNet "unarmed-acceptance"
    Engine.seal engine src
    Engine.close engine
    jsonl path >>= \s -> s.extend [eventDelivered src [tok "X"] "event-7" 1, firingBegun src 1]

    (jsonl path >>= load ingressNet "unarmed-acceptance")
      `shouldRefuseMatching` ["replay divergence", "event-7", "no armed delivery registration"]

  it "load refuses a delivery authorized by a forged initial registration" $ withScratch $ \dir -> do
    let path = dir </> "forged-registration-reopen.jsonl"
    engine <- jsonl path >>= create ingressNet "forged-registration-reopen"
    Engine.seal engine src
    Engine.close engine
    jsonl path >>= \s ->
      s.extend
        [ registrationOpened src "default" Nothing
        , eventDelivered src [tok "X"] "event-7" 1
        , firingBegun src 1
        , firingCompleted src 1
        ]

    (jsonl path >>= load ingressNet "forged-registration-reopen")
      `shouldRefuseMatching` ["replay divergence", "uncorrelated delivery registration", "only in the initial construction batch"]

  it "load refuses a delivery authorized by an orphan correlated registration" $ withScratch $ \dir -> do
    let path = dir </> "orphan-correlated-registration.jsonl"
    engine <- jsonl path >>= create ingressNet "orphan-correlated-registration"
    Engine.seal engine src
    Engine.close engine
    jsonl path >>= \s ->
      s.extend
        [ registrationOpened src "forged" (Just 1)
        , eventDelivered src [tok "X"] "event-7" 2
        , firingBegun src 2
        , firingCompleted src 2
        ]

    (jsonl path >>= load ingressNet "orphan-correlated-registration")
      `shouldRefuseMatching` ["replay divergence", "correlated delivery registration", "occurrence 1", "writer-valid completion batch"]

  it "load refuses a delivery authorized by an impossible ended firing" $ withScratch $ \dir -> do
    let path = dir </> "impossible-ended-registration.jsonl"
    engine <- jsonl path >>= create ingressNet "impossible-ended-registration"
    Engine.seal engine src
    Engine.close engine
    jsonl path >>= \s ->
      s.extend
        [ candidateSelected t 1
        , firingBegun t 1
        , registrationOpened src "forged" (Just 1)
        , firingCompleted t 1
        ]
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "impossible-ended-registration")
      `shouldRefuseMatching` ["cannot resume firing occurrence 1 (t)", "consume selections do not match"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses a late begin fact that retroactively authorizes delivery" $ withScratch $ \dir -> do
    let path = dir </> "late-begin-registration.jsonl"
        seed = tok "Seed"
    engine <-
      jsonl path >>= \s ->
        createWith ingressNet "late-begin-registration" s options {Engine.marking = markingFromList [(a, [seed])]}
    Engine.seal engine src
    Engine.close engine
    jsonl path >>= \s ->
      s.extend
        [ candidateSelected t 1
        , firingBegun t 1
        , tokensProduced b [tok "Projected"] 1
        , registrationOpened src "forged" (Just 1)
        , firingCompleted t 1
        , tokensConsumed a [seed] 1
        , eventDelivered src [tok "X"] "event-7" 2
        , firingBegun src 2
        ]
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "late-begin-registration")
      `shouldRefuseMatching` ["replay divergence", "TokensConsumed", "occurrence 1", "after", "terminal"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses an interleaved begin batch that authorizes delivery" $ withScratch $ \dir -> do
    let path = dir </> "interleaved-begin-registration.jsonl"
        seed = tok "Seed"
        rearm _ _ = Right (HandlerResult [(b, [tok "Projected"])] [forged] [])
        net =
          netOf
            [place a, place b]
            [transition src, Transition t (Just (HandlerSymbol "rearm")) [] []]
            [arc src a, arc a t, arc t b]
        handlers = symbols [("rearm", PureHandler rearm)]
    engine <-
      jsonl path >>= \s ->
        createWith net "interleaved-begin-registration" s options {Engine.handlers = handlers, Engine.marking = markingFromList [(a, [seed])]}
    Engine.seal engine src
    Engine.close engine
    unrelated <- either (fail . T.unpack) pure (lifecycleScope "unrelated" 1)
    jsonl path >>= \s ->
      s.extend
        [ candidateSelected t 1
        , firingBegun t 1
        , RScopeOpened (ScopeOpened unrelated 0)
        , tokensConsumed a [seed] 1
        , tokensProduced b [tok "Projected"] 1
        , registrationOpened src "forged" (Just 1)
        , firingCompleted t 1
        , eventDelivered src [tok "X"] "event-7" 2
        , firingBegun src 2
        ]
    malformed <- BS.readFile path

    (jsonl path >>= \s -> loadWith net "interleaved-begin-registration" s options {Engine.handlers = handlers})
      `shouldRefuseMatching` ["replay divergence", "TokensConsumed", "occurrence 1", "contiguous begin batch"]

    BS.readFile path `shouldReturn` malformed

  describe "load refuses each foreign activity fact that authorizes delivery" $
    forM_ ["requested", "completed", "failed" :: Text] $ \factKind ->
      it (T.unpack factKind) $ withScratch $ \dir -> do
        let path = dir </> T.unpack ("foreign-" <> factKind <> "-registration.jsonl")
            identity = "foreign-" <> factKind <> "-registration"
            seed = tok "Seed"
            ghost = np "ghost"
            rearm =
              ActivityBound
                ActivityHandler
                  { prepare = \_ -> Right (invocation "rearm" (Object [("event", Int 7)]))
                  , project = \_ _ -> Right (HandlerResult [(b, [tok "Projected"])] [forged] [])
                  , projectFailure = Nothing
                  }
            net =
              netOf
                [place a, place b]
                [transition src, Transition t (Just (HandlerSymbol "rearm")) [] []]
                [arc src a, arc a t, arc t b]
            handlers = symbols [("rearm", rearm)]
        engine <-
          jsonl path >>= \s ->
            createWith net identity s options {Engine.handlers = handlers, Engine.marking = markingFromList [(a, [seed])]}
        Engine.seal engine src
        Engine.close engine
        let requested =
              RActivityRequested
                ( ActivityRequested
                    (if factKind == "requested" then ghost else t)
                    "rearm"
                    (Object [("event", Int 7)])
                    defaultExecutionPolicy
                    "occurrence-1"
                    "occurrence-1"
                    1
                    Nothing
                    0
                )
            terminal
              | factKind == "failed" = RActivityFailed (ActivityFailed ghost "failed" "ActivityError" Null False Nothing 1 0)
              | otherwise = RActivityCompleted (ActivityCompleted (if factKind == "completed" then ghost else t) (Object [("ok", Bool True)]) 1 0)
        jsonl path >>= \s ->
          s.extend
            [ candidateSelected t 1
            , firingBegun t 1
            , tokensConsumed a [seed] 1
            , requested
            , terminal
            , tokensProduced b [tok "Projected"] 1
            , registrationOpened src "forged" (Just 1)
            , firingCompleted t 1
            , eventDelivered src [tok "X"] "event-7" 2
            , firingBegun src 2
            ]
        malformed <- BS.readFile path

        (jsonl path >>= \s -> loadWith net identity s options {Engine.handlers = handlers})
          `shouldRefuseMatching` ["replay divergence", "Activity" <> T.toTitle factKind, "ghost", "begun transition t"]

        BS.readFile path `shouldReturn` malformed

  it "load refuses a foreign quarantined activity fact" $ withScratch $ \dir -> do
    let path = dir </> "foreign-quarantined-activity.jsonl"
        ghost = np "ghost"
        work =
          ActivityBound
            ActivityHandler
              { prepare = \_ -> Right (invocation "work" Null)
              , project = \_ _ -> Right (handlerTokens [(b, [tok "Done"])])
              , projectFailure = Nothing
              }
        net =
          netOf
            [place a, place b]
            [transition src, Transition t (Just (HandlerSymbol "work")) [] []]
            [arc src a, arc a t, arc t b]
        handlers = symbols [("work", work)]
    engine <- jsonl path >>= \s -> createWith net "foreign-quarantined-activity" s options {Engine.handlers = handlers}
    scope <- Engine.openScope engine "request"
    _ <- Engine.deliver engine src [tok "Ready"] "seed" (Just (ScopeGeneration scope))
    _ <- Engine.advance engine
    _ <- Engine.closeScope engine scope
    Engine.close engine
    recorded <- jsonl path >>= Store.records
    occurrence : _ <- pure [selected.occurrence | RCandidateSelected selected <- recorded]
    jsonl path >>= \s ->
      Store.append
        s
        ( RActivityTerminalQuarantined
            ( ActivityTerminalQuarantined
                ghost
                (Object [("kind", String "completed"), ("value", Object [("ok", Bool True)])])
                scope
                occurrence
                0
            )
        )
    malformed <- BS.readFile path

    (jsonl path >>= \s -> loadWith net "foreign-quarantined-activity" s options {Engine.handlers = handlers})
      `shouldRefuseMatching` ["replay divergence", "ActivityTerminalQuarantined", "ghost", "begun transition t"]

    BS.readFile path `shouldReturn` malformed

  it "load refuses initial tokens recorded after registration opened" $ withScratch $ \dir -> do
    let path = dir </> "disordered-construction-prefix.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith ingressNet "disordered-construction-prefix" s options {Engine.marking = markingFromList [(b, [tok "Seed"])]}
    _ <- acceptOn engine src [tok "X"] "event-7"
    Engine.close engine
    records' <- readRecords path
    let initialized = indexWhere ((== String "TokensInitialized") . kindOf) records'
        registration =
          indexWhere
            (\r -> kindOf r == String "DeliveryRegistrationOpened" && lookupMember "occurrence" r == Just Null)
            records'
    registration `shouldBe` initialized + 1
    let swapped =
          [ if i == initialized then records' !! registration else if i == registration then records' !! initialized else r
          | (i, r) <- zip [0 ..] records'
          ]
    writeRecords path swapped
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "disordered-construction-prefix")
      `shouldRefuseMatching` ["replay divergence", "initial construction prefix"]

    BS.readFile path `shouldReturn` malformed

  -- load_refuses_a_queue_identity_subclass_before_reconstruction: N/A by
  -- construction — queue entries are 'Int'; there is no integer subclass.

  it "load refuses a correlated registration separated from its production" $ withScratch $ \dir -> do
    let path = dir </> "separated-correlated-registration.jsonl"
        openRegistration binding' _ = Right (HandlerResult [(b, bindingTokens binding')] [forged] [])
        net =
          netOf
            [place a, place b, place c]
            [Transition t (Just (HandlerSymbol "open")) [] [], transition src]
            [arc a t, arc t b, arc src c]
        handlers = symbols [("open", PureHandler openRegistration)]
    engine <-
      jsonl path >>= \s ->
        createWith
          net
          "separated-correlated-registration"
          s
          options {Engine.marking = markingFromList [(a, [tok "Work"])], Engine.handlers = handlers}
    Engine.seal engine src
    _ <- Engine.advance engine
    _ <- acceptOn engine src [tok "Event"] "event-7"
    Engine.close engine
    records' <- readRecords path
    let production =
          indexWhere (\r -> kindOf r == String "TokensProduced" && lookupMember "occurrence" r == Just (Int 1)) records'
        registration =
          indexWhere
            ( \r ->
                kindOf r == String "DeliveryRegistrationOpened"
                  && lookupMember "occurrence" r == Just (Int 1)
                  && lookupMember "key" r == Just (String "forged")
            )
            records'
    registration `shouldBe` production + 1
    let scopeOpened =
          Object
            [ ("record", String "ScopeOpened")
            , ("schema", Int 5)
            , ("scope", Object [("name", String "unrelated"), ("generation", Int 1)])
            , ("instant", member "instant" (records' !! production))
            ]
        (before, after) = splitAt registration records'
    writeRecords path (before <> [scopeOpened] <> after)
    malformed <- BS.readFile path

    (jsonl path >>= \s -> loadWith net "separated-correlated-registration" s options {Engine.handlers = handlers})
      `shouldRefuseMatching` ["replay divergence", "correlated delivery registration", "occurrence 1", "writer-valid completion batch"]

    BS.readFile path `shouldReturn` malformed

  describe "load refuses noncanonical acceptance occurrences" $
    forM_ [(Int 1, Bool True, "FiringBegun" :: Text), (Int 0, Int 0, "ExternalEventDelivered")] $ \(eventOccurrence, begunOccurrence, invalidRecord) ->
      it (T.unpack invalidRecord) $ withScratch $ \dir -> do
        let path = dir </> "invalid-acceptance-occurrence.jsonl"
        engine <- jsonl path >>= create ingressNet "invalid-acceptance-occurrence"
        _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
        Engine.close engine
        records' <- readRecords path
        let n = length records'
        writeRecords
          path
          (updateAt (n - 1) (setMember "occurrence" begunOccurrence) (updateAt (n - 2) (setMember "occurrence" eventOccurrence) records'))

        (jsonl path >>= load ingressNet "invalid-acceptance-occurrence")
          `shouldRefuseMatching` [invalidRecord <> " occurrence must be a positive integer"]

  it "load refuses a second begin for one delivery occurrence" $ withScratch $ \dir -> do
    let path = dir </> "duplicate-delivery-begin.jsonl"
    engine <- jsonl path >>= create ingressNet "duplicate-delivery-begin"
    _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
    Engine.close engine
    lines' <- readLines path
    kindOf (loads (last lines')) `shouldBe` String "FiringBegun"
    writeLines path (lines' <> [last lines'])

    (jsonl path >>= load ingressNet "duplicate-delivery-begin")
      `shouldRefuseMatching` ["replay divergence", "occurrence 1", "more than one FiringBegun"]

  it "load refuses two delivery identities that share one occurrence" $ withScratch $ \dir -> do
    let path = dir </> "aliased-delivery-occurrence.jsonl"
    engine <- jsonl path >>= create ingressNet "aliased-delivery-occurrence"
    _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
    Engine.close engine
    lines' <- readLines path
    let secondDelivery = setMember "identity" (String "event-8") (loads (lines' !! (length lines' - 2)))
    writeLines path (lines' <> [jsonDumps secondDelivery, last lines'])

    (jsonl path >>= load ingressNet "aliased-delivery-occurrence")
      `shouldRefuseMatching` ["replay divergence", "occurrence 1", "initiated more than once"]

  it "load refuses an empty failure for an accepted delivery" $ withScratch $ \dir -> do
    let path = dir </> "empty-delivery-failure.jsonl"
    engine <- jsonl path >>= create ingressNet "empty-delivery-failure"
    _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
    Engine.close engine
    lines' <- readLines path
    writeLines path (lines' <> [jsonDumps (failureLine "")])

    (jsonl path >>= load ingressNet "empty-delivery-failure")
      `shouldRefuseMatching` ["FiringFailed error must be a non-empty string of at most 4096 characters"]

  -- The reference forges a @str@ subclass whose @len@ lies about an
  -- oversize error; Haskell has no subclass, so the property ported is the
  -- oversize error itself being refused before any redelivery
  -- acknowledgement can read it.
  it "load refuses a failure with a string subclass before redelivery acknowledgement" $ withScratch $ \dir -> do
    let path = dir </> "subclass-delivery-failure.jsonl"
    engine <- jsonl path >>= create ingressNet "subclass-delivery-failure"
    _ <- acceptOn engine src [tokD "X" (Object [("event", Int 7)])] "event-7"
    Engine.close engine
    lines' <- readLines path
    writeLines path (lines' <> [jsonDumps (failureLine (T.replicate 4097 "x"))])
    malformed <- BS.readFile path

    (jsonl path >>= load ingressNet "subclass-delivery-failure")
      `shouldRefuseMatching` ["FiringFailed error must be a non-empty string of at most 4096 characters"]

    BS.readFile path `shouldReturn` malformed

  -- load_refuses_a_mutated_delivery_identity_before_it_can_split_redelivery_authority:
  -- N/A by construction — the identity is an immutable 'Text'; no subclass
  -- can carry an alternate hash.

  -- The reference mutates a live record's occurrence to @True@; Haskell
  -- records are immutable and typed, so the same forged boolean arrives
  -- through the JSONL file instead.
  it "load refuses a boolean candidate occurrence before lifecycle folding" $ withScratch $ \dir -> do
    let path = dir </> "boolean-candidate-occurrence.jsonl"
    engine <-
      jsonl path >>= \s ->
        createWith lineNet "boolean-candidate-occurrence" s options {Engine.marking = markingFromList [(a, [tok "X"])]}
    _ <- Engine.advance engine
    Engine.close engine
    records' <- readRecords path
    let selected = indexWhere ((== String "CandidateSelected") . kindOf) records'
    writeRecords path (updateAt selected (setMember "occurrence" (Bool True)) records')
    malformed <- BS.readFile path

    (jsonl path >>= load lineNet "boolean-candidate-occurrence")
      `shouldRefuseMatching` ["CandidateSelected occurrence must be a positive integer"]

    BS.readFile path `shouldReturn` malformed

  -- The reference mutates the store's token data after load; Haskell
  -- History values are immutable, so detachment holds by construction and
  -- the observable remainder — exact reconstruction after load, History
  -- untouched — is what is checked.
  it "loaded acceptance is detached from later store token mutation" $ do
    history <- inMemoryHistoryStore
    let token = tokD "X" (Object [("event", Int 7)])
    engine <- create ingressNet "detached-replay-acceptance" history
    accepted <- acceptOn engine src [token] "event-7"
    Engine.close engine
    resumed <- load ingressNet "detached-replay-acceptance" history
    recorded <- Store.records history

    reconstructed <- acceptOn resumed src [token] "event-7"

    reconstructed `shouldBe` accepted
    Store.records history `shouldReturn` recorded
  where
    failureLine message =
      Object
        [ ("record", String "FiringFailed")
        , ("schema", Int 5)
        , ("transition", String "src")
        , ("error", String message)
        , ("occurrence", Int 1)
        , ("instant", Int 0)
        ]
