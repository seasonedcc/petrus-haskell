-- | Port of @tests/petrus/agenticus/hands/test_conformance.py@.
module Petrus.Agenticus.Hands.ConformanceSpec (spec) where

import Control.Monad (forM, forM_, when)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Conformance
import Petrus.Agenticus.Hands.Contract
import Petrus.Agenticus.Hands.Fixtures
import Petrus.Agenticus.Hands.Gateway
import Petrus.Agenticus.Hands.Grants
import Petrus.Agenticus.Support (expectRight, shouldRaiseMatchingIO)
import Petrus.Json (Json (..))
import Test.Hspec

conformanceRequest :: Text -> Text -> Text -> Integer -> Integer -> Text -> [(Text, Json)] -> Json
conformanceRequest suffix episode attachment epoch grantEpoch' method' params' =
  Object
    [ ("version", Int 1)
    , ("call_id", String (suffix <> ":" <> method'))
    , ("episode_id", String episode)
    , ("attachment_id", String attachment)
    , ("attachment_epoch", Int epoch)
    , ("grant_epoch", Int grantEpoch')
    , ("method", String method')
    , ("params", Object params')
    ]

blockedWrite :: Text -> Integer -> ToolResult
blockedWrite attachment epoch =
  expectRight $
    mkToolResult ("blocked-" <> attachment) attachment epoch False Nothing (Just (expectRight (mkToolError CategoryWrite "no current write grant")))

gatewayWith :: Fake -> Text -> GrantLedger -> Fence -> Double -> IO HandsGateway
gatewayWith fake episode ledger fence now = do
  barrier' <- newBarrier
  newHandsGateway (gatewayConfig episode (fakeAdapter fake) ledger (fenceSource fence) barrier') {clock = pure now}

intOrNull :: Maybe Int -> Json
intOrNull = maybe Null (Int . fromIntegral)

runEpisode :: Text -> Integer -> Fake -> IO (Json, GatewayCounters)
runEpisode suffix epoch fake = do
  let attachment = "attachment-" <> suffix
      episode = "episode-" <> suffix
      marker = "ES049_APP_" <> T.toUpper suffix <> "_OK"
  ledger <- newGrantLedger attachment epoch
  initial <-
    openGrant
      ledger
      (grantSpec [WorkspaceRead, WorkspaceSearch, WorkspaceShell, WorkspaceTest] 90 5) {specAllowedArgv = [["/bin/cat", "message.txt"]]}
  fence <- newFence
  gw <- gatewayWith fake episode ledger fence 1
  policy <- newSevenStepEpisodePolicy (policyConfig attachment epoch marker)
  successful <- newIORef (Map.empty :: Map.Map ToolMethod Int)
  _ <- beginTurn policy
  _ <- appendObservation policy
  observe policy WorkspaceWrite (blockedWrite attachment epoch)
  let steps =
        [ (WorkspaceRead, [("path", String "message.txt")])
        , (WorkspaceSearch, [("query", String "message"), ("path", String "message.txt")])
        , (WorkspaceShell, [("argv", Array [String "/bin/cat", String "message.txt"]), ("cwd", String ".")])
        , (WorkspaceWrite, [("path", String "message.txt"), ("content", String suffix)])
        , (WorkspaceTest, [])
        ]
  grantRef <- newIORef initial
  forM_ steps $ \(m, ps) -> do
    _ <- beginTurn policy
    _ <- appendObservation policy
    turn <- policyTurns policy
    grant <- readIORef grantRef
    result <-
      submit gw (conformanceRequest (suffix <> "-" <> T.pack (show turn)) episode attachment epoch grant.grantEpoch (toolMethodText m) ps)
    result.ok `shouldBe` True
    modifyIORef' successful (Map.insertWith (+) m 1)
    observe policy m result
    when (turn == 3) $ do
      writeGrantReady policy `shouldReturn` True
      noteGrantOpened policy
      next <-
        openGrant
          ledger
          (grantSpec allToolMethods 90 3) {specWritablePaths = ["message.txt"], specAllowedArgv = [["/bin/cat", "message.txt"]]}
      writeIORef grantRef next
  _ <- beginTurn policy
  _ <- appendObservation policy
  decision <- admitMarker policy marker
  decision.admitted `shouldBe` True
  turns <- policyTurns policy
  appends <- policyAppends policy
  blocked <- policyBlockedWriteTurn policy
  opened <- policyGrantOpenedTurn policy
  finalizedTurns <- forM allToolMethods $ \m -> (,) (toolMethodText m) . intOrNull <$> policyFinalizedTurn policy m
  succeeded <- readIORef successful
  premature <- policyPrematureMarkers policy
  c <- counters gw
  pure
    ( Object
        [ ("invocations", Int (fromIntegral turns))
        , ("appends", Int (fromIntegral appends))
        , ("blocked_write_turn", intOrNull blocked)
        , ("grant_opened_turn", intOrNull opened)
        , ("finalized_turns", Object finalizedTurns)
        , ("successful_tools", Object [(toolMethodText m, Int (fromIntegral (Map.findWithDefault 0 m succeeded))) | m <- allToolMethods])
        , ("marker_outcome", String decision.outcome)
        , ("premature_markers", Int (fromIntegral premature))
        ]
    , c
    )

sumCounters :: [GatewayCounters] -> Json
sumCounters cs =
  Object
    [ ("requests", total (.requests))
    , ("adapter_entries", total (.adapterEntries))
    , ("stages", total (.stages))
    , ("commits", total (.commits))
    , ("stage_discards", total (.stageDiscards))
    , ("mutations", total (.targetMutations))
    , ("rejections", Object [(rejectionCategoryText k, Int (fromIntegral v)) | (k, v) <- Map.toList (Map.unionsWith (+) (map (.rejections) cs))])
    ]
  where
    total f = Int (fromIntegral (sum (map f cs)))

data Probe = Probe
  { probeCapabilities :: [ToolMethod]
  , probeMethod :: Text
  , probeParams :: [(Text, Json)]
  , probeChanges :: [(Text, Json)]
  , probeArgv :: [[Text]]
  , probePaths :: [Text]
  , probeDeadline :: Double
  , probeClock :: Double
  , probeCloses :: Bool
  }

probe :: [ToolMethod] -> Text -> [(Text, Json)] -> Probe
probe caps m ps = Probe caps m ps [] [] [] 90 1 False

runNegativeProbe :: Fake -> IO [GatewayCounters]
runNegativeProbe fake = forM probes $ \(category', p) -> do
  let attachment = "probe-" <> rejectionCategoryText category'
      episode = "episode-" <> rejectionCategoryText category'
  ledger <- newGrantLedger attachment 9
  grant <-
    openGrant ledger (grantSpec p.probeCapabilities p.probeDeadline 1) {specWritablePaths = p.probePaths, specAllowedArgv = p.probeArgv}
  fence <- newFence
  gw <- gatewayWith fake episode ledger fence p.probeClock
  let base = conformanceRequest (rejectionCategoryText category') episode attachment 9 grant.grantEpoch p.probeMethod p.probeParams
      payload = case base of
        Object members -> Object [(k, fromMaybe v (lookup k p.probeChanges)) | (k, v) <- members]
        other -> other
  writeIORef fake.closeOnStage (if p.probeCloses then Just fence else Nothing)
  result <- submit gw payload
  writeIORef fake.closeOnStage Nothing
  ((.category) <$> result.resultError) `shouldBe` Just category'
  counters gw
  where
    probes =
      [ (CategoryUnknown, probe [] "future_tool" [])
      , (CategoryPath, probe [WorkspaceRead] "workspace_read" [("path", String "../escape")])
      , (CategoryCapability, probe [] "workspace_read" [("path", String "message.txt")])
      , ( CategoryArgv
        , (probe [WorkspaceShell] "workspace_shell" [("argv", Array [String "/bin/echo", String "message.txt"]), ("cwd", String ".")])
            { probeArgv = [["/bin/cat", "message.txt"]]
            }
        )
      , (CategoryWrite, probe [] "workspace_write" [("path", String "x"), ("content", String "x")])
      , (CategoryDeadline, (probe [WorkspaceRead] "workspace_read" [("path", String "message.txt")]) {probeDeadline = 5, probeClock = 10})
      , (CategoryStaleEpoch, (probe [WorkspaceRead] "workspace_read" [("path", String "message.txt")]) {probeChanges = [("attachment_epoch", Int 10)]})
      , ( CategoryPostFence
        , (probe [WorkspaceWrite] "workspace_write" [("path", String "message.txt"), ("content", String "late")])
            { probePaths = ["message.txt"]
            , probeCloses = True
            }
        )
      ]

spec :: Spec
spec = describe "hands/test_conformance.py" $ do
  it "test_es049_two_episode_trace_and_gateway_report_are_exact" $ do
    fake <- newFake True "message" "message.txt:1:message"
    (e1, e1Counters) <- runEpisode "e1" 1 fake
    (e2, e2Counters) <- runEpisode "e2" 2 fake
    negatives <- runNegativeProbe fake
    let appendsOf = \case
          Object ms | Just (Int n) <- lookup "appends" ms -> n
          _ -> 0
        report =
          Object
            [ ("episodes", Object [("e1", e1), ("e2", e2)])
            , ("total_appends", Int (appendsOf e1 + appendsOf e2))
            , ("application_crossings", Int 10)
            , ("gateway", sumCounters (e1Counters : e2Counters : negatives))
            ]
        expectedEpisode =
          Object
            [ ("invocations", Int 7)
            , ("appends", Int 7)
            , ("blocked_write_turn", Int 1)
            , ("grant_opened_turn", Int 3)
            , ( "finalized_turns"
              , Object
                  [ ("workspace_read", Int 2)
                  , ("workspace_search", Int 3)
                  , ("workspace_shell", Int 4)
                  , ("workspace_write", Int 5)
                  , ("workspace_test", Int 6)
                  ]
              )
            , ("successful_tools", Object [(toolMethodText m, Int 1) | m <- allToolMethods])
            , ("marker_outcome", String "episode_complete")
            , ("premature_markers", Int 0)
            ]
    report
      `shouldBe` Object
        [ ("episodes", Object [("e1", expectedEpisode), ("e2", expectedEpisode)])
        , ("total_appends", Int 14)
        , ("application_crossings", Int 10)
        , ( "gateway"
          , Object
              [ ("requests", Int 18)
              , ("adapter_entries", Int 11)
              , ("stages", Int 3)
              , ("commits", Int 2)
              , ("stage_discards", Int 1)
              , ("mutations", Int 2)
              , ( "rejections"
                , Object
                    [ ("capability", Int 1)
                    , ("path", Int 1)
                    , ("argv", Int 1)
                    , ("write", Int 1)
                    , ("unknown", Int 1)
                    , ("deadline", Int 1)
                    , ("stale_epoch", Int 1)
                    , ("post_fence", Int 1)
                    ]
                )
              ]
          )
        ]

  it "test_premature_marker_is_a_step_and_never_crosses_hands" $ do
    policy <- newSevenStepEpisodePolicy (policyConfig "attachment-probe" 1 "DONE")
    _ <- beginTurn policy
    _ <- appendObservation policy
    observe policy WorkspaceWrite (blockedWrite "attachment-probe" 1)
    _ <- beginTurn policy
    _ <- appendObservation policy
    decision <- admitMarker policy "DONE"
    policyTurns policy `shouldReturn` 2
    policyAppends policy `shouldReturn` 2
    decision `shouldBe` markerStep
    decision.outcome `shouldBe` "episode_step"
    decision.admitted `shouldBe` False
    policyPrematureMarkers policy `shouldReturn` 1

  forM_ [CategoryAborted, CategoryDeadline] $ \category' ->
    it ("test_abort_and_deadline_fail_policy_closed_while_stale_results_are_ignored[" <> T.unpack (rejectionCategoryText category') <> "]") $ do
      policy <- newSevenStepEpisodePolicy (policyConfig "attachment" 2 "DONE")
      _ <- beginTurn policy
      let failure = Just (expectRight (mkToolError category' "call rejected"))
      observe policy WorkspaceRead (expectRight (mkToolResult "stale" "attachment" 1 False Nothing failure))
      policyFailed policy `shouldReturn` False
      observe policy WorkspaceRead (expectRight (mkToolResult "current" "attachment" 2 False Nothing failure))
      policyFailed policy `shouldReturn` True
      ((.admitted) <$> admitMarker policy "DONE") `shouldReturn` False

  it "test_turn_and_append_budgets_are_independently_finite" $ do
    turns <- newSevenStepEpisodePolicy (policyConfig "attachment" 1 "DONE") {maxTurns = 1}
    _ <- beginTurn turns
    shouldRaiseMatchingIO (beginTurn turns) ConformanceError "turn budget"
    appends <- newSevenStepEpisodePolicy (policyConfig "attachment" 1 "DONE") {maxAppends = 1}
    _ <- appendObservation appends
    shouldRaiseMatchingIO (appendObservation appends) ConformanceError "append budget"
