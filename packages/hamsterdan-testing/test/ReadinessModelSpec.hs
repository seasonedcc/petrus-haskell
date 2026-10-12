-- | @tests/unit/testing/test_readiness_model.py@: 29 functions, 34 cases
-- (three parametrized: incarnation-bound kinds x3, change kinds x2,
-- inactive lifecycles x3), plus the construction rules the reference
-- enforces in @__post_init__@ but tests only through the subject rule.
--
-- The reference builds every value through its validating constructor, so
-- each facts value here goes through 'checked' before it is evaluated:
-- a test value the reference could not construct fails the test.
module ReadinessModelSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Testing.Readiness
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps)
import Petrus.Testing.Dst.Types (CheckResult (..), Observation (..), apiCompatibility, artifactFormat, resultVersion)
import Test.Hspec

a40, c40 :: Text
a40 = T.replicate 40 "a"
c40 = T.replicate 40 "c"

-- | @claim()@.
claim :: AuthorityClaim
claim =
  AuthorityClaim
    { installation = 44
    , repository = 31
    , pullRequest = 7
    , head = a40
    , base = T.replicate 40 "b"
    , policy = "policy-1"
    , lifecycle = Active
    , strictBase = True
    , baseCurrent = True
    , mergeable = True
    }

-- | @claim(head=...)@.
headed :: Text -> AuthorityClaim
headed revision = case claim of
  AuthorityClaim i r p _ b policy l s c m -> AuthorityClaim i r p revision b policy l s c m

-- | @claim(lifecycle=...)@.
living :: Lifecycle -> AuthorityClaim
living lifecycle = claim {lifecycle}

-- | @ready_facts()@.
readyFacts :: ReadinessFacts
readyFacts =
  (readinessFacts "github:44:31:pr:7" (AuthorityFacts 1 (Just claim) claim))
    { admittedObservations = ["delivery:open"]
    , ci = CiFacts a40 ["build"] [CheckFacts "build" Success] RecoveryNone
    , review = ReviewFacts a40 ReviewClear []
    , human = humanFacts {approvals = 1, requiredApprovals = 1}
    }

-- | @authorization(operation=..., authority=...)@.
grant :: Text -> AuthorityClaim -> ChangeAuthorization
grant operation authority = ChangeAuthorization "delivery:comment:1" operation authority IntentRepair "sha256:repair-request-1"

withAuthority :: AuthorityFacts -> ReadinessFacts -> ReadinessFacts
withAuthority authority (ReadinessFacts s _ o c r h m e t) = ReadinessFacts s authority o c r h m e t

withSubject :: Text -> ReadinessFacts -> ReadinessFacts
withSubject subject (ReadinessFacts _ a o c r h m e t) = ReadinessFacts subject a o c r h m e t

-- | @MutationFacts(status, operation, head, authorization=...)@.
mutating :: MutationStatus -> Text -> Text -> Maybe ChangeAuthorization -> MutationFacts
mutating status operation revision = MutationFacts status operation revision ""

-- | @EffectObligation(...)@ with every field spelled.
effect :: EffectKind -> Text -> AuthorityClaim -> Maybe AuthorityClaim -> Text -> EffectStatus -> Maybe Text -> EffectObligation
effect kind operation authority accepted digest status authorization =
  EffectObligation kind operation authority digest status accepted authorization True

-- | @ReadinessModel().evaluate(facts)@ on a value the reference could build.
verdict :: ReadinessFacts -> ReadinessExpectation
verdict = either (error . T.unpack) evaluate . checked

fair :: FairEnvironment
fair = FairEnvironment True True True True True

spec :: Spec
spec = describe "ReadinessModel" $ do
  it "clean green is ready without topology state" $ do
    let expectation = verdict readyFacts
    expectation.ready `shouldBe` True
    expectation.disposition `shouldBe` Ready
    expectation.blockers `shouldBe` []
    expectation.violations `shouldBe` []

  it "a new provider head invalidates old readiness until fresh evidence arrives" $ do
    (verdict readyFacts).disposition `shouldBe` Ready
    let providerB = headed c40
        awaiting = withAuthority (AuthorityFacts 1 (Just claim) providerB) readyFacts
    (verdict awaiting).blockers `shouldBe` ["current_authority_admission"]
    let stale = awaiting {effects = [effect EffectReadiness "ready:head-a" claim (Just providerB) "head-a-ready" EffectSettled Nothing]}
    (verdict stale).violations `shouldBe` ["stale_effect_settled:ready:head-a", "readiness_published_with_closed_gates:ready:head-a"]
    let admittedB = withAuthority (AuthorityFacts 2 (Just providerB) providerB) readyFacts
    (verdict admittedB).blockers `shouldBe` ["current_ci_evidence", "current_review_evidence"]
    let currentB =
          admittedB
            { ci = CiFacts c40 ["build"] [CheckFacts "build" Success] RecoveryNone
            , review = ReviewFacts c40 ReviewClear []
            }
    (verdict currentB).disposition `shouldBe` Ready

  it "historical effect does not become stale when provider authority later moves" $ do
    let facts =
          (withAuthority (AuthorityFacts 1 (Just claim) (headed c40)) readyFacts)
            { effects = [effect EffectReadiness "ready:head-a" claim (Just claim) "head-a-ready" EffectSettled Nothing]
            }
        expectation = verdict facts
    expectation.blockers `shouldBe` ["current_authority_admission"]
    expectation.violations `shouldBe` []

  it "effect accepted after provider authority moves is stale" $ do
    let facts =
          (withAuthority (AuthorityFacts 1 (Just claim) (headed c40)) readyFacts)
            { effects = [effect EffectReadiness "ready:head-a-late" claim (Just (headed c40)) "head-a-ready-late" EffectSettled Nothing]
            }
    (verdict facts).violations `shouldBe` ["stale_effect_settled:ready:head-a-late", "readiness_published_with_closed_gates:ready:head-a-late"]

  describe "incarnation-bound effects remain valid after provider authority moves" $
    mapM_
      ( \kind -> it (T.unpack (spelling kind)) $ do
          let authorityB = headed c40
              facts =
                (withAuthority (AuthorityFacts 2 (Just authorityB) authorityB) readyFacts)
                  { effects = [effect kind (spelling kind <> ":incarnation-1") claim (Just authorityB) "incarnation-bound-effect" EffectSettled Nothing]
                  }
          (verdict facts).violations `shouldBe` []
      )
      [EffectDashboard, EffectConversation, EffectReminder]

  it "transient CI failure progresses but persistent repair waits for a human" $ do
    let failedCheck = CheckFacts "build" Failure
        failed = readyFacts {ci = CiFacts a40 ["build"] [failedCheck] RecoveryAutomatic}
        persistent = readyFacts {ci = CiFacts a40 ["build"] [failedCheck] RecoveryHumanAuthorization}
    (verdict failed).disposition `shouldBe` Progressing
    (verdict failed).blockers `shouldBe` ["ci_failed:build"]
    (verdict persistent).disposition `shouldBe` HumanWait
    (verdict persistent).blockers `shouldBe` ["ci_repair_authorization:build"]

  it "every required check is derived from provider facts" $ do
    let missing = readyFacts {ci = CiFacts a40 ["build", "security"] [CheckFacts "build" Success] RecoveryNone}
        failed =
          readyFacts
            { ci = CiFacts a40 ["build", "security"] [CheckFacts "build" Success, CheckFacts "security" Failure] RecoveryAutomatic
            }
    (verdict missing).blockers `shouldBe` ["required_ci_missing:security"]
    (verdict failed).blockers `shouldBe` ["ci_failed:security"]

  it "open finding and collaboration require human resolution" $ do
    let facts =
          readyFacts
            { review = ReviewFacts a40 ReviewBlocking [Finding "finding-1" True FindingOpen]
            , human = humanFacts {approvals = 1, requiredApprovals = 1, changesRequested = True, unresolvedConversations = 2}
            }
        expectation = verdict facts
    expectation.disposition `shouldBe` HumanWait
    expectation.blockers `shouldBe` ["blocking_findings", "changes_requested", "unresolved_conversations"]

  it "agent inability and missing approval are explicit waits" $ do
    let unable = readyFacts {review = ReviewFacts a40 ReviewUnable []}
        approval = readyFacts {human = humanFacts {approvals = 0, requiredApprovals = 1}}
    (verdict unable).disposition `shouldBe` ExternalWait
    (verdict unable).blockers `shouldBe` ["review_capability"]
    (verdict approval).disposition `shouldBe` HumanWait
    (verdict approval).blockers `shouldBe` ["human_approval"]

  it "provider movement stales admitted authority and current evidence" $ do
    let expectation = verdict (withAuthority (AuthorityFacts 1 (Just claim) (headed c40)) readyFacts)
    expectation.ready `shouldBe` False
    expectation.disposition `shouldBe` Progressing
    expectation.blockers `shouldBe` ["current_authority_admission"]

  it "new generation requires fresh CI and review evidence" $ do
    let current = headed c40
        expectation = verdict (withAuthority (AuthorityFacts 2 (Just current) current) readyFacts)
    expectation.blockers `shouldBe` ["current_ci_evidence", "current_review_evidence"]
    expectation.disposition `shouldBe` Progressing

  it "draft, resume, and close have distinct dispositions" $ do
    let drafted = living Draft
        draft = withAuthority (AuthorityFacts 1 (Just drafted) drafted) readyFacts
        resumed = headed c40
        resume = withAuthority (AuthorityFacts 2 (Just resumed) resumed) readyFacts
        closed = living Closed
        close = withAuthority (AuthorityFacts 1 (Just closed) closed) readyFacts
    (verdict draft).disposition `shouldBe` HumanWait
    (verdict draft).blockers `shouldBe` ["pull_request_draft"]
    (verdict resume).blockers `shouldBe` ["current_ci_evidence", "current_review_evidence"]
    (verdict close).disposition `shouldBe` Terminal

  it "mutation, effect, and timer obligations are visible" $ do
    let facts =
          readyFacts
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , mutation = mutating MutationInFlight "push:comment:1" a40 (Just (grant "push:comment:1" claim))
            , effects = [effect EffectGitMutation "push:comment:1" claim Nothing "change-1" EffectAmbiguous (Just "delivery:comment:1")]
            , timers = [TimerObligation "reminder:1" TimerDue True]
            }
        expectation = verdict facts
    expectation.disposition `shouldBe` Progressing
    expectation.blockers `shouldBe` ["mutation_in_flight", "effect_ambiguous:push:comment:1", "timer_due:reminder:1"]
    expectation.violations `shouldBe` []

  describe "coding and git mutation require explicit human authorization" $
    mapM_
      ( \kind -> it (T.unpack (spelling kind)) $ do
          let facts =
                readyFacts
                  { mutation = mutating MutationInFlight "push:comment:1" a40 Nothing
                  , effects = [effect kind "push:comment:1" claim (Just claim) "change-1" EffectAccepted Nothing]
                  }
              expectation = verdict facts
          expectation.disposition `shouldBe` Quarantined
          expectation.violations `shouldBe` ["unauthorized_change:push:comment:1"]
      )
      [EffectCoding, EffectGitMutation]

  it "change authorization is bound to one exact operation" $ do
    let facts =
          readyFacts
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , mutation = mutating MutationInFlight "push:comment:2" a40 (Just (grant "push:comment:1" claim))
            , effects = [effect EffectCoding "push:comment:2" claim (Just claim) "change-2" EffectAccepted (Just "delivery:comment:1")]
            }
    (verdict facts).violations `shouldBe` ["unauthorized_change:push:comment:2"]

  it "change effect must reference the exact authorization identity" $ do
    let facts =
          readyFacts
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , mutation = mutating MutationInFlight "push:comment:1" a40 (Just (grant "push:comment:1" claim))
            , effects =
                [effect EffectCoding "push:comment:1" claim (Just claim) "change-1" EffectAccepted (Just "delivery:someone-elses-comment")]
            }
    (verdict facts).violations `shouldBe` ["unauthorized_change:push:comment:1"]

  it "change authorization requires its human delivery to be admitted" $ do
    let facts =
          readyFacts
            { mutation = mutating MutationInFlight "push:comment:1" a40 (Just (grant "push:comment:1" claim))
            , effects = [effect EffectCoding "push:comment:1" claim (Just claim) "change-1" EffectAccepted (Just "delivery:comment:1")]
            }
    (verdict facts).violations `shouldBe` ["unauthorized_change:push:comment:1"]

  it "change authorization is bound to the current full authority" $ do
    let authorityB = headed c40
        facts =
          (withAuthority (AuthorityFacts 2 (Just authorityB) authorityB) readyFacts)
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , ci = CiFacts c40 ["build"] [CheckFacts "build" Success] RecoveryNone
            , review = ReviewFacts c40 ReviewClear []
            , mutation = mutating MutationInFlight "push:comment:1" c40 (Just (grant "push:comment:1" claim))
            , effects =
                [effect EffectGitMutation "push:comment:1" authorityB (Just authorityB) "change-1" EffectAccepted (Just "delivery:comment:1")]
            }
    (verdict facts).violations `shouldBe` ["unauthorized_change:push:comment:1"]

  it "authorized self push may advance only to its declared result head" $ do
    let pushed = headed c40
        facts =
          (withAuthority (AuthorityFacts 1 (Just claim) pushed) readyFacts)
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , mutation = MutationFacts MutationAmbiguous "push:comment:1" a40 c40 (Just (grant "push:comment:1" claim))
            , effects = [effect EffectGitMutation "push:comment:1" claim (Just claim) "change-1" EffectAmbiguous (Just "delivery:comment:1")]
            }
        expectation = verdict facts
    expectation.blockers `shouldBe` ["current_authority_admission"]
    expectation.violations `shouldBe` []
    let unrelated = withAuthority (AuthorityFacts 1 (Just claim) (headed (T.replicate 40 "d"))) facts
    (verdict unrelated).violations `shouldBe` ["unauthorized_change:push:comment:1"]

  it "duplicate admission and effect identity collision are safety violations" $ do
    let facts =
          readyFacts
            { admittedObservations = ["delivery:open", "delivery:open"]
            , effects =
                [ effect EffectDashboard "dashboard:1" claim (Just claim) "one" EffectSettled Nothing
                , effect EffectDashboard "dashboard:1" claim (Just claim) "two" EffectSettled Nothing
                ]
            }
        expectation = verdict facts
    expectation.disposition `shouldBe` Quarantined
    expectation.violations `shouldBe` ["duplicate_admission:delivery:open", "effect_identity_collision:dashboard:1"]

  it "stale effect and premature readiness publication are safety violations" $ do
    let facts =
          readyFacts
            { ci = CiFacts a40 ["build"] [CheckFacts "build" Failure] RecoveryAutomatic
            , effects = [effect EffectReadiness "ready:old" (headed (T.replicate 40 "0")) (Just claim) "ready" EffectSettled Nothing]
            }
        expectation = verdict facts
    expectation.disposition `shouldBe` Quarantined
    expectation.violations `shouldBe` ["stale_effect_settled:ready:old", "readiness_published_with_closed_gates:ready:old"]

  describe "readiness cannot be published outside an active lifecycle" $
    mapM_
      ( \lifecycle -> it (T.unpack (spelling lifecycle)) $ do
          let authority = living lifecycle
              operation = "ready:" <> spelling lifecycle
              facts =
                (withAuthority (AuthorityFacts 1 (Just authority) authority) readyFacts)
                  { effects = [effect EffectReadiness operation authority (Just authority) "ready" EffectSettled Nothing]
                  }
          (verdict facts).violations `shouldContain` ["readiness_published_outside_active_lifecycle:" <> operation]
      )
      [Draft, Merged, Closed]

  it "historical readiness is not current while resumed authority awaits admission" $ do
    let facts =
          (withAuthority (AuthorityFacts 2 (Just (living Draft)) claim) readyFacts)
            { effects = [effect EffectReadiness "ready:head:i1" claim (Just claim) "ready" EffectSettled Nothing]
            }
        expectation = verdict facts
    expectation.blockers `shouldBe` ["current_authority_admission"]
    expectation.violations `shouldBe` []

  it "settled effect is stale when provider authority moves before admission" $ do
    let provider = headed c40
        facts =
          (withAuthority (AuthorityFacts 1 (Just claim) provider) readyFacts)
            { admittedObservations = ["delivery:open", "delivery:comment:1"]
            , mutation = mutating MutationInFlight "push:stale" a40 (Just (grant "push:stale" claim))
            , effects = [effect EffectGitMutation "push:stale" claim (Just provider) "change" EffectSettled (Just "delivery:comment:1")]
            }
    (verdict facts).violations `shouldBe` ["unauthorized_change:push:stale", "stale_effect_settled:push:stale"]

  it "strict snapshot round trips as JSON and rejects unmodeled payloads" $ do
    encoded <- either (fail . show) pure (dumps compact {sortKeys = True} (dump readyFacts))
    load encoded `shouldBe` Right readyFacts
    payload <- case dump readyFacts of
      Object members -> either (fail . show) pure (dumps compact (Object (members <> [("credential", String "must-not-enter-the-model")])))
      other -> fail (show other)
    (load payload :: Either Text ReadinessFacts) `shouldSatisfy` isLeft
    checked (withSubject "github:44:31:pr:8" readyFacts) `shouldSatisfy` either ("subject must match" `T.isInfixOf`) (const False)

  -- ARTIFACT_VERSION has no constant in petrus-dst's Haskell API (the
  -- version is read off a decoded artifact); the v4 API pins it to 4.
  it "model values fit the supported Petrus detached contract" $ do
    let expectation = verdict readyFacts
        observation = Observation {name = "readiness.expected_facts", value = dump readyFacts, instant = 0, generation = 1, sequence = 0}
        result = CheckResult {passed = expectation.ready, detail = dump expectation}
    apiCompatibility `shouldBe` "petrus.testing.dst/v4"
    artifactFormat `shouldBe` "petrus-dst-world"
    resultVersion `shouldBe` 2
    observation.value `shouldBe` dump readyFacts
    result.passed `shouldBe` True

  it "liveness only blames runtime after a fair environment exhausts its budget" $ do
    let progressing = verdict ambiguousPush
    evaluateLiveness progressing fair False `shouldBe` InProgress
    evaluateLiveness progressing fair True `shouldBe` Livelock

  it "liveness does not call provider or human wait livelock" $ do
    let providerWait = verdict readyFacts {ci = CiFacts a40 ["build"] [CheckFacts "build" Unavailable] RecoveryNone}
        humanWait = verdict readyFacts {human = humanFacts {approvals = 0, requiredApprovals = 1}}
    evaluateLiveness providerWait fair True `shouldBe` NotApplicable
    evaluateLiveness humanWait fair True `shouldBe` NotApplicable

  it "liveness requires every fair environment condition" $ do
    let unfair = fair {generatedFaultsStopped = False}
    evaluateLiveness (verdict ambiguousPush) unfair True `shouldBe` NotApplicable

  describe "construction rules (the reference's __post_init__)" $ do
    it "authority identities must be positive" $
      checked claim {pullRequest = 0} `shouldBe` Left "$: authority identities must be positive"
    it "generation zero must have no admitted authority" $ do
      checked (AuthorityFacts 0 (Just claim) claim) `shouldSatisfy` refusedWith "generation zero must have no admitted authority"
      checked (AuthorityFacts 1 Nothing claim) `shouldSatisfy` refusedWith "generation zero must have no admitted authority"
      checked (AuthorityFacts (-1) Nothing claim) `shouldSatisfy` refusedWith "generation zero must have no admitted authority"
    it "human fact counts cannot be negative" $
      checked humanFacts {unresolvedConversations = -1} `shouldSatisfy` refusedWith "human fact counts cannot be negative"
    it "active mutation facts require an operation and head" $
      checked (mutating MutationRequested "push" "" Nothing) `shouldSatisfy` refusedWith "active mutation facts require an operation and head"
    it "only an accepted or ambiguous mutation may declare a result head" $ do
      checked (MutationFacts MutationInFlight "push" a40 c40 Nothing) `shouldSatisfy` refusedWith "only an accepted or ambiguous mutation"
      checked (MutationFacts MutationAcceptedPendingAdmission "push" a40 c40 Nothing) `shouldSatisfy` (not . isLeft)
    it "accepted effects require provider authority at acceptance" $
      checked (effect EffectCoding "push" claim Nothing "d" EffectSettled Nothing)
        `shouldSatisfy` refusedWith "accepted effects require provider authority at acceptance"
    it "admitted and provider authority must describe one pull request" $
      checked (withAuthority (AuthorityFacts 1 (Just claim {pullRequest = 8}) claim) readyFacts)
        `shouldSatisfy` refusedWith "admitted and provider authority must describe one pull request"
 where
  ambiguousPush =
    readyFacts
      { admittedObservations = ["delivery:open", "delivery:comment:1"]
      , mutation = mutating MutationAmbiguous "push:1" a40 (Just (grant "push:1" claim))
      }

refusedWith :: Text -> Either Text a -> Bool
refusedWith message = either (message `T.isInfixOf`) (const False)
