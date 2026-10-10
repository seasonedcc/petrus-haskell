-- | The client side's socket seam: how a Worker client opens, configures,
-- uses, and closes one DEALER socket per request attempt.
--
-- The clients reach libzmq only through a 'SocketFactory', so tests can
-- inject sockets that fail while being configured, block while sending, or
-- never answer (the reference's tests monkeypatch @_context@ and
-- @_open_socket@ for the same purpose).
module Petrus.Motus.Transport.ZeroMQ.Socket
  ( -- * Request sockets
    RpcSocket (..)
  , TransportFailure (..)
    -- * Configurable sockets
  , RawDealer (..)
  , SocketFactory (..)
  , zmqSocketFactory
  , openDealer
  , requestMilliseconds
  ) where

import Control.Exception (Exception, handle, onException, throwIO)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Transport.ZeroMQ.Curve (ClientKeys (..))
import Petrus.Motus.Transport.ZeroMQ.Native qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Wire (highWaterMark, maxMessageBytes)

-- | One connected request socket.
data RpcSocket = RpcSocket
  { send :: ByteString -> IO ()
  -- ^ Queue one single-frame message; throws 'TransportFailure'.
  , receive :: Int -> IO (Maybe [ByteString])
  -- ^ Wait up to the microseconds for one multipart message; throws
  -- 'TransportFailure'.
  , close :: IO ()
  -- ^ Close with linger 0.
  }

-- | What the reference catches as @TimeoutError@, @zmq.Again@, or
-- @zmq.ZMQError@ around a request: the operation's outcome is unknown.
data TransportFailure
  = SendTimedOut
  | ReceiveTimedOut
  | TransportZmq Z.ZmqError
  deriving stock (Show)

instance Exception TransportFailure

-- | A DEALER socket before it connects.
data RawDealer = RawDealer
  { setInt :: Z.IntOption -> Int -> IO ()
  , setMaxMessageSize :: Int64 -> IO ()
  , setBytes :: Z.BytesOption -> ByteString -> IO ()
  , connectTo :: Text -> IO ()
  , closeRaw :: IO ()
  -- ^ Close with linger 0.
  , connected :: RpcSocket
  }

-- | Where new DEALER sockets come from (the reference's @_context.socket@).
newtype SocketFactory = SocketFactory {newDealer :: IO RawDealer}

-- | DEALER sockets of a libzmq context. Sends and receives are
-- non-blocking at the C level; the send waits up to the socket's
-- @ZMQ_SNDTIMEO@ (as a blocking libzmq send would) and then fails like
-- @zmq.Again@.
zmqSocketFactory :: Z.Context -> SocketFactory
zmqSocketFactory context = SocketFactory $ do
  socket <- Z.newSocket context Z.Dealer
  sendTimeout <- newIORef (Nothing :: Maybe Int)
  let closeIt = Z.closeSocket socket
      transport :: IO a -> IO a
      transport = handle (throwIO . TransportZmq)
      setOption option v = do
        Z.setIntOption socket option v
        when (option == Z.SendTimeout) $ writeIORef sendTimeout (if v < 0 then Nothing else Just v)
  pure
    RawDealer
      { setInt = setOption
      , setMaxMessageSize = Z.setInt64Option socket
      , setBytes = Z.setBytesOption socket
      , connectTo = Z.connect socket
      , closeRaw = Z.setIntOption socket Z.Linger 0 >> closeIt
      , connected =
          RpcSocket
            { send = \payload -> do
                limit <- readIORef sendTimeout
                queued <- transport (Z.sendFrames socket [payload] limit)
                unless queued (throwIO SendTimedOut)
            , receive = \micros -> transport (Z.receiveFrames socket (Just micros))
            , close = closeIt
            }
      }

-- | @max(1, round(request_timeout * 1000))@.
requestMilliseconds :: Double -> Int
requestMilliseconds seconds = max 1 (round (seconds * 1000))

-- | The reference's @_open_socket@: linger 0, high-water marks, the
-- message size limit, @IMMEDIATE@, the send timeout, and CURVE keys on
-- TCP, then connect; a socket whose setup fails is closed (linger 0)
-- before the failure propagates.
openDealer :: SocketFactory -> Double -> Text -> Maybe ClientKeys -> IO RpcSocket
openDealer factory requestTimeout endpoint keys = do
  raw <- factory.newDealer
  let setup = do
        raw.setInt Z.Linger 0
        raw.setInt Z.SendHighWaterMark highWaterMark
        raw.setInt Z.ReceiveHighWaterMark highWaterMark
        raw.setMaxMessageSize (fromIntegral maxMessageBytes)
        raw.setInt Z.Immediate 1
        raw.setInt Z.SendTimeout (requestMilliseconds requestTimeout)
        case keys of
          Just k | "tcp://" `T.isPrefixOf` endpoint -> do
            raw.setBytes Z.CurvePublicKey k.clientPublic
            raw.setBytes Z.CurveSecretKey k.clientSecret
            raw.setBytes Z.CurveServerKey k.serverPublic
          _ -> pure ()
        raw.connectTo endpoint
  setup `onException` raw.closeRaw
  pure raw.connected
