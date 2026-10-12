-- | Strict deterministic values shared by the readiness profile and
-- provider (@host/testing/_readiness_contract.py@).
--
-- The identities' digests are 'digestJson' of the reference's definition
-- values, so they equal the reference's byte for byte: an artifact either
-- implementation writes names the same profile and checker.
module Hamsterdan.Testing.World.Contract
  ( -- * Fixtures
    headSha
  , baseSha
  , subject
  , webhookSecret
  , bot
  , clientId
  , privateKey

    -- * Limits
  , ProfileLimit (..)
  , profileLimitName
  , profileLimits
  , profileLimit
  , profileResourceLimits
  , readinessPolicyDigest
  , reminderDelay

    -- * Identities and budget
  , profileIdentity
  , checkerIdentity
  , defaultBudget
  , withProfileResource

    -- * Commands
  , commandKeys
  , hostCommands
  , events
  , effectKinds

    -- * Vocabulary checks
  , isSha
  , isName
  , isOperation
  , isPolicy

    -- * Strict helpers
  , PythonException (..)
  , pythonError
  , classAndStr
  , strictObject
  , strictDigest
  , boundedText
  , boundedJson
  , canonical
  , sha256Hex
  ) where

import Control.Exception (throw)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Json.Python (PythonException (..), pythonError, pythonExceptionStr, pythonStrListRepr)
import Petrus.Testing.Dst (Budget (..), BudgetV4 (..), CheckerIdentity, Identity (..), ProfileIdentity, canonicalBytes, digestJson)
import Hamsterdan.Python.Hashlib (sha256Hex)

-- ---------------------------------------------------------------------------
-- Fixtures

headSha, baseSha, subject, webhookSecret, bot, clientId, privateKey :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"
subject = "github:44:31:pr:7"
webhookSecret = "readiness-world-webhook-secret"
bot = "hamsterdan-test[bot]"
clientId = "readiness-world-client"
privateKey = "readiness-world-private-key"

-- ---------------------------------------------------------------------------
-- Limits

-- | A key of @PROFILE_LIMITS@, in the reference's order.
data ProfileLimit
  = AuthorityGenerations
  | ProviderTruthChanges
  | WebhookEmissions
  | DeliveryAttempts
  | Checks
  | Reviews
  | Findings
  | Comments
  | Threads
  | AgentOperations
  | GitPublications
  | GitReconciliations
  | ProviderCalls
  | Effects
  | HostFollowups
  | PendingCustody
  | Runnable
  | DispatchEntries
  | Reloads
  | PayloadBytes
  | HistoryBytes
  | ObservationBytes
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The limit's key in @PROFILE_LIMITS@.
profileLimitName :: ProfileLimit -> Text
profileLimitName = \case
  AuthorityGenerations -> "authority_generations"
  ProviderTruthChanges -> "provider_truth_changes"
  WebhookEmissions -> "webhook_emissions"
  DeliveryAttempts -> "delivery_attempts"
  Checks -> "checks"
  Reviews -> "reviews"
  Findings -> "findings"
  Comments -> "comments"
  Threads -> "threads"
  AgentOperations -> "agent_operations"
  GitPublications -> "git_publications"
  GitReconciliations -> "git_reconciliations"
  ProviderCalls -> "provider_calls"
  Effects -> "effects"
  HostFollowups -> "host_followups"
  PendingCustody -> "pending_custody"
  Runnable -> "runnable"
  DispatchEntries -> "dispatch_entries"
  Reloads -> "reloads"
  PayloadBytes -> "payload_bytes"
  HistoryBytes -> "history_bytes"
  ObservationBytes -> "observation_bytes"

-- | @PROFILE_LIMITS[name]@.
profileLimit :: ProfileLimit -> Integer
profileLimit = \case
  AuthorityGenerations -> 16
  ProviderTruthChanges -> 128
  WebhookEmissions -> 64
  DeliveryAttempts -> 128
  Checks -> 64
  Reviews -> 64
  Findings -> 128
  Comments -> 128
  Threads -> 128
  AgentOperations -> 128
  GitPublications -> 64
  GitReconciliations -> 128
  ProviderCalls -> 512
  Effects -> 128
  HostFollowups -> 512
  PendingCustody -> 64
  Runnable -> 64
  DispatchEntries -> 256
  Reloads -> 8
  PayloadBytes -> 65536
  HistoryBytes -> 2097152
  ObservationBytes -> 2097152

-- | @PROFILE_LIMITS@, in the reference's order.
profileLimits :: [(Text, Integer)]
profileLimits = [(profileLimitName limit, profileLimit limit) | limit <- [minBound .. maxBound]]

-- | @PROFILE_RESOURCE_LIMITS@, in the reference's order.
profileResourceLimits :: [(Text, Integer)]
profileResourceLimits =
  [ ("retained.host.history_bytes", profileLimit HistoryBytes)
  , ("retained.host.history_records", 4096)
  , ("retained.host.sqlite_bytes", 4194304)
  , ("retained.host.sqlite_rows", 4096)
  , ("retained.profile.dropped_generations", profileLimit Reloads)
  , ("retained.profile.followups", profileLimit HostFollowups)
  , ("retained.provider.admissions", profileLimit WebhookEmissions)
  , ("retained.provider.agent_operations", profileLimit AgentOperations)
  , ("retained.provider.authorities", profileLimit AuthorityGenerations)
  , ("retained.provider.bytes", 2097152)
  , ("retained.provider.calls", profileLimit ProviderCalls)
  , ("retained.provider.checks", profileLimit Checks)
  , ("retained.provider.collisions", profileLimit Effects)
  , ("retained.provider.comments", profileLimit Comments)
  , ("retained.provider.custody_actions", profileLimit DeliveryAttempts)
  , ("retained.provider.delivery_attempts", profileLimit DeliveryAttempts)
  , ("retained.provider.effect_bindings", profileLimit Effects)
  , ("retained.provider.effects", profileLimit Effects)
  , ("retained.provider.findings", profileLimit Findings)
  , ("retained.provider.git_publications", profileLimit GitPublications)
  , ("retained.provider.git_reconciliations", profileLimit GitReconciliations)
  , ("retained.provider.reviews", profileLimit Reviews)
  , ("retained.provider.threads", profileLimit Threads)
  , ("retained.provider.truth_changes", profileLimit ProviderTruthChanges)
  , ("retained.provider.webhooks", profileLimit WebhookEmissions)
  , ("pending.host.activities", profileLimit DispatchEntries)
  , ("pending.host.custody", profileLimit PendingCustody)
  , ("pending.host.dispatch", profileLimit DispatchEntries)
  , ("pending.host.runnable", profileLimit Runnable)
  , ("pending.host.timer_acks", profileLimit DispatchEntries)
  , ("pending.host.timer_maturities", profileLimit DispatchEntries)
  , ("pending.host.timers", profileLimit DispatchEntries)
  , ("pending.profile.proposals", profileLimit Runnable)
  ]

-- | @READINESS_POLICY_DIGEST@.
readinessPolicyDigest :: Text
readinessPolicyDigest =
  sha256Hex . canonical $
    Object
      [ ("strict", Bool True)
      , ("update_required", Bool True)
      , ("required_checks", Array [String "build"])
      , ("required_approvals", Int 0)
      , ("conversation_resolution", Bool False)
      , ("source", String "effective_rules")
      ]

-- | @REMINDER_DELAY@, in seconds.
reminderDelay :: Integer
reminderDelay = 86400

-- ---------------------------------------------------------------------------
-- Identities

intObject :: [(Text, Integer)] -> Json
intObject = Object . map (fmap Int)

texts :: [Text] -> Json
texts = Array . map String

-- | @digest_json(value)@, raising its @ValueError@ (a non-finite float).
digestOf :: Json -> Text
digestOf = either (throw . pythonError "ValueError") id . digestJson

-- | @PROFILE_IDENTITY@.
profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "hamsterdan.readiness.v5-world"
    , version = 2
    , digest =
        digestOf $
          Object
            [ ("dst_api", String "petrus.testing.dst/v4")
            , ("topology", String "v5")
            , ("reminder_delay", Int reminderDelay)
            , ("limits", intObject profileLimits)
            , ("resource_limits", intObject profileResourceLimits)
            ,
              ( "observation_semantics"
              , texts
                  [ "effect provider authority is retained at acceptance"
                  , "readiness effect authorship is bound to the exact outstanding V5 Activity request"
                  , "semantic admission records provider authority when custody executes"
                  , "every distinct full admitted authority claim advances the model generation"
                  , "provider movement does not retroactively invalidate historical effects"
                  , "dashboard, conversation, and reminder effects are fixed incarnation-bound unfenced kinds"
                  , "current readiness is an authority-fenced V5 provider effect"
                  , "reminder identity, incarnation, sequence, head, due, maturity, and status derive from "
                      <> "admitted authority, logical time, and provider acceptance"
                  , "timer custody is detached from the durable V5 host boundary"
                  , "detached host state is the durable V5 authority grant, never a Petri marking"
                  , "authorized Git publication is derived from one admitted human comment and exact operation identity"
                  , "Git ref acceptance and lookup-first recovery live in independent modeled provider truth"
                  , "ambiguous Git recovery requires one admitted human grant naming the exact operation"
                  ]
              )
            , ("commands", texts (sort (Map.keys commandKeys)))
            , ("observations", texts ["readiness.state"])
            , ("faults", texts ["readiness.github.effect", "readiness.git.publish"])
            ]
    }

-- | @CHECKER_IDENTITY@.
checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "hamsterdan.readiness.independent-model"
    , version = 4
    , digest =
        digestOf $
          Object
            [
              ( "checks"
              , texts
                  [ "expected readiness equals the current authority-fenced V5 provider effect after disclosed work drains"
                  , "only disclosed eligible work permits transient readiness-publication lag"
                  , "durable V5 grant matches active or quiescent authority and terminal lifecycle"
                  , "independent reminder identity, authority, due/maturity instants, and status match "
                      <> "detached durable V5 timer custody after disclosed work drains"
                  , "modeled custody action equals detached host disposition"
                  , "provider effect identity accepts at most once"
                  , "authorized Git acceptance matches canonical V5 request and terminal recovery"
                  , "lookup-first Git recovery retains its exact admitted human grant"
                  , "independent readiness safety violations remain empty"
                  ]
              )
            ]
    }

-- | @DEFAULT_BUDGET@.
defaultBudget :: BudgetV4
defaultBudget =
  BudgetV4
    { limits =
        Budget
          { actions = 512
          , queuedCommands = 64
          , timerAdvances = 32
          , logicalInstant = 2000000
          , reloads = profileLimit Reloads
          , predicatePolls = 256
          , artifactBytes = 4194304
          }
    , profileResources = Map.fromList profileResourceLimits
    }

-- | @DEFAULT_BUDGET.model_copy(update={"profile_resources": limits})@
-- with one limit replaced.
withProfileResource :: Text -> Integer -> BudgetV4 -> BudgetV4
withProfileResource name value budget = budget {profileResources = Map.insert name value budget.profileResources}

-- ---------------------------------------------------------------------------
-- Commands

-- | @COMMAND_KEYS@.
commandKeys :: Map Text (Set Text)
commandKeys =
  Map.fromList
    [ ("readiness.github.pr.set", Set.fromList ["subject", "authority"])
    , ("readiness.github.ci.set", Set.fromList ["subject", "head", "required_checks", "checks"])
    , ("readiness.github.review.set", Set.fromList ["subject", "head", "status", "findings"])
    , ("readiness.github.human.review", Set.fromList ["subject", "review", "reviewer", "head", "state"])
    , ("readiness.github.human.comment", Set.fromList ["subject", "comment", "author", "fixture", "digest"])
    , ("readiness.github.human.resolve_thread", Set.fromList ["subject", "thread", "resolver", "resolved"])
    , ("readiness.github.webhook.emit", Set.fromList ["subject", "delivery", "event", "fixture", "digest"])
    , ("readiness.github.webhook.deliver", Set.fromList ["delivery"])
    , ("readiness.agent.terminal", Set.fromList ["subject", "operation", "attempt", "status", "fixture", "digest"])
    , ("readiness.github.effect.reveal", Set.fromList ["subject", "operation"])
    , ("readiness.host.custody_one", Set.empty)
    , ("readiness.host.drive_one", Set.empty)
    , ("readiness.host.activity_one", Set.empty)
    , ("readiness.host.reconcile_one", Set.empty)
    , ("readiness.time.advance", Set.fromList ["seconds"])
    ]

-- | @HOST_COMMANDS@.
hostCommands :: Set Text
hostCommands = Set.filter ("readiness.host." `T.isPrefixOf`) (Map.keysSet commandKeys)

-- | @EVENTS@.
events :: Set Text
events =
  Set.fromList
    ["issue_comment", "pull_request", "pull_request_review", "pull_request_review_thread", "workflow_job", "workflow_run"]

-- | @EFFECT_KINDS@.
effectKinds :: Set Text
effectKinds = Set.fromList ["conversation", "dashboard", "finding", "readiness", "reminder"]

-- ---------------------------------------------------------------------------
-- Vocabulary checks (the reference's @re.fullmatch@ patterns)

isHex :: Char -> Bool
isHex c = isDigit c || (c >= 'a' && c <= 'f')

isAsciiLetter :: Char -> Bool
isAsciiLetter c = isAsciiLower c || isAsciiUpper c

-- | @SHA@: @[0-9a-f]{40}@.
isSha :: Text -> Bool
isSha t = T.length t == 40 && T.all isHex t

-- | The policy digest pattern: @[0-9a-f]{64}@.
isPolicy :: Text -> Bool
isPolicy t = T.length t == 64 && T.all isHex t

leadingThen :: (Char -> Bool) -> Int -> Text -> Bool
leadingThen rest bound t = case T.uncons t of
  Just (c, more) -> isAsciiLetter c && T.length more <= bound && T.all rest more
  Nothing -> False

-- | @NAME@: @[A-Za-z][A-Za-z0-9_.:-]{0,127}@.
isName :: Text -> Bool
isName = leadingThen (\c -> isAsciiLetter c || isDigit c || c `elem` ("_.:-" :: String)) 127

-- | @OPERATION@: @[A-Za-z][A-Za-z0-9_./:-]{0,255}@.
isOperation :: Text -> Bool
isOperation = leadingThen (\c -> isAsciiLetter c || isDigit c || c `elem` ("_./:-" :: String)) 255

-- ---------------------------------------------------------------------------
-- Strict helpers

-- | The class and @str()@ of an exception the profile raises.
classAndStr :: PythonException -> (Text, Text)
classAndStr e@(PythonException cls _) = (cls, pythonExceptionStr e)


-- | @strict_object(value, keys, label)@.
strictObject :: Json -> Set Text -> Text -> Either PythonException [(Text, Json)]
strictObject value keys label = case value of
  Object members | Set.fromList (map fst members) == keys && length members == Set.size keys -> Right members
  _ -> Left (pythonError "ValueError" (label <> " requires exact fields " <> pythonStrListRepr (Set.toAscList keys)))

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"))@ (ASCII).
canonical :: Json -> ByteString
canonical = either (throw . pythonError "ValueError") id . canonicalBytes

-- | Lowercase hex SHA-256.

-- | @strict_digest(value)@.
strictDigest :: Json -> Text
strictDigest = sha256Hex . canonical

-- | @bounded_text(value, label, pattern=pattern)@.
boundedText :: Json -> Text -> Maybe (Text -> Bool) -> Either PythonException Text
boundedText value label pattern = case value of
  String t | not (T.null t), T.length t <= 20000, maybe True ($ t) pattern -> Right t
  _ -> Left (pythonError "ValueError" (label <> " is outside its closed bounded vocabulary"))

-- | @bounded_json(value, limit, label)@.
boundedJson :: Json -> Integer -> Text -> Either PythonException ByteString
boundedJson value limit label = case canonicalBytes value of
  Left message -> Left (pythonError "ValueError" message)
  Right encoded
    | toInteger (BS.length encoded) > limit ->
        Left (pythonError "ValueError" (label <> " has " <> T.pack (show (BS.length encoded)) <> " bytes; limit is " <> T.pack (show limit)))
    | otherwise -> Right encoded
