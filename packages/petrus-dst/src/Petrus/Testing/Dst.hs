{-# LANGUAGE DuplicateRecordFields #-}

-- | Deterministic simulation testing for Petrus (@petrus.testing.dst@, API
-- @petrus.testing.dst/v4@).
--
-- This module re-exports the value model, codecs, choice streams, the
-- profile seam, and replay. World and Timeline operations share names with
-- model fields, so import them qualified:
--
-- > import Petrus.Testing.Dst
-- > import Petrus.Testing.Dst.World qualified as World
-- > import Petrus.Testing.Dst.Timeline qualified as Timeline
module Petrus.Testing.Dst
  ( module Petrus.Testing.Dst.Types
  , module Petrus.Testing.Dst.Codec
  , module Petrus.Testing.Dst.Choice
  , module Petrus.Testing.Dst.Profile
  , module Petrus.Testing.Dst.Replay
  , World
  , WorldConfig (..)
  , worldConfig
  , WorldT
  , DstFailure (..)
  , RunUntil (..)
  , failureMessage
  , failureClass
  , Timeline
  ) where

import Petrus.Testing.Dst.Choice
import Petrus.Testing.Dst.Codec
import Petrus.Testing.Dst.Profile
import Petrus.Testing.Dst.Replay
import Petrus.Testing.Dst.Timeline (Timeline)
import Petrus.Testing.Dst.Types
import Petrus.Testing.Dst.World
