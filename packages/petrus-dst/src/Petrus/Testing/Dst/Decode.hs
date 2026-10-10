{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Strict validation of JSON values into the DST model, mirroring the
-- reference's pydantic models (@extra="forbid"@, @strict=True@, field
-- constraints, field validators, and model validators).
--
-- A refusal reports one 'SchemaError' with pydantic's location (including
-- discriminated-union tags), error type, and message. The reference reports
-- every error at once; the first one found here is always among them.
-- Model-level coherence refusals carry the reference's exact message with an
-- empty location, as pydantic reports @model_validator@ failures.
module Petrus.Testing.Dst.Decode
  ( -- * Errors
    SchemaError (..)
  , LocPart (..)
  , renderLoc
  , renderSchemaError

    -- * Parsing primitives
  , Parser
  , Path
  , Fields
  , failAt
  , model
  , field
  , fieldDefault
  , pInt
  , pIntRange
  , pStr
  , pBool
  , pList
  , pNullable
  , pLiteral
  , pJsonValue
  , pIntDict
  , tagged
  , valueError

    -- * Model parsers
  , pProfileIdentity
  , pCheckerIdentity
  , pCommand
  , pFault
  , pBudget
  , pBudgetV4
  , pAnyBudget
  , pScheduledCommand
  , pApplyResult
  , pObservationRequest
  , pObservation
  , pCheckResult
  , pResourceUsage
  , pOperationAttempt
  , pProcessAttempt
  , pFailureDetail
  , pAcceptedOperation
  , pExpandedOperation
  , pJournalEntry
  , pChoiceProvenance
  , pDisposition
  , pAuthoredDisposition
  , pArtifactV1
  , pArtifactV2
  , pArtifactV3
  , pArtifactV4
  , artifactCoherence
  , attemptProducedOperation
  , checkResourceValues
  , strictJsonPath
  ) where

import Control.Monad (forM, forM_, unless, when, zipWithM)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst.Choice (validProvenanceDraws)
import Petrus.Testing.Dst.PyRepr (PyObj (..), jsonToPy, pyRepr)
import Petrus.Testing.Dst.Types

-- ---------------------------------------------------------------------------
-- Errors

-- | One pydantic location step.
data LocPart = LKey Text | LIndex Int
  deriving stock (Eq, Ord, Show)

-- | One validation refusal, as pydantic reports it.
data SchemaError = SchemaError
  { loc :: [LocPart]
  , errorType :: Text
  , message :: Text
  }
  deriving stock (Eq, Show)

-- | Pydantic's dotted location spelling (@operations.0.observe.position@).
renderLoc :: [LocPart] -> Text
renderLoc = T.intercalate "." . map part
  where
    part (LKey k) = k
    part (LIndex i) = T.pack (show i)

-- | A pydantic-style report of a refusal for the named model:
-- @1 validation error for M\\nloc\\n  message [type=t]@.
renderSchemaError :: Text -> SchemaError -> Text
renderSchemaError modelName e =
  "1 validation error for "
    <> modelName
    <> "\n"
    <> (if null e.loc then "" else renderLoc e.loc <> "\n")
    <> "  "
    <> e.message
    <> " [type="
    <> e.errorType
    <> "]"

-- ---------------------------------------------------------------------------
-- Primitives

type Parser = Either SchemaError

-- | A reversed location.
type Path = [LocPart]

failAt :: Path -> Text -> Text -> Parser a
failAt path t m = Left (SchemaError (reverse path) t m)

valueError :: Path -> Text -> Parser a
valueError path m = failAt path "value_error" ("Value error, " <> m)

-- | A model's members, after the extra-field refusal.
data Fields = Fields Path [(Text, Json)]

-- | Admit one strict model object with exactly the named fields allowed.
model :: Text -> [Text] -> Path -> Json -> Parser Fields
model name keys path = \case
  Object members -> case [k | (k, _) <- members, k `notElem` keys] of
    k : _ -> failAt (LKey k : path) "extra_forbidden" "Extra inputs are not permitted"
    [] -> Right (Fields path members)
  _ -> failAt path "model_type" ("Input should be a valid dictionary or instance of " <> name)

-- | One required field.
field :: Fields -> Text -> (Path -> Json -> Parser a) -> Parser a
field (Fields path members) key p = case lookup key members of
  Just v -> p (LKey key : path) v
  Nothing -> failAt (LKey key : path) "missing" "Field required"

-- | One field with a default.
fieldDefault :: Fields -> Text -> a -> (Path -> Json -> Parser a) -> Parser a
fieldDefault (Fields path members) key def p = case lookup key members of
  Just v -> p (LKey key : path) v
  Nothing -> Right def

pInt :: Path -> Json -> Parser Integer
pInt path = \case
  Int i -> Right i
  _ -> failAt path "int_type" "Input should be a valid integer"

-- | An integer with optional inclusive bounds.
pIntRange :: Maybe Integer -> Maybe Integer -> Path -> Json -> Parser Integer
pIntRange low high path v = do
  i <- pInt path v
  case low of
    Just l | i < l -> failAt path "greater_than_equal" ("Input should be greater than or equal to " <> tshow l)
    _ -> Right ()
  case high of
    Just h | i > h -> failAt path "less_than_equal" ("Input should be less than or equal to " <> tshow h)
    _ -> Right ()
  Right i

pStr :: Path -> Json -> Parser Text
pStr path = \case
  String s -> Right s
  _ -> failAt path "string_type" "Input should be a valid string"

pBool :: Path -> Json -> Parser Bool
pBool path = \case
  Bool b -> Right b
  _ -> failAt path "bool_type" "Input should be a valid boolean"

pList :: (Path -> Json -> Parser a) -> Path -> Json -> Parser [a]
pList p path = \case
  Array items -> zipWithM (\i v -> p (LIndex i : path) v) [0 ..] items
  _ -> failAt path "list_type" "Input should be a valid list"

pNullable :: (Path -> Json -> Parser a) -> Path -> Json -> Parser (Maybe a)
pNullable p path = \case
  Null -> Right Nothing
  v -> Just <$> p path v

-- | A @Literal[...]@ field; admission uses CPython equality, as pydantic's
-- literal lookup does (so @True@ and @1.0@ match @Literal[1]@).
pLiteral :: [(Json, a)] -> Path -> Json -> Parser a
pLiteral choices path v = case [a | (j, a) <- choices, j == v] of
  a : _ -> Right a
  [] -> failAt path "literal_error" ("Input should be " <> expected)
  where
    reprs = map (pyRepr . literalPy . fst) choices
    expected = case reprs of
      [] -> ""
      [one] -> one
      _ -> T.intercalate ", " (init reprs) <> " or " <> last reprs
    literalPy = \case
      String s -> PyStr s
      Int i -> PyInt i
      _ -> PyNone

-- | A @JsonValue@ field with the reference's @_strict_json@ before-validator:
-- every number must be finite.
pJsonValue :: Text -> Path -> Json -> Parser Json
pJsonValue subject path v = case strictJsonPath v of
  Nothing -> Right v
  Just at -> valueError path (subject <> " has a non-finite number at " <> at)

-- | The @_strict_json@ path of the first non-finite number (@$@, @$[0]@,
-- @$.key@), if any.
strictJsonPath :: Json -> Maybe Text
strictJsonPath = go "$"
  where
    go at = \case
      Float d | isNaN d || isInfinite d -> Just at
      Array items -> firstJust [go (at <> "[" <> tshow i <> "]") item | (i, item) <- zip [0 :: Int ..] items]
      Object members -> firstJust [go (at <> "." <> k) item | (k, item) <- members]
      _ -> Nothing
    firstJust = foldr (\x acc -> maybe acc Just x) Nothing

-- | A @dict[str, int]@ field, returned in document order.
pIntDict :: Path -> Json -> Parser [(Text, Integer)]
pIntDict path = \case
  Object members -> forM members (\(k, v) -> (k,) <$> pInt (LKey k : path) v)
  _ -> failAt path "dict_type" "Input should be a valid dictionary"

-- | A union discriminated by @kind@; the chosen alternative's tag joins the
-- location, as in pydantic.
tagged :: [(Text, Path -> Json -> Parser a)] -> Path -> Json -> Parser a
tagged alternatives path v = case v of
  Object members -> case lookup "kind" members of
    Nothing -> failAt path "union_tag_not_found" "Unable to extract tag using discriminator 'kind'"
    Just (String tag) | Just p <- lookup tag alternatives -> p (LKey tag : path) v
    Just other ->
      failAt
        path
        "union_tag_invalid"
        ( "Input tag "
            <> tagRepr other
            <> " found using 'kind' does not match any of the expected tags: "
            <> T.intercalate ", " [pyRepr (PyStr t) | (t, _) <- alternatives]
        )
  _ -> failAt path "model_attributes_type" "Input should be a valid dictionary or object to extract fields from"
  where
    -- pydantic quotes @str(tag)@.
    tagRepr = \case
      String s -> pyRepr (PyStr s)
      other -> pyRepr (PyStr (pyRepr (jsonToPy other)))

-- ---------------------------------------------------------------------------
-- Components

pIdentity :: Text -> Path -> Json -> Parser (Identity k)
pIdentity modelName path v = do
  f <- model modelName ["name", "version", "digest"] path v
  name <- field f "name" $ \p x -> do
    s <- pStr p x
    unless (isName s) (valueError p "component identity name must use letters, digits, '.', ':', '_', or '-'")
    Right s
  version <- field f "version" (pIntRange (Just 1) Nothing)
  digest <- field f "digest" $ \p x -> do
    s <- pStr p x
    unless (isDigest s) (valueError p "component identity digest must be sha256:<64 lowercase hex>")
    Right s
  Right Identity {name, version, digest}

pProfileIdentity :: Path -> Json -> Parser ProfileIdentity
pProfileIdentity = pIdentity "ProfileIdentity"

pCheckerIdentity :: Path -> Json -> Parser CheckerIdentity
pCheckerIdentity = pIdentity "CheckerIdentity"

pCommand :: Path -> Json -> Parser Command
pCommand path v = do
  f <- model "Command" ["profile", "name", "payload"] path v
  profile <- field f "profile" pProfileIdentity
  name <- field f "name" $ \p x -> do
    s <- pStr p x
    unless (isName s && not ("dst." `T.isPrefixOf` s)) $
      valueError p "command name must be non-empty, normalized, and outside the reserved 'dst.' namespace"
    Right s
  payload <- field f "payload" (pJsonValue "command payload")
  Right Command {profile, name, payload}

pFault :: Path -> Json -> Parser Fault
pFault path v = do
  f <- model "Fault" ["profile", "name", "target", "occurrence", "disposition", "payload"] path v
  profile <- field f "profile" pProfileIdentity
  let faultName p x = do
        s <- pStr p x
        unless (isName s) (valueError p "fault name and target must be normalized non-empty names")
        Right s
  name <- field f "name" faultName
  target <- field f "target" faultName
  occurrence <- field f "occurrence" (pIntRange (Just 1) Nothing)
  disposition <- field f "disposition" (pLiteral [(String (faultDispositionText d), d) | d <- [minBound .. maxBound]])
  payload <- field f "payload" (pJsonValue "fault payload")
  Right Fault {profile, name, target, occurrence, disposition, payload}

budgetKeys :: [Text]
budgetKeys =
  ["actions", "queued_commands", "timer_advances", "logical_instant", "reloads", "predicate_polls", "artifact_bytes"]

budgetFields :: Fields -> Parser Budget
budgetFields f = do
  actions <- field f "actions" (pIntRange (Just 1) (Just 100000))
  queuedCommands <- field f "queued_commands" (pIntRange (Just 1) (Just 10000))
  timerAdvances <- field f "timer_advances" (pIntRange (Just 0) (Just 10000))
  logicalInstant <- field f "logical_instant" (pIntRange (Just 0) (Just maxPortableInteger))
  reloads <- field f "reloads" (pIntRange (Just 0) (Just 1000))
  predicatePolls <- field f "predicate_polls" (pIntRange (Just 1) (Just 100000))
  artifactBytes <- field f "artifact_bytes" (pIntRange (Just 1) (Just maxArtifactBytes))
  Right Budget {actions, queuedCommands, timerAdvances, logicalInstant, reloads, predicatePolls, artifactBytes}

pBudget :: Path -> Json -> Parser Budget
pBudget path v = model "Budget" budgetKeys path v >>= budgetFields

-- | The reference's @_resource_values@ validator, in document order.
checkResourceValues :: Text -> [(Text, Integer)] -> Maybe Text
checkResourceValues subject = go
  where
    go [] = Nothing
    go ((name, count) : rest)
      | not (isName name) = Just (subject <> " names must be normalized and non-empty")
      | count < 0 || count > maxPortableInteger = Just (subject <> " values must be nonnegative JSON-portable integers")
      | otherwise = go rest

pBudgetV4 :: Path -> Json -> Parser BudgetV4
pBudgetV4 path v = do
  f <- model "BudgetV4" (budgetKeys ++ ["profile_resources"]) path v
  limits <- budgetFields f
  resources <- field f "profile_resources" $ \p x -> do
    values <- pIntDict p x
    forM_ (checkResourceValues "profile resource budget" values) (valueError p)
    Right values
  Right BudgetV4 {limits, profileResources = Map.fromList resources}

-- | @Budget | BudgetV4@: a smart union whose members refuse each other's
-- shapes (extra or missing @profile_resources@), so the member is chosen by
-- that key; pydantic names the member in the location.
pAnyBudget :: Path -> Json -> Parser SomeBudget
pAnyBudget path v = case v of
  Object members
    | isJust (lookup "profile_resources" members) -> SomeBudgetV4 <$> pBudgetV4 (LKey "BudgetV4" : path) v
  _ -> SomeBudget <$> pBudget (LKey "Budget" : path) v

pResourceUsage :: Path -> Json -> Parser ResourceUsage
pResourceUsage path v = do
  f <- model "ResourceUsage" ["values"] path v
  values <- field f "values" $ \p x -> do
    values <- pIntDict p x
    forM_ (checkResourceValues "profile resource usage" values) (valueError p)
    Right values
  Right (ResourceUsage (Map.fromList values))

pScheduledCommand :: Path -> Json -> Parser ScheduledCommand
pScheduledCommand path v = do
  f <- model "ScheduledCommand" ["instant", "command"] path v
  instant <- field f "instant" (pIntRange (Just 0) (Just maxPortableInteger))
  command <- field f "command" pCommand
  Right ScheduledCommand {instant, command}

pApplyResult :: Path -> Json -> Parser ApplyResult
pApplyResult path v = do
  f <- model "ApplyResult" ["disposition", "value", "scheduled"] path v
  disposition <- field f "disposition" (pLiteral [(String (actionDispositionText d), d) | d <- [minBound .. maxBound]])
  value <- field f "value" (pJsonValue "apply result")
  scheduled <- field f "scheduled" (pList pScheduledCommand)
  Right ApplyResult {disposition, value, scheduled}

pObservationRequest :: Path -> Json -> Parser ObservationRequest
pObservationRequest path v = do
  f <- model "ObservationRequest" ["name", "payload"] path v
  name <- field f "name" $ \p x -> do
    s <- pStr p x
    unless (isName s) (valueError p "observation name must be normalized and non-empty")
    Right s
  payload <- field f "payload" (pJsonValue "observation payload")
  Right ObservationRequest {name, payload}

pObservation :: Path -> Json -> Parser Observation
pObservation path v = do
  f <- model "Observation" ["name", "value", "instant", "generation", "sequence"] path v
  name <- field f "name" pStr
  value <- field f "value" (pJsonValue "observation value")
  instant <- field f "instant" (pIntRange (Just 0) (Just maxPortableInteger))
  generation <- field f "generation" (pIntRange (Just 1) Nothing)
  sequence' <- field f "sequence" (pIntRange (Just 0) Nothing)
  Right Observation {name, value, instant, generation, sequence = sequence'}

pCheckResult :: Path -> Json -> Parser CheckResult
pCheckResult path v = do
  f <- model "CheckResult" ["passed", "detail"] path v
  passed <- field f "passed" pBool
  detail <- field f "detail" (pJsonValue "checker detail")
  Right CheckResult {passed, detail}

pDisposition :: Path -> Json -> Parser Disposition
pDisposition = pLiteral [(String (dispositionText d), d) | d <- [minBound .. maxBound]]

pAuthoredDisposition :: Path -> Json -> Parser AuthoredDisposition
pAuthoredDisposition = pLiteral [(String (authoredDispositionText d), d) | d <- [minBound .. maxBound]]

-- ---------------------------------------------------------------------------
-- Attempts, failures, operations

generationField :: Fields -> Parser Integer
generationField f = field f "generation" (pIntRange (Just 1) Nothing)

positionField :: Fields -> Parser Integer
positionField f = field f "position" (pIntRange (Just 0) Nothing)

instantField :: Fields -> Parser Integer
instantField f = field f "instant" (pIntRange (Just 0) (Just maxPortableInteger))

cutField :: Fields -> Parser Text
cutField f = field f "cut" $ \p x -> do
  s <- pStr p x
  unless (isName s) (valueError p "crash cut must be a normalized non-empty name")
  Right s

attemptAlternatives :: [(Text, Path -> Json -> Parser OperationAttempt)]
attemptAlternatives =
  [ ("submit", \p v -> do
        f <- model "SubmitAttempt" ["kind", "generation", "command"] p v
        generation <- generationField f
        command <- field f "command" pCommand
        Right (ASubmit SubmitAttempt {generation, command}))
  , ("step", \p v -> AStep <$ model "StepAttempt" ["kind"] p v)
  , ("activate_fault", \p v -> do
        f <- model "FaultAttempt" ["kind", "generation", "fault"] p v
        generation <- generationField f
        fault <- field f "fault" pFault
        Right (AFault FaultAttempt {generation, fault}))
  , ("observe", \p v -> do
        f <- model "ObserveAttempt" ["kind", "generation", "request", "poll"] p v
        generation <- generationField f
        request <- field f "request" pObservationRequest
        poll <- field f "poll" pBool
        Right (AObserve ObserveAttempt {generation, request, poll}))
  , ("crash", \p v -> do
        f <- model "CrashAttempt" ["kind", "generation", "cut"] p v
        generation <- generationField f
        cut <- cutField f
        Right (ACrash CrashAttempt {generation, cut}))
  , ("restart", \p v -> ARestart <$ model "RestartAttempt" ["kind"] p v)
  , ("begin_fair", \p v -> do
        f <- model "FairAttempt" ["kind", "generation"] p v
        generation <- generationField f
        Right (AFair FairAttempt {generation}))
  , ("finish", \p v -> do
        f <- model "FinishAttempt" ["kind", "generation", "disposition"] p v
        generation <- generationField f
        disposition <- field f "disposition" pAuthoredDisposition
        Right (AFinish FinishAttempt {generation, disposition}))
  ]

pOperationAttempt :: Path -> Json -> Parser OperationAttempt
pOperationAttempt = tagged attemptAlternatives

-- | @ProcessAttempt@: the World attempts plus @construct@ and @close@.
pProcessAttempt :: Path -> Json -> Parser ProcessAttempt
pProcessAttempt =
  tagged
    ( [(t, \p v -> WorldAttempt <$> a p v) | (t, a) <- attemptAlternatives]
        ++ [ ("construct", \p v -> AConstruct <$ model "ConstructAttempt" ["kind"] p v)
           , ("close", \p v -> do
                f <- model "CloseAttempt" ["kind", "generation"] p v
                AClose <$> generationField f)
           ]
    )

pFailureDetail :: Path -> Json -> Parser FailureDetail
pFailureDetail =
  tagged
    [ ("budget_exhausted", \p v -> do
          f <- model "BudgetFailure" ["kind", "bound", "limit", "error"] p v
          bound <- field f "bound" pStr
          limit <- field f "limit" (pIntRange (Just 0) Nothing)
          err <- field f "error" pStr
          Right (FBudget BudgetFailure {bound, limit, error = err}))
    , ("invariant_failure", \p v -> do
          f <- model "InvariantFailure" ["kind", "error"] p v
          err <- field f "error" pStr
          Right (FInvariant InvariantFailure {error = err}))
    ]

acceptedAlternatives :: [(Text, Path -> Json -> Parser AcceptedOperation)]
acceptedAlternatives =
  [ ("execute", \p v -> do
        f <- model "ExecuteOperation" ["kind", "position", "source", "queue_order", "instant", "generation", "command", "result"] p v
        position <- positionField f
        source <- field f "source" (pLiteral [(String (commandSourceText s), s) | s <- [minBound .. maxBound]])
        queueOrder <- field f "queue_order" (pIntRange (Just 0) Nothing)
        instant <- instantField f
        generation <- generationField f
        command <- field f "command" pCommand
        result <- field f "result" pApplyResult
        Right (OpExecute ExecuteOperation {position, source, queueOrder, instant, generation, command, result}))
  , ("activate_fault", \p v -> do
        f <- model "FaultOperation" ["kind", "position", "instant", "generation", "fault"] p v
        position <- positionField f
        instant <- instantField f
        generation <- generationField f
        fault <- field f "fault" pFault
        Right (OpFault FaultOperation {position, instant, generation, fault}))
  , ("observe", \p v -> do
        f <- model "ObserveOperation" ["kind", "position", "poll", "observation", "request"] p v
        position <- positionField f
        poll <- field f "poll" pBool
        observation <- field f "observation" pObservation
        request <- field f "request" pObservationRequest
        Right (OpObserve ObserveOperation {position, poll, observation, request}))
  , ("crash", \p v -> do
        f <- model "CrashOperation" ["kind", "position", "instant", "generation", "cut", "discarded_commands"] p v
        position <- positionField f
        instant <- instantField f
        generation <- generationField f
        cut <- cutField f
        discardedCommands <- field f "discarded_commands" (pIntRange (Just 0) Nothing)
        Right (OpCrash CrashOperation {position, instant, generation, cut, discardedCommands}))
  , ("restart", \p v -> do
        f <- model "RestartOperation" ["kind", "position", "instant", "generation"] p v
        position <- positionField f
        instant <- instantField f
        generation <- generationField f
        Right (OpRestart RestartOperation {position, instant, generation}))
  , ("begin_fair", \p v -> do
        f <- model "FairOperation" ["kind", "position", "instant", "generation"] p v
        position <- positionField f
        instant <- instantField f
        generation <- generationField f
        Right (OpFair FairOperation {position, instant, generation}))
  , ("finish", \p v -> do
        f <- model "FinishOperation" ["kind", "position", "instant", "generation", "disposition"] p v
        position <- positionField f
        instant <- instantField f
        generation <- generationField f
        disposition <- field f "disposition" pAuthoredDisposition
        Right (OpFinish FinishOperation {position, instant, generation, disposition}))
  ]

-- | @ExpandedOperationV1@.
pAcceptedOperation :: Path -> Json -> Parser AcceptedOperation
pAcceptedOperation = tagged acceptedAlternatives

pFailureOperation :: Path -> Json -> Parser FailureOperation
pFailureOperation p v = do
  f <- model "FailureOperation" ["kind", "position", "instant", "generation", "accepted_operations", "attempt", "failure"] p v
  position <- positionField f
  instant <- instantField f
  generation <- field f "generation" (pNullable (pIntRange (Just 1) Nothing))
  acceptedOperations <- field f "accepted_operations" (pIntRange (Just 0) (Just 1))
  attempt <- field f "attempt" pOperationAttempt
  failure <- field f "failure" pFailureDetail
  Right FailureOperation {position, instant, generation, acceptedOperations, attempt, failure}

-- | @ExpandedOperation@: a union whose first member is itself the
-- discriminated V1 union, so accepted operations carry their tag twice in
-- pydantic locations.
pExpandedOperation :: Path -> Json -> Parser ExpandedOperation
pExpandedOperation =
  tagged
    ( [(t, \p v -> Accepted <$> tagged acceptedAlternatives p v) | (t, _) <- acceptedAlternatives]
        ++ [("failure", \p v -> Failed <$> pFailureOperation p v)]
    )

journalKinds :: [JournalKind]
journalKinds = [minBound .. maxBound]

pJournalEntry :: Path -> Json -> Parser JournalEntry
pJournalEntry path v = do
  f <- model "JournalEntry" ["position", "instant", "generation", "kind", "name", "value"] path v
  position <- positionField f
  instant <- instantField f
  generation <- field f "generation" (pNullable pInt)
  kind <- field f "kind" (pLiteral [(String (journalKindText k), k) | k <- journalKinds])
  name <- field f "name" pStr
  value <- field f "value" (pJsonValue "journal value")
  Right JournalEntry {position, instant, generation, kind, name, value}

pChoiceProvenance :: Path -> Json -> Parser ChoiceProvenance
pChoiceProvenance path v = do
  f <- model "ChoiceProvenance" ["algorithm", "seed", "draws"] path v
  _ <- field f "algorithm" (pLiteral [(String "sha256-counter-v1", ())])
  seed <- field f "seed" (pIntRange (Just 0) (Just maxPortableInteger))
  draws <- field f "draws" $ \p x -> do
    values <- pIntDict p x
    forM_ (validProvenanceDraws values) (valueError p)
    Right values
  Right ChoiceProvenance {seed, draws = Map.fromList draws}

-- ---------------------------------------------------------------------------
-- Artifacts

digestField :: Fields -> Parser Text
digestField f = field f "journal_digest" $ \p x -> do
  s <- pStr p x
  unless (isDigest s) (valueError p "journal digest must be sha256:<64 lowercase hex>")
  Right s

scenarioIdField :: Fields -> Parser Text
scenarioIdField f = field f "scenario_id" $ \p x -> do
  s <- pStr p x
  unless (isName s) (valueError p "scenario id must be a normalized non-empty name")
  Right s

literalField :: Fields -> Text -> Json -> Parser ()
literalField f key expected = field f key (pLiteral [(expected, ())])

pExpectedV1 :: Path -> Json -> Parser ScenarioExpectedV1
pExpectedV1 path v = do
  f <- model "ScenarioExpectedV1" ["disposition", "checks", "journal_digest"] path v
  disposition <- field f "disposition" pAuthoredDisposition
  checks <- field f "checks" (pList pJournalEntry)
  journalDigest <- digestField f
  Right ScenarioExpectedV1 {disposition, checks, journalDigest}

pExpected :: Path -> Json -> Parser ScenarioExpected
pExpected path v = do
  f <- model "ScenarioExpected" ["disposition", "failure", "checks", "journal_digest"] path v
  disposition <- field f "disposition" pDisposition
  failure <- field f "failure" (pNullable pFailureDetail)
  checks <- field f "checks" (pList pJournalEntry)
  journalDigest <- digestField f
  Right ScenarioExpected {disposition, failure, checks, journalDigest}

v1Keys, failureKeys :: [Text]
v1Keys = ["format", "version", "api", "scenario_id", "profile", "checkers", "budget", "operations", "expected"]
failureKeys = v1Keys

-- | @ScenarioArtifactV1.model_validate(value, strict=True)@.
pArtifactV1 :: Json -> Parser ScenarioArtifactV1
pArtifactV1 v = do
  f <- model "ScenarioArtifactV1" v1Keys [] v
  literalField f "format" (String artifactFormat)
  literalField f "version" (Int 1)
  literalField f "api" (String legacyApiCompatibility)
  scenarioId <- scenarioIdField f
  profile <- field f "profile" pProfileIdentity
  checkers <- field f "checkers" (pList pCheckerIdentity)
  budget <- field f "budget" pBudget
  operations <- field f "operations" (pList pAcceptedOperation)
  expected <- field f "expected" pExpectedV1
  let artifact = ScenarioArtifactV1 {scenarioId, profile, checkers, budget, operations, expected}
  coherent (artifactCoherence (ArtifactV1 artifact))
  Right artifact

data Common = Common
  { scenarioId :: Text
  , profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , operations :: [ExpandedOperation]
  , expected :: ScenarioExpected
  }

commonFields :: Fields -> Integer -> Text -> Parser Common
commonFields f version api = do
  literalField f "format" (String artifactFormat)
  literalField f "version" (Int version)
  literalField f "api" (String api)
  scenarioId <- scenarioIdField f
  profile <- field f "profile" pProfileIdentity
  checkers <- field f "checkers" (pList pCheckerIdentity)
  operations <- field f "operations" (pList pExpandedOperation)
  expected <- field f "expected" pExpected
  Right Common {scenarioId, profile, checkers, operations, expected}

-- | @ScenarioArtifactV2.model_validate(value, strict=True)@.
pArtifactV2 :: Json -> Parser ScenarioArtifactV2
pArtifactV2 v = do
  f <- model "ScenarioArtifactV2" failureKeys [] v
  c <- commonFields f 2 previousApiCompatibility
  budget <- field f "budget" pBudget
  let artifact =
        ScenarioArtifactV2
          {scenarioId = c.scenarioId, profile = c.profile, checkers = c.checkers, budget, operations = c.operations, expected = c.expected}
  coherent (artifactCoherence (ArtifactV2 artifact))
  Right artifact

-- | @ScenarioArtifactV3.model_validate(value, strict=True)@.
pArtifactV3 :: Json -> Parser ScenarioArtifactV3
pArtifactV3 v = do
  f <- model "ScenarioArtifactV3" (failureKeys ++ ["origin"]) [] v
  c <- commonFields f 3 seededApiCompatibility
  budget <- field f "budget" pBudget
  origin <- field f "origin" (pNullable pChoiceProvenance)
  let artifact =
        ScenarioArtifactV3
          { scenarioId = c.scenarioId
          , profile = c.profile
          , checkers = c.checkers
          , budget
          , operations = c.operations
          , expected = c.expected
          , origin
          }
  coherent (artifactCoherence (ArtifactV3 artifact))
  Right artifact

-- | @ScenarioArtifact.model_validate(value, strict=True)@ (version 4).
pArtifactV4 :: Json -> Parser ScenarioArtifactV4
pArtifactV4 v = do
  f <- model "ScenarioArtifact" (failureKeys ++ ["origin"]) [] v
  c <- commonFields f 4 apiCompatibility
  budget <- field f "budget" pBudgetV4
  origin <- field f "origin" (pNullable pChoiceProvenance)
  let artifact =
        ScenarioArtifactV4
          { scenarioId = c.scenarioId
          , profile = c.profile
          , checkers = c.checkers
          , budget
          , operations = c.operations
          , expected = c.expected
          , origin
          }
  coherent (artifactCoherence (ArtifactV4 artifact))
  Right artifact

coherent :: Maybe Text -> Parser ()
coherent = maybe (Right ()) (valueError [])

-- | The artifact model validators (@coherent@), in the reference's order:
-- the first refusal message, if any.
artifactCoherence :: AnyArtifact -> Maybe Text
artifactCoherence artifact = either Just (const Nothing) $ do
  let operations = artifactOperations artifact
      checks = artifactExpectedChecks artifact
      profile = artifactProfile artifact
  when (map operationPosition operations /= [0 .. fromIntegral (length operations) - 1]) $
    Left "DST operation positions must be dense and zero-based"
  let positions = [e.position | e <- checks]
  when (positions /= Set.toAscList (Set.fromList positions) || any (\e -> e.kind /= JCheck) checks) $
    Left "DST expected checks must be ordered unique check-journal entries"
  let identities = map identityKey (artifactCheckers artifact)
  when (length identities /= Set.size (Set.fromList identities)) $
    Left "DST checker manifest identities must be unique"
  case artifact of
    ArtifactV1 _ -> pure ()
    _ -> validateFailure operations
  forM_ operations $ \case
    Accepted (OpExecute o)
      | o.command.profile /= profile -> Left "DST operation command does not match the artifact profile"
    Accepted (OpFault o)
      | o.fault.profile /= profile -> Left "DST operation fault does not match the artifact profile"
    Failed o -> do
      when (failureKind o.failure /= artifactExpectedDisposition artifact) $
        Left "DST terminal failure kind must equal the expected disposition"
      case o.attempt of
        ASubmit a
          | a.command.profile /= profile -> Left "DST failed command attempt does not match the artifact profile"
        AFault a
          | a.fault.profile /= profile -> Left "DST failed fault attempt does not match the artifact profile"
        _ -> pure ()
    _ -> pure ()
  where
    validateFailure operations = do
      let failures = [o | Failed o <- operations]
          expectedFailure = artifactExpectedDisposition artifact `elem` [DBudgetExhausted, DInvariantFailure]
      if expectedFailure
        then do
          case (failures, reverse operations) of
            ([only], Failed final : _) | only == final -> pure ()
            _ -> Left "a failed DST artifact must end with exactly one failure operation"
          case failures of
            [only] -> do
              when (Just only.failure /= artifactExpectedFailure artifact) $
                Left "DST expected failure must equal the terminal failure operation"
              when (only.acceptedOperations /= 0) $ case reverse operations of
                _ : previous : _ | attemptProducedOperation only.attempt previous -> pure ()
                _ -> Left "DST failed attempt does not identify its accepted operation"
            _ -> pure ()
        else
          unless (null failures && artifactExpectedFailure artifact == Nothing) $
            Left "a successful DST artifact cannot contain an expected failure"

-- | @_attempt_produced_operation@.
attemptProducedOperation :: OperationAttempt -> ExpandedOperation -> Bool
attemptProducedOperation attempt operation = case (attempt, operation) of
  (ASubmit a, Accepted (OpExecute o)) ->
    o.source == Authored && a.command == o.command && a.generation == o.generation
  (AStep, Accepted (OpExecute o)) -> o.source == ProfileSource
  (AFault a, Accepted (OpFault o)) -> a.fault == o.fault && a.generation == o.generation
  (AObserve a, Accepted (OpObserve o)) ->
    a.request == o.request && a.generation == o.observation.generation && a.poll == o.poll
  (ACrash a, Accepted (OpCrash o)) -> a.cut == o.cut && a.generation == o.generation
  (ARestart, Accepted (OpRestart _)) -> True
  (AFair a, Accepted (OpFair o)) -> a.generation == o.generation
  (AFinish a, Accepted (OpFinish o)) -> a.disposition == o.disposition && a.generation == o.generation
  _ -> False

tshow :: (Show a) => a -> Text
tshow = T.pack . show
