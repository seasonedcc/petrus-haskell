{-# LANGUAGE MultiWayIf #-}

-- | The event loop of @petrus-mcp@ ("Petrus.Viewer.EventLoop"): one
-- thread, on capability 0, waits on the bridge WebSocket and standard
-- input together and runs what each descriptor registered, the way the
-- Node server's event loop serves both.
--
-- Without it every message would be a separate wait in GHC's I/O manager:
-- a one-shot registration per read, and a hand-off from the manager's
-- thread to the reader's, which with requests in flight dominated the cost
-- of a tool call. Here descriptors stay registered, and a turn waits once
-- for everything that is ready, without blocking when something already
-- is. Writes still go straight from the thread that writes (they rarely
-- wait).
module Petrus.Viewer.Mcp.Reactor
  ( Reactor
  , withReactor
  , readLines
  , withSocketStream
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Foreign.C.Types (CInt)
import Foreign.ForeignPtr (mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr, castPtr)
import Data.Word (Word8)
import Network.Socket qualified as S
import Network.Socket.ByteString.Lazy qualified as SBL
import Network.WebSockets.Stream qualified as WS
import Petrus.Viewer.EventLoop

-- | The loop and what each watched descriptor runs when it is readable.
data Reactor = Reactor EventLoop (IORef (Map CInt (IO ())))

-- | Run the loop for the duration of the action.
withReactor :: (Reactor -> IO a) -> IO a
withReactor = withEventLoop "petrus-mcp" 0 setup turn (const (pure ()))
  where
    setup loop = Reactor loop <$> newIORef Map.empty
    turn (Reactor loop handlers) = do
      -- the threads the last turn woke (request handlers) run first, on
      -- this OS thread; a wait that blocks then finds nothing runnable,
      -- and releasing the capability hands nothing to another OS thread
      yield
      events <- pollWait loop (-1)
      forM_ events $ \case
        Ready fd _ _ -> do
          -- looked up per event: a handler removed meanwhile does not run
          act <- Map.lookup fd <$> readIORef handlers
          -- a failing handler must not stop the loop
          forM_ act (void . try @SomeException)
        Woken -> pure ()

register :: Reactor -> CInt -> IO () -> IO ()
register (Reactor loop handlers) fd act = do
  atomicModifyIORef' handlers (\m -> (Map.insert fd act m, ()))
  r <- watch loop fd
  when (r < 0) $ do
    atomicModifyIORef' handlers (\m -> (Map.delete fd m, ()))
    ioError (userError ("petrus-mcp: cannot watch descriptor " <> show fd))

unregister :: Reactor -> CInt -> IO ()
unregister (Reactor loop handlers) fd = do
  atomicModifyIORef' handlers (\m -> (Map.delete fd m, ()))
  unwatch loop fd

-- | Bytes per read.
chunkSize :: Int
chunkSize = 65536

-- | One read from a ready descriptor into a reused buffer: the bytes, or
-- 'Nothing' at the end of the stream or on an error; @Just ""@ when
-- nothing was there after all.
readChunk :: (Ptr Word8 -> Int -> IO Int) -> Ptr Word8 -> IO (Maybe ByteString)
readChunk rd p = do
  n <- rd p chunkSize
  if
    | n > 0 -> Just <$> B.packCStringLen (castPtr p, n)
    | n == -2 -> pure (Just B.empty)
    | otherwise -> pure Nothing

-- | Read the descriptor (a pipe or a socket; it is put in non-blocking
-- mode) a line at a time: on the loop thread, each complete line, without
-- its newline, goes to @onLine@, in order; at the end of the stream the
-- unterminated rest (if any) goes to @onLine@ too, then @onEnd@ runs.
readLines :: Reactor -> CInt -> (ByteString -> IO ()) -> IO () -> IO ()
readLines r fd onLine onEnd = do
  ok <- setNonBlocking fd
  when (ok < 0) (ioError (userError ("petrus-mcp: cannot read descriptor " <> show fd)))
  buf <- mallocForeignPtrBytes chunkSize
  -- the start of the current line, in reverse
  partial <- newIORef []
  let feed chunk = case B.elemIndex 10 chunk of
        Nothing -> modifyIORef' partial (chunk :)
        Just i -> do
          before <- atomicModifyIORef' partial ([],)
          onLine (B.concat (reverse (B.take i chunk : before)))
          feed (B.drop (i + 1) chunk)
      end = do
        unregister r fd
        rest <- B.concat . reverse <$> readIORef partial
        unless (B.null rest) (onLine rest)
        onEnd
  register r fd $
    withForeignPtr buf (readChunk (readNonBlocking fd)) >>= \case
      Just chunk -> unless (B.null chunk) (feed chunk)
      Nothing -> end

-- | A WebSocket stream over a connected socket: reads come from the loop
-- (the socket stays registered for as long as the action runs), writes go
-- straight to the socket.
withSocketStream :: Reactor -> S.Socket -> (WS.Stream -> IO a) -> IO a
withSocketStream r sock act = do
  fd <- S.unsafeFdSocket sock
  received <- newTQueueIO
  buf <- mallocForeignPtrBytes chunkSize
  let pump =
        withForeignPtr buf (readChunk (recvSocket fd)) >>= \case
          Just chunk -> unless (B.null chunk) (atomically (writeTQueue received (Just chunk)))
          Nothing -> do
            unregister r fd
            atomically (writeTQueue received Nothing)
      -- the end of the stream stays the end
      receive = atomically $ do
        x <- readTQueue received
        when (isNothing x) (unGetTQueue received x)
        pure x
      send = maybe (pure ()) (\bytes -> unless (BL.null bytes) (SBL.sendAll sock bytes))
  register r fd pump
  (WS.makeStream receive send >>= act) `finally` unregister r fd
