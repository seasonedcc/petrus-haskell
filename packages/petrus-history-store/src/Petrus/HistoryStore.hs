-- | Durable History Store backends.
--
-- Every backend implements the kernel's one contract,
-- 'Petrus.Impetus.HistoryStore.HistoryStore', and is built with
-- 'mirroredHistoryStore' from its loaded records and one durable-write
-- action, so "durable before in memory" is structural:
--
-- * "Petrus.HistoryStore.Jsonl" — one JSON line per record, byte-identical
--   to the reference's @JsonlHistoryStore@; 'BackendOwned' commits.
--
-- = Adding a backend (the SQLite store goes here)
--
-- The SQLite store (@SqliteHistoryStore(path, instance=...)@ upstream) lands
-- as @Petrus.HistoryStore.Sqlite@ in this package, next to the JSONL module,
-- and re-exported below. Its shape is fixed by the kernel contract:
--
-- 1. Load the instance's rows in position order and decode each with
--    'Petrus.Impetus.History.Codec.decodeRecord' (refusing loud on a bad
--    row, as JSONL refuses a bad line).
-- 2. Build the store with
--    @'mirroredHistoryStore' mode loaded write@, where @write@ encodes the
--    whole batch first ('Petrus.Impetus.History.Codec.encodeRecord'), then
--    inserts it keyed by position and reports each record's 'Admission'
--    (verify-on-conflict through 'verifyConflict': an equal terminal held
--    elsewhere is 'AcknowledgedElsewhere').
-- 3. Choose the 'CommitMode': 'BackendOwned' when the store commits its own
--    transaction; 'JoinedTransaction' when it writes inside a connection the
--    Engine's provider commits. A joined store must then be paired with an
--    Engine provider whose resources carry the commit
--    (@Petrus.Engine.Provider@). As in the reference, the pairing is the
--    provider's to keep: the Engine commits at its commit points exactly
--    when the resources supply a 'commit', and does not inspect the mode.
-- 4. Locking: when a backend needs an advisory file lock, use the shared
--    @petrus-posix@ package once it lands on main; until then keep a small
--    internal module and note it for replacement. JSONL needs none.
-- 5. Port @tests/petrus/impetus/history_store/test_sqlite_history.py@ and add
--    the backend to this package's backend-contract suite
--    (@test/Petrus/HistoryStore/BackendContractSpec.hs@), which runs every
--    backend through the same @reopen@ factory.
module Petrus.HistoryStore
  ( -- * The kernel contract
    HistoryStore (..)
  , CommitMode (..)
  , Admission (..)
  , append
  , records
  , size
  , inMemoryHistoryStore
  , mirroredHistoryStore
    -- * JSONL
  , module Petrus.HistoryStore.Jsonl
  ) where

import Petrus.HistoryStore.Jsonl
import Petrus.Impetus.HistoryStore
