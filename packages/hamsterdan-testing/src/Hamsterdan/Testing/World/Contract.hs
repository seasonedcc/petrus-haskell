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
  , PyError (..)
  , strictObject
  , strictDigest
  , boundedText
  , boundedJson
  , canonical
  , sha256Hex
  ) where

import Control.Exception (Exception (..), throw)
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
import Petrus.Json.Python (pythonStrListRepr)
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

-- | @PROFILE_LIMITS@, in the reference's order.
profileLimits :: [(Text, Integer)]
profileLimits =
  [ ("authority_generations", 16)
  , ("provider_truth_changes", 128)
  , ("webhook_emissions", 64)
  , ("delivery_attempts", 128)
  , ("checks", 64)
  , ("reviews", 64)
  , ("findings", 128)
  , ("comments", 128)
  , ("threads", 128)
  , ("agent_operations", 128)
  , ("git_publications", 64)
  , ("git_reconciliations", 128)
  , ("provider_calls", 512)
  , ("effects", 128)
  , ("host_followups", 512)
  , ("pending_custody", 64)
  , ("runnable", 64)
  , ("dispatch_entries", 256)
  , ("reloads", 8)
  , ("payload_bytes", 65536)
  , ("history_bytes", 2097152)
  , ("observation_bytes", 2097152)
  ]

profileLimit :: Text -> Integer
profileLimit name = maybe (error ("unknown profile limit " <> T.unpack name)) id (lookup name profileLimits)

-- | @PROFILE_RESOURCE_LIMITS@, in the reference's order.
profileResourceLimits :: [(Text, Integer)]
profileResourceLimits =
  [ ("retained.host.history_bytes", profileLimit "history_bytes")
  , ("retained.host.history_records", 4096)
  , ("retained.host.sqlite_bytes", 4194304)
  , ("retained.host.sqlite_rows", 4096)
  , ("retained.profile.dropped_generations", profileLimit "reloads")
  , ("retained.profile.followups", profileLimit "host_followups")
  , ("retained.provider.admissions", profileLimit "webhook_emissions")
  , ("retained.provider.agent_operations", profileLimit "agent_operations")
  , ("retained.provider.authorities", profileLimit "authority_generations")
  , ("retained.provider.bytes", 2097152)
  , ("retained.provider.calls", profileLimit "provider_calls")
  , ("retained.provider.checks", profileLimit "checks")
  , ("retained.provider.collisions", profileLimit "effects")
  , ("retained.provider.comments", profileLimit "comments")
  , ("retained.provider.custody_actions", profileLimit "delivery_attempts")
  , ("retained.provider.delivery_attempts", profileLimit "delivery_attempts")
  , ("retained.provider.effect_bindings", profileLimit "effects")
  , ("retained.provider.effects", profileLimit "effects")
  , ("retained.provider.findings", profileLimit "findings")
  , ("retained.provider.git_publications", profileLimit "git_publications")
  , ("retained.provider.git_reconciliations", profileLimit "git_reconciliations")
  , ("retained.provider.reviews", profileLimit "reviews")
  , ("retained.provider.threads", profileLimit "threads")
  , ("retained.provider.truth_changes", profileLimit "provider_truth_changes")
  , ("retained.provider.webhooks", profileLimit "webhook_emissions")
  , ("pending.host.activities", profileLimit "dispatch_entries")
  , ("pending.host.custody", profileLimit "pending_custody")
  , ("pending.host.dispatch", profileLimit "dispatch_entries")
  , ("pending.host.runnable", profileLimit "runnable")
  , ("pending.host.timer_acks", profileLimit "dispatch_entries")
  , ("pending.host.timer_maturities", profileLimit "dispatch_entries")
  , ("pending.host.timers", profileLimit "dispatch_entries")
  , ("pending.profile.proposals", profileLimit "runnable")
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
digestOf = either (throw . PyError "ValueError") id . digestJson

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
          , reloads = profileLimit "reloads"
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

-- | A Python exception the profile raises: class name and message.
data PyError = PyError Text Text
  deriving stock (Eq, Show)

instance Exception PyError where
  displayException (PyError cls message) = T.unpack (cls <> ": " <> message)


-- | @strict_object(value, keys, label)@.
strictObject :: Json -> Set Text -> Text -> Either PyError [(Text, Json)]
strictObject value keys label = case value of
  Object members | Set.fromList (map fst members) == keys && length members == Set.size keys -> Right members
  _ -> Left (PyError "ValueError" (label <> " requires exact fields " <> pythonStrListRepr (Set.toAscList keys)))

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"))@ (ASCII).
canonical :: Json -> ByteString
canonical = either (throw . PyError "ValueError") id . canonicalBytes

-- | Lowercase hex SHA-256.

-- | @strict_digest(value)@.
strictDigest :: Json -> Text
strictDigest = sha256Hex . canonical

-- | @bounded_text(value, label, pattern=pattern)@.
boundedText :: Json -> Text -> Maybe (Text -> Bool) -> Either PyError Text
boundedText value label pattern = case value of
  String t | not (T.null t), T.length t <= 20000, maybe True ($ t) pattern -> Right t
  _ -> Left (PyError "ValueError" (label <> " is outside its closed bounded vocabulary"))

-- | @bounded_json(value, limit, label)@.
boundedJson :: Json -> Integer -> Text -> Either PyError ByteString
boundedJson value limit label = case canonicalBytes value of
  Left message -> Left (PyError "ValueError" message)
  Right encoded
    | toInteger (BS.length encoded) > limit ->
        Left (PyError "ValueError" (label <> " has " <> T.pack (show (BS.length encoded)) <> " bytes; limit is " <> T.pack (show limit)))
    | otherwise -> Right encoded
