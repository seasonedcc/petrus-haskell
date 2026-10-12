-- | Parity: @tests/petrus/impetus/instance/test_lifecycle_scopes.py@ —
-- production lifecycle-scope semantics on the real Instance and History:
-- scoped queue identities, close/reset cleanup and cancellation, late
-- terminal quarantine, scoped-delivery dispositions, and the replay door's
-- refusal of malformed scope closes.
--
-- Translation notes. The reference's @Work@ class (prepare/project) is an
-- 'ActivityHandler' record. Its @RefusingHistory@ subclass, which raises
-- @OSError@ on a @ScopeClosed@ append, is an in-memory store built with
-- 'mirroredHistoryStore' whose durable write throws an 'IOError'.
module Petrus.Impetus.LifecycleScopesSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Petrus.Activity (invocation)
import Petrus.Impetus.Binding
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (Admission (..), CommitMode (..), HistoryStore, mirroredHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.Scope
import Petrus.Impetus.TestSupport (expectRight, np, obj, shouldFailWith, tokD)
import Petrus.Impetus.TestSupport qualified as TS
import Petrus.Json (Json (..))
import System.IO.Error (ioeGetErrorString)
import Test.Hspec

source, queue, work, out :: NetPath
source = np "source"
queue = np "queue"
work = np "work"
out = np "out"

-- | The reference's @Work@: ask the @work@ Activity for the first token's
-- value; project its result as a @Value@ token on @out@.
workHandler :: ActivityHandler
workHandler =
  ActivityHandler
    { prepare = \b -> case bindingTokens b of
        t : _ -> invocation "work" (obj [("value", t.payload)])
        [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(out, [tokD "Value" result])])
    , projectFailure = Nothing
    }

scopedNet :: Bool -> Net
scopedNet activity =
  TS.netOf
    [place queue, place out]
    [transition source, (transition work) {handler = if activity then Just (HandlerSymbol "work") else Nothing}]
    [arc source queue, arc queue work, arc work out]

bindings :: Bool -> InstanceConfig
bindings activity =
  defaultInstanceConfig {handlerImplementations = if activity then symbols [("work", ActivityBound workHandler)] else Map.empty}

instanceWith :: Bool -> Maybe HistoryStore -> IO Instance
instanceWith activity history = mkInstance (scopedNet activity) (bindings activity) {historyStore = history}

resumeOver :: Bool -> HistoryStore -> IO (Either InstanceError Instance)
resumeOver activity store = resume (scopedNet activity) store (bindings activity)

value :: Integer -> Token
value n = tokD "Value" (Int n)

answer :: Integer -> Json
answer n = obj [("answer", Int n)]

scoped :: LifecycleScope -> Maybe DeliveryScope
scoped = Just . ScopeGeneration

lifecycle :: Text -> Integer -> LifecycleScope
lifecycle n g = either (error . show) id (lifecycleScope n g)

-- | The first candidate begun (@runtime.begin(runtime.candidates()[0])@).
beginHead :: Instance -> Maybe Instant -> IO FiringOccurrence
beginHead inst at = do
  b : _ <- candidates inst
  begin inst b at >>= expectRight

-- | A scoped activity instance with one delivered, begun occurrence.
begunScoped :: Maybe HistoryStore -> IO (Instance, LifecycleScope, FiringOccurrence)
begunScoped history = do
  inst <- instanceWith True history
  scope <- openScope inst "draft" Nothing >>= expectRight
  _ <- deliverAt inst source [value 7] "draft-7" (scoped scope) Nothing
  o <- beginHead inst Nothing
  pure (inst, scope, o)

producedIn :: LifecycleScope -> [Record] -> [TokensProduced]
producedIn scope rs = [r | RTokensProduced r <- rs, r.scope == Just scope]

queueOf :: Queues -> NetPath -> TokenQueue
queueOf qs p = OMap.findWithDefault emptyQueue p (queuesByPlace qs)

spec :: Spec
spec = describe "Lifecycle scopes" $ do
  -- test_close_discards_duplicate_valued_entries_by_identity_and_replay_preserves_the_other_scope
  it "discards duplicate-valued entries by identity on close, and replay preserves the other scope" $ do
    history <- Store.inMemoryHistoryStore
    runtime <- instanceWith False (Just history)
    first <- openScope runtime "first" (Just 1) >>= expectRight
    second <- openScope runtime "second" (Just 1) >>= expectRight
    let same = tokD "Value" (obj [("same", Bool True)])
    _ <- deliverAt runtime source [same] "first-1" (scoped first) (Just 2)
    _ <- deliverAt runtime source [same] "second-1" (scoped second) (Just 2)
    _ <- deliverAt runtime source [same] "first-2" (scoped first) (Just 2)
    before' <- Store.records history >>= either (fail . show) pure . replayQueues
    let entries = zip (toList (queueIdentities (queueOf before' queue))) (toList (queueScopes (queueOf before' queue)))
        firstIds = [i | (Just i, s) <- entries, s == Just first]
        secondIds = [i | (Just i, s) <- entries, s == Just second]
    closure <- closeScope runtime first (Just 3) >>= expectRight
    closure.discarded `shouldBe` firstIds
    marking runtime >>= (`shouldBe` markingFromList [(queue, [same])])
    after' <- Store.records history >>= either (fail . show) pure . replayQueues
    toList (queueIdentities (queueOf after' queue)) `shouldBe` map Just secondIds
    toList (queueScopes (queueOf after' queue)) `shouldBe` [Just second]
    rs <- Store.records history
    [r.discarded | RScopeClosed r <- rs] `shouldBe` [firstIds]

  -- test_queue_identity_never_reuses_a_spent_occurrence_after_restart
  it "never reuses a spent queue identity after restart" $ do
    history <- Store.inMemoryHistoryStore
    (runtime, first, o) <- begunScoped (Just history)
    firstEntry : _ <- concatMap (.entries) . producedIn first <$> Store.records history
    _ <- closeScope runtime first Nothing >>= expectRight
    resumed <- resumeOver True history >>= expectRight
    second <- openScope resumed "draft" Nothing >>= expectRight
    _ <- deliverAt resumed source [value 8] "draft-8" (scoped second) Nothing
    secondProduced <- producedIn second <$> Store.records history
    let secondEntry = head' (last' secondProduced).entries
    held <- cancelled resumed
    o.occurrence `elem` map (.occurrence) held `shouldBe` True
    secondEntry > firstEntry `shouldBe` True

  -- test_scoped_identity_allocation_matches_live_and_replay_after_unscoped_movements
  it "allocates scoped identities identically live and after replay of unscoped movements" $ do
    liveHistory <- Store.inMemoryHistoryStore
    live <- instanceWith False (Just liveHistory)
    _ <- deliver live source [value 1] "unscoped"
    _ <- step live Nothing >>= expectRight
    scope <- openScope live "draft" Nothing >>= expectRight
    resumedHistory <- Store.records liveHistory >>= storeOf
    resumed <- resumeOver False resumedHistory >>= expectRight
    _ <- deliverAt live source [value 2] "live-scoped" (scoped scope) Nothing
    _ <- deliverAt resumed source [value 2] "resumed-scoped" (scoped scope) Nothing
    liveEntry <- (.entries) . last' . producedIn scope <$> Store.records liveHistory
    resumedEntry <- (.entries) . last' . producedIn scope <$> Store.records resumedHistory
    liveEntry `shouldBe` resumedEntry

  -- test_begin_records_exact_consumed_identity_and_scope_on_the_activity_outbox
  it "records the exact consumed identity and scope on the activity outbox at begin" $ do
    (_, scope, o) <- begunScoped Nothing
    let consumed' = [r | RTokensConsumed r <- o.records]
        requested = [r | RActivityRequested r <- o.records]
    map (length . (.entries)) (take 1 consumed') `shouldBe` [1]
    map (.scope) (take 1 consumed') `shouldBe` [Just scope]
    map (.scope) (take 1 requested) `shouldBe` [Just scope]
    o.scope `shouldBe` Just scope

  -- test_close_cancels_an_activity_without_restoring_its_consumed_input
  it "cancels an activity on close without restoring its consumed input" $ do
    (runtime, scope, o) <- begunScoped Nothing
    closure <- closeScope runtime scope Nothing >>= expectRight
    closure.cancelled `shouldBe` [o.occurrence]
    inFlight runtime >>= (`shouldBe` [])
    markingNull <$> marking runtime >>= (`shouldBe` True)
    cancelled runtime >>= (`shouldBe` [o])

  -- test_completion_before_close_at_the_same_instant_is_accepted_then_its_output_is_cleaned
  it "accepts a completion before a same-instant close, then cleans its output" $ do
    runtime <- instanceWith True Nothing
    scope <- openScope runtime "draft" (Just 1) >>= expectRight
    _ <- deliverAt runtime source [value 7] "draft-7" (scoped scope) (Just 2)
    o <- beginHead runtime (Just 3)
    recordActivityCompletion runtime o (answer 8) (Just 20) >>= expectRight >>= (`shouldBe` TerminalAccepted)
    _ <- complete runtime o Nothing (Just 20) >>= expectRight
    _ <- closeScope runtime scope (Just 20) >>= expectRight
    markingNull <$> marking runtime >>= (`shouldBe` True)
    rs <- historyRecords runtime
    [() | RActivityTerminalQuarantined _ <- rs] `shouldBe` []
    [r.scope | RTokensProduced r <- rs, r.place == out] `shouldBe` [Just scope]

  -- test_close_before_completion_at_the_same_instant_quarantines_exact_redelivery_and_refuses_conflict
  it "quarantines a completion after a same-instant close, acknowledges redelivery, refuses conflict" $ do
    runtime <- instanceWith True Nothing
    scope <- openScope runtime "draft" (Just 1) >>= expectRight
    _ <- deliverAt runtime source [value 7] "draft-7" (scoped scope) (Just 2)
    o <- beginHead runtime (Just 3)
    _ <- closeScope runtime scope (Just 20) >>= expectRight
    recordActivityCompletion runtime o (answer 8) (Just 20) >>= expectRight >>= (`shouldBe` TerminalQuarantined)
    size <- Store.size (instanceHistory runtime)
    recordActivityCompletion runtime o (answer 8) (Just 20) >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    Store.size (instanceHistory runtime) >>= (`shouldBe` size)
    conflict <- recordActivityCompletion runtime o (answer 9) (Just 20)
    conflict `refusedWith` "conflicting terminal activity report"
    markingNull <$> marking runtime >>= (`shouldBe` True)

  -- test_reset_is_one_record_that_closes_cleanup_and_opens_the_next_generation
  it "resets in one record that closes, cleans up, and opens the next generation" $ do
    runtime <- instanceWith True Nothing
    first <- openScope runtime "draft" (Just 1) >>= expectRight
    _ <- deliverAt runtime source [value 7] "draft-7" (scoped first) (Just 2)
    o <- beginHead runtime (Just 3)
    size <- Store.size (instanceHistory runtime)
    second <- resetScope runtime first (Just 4) >>= expectRight
    second `shouldBe` lifecycle "draft" 2
    rs <- historyRecords runtime
    length rs `shouldBe` size + 1
    case drop size rs of
      [RScopeReset r] -> do
        r.closed `shouldBe` first
        r.opened `shouldBe` second
        r.cancelled `shouldBe` [o.occurrence]
      other -> expectationFailure ("expected one ScopeReset, got " <> show other)
    activeScopes runtime >>= (`shouldBe` Map.fromList [("draft", second)])

  -- test_scope_append_failure_leaves_live_state_unchanged
  it "leaves live state unchanged when the scope append fails" $ do
    refusing <- newIORef False
    history <-
      mirroredHistoryStore BackendOwned Seq.empty $ \_ batch -> do
        refuse <- readIORef refusing
        when (refuse && or [True | RScopeClosed _ <- batch]) $ throwIO (userError "refused close")
        pure (map (const Entered) batch)
    (runtime, scope, o) <- begunScoped (Just history)
    writeIORef refusing True
    closeScope runtime scope Nothing `shouldThrow` (\e -> ioeGetErrorString e == "refused close")
    activeScopes runtime >>= (`shouldBe` Map.fromList [("draft", scope)])
    inFlight runtime >>= (`shouldBe` [o])

  -- test_closed_and_uncertain_scoped_delivery_are_canonical_idempotent_dispositions
  it "dispositions closed and uncertain scoped deliveries canonically and idempotently" $ do
    runtime <- instanceWith False Nothing
    scope <- openScope runtime "draft" Nothing >>= expectRight
    _ <- closeScope runtime scope Nothing >>= expectRight
    seal runtime source Nothing >>= expectRight
    let same = value 7
    dropped <- acceptDelivery runtime source [same] "closed" (scoped scope) Nothing >>= expectRight
    quarantined <- acceptDelivery runtime source [same] "uncertain" (Just (ScopeName "draft")) Nothing >>= expectRight
    dropped `shouldBe` DeliveryScoped (ScopedDeliveryAcknowledgement "closed" Dropped (QuarantineGeneration scope))
    quarantined `shouldBe` DeliveryScoped (ScopedDeliveryAcknowledgement "uncertain" Quarantined (QuarantineName "draft"))
    size <- Store.size (instanceHistory runtime)
    acceptDelivery runtime source [same] "closed" (scoped scope) Nothing >>= expectRight >>= (`shouldBe` dropped)
    acceptDelivery runtime source [same] "uncertain" (Just (ScopeName "draft")) Nothing >>= expectRight >>= (`shouldBe` quarantined)
    Store.size (instanceHistory runtime) >>= (`shouldBe` size)
    conflict <- acceptDelivery runtime source [value 8] "uncertain" (Just (ScopeName "draft")) Nothing
    conflict
      `refusedWith` "delivery identity conflict for 'uncertain': recorded source NetPath('source'), scope 'draft'; attempted source NetPath('source'), scope 'draft'; canonical token content differs"
    rs <- historyRecords runtime
    length [() | RScopedDeliveryDropped _ <- rs] `shouldBe` 1
    length [() | RScopedDeliveryQuarantined _ <- rs] `shouldBe` 1

  -- test_exact_future_generation_is_quarantined_without_losing_its_target_identity
  it "quarantines an exact future generation without losing its target identity" $ do
    runtime <- instanceWith False Nothing
    current <- openScope runtime "draft" Nothing >>= expectRight
    let future = lifecycle "draft" (scopeGeneration current + 1)
    acknowledgement <- acceptDelivery runtime source [value 7] "future" (scoped future) Nothing >>= expectRight
    acknowledgement `shouldBe` DeliveryScoped (ScopedDeliveryAcknowledgement "future" Quarantined (QuarantineGeneration future))
    rs <- historyRecords runtime
    take 1 [r.scope | RScopedDeliveryQuarantined r <- rs] `shouldBe` [QuarantineGeneration future]

  -- test_scope_projection_and_quarantine_rebuild_deterministically_on_resume
  it "rebuilds the scope projection and quarantine deterministically on resume" $ do
    history <- Store.inMemoryHistoryStore
    (runtime, first, o) <- begunScoped (Just history)
    second <- resetScope runtime first Nothing >>= expectRight
    _ <- recordActivityCompletion runtime o (answer 8) Nothing >>= expectRight
    resumed <- resumeOver True history >>= expectRight
    activeScopes resumed >>= (`shouldBe` Map.fromList [("draft", second)])
    held <- cancelled resumed
    take 1 (map (.occurrence) held) `shouldBe` [o.occurrence]
    recordActivityCompletion resumed o (answer 8) Nothing >>= expectRight >>= (`shouldBe` TerminalAcknowledged)
    conflict <- recordActivityCompletion resumed o (answer 9) Nothing
    conflict `refusedWith` "conflicting terminal activity report"

  -- test_replay_refuses_a_scope_close_that_omits_queued_cleanup
  it "refuses at replay a scope close that omits queued cleanup" $ do
    history <- Store.inMemoryHistoryStore
    runtime <- instanceWith False (Just history)
    scope <- openScope runtime "draft" Nothing >>= expectRight
    _ <- deliverAt runtime source [value 7] "draft-7" (scoped scope) Nothing
    malformed <- (++ [RScopeClosed (ScopeClosed scope [] [] 0)]) <$> Store.records history
    (() <$ replayQueues malformed)
      `shouldFailWith` "replay divergence: lifecycle close left queue entries (1,) in scope LifecycleScope(name='draft', generation=1)"

  -- test_replay_refuses_a_scope_close_that_omits_an_in_flight_occurrence
  it "refuses at resume a scope close that omits an in-flight occurrence" $ do
    history <- Store.inMemoryHistoryStore
    (_, scope, _) <- begunScoped (Just history)
    malformed <- Store.records history >>= storeOf . (++ [RScopeClosed (ScopeClosed scope [] [] 0)])
    result <- resumeOver True malformed
    result
      `refusedWith` "replay divergence: lifecycle close for LifecycleScope(name='draft', generation=1) cancels (), but the exact open occurrence set at this append position is (2,)"

  -- test_replay_refuses_a_scope_close_that_reclassifies_an_already_ended_occurrence
  it "refuses at resume a scope close that reclassifies an already ended occurrence" $ do
    history <- Store.inMemoryHistoryStore
    (runtime, scope, o) <- begunScoped (Just history)
    _ <- recordActivityCompletion runtime o (answer 8) Nothing >>= expectRight
    _ <- complete runtime o Nothing Nothing >>= expectRight
    queues <- Store.records history >>= either (fail . show) pure . replayQueues
    let discarded =
          [ i
          | q <- OMap.elems (queuesByPlace queues)
          , (Just i, Just provenance) <- zip (toList (queueIdentities q)) (toList (queueScopes q))
          , provenance == scope
          ]
    malformed <- Store.records history >>= storeOf . (++ [RScopeClosed (ScopeClosed scope discarded [o.occurrence] 0)])
    result <- resumeOver True malformed
    result
      `refusedWith` "replay divergence: lifecycle close for LifecycleScope(name='draft', generation=1) cancels (2,), but the exact open occurrence set at this append position is ()"

  -- test_replay_refuses_a_scope_close_that_reclassifies_an_accepted_terminal_awaiting_projection
  it "refuses at resume a scope close that cancels an accepted terminal awaiting projection" $ do
    history <- Store.inMemoryHistoryStore
    (runtime, scope, o) <- begunScoped (Just history)
    _ <- recordActivityCompletion runtime o (answer 8) Nothing >>= expectRight
    malformed <- Store.records history >>= storeOf . (++ [RScopeClosed (ScopeClosed scope [] [o.occurrence] 0)])
    result <- resumeOver True malformed
    result
      `refusedWith` "replay divergence: lifecycle close for LifecycleScope(name='draft', generation=1) cancels accepted Activity terminal(s) (2,) still awaiting deterministic projection"

  -- test_replay_refuses_a_normal_terminal_boundary_after_lifecycle_cancellation
  it "refuses at resume a normal terminal boundary after lifecycle cancellation" $ do
    history <- Store.inMemoryHistoryStore
    (runtime, scope, o) <- begunScoped (Just history)
    _ <- closeScope runtime scope Nothing >>= expectRight
    malformed <- Store.records history >>= storeOf . (++ [RFiringFailed (FiringFailed work "late" o.occurrence 0)])
    result <- resumeOver True malformed
    result `refusedWith` "replay divergence: firing occurrence 2 reached FiringFailed after lifecycle cancellation"

  -- test_replay_refuses_inconsistent_same_occurrence_scope_provenance
  it "refuses at resume inconsistent same-occurrence scope provenance" $ do
    history <- Store.inMemoryHistoryStore
    runtime <- instanceWith True (Just history)
    first <- openScope runtime "first" Nothing >>= expectRight
    second <- openScope runtime "second" Nothing >>= expectRight
    _ <- deliverAt runtime source [value 7] "first-7" (scoped first) Nothing
    _ <- beginHead runtime Nothing
    -- The reference's @dataclasses.replace(record, scope=second)@: the
    -- ActivityRequested record rebuilt positionally with the other scope.
    let rescope = \case
          RActivityRequested r ->
            RActivityRequested
              (ActivityRequested r.transition r.activity r.input r.policy r.correlation r.idempotency r.occurrence (Just second) r.instant)
          record -> record
    malformed <- Store.records history >>= storeOf . map rescope
    result <- resumeOver True malformed
    result
      `refusedWith` "replay divergence: firing occurrence 2 (work) has scope provenance inconsistent with FiringBegun on ('ActivityRequested',)"
  where
    head' = \case
      x : _ -> x
      [] -> error "empty entries"
    last' xs = case reverse xs of
      x : _ -> x
      [] -> error "no scoped production"
