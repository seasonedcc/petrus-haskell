-- | The Impetus-native golden trace corpus: a port of the reference's
-- @scripts/gen-golden-traces.py@.
--
-- The corpus (@spec/traces/*.json@ plus @manifest.json@) is the
-- language-neutral record of eight small scenarios driven through the public
-- Net, Instance, Net-definition, and History codec APIs. This module rebuilds
-- every fixture from the same scenarios through the Haskell kernel and writes
-- it with the reference's exact spelling (@json.dumps(..., ensure_ascii=False,
-- allow_nan=False, indent=2, sort_keys=True)@ plus a newline), so the bytes —
-- and the manifest's SHA-256 digests — are identical. The scenarios' named
-- guards and handler ('goldenGuards', 'goldenHandlers') are the Haskell twins
-- of the reference's; 'bindingSpecs' carries their normative prose.
module Petrus.Impetus.GoldenTraces
  ( -- * Scenarios
    Scenario (..)
  , scenarios
  , goldenGuards
  , goldenHandlers
  , bindingSpecs
  , declaredSymbols

    -- * Generation
  , generateFixture
  , renderTrace
  , GoldenFile (..)
  , generateCorpus
  , manifestFor
  , sha256Hex

    -- * Constants
  , traceFormat
  , traceVersion
  , generationCommand

    -- * Shared encodings
  , encodeToken
  , decodeToken
  , encodeBinding
  , encodeMarking
  , encodeOutcome
  , instantJson
  , jsonInstant
  ) where

import Control.Monad (forM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Impetus.Binding (BoundHandler (..), Handler, handlerTokens)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.NetDefinition (compileNetDefinition, netDefinitionToJson, projectNetDefinition)
import Petrus.Impetus.Petrinet hiding (candidates, nextMaturation)
import Petrus.Json

-- | @FORMAT@.
traceFormat :: Text
traceFormat = "petrus-impetus-golden-trace"

-- | @VERSION@.
traceVersion :: Integer
traceVersion = 2

-- | @GENERATION_COMMAND@: the reference's command, recorded verbatim in the
-- manifest so the regenerated manifest is byte-identical.
generationCommand :: Text
generationCommand = "UV_FROZEN=1 uv run python scripts/gen-golden-traces.py spec/traces"

-- | One scenario: the net, its initial marking, and the scripted actions
-- (kept as the JSON objects the fixture records verbatim).
data Scenario = Scenario
  { name :: Text
  , description :: Text
  , net :: Net
  , initial :: Marking
  , actions :: [Json]
  }

-- ---------------------------------------------------------------------------
-- Named implementations

-- | The first peeked token's @data["amount"]@; a missing key or a non-object
-- payload is the guard raising, which the kernel reports as not satisfied.
firstAmount :: Binding -> Either Text Json
firstAmount b = case bindingPeeked b of
  t : _ | Just amount <- lookupMember "amount" t.payload -> Right amount
  _ -> Left "KeyError('amount')"

compareAmount :: (Number -> Bool) -> Guard
compareAmount holds b =
  firstAmount b >>= \case
    Int n -> Right (holds (IntNumber n))
    Float d -> Right (holds (FloatNumber d))
    other -> Left ("TypeError: amount is " <> jsonTypeName other)

-- | @amount_gte_100@ and @amount_lt_100@.
goldenGuards :: Map Text Guard
goldenGuards =
  Map.fromList
    [ ("amount_gte_100", compareAmount (>= 100))
    , ("amount_lt_100", compareAmount (< 100))
    ]

-- | @settle@: the single consumed Payment becomes an ApprovalNotice and a
-- LedgerEntry carrying its amount.
settle :: Handler
settle b _ = case bindingTokens b of
  [payment]
    | Just amount <- lookupMember "amount" payment.payload ->
        Right
          ( handlerTokens
              [ (p "approved", [Token (Just "ApprovalNotice") (Object [("approved", Bool True)])])
              , (p "ledger", [Token (Just "LedgerEntry") (Object [("amount", amount)])])
              ]
          )
    | otherwise -> Left "KeyError('amount')"
  tokens -> Left ("ValueError('too many values to unpack (expected 1, got " <> T.pack (show (length tokens)) <> ")')")

goldenHandlers :: Map Text Handler
goldenHandlers = Map.fromList [("settle", settle)]

-- | @BINDING_SPECS@: the normative prose for each named implementation.
bindingSpecs :: Map Text Json
bindingSpecs =
  Map.fromList
    [ ("amount_gte_100", spec' "guard" "the first peeked Payment token's data.amount is greater than or equal to 100")
    , ("amount_lt_100", spec' "guard" "the first peeked Payment token's data.amount is less than 100")
    ,
      ( "settle"
      , spec'
          "handler"
          "for the consumed Payment, emit ApprovalNotice {approved: true} to approved and LedgerEntry {amount: Payment.data.amount} to ledger"
      )
    ]
  where
    spec' kind semantics = Object [("kind", String kind), ("semantics", String semantics)]

-- | The symbol guards and handlers a net declares (inline CEL excluded).
declaredSymbols :: Net -> Set.Set Text
declaredSymbols n =
  Set.fromList $
    concat
      [ [s | GuardSymbol s <- t.guards] <> [s | Just (HandlerSymbol s) <- [t.handler]]
      | t <- Map.elems (netTransitions n)
      ]

-- ---------------------------------------------------------------------------
-- Scenarios

p :: Text -> NetPath
p = either (error . T.unpack) id . netPath

named :: Text -> [Place] -> [Transition] -> [Arc] -> Net
named title ps ts as = either (error . T.unpack) id (mkNet (NetSpec ps ts as Nothing (Just title)))

item :: Text -> [(Text, Json)] -> Token
item c fields = Token (Just c) (Object fields)

stepAt :: Integer -> Json
stepAt at = Object [("kind", String "step"), ("at", Int at)]

-- | @SCENARIOS@, in the reference's order.
scenarios :: [Scenario]
scenarios =
  [ Scenario
      { name = "passthrough_chain"
      , description = "A black control token traverses two default passthrough transitions."
      , net =
          named
            "passthrough-chain"
            (map (place . p) ["start", "middle", "done"])
            [transition (p "advance"), transition (p "finish")]
            [arc (p "start") (p "advance"), arc (p "advance") (p "middle"), arc (p "middle") (p "finish"), arc (p "finish") (p "done")]
      , initial = markingFromList [(p "start", [black])]
      , actions = [stepAt 1, stepAt 2]
      }
  , Scenario
      { name = "fifo_queue"
      , description = "Three equal-color values leave one place in FIFO order."
      , net =
          named
            "fifo-queue"
            [coloredPlace (p "queue") "Item", coloredPlace (p "taken") "Item"]
            [transition (p "take")]
            [arc (p "queue") (p "take"), arc (p "take") (p "taken")]
      , initial = markingFromList [(p "queue", [item "Item" [("seq", Int n)] | n <- [1, 2, 3]])]
      , actions = map stepAt [1, 2, 3]
      }
  , Scenario
      { name = "inhibitor_arc"
      , description = "An inhibitor blocks proceed until drain removes the blocking token."
      , net =
          named
            "inhibitor-arc"
            (map (place . p) ["ready", "blocked", "drained", "done"])
            [transition (p "drain"), transition (p "proceed")]
            [ arc (p "blocked") (p "drain")
            , arc (p "drain") (p "drained")
            , arc (p "ready") (p "proceed")
            , (arc (p "blocked") (p "proceed")) {mode = Inhibit}
            , arc (p "proceed") (p "done")
            ]
      , initial = markingFromList [(p "ready", [black]), (p "blocked", [black])]
      , actions = [stepAt 1, stepAt 2]
      }
  , Scenario
      { name = "conflict_selection"
      , description = "Two candidates conflict over one token; conservative selection chooses the first stable binding."
      , net =
          named
            "conflict-selection"
            (map (place . p) ["shared", "a_won", "b_won"])
            [transition (p "choose_a"), transition (p "choose_b")]
            [arc (p "shared") (p "choose_a"), arc (p "choose_a") (p "a_won"), arc (p "shared") (p "choose_b"), arc (p "choose_b") (p "b_won")]
      , initial = markingFromList [(p "shared", [black])]
      , actions = [stepAt 1]
      }
  , Scenario
      { name = "per_arc_passthrough"
      , description =
          "A weight-two consume forwards each X independently through each admitting output arc; "
            <> "the read Config remains in place and contributes no output."
      , net =
          named
            "per-arc-passthrough"
            [coloredPlace (p "input") "X", coloredPlace (p "config") "Config", coloredPlace (p "left") "X", coloredPlace (p "right") "X"]
            [transition (p "fanout")]
            [ (arc (p "input") (p "fanout")) {weight = 2}
            , (arc (p "config") (p "fanout")) {mode = Read}
            , arc (p "fanout") (p "left")
            , arc (p "fanout") (p "right")
            ]
      , initial =
          markingFromList
            [ (p "input", [item "X" [("n", Int 1)], item "X" [("n", Int 2)]])
            , (p "config", [item "Config" [("mode", String "strict")]])
            ]
      , actions = [stepAt 1]
      }
  , Scenario
      { name = "guard_enumeration"
      , description =
          "Guards evaluate every binding: reject skips the failing FIFO head and remains enabled for the deeper Payment."
      , net =
          named
            "guard-enumeration"
            [coloredPlace (p "pending") "Payment", coloredPlace (p "accepted") "Payment", coloredPlace (p "rejected") "Payment"]
            [ Transition (p "accept") Nothing [GuardSymbol "amount_gte_100"] []
            , Transition (p "reject") Nothing [GuardSymbol "amount_lt_100"] []
            ]
            [arc (p "pending") (p "accept"), arc (p "accept") (p "accepted"), arc (p "pending") (p "reject"), arc (p "reject") (p "rejected")]
      , initial =
          markingFromList
            [ ( p "pending"
              , [ item "Payment" [("amount", Int 150), ("currency", String "USD")]
                , item "Payment" [("amount", Int 40), ("currency", String "USD")]
                ]
              )
            ]
      , actions = [stepAt 1, stepAt 2]
      }
  , Scenario
      { name = "source_delivery"
      , description = "An identified external delivery fires a scheduler-excluded source and is recorded before projection."
      , net = named "source-delivery" [coloredPlace (p "events") "RawEvent"] [transition (p "webhook")] [arc (p "webhook") (p "events")]
      , initial = markingFromList []
      , actions =
          [ Object
              [ ("kind", String "deliver")
              , ("source", String "webhook")
              , ("tokens", Array [encodeToken (item "RawEvent" [("event_id", String "evt-7"), ("status", String "accepted")])])
              , ("identity", String "provider-event-7")
              , ("at", Int 1)
              ]
          , Object [("kind", String "seal"), ("source", String "webhook"), ("at", Int 2)]
          ]
      }
  , Scenario
      { name = "heterogeneous_fanout"
      , description = "One handler firing emits different single-color values to two independently typed output arcs."
      , net =
          named
            "heterogeneous-fanout"
            [coloredPlace (p "pending") "Payment", coloredPlace (p "approved") "ApprovalNotice", coloredPlace (p "ledger") "LedgerEntry"]
            [Transition (p "settle") (Just (HandlerSymbol "settle")) [] []]
            [arc (p "pending") (p "settle"), arc (p "settle") (p "approved"), arc (p "settle") (p "ledger")]
      , initial = markingFromList [(p "pending", [item "Payment" [("amount", Int 150)]])]
      , actions = [stepAt 1]
      }
  ]

-- ---------------------------------------------------------------------------
-- Encodings

encodeToken :: Token -> Json
encodeToken t = Object [("color", maybe Null String t.color), ("data", t.payload)]

decodeToken :: Json -> Either Text Token
decodeToken j = case (lookupMember "color" j, lookupMember "data" j) of
  (Just (String c), Just d) -> Right (Token (Just c) d)
  (Just Null, Just d) -> Right (Token Nothing d)
  _ -> Left "a token is {color, data}"

encodeSelections :: [(NetPath, [Token])] -> Json
encodeSelections xs = Array [Object [("place", String (netPathText at)), ("tokens", Array (map encodeToken ts))] | (at, ts) <- xs]

encodeBinding :: Binding -> Json
encodeBinding b =
  Object
    [ ("transition", String (netPathText b.transition))
    , ("consumed", encodeSelections b.consumed)
    , ("read", encodeSelections b.read)
    , ("delivered", Array (map encodeToken b.delivered))
    ]

-- | The marking as place-sorted @{place, tokens}@ entries.
encodeMarking :: Marking -> Json
encodeMarking m = encodeSelections (sortOn (netPathText . fst) (markingToList m))

encodeOutcome :: FiringOutcome -> Json
encodeOutcome o =
  Object
    [ ("occurrence", Int (fromIntegral o.occurrence))
    , ("transition", String (netPathText o.transition))
    , ("consumed", Array (map encodeToken o.consumed))
    , ("produced", Array [Object [("place", String (netPathText at)), ("token", encodeToken t)] | (at, t) <- o.produced])
    ]

instantJson :: Instant -> Json
instantJson = \case
  IntNumber n -> Int n
  FloatNumber d -> Float d

jsonInstant :: Json -> Maybe Instant
jsonInstant = \case
  Int n -> Just (IntNumber n)
  Float d -> Just (FloatNumber d)
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Generation

orFail :: Either Text a -> IO (Either Text a)
orFail = pure

-- | @generate(scenario)@: project and recompile the net, drive a fresh
-- Instance through the actions, and assemble the fixture value.
generateFixture :: Scenario -> IO (Either Text Json)
generateFixture scenario = case projected of
  Left problem -> orFail (Left problem)
  Right (definition, compiled) -> do
    let initial' = markingFromList (sortOn (netPathText . fst) (markingToList scenario.initial))
        declared = declaredSymbols compiled
        config =
          defaultInstanceConfig
            { initialMarking = initial'
            , guardImplementations = Map.fromList [(Symbol k, g) | (k, g) <- Map.toList goldenGuards, k `Set.member` declared]
            , handlerImplementations = Map.fromList [(Symbol k, PureHandler h) | (k, h) <- Map.toList goldenHandlers, k `Set.member` declared]
            , suppliedIdentity = Just ("golden-" <> T.replace "_" "-" scenario.name)
            }
    newInstance compiled config >>= \case
      Left e -> pure (Left (renderInstanceError e))
      Right inst -> do
        walked <- forM scenario.actions (walkStep inst)
        case sequence walked of
          Left problem -> pure (Left problem)
          Right walk -> do
            history <- Store.records (instanceHistory inst)
            final <- (,) <$> marking inst <*> status inst
            pure . Right $
              Object
                [ ("format", String traceFormat)
                , ("version", Int traceVersion)
                , ("name", String scenario.name)
                , ("description", String scenario.description)
                , ("net", netDefinitionToJson definition)
                , ("bindings", Object [(k, v) | (k, v) <- Map.toList bindingSpecs, k `Set.member` declared])
                , ("initialMarking", encodeMarking initial')
                , ("walk", Array walk)
                , ("history", Array (map encodeRecord history))
                , ("final", Object [("marking", encodeMarking (fst final)), ("status", String (statusText (snd final)))])
                ]
  where
    projected = do
      definition <- projectNetDefinition scenario.net
      compiled <- compileNetDefinition definition
      pure (definition, compiled)

-- | One recorded walk step: candidates before, the action, its outcome, and
-- the marking and status after.
walkStep :: Instance -> Json -> IO (Either Text Json)
walkStep inst action = do
  before <- candidates inst
  outcome <- perform
  case outcome of
    Left problem -> pure (Left problem)
    Right o -> do
      after <- marking inst
      st <- status inst
      pure . Right $
        Object
          [ ("candidatesBefore", Array (map encodeBinding before))
          , ("action", action)
          , ("outcome", maybe Null encodeOutcome o)
          , ("markingAfter", encodeMarking after)
          , ("statusAfter", String (statusText st))
          ]
  where
    field k = lookupMember k action
    at = field "at" >>= jsonInstant
    refused = either (Left . renderInstanceError) Right
    perform = case (field "kind", field "source") of
      (Just (String "step"), _) -> refused <$> step inst at
      (Just (String "deliver"), Just (String source)) -> case (field "tokens", field "identity") of
        (Just (Array raw), Just (String identity)) -> case traverse decodeToken raw of
          Left problem -> pure (Left problem)
          Right tokens ->
            acceptDelivery inst (p source) tokens identity Nothing at >>= \case
              Right (DeliveryAccepted accepted) -> fmap Just . refused <$> completeDelivery inst accepted at
              Right _ -> pure (Left "the delivery was not freshly accepted")
              Left e -> pure (Left (renderInstanceError e))
        _ -> pure (Left "a deliver action carries tokens and an identity")
      (Just (String "seal"), Just (String source)) -> fmap (const Nothing) . refused <$> seal inst (p source) at
      _ -> pure (Left "unknown golden action")

-- | The reference's fixture spelling: sorted keys, two-space indent,
-- non-ASCII kept, one final newline.
renderTrace :: Json -> Either Text ByteString
renderTrace value = case dumps indented {sortKeys = True} value of
  Right bytes -> Right (bytes <> "\n")
  Left _ -> Left "Out of range float values are not JSON compliant"

-- | One corpus file: its name, its bytes, and (for fixtures) its walk length.
data GoldenFile = GoldenFile
  { file :: FilePath
  , fixtureName :: Text
  , bytes :: ByteString
  , walkSteps :: Int
  }

-- | Lowercase hexadecimal SHA-256, as @hashlib.sha256(...).hexdigest()@.
sha256Hex :: ByteString -> Text
sha256Hex = T.pack . concatMap byte . BS.unpack . SHA256.hash
  where
    byte w = let h = showHex w "" in if length h == 1 then '0' : h else h

-- | The manifest bytes for the given fixtures.
manifestFor :: [GoldenFile] -> Either Text ByteString
manifestFor files =
  renderTrace $
    Object
      [ ("format", String "petrus-impetus-golden-trace-manifest")
      , ("version", Int traceVersion)
      , ("generator", String "scripts/gen-golden-traces.py")
      , ("generationCommand", String generationCommand)
      , ( "fixtures"
        , Array
            [ Object
                [ ("file", String (T.pack f.file))
                , ("name", String f.fixtureName)
                , ("sha256", String (sha256Hex f.bytes))
                , ("walkSteps", Int (fromIntegral f.walkSteps))
                ]
            | f <- files
            ]
        )
      ]

-- | Every fixture in scenario order, then @manifest.json@.
generateCorpus :: IO (Either Text [GoldenFile])
generateCorpus = do
  fixtures <- forM scenarios $ \scenario -> do
    generated <- generateFixture scenario
    pure $ do
      value <- generated
      rendered <- renderTrace value
      let steps = case lookupMember "walk" value of
            Just (Array xs) -> length xs
            _ -> 0
      Right GoldenFile {file = T.unpack scenario.name <> ".json", fixtureName = scenario.name, bytes = rendered, walkSteps = steps}
  pure $ do
    files <- sequence fixtures
    manifest <- manifestFor files
    Right (files <> [GoldenFile {file = "manifest.json", fixtureName = "manifest", bytes = manifest, walkSteps = 0}])
