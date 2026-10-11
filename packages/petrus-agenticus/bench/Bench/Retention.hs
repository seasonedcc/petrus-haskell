-- | Territory custody hot paths; the twin of @bench/python_retention.py@.
--
-- * @decode-row-x1000@: decode one retained row (with a 4 KiB archive and its
--   digest check) 1000 times.
-- * @ledger-lookup-x200@: run 200 @lookup@ calls against a ledger holding
--   100 retained records.
-- * @ledger-recover-100@: run @recover@ over the same 100 records. It runs
--   one write transaction and decodes all of them.
module Bench.Retention (benchmarks, withLedger) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Attachment.Retention
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty.Bench

archiveBytes :: B.ByteString
archiveBytes = B.replicate 4096 120

row :: Int -> [SqlValue]
row i =
  [ SQLText ("custody-" <> n)
  , SQLText "host-one"
  , SQLInteger 1
  , SQLText "retained"
  , SQLText "episode-a"
  , SQLText "attachment-a"
  , SQLInteger 3
  , SQLText ("operation-" <> n)
  , SQLText "local"
  , SQLText ("lease-" <> n)
  , SQLText "[\"command-cancellation\",\"process-group\",\"workspace\"]"
  , SQLFloat 1.0e12
  , SQLBlob archiveBytes
  , SQLText (sha256Hex archiveBytes)
  , SQLNull
  , SQLNull
  , SQLNull
  , SQLNull
  ]
  where
    n = T.pack (show i)

-- | A ledger with 100 retained rows.
withLedger :: (SqliteTerritoryCustody -> IO a) -> IO a
withLedger action = withSystemTempDirectory "retention-bench" $ \tmp -> do
  let dir = tmp </> "custody"
  createDirectory dir
  setFileMode dir 0o700
  let path' = dir </> "territories.db"
  openTerritoryCustodyWith path' (pure 10) >>= closeTerritoryCustody
  db <- openDatabase path'
  let insert = "INSERT INTO territory_custody VALUES (" <> T.intercalate ", " (replicate 18 "?") <> ")"
  forM_ [1 .. 100 :: Int] (runSql db insert . row)
  closeDatabase db
  bracket (openTerritoryCustodyWith path' (pure 10)) closeTerritoryCustody action

decodeMany :: Int -> Int
decodeMany n = length [() | i <- [1 .. n], Right _ <- [decodeCustodyRow (row (i `mod` 100 + 1))]]

lookups :: SqliteTerritoryCustody -> IO Int
lookups custody = do
  found <- mapM (\i -> lookupCustody custody (ids !! (i `mod` 100))) [0 .. 199 :: Int]
  pure (length [() | Just _ <- found])
  where
    ids :: [Text]
    ids = ["custody-" <> T.pack (show i) | i <- [1 .. 100 :: Int]]

benchmarks :: SqliteTerritoryCustody -> Benchmark
benchmarks custody =
  bgroup
    "retention"
    [ bench "decode-row-x1000" (whnf decodeMany 1000)
    , bench "ledger-lookup-x200" (whnfIO (lookups custody))
    , bench "ledger-recover-100" (whnfIO (length <$> recover custody))
    ]
