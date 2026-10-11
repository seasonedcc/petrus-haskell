-- | Pieces shared by the provider-managed hosts (Amp, Claude, Codex) that
-- have no single upstream module: CPython-faithful text helpers, the
-- observed platform, and newline-delimited JSON sidecar processes.
--
-- Amp and Claude drive Python SDKs upstream. Here a small verbatim-shaped
-- Python sidecar (shipped as a data file) hosts the SDK and speaks one
-- compact JSON value per line on stdin and stdout. 'Sidecar' is the Haskell
-- end of a one-off sidecar process (the probes' @version@ and @protocol@
-- modes). 'SidecarChannel' is one channel of a shared, long-lived sidecar
-- that serves every SDK stream or client of this process, so the SDK is
-- imported once per process, as upstream imports it once.
module Petrus.Agenticus.Runtime.HostSupport
  ( -- * Text
    stripAnsi
  , pyStrip
  , pyFirstWord
  , pyJsonLoadsBytes
    -- * Platform
  , observedPlatform
    -- * Sidecars
  , SidecarCommand (..)
  , Sidecar
  , spawnSidecar
  , sidecarSend
  , sidecarReceive
  , sidecarReceiveWithin
  , sidecarClose
  , sidecarPid
  , sidecarFrame
  , runSidecarOnce
    -- * Shared sidecars
  , SidecarChannel
  , openSidecarChannel
  , channelSend
  , channelReceive
  , channelReceiveWithin
  , channelClose
  , channelAwaitEnd
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (IOException, SomeException, catch, evaluate, finally, mask_, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (OnDecodeError, UnicodeException, strictDecode)
import Petrus.Agenticus.Internal.Validate (pyIsSpace)
import Petrus.Agenticus.Runtime.Pi (micros, waitExit)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafeDupablePerformIO, unsafePerformIO)
import Foreign.ForeignPtr (mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (castPtr)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hGetBufSome, hSetBinaryMode, hSetBuffering)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.Unistd (SystemID (..), getSystemID)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Text

-- | @re.sub(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))", "", value)@.
--
-- The three CSI classes are disjoint, so the greedy match never needs to
-- backtrack; the OSC body runs to the first BEL, or else (backtracking from
-- the end of the text) to the last @ESC \\@.
stripAnsi :: Text -> Text
stripAnsi = T.pack . go . T.unpack
  where
    go = \case
      [] -> []
      '\x1b' : rest | Just after <- escape rest -> go after
      c : rest -> c : go rest
    escape = \case
      '[' : rest ->
        let afterParams = dropWhile (inRange '0' '?') rest
            afterInter = dropWhile (inRange ' ' '/') afterParams
         in case afterInter of
              final : after | inRange '@' '~' final -> Just after
              _ -> Nothing
      ']' : rest -> case break (== '\x07') rest of
        (_, _ : after) -> Just after
        (body, []) -> lastStringTerminator body
      _ -> Nothing
    inRange lo hi c = c >= lo && c <= hi
    lastStringTerminator body =
      let candidates = [drop (i + 2) body | (i, ('\x1b' : '\\' : _)) <- zip [0 :: Int ..] (tailsOf body)]
       in if null candidates then Nothing else Just (last candidates)
    tailsOf xs = case xs of
      [] -> []
      _ : rest -> xs : tailsOf rest

-- | Python's @str.strip()@.
pyStrip :: Text -> Text
pyStrip = T.dropAround pyIsSpace

-- | @value.split(maxsplit=1)[0] if value else ""@ after a strip.
pyFirstWord :: Text -> Text
pyFirstWord value = T.takeWhile (not . pyIsSpace) (pyStrip value)

-- | @json.loads(bytes)@: CPython's @json.detect_encoding@, then the scanner.
pyJsonLoadsBytes :: ByteString -> Maybe Json
pyJsonLoadsBytes bytes = do
  text <- decodeDetected
  either (const Nothing) Just (J.parseJson J.pythonLoads (TE.encodeUtf8 text))
  where
    strict decode input = either (const Nothing) Just (decode input)
    viaWith :: (OnDecodeError -> ByteString -> Text) -> ByteString -> Either UnicodeException Text
    viaWith decode input = unsafeDupablePerformIO (try (evaluate (let t = decode strictDecode input in T.length t `seq` t)))
    starts = (`B.isPrefixOf` bytes)
    byteAt = B.index bytes
    decodeDetected
      | starts "\x00\x00\xfe\xff" = strict (viaWith TE.decodeUtf32BEWith) (B.drop 4 bytes)
      | starts "\xff\xfe\x00\x00" = strict (viaWith TE.decodeUtf32LEWith) (B.drop 4 bytes)
      | starts "\xfe\xff" = strict (viaWith TE.decodeUtf16BEWith) (B.drop 2 bytes)
      | starts "\xff\xfe" = strict (viaWith TE.decodeUtf16LEWith) (B.drop 2 bytes)
      | starts "\xef\xbb\xbf" = strict TE.decodeUtf8' (B.drop 3 bytes)
      | B.length bytes >= 4 && byteAt 0 == 0 =
          if byteAt 1 /= 0 then strict (viaWith TE.decodeUtf16BEWith) bytes else strict (viaWith TE.decodeUtf32BEWith) bytes
      | B.length bytes >= 4 && byteAt 1 == 0 =
          if byteAt 2 /= 0 || byteAt 3 /= 0 then strict (viaWith TE.decodeUtf16LEWith) bytes else strict (viaWith TE.decodeUtf32LEWith) bytes
      | B.length bytes == 2 && byteAt 0 == 0 = strict (viaWith TE.decodeUtf16BEWith) bytes
      | B.length bytes == 2 && byteAt 1 == 0 = strict (viaWith TE.decodeUtf16LEWith) bytes
      | otherwise = strict TE.decodeUtf8' bytes

-- ---------------------------------------------------------------------------
-- Platform

-- | @(platform.system().lower() or "unknown", platform.machine().lower() or
-- "unknown")@.
observedPlatform :: IO (Text, Text)
observedPlatform = do
  system <- getSystemID
  pure (nonEmpty (T.toLower (T.pack (systemName system))), nonEmpty (T.toLower (T.pack (machine system))))
  where
    nonEmpty value = if T.null value then "unknown" else value

-- ---------------------------------------------------------------------------
-- Sidecars

-- | How to start one sidecar: the interpreter, its arguments, the working
-- directory, and an optional environment (inherited when absent).
data SidecarCommand = SidecarCommand
  { executable :: FilePath
  , arguments :: [String]
  , directory :: Maybe FilePath
  , environment :: Maybe [(String, String)]
  }

-- | One running sidecar process in its own session.
data Sidecar = Sidecar
  { process :: ProcessHandle
  , pid :: Maybe Int
  , input :: Handle
  , output :: Handle
  , errors :: Handle
  , frames :: TQueue (Maybe ByteString)
  , reader :: ThreadId
  , drainer :: ThreadId
  , drained :: TVar Bool
  , closed :: IORef Bool
  }

sidecarPid :: Sidecar -> Maybe Int
sidecarPid s = s.pid

-- | Start the sidecar, or 'Nothing' when it cannot be launched.
spawnSidecar :: SidecarCommand -> IO (Maybe Sidecar)
spawnSidecar command = do
  spawned <-
    try . createProcess $
      (proc command.executable command.arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , cwd = command.directory
        , env = command.environment
        , new_session = True
        , close_fds = True
        }
  case spawned of
    Right (Just i, Just o, Just e, p) -> do
      mapM_ (`hSetBinaryMode` True) [i, o, e]
      hSetBuffering i (BlockBuffering Nothing)
      pid <- fmap fromIntegral <$> getPid p
      drained <- newTVarIO False
      drainer <- forkIO (drain e `finally` atomically (writeTVar drained True))
      frames <- newTQueueIO
      reader <- forkIO (readLines o frames B.empty)
      closed <- newIORef False
      pure (Just (Sidecar p pid i o e frames reader drainer drained closed))
    Right _ -> pure Nothing
    Left (_ :: IOException) -> pure Nothing
  where
    drain h = do
      chunk <- B.hGetSome h 65536 `catch` \(_ :: IOException) -> pure B.empty
      unless (B.null chunk) (drain h)
    readLines h queue pending = do
      chunk <- B.hGetSome h 65536 `catch` \(_ :: IOException) -> pure B.empty
      if B.null chunk
        then atomically (writeTQueue queue Nothing)
        else do
          let (complete, rest) = splitComplete (pending <> chunk)
          atomically (mapM_ (writeTQueue queue . Just) complete)
          readLines h queue rest
    splitComplete bytes = case BC.elemIndex '\n' bytes of
      Nothing -> ([], bytes)
      Just i ->
        let (rest', remaining) = splitComplete (B.drop (i + 1) bytes)
         in (B.take i bytes : rest', remaining)

-- | @json.dumps(value, separators=(",", ":"))@ plus a newline.
sidecarFrame :: Json -> ByteString
sidecarFrame value = either (const "null") id (J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} value) <> "\n"

-- | Write one frame; 'False' when the pipe is gone.
sidecarSend :: Sidecar -> Json -> IO Bool
sidecarSend s value = do
  sent <- try (B.hPut s.input (sidecarFrame value) >> hFlush s.input)
  pure $ case sent of
    Right () -> True
    Left (_ :: IOException) -> False

-- | The next frame, or 'Nothing' at end of output or for an undecodable
-- line.
sidecarReceive :: Sidecar -> IO (Maybe Json)
sidecarReceive s =
  atomically (readTQueue s.frames) >>= \case
    Nothing -> do
      atomically (unGetTQueue s.frames Nothing)
      pure Nothing
    Just line -> pure (either (const Nothing) Just (J.parseJson J.pythonLoads line))

-- | 'sidecarReceive' bounded by a number of seconds.
sidecarReceiveWithin :: Sidecar -> Double -> IO (Maybe Json)
sidecarReceiveWithin s seconds = maybe Nothing id <$> timeout (micros seconds) (sidecarReceive s)

-- | Close stdin, wait up to @grace@ seconds for a voluntary exit, then kill
-- the whole process group. 'True' when the process and its stderr drain
-- are proven gone.
sidecarClose :: Sidecar -> Double -> IO Bool
sidecarClose s grace = do
  already <- readIORef s.closed
  if already
    then isJust <$> getProcessExitCode s.process
    else do
      writeIORef s.closed True
      hClose s.input `catch` \(_ :: IOException) -> pure ()
      exited <- waitExit s.process grace
      when (isNothing exited) $
        mapM_ (\pid -> signalProcessGroup sigKILL (fromIntegral pid) `catch` \(_ :: IOException) -> pure ()) s.pid
      final <- maybe (waitExit s.process grace) (pure . Just) exited
      _ <- timeout (micros grace) (atomically (readTVar s.drained >>= check))
      done <- readTVarIO s.drained
      unless done (killThread s.drainer)
      killThread s.reader
      hClose s.output `catch` \(_ :: IOException) -> pure ()
      hClose s.errors `catch` \(_ :: IOException) -> pure ()
      pure (isJust final && done)

-- | Run a sidecar to completion with stdin closed, returning its exit code
-- and every frame it wrote, within @seconds@.
runSidecarOnce :: SidecarCommand -> Double -> IO (Maybe (ExitCode, [Json]))
runSidecarOnce command seconds =
  spawnSidecar command >>= \case
    Nothing -> pure Nothing
    Just s -> do
      hClose s.input `catch` \(_ :: IOException) -> pure ()
      collected <-
        timeout (micros seconds) (collect s [])
          `catch` \(_ :: SomeException) -> pure Nothing
      code <- waitExit s.process (if isJust collected then seconds else 0)
      void (sidecarClose s 1)
      pure $ case (collected, code) of
        (Just values, Just exit) -> Just (exit, values)
        _ -> Nothing
  where
    collect s acc =
      atomically (readTQueue s.frames) >>= \case
        Nothing -> pure (reverse acc)
        Just line -> case J.parseJson J.pythonLoads line of
          Right value -> collect s (value : acc)
          Left _ -> collect s acc

-- ---------------------------------------------------------------------------
-- Shared sidecars

-- | One long-lived sidecar process serving many channels, so an SDK is
-- imported once per process, as upstream imports it once into its own
-- interpreter. Frames are @[channel, value]@ in both directions; @[channel]@
-- is the end of a channel (from Haskell: the end of the channel's input;
-- from the sidecar: the channel has finished its teardown).
data SharedSidecar = SharedSidecar
  { input :: Handle
  , writeLock :: MVar ()
  , slots :: TVar (Map Integer Slot)
  , alive :: TVar Bool
  , nextChannel :: TVar Integer
  }

data Slot = Slot
  { inbox :: TQueue (Maybe Json)
  , ended :: TVar Bool
  }

-- | One channel of a shared sidecar: the Haskell end of one SDK client or
-- stream.
data SidecarChannel = SidecarChannel
  { shared :: SharedSidecar
  , channel :: Integer
  , slot :: Slot
  , closing :: IORef Bool
  }

type SharedKey = (FilePath, [String], Maybe FilePath, Maybe [(String, String)])

sharedSidecars :: MVar (Map SharedKey SharedSidecar)
sharedSidecars = unsafePerformIO (newMVar Map.empty)
{-# NOINLINE sharedSidecars #-}

-- | Open a channel on the shared sidecar that runs @command@, starting the
-- sidecar first when none is running; 'Nothing' when it cannot be launched.
openSidecarChannel :: SidecarCommand -> IO (Maybe SidecarChannel)
openSidecarChannel command = attempt (2 :: Int)
  where
    key = (command.executable, command.arguments, command.directory, command.environment)
    attempt remaining
      | remaining <= 0 = pure Nothing
      | otherwise =
          running >>= \case
            Nothing -> pure Nothing
            Just s -> do
              slot <- Slot <$> newTQueueIO <*> newTVarIO False
              registered <- atomically $ do
                up <- readTVar s.alive
                if not up
                  then pure Nothing
                  else do
                    n <- readTVar s.nextChannel
                    writeTVar s.nextChannel (n + 1)
                    modifyTVar' s.slots (Map.insert n slot)
                    pure (Just n)
              case registered of
                Nothing -> attempt (remaining - 1)
                Just n -> Just . SidecarChannel s n slot <$> newIORef False
    running = mask_ . modifyMVar sharedSidecars $ \known -> do
      current <- case Map.lookup key known of
        Just s -> do
          up <- readTVarIO s.alive
          pure (if up then Just s else Nothing)
        Nothing -> pure Nothing
      case current of
        Just s -> pure (known, Just s)
        Nothing ->
          spawnShared command >>= \case
            Nothing -> pure (Map.delete key known, Nothing)
            Just s -> pure (Map.insert key s known, Just s)

spawnShared :: SidecarCommand -> IO (Maybe SharedSidecar)
spawnShared command = do
  spawned <-
    try . createProcess $
      (proc command.executable command.arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , cwd = command.directory
        , env = command.environment
        , new_session = True
        , close_fds = True
        }
  case spawned of
    Right (Just i, Just o, Just e, p) -> do
      mapM_ (`hSetBinaryMode` True) [i, o, e]
      hSetBuffering i (BlockBuffering Nothing)
      s <- SharedSidecar i <$> newMVar () <*> newTVarIO Map.empty <*> newTVarIO True <*> newTVarIO 0
      _ <- forkIO (drain e)
      buffer <- mallocForeignPtrBytes readSize
      _ <- forkIO (readFrames s o buffer B.empty `finally` finish s p [i, o, e])
      pure (Just s)
    Right _ -> pure Nothing
    Left (_ :: IOException) -> pure Nothing
  where
    drain h = do
      chunk <- B.hGetSome h 65536 `catch` \(_ :: IOException) -> pure B.empty
      unless (B.null chunk) (drain h)
    -- One reusable read buffer: only the bytes read are copied out, where
    -- 'B.hGetSome' would allocate (and pin) the whole read size each time.
    readSize = 65536
    readFrames s h buffer pending = do
      chunk <-
        withForeignPtr buffer (\ptr -> hGetBufSome h ptr readSize >>= \n -> B.packCStringLen (castPtr ptr, n))
          `catch` \(_ :: IOException) -> pure B.empty
      unless (B.null chunk) $ do
        let (complete, rest) = splitLines (if B.null pending then chunk else pending <> chunk)
        mapM_ (dispatch s) complete
        readFrames s h buffer rest
    dispatch s line = case J.parseJson J.pythonLoads line of
      Right (Array [Int n, value]) -> atomically $ do
        known <- readTVar s.slots
        forM_ (Map.lookup n known) (\slot -> writeTQueue slot.inbox (Just value))
      Right (Array [Int n]) -> atomically $ do
        known <- readTVar s.slots
        forM_ (Map.lookup n known) endSlot
        writeTVar s.slots (Map.delete n known)
      _ -> pure ()
    finish s p handles = do
      atomically $ do
        writeTVar s.alive False
        known <- readTVar s.slots
        writeTVar s.slots Map.empty
        mapM_ endSlot known
      mapM_ (\h -> hClose h `catch` \(_ :: IOException) -> pure ()) handles
      -- Reap the process: its stdin is closed now, so it exits.
      void (try (waitForProcess p) :: IO (Either SomeException ExitCode))

endSlot :: Slot -> STM ()
endSlot slot = do
  writeTQueue slot.inbox Nothing
  writeTVar slot.ended True

-- | Split the complete newline-terminated lines off the front of a buffer.
splitLines :: ByteString -> ([ByteString], ByteString)
splitLines bytes = case BC.elemIndex '\n' bytes of
  Nothing -> ([], bytes)
  Just i ->
    let (rest', remaining) = splitLines (B.drop (i + 1) bytes)
     in (B.take i bytes : rest', remaining)

-- | Write one frame on the channel; 'False' when the sidecar is gone or the
-- channel is closing.
channelSend :: SidecarChannel -> Json -> IO Bool
channelSend c value = do
  done <- readIORef c.closing
  if done
    then pure False
    else writeShared c.shared (BB.char7 '[' <> BB.integerDec c.channel <> BB.char7 ',' <> BB.byteString encoded <> "]\n")
  where
    encoded = either (const "null") id (J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} value)

writeShared :: SharedSidecar -> BB.Builder -> IO Bool
writeShared s frame = do
  sent <- try (withMVar s.writeLock (const (BB.hPutBuilder s.input frame >> hFlush s.input)))
  pure $ case sent of
    Right () -> True
    Left (_ :: IOException) -> False

-- | The channel's next frame, or 'Nothing' once the channel has ended (and
-- from then on).
channelReceive :: SidecarChannel -> IO (Maybe Json)
channelReceive c =
  atomically (readTQueue c.slot.inbox) >>= \case
    Nothing -> do
      atomically (unGetTQueue c.slot.inbox Nothing)
      pure Nothing
    frame -> pure frame

-- | 'channelReceive' bounded by a number of seconds.
channelReceiveWithin :: SidecarChannel -> Double -> IO (Maybe Json)
channelReceiveWithin c seconds = maybe Nothing id <$> timeout (micros seconds) (channelReceive c)

-- | End the channel's input and wait up to @grace@ seconds for the sidecar
-- to finish the channel's teardown; 'True' when it has.
channelClose :: SidecarChannel -> Double -> IO Bool
channelClose c grace = do
  already <- atomicModifyIORef' c.closing (True,)
  unless already $ do
    finished <- readTVarIO c.slot.ended
    unless finished (void (writeShared c.shared (BB.char7 '[' <> BB.integerDec c.channel <> "]\n")))
  _ <- timeout (micros grace) (atomically (readTVar c.slot.ended >>= check))
  readTVarIO c.slot.ended

-- | Wait up to @grace@ seconds for a channel the sidecar ends on its own
-- (after a frame that says so), without ending its input first; 'True'
-- when it has ended. The channel's input is ended only when it has not.
channelAwaitEnd :: SidecarChannel -> Double -> IO Bool
channelAwaitEnd c grace = do
  _ <- timeout (micros grace) (atomically (readTVar c.slot.ended >>= check))
  channelClose c 0
