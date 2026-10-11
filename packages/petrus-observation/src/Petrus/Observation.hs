-- | Detached canonical projections for runtime observation and static
-- inspection (@petrus.impetus.observation@, protocol version 1).
--
-- Every projection here is a pure function from immutable values to a
-- 'Json' value whose members are in the reference's insertion order. The
-- reference returns @json.loads(json.dumps(...))@ dicts; a transport
-- serializes them with its own spelling (the observation HTTP profile uses
-- compact, key-sorted, ASCII-escaped JSON). Nothing here performs I/O except
-- 'captureInstance' and 'capture', which read one Instance's current state.
--
-- __The Engine seam.__ These projections, like the reference's, depend on
-- the kernel and never on an Engine. The Engine's three read doors
-- (@Engine.snapshot()@, @Engine.history_page()@, @Engine.net_document()@)
-- are "Petrus.Observation.Engine": each runs 'capture' under the Engine's
-- monitor ('Petrus.Engine.Observation.observeEngine'), then projects.
--
-- 'capture' must run while no writing door is active (the reference holds
-- its Engine lock for the whole door, so a reader that arrives mid-door sees
-- the after-state), so that @frontier == length records@ is coherent with
-- @current@. Only the capture needs that exclusion: the projection itself is
-- pure and can run after the lock is released.
module Petrus.Observation
  ( -- * Errors
    ObservationError (..)
  , observationErrorText
    -- * Captured state
  , ObservedInstance (..)
  , captureInstance
  , Observation (..)
  , capture
    -- * In-flight phases
  , Phase (..)
  , phaseOf
  , phaseText
    -- * Projections
  , protocolVersion
  , definition
  , netInspection
  , marking
  , snapshot
  , snapshotWith
  , historyPage
  , historyCursor
  , netDocument
  ) where

import Control.Exception (Exception)
import Control.Monad (forM, when)
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), failureJson)
import Petrus.Activity.Number (Number (..), reprNumber)
import Petrus.Impetus.History (Record, replayMarkings)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (FieldValue (FPolicy), encodeFieldValue)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
  ( FiringOccurrence (..)
  , Instance
  , Status
  , TerminalOutcome (..)
  , instanceHistory
  , instanceIdentity
  , instanceNet
  , statusText
  )
import Petrus.Impetus.Instance qualified as Instance
import Petrus.Impetus.Validation.Pydantic (fromJson, pyRepr)
import Petrus.Impetus.NetDefinition (netDefinitionToJson, projectNetDefinition)
import Petrus.Impetus.NetDocument
  ( mkExecutionLineage
  , mkLineageEntry
  , Provenance (Observed)
  , netDocumentToJson
  , placeMarkingFromJson
  , projectNetDocument
  , serializeNetDocument
  )
import Petrus.Impetus.Petrinet (Binding (..), Instant, Marking, Net, NetPath, Token (..), markingToList, netPathText)
import Petrus.Json (Json (..))

-- ---------------------------------------------------------------------------
-- Errors

-- | A projection refusal. Every refusal is a @ValueError@ (or a subclass:
-- pydantic's @ValidationError@, @NetDocumentError@) in the reference, so
-- one constructor carries the reference's exact message; a transport maps
-- every one of them to the same client error.
newtype ObservationError = ObservationError Text
  deriving stock (Eq, Show)

instance Exception ObservationError

observationErrorText :: ObservationError -> Text
observationErrorText (ObservationError message) = message

refuse :: Text -> Either ObservationError a
refuse = Left . ObservationError

strictPrefix :: Text
strictPrefix = "observation data must be strict JSON-faithful: "

-- ---------------------------------------------------------------------------
-- Captured state

-- | One Instance's current state, captured at once: everything a snapshot
-- reads (@instance_id@, @net@, @marking@, @status@, @watermark@,
-- @in_flight@, @armed@, @next_maturation@, and the frozen Activity results
-- the reference reads from @Instance._frozen_results@).
data ObservedInstance = ObservedInstance
  { identity :: Text
  , net :: Net
  , marking :: Marking
  , status :: Status
  , watermark :: Instant
  , inFlight :: [FiringOccurrence]
  -- ^ In begin (occurrence) order.
  , frozen :: IntMap TerminalOutcome
  -- ^ Frozen terminal Activity facts by occurrence: presence means the
  -- occurrence's projection is pending.
  , armed :: Map NetPath (Set Text)
  -- ^ Only sources with at least one armed key.
  , nextMaturation :: Maybe Instant
  }

-- | Read one Instance's current state through its public reads. The reads
-- are separate, so the caller must exclude writing doors for the duration
-- (see the module header).
captureInstance :: Instance -> IO ObservedInstance
captureInstance inst = do
  currentMarking <- Instance.marking inst
  currentStatus <- Instance.status inst
  currentWatermark <- Instance.watermark inst
  flight <- Instance.inFlight inst
  outcomes <- Instance.pendingActivityOutcomes inst
  registrations <- Instance.armed inst
  maturation <- Instance.nextMaturation inst
  pure
    ObservedInstance
      { identity = instanceIdentity inst
      , net = instanceNet inst
      , marking = currentMarking
      , status = currentStatus
      , watermark = currentWatermark
      , inFlight = flight
      , frozen = outcomes
      , armed = Map.filter (not . Set.null) registrations
      , nextMaturation = maturation
      }

-- | One coherent observation: the captured current state and the complete
-- canonical History through the same frontier.
data Observation = Observation
  { observed :: ObservedInstance
  , records :: Seq Record
  }

-- | Capture an Instance and its History mirror together (writers excluded
-- by the caller).
capture :: Instance -> IO Observation
capture inst = Observation <$> captureInstance inst <*> (instanceHistory inst).snapshot

-- ---------------------------------------------------------------------------
-- Phases

-- | Exactly one phase per in-flight occurrence; only a pending projection
-- carries its frozen terminal fact.
data Phase
  = PurePending
  | ActivityPending
  | ProjectionPending TerminalOutcome
  deriving stock (Eq, Show)

-- | @projection_pending@ when a terminal fact is frozen for the occurrence,
-- else @activity_pending@ when it requested an Activity, else
-- @pure_pending@.
phaseOf :: IntMap TerminalOutcome -> FiringOccurrence -> Phase
phaseOf outcomes o = case IntMap.lookup o.occurrence outcomes of
  Just outcome -> ProjectionPending outcome
  Nothing -> maybe PurePending (const ActivityPending) o.invocation

phaseText :: Phase -> Text
phaseText = \case
  PurePending -> "pure_pending"
  ActivityPending -> "activity_pending"
  ProjectionPending _ -> "projection_pending"

-- ---------------------------------------------------------------------------
-- Projections

-- | The observation protocol version (@protocol: 1@).
protocolVersion :: Integer
protocolVersion = 1

-- | @definition(net)@: the v3-pinned canonical definition body nested by
-- protocol 1 (no @format@/@version@ envelope).
definition :: Net -> Either ObservationError Json
definition value = case projectNetDefinition value of
  Left message -> refuse (strictPrefix <> message)
  Right document -> case netDefinitionToJson document of
    Object members | Just body <- lookup "definition" members -> Right body
    _ -> refuse (strictPrefix <> "the v3 projection has no definition body")

-- | @net_inspection(net)@: one definition-only portable Net document.
netInspection :: Net -> Either ObservationError Json
netInspection value = first ObservationError $ do
  document <- projectNetDocument value Nothing Nothing
  _ <- serializeNetDocument document
  Right (netDocumentToJson document)

-- | @marking(value)@: sparse, place-sorted @{place, tokens}@ entries with
-- FIFO @{color, data}@ tokens.
marking :: Marking -> Either ObservationError Json
marking value = strict (markingJson value)

markingJson :: Marking -> Json
markingJson value =
  Array
    [ Object [("place", String (netPathText place)), ("tokens", tokensJson tokens)]
    | (place, tokens) <- sortOn fst (markingToList value)
    ]

tokensJson :: [Token] -> Json
tokensJson tokens = Array [Object [("color", maybe Null String t.color), ("data", t.payload)] | t <- tokens]

selectionsJson :: [(NetPath, [Token])] -> Json
selectionsJson selections = Array [Object [("place", String (netPathText p)), ("tokens", tokensJson ts)] | (p, ts) <- selections]

-- | @snapshot(instance, records)@: one coherent current protocol-v1
-- snapshot. Only the History length (the frontier) is read from records.
snapshot :: Observation -> Either ObservationError Json
snapshot o = do
  _ <- currentTimes o.observed
  body <- definition o.observed.net
  snapshotWith body o

-- | 'snapshot' with an already projected 'definition' of the same net (a
-- Net is immutable, so a host may project its definition once and reuse
-- it).
snapshotWith :: Json -> Observation -> Either ObservationError Json
snapshotWith body o = do
  current <- currentJson o.observed
  strict $
    Object
      [ ("protocol", Int protocolVersion)
      , ("instance", String o.observed.identity)
      , ("definition", body)
      , ("frontier", Int (toInteger (Seq.length o.records)))
      , ("current", Object current)
      ]

currentTimes :: ObservedInstance -> Either ObservationError (Integer, Maybe Integer)
currentTimes state = do
  w <- integer state.watermark "current watermark"
  m <- traverse (`integer` "next maturation") state.nextMaturation
  Right (w, m)

integer :: Number -> Text -> Either ObservationError Integer
integer value subject = case value of
  IntNumber i -> Right i
  FloatNumber _ -> refuse ("protocol 1 requires " <> subject <> " to be an integer, got " <> reprNumber value)

currentJson :: ObservedInstance -> Either ObservationError [(Text, Json)]
currentJson state = do
  (w, m) <- currentTimes state
  placed <- marking state.marking
  Right
    [ ("marking", placed)
    , ("status", String (statusText state.status))
    , ("watermark", Int w)
    , ("in_flight", Array (map (occurrenceJson state.frozen) state.inFlight))
    , ("armed", Array [Object [("source", String (netPathText s)), ("key", String k)] | (s, keys) <- Map.toAscList state.armed, k <- Set.toAscList keys])
    , ("next_maturation", maybe Null Int m)
    ]

occurrenceJson :: IntMap TerminalOutcome -> FiringOccurrence -> Json
occurrenceJson outcomes o =
  Object
    [ ("occurrence", Int (toInteger o.occurrence))
    , ("transition", String (netPathText o.binding.transition))
    , ("phase", String (phaseText phase))
    , ( "binding"
      , Object
          [ ("consumed", selectionsJson o.binding.consumed)
          , ("read", selectionsJson o.binding.read)
          , ("delivered", tokensJson o.binding.delivered)
          ]
      )
    , ("invocation", maybe Null invocationJson o.invocation)
    , ("result", resultJson)
    ]
  where
    phase = phaseOf outcomes o
    resultJson = case phase of
      ProjectionPending (TerminalResult value) -> value
      ProjectionPending (TerminalFailure failure) -> failureJson failure
      _ -> Null
    invocationJson i =
      Object
        [ ("activity", String i.activity)
        , ("input", i.input)
        , ("policy", encodeFieldValue (FPolicy i.policy))
        , ("correlation", maybe Null String i.correlation)
        , ("idempotency", maybe Null String i.idempotency)
        ]

-- | @history_page(instance_id, records, after, limit)@: one exclusive-prefix
-- page of the captured History, with dense positions in @[after, next)@ and
-- @next = min(after + limit, frontier)@. @after == frontier@ is an empty
-- page; a future cursor is refused, never clamped.
historyPage :: Text -> Seq Record -> Integer -> Integer -> Either ObservationError Json
historyPage instanceId history after limit = do
  when (after < 0) $ refuse ("history after must be a non-negative integer, got " <> T.pack (show after))
  when (limit <= 0) $ refuse ("history limit must be a positive integer, got " <> T.pack (show limit))
  let frontier = toInteger (Seq.length history)
  when (after > frontier) $
    refuse ("history after " <> T.pack (show after) <> " exceeds captured frontier " <> T.pack (show frontier))
  let end = min (after + limit) frontier
      page = Seq.take (fromInteger (end - after)) (Seq.drop (fromInteger after) history)
  strict $
    Object
      [ ("protocol", Int protocolVersion)
      , ("instance", String instanceId)
      , ("after", Int after)
      , ("next", Int end)
      , ("frontier", Int frontier)
      , ( "records"
        , Array
            [ Object [("position", Int position), ("record", encodeRecord r)]
            | (position, r) <- zip [after ..] (toList page)
            ]
        )
      ]

-- | The reference's argument checks on JSON-level cursor values, for a
-- language-neutral entry point: @after@ must be a non-boolean, non-negative
-- integer and @limit@ a non-boolean, positive integer. (The frontier check
-- is 'historyPage''s.)
historyCursor :: Json -> Json -> Either ObservationError (Integer, Integer)
historyCursor afterValue limitValue = do
  after <- case afterValue of
    Int i | i >= 0 -> Right i
    other -> refuse ("history after must be a non-negative integer, got " <> pyRepr (fromJson other))
  limit <- case limitValue of
    Int i | i > 0 -> Right i
    other -> refuse ("history limit must be a positive integer, got " <> pyRepr (fromJson other))
  Right (after, limit)

-- | @net_document(instance, records)@: the observed Timeline document — one
-- @observed@ lineage entry per History record, each with the complete
-- marking after that record; the first entry's metadata names the
-- instance, the head's carries the current observation (the snapshot's
-- @current@ without its marking), and every entry carries its encoded
-- record.
netDocument :: Observation -> Either ObservationError Json
netDocument o = do
  when (Seq.null o.records) $ refuse "an observed Net document requires nonempty canonical History"
  _ <- snapshot o
  current <- currentJson o.observed
  let observation = Object [(k, v) | (k, v) <- current, k /= "marking"]
      count = Seq.length o.records
  markings <- first ObservationError (replayMarkings o.records)
  entries <- forM (zip3 [0 :: Int ..] (toList o.records) markings) $ \(index, r, m) -> do
    placed <- marking m
    places <- case placed of
      Array items -> traverse (first ObservationError . placeMarkingFromJson) items
      _ -> Right []
    first ObservationError $
      mkLineageEntry
        (toInteger index)
        (if index == 0 then Nothing else Just (toInteger index - 1))
        Observed
        places
        ( [("instance", String o.observed.identity) | index == 0]
            ++ [("observation", observation) | index == count - 1]
            ++ [("history_record", encodeRecord r)]
        )
  first ObservationError $ do
    lineage <- mkExecutionLineage (toInteger count - 1) entries
    document <- projectNetDocument o.observed.net Nothing (Just lineage)
    _ <- serializeNetDocument document
    Right (netDocumentToJson document)

-- ---------------------------------------------------------------------------
-- Strict JSON

-- | @_strict@: the reference round-trips every projection through
-- @json.dumps(allow_nan=False)@. A 'Json' value is already detached and
-- JSON-shaped, so the one refusal left is the first non-finite float in
-- serialization order.
strict :: Json -> Either ObservationError Json
strict value = case firstNonFinite value of
  Nothing -> Right value
  Just d ->
    refuse (strictPrefix <> "Out of range float values are not JSON compliant: " <> reprNumber (FloatNumber d))

firstNonFinite :: Json -> Maybe Double
firstNonFinite = \case
  Float d | isNaN d || isInfinite d -> Just d
  Array items -> firstJust (map firstNonFinite items)
  Object members -> firstJust [firstNonFinite v | (_, v) <- members]
  _ -> Nothing
  where
    firstJust = foldr (\candidate rest -> maybe rest Just candidate) Nothing
