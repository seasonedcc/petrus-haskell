{-# LANGUAGE OverloadedRecordDot #-}

-- | Replay a strict executable-world artifact through the public Engine
-- profiles: a port of the reference's @tests/dst/replay_world.py@ (the
-- @petrus-dst-world replay@ command prints its result).
module Petrus.Testing.Dst.Engine.ReplayWorld
  ( replayWorldRegistry
  , replayPath
  , replayResultBytes
  ) where

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Delayed qualified as Delayed
import Petrus.Testing.Dst.Engine.Delivery qualified as Delivery
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as GeneratedRuntime
import Petrus.Testing.Dst.Engine.Lifecycle qualified as Lifecycle
import Petrus.Testing.Dst.Engine.Projection qualified as Projection
import Petrus.Testing.Dst.Engine.Retry qualified as Retry
import Petrus.Testing.Dst.Engine.Timer qualified as Timer
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | @replay_path@'s registry: every non-joined Engine profile, each over
-- its own files in @directory@, and every checker.
replayWorldRegistry :: FilePath -> IO (Registry IO)
replayWorldRegistry directory = do
  let at = (directory </>)
  delayed <- Delayed.delayedEngineProfile (at "delayed-history.jsonl")
  delivery <- Delivery.deliveryEngineProfile (at "delivery-history.jsonl")
  dispatchRefusal <- Projection.dispatchRefusalEngineProfile (at "dispatch-refusal-history.jsonl")
  projection <- Projection.engineProfile (at "projection-history.jsonl")
  ackLoss <- Projection.historyAckLossEngineProfile (at "history-ack-loss.jsonl")
  historyRefusal <- Projection.historyRefusalEngineProfile (at "history-refusal.jsonl")
  resource <- Projection.resourceBoundedEngineProfile (at "resource-history.jsonl")
  generated <- GeneratedRuntime.generatedRuntimeProfile (at "generated-runtime-history.jsonl") (at "generated-runtime-dispatch.db")
  mutation <-
    GeneratedRuntime.generatedRuntimeProfileWith
      GeneratedRuntime.LivelockMutation
      (at "generated-runtime-mutation-history.jsonl")
      (at "generated-runtime-mutation-dispatch.db")
  cancellation <- Lifecycle.lifecycleCancellationRefusalProfile (at "lifecycle-cancellation-history.jsonl")
  lifecycle <- Lifecycle.lifecycleEngineProfile (at "lifecycle-history.jsonl")
  delayedRetry <- Retry.delayedRetryEngineProfile (at "delayed-retry-history.jsonl") (at "delayed-retry-dispatch.db")
  retry <- Retry.retryEngineProfile (at "retry-history.jsonl") (at "retry-dispatch.db")
  terminal <- Retry.terminalEngineProfile (at "terminal-history.jsonl") (at "terminal-dispatch.db")
  timer <- Timer.timerEngineProfile (at "timer-history.jsonl")
  either (fail . T.unpack . failureMessage) pure $ do
    withProfiles <-
      foldM
        (\r (SomeProfile p) -> registerProfile p r)
        emptyRegistry
        [ SomeProfile delayed.engine.profile
        , SomeProfile delivery.profile
        , SomeProfile dispatchRefusal.profile
        , SomeProfile projection.profile
        , SomeProfile ackLoss.profile
        , SomeProfile historyRefusal.profile
        , SomeProfile resource.profile
        , SomeProfile generated.profile
        , SomeProfile mutation.profile
        , SomeProfile cancellation.profile
        , SomeProfile lifecycle.profile
        , SomeProfile delayedRetry.profile
        , SomeProfile retry.profile
        , SomeProfile terminal.profile
        , SomeProfile timer.profile
        ]
    foldM
      (flip registerChecker)
      withProfiles
      [ Projection.acceptedCommitAuthorityChecker
      , Lifecycle.cancellationAuthorityChecker
      , Projection.commitAuthorityChecker
      , Delayed.delayedAuthorityChecker
      , Delivery.deliveryAuthorityChecker
      , Projection.dispatchAuthorityChecker
      , Retry.delayedRetryAuthorityChecker
      , Projection.engineHistoryChecker
      , GeneratedRuntime.generatedRuntimeChecker
      , Lifecycle.lifecycleAuthorityChecker
      , Retry.retryAuthorityChecker
      , Retry.terminalAuthorityChecker
      , Projection.terminalRefusalChecker
      , Timer.timerAuthorityChecker
      ]

-- | @replay_path(path)@: load the artifact strictly and replay it through a
-- fresh registry in a temporary directory.
replayPath :: FilePath -> IO (Either DstFailure AnyReplayResult)
replayPath path = do
  loaded <- loadArtifact path
  case loaded of
    Left problem -> pure (Left (ContractViolation "ValidationError" (decodeErrorMessage problem)))
    Right artifact -> withSystemTempDirectory "petrus-dst-world-" $ \directory -> do
      registry <- replayWorldRegistry directory
      replay registry artifact

-- | @json.dumps(result.model_dump(mode="json"), separators=(",", ":"),
-- sort_keys=True)@: what the replay command prints, without its newline.
replayResultBytes :: AnyReplayResult -> ByteString
replayResultBytes = encodeReplayResult
