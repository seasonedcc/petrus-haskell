{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The strict @petrus-dst-scenario@ contract and the narrow CV19.DS1
-- replay profile: a port of the reference's @tests/dst/replay.py@.
--
-- The format predates @petrus-dst-world@ artifacts: one schedule of
-- Engine events with expected per-step dispositions and History
-- frontiers, replayed through fresh production Engines over a JSONL
-- History and an in-memory Dispatch. Only the @projection-recovery-v1@
-- application is implemented, as in the reference; the strict contract
-- admits the other event kinds for later profiles.
module Petrus.Testing.Dst.LegacyReplay
  ( -- * Contract
    scenarioFormat
  , scenarioVersion
  , scenarioProfile
  , resultFormat
  , applicationProfile
  , applicationDigest
  , ValidationError (..)
  , Scenario (..)
  , Step (..)
  , Event (..)
  , Origin (..)
  , Application (..)
  , loadScenario
  , validateScenario
  , scenarioJson

    -- * Replay
  , ReplayReport (..)
  , replayScenario
  , reportJson
  ) where

import Control.Exception (Exception (..), SomeException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.IORef
import Data.List (findIndex, nub, sort, sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (defaultInvocationFields)
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (handlerTokens, prepareInvocation)
import Petrus.Impetus.History.Records (ActivityRequested (..), Record (..), recordName)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (InMemoryDispatch, completeOccurrence, failOccurrence, inMemoryDispatch, newInMemoryDispatch, pending)
import Petrus.Testing.Dst (loadStrictJson)
import Petrus.Testing.Dst.Campaign.Support (canonicalDumps, member, orRefuse, pListLen, pyRepr, refuse, sha256Digest, tshow)
import Petrus.Testing.Dst.Decode
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common (engineCurrent, path, pythonError, runtimeErrorText)
import Petrus.Testing.Dst.PyRepr (jsonToPy)
import Petrus.Testing.Dst.PyRepr qualified as Py
import System.Directory (doesFileExist, getFileSize)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- ---------------------------------------------------------------------------
-- Contract

scenarioFormat, scenarioProfile, resultFormat, applicationProfile :: Text
scenarioFormat = "petrus-dst-scenario"
scenarioProfile = "engine-coordinator-v1"
resultFormat = "petrus-dst-replay-result"
applicationProfile = "projection-recovery-v1"

scenarioVersion :: Integer
scenarioVersion = 1

-- | @APPLICATION_DEFINITION@.
applicationDefinition :: Json
applicationDefinition =
  Object
    [ ("activity", String "calculate")
    , ("name", String "dst-projection-recovery")
    , ("places", Array [String "done", String "input"])
    , ("projection", String "Done(result)")
    , ("transition", Object [("handler", String "bridge"), ("input", String "input"), ("output", String "done"), ("path", String "project")])
    ]

-- | @APPLICATION_DIGEST@.
applicationDigest :: Text
applicationDigest = either (error . T.unpack) sha256Digest (canonicalDumps applicationDefinition)

-- | pydantic's @ValidationError@ for @ScenarioArtifact@, rendered.
newtype ValidationError = ValidationError Text
  deriving stock (Eq, Show)

instance Exception ValidationError where
  displayException (ValidationError message) = T.unpack message

safetyProperties :: [Text]
safetyProperties =
  [ "S1-replay-agreement"
  , "S2-history-validity"
  , "S3-stable-invocation"
  , "S4-terminal-before-projection"
  , "S5-delivery-identity"
  , "S6-lifecycle-isolation"
  , "S7-commit-authority"
  , "S8-profile-bounds"
  , "L1-fair-convergence"
  ]

cuts :: [Text]
cuts =
  [ "instance_created"
  , "delivery_accepted"
  , "activity_requested"
  , "external_effect"
  , "activity_terminal_frozen"
  , "projection_committed"
  , "semantic_batch_refused"
  , "scope_fenced"
  , "terminal_acknowledged"
  ]

data TokenValue = TokenValue {color :: Maybe Text, value :: Json}

data MarkingEntry = MarkingEntry {place :: Text, tokens :: [TokenValue]}

data ScopeValue = ScopeValue {name :: Text, generation :: Integer}

data Event
  = DeliverEvent Text [TokenValue] Text
  | DriveEvent Integer
  | AdvanceTimeEvent Integer
  | DispatchTerminalEvent Integer Text Json
  | CloseScopeEvent ScopeValue
  | ResetScopeEvent ScopeValue
  | CrashEvent Text
  | RestartEvent
  | BeginFairEvent

eventKind :: Event -> Text
eventKind = \case
  DeliverEvent {} -> "deliver"
  DriveEvent _ -> "drive"
  AdvanceTimeEvent _ -> "advance_time"
  DispatchTerminalEvent {} -> "dispatch_terminal"
  CloseScopeEvent _ -> "close_scope"
  ResetScopeEvent _ -> "reset_scope"
  CrashEvent _ -> "crash"
  RestartEvent -> "restart"
  BeginFairEvent -> "begin_fair"

data Fault = Fault {kind :: Text, cut :: Text, count :: Integer, error :: Maybe Text}

data Expect = Expect {disposition :: Text, historyFrontier :: Integer, error :: Maybe Text}

data Step = Step {position :: Integer, event :: Event, faults :: [Fault], expect :: Expect}

data Dependency = Dependency {name :: Text, version :: Text}

data Origin = Origin
  { seed :: Integer
  , petrusCommit :: Text
  , implementation :: Text
  , runtimeVersion :: Text
  , dependencies :: [Dependency]
  , property :: Text
  , parentScenarioId :: Maybe Text
  , shrinkSteps :: Integer
  }

data Application = Application {profile :: Text, definitionDigest :: Text}

data Limits = Limits
  { events :: Integer
  , faults :: Integer
  , crashRestartPairs :: Integer
  , actionsPerDrive :: Integer
  , totalActions :: Integer
  , logicalInstant :: Integer
  , historyRecords :: Integer
  , historyPayloadBytes :: Integer
  , retainedTokens :: Integer
  , retainedTokenBytes :: Integer
  , pendingOutcomes :: Integer
  , inFlightActivities :: Integer
  , artifactBytes :: Integer
  , watchdogSeconds :: Integer
  }

data Initial = Initial {instanceId :: Text, instant :: Integer, marking :: [MarkingEntry]}

data Snapshot = Snapshot {marking :: [MarkingEntry], status :: Text, watermark :: Integer, inFlight :: [Integer]}

data Expected = Expected
  { disposition :: Text
  , historyRecordTypes :: [Text]
  , snapshot :: Snapshot
  , observations :: [(Text, Json)]
  , checks :: [Text]
  }

-- | @ScenarioArtifact@.
data Scenario = Scenario
  { scenarioId :: Text
  , origin :: Origin
  , application :: Application
  , limits :: Limits
  , initial :: Initial
  , schedule :: [Step]
  , expected :: Expected
  }

-- ---------------------------------------------------------------------------
-- Validation (the pydantic models)

pStrMin :: Path -> Json -> Parser Text
pStrMin at v = do
  s <- pStr at v
  when (T.null s) $ failAt at "string_too_short" "String should have at least 1 character"
  Right s

pLit :: [Text] -> Path -> Json -> Parser Text
pLit choices = pLiteral [(String c, c) | c <- choices]

pIntIn :: Integer -> Integer -> Path -> Json -> Parser Integer
pIntIn lo hi = pIntRange (Just lo) (Just hi)

pIntMin :: Integer -> Path -> Json -> Parser Integer
pIntMin lo = pIntRange (Just lo) Nothing

pTokenValue :: Path -> Json -> Parser TokenValue
pTokenValue at v = do
  f <- model "TokenValue" ["color", "data"] at v
  TokenValue <$> field f "color" (pNullable pStr) <*> field f "data" (\_ j -> Right j)

pMarkingEntry :: Path -> Json -> Parser MarkingEntry
pMarkingEntry at v = do
  f <- model "MarkingEntry" ["place", "tokens"] at v
  MarkingEntry <$> field f "place" pStrMin <*> field f "tokens" (pListLen (Just 1) Nothing pTokenValue)

pScope :: Path -> Json -> Parser ScopeValue
pScope at v = do
  f <- model "ScopeValue" ["name", "generation"] at v
  ScopeValue <$> field f "name" pStrMin <*> field f "generation" (pIntMin 1)

pEvent :: Path -> Json -> Parser Event
pEvent =
  tagged
    [ ("deliver", event "DeliverEvent" ["source", "tokens", "identity"] $ \f ->
        DeliverEvent <$> field f "source" pStrMin <*> field f "tokens" (pListLen (Just 1) Nothing pTokenValue) <*> field f "identity" pStrMin)
    , ("drive", event "DriveEvent" ["max_actions"] $ \f -> DriveEvent <$> field f "max_actions" (pIntIn 1 256))
    , ("advance_time", event "AdvanceTimeEvent" ["instant"] $ \f -> AdvanceTimeEvent <$> field f "instant" (pIntIn 0 1000000000))
    , ("dispatch_terminal", event "DispatchTerminalEvent" ["occurrence", "outcome", "value"] $ \f ->
        DispatchTerminalEvent <$> field f "occurrence" (pIntMin 1) <*> field f "outcome" (pLit ["completed", "failed"]) <*> field f "value" (\_ j -> Right j))
    , ("close_scope", event "CloseScopeEvent" ["scope"] $ \f -> CloseScopeEvent <$> field f "scope" pScope)
    , ("reset_scope", event "ResetScopeEvent" ["scope"] $ \f -> ResetScopeEvent <$> field f "scope" pScope)
    , ("crash", event "CrashEvent" ["cut"] $ \f -> CrashEvent <$> field f "cut" (pLit cuts))
    , ("restart", event "RestartEvent" [] $ \_ -> Right RestartEvent)
    , ("begin_fair", event "BeginFairEvent" [] $ \_ -> Right BeginFairEvent)
    ]
  where
    event name keys body at v = do
      f <- model name ("kind" : keys) at v
      _ <- field f "kind" (\p j -> pLiteral [(j, ())] p j)
      body f

-- | @ScenarioFault@ and its @allowed_cut@ validator.
pScenarioFault :: Path -> Json -> Parser Fault
pScenarioFault at v = do
  f <- model "ScenarioFault" ["kind", "cut", "count", "error"] at v
  fault <-
    Fault
      <$> field f "kind" (pLit (map fst allowed))
      <*> field f "cut" (pLit cuts)
      <*> field f "count" (pIntIn 1 64)
      <*> field f "error" (pNullable pStr)
  case lookup fault.kind allowed of
    Just permitted | fault.cut `notElem` permitted ->
      valueError at ("DST fault " <> pyRepr fault.kind <> " is not valid at cut " <> pyRepr fault.cut)
    _ -> Right ()
  when ((fault.kind == "projection_raise") /= isJust fault.error) $
    valueError at "only projection_raise requires a non-null error"
  Right fault
  where
    persisted = ["instance_created", "delivery_accepted", "activity_requested", "activity_terminal_frozen", "projection_committed", "scope_fenced"]
    allowed =
      [ ("history_refuse", persisted)
      , ("history_commit_refuse", persisted)
      , ("dispatch_refuse", ["activity_requested", "scope_fenced"])
      , ("dispatch_delay", ["external_effect"])
      , ("dispatch_duplicate", ["activity_terminal_frozen", "projection_committed", "terminal_acknowledged"])
      , ("dispatch_conflict", ["activity_terminal_frozen"])
      , ("ack_refuse", ["delivery_accepted", "activity_terminal_frozen", "terminal_acknowledged"])
      , ("process_crash", cuts)
      , ("history_unreadable", ["semantic_batch_refused"])
      , ("projection_raise", ["activity_terminal_frozen"])
      ]

pStep :: Path -> Json -> Parser Step
pStep at v = do
  f <- model "ScenarioStep" ["position", "event", "faults", "expect"] at v
  Step
    <$> field f "position" (pIntIn 0 511)
    <*> field f "event" pEvent
    <*> field f "faults" (pListLen Nothing (Just 64) pScenarioFault)
    <*> field f "expect" pExpect
  where
    pExpect p j = do
      e <- model "StepExpectation" ["disposition", "history_frontier", "error"] p j
      Expect
        <$> field e "disposition" (pLit ["applied", "idempotent", "refused_expected", "quarantined", "bounded_exhaustion", "harness_failure"])
        <*> field e "history_frontier" (pIntIn 0 50000)
        <*> field e "error" (pNullable pStr)

pOrigin :: Path -> Json -> Parser Origin
pOrigin at v = do
  f <- model "ScenarioOrigin" ["seed", "petrus_commit", "runtime", "dependencies", "property", "shrink"] at v
  seed <- field f "seed" (pIntMin 0)
  commit <- field f "petrus_commit" (pPattern "^[0-9a-f]{40}$" (\s -> T.length s == 40 && T.all hexLower s))
  (implementation, runtimeVersion) <- field f "runtime" $ \p j -> do
    r <- model "RuntimeIdentity" ["implementation", "version"] p j
    (,) <$> field r "implementation" pStrMin <*> field r "version" pStrMin
  dependencies <- field f "dependencies" . pListLen (Just 1) Nothing $ \p j -> do
    d <- model "DependencyIdentity" ["name", "version"] p j
    Dependency <$> field d "name" pStrMin <*> field d "version" pStrMin
  property <- field f "property" (pLit safetyProperties)
  (parentScenarioId, shrinkSteps) <- field f "shrink" $ \p j -> do
    s <- model "ShrinkLineage" ["parent_scenario_id", "steps"] p j
    (,) <$> field s "parent_scenario_id" (pNullable pStr) <*> field s "steps" (pIntMin 0)
  let names = [d.name | d <- dependencies]
  when (length names /= length (nub names)) $ valueError at "DST dependency identities must have unique names"
  Right Origin {seed, petrusCommit = commit, implementation, runtimeVersion, dependencies, property, parentScenarioId, shrinkSteps}

hexLower :: Char -> Bool
hexLower c = c `elem` ("0123456789abcdef" :: String)

-- | A string field with a @pattern=@ constraint.
pPattern :: Text -> (Text -> Bool) -> Path -> Json -> Parser Text
pPattern pattern matches at v = do
  s <- pStr at v
  unless (matches s) $ failAt at "string_pattern_mismatch" ("String should match pattern '" <> pattern <> "'")
  Right s

pLimits :: Path -> Json -> Parser Limits
pLimits at v = do
  f <- model "ScenarioLimits" (map fst bounds) at v
  let get key = case lookup key bounds of
        Just (lo, hi) -> field f key (pIntIn lo hi)
        Nothing -> Left (SchemaError [] "missing" key)
  Limits
    <$> get "events"
    <*> get "faults"
    <*> get "crash_restart_pairs"
    <*> get "actions_per_drive"
    <*> get "total_actions"
    <*> get "logical_instant"
    <*> get "history_records"
    <*> get "history_payload_bytes"
    <*> get "retained_tokens"
    <*> get "retained_token_bytes"
    <*> get "pending_outcomes"
    <*> get "in_flight_activities"
    <*> get "artifact_bytes"
    <*> get "watchdog_seconds"
  where
    bounds =
      [ ("events", (1, 512))
      , ("faults", (0, 64))
      , ("crash_restart_pairs", (0, 32))
      , ("actions_per_drive", (1, 256))
      , ("total_actions", (1, 4096))
      , ("logical_instant", (0, 1000000000))
      , ("history_records", (1, 50000))
      , ("history_payload_bytes", (1, 4194304))
      , ("retained_tokens", (1, 4096))
      , ("retained_token_bytes", (1, 4194304))
      , ("pending_outcomes", (0, 256))
      , ("in_flight_activities", (0, 64))
      , ("artifact_bytes", (1, 4194304))
      , ("watchdog_seconds", (1, 30))
      ]

pExpected :: Path -> Json -> Parser Expected
pExpected at v = do
  f <- model "ScenarioExpected" ["disposition", "history_record_types", "snapshot", "observations", "checks"] at v
  Expected
    <$> field f "disposition" (pLit ["quiescent", "terminal", "quarantined", "bounded_exhaustion", "external_wait"])
    <*> field f "history_record_types" (pList pStr)
    <*> field f "snapshot" pSnapshot
    <*> field f "observations" (pList pExpectedObservation)
    <*> field f "checks" (pListLen (Just 1) Nothing pCheck)
  where
    pSnapshot p j = do
      s <- model "ExpectedSnapshot" ["marking", "status", "watermark", "in_flight"] p j
      Snapshot
        <$> field s "marking" (pList pMarkingEntry)
        <*> field s "status" (pLit ["running", "terminated", "completed", "stuck", "awaiting"])
        <*> field s "watermark" (pIntIn 0 1000000000)
        <*> field s "in_flight" (pList pInt)
    pExpectedObservation p j = do
      o <- model "ExpectedObservation" ["name", "value"] p j
      (,) <$> field o "name" pStrMin <*> field o "value" (\_ x -> Right x)
    pCheck p j = do
      c <- model "ExpectedCheck" ["property", "outcome"] p j
      property <- field c "property" (pLit safetyProperties)
      _ <- field c "outcome" (pLit ["pass"])
      Right property

-- | @ScenarioArtifact.model_validate(value, strict=True)@.
validateScenario :: Json -> Either SchemaError Scenario
validateScenario v = do
  f <- model "ScenarioArtifact" ["format", "version", "profile", "scenario_id", "origin", "application", "limits", "initial", "schedule", "expected"] [] v
  _ <- field f "format" (pLit [scenarioFormat])
  _ <- field f "version" (\p j -> pLiteral [(Int scenarioVersion, ())] p j)
  _ <- field f "profile" (pLit [scenarioProfile])
  scenarioId <- field f "scenario_id" pStrMin
  origin <- field f "origin" pOrigin
  application <- field f "application" $ \p j -> do
    a <- model "ApplicationIdentity" ["profile", "definition_digest"] p j
    Application
      <$> field a "profile" pStrMin
      <*> field a "definition_digest" (pPattern "^sha256:[0-9a-f]{64}$" (\s -> T.isPrefixOf "sha256:" s && T.length s == 71 && T.all hexLower (T.drop 7 s)))
  limits <- field f "limits" pLimits
  initial <- field f "initial" $ \p j -> do
    i <- model "ScenarioInitial" ["instance_id", "instant", "marking"] p j
    Initial <$> field i "instance_id" pStrMin <*> field i "instant" (pIntIn 0 1000000000) <*> field i "marking" (pList pMarkingEntry)
  schedule <- field f "schedule" (pListLen (Just 1) (Just 512) pStep)
  expected <- field f "expected" pExpected
  let scenario = Scenario {scenarioId, origin, application, limits, initial, schedule, expected}
  either (valueError []) Right (coherentBounds scenario)
  Right scenario

-- | @coherent_bounds@.
coherentBounds :: Scenario -> Either Text ()
coherentBounds s = do
  let refuseWith = Left
      frontiers = [step.expect.historyFrontier | step <- s.schedule]
      crashes = length [() | Step {event = CrashEvent _} <- s.schedule]
      restarts = length [() | Step {event = RestartEvent} <- s.schedule]
      observationNames = map fst s.expected.observations
  when ([step.position | step <- s.schedule] /= [0 .. toInteger (length s.schedule) - 1]) $
    refuseWith "DST schedule positions must be dense and zero-based"
  when (length (nub [e.place | e <- s.initial.marking]) /= length s.initial.marking) $
    refuseWith "DST initial marking must name each place at most once"
  when (length (nub [e.place | e <- s.expected.snapshot.marking]) /= length s.expected.snapshot.marking) $
    refuseWith "DST expected marking must name each place at most once"
  when (toInteger (length s.schedule) > s.limits.events) $ refuseWith "DST schedule exceeds its event limit"
  when (sum [fault.count | step <- s.schedule, fault <- step.faults] > s.limits.faults) $
    refuseWith "DST schedule exceeds its fault limit"
  when (crashes /= restarts || toInteger crashes > s.limits.crashRestartPairs) $
    refuseWith "DST crash and restart counts must pair within their limit"
  when (or [n > s.limits.actionsPerDrive | Step {event = DriveEvent n} <- s.schedule]) $
    refuseWith "DST drive exceeds its per-event action limit"
  when (or [i > s.limits.logicalInstant | Step {event = AdvanceTimeEvent i} <- s.schedule]) $
    refuseWith "DST event instant exceeds its logical-time limit"
  when (s.initial.instant > s.limits.logicalInstant || s.expected.snapshot.watermark > s.limits.logicalInstant) $
    refuseWith "DST instant exceeds its logical-time limit"
  when (frontiers /= sort frontiers || last frontiers /= toInteger (length s.expected.historyRecordTypes)) $
    refuseWith "DST expected History frontiers must be monotone and end at the expected record count"
  when (last frontiers > s.limits.historyRecords) $ refuseWith "DST expected History exceeds its record limit"
  when (toInteger (sum [length e.tokens | e <- s.initial.marking]) > s.limits.retainedTokens) $
    refuseWith "DST initial marking exceeds its retained-token limit"
  when (length observationNames /= length (nub observationNames)) $
    refuseWith "DST expected observation names must be unique"
  when (length s.expected.checks /= length (nub s.expected.checks) || s.origin.property `notElem` s.expected.checks) $
    refuseWith "DST checks must be unique and include the originating property"
  let walk live = \case
        [] -> if live then Right () else refuseWith "DST schedule must end with a live runtime"
        step : rest -> case step.event of
          CrashEvent _
            | not live -> refuseWith "DST cannot crash an already discarded runtime"
            | otherwise -> walk False rest
          RestartEvent
            | live -> refuseWith "DST cannot restart while the prior runtime is still live"
            | otherwise -> walk True rest
          _
            | not live -> refuseWith "DST must restart immediately after a crash"
            | otherwise -> walk live rest
  walk True s.schedule

-- | @scenario.model_dump(mode="json")@.
scenarioJson :: Scenario -> Json
scenarioJson s =
  Object
    [ ("format", String scenarioFormat)
    , ("version", Int scenarioVersion)
    , ("profile", String scenarioProfile)
    , ("scenario_id", String s.scenarioId)
    ,
      ( "origin"
      , Object
          [ ("seed", Int s.origin.seed)
          , ("petrus_commit", String s.origin.petrusCommit)
          , ("runtime", Object [("implementation", String s.origin.implementation), ("version", String s.origin.runtimeVersion)])
          , ("dependencies", Array [Object [("name", String d.name), ("version", String d.version)] | d <- s.origin.dependencies])
          , ("property", String s.origin.property)
          , ("shrink", Object [("parent_scenario_id", maybe Null String s.origin.parentScenarioId), ("steps", Int s.origin.shrinkSteps)])
          ]
      )
    , ("application", Object [("profile", String s.application.profile), ("definition_digest", String s.application.definitionDigest)])
    ,
      ( "limits"
      , Object
          [ ("events", Int s.limits.events)
          , ("faults", Int s.limits.faults)
          , ("crash_restart_pairs", Int s.limits.crashRestartPairs)
          , ("actions_per_drive", Int s.limits.actionsPerDrive)
          , ("total_actions", Int s.limits.totalActions)
          , ("logical_instant", Int s.limits.logicalInstant)
          , ("history_records", Int s.limits.historyRecords)
          , ("history_payload_bytes", Int s.limits.historyPayloadBytes)
          , ("retained_tokens", Int s.limits.retainedTokens)
          , ("retained_token_bytes", Int s.limits.retainedTokenBytes)
          , ("pending_outcomes", Int s.limits.pendingOutcomes)
          , ("in_flight_activities", Int s.limits.inFlightActivities)
          , ("artifact_bytes", Int s.limits.artifactBytes)
          , ("watchdog_seconds", Int s.limits.watchdogSeconds)
          ]
      )
    , ("initial", initialJson s.initial)
    , ("schedule", Array (map stepJson s.schedule))
    ,
      ( "expected"
      , Object
          [ ("disposition", String s.expected.disposition)
          , ("history_record_types", Array (map String s.expected.historyRecordTypes))
          , ("snapshot", snapshotJson s.expected.snapshot)
          , ("observations", Array [Object [("name", String n), ("value", v)] | (n, v) <- s.expected.observations])
          , ("checks", Array [Object [("property", String c), ("outcome", String "pass")] | c <- s.expected.checks])
          ]
      )
    ]
  where
    stepJson step =
      Object
        [ ("position", Int step.position)
        , ("event", eventJson step.event)
        , ("faults", Array [Object [("kind", String f.kind), ("cut", String f.cut), ("count", Int f.count), ("error", maybe Null String f.error)] | f <- step.faults])
        , ("expect", Object [("disposition", String step.expect.disposition), ("history_frontier", Int step.expect.historyFrontier), ("error", maybe Null String step.expect.error)])
        ]
    eventJson e = Object (("kind", String (eventKind e)) : eventFields e)
    eventFields = \case
      DeliverEvent source tokens identity -> [("source", String source), ("tokens", Array (map tokenJson tokens)), ("identity", String identity)]
      DriveEvent n -> [("max_actions", Int n)]
      AdvanceTimeEvent i -> [("instant", Int i)]
      DispatchTerminalEvent o outcome v -> [("occurrence", Int o), ("outcome", String outcome), ("value", v)]
      CloseScopeEvent scope -> [("scope", scopeJson scope)]
      ResetScopeEvent scope -> [("scope", scopeJson scope)]
      CrashEvent c -> [("cut", String c)]
      RestartEvent -> []
      BeginFairEvent -> []
    scopeJson scope = Object [("name", String scope.name), ("generation", Int scope.generation)]

tokenJson :: TokenValue -> Json
tokenJson t = Object [("color", maybe Null String t.color), ("data", t.value)]

entriesJson :: [MarkingEntry] -> Json
entriesJson entries = Array [Object [("place", String e.place), ("tokens", Array (map tokenJson e.tokens))] | e <- entries]

initialJson :: Initial -> Json
initialJson i = Object [("instance_id", String i.instanceId), ("instant", Int i.instant), ("marking", entriesJson i.marking)]

snapshotJson :: Snapshot -> Json
snapshotJson snapshot =
  Object
    [ ("marking", entriesJson snapshot.marking)
    , ("status", String snapshot.status)
    , ("watermark", Int snapshot.watermark)
    , ("in_flight", Array (map Int snapshot.inFlight))
    ]

-- | @_strict_bytes(value)@.
strictBytes :: Json -> IO Int
strictBytes value = BS.length <$> orRefuse (canonicalDumps value)

-- | @load_scenario(path)@: decode one strict, bounded, closed-vocabulary
-- scenario. A schema refusal raises 'ValidationError'; the strict-JSON and
-- byte-limit refusals are the reference's @ValueError@s.
loadScenario :: FilePath -> IO Scenario
loadScenario file = do
  payload <- BS.readFile file
  value <- either (\e -> refuse (T.pack file <> ": invalid strict JSON: " <> e)) pure (loadStrictJson payload)
  scenario <- either (throwIO . ValidationError . renderSchemaError "ScenarioArtifact") pure (validateScenario value)
  when (toInteger (BS.length payload) > scenario.limits.artifactBytes) $
    refuse (T.pack file <> ": artifact has " <> tshow (BS.length payload) <> " bytes; limit is " <> tshow scenario.limits.artifactBytes)
  initialBytes <- strictBytes (initialJson scenario.initial)
  when (toInteger initialBytes > scenario.limits.retainedTokenBytes) $
    refuse (T.pack file <> ": initial marking exceeds its retained-token byte limit")
  pure scenario

-- ---------------------------------------------------------------------------
-- Replay

input, done, project :: NetPath
input = path "input"
done = path "done"
project = path "project"

-- | @_application_net()@.
applicationNet :: Net
applicationNet =
  either (Prelude.error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place input, place done]
        , transitions = [(transition project) {handler = Just (HandlerSymbol "bridge")}]
        , arcs = [arc input project, arc project done]
        , completion = Nothing
        , name = Just "dst-projection-recovery"
        }

-- | @_ProjectionBridge@.
data Bridge = Bridge {prepared :: IORef Int, projected :: IORef Int, projectionError :: IORef (Maybe Text)}

newBridge :: IO Bridge
newBridge = Bridge <$> newIORef 0 <*> newIORef 0 <*> newIORef Nothing

bridged :: Bridge -> Bridged
bridged bridge =
  Bridged
    { prepare = \b -> case bindingTokens b of
        t : _ -> prepareInvocation (defaultInvocationFields "calculate" t.payload)
        [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(done, [Token (Just "Done") result])])
    , onPrepare = Right () <$ modifyIORef' bridge.prepared (+ 1)
    , onProject = do
        modifyIORef' bridge.projected (+ 1)
        maybe (Right ()) (Left . runtimeErrorText) <$> readIORef bridge.projectionError
    }

-- | @ReplayReport@.
data ReplayReport = ReplayReport
  { scenarioId :: Text
  , property :: Text
  , eventsApplied :: Int
  , historyFrontier :: Integer
  , historyRecordTypes :: [Text]
  , snapshot :: Json
  , observations :: [(Text, Json)]
  , checks :: [Text]
  }

-- | @ReplayReport.as_dict()@.
reportJson :: ReplayReport -> Json
reportJson r =
  Object
    [ ("format", String resultFormat)
    , ("version", Int scenarioVersion)
    , ("profile", String scenarioProfile)
    , ("scenario_id", String r.scenarioId)
    , ("property", String r.property)
    , ("outcome", String "pass")
    , ("events_applied", Int (toInteger r.eventsApplied))
    , ("history_frontier", Int r.historyFrontier)
    , ("history_record_types", Array (map String r.historyRecordTypes))
    , ("snapshot", r.snapshot)
    , ("observations", Object r.observations)
    , ("checks", Array (map String r.checks))
    ]

-- | The live runtime of one generation.
data Live = Live {engine :: Engine, pool :: InMemoryDispatch, bridge :: Bridge}

historySize :: HistoryStore -> IO Integer
historySize store = toInteger . length <$> store.snapshot

historyRecords :: HistoryStore -> IO [Record]
historyRecords store = toList <$> store.snapshot

-- | @_encoded_marking(marking)@: places in string order.
encodedMarking :: Marking -> Json
encodedMarking m =
  Array
    [ Object [("place", String (netPathText p)), ("tokens", Array [Object [("color", maybe Null String t.color), ("data", t.payload)] | t <- ts])]
    | (p, ts) <- sortOn (netPathText . fst) (markingToList m)
    ]

assertion :: Text -> IO a
assertion = refuse

openLive :: FilePath -> Scenario -> HistoryStore -> Bool -> IO Live
openLive _ scenario history create = do
  pool <- newInMemoryDispatch
  bridge <- newBridge
  let options =
        withBridge (bridged bridge) Engine.defaultEngineOptions
      initialMarking = markingFromList [(path e.place, [Token t.color t.value | t <- e.tokens]) | e <- scenario.initial.marking]
  engine <-
    if create
      then
        Engine.create
          applicationNet
          scenario.initial.instanceId
          history
          (inMemoryDispatch pool)
          options {Engine.marking = initialMarking, Engine.at = fromInteger scenario.initial.instant}
      else Engine.load applicationNet scenario.initial.instanceId history (inMemoryDispatch pool) options
  pure Live {engine, pool, bridge}

-- | @replay_scenario(scenario)@: replay through fresh production Engines.
replayScenario :: Scenario -> IO ReplayReport
replayScenario scenario = do
  when (scenario.application.profile /= applicationProfile) $
    refuse ("unsupported DST application profile " <> pyRepr scenario.application.profile)
  when (scenario.application.definitionDigest /= applicationDigest) $
    refuse "DST application definition digest does not match projection-recovery-v1"
  withSystemTempDirectory "petrus-dst-" $ \directory -> do
    let historyPath = directory </> "history.jsonl"
    historyRef <- openJsonlHistoryStore historyPath >>= newIORef
    initialHistory <- readIORef historyRef
    liveRef <- openLive historyPath scenario initialHistory True >>= newIORef . Just
    firstInvocation <- newIORef Nothing
    observations <- newIORef []
    acceptedActions <- newIORef (0 :: Integer)
    readyOutcomes <- newIORef (0 :: Integer)
    poisoned <- newIORef False
    let observe name v = modifyIORef' observations (\os -> [(k, x) | (k, x) <- os, k /= name] <> [(name, v)])
    forM_ scenario.schedule $ \step -> do
      history <- readIORef historyRef
      frontierBefore <- historySize history
      live <- readIORef liveRef
      forM_ step.faults $ \fault -> do
        case step.event of
          DriveEvent _ | fault.kind == "projection_raise" -> pure ()
          _ -> refuse ("projection-recovery-v1 cannot apply fault " <> pyRepr fault.kind <> " to event " <> pyRepr (eventKind step.event))
        case (live, fault.error) of
          (Just l, Just message) | fault.count == 1 -> writeIORef l.bridge.projectionError (Just message)
          _ -> refuse "projection-recovery-v1 requires one projection_raise fault on a live bridge"
      outcome <- try $ case step.event of
        DriveEvent maxActions -> do
          l <- maybe (refuse "cannot drive without a live Engine") pure live
          let loop n = when (n > 0) $ do
                driven <- Engine.advance l.engine
                writeIORef readyOutcomes 0
                when (driven.ready || not (null driven.firings)) $ modifyIORef' acceptedActions (+ 1)
                waiting <- sortOn fst <$> pending l.pool
                known <- readIORef firstInvocation
                case waiting of
                  (_, inv) : _ | isNothing known -> writeIORef firstInvocation (Just inv)
                  _ -> pure ()
                when driven.ready (loop (n - 1 :: Integer))
          loop maxActions
        DispatchTerminalEvent occurrence outcome v -> do
          l <- maybe (refuse "cannot report a Dispatch terminal without a live Dispatch") pure live
          if outcome == "completed"
            then completeOccurrence l.pool (fromInteger occurrence) v
            else case v of
              String message -> failOccurrence l.pool (fromInteger occurrence) message
              _ -> refuse "projection-recovery-v1 requires a string failed outcome"
          modifyIORef' readyOutcomes (+ 1)
        CrashEvent c -> do
          when (c == "activity_terminal_frozen") $ do
            names <- map recordName <$> historyRecords history
            when ("ActivityCompleted" `notElem` names || "FiringCompleted" `elem` names) $
              refuse "crash cut is not after terminal freeze and before projection"
          forM_ live $ \l -> do
            Engine.close l.engine
            readIORef l.bridge.prepared >>= observe "prepared_before_crash" . Int . toInteger
            readIORef l.bridge.projected >>= observe "projected_before_crash" . Int . toInteger
          writeIORef liveRef Nothing
          writeIORef poisoned False
        RestartEvent -> do
          when (isJust live) $ refuse "restart requires all prior live runtime objects to be discarded"
          fresh <- openJsonlHistoryStore historyPath
          writeIORef historyRef fresh
          l <- openLive historyPath scenario fresh False
          writeIORef liveRef (Just l)
          writeIORef poisoned False
        other ->
          refuse
            ( "projection-recovery-v1 does not implement event "
                <> pyRepr (eventKind other)
                <> "; the strict contract admits it for later DS2 profiles"
            )
      (disposition, failureText) <- case outcome of
        Right () -> pure ("applied", Nothing)
        Left (e :: SomeException) -> case pythonError e of
          ("RuntimeError", message) -> do
            writeIORef readyOutcomes 0
            history' <- readIORef historyRef
            frontier <- historySize history'
            case step.event of
              DriveEvent _ | frontier > frontierBefore -> do
                modifyIORef' acceptedActions (+ 1)
                writeIORef poisoned True
              _ -> pure ()
            pure ("refused_expected" :: Text, Just message)
          _ -> throwIO e
      when (disposition /= step.expect.disposition || failureText /= step.expect.error) $
        assertion
          ( "step "
              <> tshow step.position
              <> " expected "
              <> step.expect.disposition
              <> "/"
              <> optionalRepr step.expect.error
              <> ", observed "
              <> disposition
              <> "/"
              <> optionalRepr failureText
          )
      history' <- readIORef historyRef
      frontier <- historySize history'
      when (frontier /= step.expect.historyFrontier) $
        assertion ("step " <> tshow step.position <> " expected History frontier " <> tshow step.expect.historyFrontier <> ", found " <> tshow frontier)
      accepted <- readIORef acceptedActions
      when (accepted > scenario.limits.totalActions) $ assertion "DST replay exceeded its total accepted-action limit"
      exists <- doesFileExist historyPath
      when exists $ do
        size <- getFileSize historyPath
        when (size > scenario.limits.historyPayloadBytes) $ assertion "DST replay exceeded its History payload byte limit"
      live' <- readIORef liveRef
      isPoisoned <- readIORef poisoned
      forM_ live' $ \l -> unless isPoisoned $ do
        flying <- Engine.inFlight l.engine
        when (toInteger (length flying) > scenario.limits.inFlightActivities) $
          assertion "DST replay exceeded its in-flight Activity limit"
      ready <- readIORef readyOutcomes
      when (ready > scenario.limits.pendingOutcomes) $ assertion "DST replay exceeded its pending collaborator-outcome limit"
      forM_ live' $ \l -> unless isPoisoned $ do
        m <- Engine.marking l.engine
        when (toInteger (sum [length ts | (_, ts) <- markingToList m]) > scenario.limits.retainedTokens) $
          assertion "DST replay exceeded its retained-token limit"
        bytes <- strictBytes (encodedMarking m)
        when (toInteger bytes > scenario.limits.retainedTokenBytes) $
          assertion "DST replay exceeded its retained-token byte limit"

    live <- readIORef liveRef >>= maybe (assertion "DST scenario ended without a live reconstructed Engine") pure
    history <- readIORef historyRef
    readIORef live.bridge.prepared >>= observe "prepared_after_restart" . Int . toInteger
    readIORef live.bridge.projected >>= observe "projected_after_restart" . Int . toInteger
    pending live.pool >>= observe "dispatch_pending_after_restart" . Int . toInteger . length
    current <- engineCurrent live.engine
    m <- Engine.marking live.engine
    let snapshot =
          Object
            [ ("marking", encodedMarking m)
            , ("status", member "status" current)
            , ("watermark", member "watermark" current)
            , ("in_flight", Array [member "occurrence" entry | Array entries <- [member "in_flight" current], entry <- entries])
            ]
    records <- historyRecords history
    let recordTypes = map recordName records
        actualDisposition = if member "status" current `elem` [String "terminated", String "completed"] then "terminal" else "quiescent"
        expectedSnapshot = snapshotJson scenario.expected.snapshot
    unless (snapshot == expectedSnapshot) $
      assertion ("expected final snapshot " <> repr expectedSnapshot <> ", found " <> repr snapshot)
    unless (recordTypes == scenario.expected.historyRecordTypes) $
      assertion "final History record types do not match the scenario"
    unless (actualDisposition == scenario.expected.disposition) $
      assertion ("expected final disposition " <> pyRepr scenario.expected.disposition <> ", found " <> pyRepr actualDisposition)
    observed' <- readIORef observations
    unless (Object observed' == Object scenario.expected.observations) $
      assertion ("expected observations " <> repr (Object scenario.expected.observations) <> ", found " <> repr (Object observed'))

    first <- readIORef firstInvocation
    let requested = [r | RActivityRequested r <- records]
        position name = findIndex ((== name) . recordName) records
        completedCount = length [() | r <- records, recordName r == "ActivityCompleted"]
        observedInt name = lookup name observed'
        stable = case (requested, first) of
          ([r], Just inv) ->
            inv.activity == r.activity
              && inv.input == r.input
              && inv.policy == r.policy
              && inv.correlation == Just r.correlation
              && inv.idempotency == Just r.idempotency
          _ -> False
        terminalBeforeProjection =
          completedCount == 1
            && maybe False id ((<) <$> position "ActivityCompleted" <*> position "FiringCompleted")
            && observedInt "prepared_after_restart" == Just (Int 0)
            && observedInt "projected_after_restart" == Just (Int 1)
    Engine.close live.engine
    finalHistory <- openJsonlHistoryStore historyPath
    finalPool <- newInMemoryDispatch
    finalBridge <- newBridge
    finalEngine <-
      Engine.load
        applicationNet
        scenario.initial.instanceId
        finalHistory
        (inMemoryDispatch finalPool)
        (withBridge (bridged finalBridge) Engine.defaultEngineOptions)
    finalCurrent <- engineCurrent finalEngine
    Engine.close finalEngine
    let computed =
          [ ("S3-stable-invocation", stable)
          , ("S4-terminal-before-projection", terminalBeforeProjection)
          , ("S1-replay-agreement", finalCurrent == current)
          ]
        expectedChecks = scenario.expected.checks
    when (any (\c -> lookup c computed /= Just True) expectedChecks) $
      assertion ("DST checker failure: " <> repr (Object [(k, Bool b) | (k, b) <- computed]))
    when (scenario.origin.property `notElem` expectedChecks) $
      assertion "the originating property must be among the replay checks"
    frontier <- historySize history
    pure
      ReplayReport
        { scenarioId = scenario.scenarioId
        , property = scenario.origin.property
        , eventsApplied = length scenario.schedule
        , historyFrontier = frontier
        , historyRecordTypes = recordTypes
        , snapshot
        , observations = observed'
        , checks = expectedChecks
        }
  where
    repr = Py.pyRepr . jsonToPy
    optionalRepr = maybe "None" pyRepr
