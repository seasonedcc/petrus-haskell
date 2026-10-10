{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Benchmarks against the Python reference (@scripts/bench.py@ runs the
-- same workloads there). Run from the package directory:
--
-- > cabal bench petrus-dst --benchmark-options='--stdev 5'
--
-- Results and the comparison live in @bench/RESULTS.md@.
module Main (main) where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Runner
import Generated
import Spec.Support
import System.Directory (listDirectory)
import System.FilePath (takeFileName, (</>))
import Test.Tasty.Bench

foreignFixtures :: [FilePath]
foreignFixtures = ["generated-runtime-semantic-coverage-v1.json", "projection-crash-recovery-v1.json"]

loadFixtures :: IO [ByteString]
loadFixtures = do
  names <- sort . filter (`notElem` foreignFixtures) <$> listDirectory fixturesDir
  forM names $ \name -> BS.dropWhileEnd (== 10) <$> BS.readFile (fixturesDir </> takeFileName name)

decodeAll :: [ByteString] -> [AnyArtifact]
decodeAll = map (either (error . show) id . decodeArtifact)

roundTrip :: [ByteString] -> [ByteString]
roundTrip = map (\bytes -> either (error . show) (either (error . T.unpack) id . encodeArtifact) (decodeArtifact bytes))

encodeAll :: [AnyArtifact] -> [ByteString]
encodeAll = map (either (error . T.unpack) id . encodeArtifact)

-- | Author and replay every generated script; the artifact and replay
-- bytes.
authorAll :: [Script] -> IO [(Maybe ByteString, Text)]
authorAll scripts = forM scripts $ \s -> do
  authored <- authorScript s
  case authored of
    Right (_, _, _, Right artifact) -> do
      replayed <- replayFresh s artifact
      pure (either (const Nothing) Just (encodeArtifact artifact), canonText (replayJson replayed))
    other -> pure (Nothing, T.pack (show (fmap (const ()) other)))

draws :: Int -> Integer
draws n = go n (either (error . show) id (choiceStreams 1729)) 0
  where
    go 0 _ acc = acc
    go k streams acc = case chooseIndex WorkloadChoice 1000 streams of
      Left e -> error (show e)
      Right (value, streams') -> go (k - 1) streams' (acc + value)

main :: IO ()
main = do
  fixtures <- loadFixtures
  let artifacts = decodeAll fixtures
      largest = snd (maximum [(BS.length f, f) | f <- fixtures])
  value <- either (fail . T.unpack) pure (loadStrictJson largest)
  stories <- memberList "stories" <$> readJson (dataFile "generated-stories.json")
  let scripts = map (scriptOf . member "script") stories
  children <- memberList "children" <$> readJson (dataFile "process-vectors.json")
  (runSpec, progress) <- case [c | c <- children, memberText "scenario_id" c == "queue-story"] of
    child : _ -> do
      specValue <- either (fail . T.unpack) pure (loadStrictJson (textBytes (memberText "spec" child)))
      runSpec <- either (fail . show) pure (pProcessRunSpec [] specValue)
      pure (runSpec, textBytes (memberText "progress" child))
    [] -> fail "no queue-story vector"
  -- force the inputs before measuring
  _ <- pure $! length (encodeAll artifacts)
  defaultMain
    [ bgroup
        "codec"
        [ bench "decode+encode 51 fixtures" $ nf roundTrip fixtures
        , bench "encode 51 fixtures" $ nf encodeAll artifacts
        ]
    , bench "digest_json largest fixture" $ nf (either (error . T.unpack) id . digestJson) value
    , bench "1000 workload draws" $ nf draws 1000
    , bench "author+replay 400 generated scripts" $ nfIO (authorAll scripts)
    , bench "fold queue-story progress" $
        nf (\bytes -> encodeProcessRunResult (processResult runSpec 0 Exited False (Just bytes))) progress
    ]
