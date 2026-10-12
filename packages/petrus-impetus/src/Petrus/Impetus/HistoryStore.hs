{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

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
  , AdmissionMismatch (..)
  , UnverifiableConflict (..)
  ) where

import Control.Exception (Exception (..), throwIO)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.IORef
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Exts (casMutVar#, readMutVar#)
import GHC.IO (IO (..))
import GHC.IORef (IORef (..))
import GHC.STRef (STRef (..))
import Petrus.Impetus.History.Records (Record)

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
      , extend = \case
          [record] -> modifyStrict mirror (Seq.|> record)
          batch -> modifyStrict mirror (\held -> foldl' (Seq.|>) held batch)
      , mode = BackendOwned
      }

-- | Atomically replace the value with @f@ of it, evaluated to WHNF before
-- it is published: read, compute, compare-and-swap, retried if another
-- thread swapped in between. Unlike 'atomicModifyIORef'_' it allocates no
-- thunk and no result pair, which is most of the cost of a one-record
-- append: petrus-history-store's @store.in-memory-append@ row took 295 µs
-- this way and 520 µs with 'atomicModifyIORef'', behind the reference's
-- 422 µs (Apple M4, 2026-10-12, five interleaved repetitions; see that
-- package's bench/RESULTS.md).
modifyStrict :: IORef a -> (a -> a) -> IO ()
modifyStrict (IORef (STRef var)) f = IO loop
  where
    loop s0 = case readMutVar# var s0 of
      (# s1, old #) ->
        let !new = f old
         in case casMutVar# var old new s1 of
              (# s2, 0#, _ #) -> (# s2, () #)
              (# s2, _, _ #) -> loop s2

-- | How the backend placed one record of a batch.
data Admission
  = -- | The record took the next position and enters the mirror.
    Entered
  | -- | An equal record already holds its terminal elsewhere (the one-terminal
    -- index): acknowledged, not entered, and the position does not advance.
    AcknowledgedElsewhere
  deriving stock (Eq, Show)

-- | Build a store over already-loaded records and one durable write. The
-- write receives the mirror's length (the position the batch starts at)
-- and the whole batch, commits it (or joins the caller's transaction), and
-- reports each record's admission, one per record; only then do the
-- entered records join the mirror. If the write throws, nothing does.
mirroredHistoryStore :: CommitMode -> Seq Record -> (Int -> [Record] -> IO [Admission]) -> IO HistoryStore
mirroredHistoryStore commitMode loaded durable = do
  mirror <- newIORef loaded
  let extend' batch = do
        position <- Seq.length <$> readIORef mirror
        admissions <- durable position batch
        let entered
              | all (== Entered) admissions = batch
              | otherwise = [r | (r, Entered) <- zip batch admissions]
        when (length admissions /= length batch) $
          throwIO (AdmissionMismatch (length batch) (length admissions))
        atomicModifyIORef' mirror (\held -> (foldl' (Seq.|>) held entered, ()))
  pure
    HistoryStore
      { snapshot = readIORef mirror
      , count = Seq.length <$> readIORef mirror
      , extend = extend'
      , mode = commitMode
      }

-- | A backend's durable write reported a different number of admissions
-- than the batch has records (records, admissions): a backend defect, so
-- nothing joins the mirror.
data AdmissionMismatch = AdmissionMismatch Int Int
  deriving stock (Eq, Show)

instance Exception AdmissionMismatch where
  displayException (AdmissionMismatch batch admissions) =
    "a History backend reported " <> show admissions <> " admissions for a batch of " <> show batch <> " records"

-- | A transactional backend's insert conflicted and no stored row explains
-- it (the reference's @RuntimeError@): the conflict cannot be verified, so
-- it is never acknowledged. (A conflict is verified with the 'Eq' instance
-- of 'Petrus.Json.Json', Python value equality on the decoded payloads.)
newtype UnverifiableConflict = UnverifiableConflict Text
  deriving stock (Eq, Show)

instance Exception UnverifiableConflict where
  displayException (UnverifiableConflict message) = T.unpack message
