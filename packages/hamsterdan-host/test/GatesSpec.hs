-- | @tests/unit/host/test_v5_gates.py@: the provider-backed V5
-- publication gates against provider fakes.
module GatesSpec
  ( spec
  , FakePublisher (..)
  , Mode (..)
  , Call (..)
  , newFakePublisher
  , fakeProvider
  , claim1
  , variantName
  , variantField
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (Contract, spelling, validate)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Effects qualified as Effects
import Hamsterdan.GitHub.Models
  ( CommentReference (..)
  , FindingPublication (..)
  , PublicationCollision (..)
  , PublicationResult (..)
  , PublicationStatus (..)
  , Transport (..)
  , boundary
  )
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Gates
import Hamsterdan.Readiness.NetV5.Gating (Variant (..), variantOf)
import Petrus.Json (Json (..))
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Fakes

claim1 :: CurrentClaim
claim1 = CurrentClaim {phase = PhaseRunning, incarnation = 1, head = "h1", base = "b1", policy = "p1"}

reference :: CommentReference
reference = CommentReference 1 "https://example.test/c/1"

data Mode = Created | Existing | Boundary | Collision | Unknown | Capability | Unclassified
  deriving stock (Eq, Show)

data Call
  = CFind Text Text Text Text [Text]
  | CImmutable Text Text Text Text [Text]
  | CImmutableOperation Text Text (Maybe Text) Text
  | CDashboard Text Text Text
  | CFindingFind Text Text
  | CFinding FindingPublication Text (Maybe Text)
  | CFindings Text [FindingPublication] Text
  | CReminderOperation Text (Maybe (Maybe Text)) (Maybe Text)
  deriving stock (Eq, Show)

data FakePublisher = FakePublisher
  { mode :: Mode
  , found :: Bool
  , collide :: Bool
  , calls :: IORef [Call]
  }

newFakePublisher :: Mode -> Bool -> IO FakePublisher
newFakePublisher mode found = FakePublisher mode found False <$> newIORef []

record :: FakePublisher -> Call -> IO ()
record p c = modifyIORef' p.calls (++ [c])

result :: PublicationStatus -> PublicationResult
result status = PublicationResult status (Just reference) True False

outcome :: FakePublisher -> IO PublicationResult
outcome p = case p.mode of
  Existing -> pure (result PublicationExisting)
  Boundary -> throwIO (boundary "GitHub did not prove comment publication")
  Collision -> throwIO PublicationCollision
  Unknown -> throwIO (RuntimeError "provider returned an unclassifiable terminal")
  Capability -> pure (PublicationResult PublicationCapabilityUnavailable Nothing False False)
  Unclassified -> pure (result (PublicationUnclassified "banana"))
  Created -> pure (result PublicationCreated)

fakeProvider :: FakePublisher -> PublicationProvider
fakeProvider p =
  PublicationProvider
    { find = \kind operation head' body compatible -> do
        record p (CFind kind operation head' body compatible)
        when p.collide (throwIO PublicationCollision)
        pure (if p.found then Just (result PublicationExisting) else Nothing)
    , immutable = \kind operation _epoch head' body _authority compatible -> do
        record p (CImmutable kind operation head' body compatible)
        outcome p
    , immutableOperation = \kind operation body ctx _compatible ->
        if p.found
          then record p (CImmutableOperation kind operation Nothing body) >> pure (result PublicationExisting)
          else do
            (_, head') <- ctx
            record p (CImmutableOperation kind operation (Just head') body)
            outcome p
    , dashboard = \operation _epoch head' body -> do
        record p (CDashboard operation head' body)
        outcome p
    , reminderOperation = \operation ctx ->
        if p.found
          then record p (CReminderOperation operation Nothing Nothing) >> pure (result PublicationExisting)
          else do
            (_, _, reviewer, author) <- ctx
            record p (CReminderOperation operation (Just reviewer) (Just author))
            outcome p
    , finding = \publication _epoch head' authority -> do
        record p (CFinding publication head' authority)
        outcome p
    , findings = \_epoch head' items authority -> do
        record p (CFindings head' items authority)
        mapM (const (outcome p)) items
    , findingFind = \operation head' -> do
        record p (CFindingFind operation head')
        pure (if p.found then Just (PublicationResult PublicationExisting (Just reference) True True) else Nothing)
    }

gatesWith :: FakePublisher -> CurrentClaim -> V5PublicationGates
gatesWith p c =
  V5PublicationGates
    { publisher = fakeProvider p
    , claim = pure c
    , recipients = pure (Just "the-reviewer", "the-author")
    , dashboardPhase = pure c.phase
    , resolveStaleThreads = Nothing
    }

gates :: FakePublisher -> V5PublicationGates
gates p = gatesWith p claim1

-- | Gates whose claim AND recipients ports fail.
gatesWithoutContext :: FakePublisher -> V5PublicationGates
gatesWithoutContext p =
  (publicationGates (fakeProvider p) (throwIO (boundary "claim unreadable")) (throwIO (boundary "recipients unreadable")))

moved :: (CurrentClaim -> CurrentClaim) -> CurrentClaim
moved f = f claim1

callsOf :: FakePublisher -> IO [Call]
callsOf p = readIORef p.calls

variantName :: Variant -> Text
variantName x = x.name

variantField :: Text -> Variant -> Json
variantField key x = case x.fields of
  Object members -> maybe Null id (lookup key members)
  _ -> Null

reasonOf :: Variant -> Text
reasonOf x = case variantField "reason" x of
  String r -> r
  _ -> ""

shouldBeVariant :: (Contract a) => Variant -> a -> Expectation
shouldBeVariant actual expected = actual `shouldBe` variantOf expected

-- ---------------------------------------------------------------------------

replyWork :: ReplyReq
replyWork = ReplyReq {id = "c1", text = "the answer"}

remWork :: RemReq
remWork = RemReq {timerId = "t1"}

announceWork :: AnnounceReq
announceWork =
  AnnounceReq {op = "ready:h1:i1", incarnation = 1, head = "h1", base = "b1", policy = "p1", strictBase = True, baseCurrent = True}

legacyAnnounce :: AnnounceReq
legacyAnnounce =
  either (error . show) id $
    validate @AnnounceReq
      ( Object
          [("op", String "ready:h1:i1"), ("incarnation", Int 1), ("head", String "h1"), ("base", String "b1"), ("policy", String "p1")]
      )

dashWork :: DashReq
dashWork =
  either (error . show) id $
    validate @DashReq
      ( Object
          [ ("entries", Array [String "row1", String "row2"])
          , ("digest", String "d1")
          , ("desired_entries", Array [String "row1", String "row2"])
          , ("desired_digest", String "d1")
          ]
      )

dashTerminal :: ([Text] -> Text -> [Text] -> Text -> a) -> a
dashTerminal make = make ["row1", "row2"] "d1" ["row1", "row2"] "d1"

memObject :: [(Text, Json)]
memObject =
  [("reviewed", Array []), ("provisional", Array []), ("findings", Array []), ("dismissed", Array []), ("pub", Object [])]

f1, f2 :: [(Text, Json)]
f1 =
  [ ("id", String "f1")
  , ("blocking", Bool True)
  , ("body", String "The TTL is read as minutes.")
  , ("path", String "src/gate.py")
  , ("line", Int 10)
  , ("suggestion", String "    return issued_at + timedelta(seconds=ttl_seconds)")
  , ("related_locations", Array [Object [("path", String "src/models.py"), ("line", Int 18)]])
  ]
f2 = [("id", String "f2"), ("blocking", Bool True), ("body", String "Only true approvals may count.")]

publishWork :: Publishable
publishWork =
  Publishable
    { head = "h1"
    , base = "b1"
    , policy = "p1"
    , incarnation = 1
    , findings = [f1, f2]
    , effect = "findings:h1:i1"
    , op = "findings:h1:i1"
    , mem = memObject
    }

withFindings :: [[(Text, Json)]] -> Publishable
withFindings fs = Publishable publishWork.head publishWork.base publishWork.policy publishWork.incarnation fs publishWork.effect publishWork.op publishWork.mem

landedOf :: Publishable -> ReviewLanded
landedOf w = ReviewLanded {head = w.head, incarnation = w.incarnation, findings = w.findings, effect = w.effect, mem = w.mem}

spec :: Spec
spec = describe "test_v5_gates" $ do
  describe "TestReplyGate" $ do
    it "test_a_reply_lands_under_its_operation_scoped_identity" $ do
      p <- newFakePublisher Created False
      r <- replyGate (gates p) replyWork
      r `shouldBeVariant` Replied {id = "c1", text = "the answer"}
      cs <- callsOf p
      [(k, o, b) | CImmutableOperation k o _ b <- cs] `shouldSatisfy` \case
        [(k, o, b)] -> (k, o) == ("conversation", "reply:c1") && "the answer" `T.isInfixOf` b
        _ -> False
    it "test_an_already_held_reply_reconciles_landed" $ do
      p <- newFakePublisher Existing False
      r <- replyGate (gates p) replyWork
      r `shouldBeVariant` Replied {id = "c1", text = "the answer"}
    it "test_a_held_reply_reconciles_even_when_the_claim_is_unreadable" $ do
      p <- newFakePublisher Created True
      r <- replyGate (gatesWithoutContext p) replyWork
      r `shouldBeVariant` Replied {id = "c1", text = "the answer"}
    it "test_retryable_exhaustion_classifies_blocked_with_the_text_retained" $ do
      p <- newFakePublisher Boundary False
      r <- replyGate (gates p) replyWork
      r `shouldBeVariant` ReplyBlocked {id = "c1", text = "the answer"}
    it "test_an_identity_collision_fails_closed" $ do
      p <- newFakePublisher Collision False
      r <- replyGate (gates p) replyWork
      variantName r `shouldBe` "ReplyFault"
      (variantField "id" r, variantField "text" r) `shouldBe` (String "c1", String "the answer")
      reasonOf r `shouldBe` "stable publication operation collided with a different payload"
    it "test_an_unknown_terminal_fails_closed" $ do
      p <- newFakePublisher Unknown False
      r <- replyGate (gates p) replyWork
      variantName r `shouldBe` "ReplyFault"
      reasonOf r `shouldBe` "provider returned an unclassifiable terminal"
    it "test_a_proven_capability_denial_classifies_blocked_not_landed" $ do
      p <- newFakePublisher Capability False
      r <- replyGate (gates p) replyWork
      r `shouldBeVariant` ReplyBlocked {id = "c1", text = "the answer"}
    it "test_an_unrecognized_returned_status_fails_closed" $ do
      p <- newFakePublisher Unclassified False
      r <- replyGate (gates p) replyWork
      variantName r `shouldBe` "ReplyFault"
      reasonOf r `shouldBe` "unclassified publication status 'banana'"

  describe "TestReminderGate" $ do
    it "test_a_nudge_lands_under_its_operation_scoped_timer_identity" $ do
      p <- newFakePublisher Created False
      r <- reminderGate (gates p) remWork
      r `shouldBeVariant` RemLanded {timerId = "t1"}
      cs <- callsOf p
      [(o, rv, a) | CReminderOperation o rv a <- cs] `shouldBe` [("reminder:t1", Just (Just "the-reviewer"), Just "the-author")]
    it "test_a_held_nudge_reconciles_even_when_context_is_unreadable" $ do
      p <- newFakePublisher Created True
      r <- reminderGate (gatesWithoutContext p) remWork
      r `shouldBeVariant` RemLanded {timerId = "t1"}
    it "test_retryable_exhaustion_classifies_blocked" $ do
      p <- newFakePublisher Boundary False
      r <- reminderGate (gates p) remWork
      r `shouldBeVariant` RemBlocked {timerId = "t1"}
    it "test_an_unknown_terminal_fails_closed" $ do
      p <- newFakePublisher Unknown False
      r <- reminderGate (gates p) remWork
      variantName r `shouldBe` "RemFault"
      variantField "timer_id" r `shouldBe` String "t1"
      reasonOf r `shouldNotBe` ""
    it "test_a_proven_capability_denial_classifies_blocked_not_landed" $ do
      p <- newFakePublisher Capability False
      r <- reminderGate (gates p) remWork
      r `shouldBeVariant` RemBlocked {timerId = "t1"}
    it "test_an_unrecognized_returned_status_fails_closed" $ do
      p <- newFakePublisher Unclassified False
      r <- reminderGate (gates p) remWork
      variantName r `shouldBe` "RemFault"
      reasonOf r `shouldSatisfy` T.isInfixOf "banana"

  describe "TestAnnounceGate" $ do
    it "test_an_announcement_lands_under_a_standing_claim" $ do
      p <- newFakePublisher Created False
      r <- announceGate (gates p) announceWork
      r `shouldBeVariant` ALanded {incarnation = 1, head = "h1"}
      cs <- callsOf p
      [(k, o) | CImmutable k o _ _ _ <- cs] `shouldBe` [("readiness", "ready:h1:i1")]
    let drifts =
          [ ("phase=terminal", \c -> CurrentClaim PhaseTerminal c.incarnation c.head c.base c.policy)
          , ("phase=quiescent", \c -> CurrentClaim PhaseQuiescent c.incarnation c.head c.base c.policy)
          , ("incarnation=2", \c -> CurrentClaim c.phase 2 c.head c.base c.policy)
          , ("head=h2", \c -> CurrentClaim c.phase c.incarnation "h2" c.base c.policy)
          , ("base=b2", \c -> CurrentClaim c.phase c.incarnation c.head "b2" c.policy)
          , ("policy=p2", \c -> CurrentClaim c.phase c.incarnation c.head c.base "p2")
          ]
    forM_ drifts $ \(label, drift) ->
      it ("test_any_moved_claim_field_refuses_the_post[" <> label <> "]") $ do
        p <- newFakePublisher Created False
        let observed = moved drift
        r <- announceGate (gatesWith p observed) announceWork
        r
          `shouldBeVariant` AMoved
            { incarnation = 1
            , observedHead = observed.head
            , observedBase = observed.base
            , observedPolicy = observed.policy
            , observedIncarnation = observed.incarnation
            , observedPhase = spelling observed.phase
            }
        cs <- callsOf p
        [() | CImmutable {} <- cs] `shouldBe` []
    it "test_lookup_first_reconciles_landed_even_after_the_claim_moved" $ do
      p <- newFakePublisher Created True
      r <- announceGate (gatesWith p (moved (\c -> CurrentClaim c.phase 2 c.head c.base c.policy))) announceWork
      r `shouldBeVariant` ALanded {incarnation = 1, head = "h1"}
    it "test_a_legacy_unlanded_announcement_fails_closed_as_moved" $ do
      p <- newFakePublisher Created False
      r <- announceGate (gates p) legacyAnnounce
      variantName r `shouldBe` "AMoved"
      cs <- callsOf p
      [() | CImmutable {} <- cs] `shouldBe` []
    it "test_a_legacy_announcement_still_reconciles_when_it_already_landed" $ do
      p <- newFakePublisher Created True
      r <- announceGate (gates p) legacyAnnounce
      r `shouldBeVariant` ALanded {incarnation = 1, head = "h1"}
    it "test_retryable_exhaustion_retains_the_exact_request" $ do
      p <- newFakePublisher Boundary False
      r <- announceGate (gates p) announceWork
      r `shouldBeVariant` ABlocked {incarnation = 1, head = "h1", base = "b1", policy = "p1"}
    it "test_unstaged_custody_defers_the_exact_request_without_a_provider_call" $ do
      let blocker = "2c60edc8-6ba8-4cd7-bd89-e1638d70329d"
      p <- newFakePublisher Created False
      let g =
            V5PublicationGates
              { publisher = fakeProvider p
              , claim = throwIO (UnstagedCustodyError blocker)
              , recipients = pure (Just "the-reviewer", "the-author")
              , dashboardPhase = pure PhaseRunning
              , resolveStaleThreads = Nothing
              }
      r <- announceGate g announceWork
      r
        `shouldBeVariant` ADeferred
          { op = announceWork.op
          , incarnation = announceWork.incarnation
          , head = announceWork.head
          , base = announceWork.base
          , policy = announceWork.policy
          , strictBase = announceWork.strictBase
          , baseCurrent = announceWork.baseCurrent
          , blocker
          }
      cs <- callsOf p
      [() | CImmutable {} <- cs] `shouldBe` []
    it "test_an_identity_collision_fails_closed" $ do
      p <- newFakePublisher Collision False
      r <- announceGate (gates p) announceWork
      variantName r `shouldBe` "AFault"
      variantField "op" r `shouldBe` String "ready:h1:i1"
    it "test_an_unknown_terminal_fails_closed" $ do
      p <- newFakePublisher Unknown False
      r <- announceGate (gates p) announceWork
      variantName r `shouldBe` "AFault"
      reasonOf r `shouldNotBe` ""
    it "test_a_proven_capability_denial_classifies_blocked_not_landed" $ do
      p <- newFakePublisher Capability False
      r <- announceGate (gates p) announceWork
      r `shouldBeVariant` ABlocked {incarnation = 1, head = "h1", base = "b1", policy = "p1"}
    it "test_an_unrecognized_returned_status_fails_closed" $ do
      p <- newFakePublisher Unclassified False
      r <- announceGate (gates p) announceWork
      variantName r `shouldBe` "AFault"
      reasonOf r `shouldSatisfy` T.isInfixOf "banana"

  describe "TestDashGate" $ do
    it "test_a_dormant_pr_defers_without_a_provider_effect" $ do
      p <- newFakePublisher Created False
      r <- dashGate (gatesWith p (moved (\c -> CurrentClaim PhaseQuiescent c.incarnation c.head c.base c.policy))) dashWork
      r `shouldBeVariant` dashTerminal (\e d de dd -> DashDeferred e d de dd dashWork.landed dashWork.blocked dashWork.faulted)
      callsOf p >>= (`shouldBe` [])
    it "test_an_upsert_lands_and_echoes_the_desired_state" $ do
      p <- newFakePublisher Created False
      r <- dashGate (gates p) dashWork
      r `shouldBeVariant` dashTerminal DashLanded
      cs <- callsOf p
      case [(o, b) | CDashboard o _ b <- cs] of
        [(o, b)] -> do
          o `shouldBe` "dash:d1"
          b `shouldSatisfy` (\x -> "row1" `T.isInfixOf` x && "row2" `T.isInfixOf` x)
        other -> expectationFailure (show other)
    it "test_an_upsert_never_reads_authority" $ do
      p <- newFakePublisher Created False
      let g = publicationGates (fakeProvider p) (throwIO (userError "the authority-orthogonal dashboard must not read a claim")) (pure (Just "the-reviewer", "the-author"))
      r <- dashGate g dashWork
      variantName r `shouldBe` "DashLanded"
    it "test_retryable_exhaustion_retains_the_exact_effect" $ do
      p <- newFakePublisher Boundary False
      r <- dashGate (gates p) dashWork
      r `shouldBeVariant` dashTerminal DashBlocked
    it "test_an_unknown_terminal_fails_closed" $ do
      p <- newFakePublisher Unknown False
      r <- dashGate (gates p) dashWork
      variantName r `shouldBe` "DashFault"
      variantField "digest" r `shouldBe` String "d1"
      reasonOf r `shouldNotBe` ""
    it "test_a_proven_capability_denial_classifies_blocked_not_landed" $ do
      p <- newFakePublisher Capability False
      r <- dashGate (gates p) dashWork
      r `shouldBeVariant` dashTerminal DashBlocked
    it "test_an_unrecognized_returned_status_fails_closed" $ do
      p <- newFakePublisher Unclassified False
      r <- dashGate (gates p) dashWork
      variantName r `shouldBe` "DashFault"
      reasonOf r `shouldSatisfy` T.isInfixOf "banana"
    it "test_an_updated_board_is_a_proven_landing" $ do
      p <- newFakePublisher Existing False
      r <- dashGate (gates p) dashWork
      variantName r `shouldBe` "DashLanded"

  describe "TestPublishGate" $ do
    it "test_each_finding_lands_under_its_own_anchored_identity" $ do
      p <- newFakePublisher Created False
      r <- publishGate (gates p) publishWork
      r `shouldBeVariant` landedOf publishWork
      cs <- callsOf p
      [o | CFindingFind o _ <- cs] `shouldBe` ["findings:h1:i1:f1", "findings:h1:i1:f2"]
      case [(h, items, a) | CFindings h items a <- cs] of
        [(h, [anchoredOne], a)] -> do
          (h, a) `shouldBe` ("h1", "findings:h1:i1")
          ( anchoredOne.operation
            , anchoredOne.text
            , anchoredOne.path
            , anchoredOne.line
            , anchoredOne.relatedLocations
            , anchoredOne.suggestion
            )
            `shouldBe` ( "findings:h1:i1:f1"
                       , "The TTL is read as minutes."
                       , "src/gate.py"
                       , 10
                       , [("src/models.py", 18)]
                       , "    return issued_at + timedelta(seconds=ttl_seconds)"
                       )
        other -> expectationFailure (show other)
      case [(pub, a) | CFinding pub _ a <- cs] of
        [(pub, a)] -> do
          (pub.operation, pub.path, pub.line) `shouldBe` ("findings:h1:i1:f2", "", 0)
          a `shouldBe` Just "findings:h1:i1"
        other -> expectationFailure (show other)
    it "test_all_anchored_findings_share_one_native_review_mutation" $ do
      let work =
            withFindings
              [ f1
              , [ ("id", String "f2")
                , ("blocking", Bool True)
                , ("body", String "Only true approvals may count.")
                , ("path", String "src/gate.py")
                , ("line", Int 16)
                ]
              ]
      p <- newFakePublisher Created False
      r <- publishGate (gates p) work
      variantName r `shouldBe` "ReviewLanded"
      cs <- callsOf p
      [map (.operation) items | CFindings _ items _ <- cs] `shouldBe` [["findings:h1:i1:f1", "findings:h1:i1:f2"]]
      [() | CFinding {} <- cs] `shouldBe` []
    it "test_a_clear_review_resolves_findings_from_the_superseded_head" $ do
      let work = withFindings []
      p <- newFakePublisher Created False
      resolved <- newIORef []
      let g =
            (publicationGates (fakeProvider p) (pure claim1) (pure (Just "reviewer", "author")))
              { resolveStaleThreads = Just (\h -> modifyIORef' resolved (++ [h]) >> pure 3)
              }
      r <- publishGate g work
      variantName r `shouldBe` "ReviewLanded"
      readIORef resolved >>= (`shouldBe` ["h1"])
      cs <- callsOf p
      [() | c <- cs, isFindingCall c] `shouldBe` []
    it "test_a_clear_review_defers_behind_unstaged_webhook_custody" $ do
      let work = withFindings []
      p <- newFakePublisher Created False
      let g =
            (publicationGates (fakeProvider p) (throwIO (UnstagedCustodyError "delivery-1")) (pure (Just "reviewer", "author")))
              { resolveStaleThreads = Just (\_ -> pure 0)
              }
      r <- publishGate g work
      r
        `shouldBeVariant` PublicationDeferred
          { operation = "findings:h1:i1"
          , head = "h1"
          , base = "b1"
          , policy = "p1"
          , incarnation = 1
          , findings = []
          , effect = "findings:h1:i1"
          , mem = work.mem
          , attempt = 1
          , blocker = "delivery-1"
          }
    it "test_an_unmarkable_finding_id_degrades_to_its_digest" $ do
      let work = withFindings [[("id", String "spaced finding id"), ("blocking", Bool True), ("body", String "b")]]
      p <- newFakePublisher Created False
      _ <- publishGate (gates p) work
      cs <- callsOf p
      case [o | CFindingFind o _ <- cs] of
        [o] -> do
          o `shouldSatisfy` T.isPrefixOf "findings:h1:i1:"
          o `shouldSatisfy` (not . T.isInfixOf " ")
        other -> expectationFailure (show other)
    it "test_a_held_finding_reconciles_without_a_fence_claim_or_post" $ do
      let head' = T.replicate 40 "a"
          operation = "findings:" <> head' <> ":i1"
          work =
            Publishable
              { head = head'
              , base = T.replicate 40 "b"
              , policy = "p1"
              , incarnation = 1
              , findings = [[("id", String "f1"), ("blocking", Bool True), ("body", String "The TTL is read as minutes.")]]
              , effect = operation
              , op = operation
              , mem = memObject
              }
      marker <- either (fail . show) pure (Effects.marker "finding" (operation <> ":f1") head')
      requests <- newIORef []
      fences <- newIORef (0 :: Int)
      claims <- newIORef (0 :: Int)
      let transport =
            Transport
              { pages = \path ->
                  if path == "/repos/owner/repo/pulls/7/comments?per_page=100"
                    then
                      pure
                        [ [ ("id", Int 7)
                          , ("html_url", String "https://github.com/owner/repo/pull/7#discussion_r7")
                          , ("body", String ("The TTL is read as minutes.\n\n" <> marker))
                          , ("user", Object [("login", String "hamsterdan[bot]")])
                          ]
                        ]
                    else do
                      path `shouldBe` "/repos/owner/repo/issues/7/comments?per_page=100"
                      pure []
              , request = \method path _ -> do
                  modifyIORef' requests (++ [(method, path)])
                  fail "a held finding must not be posted again"
              }
      pub <-
        either (fail . show) pure $
          Effects.commentPublisher transport "owner/repo" 7 "hamsterdan[bot]" (\_ _ _ _ _ -> modifyIORef' fences (+ 1)) Nothing (\_ -> pure ())
      let g =
            publicationGates
              (publicationProvider pub)
              (modifyIORef' claims (+ 1) >> pure (CurrentClaim PhaseRunning 1 head' (T.replicate 40 "b") "p1"))
              (pure (Just "reviewer", "author"))
      r <- publishGate g work
      r `shouldBeVariant` landedOf work
      readIORef claims >>= (`shouldBe` 0)
      readIORef fences >>= (`shouldBe` 0)
      readIORef requests >>= (`shouldBe` ([] :: [(Text, Text)]))
    it "test_lookup_first_reconciles_landed_even_after_the_claim_moved" $ do
      p <- newFakePublisher Created True
      r <- publishGate (gatesWith p (moved (\c -> CurrentClaim c.phase c.incarnation "h2" c.base c.policy))) publishWork
      variantName r `shouldBe` "ReviewLanded"
      variantField "effect" r `shouldBe` String "findings:h1:i1"
    it "test_a_content_collision_fails_closed" $ do
      p <- newFakePublisher Collision False
      r <- publishGate (gates p) publishWork
      variantName r `shouldBe` "ReviewFault"
      reasonOf r `shouldSatisfy` T.isInfixOf "collided"
    it "test_a_moved_claim_reports_the_complete_observed_authority" $ do
      p <- newFakePublisher Created False
      let observed = moved (\c -> CurrentClaim PhaseQuiescent 2 c.head c.base c.policy)
      r <- publishGate (gatesWith p observed) publishWork
      r
        `shouldBeVariant` ReviewMoved
          { head = "h1"
          , observed = observed.head
          , observedBase = observed.base
          , observedPolicy = observed.policy
          , observedIncarnation = 2
          , observedPhase = PhaseQuiescent
          , findings = publishWork.findings
          , mem = publishWork.mem
          }
      cs <- callsOf p
      [() | CFinding {} <- cs] `shouldBe` []
    it "test_retryable_exhaustion_retains_the_exact_operation" $ do
      p <- newFakePublisher Boundary False
      r <- publishGate (gates p) publishWork
      r
        `shouldBeVariant` ReviewBlocked
          { head = "h1"
          , base = "b1"
          , policy = "p1"
          , incarnation = 1
          , findings = publishWork.findings
          , effect = "findings:h1:i1"
          , op = "findings:h1:i1"
          , failureClass = FailureTransportAmbiguity
          , providerStatus = Nothing
          , providerDetail = "none"
          , mem = publishWork.mem
          }
    it "test_an_unknown_terminal_fails_closed" $ do
      p <- newFakePublisher Unknown False
      r <- publishGate (gates p) publishWork
      variantName r `shouldBe` "ReviewFault"
      reasonOf r `shouldNotBe` ""
    it "test_a_proven_capability_denial_classifies_blocked_not_landed" $ do
      p <- newFakePublisher Capability False
      r <- publishGate (gates p) publishWork
      variantName r `shouldBe` "ReviewBlocked"
      variantField "op" r `shouldBe` String "findings:h1:i1"
      (variantField "failure_class" r, variantField "provider_status" r, variantField "provider_detail" r)
        `shouldBe` (String "capability_denial", Null, String "none")
    it "test_an_unrecognized_returned_status_fails_closed" $ do
      p <- newFakePublisher Unclassified False
      r <- publishGate (gates p) publishWork
      variantName r `shouldBe` "ReviewFault"
      reasonOf r `shouldSatisfy` T.isInfixOf "banana"

  describe "TestStaleThreadResolution" $ do
    let staleGates p resolved =
          (gates p) {resolveStaleThreads = Just (\h -> modifyIORef' resolved (++ [h]) >> pure 0)}
        work =
          AnnounceReq {op = "ready:h1:i1", incarnation = 1, head = "h1", base = "b1", policy = "p1", strictBase = False, baseCurrent = True}
    it "test_a_fresh_finding_publication_resolves_stale_threads_for_its_head" $ do
      resolved <- newIORef []
      p <- newFakePublisher Created False
      r <- publishGate (staleGates p resolved) publishWork
      variantName r `shouldBe` "ReviewLanded"
      readIORef resolved >>= (`shouldBe` ["h1"])
    it "test_a_held_finding_reconcile_never_touches_threads" $ do
      resolved <- newIORef []
      p <- newFakePublisher Created True
      r <- publishGate (staleGates p resolved) publishWork
      variantName r `shouldBe` "ReviewLanded"
      readIORef resolved >>= (`shouldBe` [])
    it "test_a_fresh_announcement_resolves_stale_threads_for_its_head" $ do
      resolved <- newIORef []
      p <- newFakePublisher Created False
      r <- announceGate (staleGates p resolved) work
      r `shouldBeVariant` ALanded {incarnation = 1, head = "h1"}
      readIORef resolved >>= (`shouldBe` ["h1"])
    it "test_a_held_announcement_reconcile_never_touches_threads" $ do
      resolved <- newIORef []
      p <- newFakePublisher Created True
      r <- announceGate (staleGates p resolved) work
      r `shouldBeVariant` ALanded {incarnation = 1, head = "h1"}
      readIORef resolved >>= (`shouldBe` [])
  where
    isFindingCall = \case
      CFinding {} -> True
      CFindings {} -> True
      CFindingFind {} -> True
      _ -> False
