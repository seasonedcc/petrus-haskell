-- | Port of upstream @tests/petrus/engine/test_execution.py@,
-- @TestIdentifiedDeliveryPhases@, the tests defined in source lines
-- 1486-2769: load-time refusal of forged accepted-delivery histories,
-- targeted completion, exact redelivery, and identity collisions.
--
-- Not ported (N/A by construction — the Haskell types are closed, so the
-- reference's @str@ / @int@ / @NetPath@ / @LifecycleScope@ subclass
-- spoofing cannot be spelled):
--
-- * @test_reserved_identity_subclass_is_rejected_before_mutation@
-- * @test_changed_scope_subclass_is_rejected_before_redelivery_judgment@
-- * @test_changed_lifecycle_scope_subclass_is_rejected_before_redelivery_judgment@
-- * @test_changed_lifecycle_generation_subclass_is_rejected_before_redelivery_judgment@
-- * @test_net_path_subclass_is_rejected_before_durable_acceptance@
-- * @test_seal_rejects_a_source_subclass_before_mutation@
module Petrus.Engine.DeliveryPhasesBSpec (spec) where

import Control.Exception (SomeException, bracket, fromException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport
import Petrus.HistoryStore.Jsonl (HistoryStoreError (..), openJsonlHistoryStore)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
  ( AcceptedDelivery (..)
  , DeliveryAnswer (..)
  , DeliveryScope (..)
  , FiringOccurrence (..)
  , FiringOutcome (..)
  , PriorAcknowledgement (..)
  , firingOccurrenceIdInt
  )
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.Scope (lifecycleScope)
import Petrus.Impetus.TestSupport (netOf, np, tok, tokD)
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch, pending)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec hiding (pending)

-- ---------------------------------------------------------------------------
-- Fixtures (the module-level helpers of test_execution.py)

a, b, c, t, src :: NetPath
a = np "a"
b = np "b"
c = np "c"
t = np "t"
src = np "src"

-- | @_ingress_net()@: src -> a -> t -> b.
ingressNet :: Net
ingressNet = netOf [place a, place b] [transition src, transition t] [arc src a, arc a t, arc t b]

memPort :: IO Dispatch
memPort = inMemoryDispatch <$> newInMemoryDispatch

-- | @tmp_path@.
withScratch :: (FilePath -> IO r) -> IO r
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-engine-phases-b"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- | @Engine.create(net, identity, history=JsonlHistoryStore(path), dispatch=InMemoryDispatch(), ...)@.
createJsonl :: Net -> Text -> FilePath -> Engine.EngineOptions -> IO Engine.Engine
createJsonl net identity path options = do
  store <- openJsonlHistoryStore path
  port <- memPort
  Engine.create net identity store port options

-- | @Engine.load(net, identity, history=JsonlHistoryStore(path), dispatch=InMemoryDispatch(), ...)@.
loadJsonl :: Net -> Text -> FilePath -> Engine.EngineOptions -> IO Engine.Engine
loadJsonl net identity path options = do
  store <- openJsonlHistoryStore path
  port <- memPort
  Engine.load net identity store port options

accept :: Engine.Engine -> NetPath -> Token -> Text -> Maybe DeliveryScope -> IO (DeliveryAnswer AcceptedDelivery)
accept engine source parcel = Engine.acceptDelivery engine source [parcel]

accepted :: HasCallStack => DeliveryAnswer AcceptedDelivery -> IO AcceptedDelivery
accepted = \case
  DeliveryAccepted carrier -> pure carrier
  other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other) >> error "unreachable"

-- | @engine.accept_delivery(SRC, Token("X", {"event": 7}), identity="event-7")@.
acceptEvent7 :: Engine.Engine -> IO ()
acceptEvent7 engine = () <$ accept engine src event7 "event-7" Nothing

event :: Integer -> Json
event n = Object [("event", Int n)]

event7 :: Token
event7 = tokD "X" (event 7)

-- ---------------------------------------------------------------------------
-- JSONL line surgery

-- | @path.read_text().splitlines()@.
readLines :: FilePath -> IO [BS.ByteString]
readLines path = BC.lines <$> BS.readFile path

-- | @path.write_text("\n".join(lines) + "\n")@.
writeLines :: FilePath -> [BS.ByteString] -> IO ()
writeLines path ls = BS.writeFile path (BS.intercalate "\n" ls <> "\n")

-- | @json.dumps(record)@.
enc :: Json -> BS.ByteString
enc = either (error . show) id . dumps defaultDumps

dec :: BS.ByteString -> Json
dec = either error id . parseJson surrogateRefusingLoads

setMember :: Text -> Json -> Json -> Json
setMember key value = \case
  Object members -> Object [(k, if k == key then value else v) | (k, v) <- members]
  other -> error ("not an object: " <> show other)

tokenJ :: Text -> Json -> Json
tokenJ color payload = Object [("color", String color), ("data", payload)]

-- | A schema-5 @TokensProduced@ line.
producedJ :: Text -> [Json] -> Json -> [Integer] -> Json -> Integer -> Json
producedJ at tokens occurrence entries scope instant =
  Object
    [ ("record", String "TokensProduced")
    , ("schema", Int 5)
    , ("place", String at)
    , ("tokens", Array tokens)
    , ("occurrence", occurrence)
    , ("entries", Array (map Int entries))
    , ("scope", scope)
    , ("instant", Int instant)
    ]

-- | The default forged source production: @a@ ← @Token("X", {"event": 7})@,
-- occurrence 1, unscoped, instant 0.
production7 :: Json
production7 = producedJ "a" [tokenJ "X" (event 7)] (Int 1) [] Null 0

-- | A schema-5 terminal line (@FiringCompleted@ / @FiringFailed@).
terminalJ :: Text -> Text -> Json -> Integer -> [(Text, Json)] -> Json
terminalJ record at occurrence instant extra =
  Object
    ( [ ("record", String record)
      , ("schema", Int 5)
      , ("transition", String at)
      , ("occurrence", occurrence)
      , ("instant", Int instant)
      ]
        <> extra
    )

completedSrc1 :: Json
completedSrc1 = terminalJ "FiringCompleted" "src" (Int 1) 0 []

registrationOpenedJ :: Json -> Json -> Json
registrationOpenedJ key occurrence =
  Object
    [ ("record", String "DeliveryRegistrationOpened")
    , ("schema", Int 5)
    , ("source", String "src")
    , ("key", key)
    , ("occurrence", occurrence)
    , ("instant", Int 0)
    ]

-- | The reference's terminal-record parametrization.
terminals :: [(Text, [(Text, Json)])]
terminals = [("FiringCompleted", []), ("FiringFailed", [("error", String "boom")])]

-- ---------------------------------------------------------------------------
-- Refusal assertions

-- | Run the load expecting the reference's @ValueError@: an Engine value
-- refusal, or the JSONL store's decode refusal (the reference raises both
-- inside the same @pytest.raises@ block). Answers the message.
refusal :: HasCallStack => IO r -> IO Text
refusal action =
  try action >>= \case
    Right _ -> expectationFailure "expected a ValueError refusal, but the action succeeded" >> error "unreachable"
    Left (e :: SomeException)
      | Just (Engine.EngineValueError m) <- fromException e -> pure m
      | Just (HistoryStoreError m) <- fromException e -> pure m
      | otherwise -> expectationFailure ("expected a ValueError refusal, got " <> show e) >> error "unreachable"

-- | @re.search("f1.*f2.*...", message)@ for literal fragments.
shouldMatchInOrder :: HasCallStack => Text -> [Text] -> Expectation
shouldMatchInOrder message fragments
  | go message fragments = pure ()
  | otherwise = expectationFailure ("expected " <> show message <> " to match fragments in order " <> show fragments)
  where
    go _ [] = True
    go rest (f : fs) = case T.breakOn f rest of
      (_, found) | T.null found -> False
      (_, found) -> go (T.drop (T.length f) found) fs

-- | The refusal's message, for exact comparison.
valueRefusal :: HasCallStack => IO r -> IO Text
valueRefusal action =
  try action >>= \case
    Right _ -> expectationFailure "expected a ValueError" >> error "unreachable"
    Left (Engine.EngineValueError m) -> pure m
    Left other -> expectationFailure ("expected a ValueError, got " <> show other) >> error "unreachable"

recordsOf :: HistoryStore -> IO [Record]
recordsOf = Store.records

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "TestIdentifiedDeliveryPhases" $ do
  it "load refuses an ended scheduled source before movement replay" $ do
    history <- inMemoryHistoryStore
    let net = netOf [place a] [transition src] [arc src a]
    port <- memPort
    engine <- Engine.create net "ended-scheduled-source" history port Engine.defaultEngineOptions
    Engine.close engine
    history.extend
      [ RCandidateSelected (CandidateSelected src 1 0)
      , RFiringBegun (FiringBegun src 1 Nothing 0)
      , RTokensProduced (TokensProduced a [tok "X"] 1 [] Nothing 0)
      , RFiringCompleted (FiringCompleted src 1 0)
      ]
    malformed <- recordsOf history
    port' <- memPort
    message <- refusal (Engine.load net "ended-scheduled-source" history port' Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["scheduled selection on a source transition"]
    recordsOf history `shouldReturn` malformed

  describe "load refuses a foreign transition terminal for an accepted delivery" $
    mapM_
      ( \(record, extra) -> it (T.unpack record) $ withScratch $ \dir -> do
          let path = dir </> "foreign-delivery-terminal.jsonl"
          engine <- createJsonl ingressNet "foreign-delivery-terminal" path Engine.defaultEngineOptions
          acceptEvent7 engine
          Engine.close engine
          ls <- readLines path
          writeLines path (ls <> [enc (terminalJ record "t" (Int 1) 0 extra)])
          message <- refusal (loadJsonl ingressNet "foreign-delivery-terminal" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` ["replay divergence", "occurrence 1", "terminal transition t", "begun transition src"]
      )
      terminals

  describe "load refuses a boolean terminal occurrence" $
    mapM_
      ( \(record, extra) -> it (T.unpack record) $ withScratch $ \dir -> do
          let path = dir </> "boolean-delivery-terminal.jsonl"
          engine <- createJsonl ingressNet "boolean-delivery-terminal" path Engine.defaultEngineOptions
          acceptEvent7 engine
          Engine.close engine
          ls <- readLines path
          writeLines path (ls <> [enc (terminalJ record "src" (Bool True) 0 extra)])
          message <- refusal (loadJsonl ingressNet "boolean-delivery-terminal" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` [record <> " occurrence must be a positive integer"]
      )
      terminals

  describe "load refuses an ended delivery recorded on a non source" $
    mapM_
      ( \(record, extra) -> it (T.unpack record) $ withScratch $ \dir -> do
          let path = dir </> "ended-non-source-delivery.jsonl"
          engine <- createJsonl ingressNet "ended-non-source-delivery" path Engine.defaultEngineOptions
          acceptEvent7 engine
          Engine.close engine
          records <- map dec <$> readLines path
          let n = length records
              edited =
                [ if i == n - 2 then setMember "source" (String "t") r else if i == n - 1 then setMember "transition" (String "t") r else r
                | (i, r) <- zip [0 :: Int ..] records
                ]
                  <> [terminalJ record "t" (Int 1) 0 extra]
          writeLines path (map enc edited)
          message <- refusal (loadJsonl ingressNet "ended-non-source-delivery" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "transition t", "input arcs"]
      )
      terminals

  describe "load refuses an ended source occurrence with an activity request" $
    mapM_
      ( \(record, extra) -> it (T.unpack record) $ withScratch $ \dir -> do
          let path = dir </> "ended-impure-source.jsonl"
          engine <- createJsonl ingressNet "ended-impure-source" path Engine.defaultEngineOptions
          acceptEvent7 engine
          Engine.close engine
          ls <- readLines path
          let requested =
                Object
                  [ ("record", String "ActivityRequested")
                  , ("schema", Int 5)
                  , ("transition", String "src")
                  , ("activity", String "work")
                  , ("input", event 7)
                  , ( "policy"
                    , Object
                        [ ("attempts", Int 1)
                        , ("heartbeat_timeout", Int 30)
                        , ("initial_interval", Int 0)
                        , ("coefficient", Int 2)
                        , ("max_interval", Int 60)
                        , ("jitter", Int 0)
                        , ("start_to_close", Null)
                        , ("schedule_to_close", Null)
                        ]
                    )
                  , ("correlation", String "event-7")
                  , ("idempotency", String "event-7")
                  , ("occurrence", Int 1)
                  , ("scope", Null)
                  , ("instant", Int 0)
                  ]
          writeLines path (ls <> [enc requested, enc (terminalJ record "src" (Int 1) 0 extra)])
          message <- refusal (loadJsonl ingressNet "ended-impure-source" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "source occurrence 1", "ActivityRequested"]
      )
      terminals

  it "load refuses token consumption correlated to an ended source occurrence" $ withScratch $ \dir -> do
    let path = dir </> "ended-consuming-source.jsonl"
    engine <-
      createJsonl ingressNet "ended-consuming-source" path
        Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [tokD "Seed" (Int 1)])]}
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    let consumed =
          Object
            [ ("record", String "TokensConsumed")
            , ("schema", Int 5)
            , ("place", String "a")
            , ("tokens", Array [tokenJ "Seed" (Int 1)])
            , ("occurrence", Int 1)
            , ("entries", Array [])
            , ("scope", Null)
            , ("instant", Int 0)
            ]
    writeLines path (ls <> [enc consumed, enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "ended-consuming-source" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "source occurrence 1", "TokensConsumed"]

  it "load refuses production after an accepted delivery completed" $ withScratch $ \dir -> do
    let path = dir </> "production-after-delivery-completion.jsonl"
    engine <- createJsonl ingressNet "production-after-delivery-completion" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc production7, enc completedSrc1, enc production7])
    message <- refusal (loadJsonl ingressNet "production-after-delivery-completion" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "TokensProduced after FiringCompleted"]

  it "load refuses an accepted delivery completion effect before its acceptance" $ withScratch $ \dir -> do
    let path = dir </> "production-before-delivery-acceptance.jsonl"
    engine <- createJsonl ingressNet "production-before-delivery-acceptance" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    let (prefix, pair) = splitAt (length ls - 2) ls
    writeLines path (prefix <> [enc production7] <> pair <> [enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "production-before-delivery-acceptance" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "contains TokensProduced before its acceptance pair"]

  it "load refuses accepted delivery production outside the source output arcs" $ withScratch $ \dir -> do
    let path = dir </> "delivery-production-outside-output.jsonl"
    engine <- createJsonl ingressNet "delivery-production-outside-output" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc (producedJ "b" [tokenJ "X" (event 7)] (Int 1) [] Null 0), enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "delivery-production-outside-output" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "production on b", "output arc"]

  it "load refuses accepted delivery production with a color the output arc does not admit" $ withScratch $ \dir -> do
    let path = dir </> "delivery-production-wrong-color.jsonl"
        net = netOf [Place a (Just "Expected"), place b] [transition src, transition t] [arc src a, arc a t, arc t b]
    engine <- createJsonl net "delivery-production-wrong-color" path Engine.defaultEngineOptions
    _ <- accept engine src (tokD "Other" (event 7)) "event-7" Nothing
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc (producedJ "a" [tokenJ "Other" (event 7)] (Int 1) [] Null 0), enc completedSrc1])
    message <- refusal (loadJsonl net "delivery-production-wrong-color" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "production on a", "not admitted", "output arc"]

  it "load refuses a passthrough completion that omits its output" $ withScratch $ \dir -> do
    let path = dir </> "delivery-passthrough-output-omitted.jsonl"
    engine <- createJsonl ingressNet "delivery-passthrough-output-omitted" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc completedSrc1])
    malformed <- BS.readFile path
    message <- refusal (loadJsonl ingressNet "delivery-passthrough-output-omitted" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "default passthrough", "productions"]
    BS.readFile path `shouldReturn` malformed

  describe "load refuses a passthrough completion that substitutes its output" $
    mapM_
      ( \(label, acceptedData, substitutedData) -> it label $ withScratch $ \dir -> do
          let path = dir </> "delivery-passthrough-output-substituted.jsonl"
          engine <- createJsonl ingressNet "delivery-passthrough-output-substituted" path Engine.defaultEngineOptions
          _ <- accept engine src (tokD "X" acceptedData) "event-7" Nothing
          Engine.close engine
          ls <- readLines path
          writeLines path (ls <> [enc (producedJ "a" [tokenJ "X" substitutedData] (Int 1) [] Null 0), enc completedSrc1])
          malformed <- BS.readFile path
          message <- refusal (loadJsonl ingressNet "delivery-passthrough-output-substituted" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "default passthrough", "productions"]
          BS.readFile path `shouldReturn` malformed
      )
      [ ("object-value", event 7, event 8)
      , ("boolean-for-integer", Bool True, Int 1)
      , ("integer-for-float", Int 1, Float 1.0)
      , ("negative-for-positive-zero", Float (-0.0), Float 0.0)
      ]

  it "load refuses a passthrough completion with registration effects" $ withScratch $ \dir -> do
    let path = dir </> "delivery-passthrough-registration-effect.jsonl"
    engine <- createJsonl ingressNet "delivery-passthrough-registration-effect" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc production7, enc (registrationOpenedJ (String "forged") (Int 1)), enc completedSrc1])
    malformed <- BS.readFile path
    message <- refusal (loadJsonl ingressNet "delivery-passthrough-registration-effect" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "default passthrough", "delivery-registration effects"]
    BS.readFile path `shouldReturn` malformed

  it "load refuses a disordered accepted delivery completion batch" $ withScratch $ \dir -> do
    let path = dir </> "disordered-delivery-completion.jsonl"
    engine <- createJsonl ingressNet "disordered-delivery-completion" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc (registrationOpenedJ (String "secondary") (Int 1)), enc production7, enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "disordered-delivery-completion" path Engine.defaultEngineOptions)
    message
      `shouldMatchInOrder` ["replay divergence", "correlated delivery registration", "occurrence 1", "writer-valid completion batch"]

  it "load refuses accepted delivery production outside its lifecycle scope" $ withScratch $ \dir -> do
    let path = dir </> "delivery-production-wrong-scope.jsonl"
    engine <- createJsonl ingressNet "delivery-production-wrong-scope" path Engine.defaultEngineOptions
    scope <- Engine.openScope engine "draft"
    _ <- accept engine src event7 "event-7" (Just (ScopeGeneration scope))
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc production7, enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "delivery-production-wrong-scope" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "production on a", "scope None", "draft"]

  it "load refuses an accepted delivery completion batch split across instants" $ withScratch $ \dir -> do
    let path = dir </> "split-delivery-completion.jsonl"
    engine <- createJsonl ingressNet "split-delivery-completion" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc production7, enc (terminalJ "FiringCompleted" "src" (Int 1) 1 [])])
    message <- refusal (loadJsonl ingressNet "split-delivery-completion" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "completion batch changes instant from 0 to 1"]

  it "load refuses interleaved accepted delivery completion batches" $ withScratch $ \dir -> do
    let path = dir </> "interleaved-delivery-completions.jsonl"
    engine <- createJsonl ingressNet "interleaved-delivery-completions" path Engine.defaultEngineOptions
    _ <- accept engine src (tokD "X" (event 1)) "event-1" Nothing
    _ <- accept engine src (tokD "X" (event 2)) "event-2" Nothing
    Engine.close engine
    ls <- readLines path
    let productionOf n occurrence = producedJ "a" [tokenJ "X" (event n)] (Int occurrence) [] Null 0
        terminalOf occurrence = terminalJ "FiringCompleted" "src" (Int occurrence) 0 []
        forged = [productionOf 1 1, productionOf 2 2, terminalOf 1, terminalOf 2]
    writeLines path (ls <> map enc forged)
    message <- refusal (loadJsonl ingressNet "interleaved-delivery-completions" path Engine.defaultEngineOptions)
    message
      `shouldMatchInOrder` ["accepted delivery identity 'event-1'", "completion batch", "interrupted by TokensProduced", "occurrence 2"]

  it "load refuses a boolean accepted delivery production occurrence" $ withScratch $ \dir -> do
    let path = dir </> "boolean-delivery-production.jsonl"
    engine <- createJsonl ingressNet "boolean-delivery-production" path Engine.defaultEngineOptions
    acceptEvent7 engine
    Engine.close engine
    ls <- readLines path
    writeLines path (ls <> [enc (producedJ "a" [tokenJ "X" (event 7)] (Bool True) [] Null 0), enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "boolean-delivery-production" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["TokensProduced occurrence must be a positive integer"]

  describe "load refuses malformed registration effects in an accepted delivery completion" $
    mapM_
      ( \(label, occurrence, key, expected) -> it label $ withScratch $ \dir -> do
          let path = dir </> "malformed-delivery-registration.jsonl"
          engine <- createJsonl ingressNet "malformed-delivery-registration" path Engine.defaultEngineOptions
          acceptEvent7 engine
          Engine.close engine
          ls <- readLines path
          writeLines path (ls <> [enc (registrationOpenedJ key occurrence), enc completedSrc1])
          message <- refusal (loadJsonl ingressNet "malformed-delivery-registration" path Engine.defaultEngineOptions)
          message `shouldMatchInOrder` [expected]
      )
      [ ("True-secondary", Bool True, String "secondary", "DeliveryRegistrationOpened occurrence must be a positive integer")
      , ("1-", Int 1, String "", "DeliveryRegistrationOpened requires a non-empty string key")
      , ("1-7", Int 1, Int 7, "DeliveryRegistrationOpened requires a non-empty string key")
      ]

  it "load refuses noncontiguous scoped entry ids in an accepted delivery completion" $ withScratch $ \dir -> do
    let path = dir </> "noncontiguous-delivery-entries.jsonl"
    engine <- createJsonl ingressNet "noncontiguous-delivery-entries" path Engine.defaultEngineOptions
    scope <- Engine.openScope engine "draft"
    _ <- accept engine src event7 "event-7" (Just (ScopeGeneration scope))
    Engine.close engine
    ls <- readLines path
    let scoped = Object [("name", String "draft"), ("generation", Int 1)]
    writeLines path (ls <> [enc (producedJ "a" [tokenJ "X" (event 7)] (Int 1) [7] scoped 0), enc completedSrc1])
    message <- refusal (loadJsonl ingressNet "noncontiguous-delivery-entries" path Engine.defaultEngineOptions)
    message `shouldMatchInOrder` ["accepted delivery identity 'event-7'", "queue-entry identities (7,)", "expected (1,)"]

  it "completion targets only the accepted source occurrence" $ do
    let sourceOut = np "source_out"
        net =
          netOf
            [place a, place b, place sourceOut]
            [Transition t (Just (HandlerSymbol "work")) [] [], transition src]
            [arc a t, arc t b, arc src sourceOut]
    pool <- newInMemoryDispatch
    history <- inMemoryHistoryStore
    engine <-
      Engine.create net "targeted-completion" history (inMemoryDispatch pool)
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tokD "Work" (Int 3)])]
          , Engine.handlers = symbols [("work", workHandler)]
          }
    _ <- Engine.advance engine
    let delivered = tokD "Event" (Int 7)
    carrier <- accept engine src delivered "event-7" Nothing >>= accepted
    completed <- Engine.completeDelivery engine carrier
    (completed.transition, completed.occurrence) `shouldBe` (src, 2)
    Engine.marking engine `shouldReturn` markingFromList [(sourceOut, [delivered])]
    map (.occurrence) <$> Engine.inFlight engine `shouldReturn` [1]
    map fst <$> pending pool `shouldReturn` [1]
    recs <- Engine.records engine
    [r.occurrence | RFiringCompleted r <- recs] `shouldBe` [2]

  it "fresh completion neither reconciles nor advances unrelated work" $ withScratch $ \dir -> do
    let candidate = np "z"
        sourceOut = np "source_out"
        net =
          netOf
            [place a, place b, place c, place sourceOut]
            [ Transition t (Just (HandlerSymbol "work")) [] []
            , Transition candidate (Just (HandlerSymbol "candidate")) [] []
            , transition src
            ]
            [arc a t, arc t b, arc c candidate, arc candidate b, arc src sourceOut]
        path = dir </> "targeted-reconstruction.jsonl"
    candidateCalls <- newIORef (0 :: Int)
    let projectCandidate = PureHandler (\binding outs -> counting candidateCalls (\_ -> Right (handlerTokens [])) (binding, outs))
        handlers = symbols [("work", workHandler), ("candidate", projectCandidate)]
    created <-
      createJsonl net "targeted-reconstruction" path
        Engine.defaultEngineOptions
          { Engine.marking = markingFromList [(a, [tokD "Work" (Int 3)]), (c, [tokD "Candidate" (Int 4)])]
          , Engine.handlers = handlers
          }
    _ <- Engine.advance created
    let delivered = tokD "Event" (Int 7)
    original <- accept created src delivered "event-7" Nothing >>= accepted
    Engine.close created

    pool <- newInMemoryDispatch
    store <- openJsonlHistoryStore path
    loaded <- Engine.load net "targeted-reconstruction" store (inMemoryDispatch pool) Engine.defaultEngineOptions {Engine.handlers = handlers}
    reconstructed <- accept loaded src delivered "event-7" Nothing >>= accepted
    beforeCompletion <- Engine.records loaded
    completed <- Engine.completeDelivery loaded reconstructed
    reconstructed `shouldBe` original
    (completed.transition, completed.occurrence) `shouldBe` (src, 2)
    drop (length beforeCompletion) <$> Engine.records loaded
      `shouldReturn` [ RTokensProduced (TokensProduced sourceOut [delivered] 2 [] Nothing 0)
                     , RFiringCompleted (FiringCompleted src 2 0)
                     ]
    map (.occurrence) <$> Engine.inFlight loaded `shouldReturn` [1]
    pending pool `shouldReturn` []
    readIORef candidateCalls `shouldReturn` 0
    Engine.marking loaded `shouldReturn` markingFromList [(c, [tokD "Candidate" (Int 4)]), (sourceOut, [delivered])]

  it "exact redelivery reconstructs unfinished acceptance then acknowledges its end" $ do
    history <- inMemoryHistoryStore
    port <- memPort
    engine <- Engine.create ingressNet "redelivered-acceptance" history port Engine.defaultEngineOptions
    original <- accept engine src event7 "event-7" Nothing >>= accepted
    acceptedRecords <- recordsOf history
    reconstructed <- accept engine src event7 "event-7" Nothing >>= accepted
    reconstructed `shouldBe` original
    recordsOf history `shouldReturn` acceptedRecords
    _ <- Engine.completeDelivery engine reconstructed
    completedRecords <- recordsOf history
    acknowledged <- accept engine src event7 "event-7" Nothing
    acknowledged `shouldBe` DeliveryPrior (PriorAcknowledgement "event-7" (firingOccurrenceIdInt original.occurrence))
    recordsOf history `shouldReturn` completedRecords

  it "identity content collision fails before mutation" $ do
    history <- inMemoryHistoryStore
    port <- memPort
    engine <- Engine.create ingressNet "delivery-collision" history port Engine.defaultEngineOptions
    acceptEvent7 engine
    acceptedRecords <- recordsOf history
    message <- valueRefusal (accept engine src (tokD "X" (event 8)) "event-7" Nothing)
    message
      `shouldBe` "delivery identity conflict for 'event-7': recorded source NetPath('src'), scope None; attempted source NetPath('src'), scope None; canonical token content differs"
    recordsOf history `shouldReturn` acceptedRecords

  it "identity source collision names both addresses before mutation" $ do
    let otherSource = np "other_source"
        net = netOf [place a, place b] [transition src, transition otherSource] [arc src a, arc otherSource b]
    history <- inMemoryHistoryStore
    port <- memPort
    engine <- Engine.create net "source-collision" history port Engine.defaultEngineOptions
    acceptEvent7 engine
    acceptedRecords <- recordsOf history
    message <- valueRefusal (accept engine otherSource event7 "event-7" Nothing)
    message
      `shouldBe` "delivery identity conflict for 'event-7': recorded source NetPath('src'), scope None; attempted source NetPath('other_source'), scope None; canonical token content matches"
    recordsOf history `shouldReturn` acceptedRecords

  it "identity scope collision names both generations before mutation" $ do
    history <- inMemoryHistoryStore
    port <- memPort
    engine <- Engine.create ingressNet "scope-collision" history port Engine.defaultEngineOptions
    scope <- Engine.openScope engine "draft"
    _ <- accept engine src event7 "event-7" (Just (ScopeGeneration scope))
    acceptedRecords <- recordsOf history
    otherScope <- either (fail . T.unpack) pure (lifecycleScope "draft" 2)
    message <- valueRefusal (accept engine src event7 "event-7" (Just (ScopeGeneration otherScope)))
    message
      `shouldBe` "delivery identity conflict for 'event-7': recorded source NetPath('src'), scope LifecycleScope(name='draft', generation=1); attempted source NetPath('src'), scope LifecycleScope(name='draft', generation=2); canonical token content matches"
    recordsOf history `shouldReturn` acceptedRecords

  describe "identity content comparison preserves json scalar types" $
    mapM_
      ( \(label, acceptedData, collisionData) -> it label $ do
          history <- inMemoryHistoryStore
          port <- memPort
          engine <- Engine.create ingressNet "typed-delivery-content" history port Engine.defaultEngineOptions
          _ <- accept engine src (tokD "X" acceptedData) "event-7" Nothing
          acceptedRecords <- recordsOf history
          message <- valueRefusal (accept engine src (tokD "X" collisionData) "event-7" Nothing)
          message `shouldMatchInOrder` ["delivery identity conflict for 'event-7'", "token content differs"]
          recordsOf history `shouldReturn` acceptedRecords
      )
      [("True-1", Bool True, Int 1), ("1-1.0", Int 1, Float 1.0)]

  -- Haskell token data is immutable, so the caller cannot mutate it after
  -- acceptance; the reference's observable outcome is asserted as written.
  it "acceptance snapshots caller owned token data before mutation" $ do
    history <- inMemoryHistoryStore
    port <- memPort
    let callerData = Object [("items", Array [Int 1])]
    engine <- Engine.create ingressNet "snapshotted-delivery-content" history port Engine.defaultEngineOptions
    carrier <- accept engine src (tokD "X" callerData) "event-7" Nothing >>= accepted
    completed <- Engine.completeDelivery engine carrier
    recs <- recordsOf history
    [r.tokens | RExternalEventDelivered r <- recs] `shouldBe` [[tokD "X" callerData]]
    drop (length completed.records - 2) completed.records
      `shouldBe` [ RTokensProduced (TokensProduced a [tokD "X" callerData] 1 [] Nothing 0)
                 , RFiringCompleted (FiringCompleted src 1 0)
                 ]
    Engine.marking engine `shouldReturn` markingFromList [(a, [tokD "X" callerData])]

  -- The reference handler mutates the bound token in place; a Haskell
  -- handler can only produce a changed copy, which is the same observable
  -- projection.
  it "source projection cannot mutate the accepted delivery fact" $ withScratch $ \dir -> do
    let path = dir </> "handler-isolated-delivery.jsonl"
        mutate = PureHandler $ \binding _ ->
          Right (handlerTokens [(a, [Token tk.color (setMember "event" (Int 8) tk.payload) | tk <- bindingTokens binding])])
        net =
          netOf
            [place a, place b]
            [Transition src (Just (HandlerSymbol "mutate")) [] [], transition t]
            [arc src a, arc a t, arc t b]
        options = Engine.defaultEngineOptions {Engine.handlers = symbols [("mutate", mutate)]}
    engine <- createJsonl net "handler-isolated-delivery" path options
    carrier <- accept engine src event7 "event-7" Nothing >>= accepted
    completed <- Engine.completeDelivery engine carrier
    recs <- Engine.records engine
    take 1 [r.tokens | RExternalEventDelivered r <- recs] `shouldBe` [[event7]]
    completed.produced `shouldBe` [(a, tokD "X" (event 8))]
    accept engine src event7 "event-7" Nothing `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
    Engine.close engine

    loaded <- loadJsonl net "handler-isolated-delivery" path options
    durable <- Engine.records loaded
    take 1 [r.tokens | RExternalEventDelivered r <- durable] `shouldBe` [[event7]]
    accept loaded src event7 "event-7" Nothing `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
  where
    -- @class Work@: prepare names "work" with {"value": first token data};
    -- project deposits Token("Worked", result) on b.
    workHandler =
      ActivityBound
        ActivityHandler
          { prepare = \binding -> case bindingTokens binding of
              first : _ -> Right (invocation "work" (Object [("value", first.payload)]))
              [] -> Left "IndexError('tuple index out of range')"
          , project = \_ result -> Right (handlerTokens [(b, [tokD "Worked" result])])
          , projectFailure = Nothing
          }
