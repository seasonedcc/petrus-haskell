{-# LANGUAGE MultiWayIf #-}

-- | Deterministic semantic coverage accounting for V5 readiness DST
-- artifacts (@host/testing/readiness_coverage.py@).
--
-- Coverage is evidence accounting, not a score. A dimension is covered only
-- when one scenario contains its executable adapter, a passed relevant
-- checker, and the detached semantic outcome. Unsupported dimensions remain
-- explicit blocked entries.
--
-- The report's JSON and its @encode_readiness_coverage@ bytes are the
-- reference's. 'loadReadinessCoverage' mirrors the strict pydantic model and
-- its validators; a refusal carries the class (@ValidationError@ or
-- @ValueError@) and the reference validator's message.
module Hamsterdan.Testing.World.Coverage
  ( CoverageRun (..)
  , ScenarioReference (..)
  , Evidence (..)
  , CoverageDimension (..)
  , CoverageReport (..)
  , collectReadinessCoverage
  , encodeReadinessCoverage
  , loadReadinessCoverage
  , coverageJson
  , covered
  , blocked
  , dimensionNames
  , modelDumpJsonLength
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Testing.World.Contract (PyError (..), canonical, checkerIdentity, profileIdentity)
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Json.Float (shortestDigits)
import Petrus.Testing.Dst
  ( AcceptedOperation (..)
  , AnyArtifact (..)
  , AuthoredDisposition (..)
  , CheckResult (..)
  , CheckerIdentity
  , CrashOperation (..)
  , ExecuteOperation (..)
  , ExpandedOperation (..)
  , FaultOperation (..)
  , FinishOperation (..)
  , Identity (..)
  , JournalEntry (..)
  , JournalKind (..)
  , Observation (..)
  , ProfileIdentity
  , ReplayResult (..)
  , ScenarioArtifactV4 (..)
  , ScenarioExpected (..)
  , operationPosition
  , toJson
  )
import Petrus.Testing.Dst qualified as Dst
import Petrus.Testing.Dst.Decode
  ( Parser
  , Path
  , failAt
  , field
  , fieldDefault
  , model
  , pBool
  , pCheckResult
  , pCheckerIdentity
  , pIntRange
  , pList
  , pLiteral
  , pNullable
  , pObservation
  , pProfileIdentity
  , pStr
  , renderSchemaError
  , valueError
  )

-- ---------------------------------------------------------------------------
-- The catalog

dimensionNames :: [Text]
dimensionNames =
  [ "authority_movement"
  , "lifecycle_movement"
  , "duplicate_delivery"
  , "timer_lifecycle"
  , "provider_response_loss"
  , "crash_reconstruction"
  , "conversation_effect"
  , "coding_effect"
  , "git_mutation"
  , "git_ambiguity_recovery"
  , "fair_convergence"
  , "checker_activation"
  , "exact_replay"
  , "ci_rerun_repair"
  , "agent_terminal_fault_cuts"
  , "stale_rate_limited_reads"
  , "history_dispatch_fault_cuts"
  ]

adapterEvidence, checkerEvidence, outcomeEvidence :: [Text]
adapterEvidence =
  [ "agent.coding_terminal"
  , "agent.conversation_terminal"
  , "authority.set"
  , "fair.begin"
  , "generation.crash"
  , "generation.restart"
  , "git.provider_request"
  , "git.recovery_grant"
  , "git.response_loss"
  , "provider.response_loss"
  , "petrus.replay"
  , "time.advance"
  , "webhook.redelivery"
  , "world.accepted_operation"
  ]
checkerEvidence =
  [ "petrus.exact_replay"
  , "readiness.authority"
  , "readiness.fair_boundary"
  , "readiness.git_custody"
  , "readiness.generation_load"
  , "readiness.independent_model"
  , "readiness.no_duplicate_effect"
  , "readiness.timer_custody"
  ]
outcomeEvidence =
  [ "agent.coding_called"
  , "agent.conversation_called"
  , "authority.generation_moved"
  , "checker.passed"
  , "crash.cut.authority_lifecycle"
  , "crash.cut.git_after_acceptance"
  , "crash.cut.git_after_head"
  , "crash.cut.git_before_delivery"
  , "crash.cut.timer_after_acceptance"
  , "crash.cut.timer_after_due"
  , "crash.cut.timer_before_due"
  , "fair.converged"
  , "generation.reloaded"
  , "git.accepted"
  , "git.faultm_then_pushed"
  , "git.recovery_authorized"
  , "lifecycle.changed"
  , "lifecycle.closed"
  , "lifecycle.draft"
  , "lifecycle.resumed"
  , "provider.response_lost"
  , "replay.exact"
  , "timer.acknowledged"
  , "timer.armed"
  , "timer.matured"
  , "webhook.duplicate"
  ]

type Requirements = (Set Text, Set Text, Set Text)

requirements :: Map Text Requirements
requirements =
  Map.fromList
    [ ("authority_movement", req ["authority.set"] ["readiness.authority"] ["authority.generation_moved"])
    , ("lifecycle_movement", req ["authority.set"] ["readiness.authority"] ["lifecycle.changed"])
    , ("duplicate_delivery", req ["webhook.redelivery"] ["readiness.no_duplicate_effect"] ["webhook.duplicate"])
    , ("timer_lifecycle", req ["time.advance"] ["readiness.timer_custody"] ["timer.armed", "timer.matured", "timer.acknowledged"])
    , ("provider_response_loss", req ["provider.response_loss"] ["readiness.independent_model"] ["provider.response_lost"])
    , ("crash_reconstruction", req ["generation.crash", "generation.restart"] ["readiness.generation_load"] ["generation.reloaded"])
    , ("conversation_effect", req ["agent.conversation_terminal"] ["readiness.independent_model"] ["agent.conversation_called"])
    , ("coding_effect", req ["agent.coding_terminal"] ["readiness.independent_model"] ["agent.coding_called"])
    , ("git_mutation", req ["git.provider_request"] ["readiness.git_custody"] ["git.accepted"])
    , ("git_ambiguity_recovery", req ["git.response_loss", "git.recovery_grant"] ["readiness.git_custody"] ["git.faultm_then_pushed", "git.recovery_authorized"])
    , ("fair_convergence", req ["fair.begin"] ["readiness.fair_boundary"] ["fair.converged"])
    , ("checker_activation", req ["world.accepted_operation"] ["readiness.independent_model"] ["checker.passed"])
    , ("exact_replay", req ["petrus.replay"] ["petrus.exact_replay"] ["replay.exact"])
    ]
  where
    req a c o = (Set.fromList a, Set.fromList c, Set.fromList o)

blockedDimensions :: Map Text (Text, Text)
blockedDimensions =
  Map.fromList
    [
      ( "ci_rerun_repair"
      ,
        ( "V5 CI truth is observable, but the DST profile has no rerun request/terminal adapter or independent recovery checker."
        , "Revisit when DS3 adds the modeled CI rerun boundary and drives the real V5 repair loop."
        )
      )
    ,
      ( "agent_terminal_fault_cuts"
      ,
        ( "Agent terminals are modeled, but no deterministic pre/post-terminal fault cut is executable."
        , "Revisit when DS3 adds named agent terminal cuts with custody and retry outcomes."
        )
      )
    ,
      ( "stale_rate_limited_reads"
      ,
        ( "The modeled provider has no stale-read or rate-limit/unavailability schedule adapter."
        , "Revisit when provider read outcomes are first-class normalized commands or faults."
        )
      )
    ,
      ( "history_dispatch_fault_cuts"
      ,
        ( "Remaining canonical History and Motus Dispatch cut names have no application profile adapters."
        , "Revisit when each public-boundary cut has a checker-visible durable disposition."
        )
      )
    ]

crashOutcomes :: Map Text Text
crashOutcomes =
  Map.fromList
    [ ("generated_authority_lifecycle_cut", "crash.cut.authority_lifecycle")
    , ("generated_timer_before_due", "crash.cut.timer_before_due")
    , ("generated_timer_after_due", "crash.cut.timer_after_due")
    , ("generated_timer_after_acceptance", "crash.cut.timer_after_acceptance")
    , ("generated_git_before_delivery", "crash.cut.git_before_delivery")
    , ("generated_git_after_acceptance", "crash.cut.git_after_acceptance")
    , ("generated_git_after_head", "crash.cut.git_after_head")
    ]

maxRuns, maxOperations, maxChecks, maxArtifactBytes, maxTotalArtifactBytes, maxReportBytes :: Int
maxRuns = 16
maxOperations = 8192
maxChecks = 8192
maxArtifactBytes = 4194304

-- | The length in bytes of pydantic's @model_dump_json()@ for a model whose
-- JSON-mode dump is this value: the reference bounds each artifact by
-- @len(artifact.model_dump_json().encode())@. pydantic-core writes compact
-- JSON in field order (irrelevant to the length), non-ASCII text as raw
-- UTF-8, controls as @serde_json@ escapes them, and floats in @ryu@'s
-- layout with a signed positive exponent (@1e+16@, @1.5e-7@, @0.00001@,
-- @100.0@).
modelDumpJsonLength :: Json -> Int
modelDumpJsonLength = \case
  Null -> 4
  Bool True -> 4
  Bool False -> 5
  Int n -> length (show n)
  Float d -> ryuLength d
  String s -> stringLength s
  Array items -> 2 + commas items + sum (map modelDumpJsonLength items)
  Object members -> 2 + commas members + sum [stringLength k + 1 + modelDumpJsonLength v | (k, v) <- members]
  where
    commas xs = max 0 (length xs - 1)
    stringLength = T.foldl' (\n c -> n + charLength c) 2
    charLength c
      | c == '"' || c == '\\' || c == '\b' || c == '\t' || c == '\n' || c == '\f' || c == '\r' = 2
      | c < ' ' = 6
      | c < '\x80' = 1
      | c < '\x800' = 2
      | c < '\x10000' = 3
      | otherwise = 4
    -- ryu's format64: a sign, then the shortest digits laid out by the
    -- decimal exponent (10^(kk-1) <= |d| < 10^kk)
    ryuLength d
      | d == 0 = if isNegativeZero d then 4 else 3
      | otherwise = (if d < 0 then 1 else 0) + layout
      where
        (digits, k) = stripZeros (shortestDigits (abs d))
        size = length (show digits)
        kk = size + k
        -- a positive exponent is signed (`1e+16`), a negative one is not padded
        exponentSize = length (show (kk - 1)) + (if kk > 1 then 1 else 0)
        layout
          | 0 <= k && kk <= 16 = kk + 2
          | 0 < kk && kk <= 16 = size + 1
          | -5 < kk && kk <= 0 = size + 2 - kk
          | size == 1 = 2 + exponentSize
          | otherwise = size + 2 + exponentSize
    stripZeros (m, e)
      | m /= 0 && m `mod` 10 == 0 = stripZeros (m `div` 10, e + 1)
      | otherwise = (m, e)
maxTotalArtifactBytes = 16777216
maxReportBytes = 262144

-- | @_SCENARIO.fullmatch@.
scenarioMatches :: Text -> Bool
scenarioMatches s = case T.uncons s of
  Just (c, rest) -> alnum c && T.length rest <= 127 && T.all (\x -> alnum x || x `elem` ("_.:-" :: String)) rest
  Nothing -> False
  where
    alnum x = isAsciiLower x || isAsciiUpper x || isDigit x

-- | @_DIGEST.fullmatch@.
digestMatches :: Text -> Bool
digestMatches s = case T.stripPrefix "sha256:" s of
  Just hex -> T.length hex == 64 && T.all (\c -> isDigit c || (isHexDigit c && isAsciiLower c)) hex
  Nothing -> False

-- ---------------------------------------------------------------------------
-- The report

-- | @CoverageRun(artifact, replay)@.
data CoverageRun = CoverageRun
  { artifact :: AnyArtifact
  , replay :: Maybe ReplayResult
  }

data ScenarioReference = ScenarioReference
  { scenarioId :: Text
  , journalDigest :: Text
  , replayed :: Bool
  }
  deriving stock (Eq, Show)

-- | @ScenarioDimensionEvidence@.
data Evidence = Evidence
  { scenarioId :: Text
  , journalDigest :: Text
  , checkpoint :: Integer
  , adapters :: [Text]
  , checkers :: [Text]
  , outcomes :: [Text]
  }
  deriving stock (Eq, Show)

data CoverageDimension = CoverageDimension
  { name :: Text
  , status :: Text
  , evidence :: [Evidence]
  , blockedReason :: Maybe Text
  , revisitTrigger :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @ReadinessCoverageReport@ (format, version and API are constants).
data CoverageReport = CoverageReport
  { profile :: ProfileIdentity
  , checker :: CheckerIdentity
  , scenarios :: [ScenarioReference]
  , dimensions :: [CoverageDimension]
  }
  deriving stock (Eq, Show)

covered, blocked :: CoverageReport -> Set Text
covered r = Set.fromList [d.name | d <- r.dimensions, d.status == "covered"]
blocked r = Set.fromList [d.name | d <- r.dimensions, d.status == "blocked"]

-- | @report.model_dump(mode="json")@.
coverageJson :: CoverageReport -> Json
coverageJson r =
  Object
    [ ("format", String "hamsterdan-readiness-semantic-coverage")
    , ("version", Int 1)
    , ("artifact_api", String "petrus.testing.dst/v4")
    , ("profile", toJson r.profile)
    , ("checker", toJson r.checker)
    , ("scenarios", Array [Object [("scenario_id", String s.scenarioId), ("journal_digest", String s.journalDigest), ("replayed", Bool s.replayed)] | s <- r.scenarios])
    , ("dimensions", Array (map dimensionJson r.dimensions))
    ]
  where
    dimensionJson d =
      Object
        [ ("name", String d.name)
        , ("status", String d.status)
        , ("evidence", Array (map evidenceJson d.evidence))
        , ("blocked_reason", maybe Null String d.blockedReason)
        , ("revisit_trigger", maybe Null String d.revisitTrigger)
        ]
    evidenceJson e =
      Object
        [ ("scenario_id", String e.scenarioId)
        , ("journal_digest", String e.journalDigest)
        , ("checkpoint", Int e.checkpoint)
        , ("adapters", Array (map String e.adapters))
        , ("checkers", Array (map String e.checkers))
        , ("outcomes", Array (map String e.outcomes))
        ]

-- | @encode_readiness_coverage(report)@.
encodeReadinessCoverage :: CoverageReport -> ByteString
encodeReadinessCoverage = canonical . coverageJson

-- ---------------------------------------------------------------------------
-- Collection

valueErr :: Text -> Either PyError a
valueErr = Left . PyError "ValueError"

-- | @collect_readiness_coverage(runs)@.
collectReadinessCoverage :: [CoverageRun] -> Either PyError CoverageReport
collectReadinessCoverage runs = do
  when (null runs || length runs > maxRuns) $
    valueErr ("readiness coverage requires 1 to at most " <> tshow maxRuns <> " scenario runs")
  let go _ _ acc [] = Right (reverse acc)
      go byId (ops, checks, bytes) acc (run : rest) = do
        a <- case run.artifact of
          ArtifactV4 v4 -> Right v4
          ArtifactV1 v -> scenarioFirst v.scenarioId byId >> notV4
          ArtifactV2 v -> scenarioFirst v.scenarioId byId >> notV4
          ArtifactV3 v -> scenarioFirst v.scenarioId byId >> notV4
        _ <- scenarioFirst a.scenarioId byId
        let digest = a.expected.journalDigest
        case Map.lookup a.scenarioId byId of
          Just previous
            | previous /= digest -> valueErr "coverage scenario identity is contradictory"
            | otherwise -> valueErr "coverage scenario identity is duplicated"
          Nothing -> Right ()
        requireCompatible a
        let ops' = ops + length a.operations
            checks' = checks + length a.expected.checks
            encoded = modelDumpJsonLength (toJson (ArtifactV4 a))
        when (encoded > maxArtifactBytes) $ valueErr "coverage artifact exceeds the per-scenario byte bound"
        let bytes' = bytes + encoded
        when (ops' > maxOperations || checks' > maxChecks) $ valueErr "coverage evidence exceeds operation or checker bounds"
        when (bytes' > maxTotalArtifactBytes) $ valueErr "coverage evidence exceeds the aggregate byte bound"
        isReplayed <- maybe (Right False) (requireExactReplay a) run.replay
        points <- extractCheckpoints a isReplayed
        go (Map.insert a.scenarioId digest byId) (ops', checks', bytes') ((a, isJust run.replay, points) : acc) rest
      scenarioFirst sid _ = unless (scenarioMatches sid) (valueErr "coverage scenario identity is not bounded")
      notV4 = valueErr "readiness coverage requires a Petrus DST v4 artifact"
  normalized <- sortOn (\(a, _, _) -> a.scenarioId) <$> go Map.empty (0, 0, 0) [] runs
  let references = [ScenarioReference a.scenarioId a.expected.journalDigest r | (a, r, _) <- normalized]
      report =
        CoverageReport
          { profile = profileIdentity
          , checker = checkerIdentity
          , scenarios = references
          , dimensions = map (dimension normalized) dimensionNames
          }
  when (BS.length (encodeReadinessCoverage report) > maxReportBytes) $
    valueErr "readiness coverage report exceeds its byte bound"
  Right report

requireCompatible :: ScenarioArtifactV4 -> Either PyError ()
requireCompatible a = do
  unless (a.profile == profileIdentity) $ valueErr "readiness coverage artifact has a foreign profile"
  unless (a.checkers == [checkerIdentity]) $ valueErr "readiness coverage artifact has a foreign checker catalog"
  unless (digestMatches a.expected.journalDigest) $ valueErr "readiness coverage artifact has an invalid journal digest"

requireExactReplay :: ScenarioArtifactV4 -> ReplayResult -> Either PyError Bool
requireExactReplay a r = do
  unless (r.scenarioId == a.scenarioId) $ valueErr "replay scenario does not match coverage artifact"
  unless (r.disposition == a.expected.disposition) $ valueErr "replay disposition does not match coverage artifact"
  unless (r.failure == a.expected.failure) $ valueErr "replay failure does not match coverage artifact"
  unless (r.operations == toInteger (length a.operations)) $ valueErr "replay operation count does not match coverage artifact"
  unless (r.journalDigest == a.expected.journalDigest) $ valueErr "replay journal digest does not match coverage artifact"
  Right True

dimension :: [(ScenarioArtifactV4, Bool, [Checkpoint])] -> Text -> CoverageDimension
dimension runs name = case Map.lookup name blockedDimensions of
  Just (reason, trigger) -> CoverageDimension name "blocked" [] (Just reason) (Just trigger)
  Nothing ->
    let found = mapMaybe (\(a, _, points) -> scenarioEvidence name a.scenarioId a.expected.journalDigest points) runs
     in CoverageDimension name (if any (complete name) found then "covered" else "uncovered") found Nothing Nothing

requirementsOf :: Text -> Requirements
requirementsOf name = Map.findWithDefault (Set.empty, Set.empty, Set.empty) name requirements

complete :: Text -> Evidence -> Bool
complete name e =
  let (a, c, o) = requirementsOf name
   in a `Set.isSubsetOf` Set.fromList e.adapters && c `Set.isSubsetOf` Set.fromList e.checkers && o `Set.isSubsetOf` Set.fromList e.outcomes

scenarioEvidence :: Text -> Text -> Text -> [Checkpoint] -> Maybe Evidence
scenarioEvidence name sid digest points =
  case candidates of
    [] -> Nothing
    first : rest -> Just (foldl (\best x -> if key x > key best then x else best) first rest)
  where
    (reqA, reqC, reqO) = requirementsOf name
    relevantA = if name == "provider_response_loss" then Set.insert "git.response_loss" reqA else reqA
    relevantO
      | name == "lifecycle_movement" = reqO <> Set.fromList ["lifecycle.draft", "lifecycle.resumed", "lifecycle.closed"]
      | name == "crash_reconstruction" = reqO <> Set.fromList (Map.elems crashOutcomes)
      | otherwise = reqO
    candidates =
      [ Evidence sid digest p.position adapters checkers outcomes
      | p <- points
      , let adapters = Set.toAscList (p.signals.adapters `Set.intersection` relevantA)
            checkers = Set.toAscList (p.signals.checkers `Set.intersection` reqC)
            outcomes = Set.toAscList (p.signals.outcomes `Set.intersection` relevantO)
      , not (null adapters && null checkers && null outcomes)
      ]
    key e =
      ( complete name e
      , Set.size (reqA `Set.intersection` Set.fromList e.adapters)
          + Set.size (reqC `Set.intersection` Set.fromList e.checkers)
          + Set.size (reqO `Set.intersection` Set.fromList e.outcomes)
      , e.checkpoint
      )

-- ---------------------------------------------------------------------------
-- Checkpoints

data Signals = Signals
  { adapters :: Set Text
  , checkers :: Set Text
  , outcomes :: Set Text
  }

data Checkpoint = Checkpoint
  { position :: Integer
  , signals :: Signals
  }

-- | @_object(value, label)@.
object :: Json -> Text -> Either PyError [(Text, Json)]
object value label = case value of
  Object members -> Right members
  _ -> valueErr (label <> " must be a strict object")

get :: Text -> [(Text, Json)] -> Json
get key members = maybe Null id (lookup key members)

-- | @_extract_checkpoints(artifact, replayed=...)@.
extractCheckpoints :: ScenarioArtifactV4 -> Bool -> Either PyError [Checkpoint]
extractCheckpoints a isReplayed = do
  let byPosition = Map.fromList [(operationPosition op, op) | op <- a.operations]
      visit (points, certified, allPassed, fairChecked) entry = do
        unless (entry.kind == JCheck && entry.name == identityName checkerIdentity) $
          valueErr "readiness coverage artifact contains an unexpected checker entry"
        value <- object entry.value "checker entry"
        unless (Set.fromList (map fst value) == Set.fromList ["checker", "trigger", "observation", "result"] && length value == 4) $
          valueErr "checker entry must contain exact fields ['checker', 'observation', 'result', 'trigger']"
        unless (get "checker" value == toJson checkerIdentity) $ valueErr "readiness coverage checker identity is contradictory"
        trigger <- case get "trigger" value of
          String t -> Right t
          _ -> valueErr "readiness coverage checker trigger is malformed"
        observation <- schema "Observation" (pObservation [] (get "observation" value))
        result <- schema "CheckResult" (pCheckResult [] (get "result" value))
        _ <- readinessState observation
        if not result.passed
          then Right (points, certified, False, fairChecked)
          else do
            let certified' = certified <> [observation]
                position = observation.sequence
                base = if trigger == "create" then -1 else position
                prefix = case Map.lookup position byPosition of
                  Just (Accepted (OpCrash _)) -> base - 1
                  _ -> base
            signals <- operationSignals a prefix certified'
            checkerSignals' <- checkerSignals trigger result
            let signals' = Signals signals.adapters (signals.checkers <> checkerSignals') (Set.insert "checker.passed" signals.outcomes)
            Right (points <> [Checkpoint position signals'], certified', allPassed, fairChecked || trigger == "begin_fair")
  (points, certified, allPassed, fairChecked) <- foldlE visit ([], [], True, False) a.expected.checks
  let finishes = [f | Accepted (OpFinish f) <- a.operations]
  when (length finishes > 1) $ valueErr "readiness coverage artifact has multiple finish operations"
  finishPoint <- case finishes of
    [finish]
      | finish.disposition == Converged && fairChecked && allPassed && isNothing a.expected.failure -> do
          signals <- operationSignals a finish.position certified
          Right
            [ Checkpoint
                finish.position
                (Signals signals.adapters (Set.insert "readiness.fair_boundary" signals.checkers) (Set.insert "fair.converged" signals.outcomes))
            ]
    _ -> Right []
  let replayPoint =
        [ Checkpoint
            (maximum (0 : map operationPosition a.operations))
            (Signals (Set.singleton "petrus.replay") (Set.singleton "petrus.exact_replay") (Set.singleton "replay.exact"))
        | isReplayed
        ]
  Right (points <> finishPoint <> replayPoint)

identityName :: Identity k -> Text
identityName i = i.name

foldlE :: (b -> x -> Either e b) -> b -> [x] -> Either e b
foldlE f = go
  where
    go acc [] = Right acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

schema :: Text -> Parser x -> Either PyError x
schema modelName = either (\e -> Left (PyError "ValidationError" (renderSchemaError modelName e))) Right

-- | @_operation_signals(artifact, prefix_position, observations)@.
operationSignals :: ScenarioArtifactV4 -> Integer -> [Observation] -> Either PyError Signals
operationSignals a prefix observations = do
  let visit (adapters, outcomes, authorities, lifecycles, deliveries) op
        | operationPosition op > prefix = Right (adapters, outcomes, authorities, lifecycles, deliveries)
        | otherwise = case op of
            Accepted (OpExecute e) -> do
              let adapters0 = Set.insert "world.accepted_operation" adapters
                  name = e.command.name
              payload <- object e.command.payload (name <> " payload")
              if
                | name == "readiness.github.pr.set" -> do
                    authority <- object (get "authority" payload) "authority command"
                    lifecycle <- case get "lifecycle" authority of
                      String l -> Right l
                      _ -> valueErr "authority lifecycle is malformed"
                    Right (Set.insert "authority.set" adapters0, outcomes, authorities <> [Object authority], lifecycles <> [lifecycle], deliveries)
                | name == "readiness.github.webhook.deliver" -> do
                    delivery <- case get "delivery" payload of
                      String d -> Right d
                      _ -> valueErr "webhook delivery evidence is malformed"
                    result <- object e.result.value "webhook delivery result"
                    let outcomes' = if get "disposition" result == String "duplicate" then Set.insert "webhook.duplicate" outcomes else outcomes
                    Right (adapters0, outcomes', authorities, lifecycles, Map.insertWith (+) delivery (1 :: Int) deliveries)
                | name == "readiness.time.advance" -> Right (Set.insert "time.advance" adapters0, outcomes, authorities, lifecycles, deliveries)
                | name == "readiness.agent.terminal" ->
                    let fixture = get "fixture" payload
                        adapters'
                          | fixture `elem` [String "conversation_change", String "conversation_recover"] = Set.insert "agent.conversation_terminal" adapters0
                          | fixture == String "coding" = Set.insert "agent.coding_terminal" adapters0
                          | otherwise = adapters0
                     in Right (adapters', outcomes, authorities, lifecycles, deliveries)
                | name == "readiness.github.human.comment" ->
                    let adapters' = case get "fixture" payload of
                          String f | "recover:" `T.isPrefixOf` f -> Set.insert "git.recovery_grant" adapters0
                          _ -> adapters0
                     in Right (adapters', outcomes, authorities, lifecycles, deliveries)
                | otherwise -> Right (adapters0, outcomes, authorities, lifecycles, deliveries)
            Accepted (OpFault f) -> do
              payload <- object f.fault.payload "fault payload"
              let cut = get "cut" payload
                  adapters'
                    | f.fault.name == "readiness.github.effect" && cut == String "after_acceptance_before_response" = Set.insert "provider.response_loss" adapters
                    | f.fault.name == "readiness.git.publish" && cut == String "ref_cas" = adapters <> Set.fromList ["provider.response_loss", "git.response_loss"]
                    | otherwise = adapters
              Right (adapters', outcomes, authorities, lifecycles, deliveries)
            Accepted (OpCrash c) ->
              Right
                ( Set.insert "generation.crash" adapters
                , maybe outcomes (`Set.insert` outcomes) (Map.lookup c.cut crashOutcomes)
                , authorities
                , lifecycles
                , deliveries
                )
            Accepted (OpRestart _) -> Right (Set.insert "generation.restart" adapters, outcomes, authorities, lifecycles, deliveries)
            Accepted (OpFair _) -> Right (Set.insert "fair.begin" adapters, outcomes, authorities, lifecycles, deliveries)
            Accepted (OpFinish f)
              | f.disposition == Converged -> Right (adapters, Set.insert "fair.converged" outcomes, authorities, lifecycles, deliveries)
            _ -> Right (adapters, outcomes, authorities, lifecycles, deliveries)
  (adapters0, outcomes0, authorities, lifecycles, deliveries) <- foldlE visit (Set.empty, Set.empty, [], [], Map.empty) a.operations
  let adapters1 = if any (> 1) (Map.elems deliveries) then Set.insert "webhook.redelivery" adapters0 else adapters0
  states <- mapM readinessState observations
  (generations, observedLifecycles, outcomes1, adapters2) <- stateOutcomes states outcomes0 adapters1
  let distinct = Set.fromList (map canonical authorities)
      lifecycleSet = Set.fromList lifecycles
      moved = Set.size distinct > 1 && maximum (0 : generations) > 1
      outcomes2 = if moved then Set.insert "authority.generation_moved" outcomes1 else outcomes1
      outcomes3
        | Set.size lifecycleSet > 1 && lifecycleSet `Set.isSubsetOf` observedLifecycles =
            Set.fromList
              ( ["lifecycle.changed"]
                  <> ["lifecycle.draft" | "draft" `elem` lifecycles]
                  <> ["lifecycle.closed" | "closed" `elem` lifecycles]
                  <> ["lifecycle.resumed" | or (zipWith (\p c -> p == "draft" && c == "active") lifecycles (drop 1 lifecycles))]
              )
              <> outcomes2
        | otherwise = outcomes2
      outcomes4 = if maximum (0 : map (.generation) observations) > 1 then Set.insert "generation.reloaded" outcomes3 else outcomes3
  Right (Signals adapters2 Set.empty outcomes4)

-- | @_checker_signals(trigger, result)@.
checkerSignals :: Text -> CheckResult -> Either PyError (Set Text)
checkerSignals trigger result = do
  detail <- object result.detail "checker detail"
  let at k = get k detail
  Right . Set.fromList $
    ["readiness.independent_model"]
      <> [ "readiness.authority"
         | at "parity" == Bool True && at "snapshot_parity" == Bool True && at "authority_lag" == Bool False && at "violations" == Array []
         ]
      <> [ "readiness.no_duplicate_effect"
         | at "duplicate_acceptance" == Array [] && at "duplicate_terminal_projection" == Array [] && at "effect_identity_collisions" == Array []
         ]
      <> ["readiness.timer_custody" | at "timer_custody_parity" == Bool True && at "timer_custody_mismatches" == Array []]
      <> ["readiness.git_custody" | at "git_custody_parity" == Bool True && at "git_custody_mismatches" == Array []]
      <> ["readiness.generation_load" | trigger == "load"]
      <> ["readiness.fair_boundary" | trigger == "begin_fair"]

-- | @_state_outcomes(states, outcomes, adapters)@.
stateOutcomes :: [[(Text, Json)]] -> Set Text -> Set Text -> Either PyError ([Integer], Set Text, Set Text, Set Text)
stateOutcomes states outcomes0 adapters0 = foldlE visit ([], Set.empty, outcomes0, adapters0) states
  where
    isDict = \case
      Object _ -> True
      _ -> False
    member k = \case
      Object xs -> maybe Null id (lookup k xs)
      _ -> Null
    visit (generations, lifecycles, outcomes, adapters) state = do
      expected <- object (get "expected" state) "expected readiness state"
      let generations' = case get "generation" expected of
            Int g -> generations <> [g]
            _ -> generations
      facts <- object (get "facts" state) "readiness facts"
      authority <- object (get "authority" facts) "readiness authority facts"
      claimed <- forM [get "admitted" authority, get "provider" authority] $ \case
        Null -> Right Nothing
        claim -> do
          members <- object claim "observed readiness authority"
          case get "lifecycle" members of
            String l -> Right (Just l)
            _ -> valueErr "observed readiness lifecycle is malformed"
      let lifecycles' = lifecycles <> Set.fromList [l | Just l <- claimed]
      timers <- case get "timers" facts of
        Array xs -> Right xs
        _ -> valueErr "readiness timer facts are malformed"
      custody <- object (get "timer_custody" state) "timer custody"
      durable <- case get "timers" custody of
        Array xs -> Right xs
        _ -> valueErr "durable timer custody is malformed"
      provider <- object (get "provider" state) "provider observation"
      (losses, publications, calls) <- case (get "response_losses" provider, get "git_publications" provider, get "agent_call_log" provider) of
        (Array l, Array p, Array c) -> Right (l, p, c)
        _ -> valueErr "provider coverage observation is malformed"
      recoveries <- case get "admitted_recoveries" provider of
        Array r -> Right r
        _ -> valueErr "provider recovery observation is malformed"
      gitCustody <- object (get "git_custody" state) "Git custody"
      (requests, terminals) <- case (get "requests" gitCustody, get "terminals" gitCustody) of
        (Array r, Array t) -> Right (r, t)
        _ -> valueErr "Git custody observation is malformed"
      let variants = [member "variant" t | t <- terminals, isDict t]
          firstIndex v = lookup v (zip variants [0 :: Int ..])
          added =
            ["timer.acknowledged" | any (\t -> isDict t && member "status" t == String "acknowledged") timers]
              <> ["timer.armed" | any (\t -> isDict t && member "state" t == String "armed") durable]
              <> ["timer.matured" | any (\t -> isDict t && member "matured_at" t /= Null) durable]
              <> ["provider.response_lost" | not (null losses) || any (\p -> isDict p && member "response_lost" p == Bool True) publications]
              <> ["agent.conversation_called" | any (\c -> isDict c && member "kind" c == String "conversation") calls]
              <> ["agent.coding_called" | any (\c -> isDict c && member "kind" c == String "coding") calls]
              <> ["git.accepted" | not (null publications)]
              <> ["git.recovery_authorized" | not (null recoveries)]
              <> [ "git.faultm_then_pushed"
                 | Just f <- [firstIndex (String "FaultM")]
                 , Just p <- [firstIndex (String "Pushed")]
                 , f < p
                 ]
          adapters' = if null requests then adapters else Set.insert "git.provider_request" adapters
      Right (generations', lifecycles', outcomes <> Set.fromList added, adapters')

-- | @_readiness_state(observation)@.
readinessState :: Observation -> Either PyError [(Text, Json)]
readinessState o = do
  unless (o.name == "readiness.state") $ valueErr "readiness coverage encountered a foreign observation"
  object o.value "readiness observation"

-- ---------------------------------------------------------------------------
-- Loading

-- | @load_readiness_coverage(data)@: pydantic's @model_validate_json@, whose
-- JSON parser (jiter) refuses a lone surrogate escape, as this one does.
loadReadinessCoverage :: ByteString -> Either PyError CoverageReport
loadReadinessCoverage bytes = do
  when (BS.length bytes > maxReportBytes) $ valueErr "readiness coverage report exceeds its byte bound"
  value <- case parseJson surrogateRefusingLoads bytes of
    Right v -> Right v
    Left problem -> Left (PyError "ValidationError" ("1 validation error for ReadinessCoverageReport\n  Invalid JSON: " <> T.pack problem <> " [type=json_invalid]"))
  schema "ReadinessCoverageReport" (pReport [] value)

-- | A string field with pydantic's length bounds and (unanchored) pattern.
pBoundedStr :: Maybe Int -> Maybe Int -> Maybe (Text, Text -> Bool) -> Path -> Json -> Parser Text
pBoundedStr low high pattern path v = do
  s <- pStr path v
  case low of
    Just l | T.length s < l -> failAt path "string_too_short" ("String should have at least " <> tshow l <> " character" <> plural l)
    _ -> Right ()
  case high of
    Just h | T.length s > h -> failAt path "string_too_long" ("String should have at most " <> tshow h <> " character" <> plural h)
    _ -> Right ()
  case pattern of
    Just (spelled, matches) | not (matches s) -> failAt path "string_pattern_mismatch" ("String should match pattern '" <> spelled <> "'")
    _ -> Right ()
  Right s
  where
    plural n = if n == 1 then "" else "s"

-- | A tuple field with a length bound.
pTuple :: Maybe Int -> Maybe Int -> (Path -> Json -> Parser a) -> Path -> Json -> Parser [a]
pTuple low high p path v = do
  items <- case v of
    Array xs -> Right xs
    _ -> failAt path "tuple_type" "Input should be a valid tuple"
  case high of
    Just h | length items > h -> failAt path "too_long" ("Tuple should have at most " <> tshow h <> " item" <> plural h <> " after validation, not " <> tshow (length items))
    _ -> Right ()
  case low of
    Just l | length items < l -> failAt path "too_short" ("Tuple should have at least " <> tshow l <> " item" <> plural l <> " after validation, not " <> tshow (length items))
    _ -> Right ()
  pList p path v
  where
    plural n = if n == 1 then "" else "s"

-- | Search semantics: pydantic patterns are unanchored.
scenarioPattern, digestPattern :: (Text, Text -> Bool)
scenarioPattern = ("[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}", T.any (\c -> isAsciiLower c || isAsciiUpper c || isDigit c))
digestPattern = ("sha256:[0-9a-f]{64}", hasDigest)
  where
    hasDigest s = any (\rest -> T.length (T.takeWhile lowerHex rest) >= 64) [T.drop 7 t | t <- T.tails s, "sha256:" `T.isPrefixOf` t]
    lowerHex c = isDigit c || (isHexDigit c && isAsciiLower c)

pReport :: Path -> Json -> Parser CoverageReport
pReport path v = do
  f <- model "ReadinessCoverageReport" ["format", "version", "artifact_api", "profile", "checker", "scenarios", "dimensions"] path v
  _ <- field f "format" (pLiteral [(String "hamsterdan-readiness-semantic-coverage", ())])
  _ <- field f "version" (pLiteral [(Int 1, ())])
  _ <- field f "artifact_api" (pLiteral [(String "petrus.testing.dst/v4", ())])
  profile <- field f "profile" pProfileIdentity
  checker <- field f "checker" pCheckerIdentity
  scenarios <- field f "scenarios" (pTuple (Just 1) (Just maxRuns) pReference)
  dimensions <- field f "dimensions" (pTuple Nothing Nothing pDimension)
  let report = CoverageReport {profile, checker, scenarios, dimensions}
      references = Map.fromList [(s.scenarioId, s.journalDigest) | s <- scenarios]
  unless (profile == profileIdentity && checker == checkerIdentity) $
    valueError path "coverage report dependency identities do not match its contract"
  unless (map (.name) dimensions == dimensionNames) $
    valueError path "coverage report must contain the ordered complete dimension catalog"
  unless (sortOn (.scenarioId) scenarios == scenarios && Set.size (Set.fromList (map (.scenarioId) scenarios)) == length scenarios) $
    valueError path "coverage scenarios must be unique and ordered"
  forM_ dimensions $ \d -> forM_ d.evidence $ \e ->
    unless (Map.lookup e.scenarioId references == Just e.journalDigest) $
      valueError path "coverage evidence has no matching scenario reference"
  Right report

pReference :: Path -> Json -> Parser ScenarioReference
pReference path v = do
  f <- model "ScenarioReference" ["scenario_id", "journal_digest", "replayed"] path v
  ScenarioReference
    <$> field f "scenario_id" (pBoundedStr (Just 1) (Just 128) (Just scenarioPattern))
    <*> field f "journal_digest" (pBoundedStr Nothing Nothing (Just digestPattern))
    <*> field f "replayed" pBool

pEvidence :: Path -> Json -> Parser Evidence
pEvidence path v = do
  f <- model "ScenarioDimensionEvidence" ["scenario_id", "journal_digest", "checkpoint", "adapters", "checkers", "outcomes"] path v
  scenarioId <- field f "scenario_id" (pBoundedStr (Just 1) (Just 128) (Just scenarioPattern))
  journalDigest <- field f "journal_digest" (pBoundedStr Nothing Nothing (Just digestPattern))
  checkpoint <- field f "checkpoint" (pIntRange (Just 0) (Just (toInteger maxOperations)))
  adapters <- field f "adapters" (pTuple Nothing (Just 16) (literals adapterEvidence))
  checkers <- field f "checkers" (pTuple Nothing (Just 16) (literals checkerEvidence))
  outcomes <- field f "outcomes" (pTuple Nothing (Just 24) (literals outcomeEvidence))
  forM_ [("adapters", adapters), ("checkers", checkers), ("outcomes", outcomes)] $ \(label, values) ->
    unless (Set.toAscList (Set.fromList values) == values) $
      valueError path ("coverage " <> label <> " must be sorted and unique")
  when (null adapters && null checkers && null outcomes) $
    valueError path "scenario coverage evidence cannot be empty"
  Right Evidence {scenarioId, journalDigest, checkpoint, adapters, checkers, outcomes}

literals :: [Text] -> Path -> Json -> Parser Text
literals choices = pLiteral [(String c, c) | c <- choices]

pDimension :: Path -> Json -> Parser CoverageDimension
pDimension path v = do
  f <- model "CoverageDimension" ["name", "status", "evidence", "blocked_reason", "revisit_trigger"] path v
  name <- field f "name" (literals dimensionNames)
  status <- field f "status" (literals ["covered", "uncovered", "blocked"])
  evidence <- field f "evidence" (pTuple Nothing (Just maxRuns) pEvidence)
  blockedReason <- fieldDefault f "blocked_reason" Nothing (pNullable (pBoundedStr Nothing (Just 512) Nothing))
  revisitTrigger <- fieldDefault f "revisit_trigger" Nothing (pNullable (pBoundedStr Nothing (Just 512) Nothing))
  let d = CoverageDimension {name, status, evidence, blockedReason, revisitTrigger}
  unless (sortOn (.scenarioId) evidence == evidence && Set.size (Set.fromList (map (.scenarioId) evidence)) == length evidence) $
    valueError path "dimension evidence must have unique ordered scenarios"
  case Map.lookup name blockedDimensions of
    Just (reason, trigger) -> do
      unless (status == "blocked" && null evidence && blockedReason == Just reason && revisitTrigger == Just trigger) $
        valueError path "blocked dimension must retain its exact reason and revisit trigger"
      Right d
    Nothing -> do
      unless (isNothing blockedReason && isNothing revisitTrigger) $
        valueError path "executable dimension cannot carry a blocked reason"
      let isComplete = any (complete name) evidence
      when (status == "covered" && not isComplete) $
        valueError path "covered dimension requires complete scenario evidence"
      when (status == "uncovered" && isComplete) $
        valueError path "uncovered dimension contradicts complete scenario evidence"
      when (status == "blocked") $
        valueError path "executable dimension cannot be blocked"
      Right d

tshow :: (Show a) => a -> Text
tshow = T.pack . show
