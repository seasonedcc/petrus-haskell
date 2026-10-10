-- | The provider seam: how a durable backend composes an Engine (the
-- reference's private @Engine._open(..., resources=_EngineResources(...))@).
--
-- = What a provider supplies
--
-- A provider (Local SQLite, Postgres, Absurd, …) builds three things and
-- hands them to 'openEngine':
--
-- 1. A 'HistoryStore' — backend-owned ('Petrus.Impetus.HistoryStore.BackendOwned':
--    every append durable at the door, like JSONL) or joined
--    ('Petrus.Impetus.HistoryStore.JoinedTransaction': appends ride a
--    caller-held transaction).
-- 2. A 'Dispatch' — the outbox port from "Petrus.Motus.Dispatch"; a
--    provider whose Dispatch shares the History's transaction (Postgres
--    join mode, Absurd) makes begin + spawn + doorbell one atomic cut.
-- 3. 'EngineResources' — the transaction and hosting fate:
--
--     * 'commit' (joined stores only) is called at every commit point the
--       coordinator and the doors define (see "Petrus.Engine.Coordinator").
--       Begin, dispatch, and the selection commit or vanish together; the
--       selection state installs only after 'commit' returns.
--     * 'rollback' runs after any writing-door failure, before the
--       resources close; the Engine is then poisoned and every later door
--       refuses — the coherent continuation is a fresh load.
--     * 'release' (drop the writer fence: an advisory lock, a lease row)
--       then 'close' (the connection) run at most once, on 'close' or on
--       poisoning; 'close' runs even when 'release' throws.
--     * 'ensure' runs before every door: a provider that lost its lease
--       raises here and the door never runs.
--     * 'wait' answers 'Petrus.Engine.wait' with a wake hint (LISTEN/NOTIFY,
--       a doorbell table); 'Nothing' sleeps the bounded interval.
--
-- A construction failure (a refused load, a store error) rolls back,
-- releases, and closes before it propagates.
--
-- = Durable Dispatch lifecycle
--
-- The 'Dispatch' record carries no lifecycle or wait methods: queues,
-- leases, and worker pools belong to the provider, which releases them in
-- 'release' / 'close' and surfaces arrival in 'wait'. A provider whose
-- Dispatch implements recoverable cancellation sets
-- 'Petrus.Motus.Dispatch.cancel'; the Engine then fences lifecycle-cancelled
-- Activities with an exact 'Petrus.Motus.Dispatch.CancellationInstruction'
-- naming the History position of the committed close or reset.
module Petrus.Engine.Provider
  ( EngineResources (..)
  , defaultResources
  , OpenMode (..)
  , openEngine
  , engineInstance
  ) where

import Petrus.Engine.Internal (EngineResources (..), OpenMode (..), defaultResources, engineInstance, openEngine)
