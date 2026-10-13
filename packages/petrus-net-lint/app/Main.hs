-- | @petrus-net-lint NET.json@: lint a net's definition, a Net-definition v3
-- or a Net document v1. It reads the declarations and waivers beside it,
-- @NET.declared.json@ and @NET.waivers.json@, when they exist, prints each
-- finding on a line, and exits 1 when there is any.
module Main (main) where

import Data.Text (Text)
import Data.Text.IO qualified as T
import Petrus.Net.Files
import Petrus.Net.Lint
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (stderr)

main :: IO ()
main =
  getArgs >>= \case
    [path] -> do
      net <- orStop =<< readNet path
      declared <- orStop =<< readDeclared path
      waivers <- orStop =<< readWaivers path
      case lint net declared waivers of
        [] -> pure ()
        found -> mapM_ (T.putStrLn . renderFinding) found >> exitFailure
    _ -> T.hPutStrLn stderr "usage: petrus-net-lint NET.json" >> exitFailure

orStop :: Either Text a -> IO a
orStop = either (\problem -> T.hPutStrLn stderr problem >> exitFailure) pure
