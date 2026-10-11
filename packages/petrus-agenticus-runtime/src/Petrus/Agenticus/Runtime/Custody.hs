-- | The connection-custody seam every provider host uses (the reference's
-- structural @PiConnectionCustody@ protocol, which its Claude and Codex
-- hosts accept as well).
--
-- A host materializes one Agent Connection lease, activates it for an
-- operation, has a result admitted through the connection fence,
-- checkpoints refreshed private state, and releases the lease. Records of
-- these operations let tests substitute scripted custody;
-- 'hostConnectionCustody' adapts the real 'AgentConnectionCustody'.
module Petrus.Agenticus.Runtime.Custody
  ( ProviderHome (..)
  , HostMaterialization (..)
  , HostConnectionCustody (..)
  , hostConnectionCustody
  ) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult
  , AgentConnectionCustody
  , AttachmentFence
  , LeaseMode
  , Materialization (..)
  , PublicationResult
  , ReleaseResult
  )
import Petrus.Agenticus.Connection.Custody qualified as Custody
import Petrus.Agenticus.Connection.Materialization (readMaterialized, replaceMaterialized)
import Petrus.Agenticus.Error

-- | The materialized private state of one lease.
data ProviderHome = ProviderHome
  { read :: IO ByteString
  , replace :: ByteString -> IO ()
  }

-- | One materialized connection lease, as a host sees it.
data HostMaterialization = HostMaterialization
  { fence :: AttachmentFence
  , mode :: LeaseMode
  , expiresAt :: Double
  , home :: ProviderHome
  }

-- | The custody operations a host needs.
data HostConnectionCustody = HostConnectionCustody
  { materialize :: Text -> Text -> LeaseMode -> Double -> Text -> IO HostMaterialization
  -- ^ connection, host, mode, ttl, operation
  , activate :: HostMaterialization -> Text -> IO ()
  , admitResult :: AttachmentFence -> Text -> IO AdmissionResult
  , checkpoint :: HostMaterialization -> Text -> IO PublicationResult
  , release :: HostMaterialization -> Text -> IO ReleaseResult
  }

-- | The real 'AgentConnectionCustody' as host custody.
hostConnectionCustody :: AgentConnectionCustody -> IO HostConnectionCustody
hostConnectionCustody custody = do
  live <- newIORef (Map.empty :: Map AttachmentFence Materialization)
  let underlying m =
        readIORef live >>= \known -> case Map.lookup m.fence known of
          Just value -> pure value
          Nothing -> throwIO (agenticusError CustodyError "materialization is not owned by this custody")
  pure
    HostConnectionCustody
      { materialize = \connection host mode ttl operation -> do
          m <- Custody.materialize custody connection host mode ttl operation
          modifyIORef' live (Map.insert m.fence m)
          pure
            HostMaterialization
              { fence = m.fence
              , mode = m.mode
              , expiresAt = m.expiresAt
              , home = ProviderHome {read = readMaterialized m.home, replace = replaceMaterialized m.home}
              }
      , activate = \m operation -> underlying m >>= \value -> Custody.activate custody value operation
      , admitResult = Custody.admitResult custody
      , checkpoint = \m operation -> underlying m >>= \value -> Custody.checkpoint custody value operation
      , release = \m operation -> underlying m >>= \value -> Custody.release custody value operation
      }
