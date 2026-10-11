-- | @hamsterdan-e2e-replay TAPE ROOT --github-port PORT --server-log LOG
-- --report REPORT --private-key PEM@: replay a tier B tape into the Haskell
-- host (the twin of @python/replay_python.py@). See "Hamsterdan.E2E.Replay".
module Main (main) where

import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as TE
import Hamsterdan.E2E.Replay (ReplayOptions (..), runReplay)
import Petrus.Json (EncodeOptions (..), defaultDumps, dumpsText)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    tape : root : rest
      | Just port <- readMaybe =<< lookup "--github-port" (pairs rest)
      , Just serverLog <- lookup "--server-log" (pairs rest)
      , Just report <- lookup "--report" (pairs rest)
      , Just keyPath <- lookup "--private-key" (pairs rest) -> do
          key <- TE.decodeUtf8 <$> BS.readFile keyPath
          result <- runReplay ReplayOptions {tape, root, githubPort = port, serverLog, privateKey = key}
          case dumpsText defaultDumps {sortKeys = True, indent = Just 1} result of
            Right text -> BS.writeFile report (TE.encodeUtf8 (text <> "\n"))
            Left problem -> hPutStrLn stderr (show problem) >> die "report not encodable"
    _ -> die "usage: hamsterdan-e2e-replay TAPE ROOT --github-port PORT --server-log LOG --report REPORT --private-key PEM"
  where
    pairs = \case
      name : value : rest -> (name, value) : pairs rest
      _ -> []
