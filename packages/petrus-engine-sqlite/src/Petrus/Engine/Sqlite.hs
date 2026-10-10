-- | The fenced local SQLite Engine (@petrus.engine.sqlite@, docs/runtime.md
-- §14.2): one Engine per Instance per database file, composed through the
-- provider seam ("Petrus.Engine.Provider").
--
-- 'createEngine' / 'loadEngine' take the writer fence first (a non-blocking
-- BSD @flock@ shared with Python Engines on the same file, see
-- "Petrus.Sqlite.WriterFence"), then open the SQLite History store
-- ("Petrus.HistoryStore.Sqlite"), then hand both to the Engine:
--
-- * @release@ drops the fence and @close@ closes the History connection —
--   on 'Petrus.Engine.close' or when a writing door poisons the Engine;
-- * @ensure@ runs before every door and refuses an Engine used from a
--   process other than the one that opened it ('InheritedAcrossFork');
-- * there is no commit point: every History append is durable at the door
--   ('Petrus.Impetus.HistoryStore.BackendOwned').
--
-- A construction failure (the fence held elsewhere, a refused History file,
-- a refused create or load) releases everything it took before it
-- propagates.
--
-- The Dispatch is the caller's: the Engine's 'Petrus.Motus.Dispatch.Dispatch'
-- is any port — inline, in-memory, or the durable Local Dispatch
-- ("Petrus.Motus.Dispatch.Local"), whose tables may share the History's
-- database file.
module Petrus.Engine.Sqlite
  ( createEngine
  , loadEngine
  , openSqliteEngine
  , OpenMode (..)
    -- * Refusals
  , FenceError (..)
  , fenceErrorMessage
  ) where

import Control.Exception (mask, onException)
import Data.Text (Text)
import Petrus.Engine (Engine, EngineOptions)
import Petrus.Engine.Provider (EngineResources (..), OpenMode (..), defaultResources, openEngine)
import Petrus.HistoryStore.Sqlite (SqliteHistoryStore (..), openSqliteHistoryStore)
import Petrus.Impetus.Petrinet (Net)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Sqlite.WriterFence (FenceError (..), acquireWriterFence, ensureWriterFence, fenceErrorMessage, releaseWriterFence)

-- | @create_engine(path, net, instance, dispatch=..., **options)@: create
-- and host one Instance through the fenced local SQLite route.
createEngine :: FilePath -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
createEngine = openSqliteEngine CreateInstance

-- | @load_engine(path, net, instance, dispatch=..., **options)@: load and
-- host one Instance through the fenced local SQLite route.
loadEngine :: FilePath -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
loadEngine = openSqliteEngine LoadInstance

-- | @_open_engine@: fence before loading History, then transfer both
-- resources to the Engine.
openSqliteEngine :: OpenMode -> FilePath -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
openSqliteEngine mode path net instanceId port options = mask $ \restore -> do
  fence <- acquireWriterFence path instanceId
  store <- restore (openSqliteHistoryStore path instanceId) `onException` releaseWriterFence fence
  let resources =
        defaultResources
          { release = releaseWriterFence fence
          , close = store.close
          , ensure = ensureWriterFence fence
          }
  -- 'openEngine' rolls back, releases and closes on its own failure.
  restore (openEngine mode net instanceId store.history port options resources)
