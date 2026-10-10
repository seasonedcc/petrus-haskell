-- | Port of @tests/petrus/agenticus/hands/test_contract_and_gateway.py@.
module Petrus.Agenticus.HandsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, poll, wait, waitCatch)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (UserInterrupt), fromException, throwIO)
import Control.Monad (forM_, when)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract
import Petrus.Agenticus.Hands.Fixtures
import Petrus.Agenticus.Hands.Gateway
import Petrus.Agenticus.Hands.Gateway qualified as G
import Petrus.Agenticus.Hands.Grants
import Petrus.Agenticus.Support (expectRight, setMember, shouldRaise, shouldRaiseIO, shouldRaiseMatchingIO)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Hspec

rejectionOf :: Json -> Maybe ToolRequestRejected
rejectionOf = either Just (const Nothing) . parseToolRequest

categoryOf :: Json -> Maybe RejectionCategory
categoryOf = fmap (.category) . rejectionOf

errorCategory :: ToolResult -> Maybe RejectionCategory
errorCategory r = (.category) <$> r.resultError

-- | The upstream @gateway(capabilities, clock=...)@ helper.
gatewayFor :: [ToolMethod] -> IO (HandsGateway, Fake, Fence)
gatewayFor caps = do
  fake <- newFake False "safe" "match"
  fence <- newFence
  ledger <- newGrantLedger "attachment-1" 1
  _ <- openGrant ledger (grantSpec caps 50 20) {specWritablePaths = ["out.txt"], specAllowedArgv = [["printf", "ok"]]}
  gw <- gatewayOver (fakeAdapter fake) ledger fence id
  pure (gw, fake, fence)

-- | A gateway over the adapter and ledger with @clock=lambda: 1@.
gatewayOver :: HandsAdapter -> GrantLedger -> Fence -> (GatewayConfig -> GatewayConfig) -> IO HandsGateway
gatewayOver adapter' ledger fence tweak = do
  barrier' <- newBarrier
  newHandsGateway (tweak (gatewayConfig "episode-1" adapter' ledger (fenceSource fence) barrier') {clock = pure 1})

-- | A two-party rendezvous standing in for @threading.Barrier(2)@.
rendezvous :: IO (IO (), IO ())
rendezvous = do
  a <- newEmptyMVar
  b <- newEmptyMVar
  pure (putMVar a () >> takeMVar b, takeMVar a >> putMVar b ())

spec :: Spec
spec = describe "hands/test_contract_and_gateway.py" $ do
  let closed =
        [ ("workspace_read", [("path", String "README.md")])
        , ("workspace_search", [("query", String "needle"), ("path", String ".hidden")])
        , ("workspace_shell", [("argv", Array [String "printf", String "ok"]), ("cwd", String ".")])
        , ("workspace_write", [("path", String "out.txt"), ("content", String "safe")])
        , ("workspace_test", [])
        ]
  forM_ closed $ \(m, ps) ->
    it ("test_closed_v1_requests_are_exact_strict_and_json_safe[" <> T.unpack m <> "]") $ do
      parsed <- either (fail . show) pure (parseToolRequest (request m ps))
      toolMethodText parsed.method `shouldBe` m
      J.dumps J.defaultDumps {J.allowNan = False} (request m ps) `shouldSatisfy` either (const False) (const True)
      categoryOf (requestWith m ps [("extra", Bool True)]) `shouldBe` Just CategorySchema

  it "test_capability_scoped_hands_descriptor_is_host_registerable_and_exact" $ do
    capabilityScopedHands.identity.kind `shouldBe` KindHands
    capabilityScopedHands.identity.contractVersion `shouldBe` 1
    capabilityScopedHands.offers
      `shouldBe` Set.fromList
        [ "hands.capability-scoped"
        , "workspace.read"
        , "workspace.search"
        , "workspace.shell"
        , "workspace.write"
        , "workspace.test"
        ]

  forM_ ["/absolute", "../escape", "a/../b", "a//b", "a\\b", "nul\0x"] $ \p ->
    it ("test_paths_fail_closed_before_policy[" <> show (p :: Text) <> "]") $
      categoryOf (request "workspace_read" [("path", String p)]) `shouldBe` Just CategoryPath

  it "test_unknown_malformed_and_bounds_are_safe" $ do
    categoryOf (request "future_tool" []) `shouldBe` Just CategoryUnknown
    rejectionOf (request "workspace_shell" [("argv", Array (replicate (maxArgvParts + 1) (String "x"))), ("cwd", String ".")])
      `shouldSatisfy` (/= Nothing)
    rejectionOf (request "workspace_write" [("path", String "x"), ("content", String (T.replicate (maxContentChars + 1) "x"))])
      `shouldSatisfy` (/= Nothing)
    let canary = "SECRET-CANARY"
    case rejectionOf (Object [("call_id", String canary)]) of
      Just r -> do
        T.pack (show r) `shouldNotSatisfy` T.isInfixOf canary
        T.pack (show (rejectedError r)) `shouldNotSatisfy` T.isInfixOf canary
      Nothing -> expectationFailure "malformed envelope must be rejected"

  it "test_workspace_write_accepts_exact_1024_character_boundary" $ do
    maxContentChars `shouldBe` 1024
    case parseToolRequest (request "workspace_write" [("path", String "x"), ("content", String (T.replicate 1024 "x"))]) of
      Right parsed | ParamsWrite p <- parsed.params -> p.content `shouldBe` T.replicate 1024 "x"
      other -> expectationFailure (show other)
    categoryOf (request "workspace_write" [("path", String "x"), ("content", String (T.replicate 1025 "x"))])
      `shouldBe` Just CategoryWrite
    categoryOf (request "workspace_write" [("path", String "x"), ("content", String "x\0y")])
      `shouldBe` Just CategorySchema

  it "test_grants_are_exact_finite_monotonic_and_budgeted" $ do
    ledger <- newGrantLedger "attachment-1" 1
    first <- openGrant ledger (grantSpec [WorkspaceRead] 10 1)
    consumeGrant ledger first.grantEpoch `shouldReturn` first
    consumeGrant ledger first.grantEpoch `shouldRaiseIO` GrantLedgerError
    second <- openGrant ledger (grantSpec [WorkspaceShell] 11 2) {specAllowedArgv = [["printf", "ok"]]}
    second.grantEpoch `shouldBe` first.grantEpoch + 1
    consumeGrant ledger first.grantEpoch `shouldRaiseIO` GrantLedgerError
    current <- currentGrant ledger
    openGrant ledger (grantSpec [] (1 / 0) 1) `shouldRaiseIO` ValueError
    currentGrant ledger `shouldReturn` current
    third <- openGrant ledger (grantSpec [] 12 1)
    third.grantEpoch `shouldBe` second.grantEpoch + 1

  it "test_write_roots_are_bounded_and_denied_roots_take_precedence" $ do
    fake <- newFake False "safe" "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <-
      openGrant
        ledger
        (grantSpec [WorkspaceWrite] 50 3) {specWritableRoots = ["."], specDeniedWritableRoots = [".git", ".petrus-hands-stage"]}
    hands <- gatewayOver (fakeAdapter fake) ledger fence id
    accepted <- submit hands (request "workspace_write" [("path", String "src/new.txt"), ("content", String "safe")])
    git <- submit hands (requestWith "workspace_write" [("path", String ".git/config"), ("content", String "unsafe")] [("call_id", String "call-2")])
    stage <-
      submit
        hands
        (requestWith "workspace_write" [("path", String ".petrus-hands-stage/foreign"), ("content", String "unsafe")] [("call_id", String "call-3")])
    accepted.ok `shouldBe` True
    Map.lookup "src/new.txt" <$> targetOf fake `shouldReturn` Just "safe"
    errorCategory git `shouldBe` Just CategoryPath
    errorCategory stage `shouldBe` Just CategoryPath
    callsOf fake `shouldReturn` ["stage", "commit"]
    outcome <- tryOpenGrant ledger (grantSpec [WorkspaceWrite] 50 1) {specWritableRoots = ["../foreign"]}
    outcome `shouldRaise` ValueError
    either (T.isInfixOf "normalized relative path" . errorMessage) (const False) outcome `shouldBe` True

  it "test_write_root_matching_uses_segments_and_denial_overrides_exact_path" $ do
    let grantWith denied = expectRight (mkCapabilityGrant "attachment-1" 1 1 [WorkspaceWrite] [".git/config"] [] 50 3 ["src"] denied)
        grant = grantWith [".git"]
        denyAll = grantWith ["."]
    permitsWritePath grant "src/new.txt" `shouldBe` True
    permitsWritePath grant "src2/new.txt" `shouldBe` False
    permitsWritePath grant ".git/config" `shouldBe` False
    permitsWritePath denyAll "src/new.txt" `shouldBe` False

  it "test_all_direct_rejections_are_pre_crossing_and_flat" $ do
    (hands, fake, fence) <- gatewayFor [WorkspaceRead]
    let early =
          [ request "future" []
          , request "workspace_write" [("path", String "out.txt"), ("content", String "x")]
          , request "workspace_shell" [("argv", Array [String "printf", String "ok"]), ("cwd", String ".")]
          , requestWith "workspace_read" [("path", String "README.md")] [("attachment_epoch", Int 2)]
          ]
    modifyFence fence (\f -> callFence False f.aborted f.deadline)
    let cases = early <> [request "workspace_read" [("path", String "README.md")]]
    forM_ (zip [0 :: Int ..] cases) $ \(index, item) -> do
      result <- submit hands (setMember "call_id" (String ("reject-" <> T.pack (show index))) item)
      result.ok `shouldBe` False
    c <- counters hands
    (c.adapterEntries, c.stages, c.commits, c.targetMutations) `shouldBe` (0, 0, 0, 0)
    callsOf fake `shouldReturn` []

  it "test_foreign_episode_is_rejected_before_adapter_crossing" $ do
    (hands, fake, _) <- gatewayFor [WorkspaceRead]
    result <- submit hands (requestWith "workspace_read" [("path", String "README.md")] [("episode_id", String "episode-foreign")])
    errorCategory result `shouldBe` Just CategoryStaleEpoch
    callsOf fake `shouldReturn` []
    ((.adapterEntries) <$> counters hands) `shouldReturn` 0

  it "test_staged_write_commits_once_and_post_fence_discards" $ do
    (hands, fake, fence) <- gatewayFor [WorkspaceWrite]
    good <- submit hands (request "workspace_write" [("path", String "out.txt"), ("content", String "new")])
    good.ok `shouldBe` True
    callsOf fake `shouldReturn` ["stage", "commit"]
    targetOf fake `shouldReturn` Map.fromList [("out.txt", "new")]
    ((.targetMutations) <$> counters hands) `shouldReturn` 1

    closing <- newFake False "safe" "match"
    writeIORef closing.closeOnStage (Just fence)
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceWrite] 50 1) {specWritablePaths = ["out.txt"]}
    rejectedGateway <- gatewayOver (fakeAdapter closing) ledger fence id
    setFence fence (callFence True False 100)
    rejected' <- submit rejectedGateway (request "workspace_write" [("path", String "out.txt"), ("content", String "canary")])
    errorCategory rejected' `shouldBe` Just CategoryPostFence
    callsOf closing `shouldReturn` ["stage", "discard"]
    Map.member "out.txt" <$> targetOf closing `shouldReturn` False

  it "test_provider_exception_is_sanitized_and_evidence_is_bounded" $ do
    fake <- newFake False "safe" "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 20)
    let explode = (fakeAdapter fake) {read = \_ -> throwIO (userError "SECRET-CANARY")}
    hands <- gatewayOver explode ledger fence id
    result <- submit hands (request "workspace_read" [("path", String "README.md")])
    ev <- evidence hands
    let rendered = T.pack (show (toolResultToData result) <> show ev)
    errorCategory result `shouldBe` Just CategoryProvider
    rendered `shouldNotSatisfy` T.isInfixOf "SECRET-CANARY"

  it "test_model_projection_preserves_semantics_without_attachment_custody" $ do
    (hands, _, _) <- gatewayFor [WorkspaceRead]
    result <- submit hands (request "workspace_read" [("path", String "README.md")])
    toolResultToModelData result
      `shouldBe` Object [("version", Int 1), ("ok", Bool True), ("data", Object [("content", String "safe")]), ("error", Null)]
    let full = toolResultToData result
    J.lookupMember "call_id" full `shouldBe` Just (String "call-1")
    J.lookupMember "attachment_id" full `shouldBe` Just (String "attachment-1")
    J.lookupMember "epoch" full `shouldBe` Just (Int 1)

  it "test_exact_retransmission_is_terminal_and_conflict_fails_loud" $ do
    (hands, fake, fence) <- gatewayFor [WorkspaceRead]
    let payload = request "workspace_read" [("path", String "README.md")]
    first <- submit hands payload
    setFence fence (callFence False True 0)
    second <- submit hands payload
    second `shouldBe` first
    callsOf fake `shouldReturn` ["read"]
    length <$> evidence hands `shouldReturn` 1
    shouldRaiseMatchingIO (submit hands (request "workspace_read" [("path", String "other")])) ToolCallConflict "immutable request"
    toolCallConflict.errorMessage `shouldSatisfy` T.isInfixOf "immutable request"
    T.pack (show toolCallConflict) `shouldNotSatisfy` T.isInfixOf "other"

  it "test_concurrent_exact_duplicates_single_flight" $ do
    fake <- newFake False "safe" "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 20)
    (enterA, enterB) <- rendezvous
    (releaseA, releaseB) <- rendezvous
    let delayed = (fakeAdapter fake) {read = \_ -> modifyIORef' fake.callLog (<> ["read"]) >> enterA >> releaseA >> pure "safe"}
    hands <- gatewayOver delayed ledger fence id
    let payload = request "workspace_read" [("path", String "README.md")]
    first <- async (submit hands payload)
    enterB
    second <- async (submit hands payload)
    threadDelay 20000
    releaseB
    r1 <- wait first
    r2 <- wait second
    r1 `shouldBe` r2
    callsOf fake `shouldReturn` ["read"]
    length <$> evidence hands `shouldReturn` 1

  it "test_call_ledger_and_grant_exhaustion_are_budget_not_stale" $ do
    fake <- newFake False "safe" "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 1)
    hands <- gatewayOver (fakeAdapter fake) ledger fence (\c -> c {maxGatewayCalls = 2})
    one <- submit hands (requestWith "workspace_read" [("path", String "one")] [("call_id", String "one")])
    one.ok `shouldBe` True
    exhausted <- submit hands (requestWith "workspace_read" [("path", String "two")] [("call_id", String "two")])
    full <- submit hands (requestWith "workspace_read" [("path", String "three")] [("call_id", String "three")])
    errorCategory exhausted `shouldBe` Just CategoryBudget
    errorCategory full `shouldBe` Just CategoryBudget

  it "test_malformed_adapter_result_is_a_typed_provider_error" $ do
    fake <- newFake False (T.replicate 5000 "x") "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 20)
    hands <- gatewayOver (fakeAdapter fake) ledger fence id
    result <- submit hands (request "workspace_read" [("path", String "README.md")])
    errorCategory result `shouldBe` Just CategoryProvider
    length <$> evidence hands `shouldReturn` 1

  it "test_abandoned_primary_allows_an_exact_waiter_to_reclaim_without_key_error" $ do
    fake <- newFake False "safe" "match"
    fence <- newFence
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 20)
    (enterA, enterB) <- rendezvous
    (releaseA, releaseB) <- rendezvous
    attempts <- newIORef (0 :: Int)
    let interrupted =
          (fakeAdapter fake)
            { read = \_ -> do
                n <- atomicModifyIORef' attempts (\a -> (a + 1, a + 1))
                when (n == 1) $ do
                  enterA
                  releaseA
                  throwIO UserInterrupt
                pure "safe"
            }
    hands <- gatewayOver interrupted ledger fence id
    let payload = request "workspace_read" [("path", String "README.md")]
    primary <- async (submit hands payload)
    enterB
    duplicate <- async (submit hands payload)
    threadDelay 20000
    releaseB
    waitCatch primary >>= \case
      Left e -> fromException e `shouldBe` Just UserInterrupt
      Right r -> expectationFailure ("primary must be interrupted, got " <> show r)
    ((.ok) <$> wait duplicate) `shouldReturn` True
    readIORef attempts `shouldReturn` 2
    length <$> evidence hands `shouldReturn` 1

  it "test_authority_target_deadline_abort_and_grant_postchecks_fail_closed" $ do
    do
      fake <- newFake False "safe" "match"
      fence <- newFence
      ledger <- newGrantLedger "attachment-1" 1
      _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 1)
      authority <- gatewayOver (fakeAdapter fake) ledger fence (\c -> c {G.admission = Just (ResultAdmission (\_ -> pure False))})
      denied <- submit authority (request "workspace_read" [("path", String "README.md")])
      errorCategory denied `shouldBe` Just CategoryAuthority

    do
      fake <- newFake False "safe" "match"
      fence <- newFence
      ledger <- newGrantLedger "attachment-1" 1
      _ <- openGrant ledger (grantSpec [WorkspaceWrite] 50 1) {specWritablePaths = ["out.txt"]}
      staleTarget <- gatewayOver (fakeAdapter fake) ledger fence (\c -> c {G.target = Just (TargetCurrency (pure False))})
      denied <- submit staleTarget (request "workspace_write" [("path", String "out.txt"), ("content", String "safe")])
      errorCategory denied `shouldBe` Just CategoryPostFence
      callsOf fake `shouldReturn` ["stage", "discard"]
      Map.member "out.txt" <$> targetOf fake `shouldReturn` False

    forM_ [(CategoryDeadline, callFence True False 0), (CategoryAborted, callFence True True 100)] $ \(category', update) -> do
      fake <- newFake False "safe" "match"
      fence <- newFence
      ledger <- newGrantLedger "attachment-1" 1
      _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 1)
      let changeFence = (fakeAdapter fake) {read = \_ -> setFence fence update >> pure "safe"}
      checked <- gatewayOver changeFence ledger fence id
      denied <- submit checked (request "workspace_read" [("path", String "README.md")])
      errorCategory denied `shouldBe` Just category'

    do
      fake <- newFake False "safe" "match"
      fence <- newFence
      ledger <- newGrantLedger "attachment-1" 1
      let spec' = (grantSpec [WorkspaceWrite] 50 1) {specWritablePaths = ["out.txt"]}
      _ <- openGrant ledger spec'
      let base = fakeAdapter fake
          replaceGrant = base {stageWrite = \c p t -> base.stageWrite c p t <* openGrant ledger spec'}
      checked <- gatewayOver replaceGrant ledger fence id
      denied <- submit checked (request "workspace_write" [("path", String "out.txt"), ("content", String "safe")])
      errorCategory denied `shouldBe` Just CategoryStaleEpoch
      callsOf fake `shouldReturn` ["stage", "discard"]
      Map.member "out.txt" <$> targetOf fake `shouldReturn` False

  -- Upstream pins the claim/consume window by delaying @ledger.consume@; the
  -- Haskell ledger is not monkeypatchable, so the same window (claimed, not
  -- yet at the adapter) is pinned in the precheck's fence snapshot, which
  -- runs after the claim and before the grant is consumed.
  it "test_claimed_call_is_drained_before_attachment_cleanup_can_start" $ do
    fake <- newFake False "safe" "match"
    ledger <- newGrantLedger "attachment-1" 1
    _ <- openGrant ledger (grantSpec [WorkspaceRead] 50 20)
    entered <- newEmptyMVar
    release <- newEmptyMVar
    snapshots <- newIORef (0 :: Int)
    let delayedFence = CallFenceSource $ do
          n <- atomicModifyIORef' snapshots (\a -> (a + 1, a + 1))
          when (n == 1) $ putMVar entered () >> takeMVar release
          pure (callFence True False 100)
    barrier' <- newBarrier
    hands <- newHandsGateway (gatewayConfig "episode-1" (fakeAdapter fake) ledger delayedFence barrier') {clock = pure 1}
    let payload = request "workspace_read" [("path", String "README.md")]
    submitted <- async (submit hands payload)
    takeMVar entered
    drained <- async (drain hands 2)
    threadDelay 50000
    poll drained >>= (`shouldSatisfy` null)
    putMVar release ()
    ((.ok) <$> wait submitted) `shouldReturn` True
    wait drained `shouldReturn` True
    callsOf fake `shouldReturn` ["read"]
