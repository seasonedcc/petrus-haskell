{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# OPTIONS_GHC -fno-full-laziness -fno-cse #-}

-- | The one place the DST worlds run effects inside an Engine Activity
-- handler.
--
-- The reference's bridges (@RuntimeBridge@, @RetryBridge@, the lifecycle,
-- projection and joined bridges) count their @prepare@/@project@ calls and
-- read injected faults. @petrus-impetus@'s 'ActivityHandler' makes both
-- functions pure, and changing that kernel API is outside the DST slice, so
-- an 'ObservedHandler' runs its 'IO' with 'unsafePerformIO' when the Engine
-- forces the result. That is sound because the Engine forces each handler
-- result exactly once per call, and because this module alone carries the
-- flags (@-fno-full-laziness -fno-cse@) and the @NOINLINE@ that stop GHC
-- from sharing or floating two calls into one. The authored journals pin
-- the call counts, so a lost or duplicated effect fails the World
-- fixtures.
module Petrus.Testing.Dst.Engine.Bridge
  ( ObservedHandler (..)
  , observed
  ) where

import Data.Text (Text)
import Petrus.Activity (ActivityInvocation)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult)
import Petrus.Impetus.Petrinet.Enabledness (Binding)
import Petrus.Json (Json)
import System.IO.Unsafe (unsafePerformIO)

-- | An Activity handler whose @prepare@ and @project@ run effects.
data ObservedHandler = ObservedHandler
  { prepare :: Binding -> IO (Either Text ActivityInvocation)
  , project :: Binding -> Json -> IO (Either Text HandlerResult)
  }

-- | The Engine handler running each effect once per Engine call.
observed :: ObservedHandler -> BoundHandler
observed handler =
  ActivityBound
    ActivityHandler
      { prepare = \binding -> unsafePerformIO (handler.prepare binding)
      , project = \binding value -> unsafePerformIO (handler.project binding value)
      , projectFailure = Nothing
      }
{-# NOINLINE observed #-}
