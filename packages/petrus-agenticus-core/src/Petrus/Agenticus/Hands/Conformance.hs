-- | Maintained ES-049 seven-step application sensor/guard conformance policy
-- (@petrus.agenticus.hands.conformance@).
--
-- One host policy over the general grant and evidence primitives, kept as
-- the executable ES-049 conformance/example policy.  The gateway does not
-- require it and hosts may bring their own sensors; nothing here claims that
-- every Episode must follow the seven-step shape.
--
-- The accepted ES-049 Episode performs at most eight one-turn appends: one
-- blocked write, then read, search, shell, a permitted write, the fixed
-- test, and one completion marker.  The write grant may open only after read
-- and search have finalized, the marker is admitted only after a committed
-- write and a passing test, and any abort, deadline, stale result, or budget
-- overrun fails closed.
module Petrus.Agenticus.Hands.Conformance
  ( maxTurns
  , MarkerDecision (..)
  , markerComplete
  , markerStep
  , PolicyConfig (..)
  , policyConfig
  , SevenStepEpisodePolicy
  , newSevenStepEpisodePolicy
  , policyTurns
  , policyAppends
  , policyBlockedWriteTurn
  , policyGrantOpenedTurn
  , policyPrematureMarkers
  , policyFailed
  , policyFinalizedTurn
  , beginTurn
  , appendObservation
  , observe
  , writeGrantReady
  , noteGrantOpened
  , admitMarker
  ) where

import Control.Monad (forM_, when)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract
import Petrus.Json (Json (..))

maxTurns :: Int
maxTurns = 8

-- | One admission decision for a proposed completion marker.
data MarkerDecision = MarkerDecision
  { admitted :: Bool
  , outcome :: Text
  }
  deriving stock (Eq, Show)

markerComplete, markerStep :: MarkerDecision
markerComplete = MarkerDecision True "episode_complete"
markerStep = MarkerDecision False "episode_step"

-- | The constructor arguments of @SevenStepEpisodePolicy(...)@.
data PolicyConfig = PolicyConfig
  { attachmentId :: Text
  , attachmentEpoch :: Integer
  , expectedMarker :: Text
  , maxTurns :: Int
  , maxAppends :: Int
  }
  deriving stock (Eq, Show)

-- | Both budgets at 'maxTurns'.
policyConfig :: Text -> Integer -> Text -> PolicyConfig
policyConfig attachment epoch marker = PolicyConfig attachment epoch marker maxTurns maxTurns

data PolicyState = PolicyState
  { turns :: Int
  , appends :: Int
  , blockedWriteTurn :: Maybe Int
  , finalized :: Map ToolMethod Int
  , grantOpenedTurn :: Maybe Int
  , writeCommittedTurn :: Maybe Int
  , testPassedTurn :: Maybe Int
  , prematureMarkers :: Int
  , failed :: Bool
  }

-- | State-derived marker admission for one attachment epoch.
--
-- The policy projects only finalized current-epoch tool results.  Stale
-- results are ignored, aborted or deadline results fail the Episode closed,
-- and marker text alone can never complete an Episode.
data SevenStepEpisodePolicy = SevenStepEpisodePolicy
  { config :: PolicyConfig
  , state :: IORef PolicyState
  }

newSevenStepEpisodePolicy :: PolicyConfig -> IO SevenStepEpisodePolicy
newSevenStepEpisodePolicy cfg = do
  when (T.null cfg.attachmentId) $ throwAgenticus ValueError "policy attachment_id must be a non-empty string"
  when (cfg.attachmentEpoch <= 0) $ throwAgenticus ValueError "policy attachment_epoch must be a positive integer"
  when (T.null cfg.expectedMarker) $ throwAgenticus ValueError "policy expected_marker must be a non-empty string"
  forM_ [("max_turns", cfg.maxTurns), ("max_appends", cfg.maxAppends)] $ \(name, bound) ->
    when (bound <= 0 || bound > maxTurns) $
      throwAgenticus ValueError ("policy " <> name <> " must be an integer between 1 and " <> T.pack (show maxTurns))
  SevenStepEpisodePolicy cfg <$> newIORef (PolicyState 0 0 Nothing Map.empty Nothing Nothing Nothing 0 False)

peek :: (PolicyState -> a) -> SevenStepEpisodePolicy -> IO a
peek f policy = f <$> readIORef policy.state

policyTurns, policyAppends, policyPrematureMarkers :: SevenStepEpisodePolicy -> IO Int
policyTurns = peek (.turns)
policyAppends = peek (.appends)
policyPrematureMarkers = peek (.prematureMarkers)

policyBlockedWriteTurn, policyGrantOpenedTurn :: SevenStepEpisodePolicy -> IO (Maybe Int)
policyBlockedWriteTurn = peek (.blockedWriteTurn)
policyGrantOpenedTurn = peek (.grantOpenedTurn)

policyFailed :: SevenStepEpisodePolicy -> IO Bool
policyFailed = peek (.failed)

policyFinalizedTurn :: SevenStepEpisodePolicy -> ToolMethod -> IO (Maybe Int)
policyFinalizedTurn policy m = peek (Map.lookup m . (.finalized)) policy

-- | Start the next bounded one-tool-call turn or fail closed.
beginTurn :: SevenStepEpisodePolicy -> IO Int
beginTurn policy = do
  s <- readIORef policy.state
  when (s.turns >= policy.config.maxTurns) $ throwAgenticus ConformanceError "episode exceeded its turn budget"
  writeIORef policy.state s {turns = s.turns + 1}
  pure (s.turns + 1)

-- | Count one caller-owned transcript append or fail closed.
appendObservation :: SevenStepEpisodePolicy -> IO Int
appendObservation policy = do
  s <- readIORef policy.state
  when (s.appends >= policy.config.maxAppends) $ throwAgenticus ConformanceError "episode exceeded its append budget"
  writeIORef policy.state s {appends = s.appends + 1}
  pure (s.appends + 1)

-- | Project one finalized result; stale results never contribute.
observe :: SevenStepEpisodePolicy -> ToolMethod -> ToolResult -> IO ()
observe policy m result
  | result.attachmentId /= policy.config.attachmentId || result.epoch /= policy.config.attachmentEpoch = pure ()
  | not result.ok = modifyIORef' policy.state $ \s ->
      let category' = (.category) <$> result.resultError
          failed' = s.failed || category' `elem` [Just CategoryAborted, Just CategoryDeadline]
          blocked
            | m == WorkspaceWrite
            , category' == Just CategoryWrite
            , Nothing <- s.grantOpenedTurn
            , Nothing <- s.blockedWriteTurn =
                Just s.turns
            | otherwise = s.blockedWriteTurn
       in s {failed = failed', blockedWriteTurn = blocked}
  | otherwise = modifyIORef' policy.state $ \s ->
      s
        { finalized = Map.insertWith (\_ old -> old) m s.turns s.finalized
        , writeCommittedTurn =
            if m == WorkspaceWrite && s.grantOpenedTurn /= Nothing then Just s.turns else s.writeCommittedTurn
        , testPassedTurn =
            if m == WorkspaceTest && (lookup "passed" =<< result.resultData) == Just (Bool True)
              then Just s.turns
              else s.testPassedTurn
        }

ready :: PolicyState -> Bool
ready s =
  not s.failed
    && s.grantOpenedTurn == Nothing
    && Map.member WorkspaceRead s.finalized
    && Map.member WorkspaceSearch s.finalized

-- | Whether finalized read plus search permit opening the write grant.
writeGrantReady :: SevenStepEpisodePolicy -> IO Bool
writeGrantReady = peek ready

-- | Record that the host opened the write grant for this epoch.
noteGrantOpened :: SevenStepEpisodePolicy -> IO ()
noteGrantOpened policy = do
  s <- readIORef policy.state
  if ready s
    then writeIORef policy.state s {grantOpenedTurn = Just s.turns}
    else throwAgenticus ConformanceError "write grant requires prior finalized read and search"

-- | Admit a completion marker only from proven current-epoch state.
admitMarker :: SevenStepEpisodePolicy -> Text -> IO MarkerDecision
admitMarker policy marker = do
  s <- readIORef policy.state
  let readTurn = Map.lookup WorkspaceRead s.finalized
      searchTurn = Map.lookup WorkspaceSearch s.finalized
      proven = case (s.blockedWriteTurn, s.grantOpenedTurn, readTurn, searchTurn, s.writeCommittedTurn, s.testPassedTurn) of
        (Just _, Just opened, Just r, Just q, Just written, Just tested) ->
          r <= opened && q <= opened && written > opened && tested > written
        _ -> False
      admitted' = marker == policy.config.expectedMarker && not s.failed && s.turns <= policy.config.maxTurns && proven
  if admitted'
    then pure markerComplete
    else do
      writeIORef policy.state s {prematureMarkers = s.prematureMarkers + 1}
      pure markerStep
