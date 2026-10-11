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
import Spec.EngineWorlds (AuthorCase (..), authorCases, replayCases, replayFixture)
import Spec.JoinedWorlds (JoinedCase (..), fixtureBytes, isolated, joinedCases)
import Petrus.TestSupport.Postgres (lookupPostgresUrl)
import Spec.Support
import System.Directory (listDirectory)
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (localOption)
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

-- | Replay every supported non-joined fixture through fresh real Engine
-- profiles (a fresh scratch directory and History per fixture); the replay
-- result bytes.
replayEngineFixtures :: IO [Text]
replayEngineFixtures = forM replayCases (fmap (canonText . replayJson) . replayFixture)

-- | Author every Engine world the reference's builders author, in a fresh
-- scratch directory each; the artifact bytes.
authorEngineWorlds :: IO [ByteString]
authorEngineWorlds = forM authorCases $ \c -> do
  authored <- withSystemTempDirectory "petrus-dst-bench" c.build
  pure (either (error . show) (either (error . T.unpack) id . encodeArtifact) authored)

-- | Replay every joined fixture through a fresh profile in a fresh
-- isolated database (@isolated_absurd_database@); the replay result bytes.
replayJoinedFixtures :: ByteString -> IO [Text]
replayJoinedFixtures server = forM joinedCases $ \c -> do
  bytes <- fixtureBytes c.file
  artifact <- either (fail . show) pure (decodeArtifact bytes)
  outcome <- isolated server $ \dsn -> do
    registry <- c.registry dsn
    replay registry artifact
  pure (canonText (replayJson outcome))

-- | Author every joined world in a fresh isolated database; the artifact
-- bytes.
authorJoinedWorlds :: ByteString -> IO [ByteString]
authorJoinedWorlds server = forM joinedCases $ \c -> do
  authored <- isolated server c.build
  pure (either (error . show) (either (error . T.unpack) id . encodeArtifact) authored)

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
  server <- lookupPostgresUrl
  -- force the inputs before measuring
  _ <- pure $! length (encodeAll artifacts)
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
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
    , bgroup
        "engine"
        [ bench "replay the Engine-world fixtures" $ nfIO replayEngineFixtures
        , bench "author the Engine worlds" $ nfIO authorEngineWorlds
        ]
    , -- Only with PETRUS_TEST_POSTGRES (a role that may create databases).
      bgroup
        "joined"
        ( case server of
            Nothing -> []
            Just url ->
              [ bench "one isolated database (create, both schemas, drop)" $ nfIO (isolated url (\_ -> pure ()))
              , bench "replay the 33 joined fixtures" $ nfIO (replayJoinedFixtures url)
              , bench "author the 33 joined worlds" $ nfIO (authorJoinedWorlds url)
              ]
        )
    ]
