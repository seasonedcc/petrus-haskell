-- | The observation seam: one coherent, non-reentrant read of a hosted
-- Instance and its History.
--
-- The reference's @Engine.snapshot()@, @Engine.net_document()@, and
-- @Engine.history_page(after, limit)@ each run one protocol view
-- (@petrus.impetus.observation@) under the Engine's monitor. This package
-- does not depend on the Haskell observation package; that package builds
-- the three views on 'observeEngine' ("Petrus.Observation.Engine" in
-- @petrus-observation@).
--
-- The read refuses from inside a writing door (the reference's
-- non-reentrant reads) and on a poisoned or closed Engine.
module Petrus.Engine.Observation
  ( observeEngine
  ) where

import Petrus.Engine.Internal (observeEngine)
