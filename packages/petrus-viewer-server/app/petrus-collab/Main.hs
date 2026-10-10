-- | @server/collab.mjs@: the standalone collaboration relay.
--
-- Usage: petrus-collab [port]   (default 4567)
module Main (main) where

import Petrus.Viewer.Server (runCollabServer)
import System.Environment (getArgs)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  runCollabServer $ case args of
    (p : _) | Just n <- readMaybe p, n > 0 -> n
    _ -> 4567
