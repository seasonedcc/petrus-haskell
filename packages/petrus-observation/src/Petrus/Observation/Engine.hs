-- | The Engine's three protocol-v1 read doors (the reference's
-- @Engine.snapshot()@, @Engine.net_document()@, and
-- @Engine.history_page(after, limit)@), built on the Engine's observation
-- seam, 'Petrus.Engine.Observation.observeEngine'.
--
-- Import qualified:
--
-- > import Petrus.Observation.Engine qualified as Observe
-- >
-- > current <- Observe.snapshot engine
-- > page <- Observe.historyPage engine 0 100
--
-- Each door is one coherent, non-reentrant read: the Instance and its
-- History are captured under the Engine's monitor, so a reader that
-- arrives while a writing door is between its append and its projection
-- waits and then sees the after-state (@frontier == length records@ agrees
-- with @current@). The projection itself is pure.
--
-- Refusals are thrown, as the reference raises them:
--
-- * an 'Petrus.Engine.EngineError' ('Petrus.Engine.EngineRuntimeError')
--   from the Engine, with the reference's text, when the read re-enters
--   from inside a writing door, or the Engine is poisoned or closed — these
--   are checked first, before any argument;
-- * an 'ObservationError' (the reference's @ValueError@) from the
--   projection: a malformed or future cursor, non-integer current times,
--   non-finite data, or an empty History for 'netDocument'.
module Petrus.Observation.Engine
  ( observe
  , snapshot
  , netDocument
  , historyPage
  , historyPageJson
  ) where

import Control.Exception (throwIO)
import Petrus.Engine (Engine)
import Petrus.Engine.Observation (observeEngine)
import Petrus.Impetus.Instance (instanceIdentity)
import Petrus.Json (Json)
import Petrus.Observation (Observation (..), ObservationError, captureInstance)
import Petrus.Observation qualified as Observation

-- | One coherent capture of the hosted Instance and its complete canonical
-- History, read under the Engine's monitor.
observe :: Engine -> IO Observation
observe engine = observeEngine engine $ \inst history -> do
  observed <- captureInstance inst
  pure Observation {observed, records = history}

-- | @Engine.snapshot()@: a coherent detached protocol-v1 view of the
-- definition and current state.
snapshot :: Engine -> IO Json
snapshot engine = observe engine >>= orThrow . Observation.snapshot

-- | @Engine.net_document()@: one coherent observed portable Net document.
netDocument :: Engine -> IO Json
netDocument engine = observe engine >>= orThrow . Observation.netDocument

-- | @Engine.history_page(after, limit)@: a detached protocol-v1 page after
-- an exclusive confirmed prefix.
historyPage :: Engine -> Integer -> Integer -> IO Json
historyPage engine after limit =
  orThrow
    =<< observeEngine engine (\inst history -> pure (Observation.historyPage (instanceIdentity inst) history after limit))

-- | 'historyPage' over untyped cursor values (a transport's parsed query):
-- the reference's argument checks ('Observation.historyCursor', Python
-- @repr@ in the message) run inside the read door, after the Engine's own
-- checks, exactly where the reference's @history_page@ runs them.
historyPageJson :: Engine -> Json -> Json -> IO Json
historyPageJson engine after limit =
  orThrow
    =<< observeEngine
      engine
      ( \inst history ->
          pure (Observation.historyCursor after limit >>= uncurry (Observation.historyPage (instanceIdentity inst) history))
      )

orThrow :: Either ObservationError Json -> IO Json
orThrow = either throwIO pure
