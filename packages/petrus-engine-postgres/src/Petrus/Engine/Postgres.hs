-- | PostgreSQL History construction doors for the neutral Engine (the
-- reference's @petrus.engine.postgres@).
--
-- > import Petrus.Engine qualified as Engine
-- > import Petrus.Engine.Postgres qualified as Postgres
-- >
-- > connection <- Petrus.Postgres.connect dsn False   -- join mode
-- > engine <- Postgres.createEngine connection net "order-1" dispatch Engine.defaultEngineOptions
--
-- Each door takes a join-mode connection (@autocommit=False@) and hands it
-- to the Engine, which then owns the joined transaction, the writer fence,
-- rollback, and poisoning: History appends ride the connection's
-- transaction and the Engine commits at its commit points; the
-- session-level authority fence ('Petrus.Postgres.Fence') keeps every other
-- writer — Haskell or Python — off the instance until the Engine closes or
-- its connection ends. The doors return the plain 'Engine'.
--
-- The connection is closed on every construction failure (an autocommit
-- connection, a held fence, a missing schema, a refused load or create), so
-- a caller never has to clean up after a refused door. The schema is never
-- provisioned here: run 'Petrus.HistoryStore.Postgres.ensureSchema' first,
-- deliberately.
module Petrus.Engine.Postgres
  ( -- * Doors
    createEngine
  , loadEngine
  , withEngine

    -- * Supplying the transaction's fate
  , PostgresSession (..)
  , postgresSession
  , openPostgresEngine
  ) where

import Control.Exception (bracket, throwIO)
import Control.Monad (when)
import Data.Text (Text)
import Petrus.Engine (Engine, EngineError (..), EngineOptions)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres.Joined (JoinedProvider (..), joinedProvider, openJoinedEngine)
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Impetus.Petrinet (Net)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Postgres (Connection, autocommit)
import Petrus.Postgres qualified as Pg

-- | The joined connection and the two acts the Engine performs on it at
-- its boundaries. 'postgresSession' gives the connection's own; a host can
-- wrap them (to count commits, or to observe them).
data PostgresSession = PostgresSession
  { connection :: Connection
  , commit :: IO ()
  , close :: IO ()
  }

-- | The connection's own commit and close.
postgresSession :: Connection -> PostgresSession
postgresSession connection = PostgresSession {connection, commit = Pg.commit connection, close = Pg.close connection}

-- | @create_engine(connection, net, instance, dispatch=…, **options)@:
-- create and host one previously absent Instance.
createEngine :: Connection -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
createEngine connection = openPostgresEngine (postgresSession connection) CreateInstance

-- | @load_engine(connection, net, instance, dispatch=…, **options)@: load
-- and host one existing Instance.
loadEngine :: Connection -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
loadEngine connection = openPostgresEngine (postgresSession connection) LoadInstance

-- | Open (create or load), run, and close the Engine — which releases the
-- fence and closes the connection.
withEngine :: OpenMode -> Connection -> Net -> Text -> Dispatch -> EngineOptions -> (Engine -> IO a) -> IO a
withEngine mode connection net instanceId port options =
  bracket (openPostgresEngine (postgresSession connection) mode net instanceId port options) Engine.close

-- | The doors over a session.
openPostgresEngine :: PostgresSession -> OpenMode -> Net -> Text -> Dispatch -> EngineOptions -> IO Engine
openPostgresEngine session mode net instanceId port =
  openJoinedEngine
    (joinedProvider session.connection port)
      { validate = do
          mode' <- autocommit session.connection
          when mode' $
            throwIO
              ( EngineValueError
                  "PostgreSQL Engine construction requires an autocommit=False connection: the Engine owns the joined transaction, writer fence, rollback, and poison fate"
              )
      , commit = session.commit
      , closeConnections = session.close
      }
    mode
    net
    instanceId
