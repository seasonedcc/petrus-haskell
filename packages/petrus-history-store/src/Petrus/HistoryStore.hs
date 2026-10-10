-- | Durable History Store backends.
--
-- Every backend implements the kernel's one contract,
-- 'Petrus.Impetus.HistoryStore.HistoryStore', and is built with
-- 'mirroredHistoryStore' from its loaded records and one durable-write
-- action, so "durable before in memory" is structural:
--
-- * "Petrus.HistoryStore.Jsonl" — one JSON line per record, byte-identical
--   to the reference's @JsonlHistoryStore@; 'BackendOwned' commits.
-- * "Petrus.HistoryStore.Sqlite" — the reference's @SqliteHistoryStore@:
--   one short @BEGIN IMMEDIATE@ transaction per batch over the same DDL,
--   rows and payload spelling, with verify-on-conflict
--   ('verifyConflict'); 'BackendOwned' commits. It also re-exports the
--   SQLite writer fence that production hosts take before loading (the
--   SQLite Engine provider, @petrus-engine-sqlite@).
--
-- = Adding a backend
--
-- 1. Load the instance's records in order and decode each with
--    'Petrus.Impetus.History.Codec.decodeRecord' (refusing loud on a bad
--    one).
-- 2. Build the store with @'mirroredHistoryStore' mode loaded write@, where
--    @write@ encodes the whole batch first, then writes it and reports each
--    record's 'Admission' ('AcknowledgedElsewhere' for an equal terminal
--    held elsewhere).
-- 3. Choose the 'CommitMode': 'BackendOwned' when the store commits its own
--    transaction; 'JoinedTransaction' when it writes inside a connection the
--    Engine's provider commits (@Petrus.Engine.Provider@).
-- 4. Add the backend to this package's backend-contract suite
--    (@test/Petrus/HistoryStore/BackendContractSpec.hs@), which runs every
--    backend through the same @reopen@ factory.
module Petrus.HistoryStore
  ( -- * The kernel contract
    HistoryStore (..)
  , CommitMode (..)
  , Admission (..)
  , ConflictVerdict (..)
  , verifyConflict
  , append
  , records
  , size
  , inMemoryHistoryStore
  , mirroredHistoryStore
    -- * JSONL
  , module Petrus.HistoryStore.Jsonl
    -- * SQLite
  , module Petrus.HistoryStore.Sqlite
  ) where

import Petrus.HistoryStore.Jsonl
import Petrus.HistoryStore.Sqlite
import Petrus.Impetus.HistoryStore
