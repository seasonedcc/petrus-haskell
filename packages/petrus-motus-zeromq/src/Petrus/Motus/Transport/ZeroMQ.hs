-- | The ZeroMQ Dispatch transport, protocol v2 (a port of
-- @petrus.motus.transport.zeromq@).
--
-- ZeroMQ is a transport, not a custody provider: a 'ZeroMQDispatchServer'
-- exposes the Worker side of Local SQLite Dispatch (claim, heartbeat,
-- complete, fail) over IPC, or over TCP authenticated with CURVE; remote
-- Workers use 'ZeroMQWorkerDispatch' (synchronous) or
-- 'AsyncZeroMQWorkerAccess' (native asynchronous). Clients and servers
-- interoperate with the reference's in either direction: the frames, the
-- JSON envelopes, the error kinds and messages, the CURVE certificate files,
-- the ZAP domain, and the IPC ownership lock file are the same.
--
-- > server <- localServer "ipc:///run/app/dispatch.sock" "app/dispatch.db" ["default"] Nothing Nothing
-- > _ <- forkIO (serveForever server)
-- > endpoint <- waitReady server 5
-- > client <- newZeroMQWorkerDispatch endpoint defaultClientOptions
-- > attempt <- claim client
module Petrus.Motus.Transport.ZeroMQ
  ( -- * Protocol constants
    protocolVersion
  , maxMessageBytes
  , highWaterMark
  , maxClients
  , maxIdentityBytes
  , maxQueueCount
  , maxErrorBytes
  , zapDomain
    -- * Worker clients
  , module Petrus.Motus.Transport.ZeroMQ.Client
    -- * Server
  , module Petrus.Motus.Transport.ZeroMQ.Server
    -- * CURVE certificates
  , loadCertificate
  , createCertificates
    -- * Errors
  , module Petrus.Motus.Transport.ZeroMQ.Errors
  , OSError (..)
    -- * libzmq
  , curveAvailable
  ) where

import Petrus.Motus.Transport.ZeroMQ.Client
import Petrus.Motus.Transport.ZeroMQ.Curve (createCertificates, loadCertificate)
import Petrus.Motus.Transport.ZeroMQ.Errors
import Petrus.Motus.Transport.ZeroMQ.Native (hasCapability)
import Petrus.Motus.Transport.ZeroMQ.Server
import Petrus.Motus.Transport.ZeroMQ.Wire

-- | Whether the linked libzmq supports CURVE (@zmq_has("curve")@); the
-- TCP transport requires it.
curveAvailable :: IO Bool
curveAvailable = hasCapability "curve"
