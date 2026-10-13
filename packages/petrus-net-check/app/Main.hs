-- | @petrus-net-check NET.json@: explore every marking of a net's skeleton,
-- for each scenario in @NET.declared.json@ beside it. It prints what each
-- scenario reached, each problem with the firings that lead to it, and the
-- net's P-invariants, and exits 1 when there is any problem.
module Main (main) where

import Data.Text (Text)
import Data.Text.IO qualified as T
import Petrus.Net.Check
import Petrus.Net.Files
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (stderr)

main :: IO ()
main =
  getArgs >>= \case
    [path] -> do
      net <- orStop =<< readNet path
      declared <- orStop =<< readDeclared path
      let checked = check defaultLimits net declared
      mapM_ T.putStrLn (renderChecked checked)
      if any (\r -> not (null r.problems)) checked.reports then exitFailure else pure ()
    _ -> T.hPutStrLn stderr "usage: petrus-net-check NET.json" >> exitFailure

orStop :: Either Text a -> IO a
orStop = either (\problem -> T.hPutStrLn stderr problem >> exitFailure) pure
