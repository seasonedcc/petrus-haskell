{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | How the DST worlds install their Activity bridge in an Engine.
--
-- The reference's bridges (@RuntimeBridge@, @RetryBridge@, the lifecycle,
-- projection and joined bridges) count their @prepare@/@project@ calls and
-- read injected faults. @petrus-impetus@'s 'ActivityHandler' keeps both
-- functions pure, so a world splits its bridge in two: the pure handler,
-- and the per-call effects, which run as the Engine's handler observer
-- ('Engine.handlerObserver') in the writing door, once per call, before
-- the pure function is applied. An effect answering 'Left' is the bridge
-- raising.
module Petrus.Testing.Dst.Engine.Bridge
  ( Bridged (..)
  , withBridge
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Activity (ActivityInvocation)
import Petrus.Engine (EngineOptions, HandlerCall (..))
import Petrus.Engine qualified as Engine
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult)
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Petrinet.Enabledness (Binding)
import Petrus.Json (Json)

-- | A world's Activity bridge.
data Bridged = Bridged
  { prepare :: Binding -> Either Text ActivityInvocation
  , project :: Binding -> Json -> Either Text HandlerResult
  , onPrepare :: IO (Either Text ())
  -- ^ Run before each @prepare@ (a 'Left' raises it).
  , onProject :: IO (Either Text ())
  -- ^ Run before each @project@ (a 'Left' raises it).
  }

-- | Bind the bridge to the @bridge@ handler symbol and run its effects as
-- the Engine's handler observer.
withBridge :: Bridged -> EngineOptions -> EngineOptions
withBridge bridge options =
  options
    { Engine.handlers =
        Map.insert
          (Symbol "bridge")
          (ActivityBound ActivityHandler {prepare = bridge.prepare, project = bridge.project, projectFailure = Nothing})
          options.handlers
    , Engine.handlerObserver = Just $ \case
        Preparing _ -> bridge.onPrepare
        Projecting _ _ -> bridge.onProject
        ProjectingFailure _ _ -> pure (Right ())
    }
