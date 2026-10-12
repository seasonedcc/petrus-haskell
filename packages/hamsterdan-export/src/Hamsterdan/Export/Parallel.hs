-- | The exporter's two uses of the machine's cores, neither of which may
-- change what the reference would produce:
--
-- * 'parallelMap': a pure function over many inputs (one History line
--   each), the results in input order. It is @map@, with every result
--   forced ahead in parallel (GHC sparks), so a failing input raises
--   exactly where the sequential map would: when its result is used.
-- * 'writeFiles': the files of one output directory written at once, with
--   exactly the outcome of writing them one by one: every planned file has
--   its last planned content and, if any write fails, the directory is put
--   back the way the sequential writes would leave it (every write before
--   the first failing one done, none after) and that failure is raised.
--   Its threads are owned: an exception to the caller cancels them.
module Hamsterdan.Export.Parallel
  ( parallelMap
  , writeFiles
  ) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (forConcurrently)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Conc (numCapabilities, par, pseq)
import Hamsterdan.Export.Files (removeFileQuietly, writeBytes)

-- | @map f@, with each result forced (by @force@) in parallel: the inputs
-- are cut into a few contiguous chunks per capability and forcing each
-- chunk is sparked. The results are the plain map's, consumed in order, so
-- the first failure in order is the one raised, when its result is used.
-- Fewer than @smallest@ inputs are mapped plainly.
parallelMap :: Int -> (b -> ()) -> (a -> b) -> [a] -> [b]
parallelMap smallest force f inputs
  | numCapabilities <= 1 || total < smallest = map f inputs
  | otherwise = foldr par () forcings `pseq` keeping forcings slices
  where
    total = length inputs
    size = max 1 ((total + 4 * numCapabilities - 1) `div` (4 * numCapabilities))
    slices = map (map f) (chunks size inputs)
    forcings = map (foldr (\result rest -> force result `seq` rest) ()) slices
    -- The concatenation, holding on to each chunk's forcing until the
    -- consumer reaches the chunk (a spark only reachable from the spark
    -- pool would be collected unevaluated).
    keeping (_ : later) (slice : rest) = slice ++ keeping later rest
    keeping _ _ = []

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
      done <- forConcurrently (chunks size final) $ \slice ->
        all succeeded <$> forM slice (\(path, bytes) -> try (writeBytes path bytes))
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
