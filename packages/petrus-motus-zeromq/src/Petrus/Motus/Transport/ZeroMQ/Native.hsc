{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE InterruptibleFFI #-}

-- | A thin binding to the few libzmq 4.x functions the Dispatch transport
-- uses.
--
-- Every send and receive is non-blocking at the C level (@ZMQ_DONTWAIT@).
-- When libzmq answers @EAGAIN@, the calling Haskell thread waits for the
-- socket with an interruptible @zmq_poll@ on its OS thread, as pyzmq's
-- blocking receive waits, and retries. Every poll is bounded at 50 ms and
-- the wait loops until its deadline, so cancellation stays safe: an
-- asynchronous exception ('System.Timeout.timeout', @cancel@) interrupts
-- the call with a signal, but @zmq_poll@ is not one system call. When it
-- wakes for a libzmq command (a peer's pipe ending, say) it handles the
-- command in user space and polls again, and a signal that lands in that
-- window is lost. An unbounded poll would then hold the exception until a
-- message arrived, which at server shutdown is never; a bounded one only
-- delays it, by 50 ms at most. The bound costs nothing measurable
-- (bench/RESULTS.md), and the transport tests cancel waits in that window.
--
-- The clean wait is GHC's IO manager on the socket's @ZMQ_FD@. It holds
-- no OS thread, but each wake-up costs an event-manager hand-off and each
-- 'System.Timeout.timeout' a timer-manager registration. On macOS it
-- cleared every row against pyzmq (bench/RESULTS.md); on the Linux CI
-- runners it did not. Python ÷ Haskell in bench-gate run 38202655016 (job
-- 114660170314, commit 81bbdc5, the IO-manager wait):
-- @zeromq/memory/claim-empty-100@ 0.90× (rerun 0.95×),
-- @zeromq/memory/custody-20@ 0.98× (rerun 0.98×). With the poll: 1.19× and
-- 1.36×, 1.18× and 1.27× (run 38206418285), and 1.11× and 1.28× (run
-- 38255030541, commit d869f62).
--
-- Each waiting socket holds an OS thread in a safe call, so the package
-- needs the threaded runtime; every component that links it is built
-- @-threaded@. (Under the non-threaded runtime each wait would stall every
-- Haskell thread for up to 50 ms.)
--
-- A socket must be used by one Haskell thread at a time; libzmq tolerates a
-- socket moving between OS threads, which the GHC scheduler may do, because
-- every scheduler hand-off is a full memory barrier.
module Petrus.Motus.Transport.ZeroMQ.Native
  ( -- * Errors
    ZmqError (..)
  , eagain
  , eterm
    -- * Library
  , hasCapability
  , libraryVersion
    -- * Contexts
  , Context
  , newContext
  , terminateContext
    -- * Sockets
  , Socket
  , SocketType (..)
  , newSocket
  , closeSocket
  , bind
  , connect
    -- * Options
  , IntOption (..)
  , setIntOption
  , setInt64Option
  , BytesOption (..)
  , setBytesOption
  , lastEndpoint
    -- * Messages
  , sendFrames
  , receiveFrames
  , waitReadable
    -- * CURVE keys
  , z85Encode
  , z85Decode
  , curveKeypair
  , curvePublic
  ) where

#include <zmq.h>

import Control.Concurrent (yield)
import Control.Exception (Exception (..), throwIO)
import Control.Monad (unless, void, when)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Foreign.C.ConstPtr (ConstPtr (..))
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CChar, CInt (..), CLong (..), CShort (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes, allocaBytesAligned)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, pokeByteOff, sizeOf)
import GHC.Clock (getMonotonicTimeNSec)
import Petrus.Json.Python.Exception (IsPythonException (..), pythonExceptionFromException, pythonExceptionToException, raised)
import System.IO.Unsafe (unsafePerformIO)

-- ---------------------------------------------------------------------------
-- Errors

-- | A libzmq failure: the C function, @errno@, and @zmq_strerror@ text
-- (which is what pyzmq's @str(ZMQError)@ shows).
data ZmqError = ZmqError
  { function :: Text
  , errno :: Int
  , message :: Text
  }
  deriving stock (Eq, Show)

instance Exception ZmqError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException e = T.unpack e.message

-- | pyzmq's @zmq.ZMQError@ with the @zmq_strerror@ text.
instance IsPythonException ZmqError where
  toPythonException e = raised "ZMQError" e.message

-- | @EAGAIN@ on this platform.
eagain :: Int
eagain = #{const EAGAIN}

-- | @ETERM@: the context was terminated.
eterm :: Int
eterm = #{const ETERM}

foreign import capi unsafe "zmq.h zmq_errno" c_zmq_errno :: IO CInt
foreign import capi unsafe "zmq.h zmq_strerror" c_zmq_strerror :: CInt -> IO (ConstPtr CChar)

lastError :: Text -> IO ZmqError
lastError name = do
  code <- c_zmq_errno
  text <- c_zmq_strerror code >>= peekCString . unConstPtr
  pure ZmqError {function = name, errno = fromIntegral code, message = T.pack text}

throwLast :: Text -> IO a
throwLast name = lastError name >>= throwIO

check :: Text -> IO CInt -> IO ()
check name action = do
  rc <- action
  when (rc /= 0) (throwLast name)

-- ---------------------------------------------------------------------------
-- Library

foreign import capi unsafe "zmq.h zmq_has" c_zmq_has :: CString -> IO CInt
foreign import capi unsafe "zmq.h zmq_version" c_zmq_version :: Ptr CInt -> Ptr CInt -> Ptr CInt -> IO ()

-- | @zmq_has(capability)@, e.g. @hasCapability "curve"@.
hasCapability :: String -> IO Bool
hasCapability name = withCString name (fmap (== 1) . c_zmq_has)

-- | The linked libzmq version.
libraryVersion :: IO (Int, Int, Int)
libraryVersion =
  alloca $ \major -> alloca $ \minor -> alloca $ \patch -> do
    c_zmq_version major minor patch
    (,,) <$> (fromIntegral <$> peek major) <*> (fromIntegral <$> peek minor) <*> (fromIntegral <$> peek patch)

-- ---------------------------------------------------------------------------
-- Contexts

-- | A libzmq context.
newtype Context = Context (Ptr ())

foreign import capi safe "zmq.h zmq_ctx_new" c_zmq_ctx_new :: IO (Ptr ())
foreign import capi safe "zmq.h zmq_ctx_term" c_zmq_ctx_term :: Ptr () -> IO CInt

-- | @zmq_ctx_new@.
newContext :: IO Context
newContext = do
  ptr <- c_zmq_ctx_new
  when (ptr == nullPtr) (throwLast "zmq_ctx_new")
  pure (Context ptr)

-- | @zmq_ctx_term@: blocks until every socket of the context is closed
-- (sockets close with linger 0 here, so nothing is flushed).
terminateContext :: Context -> IO ()
terminateContext (Context ptr) = loop
  where
    loop = do
      rc <- c_zmq_ctx_term ptr
      unless (rc == 0) $ do
        e <- lastError "zmq_ctx_term"
        if e.errno == #{const EINTR} then loop else throwIO e

-- ---------------------------------------------------------------------------
-- Sockets

-- | The socket types the transport uses.
data SocketType = Dealer | Router | Rep
  deriving stock (Eq, Show)

socketTypeCode :: SocketType -> CInt
socketTypeCode = \case
  Dealer -> #{const ZMQ_DEALER}
  Router -> #{const ZMQ_ROUTER}
  Rep -> #{const ZMQ_REP}

-- | A libzmq socket.
data Socket = Socket
  { pointer :: Ptr ()
  , open :: IORef Bool
  }

foreign import capi unsafe "zmq.h zmq_socket" c_zmq_socket :: Ptr () -> CInt -> IO (Ptr ())
foreign import capi unsafe "zmq.h zmq_close" c_zmq_close :: Ptr () -> IO CInt
foreign import capi unsafe "zmq.h zmq_bind" c_zmq_bind :: Ptr () -> CString -> IO CInt
foreign import capi unsafe "zmq.h zmq_connect" c_zmq_connect :: Ptr () -> CString -> IO CInt
foreign import capi unsafe "zmq.h zmq_setsockopt" c_zmq_setsockopt :: Ptr () -> CInt -> Ptr () -> CSize -> IO CInt
foreign import capi unsafe "zmq.h zmq_getsockopt" c_zmq_getsockopt :: Ptr () -> CInt -> Ptr () -> Ptr CSize -> IO CInt

-- | @zmq_socket@.
newSocket :: Context -> SocketType -> IO Socket
newSocket (Context ctx) kind = do
  ptr <- c_zmq_socket ctx (socketTypeCode kind)
  when (ptr == nullPtr) (throwLast "zmq_socket")
  Socket ptr <$> newIORef True

-- | @zmq_close@; idempotent. Set linger first when it matters.
closeSocket :: Socket -> IO ()
closeSocket s = do
  wasOpen <- atomicModifyIORef' s.open (False,)
  when wasOpen (void (c_zmq_close s.pointer))

-- | @zmq_bind@.
bind :: Socket -> Text -> IO ()
bind s endpoint = withCString (T.unpack endpoint) (check "zmq_bind" . c_zmq_bind s.pointer)

-- | @zmq_connect@.
connect :: Socket -> Text -> IO ()
connect s endpoint = withCString (T.unpack endpoint) (check "zmq_connect" . c_zmq_connect s.pointer)

-- | Integer socket options.
data IntOption
  = Linger
  | SendHighWaterMark
  | ReceiveHighWaterMark
  | SendTimeout
  | Immediate
  | RouterMandatory
  | CurveServer
  deriving stock (Eq, Show)

intOptionCode :: IntOption -> CInt
intOptionCode = \case
  Linger -> #{const ZMQ_LINGER}
  SendHighWaterMark -> #{const ZMQ_SNDHWM}
  ReceiveHighWaterMark -> #{const ZMQ_RCVHWM}
  SendTimeout -> #{const ZMQ_SNDTIMEO}
  Immediate -> #{const ZMQ_IMMEDIATE}
  RouterMandatory -> #{const ZMQ_ROUTER_MANDATORY}
  CurveServer -> #{const ZMQ_CURVE_SERVER}

-- | Byte-string socket options (CURVE keys accept 40-character Z85 text).
data BytesOption
  = ZapDomain
  | CurvePublicKey
  | CurveSecretKey
  | CurveServerKey
  deriving stock (Eq, Show)

bytesOptionCode :: BytesOption -> CInt
bytesOptionCode = \case
  ZapDomain -> #{const ZMQ_ZAP_DOMAIN}
  CurvePublicKey -> #{const ZMQ_CURVE_PUBLICKEY}
  CurveSecretKey -> #{const ZMQ_CURVE_SECRETKEY}
  CurveServerKey -> #{const ZMQ_CURVE_SERVERKEY}

-- | @zmq_setsockopt@ with a C @int@.
setIntOption :: Socket -> IntOption -> Int -> IO ()
setIntOption s option value =
  with (fromIntegral value :: CInt) $ \p ->
    check "zmq_setsockopt" (c_zmq_setsockopt s.pointer (intOptionCode option) (castPtr p) (fromIntegral (sizeOf (0 :: CInt))))

-- | @ZMQ_MAXMSGSIZE@ (an @int64_t@ option).
setInt64Option :: Socket -> Int64 -> IO ()
setInt64Option s value =
  with value $ \p ->
    check "zmq_setsockopt" (c_zmq_setsockopt s.pointer #{const ZMQ_MAXMSGSIZE} (castPtr p) (fromIntegral (sizeOf value)))

-- | @zmq_setsockopt@ with bytes.
setBytesOption :: Socket -> BytesOption -> ByteString -> IO ()
setBytesOption s option value =
  BU.unsafeUseAsCStringLen value $ \(p, n) ->
    check "zmq_setsockopt" (c_zmq_setsockopt s.pointer (bytesOptionCode option) (castPtr p) (fromIntegral n))

getIntOption :: Socket -> CInt -> IO CInt
getIntOption s code =
  alloca $ \value -> with (fromIntegral (sizeOf (0 :: CInt))) $ \size -> do
    check "zmq_getsockopt" (c_zmq_getsockopt s.pointer code (castPtr value) size)
    peek value

-- | @ZMQ_LAST_ENDPOINT@ (e.g. the port a @tcp://host:*@ bind chose).
lastEndpoint :: Socket -> IO Text
lastEndpoint s =
  allocaBytes 1024 $ \buffer -> with (1024 :: CSize) $ \size -> do
    check "zmq_getsockopt" (c_zmq_getsockopt s.pointer #{const ZMQ_LAST_ENDPOINT} (castPtr buffer) size)
    T.pack <$> peekCString (castPtr buffer :: Ptr CChar)

events :: Socket -> IO CInt
events s = getIntOption s #{const ZMQ_EVENTS}

-- ---------------------------------------------------------------------------
-- Messages

foreign import capi unsafe "zmq.h zmq_send" c_zmq_send :: Ptr () -> Ptr () -> CSize -> CInt -> IO CInt
foreign import capi unsafe "zmq.h zmq_msg_init" c_zmq_msg_init :: Ptr () -> IO CInt
foreign import capi unsafe "zmq.h zmq_msg_recv" c_zmq_msg_recv :: Ptr () -> Ptr () -> CInt -> IO CInt
foreign import capi unsafe "zmq.h zmq_msg_data" c_zmq_msg_data :: Ptr () -> IO (Ptr Word8)
foreign import capi unsafe "zmq.h zmq_msg_size" c_zmq_msg_size :: Ptr () -> IO CSize
foreign import capi unsafe "zmq.h zmq_msg_more" c_zmq_msg_more :: Ptr () -> IO CInt
foreign import capi unsafe "zmq.h zmq_msg_close" c_zmq_msg_close :: Ptr () -> IO CInt

-- | Microseconds on the monotonic clock.
nowMicros :: IO Int
nowMicros = (\ns -> fromIntegral (ns `div` 1000)) <$> getMonotonicTimeNSec

-- | Wait (at most until the deadline, in monotonic microseconds) for the
-- socket to signal; answers whether the wanted event is now set. Each poll
-- lasts at most 'pollBound', whatever the deadline (see the module header).
awaitEvent :: Socket -> CInt -> Maybe Int -> IO Bool
awaitEvent s wanted deadline = loop
  where
    loop = do
      current <- events s
      if current .&. wanted /= 0
        then pure True
        else do
          now <- nowMicros
          let remaining = maybe pollBound (\d -> d - now) deadline
          if remaining <= 0
            then pure False
            else pollFor s wanted ((min pollBound remaining + 999) `div` 1000) >> loop

-- | The longest single @zmq_poll@, in microseconds: how late a lost
-- interrupt can make an asynchronous exception.
pollBound :: Int
pollBound = 50000

-- | @zmq_poll@ on one socket for the wanted events, for at most the given
-- milliseconds, on the calling OS thread. An interrupted poll (an
-- asynchronous exception, or a signal) returns to the caller, which
-- re-checks the socket.
pollFor :: Socket -> CInt -> Int -> IO ()
pollFor s wanted milliseconds =
  allocaBytesAligned #{size zmq_pollitem_t} #{alignment zmq_pollitem_t} $ \item -> do
    #{poke zmq_pollitem_t, socket} item s.pointer
    #{poke zmq_pollitem_t, fd} item (0 :: CInt)
    #{poke zmq_pollitem_t, events} item (fromIntegral wanted :: CShort)
    #{poke zmq_pollitem_t, revents} item (0 :: CShort)
    rc <- c_zmq_poll item 1 (fromIntegral milliseconds)
    when (rc < 0) $ do
      code <- c_zmq_errno
      unless (code == #{const EINTR}) (throwLast "zmq_poll")

foreign import capi interruptible "zmq.h zmq_poll" c_zmq_poll :: Ptr () -> CInt -> CLong -> IO CInt

-- | Wait up to the given microseconds for an incoming message.
waitReadable :: Socket -> Int -> IO Bool
waitReadable s micros = do
  now <- nowMicros
  awaitEvent s #{const ZMQ_POLLIN} (Just (now + micros))

-- | Send one multipart message; 'False' when it could not be queued
-- before the timeout (milliseconds; 'Nothing' waits forever), as libzmq's
-- @EAGAIN@ after @ZMQ_SNDTIMEO@. Other failures throw 'ZmqError'.
sendFrames :: Socket -> [ByteString] -> Maybe Int -> IO Bool
sendFrames s frames timeoutMs = do
  deadline <- traverse (\ms -> (+ ms * 1000) <$> nowMicros) timeoutMs
  case frames of
    [] -> pure True
    first : rest -> do
      queued <- sendOne deadline first (not (null rest))
      if not queued
        then pure False
        else do
          mapM_ (\(frame, more) -> sendOne Nothing frame more) (zip rest (map (const True) (drop 1 rest) ++ [False]))
          pure True
  where
    sendOne deadline frame more = loop
      where
        flags = #{const ZMQ_DONTWAIT} .|. (if more then #{const ZMQ_SNDMORE} else 0)
        loop = do
          rc <- BU.unsafeUseAsCStringLen frame $ \(p, n) -> c_zmq_send s.pointer (castPtr p) (fromIntegral n) flags
          if rc >= 0
            then pure True
            else do
              e <- lastError "zmq_send"
              if e.errno /= eagain
                then throwIO e
                else do
                  ready <- awaitEvent s #{const ZMQ_POLLOUT} deadline
                  if ready then loop else yield >> retryOnce
        -- One last non-blocking attempt at the deadline.
        retryOnce = do
          rc <- BU.unsafeUseAsCStringLen frame $ \(p, n) -> c_zmq_send s.pointer (castPtr p) (fromIntegral n) flags
          if rc >= 0
            then pure True
            else do
              e <- lastError "zmq_send"
              if e.errno == eagain then pure False else throwIO e

-- | Receive one whole multipart message, waiting up to the timeout
-- (microseconds; 'Nothing' waits forever). 'Nothing' on timeout.
receiveFrames :: Socket -> Maybe Int -> IO (Maybe [ByteString])
receiveFrames s timeoutMicros = do
  deadline <- traverse (\us -> (+ us) <$> nowMicros) timeoutMicros
  firstFrame <- receiveOne deadline
  case firstFrame of
    Nothing -> pure Nothing
    Just (frame, more) -> Just <$> collect [frame] more
  where
    collect acc more
      | not more = pure (reverse acc)
      | otherwise =
          receiveOne Nothing >>= \case
            Just (frame, more') -> collect (frame : acc) more'
            Nothing -> pure (reverse acc)
    receiveOne deadline =
      allocaBytesAligned #{size zmq_msg_t} #{alignment zmq_msg_t} $ \msg -> do
        check "zmq_msg_init" (c_zmq_msg_init msg)
        let loop = do
              rc <- c_zmq_msg_recv msg s.pointer #{const ZMQ_DONTWAIT}
              if rc >= 0
                then do
                  size <- c_zmq_msg_size msg
                  bytes <- c_zmq_msg_data msg
                  frame <- BS.packCStringLen (castPtr bytes, fromIntegral size)
                  more <- (/= 0) <$> c_zmq_msg_more msg
                  pure (Just (frame, more))
                else do
                  e <- lastError "zmq_msg_recv"
                  if e.errno /= eagain
                    then throwIO e
                    else do
                      ready <- awaitEvent s #{const ZMQ_POLLIN} deadline
                      if ready then loop else pure Nothing
        result <- loop
        void (c_zmq_msg_close msg)
        pure result

-- ---------------------------------------------------------------------------
-- CURVE keys

foreign import capi unsafe "zmq.h zmq_z85_encode" c_zmq_z85_encode :: Ptr CChar -> Ptr Word8 -> CSize -> IO (Ptr CChar)
foreign import capi unsafe "zmq.h zmq_z85_decode" c_zmq_z85_decode :: Ptr Word8 -> Ptr CChar -> IO (Ptr Word8)
foreign import capi unsafe "zmq.h zmq_curve_keypair" c_zmq_curve_keypair :: Ptr CChar -> Ptr CChar -> IO CInt
foreign import capi unsafe "zmq.h zmq_curve_public" c_zmq_curve_public :: Ptr CChar -> Ptr CChar -> IO CInt

-- | Z85-encode bytes whose length is a multiple of 4. unsafePerformIO:
-- libzmq's pure codec over a buffer this call allocates; no other effect.
z85Encode :: ByteString -> Maybe ByteString
z85Encode bytes
  | BS.length bytes `mod` 4 /= 0 = Nothing
  | otherwise = unsafePerformIO $
      allocaBytes (BS.length bytes * 5 `div` 4 + 1) $ \out ->
        BU.unsafeUseAsCStringLen bytes $ \(p, n) -> do
          r <- c_zmq_z85_encode out (castPtr p) (fromIntegral n)
          if r == nullPtr then pure Nothing else Just <$> BS.packCString out

-- | Z85-decode text whose length is a multiple of 5. unsafePerformIO: as
-- for 'z85Encode'.
z85Decode :: ByteString -> Maybe ByteString
z85Decode text
  | BS.length text `mod` 5 /= 0 || BS.elem 0 text = Nothing
  | otherwise = unsafePerformIO $
      allocaBytes (BS.length text * 4 `div` 5) $ \out ->
        BS.useAsCString text $ \p -> do
          r <- c_zmq_z85_decode out p
          if r == nullPtr then pure Nothing else Just <$> BS.packCStringLen (castPtr out, BS.length text * 4 `div` 5)

-- | A new CURVE key pair, (public, secret), as 40-character Z85 text.
curveKeypair :: IO (ByteString, ByteString)
curveKeypair =
  allocaBytes 41 $ \public -> allocaBytes 41 $ \secret -> do
    check "zmq_curve_keypair" (c_zmq_curve_keypair public secret)
    (,) <$> BS.packCString public <*> BS.packCString secret

-- | The Z85 public key of a Z85 secret key.
curvePublic :: ByteString -> IO ByteString
curvePublic secret =
  allocaBytes 41 $ \public -> BS.useAsCString secret $ \s -> do
    check "zmq_curve_public" (c_zmq_curve_public public s)
    BS.packCString public
