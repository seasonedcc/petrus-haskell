{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Durable admission routing for configured installation accounts
-- (@github_app/routing.py@), over the same SQLite schema.
module Hamsterdan.GitHub.Routing
  ( Route (..)
  , InstallationRegistry
  , openRegistry
  , closeRegistry
  , installation
  , repositories
  , route
  , reconcile
  , activeCount
  , activeInstallationCount
  , validRepository
  , InventoryMismatch (..)
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM_, unless, when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Config (AccountConfig (..))
import Hamsterdan.GitHub.Models (InstallationInventory (..))
import Hamsterdan.GitHub.Python (PythonFault (..), isAscii, isPrintable, strip)
import Hamsterdan.GitHub.Sqlite (Connection, SQLData (..))
import Hamsterdan.GitHub.Sqlite qualified as Db
import Petrus.Json (Json (..), jsonTypeName)

data Route = Route
  { installationId :: Integer
  , accountId :: Integer
  , repositoryId :: Integer
  , repositoryFullName :: Text
  }
  deriving stock (Eq, Show)

-- | @ValueError@ from 'reconcile': the provider inventory does not match the
-- configured accounts.
newtype InventoryMismatch = InventoryMismatch Text
  deriving stock (Eq, Show)

instance Exception InventoryMismatch

data InstallationRegistry = InstallationRegistry
  { allowed :: Map Integer (Map Integer Text)
  , connection :: Connection
  }

-- | @InstallationRegistry(path, accounts=...)@.
openRegistry :: FilePath -> [AccountConfig] -> IO InstallationRegistry
openRegistry path accounts = do
  connection <- Db.open (T.pack path)
  Db.script
    connection
    "\n\
    \            PRAGMA journal_mode=WAL;\n\
    \            CREATE TABLE IF NOT EXISTS installations (\n\
    \              installation_id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL, active INTEGER NOT NULL);\n\
    \            CREATE TABLE IF NOT EXISTS repositories (\n\
    \              installation_id INTEGER NOT NULL, repository_id INTEGER NOT NULL, full_name TEXT NOT NULL,\n\
    \              active INTEGER NOT NULL, PRIMARY KEY (installation_id, repository_id));\n\
    \        "
  pure
    InstallationRegistry
      { allowed = Map.fromList [(account.accountId, Map.fromList account.repositories) | account <- accounts]
      , connection
      }

closeRegistry :: InstallationRegistry -> IO ()
closeRegistry registry = Db.close registry.connection

-- | @type(value) is int and value > 0@.
validId :: Json -> Maybe Integer
validId = \case
  Int n | n > 0 -> Just n
  _ -> Nothing

int :: Integer -> SQLData
int = SQLInteger . fromInteger

-- | Apply an @installation@ lifecycle action. The arguments are the
-- observation's provider values; 'False' means the action was inert.
--
-- An unhashable action (a list or object) fails exactly where CPython's
-- set membership test raises @TypeError@.
installation :: InstallationRegistry -> Json -> Json -> Json -> IO Bool
installation registry action installationValue accountValue =
  case (validId installationValue, validId accountValue) of
    (Just installationId, Just accountId)
      | Map.member accountId registry.allowed ->
          Db.withLock registry.connection $ Db.transaction registry.connection $ do
            existing <- Db.query registry.connection "SELECT account_id FROM installations WHERE installation_id=?" [int installationId]
            case existing of
              [[SQLInteger owner]] | toInteger owner /= accountId -> pure False
              _ -> apply installationId accountId
    _ -> pure False
  where
    connection = registry.connection
    apply installationId accountId = case action of
      String name
        | name `elem` ["created", "unsuspend", "new_permissions_accepted"] -> do
            _ <-
              Db.execute
                connection
                "DELETE FROM repositories WHERE installation_id IN \
                \(SELECT installation_id FROM installations WHERE account_id=? AND installation_id<>?)"
                [int accountId, int installationId]
            _ <- Db.execute connection "DELETE FROM installations WHERE account_id=? AND installation_id<>?" [int accountId, int installationId]
            _ <-
              Db.execute
                connection
                "INSERT INTO installations VALUES (?, ?, 1) ON CONFLICT(installation_id) DO UPDATE SET account_id=excluded.account_id, active=1"
                [int installationId, int accountId]
            pure True
        | name == "suspend" -> do
            _ <- Db.execute connection "UPDATE installations SET active=0 WHERE installation_id=? AND account_id=?" [int installationId, int accountId]
            pure True
        | name == "deleted" -> do
            _ <-
              Db.execute
                connection
                "DELETE FROM repositories WHERE installation_id IN \
                \(SELECT installation_id FROM installations WHERE installation_id=? AND account_id=?)"
                [int installationId, int accountId]
            _ <- Db.execute connection "DELETE FROM installations WHERE installation_id=? AND account_id=?" [int installationId, int accountId]
            pure True
      Array _ -> unhashable
      Object _ -> unhashable
      _ -> pure False
    unhashable = throwIO (unhashableAction action)

-- | CPython 3.14's @TypeError@ for a list or object action tested for
-- membership in a set literal.
unhashableAction :: Json -> PythonFault
unhashableAction value =
  PythonFault "TypeError" ("cannot use '" <> name <> "' as a set element (unhashable type: '" <> name <> "')")
  where
    name = jsonTypeName value

-- | @_valid_repository@: a positive integer id and an ASCII, printable
-- @owner/name@ whose parts carry no surrounding whitespace.
validRepository :: (Json, Json) -> Maybe (Integer, Text)
validRepository (repositoryValue, nameValue) = do
  repositoryId <- validId repositoryValue
  fullName <- case nameValue of
    String s -> Just s
    _ -> Nothing
  let parts = T.splitOn "/" fullName
  unless
    ( T.length fullName >= 1
        && T.length fullName <= 201
        && isAscii fullName
        && isPrintable fullName
        && length parts == 2
        && all (\part -> not (T.null part) && strip part == part) parts
    )
    Nothing
  Just (repositoryId, fullName)

-- | Apply an @installation_repositories@ action (@added@ or @removed@).
repositories :: InstallationRegistry -> Json -> Json -> Json -> [(Json, Json)] -> IO Bool
repositories registry action installationValue accountValue items = do
  name <- case action of
    String s -> pure (Just s)
    Array _ -> throwIO (unhashableAction action)
    Object _ -> throwIO (unhashableAction action)
    _ -> pure Nothing
  case (name, validId installationValue, validId accountValue, traverse validRepository items) of
    (Just verb, Just installationId, Just accountId, Just valid)
      | verb `elem` ["added", "removed"]
      , Just admitted <- Map.lookup accountId registry.allowed ->
          Db.withLock registry.connection $ Db.transaction registry.connection $ do
            exists <- installationExists installationId accountId
            if not exists
              then pure False
              else do
                forM_ valid $ \(repositoryId, fullName) -> do
                  let lowered = T.toLower fullName
                  if verb == "added" && Map.lookup repositoryId admitted == Just lowered
                    then
                      () <$ Db.execute
                        registry.connection
                        "INSERT INTO repositories VALUES (?, ?, ?, 1) ON CONFLICT(installation_id, repository_id) DO UPDATE SET full_name=excluded.full_name, active=1"
                        [int installationId, int repositoryId, SQLText lowered]
                    else
                      when (verb == "removed") $
                        () <$ Db.execute
                          registry.connection
                          "DELETE FROM repositories WHERE installation_id=? AND repository_id=?"
                          [int installationId, int repositoryId]
                pure True
    _ -> pure False
  where
    installationExists installationId accountId =
      not . null
        <$> Db.query
          registry.connection
          "SELECT 1 FROM installations WHERE installation_id=? AND account_id=?"
          [int installationId, int accountId]

-- | @route(installation_id, repository_id)@.
route :: InstallationRegistry -> Integer -> Integer -> IO (Maybe Route)
route registry installationId repositoryId = Db.withLock registry.connection $ do
  rows <-
    Db.query
      registry.connection
      "SELECT i.account_id, r.full_name FROM installations i JOIN repositories r USING (installation_id) \
      \WHERE i.installation_id=? AND r.repository_id=? AND i.active=1 AND r.active=1"
      [int installationId, int repositoryId]
  pure $ case rows of
    [SQLInteger account, SQLText fullName] : _ -> Just (Route installationId (toInteger account) repositoryId fullName)
    _ -> Nothing

-- | Atomically replace every configured installation and repository route.
reconcile :: InstallationRegistry -> [InstallationInventory] -> IO Int
reconcile registry installations = do
  let installationIds = Set.fromList (map (.installationId) installations)
      accountIds = Set.fromList (map (.accountId) installations)
  when
    ( Set.size installationIds /= length installations
        || Set.size accountIds /= length installations
        || accountIds /= Map.keysSet registry.allowed
    )
    $ throwIO (InventoryMismatch "registration inventory does not match configured accounts")
  admitted <- fmap concat . traverse admit $ installations
  Db.withLock registry.connection $ Db.transaction registry.connection $ do
    _ <- Db.execute registry.connection "DELETE FROM repositories" []
    _ <- Db.execute registry.connection "DELETE FROM installations" []
    forM_ installations $ \item ->
      Db.execute registry.connection "INSERT INTO installations VALUES (?, ?, 1)" [int item.installationId, int item.accountId]
    forM_ admitted $ \(installationId, repositoryId, fullName) ->
      Db.execute registry.connection "INSERT INTO repositories VALUES (?, ?, ?, 1)" [int installationId, int repositoryId, SQLText fullName]
  pure (length admitted)
  where
    admit item = do
      when (item.installationId <= 0) $ throwIO (InventoryMismatch "registration inventory is malformed")
      let observed =
            Map.fromList
              [ (repositoryId, T.toLower fullName)
              | (repositoryId, fullName) <- item.repositories
              , Just _ <- [validRepository (Int repositoryId, String fullName)]
              ]
          allowedRepositories = Map.findWithDefault Map.empty item.accountId registry.allowed
      when (any (\(repositoryId, fullName) -> Map.lookup repositoryId observed /= Just fullName) (Map.toList allowedRepositories)) $
        throwIO (InventoryMismatch "registration inventory does not contain every configured repository")
      pure [(item.installationId, repositoryId, fullName) | (repositoryId, fullName) <- Map.toList allowedRepositories]

-- | Active repository routes.
activeCount :: InstallationRegistry -> IO Int
activeCount registry = Db.withLock registry.connection $ do
  rows <-
    Db.query
      registry.connection
      "SELECT count(*) FROM repositories r JOIN installations i USING(installation_id) WHERE r.active=1 AND i.active=1"
      []
  pure $ case rows of
    [SQLInteger n] : _ -> fromIntegral n
    _ -> 0

-- | Active installations.
activeInstallationCount :: InstallationRegistry -> IO Int
activeInstallationCount registry = Db.withLock registry.connection $ do
  rows <- Db.query registry.connection "SELECT count(*) FROM installations WHERE active=1" []
  pure $ case rows of
    [SQLInteger n] : _ -> fromIntegral n
    _ -> 0
