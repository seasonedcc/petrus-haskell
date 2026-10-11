-- | PostgreSQL History plus Absurd Dispatch construction doors (the
-- reference's @petrus.engine.absurd@).
--
-- > import Petrus.Engine qualified as Engine
-- > import Petrus.Engine.Absurd qualified as Absurd
-- >
-- > joined <- Petrus.Postgres.connect dsn False   -- join mode
-- > listen <- Petrus.Postgres.connect dsn True    -- the dedicated listener
-- > engine <- Absurd.createEngine joined (Just listen) net "order-1"
-- >             Absurd.defaultAbsurdEngineOptions Engine.defaultEngineOptions
--
-- The composition is a 'JoinedProvider' ("Petrus.Engine.Postgres.Joined"):
-- the authority fence is taken on the joined connection before any History
-- is read, the PostgreSQL History store and the 'AbsurdDispatch' share that
-- connection's transaction (so a semantic begin, its
-- @absurd.spawn_task@ and its @impetus_dispatch@ doorbell commit or vanish
-- together), and 'Petrus.Engine.wait' is the Dispatch's
-- @wait_for_results@, which blocks only on the dedicated autocommit listen
-- connection (the @impetus_results@ doorbell plus the terminal probe), so
-- the joined connection never idles in a transaction while the driver
-- blocks.
--
-- Both connections are closed on every construction failure (a refused
-- precondition, a held fence, a missing schema, a refused load or create,
-- an invalid Absurd option), and by 'Petrus.Engine.close' (the listen
-- connection first, then the joined one). Neither schema is provisioned
-- here: run 'Petrus.HistoryStore.Postgres.ensureSchema' and
-- 'Petrus.Motus.Dispatch.Absurd.ensureAbsurdSchema' first, deliberately.
module Petrus.Engine.Absurd
  ( -- * Doors
    createEngine
  , loadEngine
  , withEngine

    -- * Options
  , AbsurdEngineOptions (..)
  , defaultAbsurdEngineOptions

    -- * Supplying the transaction's fate
  , AbsurdSession (..)
  , absurdSession
  , openAbsurdEngine
  , validateConnections
  ) where

import Control.Exception (bracket, finally, throwIO)
import Control.Monad (unless, when)
import Data.Text (Text)
import Petrus.Engine (Engine, EngineError (..), EngineOptions)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres.Joined (JoinedProvider (..), openJoinedEngine)
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.Petrinet (Net)
import Petrus.Motus.Dispatch.Absurd
  ( AbsurdDispatchOptions (..)
  , Session
  , absurdDispatchOver
  , defaultAbsurdDispatchOptions
  , sessionOf
  , toDispatch
  , waitForResults
  )
import Petrus.Postgres (Connection, autocommit, sameConnection)
import Petrus.Postgres qualified as Pg

-- | The provider's own keywords (@poll_interval=0.25@,
-- @default_queue="default"@, @activity_queues=None@); every other keyword
-- of the reference's @**options@ is an 'EngineOptions' field.
data AbsurdEngineOptions = AbsurdEngineOptions
  { pollInterval :: Double
  , defaultQueue :: Text
  , activityQueues :: [(Text, Text)]
  -- ^ Exact Activity name to queue overrides, in order.
  }

-- | The reference's defaults.
defaultAbsurdEngineOptions :: AbsurdEngineOptions
defaultAbsurdEngineOptions = AbsurdEngineOptions {pollInterval = 0.25, defaultQueue = "default", activityQueues = []}

-- | The joined connection, the listen connection, and the acts the Engine
-- performs on them. 'absurdSession' gives the connections' own; a host (or
-- a deterministic-simulation profile) can wrap any of them — the
-- reference's tests reach the same seams by wrapping the connection.
data AbsurdSession = AbsurdSession
  { connection :: Connection
  , listen :: Maybe Connection
  , commit :: IO ()
  , rollback :: IO ()
  , close :: IO ()
  -- ^ Close both connections: the listen connection, then the joined one.
  , dispatchSession :: Session
  -- ^ The statements the Absurd Dispatch runs on the joined connection.
  , observeHistory :: HistoryStore -> HistoryStore
  }

-- | The connections' own acts.
absurdSession :: Connection -> Maybe Connection -> AbsurdSession
absurdSession connection listen =
  AbsurdSession
    { connection
    , listen
    , commit = Pg.commit connection
    , rollback = Pg.rollback connection
    , close = closeConnections connection listen
    , dispatchSession = sessionOf connection
    , observeHistory = id
    }

-- | @_close_connections@: the listen connection first (when it is a
-- distinct connection), then the joined one, even when the first close
-- throws.
closeConnections :: Connection -> Maybe Connection -> IO ()
closeConnections connection = \case
  Just listening | not (sameConnection listening connection) -> Pg.close listening `finally` Pg.close connection
  _ -> Pg.close connection

-- | @_validate_connections@: the joined connection is in join mode, and the
-- listen connection is present, dedicated, and autocommit.
validateConnections :: Connection -> Maybe Connection -> IO ()
validateConnections connection listen = do
  joinMode <- not <$> autocommit connection
  unless joinMode $
    refuse
      "Absurd Engine construction requires an autocommit=False connection: the Engine owns the joined \
      \transaction that makes begin+dispatch commit-or-vanish \8212 an autocommit connection would commit \
      \each statement alone"
  case listen of
    Nothing ->
      refuse
        "Absurd Engine construction requires a dedicated autocommit listen connection: the results \
        \doorbell and every wait-time probe ride it, so the joined connection never idles in transaction \
        \while the driver blocks"
    Just listening -> do
      when (sameConnection listening connection) $
        refuse "Absurd Engine construction requires the listen connection to be dedicated, not the joined connection"
      listenMode <- autocommit listening
      unless listenMode $
        refuse "Absurd Engine construction requires the dedicated listen connection to use autocommit=True"
  where
    refuse = throwIO . EngineValueError

-- | @create_engine(connection, net, instance, listen=…, **options)@: create
-- and host one previously absent Instance.
createEngine :: Connection -> Maybe Connection -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> IO Engine
createEngine connection listen = openAbsurdEngine (absurdSession connection listen) CreateInstance

-- | @load_engine(connection, net, instance, listen=…, **options)@: load and
-- host one existing Instance.
loadEngine :: Connection -> Maybe Connection -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> IO Engine
loadEngine connection listen = openAbsurdEngine (absurdSession connection listen) LoadInstance

-- | Open (create or load), run, and close the Engine — which releases the
-- fence and closes both connections.
withEngine
  :: OpenMode -> Connection -> Maybe Connection -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> (Engine -> IO a) -> IO a
withEngine mode connection listen net instanceId absurdOptions options =
  bracket (openAbsurdEngine (absurdSession connection listen) mode net instanceId absurdOptions options) Engine.close

-- | The doors over a session ('openJoinedEngine' with the Absurd
-- composition).
openAbsurdEngine :: AbsurdSession -> OpenMode -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> IO Engine
openAbsurdEngine session mode net instanceId absurdOptions =
  openJoinedEngine provider mode net instanceId
  where
    provider :: JoinedProvider
    provider =
      JoinedProvider
        { connection = session.connection
        , validate = validateConnections session.connection session.listen
        , commit = session.commit
        , rollback = session.rollback
        , closeConnections = session.close
        , observeHistory = session.observeHistory
        , compose = \_ -> do
            adapter <-
              absurdDispatchOver
                session.dispatchSession
                instanceId
                defaultAbsurdDispatchOptions
                  { listen = session.listen
                  , pollInterval = absurdOptions.pollInterval
                  , defaultQueue = absurdOptions.defaultQueue
                  , activityQueues = absurdOptions.activityQueues
                  }
            pure (toDispatch adapter, Just (waitForResults adapter))
        }
