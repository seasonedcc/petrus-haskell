-- | A PostgreSQL resource for test suites.
--
-- Tests that need PostgreSQL read a libpq connection string (URI or
-- @key=value@ form) from the @PETRUS_TEST_POSTGRES@ environment variable.
-- CI's @postgres:17@ service sets it; locally, point it at any server where
-- the role may create databases, for example
-- @PETRUS_TEST_POSTGRES=postgresql://localhost:5432/postgres@ with
-- Postgres.app.
--
-- Each run gets a fresh scratch database (@petrus_test_<pid>_<random>@),
-- created through the configured connection and dropped (@WITH (FORCE)@)
-- afterwards, so suites never see each other's tables and never touch the
-- configured database itself. When the variable is unset or empty, the
-- tests are reported as pending with a message saying so, never silently
-- passed; CI always sets it, so a skip there is impossible.
module Petrus.TestSupport.Postgres
  ( -- * The resource
    PostgresTarget (..)
  , postgresEnvVar
  , lookupPostgresUrl
  , withScratchDatabase

    -- * hspec integration
  , postgresSpec
  , skipMessage
  ) where

import Control.Exception (Exception, bracket, throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Database.PostgreSQL.LibPQ qualified as PQ
import Numeric (showHex)
import System.Environment (lookupEnv)
import System.Posix.Process (getProcessID)
import System.Random (randomIO)
import Test.Hspec (Spec, SpecWith, around, aroundAll, pendingWith, runIO)

-- | A scratch database prepared for one test run.
data PostgresTarget = PostgresTarget
  { targetUrl :: ByteString
  -- ^ A libpq @key=value@ connection string for the scratch database.
  , targetDatabase :: ByteString
  -- ^ The scratch database's name.
  , adminUrl :: ByteString
  -- ^ The configured connection string (@PETRUS_TEST_POSTGRES@).
  }
  deriving stock (Show)

-- | A failure to prepare or remove the scratch database.
newtype PostgresSetupFailure = PostgresSetupFailure String
  deriving stock (Show)

instance Exception PostgresSetupFailure

-- | @PETRUS_TEST_POSTGRES@.
postgresEnvVar :: String
postgresEnvVar = "PETRUS_TEST_POSTGRES"

-- | The configured connection string, if any (an empty value counts as
-- unset).
lookupPostgresUrl :: IO (Maybe ByteString)
lookupPostgresUrl =
  lookupEnv postgresEnvVar >>= \case
    Just url | not (null url) -> pure (Just (BC.pack url))
    _ -> pure Nothing

-- | The pending message used when the variable is unset.
skipMessage :: String
skipMessage =
  postgresEnvVar
    ++ " is unset: PostgreSQL tests did not run. Set it to a libpq connection string for a server where the role may create databases (CI sets it)."

-- | Create a scratch database through the given connection string, run the
-- action against it, and drop it afterwards (even when the action fails).
withScratchDatabase :: ByteString -> (PostgresTarget -> IO a) -> IO a
withScratchDatabase url action = do
  pid <- getProcessID
  suffix <- randomIO :: IO Word
  let name = BC.pack ("petrus_test_" ++ show pid ++ "_" ++ showHex suffix "")
  bracket (create name) (const (drop' name)) action
  where
    create name = withAdmin $ \admin -> do
      exec admin ("CREATE DATABASE " <> quoteIdentifier name)
      parts <- connectionParts admin
      pure
        PostgresTarget
          { targetUrl = conninfo (parts ++ [("dbname", name)])
          , targetDatabase = name
          , adminUrl = url
          }
    drop' name = withAdmin $ \admin ->
      exec admin ("DROP DATABASE IF EXISTS " <> quoteIdentifier name <> " WITH (FORCE)")
    withAdmin :: (PQ.Connection -> IO b) -> IO b
    withAdmin = bracket open PQ.finish
    open = do
      connection <- PQ.connectdb url
      status <- PQ.status connection
      unless (status == PQ.ConnectionOk) $ do
        problem <- PQ.errorMessage connection
        PQ.finish connection
        throwIO (PostgresSetupFailure ("cannot connect with " ++ postgresEnvVar ++ ": " ++ maybe "" BC.unpack problem))
      pure connection

-- | hspec: run the given tests against one scratch database shared by the
-- whole group, or mark them pending with 'skipMessage' when
-- @PETRUS_TEST_POSTGRES@ is unset.
postgresSpec :: SpecWith PostgresTarget -> Spec
postgresSpec spec = do
  url <- runIO lookupPostgresUrl
  case url of
    Nothing -> around (\_ -> pendingWith skipMessage) spec
    Just configured -> aroundAll (withScratchDatabase configured) spec

exec :: PQ.Connection -> ByteString -> IO ()
exec connection statement = do
  result <- PQ.exec connection statement
  status <- maybe (pure PQ.FatalError) PQ.resultStatus result
  unless (status == PQ.CommandOk || status == PQ.TuplesOk) $ do
    problem <- maybe (PQ.errorMessage connection) PQ.resultErrorMessage result
    throwIO (PostgresSetupFailure (BC.unpack statement ++ ": " ++ maybe "" BC.unpack problem))

-- The host, port, user and password the admin connection actually used.
connectionParts :: PQ.Connection -> IO [(ByteString, ByteString)]
connectionParts connection = do
  host <- PQ.host connection
  port <- PQ.port connection
  user <- PQ.user connection
  password <- PQ.pass connection
  pure
    [ (key, value)
    | (key, Just value) <- [("host", host), ("port", port), ("user", user), ("password", password)]
    , not (BS.null value)
    ]

-- A libpq key=value connection string with every value quoted.
conninfo :: [(ByteString, ByteString)] -> ByteString
conninfo = BC.unwords . map (\(key, value) -> key <> "='" <> escape value <> "'")
  where
    escape = BC.concatMap (\c -> if c == '\'' || c == '\\' then BC.pack ['\\', c] else BC.singleton c)

quoteIdentifier :: ByteString -> ByteString
quoteIdentifier name = "\"" <> BC.concatMap (\c -> if c == '"' then "\"\"" else BC.singleton c) name <> "\""
