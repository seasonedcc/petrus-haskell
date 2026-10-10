{-# LANGUAGE DuplicateRecordFields #-}

-- | The deterministic World interpreter. Import qualified:
--
-- > import Petrus.Testing.Dst.World qualified as World
--
-- A World is built from a 'WorldConfig' with 'newWorld' (or 'withWorld',
-- which also closes it) and driven in 'WorldT'. Each operation mirrors one
-- method of the reference's @World@.
module Petrus.Testing.Dst.World
  ( -- * Worlds
    World
  , WorldConfig (..)
  , worldConfig
  , WorldT
  , newWorld
  , runWorldT
  , withWorld
  , liftWorld
  , tryWorld
  , throwWorld

    -- * Failures
  , DstFailure (..)
  , RunUntil (..)
  , failureMessage
  , failureClass

    -- * Process progress
  , Progress (..)
  , Boundary (..)

    -- * Operations
  , submit
  , step
  , activateFault
  , observe
  , crash
  , restart
  , beginFair
  , finish
  , artifact
  , close
  , pending
  , pendingCount
  , timeline

    -- * State
  , generation
  , currentInstant
  , operations
  , operationCount
  , operationsFrom
  , journal
  , disposition
  , worldBudget
  , worldProfileIdentity
  , worldCheckerIdentities
  , worldSeed

    -- * Choices
  , chooseIndex
  , chooseIdentifier
  , choiceDraws
  ) where

import Petrus.Testing.Dst.Internal.World
import Petrus.Testing.Dst.Timeline (timeline)
