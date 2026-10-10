-- | The joined-transaction composition shared by every PostgreSQL Engine
-- provider: the PostgreSQL provider ("Petrus.Engine.Postgres", the
-- reference's @petrus.engine.postgres@) and the Absurd provider (the
-- reference's @petrus.engine.absurd@, which builds its Dispatch on the same
-- connection).
--
-- = What 'openJoinedEngine' does, in order
--
-- 1. Runs the provider's 'validate' (its connection preconditions).
-- 2. Takes the authority fence for the instance on the joined connection
--    (@SELECT pg_try_advisory_lock(%s)@, "Petrus.Postgres.Fence") /before/
--    any History is read: no writer reads History without authority. On a
--    join-mode connection that statement opens the transaction that then
--    also covers the History load and the Instance's construction or resume,
--    up to the Engine's construction commit.
-- 3. Loads the History store on the same connection (joined:
--    'Petrus.Impetus.HistoryStore.JoinedTransaction').
-- 4. Asks the provider to 'compose' its Dispatch (and an optional wake hint
--    for 'Petrus.Engine.wait') over the loaded store.
-- 5. Opens the Engine with 'EngineResources' carrying the transaction's
--    fate:
--
--     * @commit@ — the provider's 'commit' (normally @COMMIT@ on the
--       connection), at every commit point the Engine defines;
--     * @rollback@ — @ROLLBACK@, a database error swallowed;
--     * @release@ — unlock the fence, then roll back (the unlock opens a
--       transaction on a join-mode connection);
--     * @close@ — the provider's 'closeConnections';
--     * @wait@ — the hint 'compose' returned.
--
-- If anything fails before the Engine owns these resources — a refused
-- precondition, a held fence, a missing schema, a refused load — the
-- connection rolls back, the fence (when taken) is released, and the
-- connections close, before the failure propagates: the caller's
-- connections are always closed on a failed construction. Once the Engine
-- is open it owns them, and a writing-door failure poisons it (rollback,
-- release, close); the coherent continuation is a fresh load on a fresh
-- connection.
--
-- = Building another provider on it (Absurd)
--
-- The Absurd composition is a 'JoinedProvider' whose 'validate' refuses an
-- autocommit joined connection and a missing, shared, or non-autocommit
-- listen connection; whose 'compose' builds the Absurd Dispatch on the
-- joined connection (so begin + @absurd.spawn_task@ +
-- @pg_notify('impetus_dispatch', queue)@ commit or vanish with the History
-- batch) and returns its @wait_for_results@ as the wake hint (which polls
-- the listen connection, "Petrus.Postgres.Notify"); and whose
-- 'closeConnections' closes the listen connection, then the joined one.
module Petrus.Engine.Postgres.Joined
  ( -- * The composition
    JoinedProvider (..)
  , joinedProvider
  , openJoinedEngine

    -- * Resource helpers
  , rollbackQuietly
  , releaseFenceThenRollback
  , closeBoth
  ) where

import Control.Exception (finally, mask, onException, try)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Petrus.Engine (Engine, EngineOptions (..))
import Petrus.Engine.Provider (EngineResources (..), OpenMode, defaultResources, openEngine)
import Petrus.HistoryStore.Postgres (PostgresHistoryOptions (..), defaultPostgresHistoryOptions, openPostgresHistoryStoreWith)
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.Petrinet (Net)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Postgres (AuthorityFence, Connection, PostgresError, acquireAuthorityFence, releaseAuthorityFence)
import Petrus.Postgres qualified as Pg

-- | One joined PostgreSQL composition.
data JoinedProvider = JoinedProvider
  { connection :: Connection
  -- ^ The joined connection (autocommit off): fence, History, and the
  -- provider's Dispatch statements share its transaction.
  , validate :: IO ()
  -- ^ The provider's preconditions, checked first (failures close the
  -- connections like any other construction failure).
  , commit :: IO ()
  -- ^ The commit point ('Pg.commit' on the joined connection).
  , closeConnections :: IO ()
  -- ^ Close every connection the provider was handed.
  , compose :: HistoryStore -> IO (Dispatch, Maybe (Double -> IO Bool))
  -- ^ Build the Dispatch once the fence is held and History is loaded,
  -- with an optional wake hint for 'Petrus.Engine.wait'.
  }

-- | A provider over one joined connection with a caller-supplied Dispatch:
-- commit and close are the connection's own, there is no wake hint, and
-- nothing is validated.
joinedProvider :: Connection -> Dispatch -> JoinedProvider
joinedProvider connection port =
  JoinedProvider
    { connection
    , validate = pure ()
    , commit = Pg.commit connection
    , closeConnections = Pg.close connection
    , compose = \_ -> pure (port, Nothing)
    }

-- | @connection.rollback()@, a database error swallowed (a dead connection
-- has nothing to roll back).
rollbackQuietly :: Connection -> IO ()
rollbackQuietly connection = void (try @PostgresError (Pg.rollback connection))

-- | Unlock the fence (its own database error swallowed), then roll back,
-- even when the unlock throws.
releaseFenceThenRollback :: AuthorityFence -> Connection -> IO ()
releaseFenceThenRollback fence connection = releaseAuthorityFence fence `finally` rollbackQuietly connection

-- | Close the listen connection, then the joined one (even when the first
-- close throws).
closeBoth :: Connection -> Connection -> IO ()
closeBoth listening joined = Pg.close listening `finally` Pg.close joined

-- | Compose and open the Engine (see the module header). The History store
-- reports to the Engine's telemetry sink.
openJoinedEngine :: JoinedProvider -> OpenMode -> Net -> Text -> EngineOptions -> IO Engine
openJoinedEngine provider mode net instanceId options = mask $ \restore -> do
  -- Until 'openEngine' holds the resources, a failure is cleaned up here;
  -- from then on 'openEngine' runs the same fate itself (rollback, release,
  -- close) and this composition stays out of the way.
  fenceRef <- newIORef Nothing
  handedOver <- newIORef False
  let cleanup =
        readIORef handedOver >>= \case
          True -> pure ()
          False -> do
            rollbackQuietly provider.connection
            readIORef fenceRef >>= mapM_ (`releaseFenceThenRollback` provider.connection)
            provider.closeConnections
      construct = do
        provider.validate
        fence <- acquireAuthorityFence provider.connection instanceId
        writeIORef fenceRef (Just fence)
        history <-
          openPostgresHistoryStoreWith
            defaultPostgresHistoryOptions {telemetry = options.telemetrySink}
            provider.connection
            instanceId
        (port, hint) <- provider.compose history
        let resources =
              defaultResources
                { commit = Just provider.commit
                , rollback = rollbackQuietly provider.connection
                , release = releaseFenceThenRollback fence provider.connection
                , close = provider.closeConnections
                , wait = hint
                }
        writeIORef handedOver True
        openEngine mode net instanceId history port options resources
  restore construct `onException` cleanup
