-- | Schema creation and upstream's schema checks.
--
-- SQLite stores the text of each @CREATE@ statement in @sqlite_master.sql@,
-- and upstream validates an existing database by comparing that text
-- (whitespace collapsed, lowercased) with its own DDL, plus the
-- @PRAGMA table_info@/@index_info@/@foreign_key_list@ rows. A Haskell writer
-- must therefore create its tables from the /same strings/: copy upstream's
-- DDL verbatim and run it with 'createSchema', which executes each statement
-- as written so @sqlite_master.sql@ is byte-identical to what Python
-- produces.
module Petrus.Sqlite.Schema
  ( -- * Creating
    createSchema

    -- * Text comparison
  , normalizeDdl
  , pythonIsSpace
  , ddlMatches
  , schemaObjects
  , objectSql

    -- * PRAGMA readers
  , ColumnInfo (..)
  , tableInfo
  , IndexColumn (..)
  , indexInfo
  , ForeignKey (..)
  , foreignKeyList
  , userVersion
  , quickCheck
  ) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Python (isPythonSpace, pythonLower)
import Petrus.Sqlite.Connection (Connection, SQLData (..), execute_, query, queryFirst)

-- | Execute each statement verbatim, in order (inside whatever transaction
-- the caller holds; upstream creates its schema under @BEGIN IMMEDIATE@).
createSchema :: Connection -> [Text] -> IO ()
createSchema connection = mapM_ (execute_ connection)

-- | Python's @str.isspace@, which is also what @\\s@ matches in a @str@
-- regular expression and what @str.strip()@ removes (petrus-json's
-- CPython 3.14 table).
pythonIsSpace :: Char -> Bool
pythonIsSpace = isPythonSpace

-- | Upstream's @normalize@: @re.sub(r"\\s+", " ", sql.strip()).lower()@,
-- with CPython's @str.lower@ (Unicode 16.0, the final-sigma rule).
normalizeDdl :: Text -> Text
normalizeDdl = pythonLower . T.intercalate " " . filter (not . T.null) . T.split pythonIsSpace

-- | Whether two name-to-DDL maps are equal after 'normalizeDdl' (upstream
-- compares the dictionaries, so a missing or extra object is a mismatch).
ddlMatches :: Map Text Text -> Map Text Text -> Bool
ddlMatches expected actual = Map.map normalizeDdl expected == Map.map normalizeDdl actual

-- | @dict(SELECT name, type FROM sqlite_master WHERE name LIKE ?)@ with the
-- given @LIKE@ pattern (for example @impetus_history_%@).
schemaObjects :: Connection -> Text -> IO (Map Text Text)
schemaObjects connection pattern = do
  rows <- query connection "SELECT name, type FROM sqlite_master WHERE name LIKE ?" [SQLText pattern]
  pure (Map.fromList [(name, kind) | [SQLText name, SQLText kind] <- rows])

-- | The stored @sql@ of the named objects that exist (@NULL@ for automatic
-- indexes is skipped).
objectSql :: Connection -> [Text] -> IO (Map Text Text)
objectSql connection names = do
  rows <- query connection "SELECT name, sql FROM sqlite_master" []
  let wanted = Map.fromList [(name, ()) | name <- names]
  pure (Map.fromList [(name, sql) | [SQLText name, SQLText sql] <- rows, Map.member name wanted])

-- | One row of @PRAGMA table_info(table)@.
data ColumnInfo = ColumnInfo
  { columnId :: Int64
  , columnName :: Text
  , columnType :: Text
  , columnNotNull :: Bool
  , columnDefault :: Maybe Text
  -- ^ The default's SQL text, as SQLite reports it.
  , columnPrimaryKey :: Int64
  -- ^ 0, or the column's 1-based position in the primary key.
  }
  deriving stock (Eq, Show)

-- | @PRAGMA table_info(table)@ (the table name is interpolated as upstream
-- does; pass constants).
tableInfo :: Connection -> Text -> IO [ColumnInfo]
tableInfo connection table = do
  rows <- query connection ("PRAGMA table_info(" <> table <> ")") []
  pure
    [ ColumnInfo cid name kind (notnull /= 0) (textOrNull dflt) pk
    | [SQLInteger cid, SQLText name, SQLText kind, SQLInteger notnull, dflt, SQLInteger pk] <- rows
    ]

-- | One row of @PRAGMA index_info(index)@.
data IndexColumn = IndexColumn
  { indexRank :: Int64
  , indexColumnId :: Int64
  , indexColumnName :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @PRAGMA index_info(index)@.
indexInfo :: Connection -> Text -> IO [IndexColumn]
indexInfo connection index = do
  rows <- query connection ("PRAGMA index_info(" <> index <> ")") []
  pure [IndexColumn rank cid (textOrNull name) | [SQLInteger rank, SQLInteger cid, name] <- rows]

-- | One row of @PRAGMA foreign_key_list(table)@.
data ForeignKey = ForeignKey
  { foreignKeyId :: Int64
  , foreignKeySeq :: Int64
  , foreignKeyTable :: Text
  , foreignKeyFrom :: Text
  , foreignKeyTo :: Maybe Text
  , foreignKeyOnUpdate :: Text
  , foreignKeyOnDelete :: Text
  , foreignKeyMatch :: Text
  }
  deriving stock (Eq, Show)

-- | @PRAGMA foreign_key_list(table)@.
foreignKeyList :: Connection -> Text -> IO [ForeignKey]
foreignKeyList connection table = do
  rows <- query connection ("PRAGMA foreign_key_list(" <> table <> ")") []
  pure
    [ ForeignKey fid fseq target from (textOrNull to) onUpdate onDelete match
    | [SQLInteger fid, SQLInteger fseq, SQLText target, SQLText from, to, SQLText onUpdate, SQLText onDelete, SQLText match] <- rows
    ]

-- | @PRAGMA user_version@.
userVersion :: Connection -> IO Int64
userVersion connection =
  queryFirst connection "PRAGMA user_version" [] >>= \case
    Just [SQLInteger version] -> pure version
    _ -> pure 0

-- | @PRAGMA quick_check@'s first row (@ok@ for a sound database).
quickCheck :: Connection -> IO (Maybe Text)
quickCheck connection =
  queryFirst connection "PRAGMA quick_check" [] >>= \case
    Just [SQLText result] -> pure (Just result)
    _ -> pure Nothing

textOrNull :: SQLData -> Maybe Text
textOrNull = \case
  SQLText text -> Just text
  _ -> Nothing
