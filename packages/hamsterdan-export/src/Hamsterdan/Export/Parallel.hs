-- | The exporter's two uses of the machine's cores, neither of which may
-- change what the reference would produce:
--
-- * 'parallelMap': a pure function over many inputs (one History line
--   each), the results in input order, every result forced on a worker.
-- * 'writeFiles': the files of one output directory written at once, with
--   exactly the outcome of writing them one by one: every planned file has
--   its last planned content and, if any write fails, the directory is put
--   back the way the sequential writes would leave it (every write before
--   the first failing one done, none after) and that failure is raised.
module Hamsterdan.Export.Parallel
  ( parallelMap
  , writeFiles
  ) where

import Control.Concurrent (forkOn, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, throwIO, try)
import Control.Monad (forM, forM_, void)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hamsterdan.Export.Files (removeFileQuietly, writeBytes)

-- | @map f@, evaluated on every capability (one worker pinned to each):
-- each worker takes a contiguous
-- slice and runs @force@ on each result before handing it back. Fewer than
-- @smallest@ inputs are mapped here instead. An exception from a worker is
-- rethrown here.
parallelMap :: forall a b. Int -> (b -> ()) -> (a -> b) -> [a] -> IO [b]
parallelMap smallest force f inputs = do
  workers <- getNumCapabilities
  let total = length inputs
  if workers <= 1 || total < smallest
    then pure (map f inputs)
    else do
      let size = (total + workers - 1) `div` workers
      slots <- forM (zip [0 ..] (chunks size inputs)) $ \(worker, slice) -> do
        slot <- newEmptyMVar
        void . forkOn worker $ do
          outcome <- try (evaluate (let results = map f slice in foldr (\r acc -> force r `seq` acc) () results `seq` results))
          putMVar slot (outcome :: Either SomeException [b])
        pure slot
      fmap concat . forM slots $ \slot -> takeMVar slot >>= either throwIO pure

chunks :: Int -> [a] -> [[a]]
chunks size = \case
  [] -> []
  items -> let (slice, rest) = splitAt size items in slice : chunks size rest

-- | Write each planned file (path, contents), in plan order, into a
-- directory this export created empty and alone writes to. The writes run
-- on every capability; the result is the sequential one.
writeFiles :: [(Text, ByteString)] -> IO ()
writeFiles planned = do
  workers <- getNumCapabilities
  if workers <= 1 || length planned < 64
    then mapM_ (uncurry writeBytes) planned
    else do
      -- A path planned twice ends with its last contents.
      let final = Map.toList (Map.fromList planned)
          size = (length final + workers - 1) `div` workers
      slots <- forM (zip [0 ..] (chunks size final)) $ \(worker, slice) -> do
        slot <- newEmptyMVar
        void . forkOn worker $ do
          outcomes <- forM slice $ \(path, bytes) -> try (writeBytes path bytes)
          putMVar slot (all succeeded outcomes)
        pure slot
      done <- mapM takeMVar slots
      if and done
        then pure ()
        else do
          -- Start over one by one: the same writes, raising at the first
          -- failure, exactly as the reference does.
          forM_ final (removeFileQuietly . fst)
          mapM_ (uncurry writeBytes) planned
  where
    succeeded :: Either SomeException () -> Bool
    succeeded = either (const False) (const True)
