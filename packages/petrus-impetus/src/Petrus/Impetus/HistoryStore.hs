-- | The History Store contract an Instance writes through, and its
-- in-memory implementation (@petrus.impetus.history_store@ protocol and
-- @memory.py@).
--
-- The contract every backend keeps:
--
-- * __Batch.__ One 'extend' is one commit batch. Every Instance door writes
--   all of its records in a single 'extend'.
-- * __Durable before memory.__ The in-memory mirror ('records', 'size')
--   grows only after the durable write returned. A refused write raises and
--   leaves the mirror untouched, so an Instance never advances on a fact the
--   backend did not take.
-- * __No optimistic-concurrency parameter.__ The implicit expected length is
--   the mirror's size; durable backends key each record by its position.
--
-- A durable backend (JSONL, SQLite, Postgres — other packages) is built with
-- 'mirroredHistoryStore' from its loaded records and one durable-write
-- action, which makes "mirror after durable write" structural instead of a
-- convention each backend re-implements. 'CommitMode' tells the Engine
-- whether the backend owns its commits or joins a transaction the caller
-- commits (where "durable" means "visible inside the caller's transaction"
-- and a rollback obliges the caller to discard the store and every Instance
-- built over it).
module Petrus.Impetus.HistoryStore
  ( -- * Contract
    HistoryStore (..)
  , CommitMode (..)
  , append
  , records
  , size
    -- * Implementations
  , inMemoryHistoryStore
  , mirroredHistoryStore
    -- * Verify-on-conflict
  , Admission (..)
  , ConflictVerdict (..)
  , verifyConflict
  ) where

import Data.Foldable (toList)
import Data.IORef
import GHC.IORef (atomicModifyIORef'_)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Petrus.Impetus.History.Records (Record)
import Petrus.Json (Json)

-- | Who commits a batch: the backend itself, or the caller's transaction
-- that the backend joined.
data CommitMode = BackendOwned | JoinedTransaction
  deriving stock (Eq, Show)

-- | The structural History Store contract accepted by an Instance: a record
-- of operations rather than a class, so a backend is a value that can be
-- wrapped (instrumented, made to refuse in tests) without new types.
data HistoryStore = HistoryStore
  { snapshot :: IO (Seq Record)
  -- ^ The mirror: every record durably accepted so far, in append order.
  , count :: IO Int
  -- ^ The mirror's length (the implicit expected position of the next record).
  , extend :: [Record] -> IO ()
  -- ^ Commit one batch. Throws when the backend refuses it; the mirror is
  -- then unchanged.
  , mode :: CommitMode
  }

-- | @history.append(record)@: a batch of one.
append :: HistoryStore -> Record -> IO ()
append store record = store.extend [record]

-- | @history.records@.
records :: HistoryStore -> IO [Record]
records store = toList <$> store.snapshot

-- | @len(history)@.
size :: HistoryStore -> IO Int
size store = store.count

-- | @InMemoryHistoryStore()@: an append-only sequence of records, per net
-- instance. Its "durable write" is the mirror itself.
inMemoryHistoryStore :: IO HistoryStore
inMemoryHistoryStore = do
  -- 'mirroredHistoryStore' with a write that admits everything, without
  -- the admission bookkeeping: every batch simply joins the sequence.
  mirror <- newIORef Seq.empty
  pure
    HistoryStore
      { snapshot = readIORef mirror
      , count = Seq.length <$> readIORef mirror
      , extend = \batch -> () <$ atomicModifyIORef'_ mirror (\held -> foldl' (Seq.|>) held batch)
      , mode = BackendOwned
      }

-- | How the backend placed one record of a batch.
data Admission
  = -- | The record took the next position and enters the mirror.
    Entered
  | -- | An equal record already holds its terminal elsewhere (the one-terminal
    -- index): acknowledged, not entered, and the position does not advance.
    AcknowledgedElsewhere
  deriving stock (Eq, Show)

-- | Build a store over already-loaded records and one durable write. The
-- write receives the whole batch, commits it (or joins the caller's
-- transaction), and reports each record's admission; only then do the
-- entered records join the mirror. If the write throws, nothing does.
mirroredHistoryStore :: CommitMode -> Seq Record -> ([Record] -> IO [Admission]) -> IO HistoryStore
mirroredHistoryStore commitMode loaded durable = do
  mirror <- newIORef loaded
  let extend' batch = do
        admissions <- durable batch
        let entered
              | all (== Entered) admissions = batch
              | otherwise = [r | (r, Entered) <- zip batch (admissions ++ repeat Entered)]
        atomicModifyIORef' mirror (\held -> (foldl' (Seq.|>) held entered, ()))
  pure
    HistoryStore
      { snapshot = readIORef mirror
      , count = Seq.length <$> readIORef mirror
      , extend = extend'
      , mode = commitMode
      }

-- | The outcome of verifying a conflicting insert against the stored row.
data ConflictVerdict
  = -- | Equal payload at the same position: the record fills it.
    FillsPosition
  | -- | Equal payload at another position: acknowledged elsewhere.
    Acknowledged
  | -- | A different payload: a conflicting fact (the reference's @ValueError@).
    Conflicting
  deriving stock (Eq, Show)

-- | Verify-on-conflict with Python value equality on the decoded payloads
-- (@1 == 1.0 == true@, objects order-insensitive): the 'Eq' instance of
-- 'Json'. The 'Bool' says whether the stored row sits at the attempted
-- position.
verifyConflict :: Bool -> Json -> Json -> ConflictVerdict
verifyConflict samePosition stored attempted
  | stored /= attempted = Conflicting
  | samePosition = FillsPosition
  | otherwise = Acknowledged
