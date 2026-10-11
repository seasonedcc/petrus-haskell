{-# LANGUAGE MultiWayIf #-}

-- | The event-loop substrate shared by the relays ("Petrus.Viewer.Relay"),
-- the HTTP front ("Petrus.Viewer.HttpFront") and @petrus-mcp@'s stdin and
-- bridge socket ("Petrus.Viewer.Mcp.Reactor"): one thread that owns a
-- kqueue or epoll set (@cbits/relay_io.c@), the way Node's event loop
-- owns its sockets.
--
-- * Sockets stay registered for reading for as long as the loop serves
--   them; writing is watched only while output is pending.
-- * A turn waits once for everything that is ready, without blocking when
--   something already is ('pollWait'), so a busy loop never pays a
--   blocking system call or a capability release.
-- * Other threads hand work to the loop through their own queue and
--   'wake' it with a byte on a pipe the loop watches.
-- * Output is written with @writev@, without blocking ('writeChunks').
--
-- Each user keeps only its own state and dispatch: what a ready socket
-- means, and what one turn does.
module Petrus.Viewer.EventLoop
  ( -- * The loop thread
    EventLoop
  , withEventLoop
  , wake
  , awaitStopped
    -- * Readiness
  , Event (..)
  , pollWait
  , pollerFd
  , watch
  , unwatch
  , watchWrite
    -- * Non-blocking socket I/O
  , recvSocket
  , readNonBlocking
  , setNonBlocking
  , writeChunks
  , closeFd
  ) where

import Control.Concurrent (forkOn)
import Control.Concurrent.STM
import Control.Exception (bracket, finally, onException)
import Control.Monad (forM_, unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CLong (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrArray, touchForeignPtr, withForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeElemOff)

-- C side (cbits/relay_io.c) ------------------------------------------------

foreign import ccall unsafe "prelay_poll_create" c_pollCreate :: IO CInt
foreign import ccall unsafe "prelay_poll_add" c_pollAdd :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_poll_write" c_pollWrite :: CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_poll_remove" c_pollRemove :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_poll_wait" c_pollNow :: CInt -> Ptr CInt -> Ptr CInt -> CInt -> CInt -> IO CInt
-- the blocking wait releases the capability while it waits
foreign import ccall safe "prelay_poll_wait" c_pollBlock :: CInt -> Ptr CInt -> Ptr CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_recv" c_recv :: CInt -> Ptr Word8 -> CLong -> IO CLong
foreign import ccall unsafe "prelay_read" c_read :: CInt -> Ptr Word8 -> CLong -> IO CLong
foreign import ccall unsafe "prelay_set_nonblocking" c_setNonBlocking :: CInt -> IO CInt
foreign import ccall unsafe "prelay_sendv" c_sendv :: CInt -> Ptr (Ptr Word8) -> Ptr CLong -> CInt -> IO CLong
foreign import ccall unsafe "prelay_pipe" c_pipe :: Ptr CInt -> IO CInt
foreign import ccall unsafe "prelay_wake" c_wake :: CInt -> IO ()
foreign import ccall unsafe "prelay_drain" c_drain :: CInt -> IO ()
foreign import ccall unsafe "prelay_close" c_close :: CInt -> IO CInt

-- The loop thread --------------------------------------------------------------

data EventLoop = EventLoop
  { pollerFd :: CInt
  -- ^ the kqueue or epoll descriptor
  , wakeRead :: CInt
  , wakeWrite :: CInt
  , readyFds :: ForeignPtr CInt
  , readyFlags :: ForeignPtr CInt
  , stopRequested :: IORef Bool
  , stopped :: TVar Bool
  -- ^ set once the loop thread has finished and released the poller
  }

-- | The most events one wait reports.
maxReady :: Int
maxReady = 256

newEventLoop :: String -> IO EventLoop
newEventLoop name = do
  pfd <- c_pollCreate
  when (pfd < 0) (ioError (userError (name <> ": cannot create the readiness poller")))
  (wr, ww) <-
    allocaArray 2 (\p -> do
      r <- c_pipe p
      when (r < 0) (ioError (userError (name <> ": cannot create the wake-up pipe")))
      [a, b] <- peekArray 2 p
      pure (a, b))
      `onException` c_close pfd
  _ <- c_pollAdd pfd wr
  EventLoop pfd wr ww
    <$> mallocForeignPtrArray maxReady
    <*> mallocForeignPtrArray maxReady
    <*> newIORef False
    <*> newTVarIO False

-- | Release the poller and the pipe, and tell the waiters.
closeLoop :: EventLoop -> IO ()
closeLoop loop = do
  forM_ [pollerFd loop, wakeRead loop, wakeWrite loop] c_close
  atomically (writeTVar (stopped loop) True)

-- | Run an event loop on its own thread, on capability @cap@, for the
-- duration of the action.
--
-- @setup@ builds the loop's state (on the calling thread; registering
-- sockets with 'watch' is fine there). @turn@ runs on the loop thread,
-- again and again, until the action ends: it waits with 'pollWait' and
-- serves what is ready. @teardown@ runs on the loop thread when it stops
-- (also after an exception), before the poller is released. The action
-- returns only once the loop thread has finished.
withEventLoop
  :: String
  -- ^ name, for errors
  -> Int
  -> (EventLoop -> IO s)
  -> (s -> IO ())
  -> (s -> IO ())
  -> (s -> IO a)
  -> IO a
withEventLoop name cap setup turn teardown action = bracket start stop (action . snd)
  where
    start = do
      loop <- newEventLoop name
      s <- setup loop `onException` closeLoop loop
      let run = do
            turn s
            done <- readIORef (stopRequested loop)
            unless done run
      _ <- forkOn cap (run `finally` (teardown s `finally` closeLoop loop))
      pure (loop, s)
    stop (loop, _) = do
      writeIORef (stopRequested loop) True
      wake loop
      atomically (awaitStopped loop)

-- | Wake the loop from another thread (its turn then sees 'Woken').
wake :: EventLoop -> IO ()
wake = c_wake . wakeWrite

-- | Blocks until the loop thread has finished.
awaitStopped :: EventLoop -> STM ()
awaitStopped loop = readTVar (stopped loop) >>= check

-- Readiness --------------------------------------------------------------------

data Event
  = -- | another thread called 'wake' (the pipe is drained)
    Woken
  | -- | a socket is ready: readable (or hung up), writable
    Ready CInt Bool Bool

-- | Wait for readiness: return at once when something is ready, otherwise
-- block (releasing the capability) for up to @timeoutMs@ milliseconds
-- (negative: until something is ready). An empty list after the timeout.
pollWait :: EventLoop -> Int -> IO [Event]
pollWait loop timeoutMs =
  withForeignPtr (readyFds loop) $ \fds -> withForeignPtr (readyFlags loop) $ \fls -> do
    n0 <- c_pollNow pfd fds fls (fromIntegral maxReady) 0
    n <- if n0 == 0 then c_pollBlock pfd fds fls (fromIntegral maxReady) (fromIntegral timeoutMs) else pure n0
    if n <= 0
      then pure []
      else do
        ready <- zip <$> peekArray (fromIntegral n) fds <*> peekArray (fromIntegral n) fls
        mapM event ready
  where
    pfd = pollerFd loop
    event (fd, fl)
      | fd == wakeRead loop = Woken <$ c_drain fd
      | otherwise = pure (Ready fd (fl .&. 1 /= 0) (fl .&. 2 /= 0))

-- | Start watching a socket for reading; negative on failure.
watch :: EventLoop -> CInt -> IO CInt
watch loop = c_pollAdd (pollerFd loop)

-- | Stop watching a socket.
unwatch :: EventLoop -> CInt -> IO ()
unwatch loop fd = () <$ c_pollRemove (pollerFd loop) fd

-- | Watch a socket for writing too, or stop; reading stays watched.
watchWrite :: EventLoop -> CInt -> Bool -> IO ()
watchWrite loop fd on = () <$ c_pollWrite (pollerFd loop) fd (if on then 1 else 0)

-- Non-blocking socket I/O ------------------------------------------------------

-- | @recv@ without blocking into the buffer: the bytes read, 0 at the end
-- of the stream, -2 when nothing is there, -1 on error.
recvSocket :: CInt -> Ptr Word8 -> Int -> IO Int
recvSocket fd p len = fromIntegral <$> c_recv fd p (fromIntegral len)

-- | @read@ from a non-blocking descriptor (a pipe), with 'recvSocket''s
-- results.
readNonBlocking :: CInt -> Ptr Word8 -> Int -> IO Int
readNonBlocking fd p len = fromIntegral <$> c_read fd p (fromIntegral len)

-- | Put a descriptor in non-blocking mode; negative on failure.
setNonBlocking :: CInt -> IO CInt
setNonBlocking = c_setNonBlocking

closeFd :: CInt -> IO ()
closeFd fd = () <$ c_close fd

-- | @writev@ until done or the socket is full: the unwritten rest, and
-- whether the socket failed.
writeChunks :: CInt -> [ByteString] -> IO ([ByteString], Bool)
writeChunks _ [] = pure ([], False)
writeChunks fd chunks = do
  let batch = take 64 chunks
      count = length batch
  r <- allocaArray count $ \ptrs -> allocaArray count $ \lens -> do
    forM_ (zip [0 ..] batch) $ \(i, BI.BS fp len) -> do
      pokeElemOff ptrs i (unsafeForeignPtrToPtr fp)
      pokeElemOff lens i (fromIntegral len)
    w <- c_sendv fd ptrs lens (fromIntegral count)
    mapM_ (\(BI.BS fp _) -> touchForeignPtr fp) batch
    pure (fromIntegral w :: Int)
  if
    | r == -2 -> pure (chunks, False)
    | r < 0 -> pure ([], True)
    | otherwise ->
        let rest = dropBytes r chunks
         in if
              | null rest -> pure ([], False)
              | r < sum (map B.length batch) -> pure (rest, False) -- the socket is full
              | otherwise -> writeChunks fd rest
  where
    dropBytes :: Int -> [ByteString] -> [ByteString]
    dropBytes 0 xs = xs
    dropBytes _ [] = []
    dropBytes k (x : xs)
      | k >= B.length x = dropBytes (k - B.length x) xs
      | otherwise = BU.unsafeDrop k x : xs
