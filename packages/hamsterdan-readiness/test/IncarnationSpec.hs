-- | Incarnation fencing of the readiness snapshot, as properties
-- (ELG-H-12): a fact from a stale incarnation never changes the snapshot,
-- whatever the snapshot and the fact hold.
--
-- A lifecycle fact applies from the snapshot's incarnation on (A1.4's
-- @fact.incarnation < snapshot.incarnation@ skip); every other decision
-- fact applies only when it is global (incarnation 0) or current.
module IncarnationSpec (spec) where

import Data.Maybe (isJust)
import Data.Text (Text)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.Readiness.NetV5.Readiness
  ( applyChecks
  , applyFindings
  , applyHuman
  , applyMutationPending
  , applyMutationSettled
  , applyReview
  , applyState
  )
import Hedgehog (Gen, Property, assert, forAll, property, (===))
import Hedgehog qualified as H
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Petrus.Json (Json (..))
import Test.Hspec (Expectation, Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "incarnation fencing (properties)" $ do
  it "a lifecycle fact older than the snapshot leaves it unchanged" $ holds $ property $ do
    snap <- forAll (Gen.filter ((> 0) . (.incarnation)) genSnapshot)
    fact <- forAll (genStateFact (Range.linear 0 (snap.incarnation - 1)))
    applyState snap fact === Nothing
  it "a lifecycle fact of the snapshot's incarnation or later applies" $ holds $ property $ do
    snap <- forAll genSnapshot
    fact <- forAll (genStateFact (Range.linear snap.incarnation (snap.incarnation + 3)))
    let applied = applyState snap fact
    assert (isJust applied)
    fmap (.incarnation) applied === Just fact.incarnation
  it "a stale decision fact leaves the snapshot unchanged" $ holds $ property $ do
    snap <- forAll genSnapshot
    stale <- forAll (Gen.filter (\i -> i /= 0 && i /= snap.incarnation) (genIncarnation (snap.incarnation + 3)))
    apply <- forAll genDecision
    applyDecision apply snap stale === Nothing
  it "a global or current decision fact applies" $ holds $ property $ do
    snap <- forAll genSnapshot
    incarnation <- forAll (Gen.element [0, snap.incarnation])
    apply <- forAll genDecision
    assert (isJust (applyDecision apply snap incarnation))
  where
    holds :: Property -> Expectation
    holds law = H.check law >>= (`shouldBe` True)

-- | One of the incarnation-fenced decision facts, with a fixed body.
data Decision = Checks | Review | Findings | Human | Pending | Settled
  deriving stock (Bounded, Enum, Show)

genDecision :: Gen Decision
genDecision = Gen.enumBounded

applyDecision :: Decision -> C.Snapshot -> Integer -> Maybe C.Snapshot
applyDecision decision snap incarnation = case decision of
  Checks -> applyChecks snap C.ChecksFact {incarnation = incarnation, body = C.ChecksFactBody {status = C.StatusSuccess}}
  Review ->
    applyReview
      snap
      C.ReviewFact {incarnation = incarnation, body = C.BodyReviewStatus C.ReviewStatusFactBody {head = "h", status = C.ReviewClear}}
  Findings ->
    applyFindings snap C.FindingsFact {incarnation = incarnation, body = C.FindingsFactBody {head = "h", blocking = 1, count = 2}}
  Human ->
    applyHuman snap C.HumanFact {incarnation = incarnation, body = C.HumanFactBody {approval = True, changesRequested = False, unresolved = 0}}
  Pending ->
    applyMutationPending snap C.MutationPendingFact {incarnation = incarnation, body = C.MutationPendingFactBody {op = "change", opKey = "k"}}
  Settled ->
    applyMutationSettled
      snap
      C.MutationSettledFact
        { incarnation = incarnation
        , body = C.MutationSettled {op = "change", opKey = "k", outcome = C.OutcomeLanded, incarnation = incarnation, fingerprint = ""}
        }

genIncarnation :: Integer -> Gen Integer
genIncarnation top = Gen.integral (Range.linear 0 top)

genText :: Gen Text
genText = Gen.element ["", "h1", "h2", "b1", "p1", "running", "success", "pending"]

genKeyed :: Gen [(Text, Json)]
genKeyed = Gen.element [[], [("op", String "x")], [("announce:x", String "boom")]]

genSnapshot :: Gen C.Snapshot
genSnapshot = do
  incarnation <- genIncarnation 6
  phase <- genText
  head_ <- genText
  base <- genText
  policy <- genText
  mergeable <- Gen.bool
  checks <- genText
  review <- Gen.enumBounded
  findingsBlocking <- Gen.integral (Range.linear 0 3)
  approval <- Gen.bool
  changesRequested <- Gen.bool
  unresolved <- Gen.integral (Range.linear 0 3)
  pending <- Gen.list (Range.linear 0 2) genText
  faults <- genKeyed
  announced <- Gen.list (Range.linear 0 2) (genIncarnation 6)
  candidate <- Gen.bool
  announcing <- genKeyed
  blocked <- genKeyed
  strictBase <- Gen.bool
  baseCurrent <- Gen.bool
  closing <- Gen.maybe genText
  pure
    C.Snapshot
      { incarnation = incarnation
      , phase = phase
      , head = head_
      , base = base
      , policy = policy
      , mergeable = mergeable
      , checks = checks
      , review = review
      , findingsBlocking = findingsBlocking
      , approval = approval
      , changesRequested = changesRequested
      , unresolved = unresolved
      , pending = pending
      , faults = faults
      , announced = announced
      , candidate = candidate
      , announcing = announcing
      , blocked = blocked
      , strictBase = strictBase
      , baseCurrent = baseCurrent
      , closing = closing
      }

genStateFact :: Range.Range Integer -> Gen C.StateFact
genStateFact incarnations = do
  incarnation <- Gen.integral incarnations
  phase <- Gen.enumBounded
  head_ <- genText
  base <- genText
  mergeable <- Gen.bool
  policy <- genText
  strictBase <- Gen.bool
  baseCurrent <- Gen.bool
  pure
    C.StateFact
      { incarnation = incarnation
      , body =
          C.StateFactBody
            { phase = phase
            , head = head_
            , base = base
            , mergeable = mergeable
            , policy = policy
            , strictBase = strictBase
            , baseCurrent = baseCurrent
            }
      }
