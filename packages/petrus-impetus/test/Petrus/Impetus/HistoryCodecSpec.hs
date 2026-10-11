-- | Parity: @tests/petrus/impetus/history_store/test_persistence.py@ — the
-- schema-5 record codec (@TestRecordCodec@), the line spelling the JSONL
-- tests pin byte for byte, the Instance's History-injection seam
-- (@TestInstanceDurableHistory@), and the appending doors' obligation that
-- a refused append moves nothing else (@TestARaisingAppendMovesNothingElse@).
--
-- The JSONL file mechanics (@DurableAppend@, loading, torn tails, line
-- numbers in load errors) belong to the durable backend, which lives in
-- another package. The durable seam runs here over 'newReopen', the
-- reference's reopen move over the kernel's own 'mirroredHistoryStore'.
--
-- @decode_record@ raises @ValueError@ or (for an argument mismatch)
-- @TypeError@; 'decodeRecord' returns 'Left' with the same text either way.
module Petrus.Impetus.HistoryCodecSpec (spec) where

import Control.Monad (foldM, forM_, when)
import Data.IORef
import Data.List (nub, sort)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory, jsonLine, newReopen)
import Petrus.Impetus.Binding
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.ReferenceCodec qualified as Reference
import Petrus.Impetus.Scope (LifecycleScope, lifecycleScope)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json
import System.IO.Error (ioeGetErrorString)
import Test.Hspec
import Test.QuickCheck

p, t :: NetPath
p = np "p"
t = np "t"

-- | @TOKEN = Token("issue", {"id": "goose", "passed": True})@.
issue :: Token
issue = tokD "issue" (Object [("id", String "goose"), ("passed", Bool True)])

-- | One index per 'Record' constructor. The match is exhaustive under
-- @-Werror -Wincomplete-patterns@, so a new kernel category fails to
-- compile here until 'everyRecordCategory' proves it — the reference's
-- @{type(r) for r in records} == set(get_args(Record))@.
category :: Record -> Int
category = \case
  RInstanceCreated _ -> 0
  RTokensInitialized _ -> 1
  RScopeOpened _ -> 2
  RScopeClosed _ -> 3
  RScopeReset _ -> 4
  RCandidateSelected _ -> 5
  RExternalEventDelivered _ -> 6
  RScopedDeliveryDropped _ -> 7
  RScopedDeliveryQuarantined _ -> 8
  RDeliveryRegistrationOpened _ -> 9
  RDeliveryRegistrationClosed _ -> 10
  RTimerMatured _ -> 11
  RFiringBegun _ -> 12
  RTokensConsumed _ -> 13
  RTokensRead _ -> 14
  RActivityRequested _ -> 15
  RActivityCompleted _ -> 16
  RActivityTerminalQuarantined _ -> 17
  RTokensProduced _ -> 18
  RFiringCompleted _ -> 19
  RActivityFailed _ -> 20
  RFiringFailed _ -> 21

-- | @json.loads(json.dumps(encode_record(record)))@, then decode: the round
-- trip across real JSON text.
throughText :: Record -> Either Text Record
throughText record = case jsonLine record of
  Left err -> Left ("unencodable: " <> T.pack (show err))
  Right line -> case parseJson pythonLoads (TE.encodeUtf8 line) of
    Left err -> Left ("unparsable: " <> T.pack err)
    Right payload -> decodeRecord payload

-- | @payload | {key: value}@: replace a member in place (or append it).
withMember :: Text -> Json -> Json -> Json
withMember key value = \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then value else v) | (k, v) <- members]
    | otherwise -> Object (members ++ [(key, value)])
  other -> other

-- | @{k: v for k, v in payload.items() if k != key}@.
withoutMember :: Text -> Json -> Json
withoutMember key = \case
  Object members -> Object [(k, v) | (k, v) <- members, k /= key]
  other -> other

-- | The canonical payload of some category, put through zero to three
-- random edits anywhere in its tree: members reordered, dropped,
-- duplicated, renamed, or added; array items reordered, dropped, or
-- duplicated; values swapped for numeric twins (@1@ / @1.0@ / @true@),
-- other categories' names, NaN, or other shapes.
mutatedPayload :: Gen Json
mutatedPayload = do
  record <- elements everyRecordCategory
  edits <- frequency [(1, pure 0), (4, choose (1, 3 :: Int))]
  foldM (\payload _ -> mutateSomewhere payload) (encodeRecord record) [1 .. edits]

mutateSomewhere :: Json -> Gen Json
mutateSomewhere = \case
  Object members
    | not (null members) ->
        frequency
          [ (2, mutateHere (Object members))
          , (3, Object <$> descend (\(k, v) -> (k,) <$> mutateSomewhere v) members)
          ]
  Array items
    | not (null items) ->
        frequency [(2, mutateHere (Array items)), (3, Array <$> descend mutateSomewhere items)]
  other -> mutateHere other
  where
    descend edit xs = do
      i <- choose (0, length xs - 1)
      x' <- edit (xs !! i)
      pure (take i xs ++ [x'] ++ drop (i + 1) xs)

mutateHere :: Json -> Gen Json
mutateHere = \case
  Object members ->
    oneof
      [ Object <$> shuffle members
      , Object <$> dropOne members
      , Object <$> duplicateOne members
      , (\k v -> Object (members ++ [(k, v)])) <$> elements keyPool <*> elements valuePool
      , (\k v -> Object ((k, v) : members)) <$> elements keyPool <*> elements valuePool
      , Object <$> renameOne members
      , elements valuePool
      ]
  Array items ->
    oneof [Array <$> shuffle items, Array <$> dropOne items, Array <$> duplicateOne items, elements valuePool]
  value -> frequency [(2, numericTwin value), (3, elements valuePool)]
  where
    dropOne xs
      | null xs = pure xs
      | otherwise = (\i -> take i xs ++ drop (i + 1) xs) <$> choose (0, length xs - 1)
    duplicateOne xs
      | null xs = pure xs
      | otherwise = (\i -> take (i + 1) xs ++ drop i xs) <$> choose (0, length xs - 1)
    renameOne xs
      | null xs = pure xs
      | otherwise = do
          i <- choose (0, length xs - 1)
          k <- elements keyPool
          pure (take i xs ++ [(k, snd (xs !! i))] ++ drop (i + 1) xs)
    numericTwin = \case
      Int i -> elements [Float (fromInteger i), Bool (i /= 0), Int (i + 1), String (T.pack (show i))]
      Float d -> elements [Int (truncate d), Float (d + 0.5), Float (0 / 0)]
      Bool b -> elements [Int (if b then 1 else 0), Float (if b then 1 else 0), Bool (not b)]
      String s -> elements [String (s <> "x"), String (T.toUpper s), String "", Null]
      _ -> elements valuePool
    keyPool =
      ["record", "schema", "instance", "name", "instant", "place", "tokens", "entries", "scope", "generation", "color", "data", "occurrence", "transition", "attempts", "extra"]
    valuePool =
      [ Null
      , Bool True
      , Bool False
      , Int 0
      , Int 1
      , Int 2
      , Int 5
      , Int (-1)
      , Float 0.5
      , Float 2
      , Float (0 / 0)
      , Float (1 / 0)
      , String ""
      , String "draft"
      , String "p"
      , Array []
      , Object []
      , Object [("name", String "draft"), ("generation", Int 1)]
      ]
        ++ [String (recordName r) | r <- everyRecordCategory]

draft ::Integer -> LifecycleScope
draft = either (error . show) id . lifecycleScope "draft"

firingBegunPayload :: Json -> Json
firingBegunPayload schema =
  Object [("record", String "FiringBegun"), ("schema", schema), ("transition", String "t"), ("occurrence", Int 1), ("instant", Int 0)]

expectOk :: (HasCallStack, Show e) => IO (Either e a) -> IO a
expectOk action = action >>= expectRight

recordsOf :: Instance -> IO [Record]
recordsOf = Store.records . instanceHistory

-- | @RefusingHistory@: a store whose commit fails on demand with the
-- reference's @OSError("disk full")@ (here an 'IOError').
refusingHistory :: IO (IORef Bool, HistoryStore)
refusingHistory = do
  refusing <- newIORef False
  store <- Store.mirroredHistoryStore Store.BackendOwned Seq.empty $ \_ batch -> do
    refuse <- readIORef refusing
    when refuse $ ioError (userError "disk full")
    pure (map (const Store.Entered) batch)
  pure (refusing, store)

diskFull :: IOError -> Bool
diskFull e = ioeGetErrorString e == "disk full"

spec :: Spec
spec = describe "History codec" $ do
  describe "record codec" $ do
    -- TestRecordCodec.test_every_record_category_round_trips_value_equal
    it "every record category round-trips value-equal" $ do
      sort (nub (map category everyRecordCategory)) `shouldBe` [0 .. 21]
      forM_ everyRecordCategory $ \record -> throughText record `shouldBe` Right record

    -- TestRecordCodec.test_the_ratified_wire_shape
    it "spells the ratified wire shape" $ do
      encodeRecord (RExternalEventDelivered (ExternalEventDelivered (np "net.in") [issue] "evt_123" 1 Nothing 3))
        `shouldBe` Object
          [ ("record", String "ExternalEventDelivered")
          , ("schema", Int 5)
          , ("source", String "net.in")
          , ("tokens", Array [Object [("color", String "issue"), ("data", Object [("id", String "goose"), ("passed", Bool True)])]])
          , ("identity", String "evt_123")
          , ("occurrence", Int 1)
          , ("scope", Null)
          , ("instant", Int 3)
          ]
      let blackMovement name =
            Object
              [ ("record", String name)
              , ("schema", Int 5)
              , ("place", String "p")
              , ("tokens", Array [Object [("color", Null), ("data", Null)]])
              , ("occurrence", Int 2)
              , ("entries", Array [])
              , ("scope", Null)
              , ("instant", Int 2)
              ]
      encodeRecord (RTokensConsumed (TokensConsumed p [black] 2 [] Nothing 2)) `shouldBe` blackMovement "TokensConsumed"
      encodeRecord (RTokensRead (TokensRead p [black] 2 [] Nothing 2)) `shouldBe` blackMovement "TokensRead"
      encodeRecord (RCandidateSelected (CandidateSelected t 2 2))
        `shouldBe` Object
          [("record", String "CandidateSelected"), ("schema", Int 5), ("transition", String "t"), ("occurrence", Int 2), ("instant", Int 2)]
      encodeRecord (RDeliveryRegistrationOpened (DeliveryRegistrationOpened t "default" Nothing 0))
        `shouldBe` Object
          [ ("record", String "DeliveryRegistrationOpened")
          , ("schema", Int 5)
          , ("source", String "t")
          , ("key", String "default")
          , ("occurrence", Null)
          , ("instant", Int 0)
          ]
      let requested = [r | RActivityRequested r <- everyRecordCategory]
      forM_ requested $ \r ->
        encodeRecord (RActivityRequested (ActivityRequested r.transition r.activity r.input r.policy r.correlation "key-9" r.occurrence r.scope r.instant))
          `shouldBe` Object
            [ ("record", String "ActivityRequested")
            , ("schema", Int 5)
            , ("transition", String "t")
            , ("activity", String "charge_card")
            , ("input", Object [("amount", Int 100)])
            ,
              ( "policy"
              , Object
                  [ ("attempts", Int 2)
                  , ("heartbeat_timeout", Int 45)
                  , ("initial_interval", Int 0)
                  , ("coefficient", Int 2)
                  , ("max_interval", Int 60)
                  , ("jitter", Int 0)
                  , ("start_to_close", Null)
                  , ("schedule_to_close", Null)
                  ]
              )
            , ("correlation", String "order-77")
            , ("idempotency", String "key-9")
            , ("occurrence", Int 2)
            , ("scope", Null)
            , ("instant", Int 3)
            ]
      encodeRecord (RActivityCompleted (ActivityCompleted t (Object [("status", String "declined")]) 2 4))
        `shouldBe` Object
          [ ("record", String "ActivityCompleted")
          , ("schema", Int 5)
          , ("transition", String "t")
          , ("result", Object [("status", String "declined")])
          , ("occurrence", Int 2)
          , ("instant", Int 4)
          ]

    -- TestRecordCodec.test_schema_5_is_the_only_current_record_spelling
    it "schema 5 is the only current record spelling" $ do
      let scoped = RTokensProduced (TokensProduced p [issue] 2 [17] (Just (draft 3)) 4)
      encodeRecord scoped
        `shouldBe` Object
          [ ("record", String "TokensProduced")
          , ("schema", Int 5)
          , ("place", String "p")
          , ("tokens", Array [Object [("color", String "issue"), ("data", Object [("id", String "goose"), ("passed", Bool True)])]])
          , ("occurrence", Int 2)
          , ("entries", Array [Int 17])
          , ("scope", Object [("name", String "draft"), ("generation", Int 3)])
          , ("instant", Int 4)
          ]
      decodeRecord (encodeRecord scoped) `shouldBe` Right scoped
      schemaVersion `shouldBe` 5
      decodeRecord (withMember "schema" (Int 4) (encodeRecord scoped))
        `shouldFailWith` "cannot decode event history record 'TokensProduced': 'schema' is 4, and this kernel reads schema 5 only — no migration or converter exists"
      let ordinary = RTokensProduced (TokensProduced p [] 2 [] Nothing 0)
      decodeRecord (encodeRecord ordinary) `shouldBe` Right ordinary

    -- TestRecordCodec.test_schema_5_refuses_partial_or_invalid_scope_provenance
    -- (the True and "3" generations and the name 3 are spelled as JSON
    -- values, which decode refuses as the reference does)
    it "schema 5 refuses partial or invalid scope provenance" $ do
      let payload = encodeRecord (RTokensProduced (TokensProduced p [issue] 2 [17] (Just (draft 3)) 4))
      decodeRecord (withoutMember "entries" payload)
        `shouldFailWith` "TokensProduced scoped movements require one queue-entry identity per token"
      decodeRecord (withoutMember "scope" payload)
        `shouldFailWith` "TokensProduced queue-entry identities require lifecycle scope provenance"
      forM_ [Int 0, Int (-1), Bool True, String "3"] $ \generation ->
        decodeRecord (withMember "scope" (Object [("name", String "draft"), ("generation", generation)]) payload)
          `shouldFailWith` "LifecycleScope generation must be a positive integer of the exact built-in type"
      forM_ [String "", String "bad\0name", Int 3] $ \name ->
        decodeRecord (withMember "scope" (Object [("name", name), ("generation", Int 3)]) payload)
          `shouldFailWith` "LifecycleScope name must be a non-empty string without NUL and use the exact built-in type"

    -- not translated: TestRecordCodec.test_token_data_must_be_json_faithful_to_round_trip
    -- (enforced by types: token data is Json, which has no tuple to read
    -- back as a list).

    -- TestRecordCodec.test_an_unknown_record_name_fails_loud
    it "an unknown record name fails loud" $
      decodeRecord (Object [("record", String "Bogus"), ("schema", Int 5), ("instant", Int 0)])
        `shouldFailWith` "cannot decode event history record: unknown 'record' discriminator 'Bogus' — not a record type the kernel emits"

    -- TestRecordCodec.test_a_payload_without_a_discriminator_fails_loud
    it "a payload without a discriminator fails loud" $
      decodeRecord (Object [("transition", String "t"), ("instant", Int 0)])
        `shouldFailWith` "cannot decode event history record: payload has no 'record' discriminator"

    -- TestRecordCodec.test_field_drift_fails_as_the_record_types_own_rejection
    it "field drift fails as the record type's own rejection" $
      decodeRecord
        ( Object
            [ ("record", String "FiringBegun")
            , ("schema", Int 5)
            , ("transition", String "t")
            , ("occurrence", Int 1)
            , ("scope", Null)
            , ("instant", Int 0)
            , ("stray", Int 1)
            ]
        )
        `shouldFailWith` "FiringBegun.__init__() got an unexpected keyword argument 'stray'"

    describe "test_schema_5_activity_request_refuses_noncanonical_policy_shapes" $ do
      let payload policy =
            Object
              [ ("record", String "ActivityRequested")
              , ("schema", Int 5)
              , ("transition", String "t")
              , ("activity", String "work")
              , ("input", Null)
              , ("policy", policy)
              , ("correlation", String "c")
              , ("idempotency", String "i")
              , ("occurrence", Int 1)
              , ("scope", Null)
              , ("instant", Int 0)
              ]
          refused policy repr =
            decodeRecord (payload policy)
              `shouldFailWith` ("cannot decode ExecutionPolicy: policy must be exactly the current exact policy fields, got " <> repr)
      -- test_schema_5_activity_request_refuses_noncanonical_policy_shapes[policy0]
      it "refuses a policy missing fields" $
        refused (Object [("attempts", Int 2)]) "{'attempts': 2}"
      -- test_schema_5_activity_request_refuses_noncanonical_policy_shapes[policy1]
      it "refuses a policy with an extra field" $
        refused
          (Object [("attempts", Int 2), ("heartbeat_timeout", Int 30), ("extra", Bool True)])
          "{'attempts': 2, 'heartbeat_timeout': 30, 'extra': True}"
      -- test_schema_5_activity_request_refuses_noncanonical_policy_shapes[policy2]
      it "refuses a boolean attempts" $
        refused (Object [("attempts", Bool True), ("heartbeat_timeout", Int 30)]) "{'attempts': True, 'heartbeat_timeout': 30}"
      -- test_schema_5_activity_request_refuses_noncanonical_policy_shapes[policy3]
      it "refuses a string heartbeat timeout" $
        refused (Object [("attempts", Int 2), ("heartbeat_timeout", String "30")]) "{'attempts': 2, 'heartbeat_timeout': '30'}"

    -- TestRecordCodec.test_a_delivery_identity_must_be_a_non_empty_string_to_decode
    it "a delivery identity must be a non-empty string to decode" $
      forM_ [(String "", "''"), (Int 7, "7")] $ \(bad, repr) ->
        decodeRecord
          ( Object
              [ ("record", String "ExternalEventDelivered")
              , ("schema", Int 5)
              , ("source", String "t")
              , ("tokens", Array [])
              , ("identity", bad)
              , ("occurrence", Int 1)
              , ("scope", Null)
              , ("instant", Int 0)
              ]
          )
          `shouldFailWith` ("ExternalEventDelivered requires an exact non-empty string identity, got " <> repr)

    -- TestRecordCodec.test_a_payload_without_a_schema_version_fails_naming_the_migration
    it "a payload without a schema version fails naming the migration" $
      decodeRecord (Object [("record", String "FiringBegun"), ("transition", String "t"), ("occurrence", Int 1), ("instant", Int 0)])
        `shouldFailWith` "cannot decode event history record 'FiringBegun': payload has no 'schema' version — this kernel writes schema 5, reads schema 5 only, and has no converter for older durable data"

    -- TestRecordCodec.test_a_wrong_schema_version_fails_naming_the_migration
    it "a wrong schema version fails naming the migration" $
      forM_ [(Int 1, "1"), (Bool True, "True"), (Float 5.0, "5.0"), (String "5", "'5'")] $ \(schema, repr) ->
        decodeRecord (firingBegunPayload schema)
          `shouldFailWith` ( "cannot decode event history record 'FiringBegun': 'schema' is "
                               <> repr
                               <> ", and this kernel reads schema 5 only — no migration or converter exists"
                           )

    -- TestRecordCodec.test_schema_2_is_refused_before_record_interpretation
    -- TestRecordCodec.test_schema_3_is_refused_before_record_interpretation
    forM_ [2, 3 :: Integer] $ \version ->
      it ("schema " <> show version <> " is refused before record interpretation") $
        decodeRecord
          (Object [("record", String "FiringBegun"), ("schema", Int version), ("not", String "the schema-5 fields")])
          `shouldFailWith` ( "cannot decode event history record 'FiringBegun': 'schema' is "
                               <> T.pack (show version)
                               <> ", and this kernel reads schema 5 only — no migration or converter exists"
                           )

    -- TestRecordCodec.test_unversioned_old_discriminators_are_refused_before_interpretation
    it "unversioned old discriminators are refused before interpretation" $
      forM_ ["RegistrationOpened", "RegistrationClosed", "ExternalEventRecorded"] $ \old ->
        decodeRecord (Object [("record", String old), ("source", String "t"), ("key", String "default"), ("attempt", Null)])
          `shouldFailWith` ( "cannot decode event history record '"
                               <> old
                               <> "': payload has no 'schema' version — this kernel writes schema 5, reads schema 5 only, and has no converter for older durable data"
                           )

    describe "properties" $ do
      -- Not upstream (no Hypothesis there): the codec is a bijection on the
      -- canonical spelling for arbitrary token payloads and positions, and a
      -- decoded payload re-encodes to itself.
      it "round-trips arbitrary movement records through JSON text (property)" $
        property $ \(Positive occurrence) (n :: Int) (labels :: [Bool]) (NonNegative instant) ->
          let tokens = [if l then tokD "X" (Object [("n", Int (toInteger n))]) else black | l <- labels]
              record = RTokensProduced (TokensProduced p tokens occurrence [] Nothing (IntNumber instant))
           in throughText record === Right record
      -- Not upstream: the accessors are total matches; the wire fields are
      -- their oracle.
      it "recordInstant and recordOccurrence read every category's wire fields" $
        forM_ everyRecordCategory $ \record -> do
          [i | ("instant", FNumber i) <- recordFields record] `shouldBe` [recordInstant record]
          concat [maybe [] pure o | ("occurrence", FOccurrence o) <- recordFields record]
            `shouldBe` maybe [] pure (recordOccurrence record)
      it "every decoded category re-encodes to its payload (property)" $
        property $ forAll (elements everyRecordCategory) $ \record ->
          fmap encodeRecord (decodeRecord (encodeRecord record)) === Right (encodeRecord record)
      -- Not upstream: 'decodeRecord' was optimized (per-layout converters,
      -- a member-by-member canonical check that falls back to the full
      -- mapping comparison). The pre-optimization codec is kept as an
      -- oracle; on canonical and mutated payloads alike, both must accept
      -- the same record or refuse with the same text.
      it "decodes every mutated payload exactly as the pre-optimization codec (property)" $
        withNumTests 20000 $
          forAll mutatedPayload $ \payload ->
            counterexample (show payload) $
              case (decodeRecord payload, Reference.decodeRecord payload) of
                (Left err, Left err') -> err === err'
                (Right record, Right record') ->
                  counterexample "decoded records differ" (exactEq (encodeRecord record) (encodeRecord record'))
                (outcome, outcome') ->
                  counterexample (show (fmap encodeRecord outcome) <> " /= " <> show (fmap encodeRecord outcome')) False

  describe "durable line spelling" $ do
    -- TestJsonlHistoryStore.test_the_durable_spelling_is_byte_stable (the
    -- line spelling, both directions; the file itself is the JSONL
    -- backend's)
    it "the durable spelling is byte-stable" $ do
      let fixture =
            [ "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"p\", \"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \"instant\": 0, \"entries\": [], \"scope\": null}"
            , "{\"record\": \"CandidateSelected\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 2}"
            ]
          records' =
            [ RTokensInitialized (TokensInitialized p [issue] 0 [] Nothing)
            , RCandidateSelected (CandidateSelected t 1 2)
            ]
      mapM jsonLine records' `shouldBe` Right fixture
      mapM (either (Left . show) (either (Left . show) Right . decodeRecord) . parseJson pythonLoads . TE.encodeUtf8) fixture
        `shouldBe` Right records'

    -- TestJsonlHistoryStore.test_direct_firing_lifecycle_jsonl_bytes_are_stable
    it "the direct firing lifecycle's lines are byte-stable" $ do
      let consumedPlace = np "consume"
          observed = np "read"
          producedPlace = np "produced"
          net =
            netOf
              [place consumedPlace, place observed, place producedPlace]
              [transition t]
              [arc consumedPlace t, (arc observed t) {mode = Read}, arc t producedPlace]
          fixture =
            [ "{\"record\": \"InstanceCreated\", \"schema\": 5, \"instance\": \"fixture-instance\", \"name\": null, \"instant\": 1}"
            , "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"consume\", \"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \"instant\": 1, \"entries\": [], \"scope\": null}"
            , "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"read\", \"tokens\": [{\"color\": null, \"data\": null}], \"instant\": 1, \"entries\": [], \"scope\": null}"
            , "{\"record\": \"CandidateSelected\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 2}"
            , "{\"record\": \"FiringBegun\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"scope\": null, \"instant\": 2}"
            , "{\"record\": \"TokensConsumed\", \"schema\": 5, \"place\": \"consume\", \"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 2}"
            , "{\"record\": \"TokensRead\", \"schema\": 5, \"place\": \"read\", \"tokens\": [{\"color\": null, \"data\": null}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 2}"
            , "{\"record\": \"TokensProduced\", \"schema\": 5, \"place\": \"produced\", \"tokens\": [{\"color\": \"result\", \"data\": {\"fixed\": true}}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 3}"
            , "{\"record\": \"FiringCompleted\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 3}"
            ]
      reopen <- newReopen
      history <- reopen
      inst <-
        expectOk
          ( newInstance
              net
              defaultInstanceConfig
                { initialMarking = markingFromList [(consumedPlace, [issue]), (observed, [black])]
                , constructionInstant = 1
                , historyStore = Just history
                , suppliedIdentity = Just "fixture-instance"
                }
          )
      (b : _) <- candidates inst
      occurrence <- expectOk (begin inst b (Just 2))
      _ <- expectOk (complete inst occurrence (Just (handlerTokens [(producedPlace, [tokD "result" (Object [("fixed", Bool True)])])])) (Just 3))
      recorded <- recordsOf inst
      mapM jsonLine recorded `shouldBe` Right fixture
      (reopen >>= Store.records) `shouldReturn` recorded

  describe "Instance over an injected history" $ do
    let source = np "intake"
        done = np "done"
        forward = np "forward"
        out = np "out"
        net = netOf [place done, place out] [transition source, transition forward] [arc source done, arc done forward, arc forward out]
        over store = defaultInstanceConfig {historyStore = Just store}

    -- TestInstanceDurableHistory.test_construction_records_are_durable_at_construction
    it "construction records are durable at construction" $ do
      reopen <- newReopen
      inst <- reopen >>= expectOk . newInstance net . over
      durable <- reopen >>= Store.records
      durable `shouldContain` [RDeliveryRegistrationOpened (DeliveryRegistrationOpened source "default" Nothing 0)]
      recordsOf inst `shouldReturn` durable

    -- TestInstanceDurableHistory.test_every_appending_door_writes_through
    it "every appending door writes through" $ do
      reopen <- newReopen
      inst <- reopen >>= expectOk . newInstance net . over
      DeliveryAccepted accepted <- expectOk (acceptDelivery inst source [black] "durable-event" Nothing Nothing)
      _ <- expectOk (completeDelivery inst accepted Nothing)
      _ <- expectOk (run inst)
      expectOk (seal inst source Nothing)
      durable <- reopen >>= Store.records
      recordsOf inst `shouldReturn` durable
      [() | RExternalEventDelivered _ <- durable] `shouldNotBe` []
      [() | RCandidateSelected _ <- durable] `shouldNotBe` []
      [() | RDeliveryRegistrationClosed _ <- durable] `shouldNotBe` []
      marking inst `shouldReturn` markingFromList [(out, [black])]

    -- TestInstanceDurableHistory.test_a_refused_delivery_payload_leaves_the_instance_unchanged
    -- (a NaN payload stands in for the reference's object(): it is the one
    -- Json value with no strict-JSON spelling)
    it "a refused delivery payload leaves the instance unchanged" $ do
      reopen <- newReopen
      inst <- reopen >>= expectOk . newInstance net . over
      constructed <- recordsOf inst
      Left (Refused message) <- acceptDelivery inst source [tokD "bad" (Float (0 / 0))] "invalid-event" Nothing (Just 7)
      message
        `shouldBe` "delivery to intake: token 1 has invalid data: the payload must be JSON-faithful — objects, arrays, strings, numbers, booleans, null — and never net state; Out of range float values are not JSON compliant: nan"
      recordsOf inst `shouldReturn` constructed
      (reopen >>= Store.records) `shouldReturn` constructed
      watermark inst `shouldReturn` 0
      marking inst `shouldReturn` emptyMarking
      inFlight inst `shouldReturn` []
      DeliveryAccepted accepted <- expectOk (acceptDelivery inst source [black] "valid-event" Nothing (Just 7))
      outcome <- expectOk (completeDelivery inst accepted (Just 7))
      outcome.occurrence `shouldBe` 1
      watermark inst `shouldReturn` 7

    -- TestInstanceDurableHistory.test_a_recorded_history_is_rejected_at_construction
    it "a recorded history is rejected at construction" $ do
      reopen <- newReopen
      _ <- reopen >>= expectOk . newInstance net . over
      Left (Refused message) <- reopen >>= newInstance net . over
      message
        `shouldBe` "cannot construct an Instance over a recorded history (2 records): construction appends the instance's initial records; a recorded history is for resume()"
      recorded <- Store.inMemoryHistoryStore
      Store.append recorded (RTokensInitialized (TokensInitialized p [issue] 0 [] Nothing))
      Left (Refused message') <- newInstance net (over recorded)
      message'
        `shouldBe` "cannot construct an Instance over a recorded history (1 records): construction appends the instance's initial records; a recorded history is for resume()"

  describe "a raising append moves nothing else" $ do
    -- TestARaisingAppendMovesNothingElse.test_a_refused_seal_keeps_the_registration_armed
    it "a refused seal keeps the registration armed" $ do
      let source = np "intake"
          done = np "done"
          net = netOf [place done] [transition source] [arc source done]
      (refusing, history) <- refusingHistory
      inst <- expectOk (newInstance net defaultInstanceConfig {historyStore = Just history})
      writeIORef refusing True
      seal inst source (Just 5) `shouldThrow` diskFull
      watermark inst `shouldReturn` 0
      writeIORef refusing False
      DeliveryAccepted accepted <- expectOk (acceptDelivery inst source [black] "after-refused-seal" Nothing Nothing)
      -- still armed: the failed seal closed nothing
      _ <- expectOk (completeDelivery inst accepted Nothing)
      expectOk (seal inst source Nothing)
      Left (Refused message) <- acceptDelivery inst source [black] "after-seal" Nothing Nothing
      message `shouldBe` "cannot deliver to source transition intake: no armed delivery registration"

    -- TestARaisingAppendMovesNothingElse.test_a_refused_complete_leaves_the_occurrence_in_flight
    it "a refused complete leaves the occurrence in flight" $ do
      let start = np "start"
          work = np "work"
          out = np "out"
          net = netOf [place start, place out] [transition work] [arc start work, arc work out]
      (refusing, history) <- refusingHistory
      inst <- expectOk (newInstance net defaultInstanceConfig {historyStore = Just history, initialMarking = fromCounts [(start, 1)]})
      (b : _) <- candidates inst
      occurrence <- expectOk (begin inst b (Just 3))
      let result = Just (handlerTokens [(out, bindingTokens occurrence.binding)])
      writeIORef refusing True
      complete inst occurrence result (Just 9) `shouldThrow` diskFull
      -- begin's commit stands (tokens accounted, watermark at 3); the failed
      -- completion's does not.
      inFlight inst `shouldReturn` [occurrence]
      watermark inst `shouldReturn` 3
      marking inst `shouldReturn` emptyMarking
      writeIORef refusing False
      firing <- expectOk (complete inst occurrence result (Just 9))
      firing.occurrence `shouldBe` occurrence.occurrence
      marking inst `shouldReturn` markingFromList [(out, [black])]
      watermark inst `shouldReturn` 9
