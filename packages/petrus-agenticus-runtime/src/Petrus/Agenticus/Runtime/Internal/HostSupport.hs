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
module Petrus.Agenticus.Runtime.Internal.HostSupport
  ( -- * Text
    stripAnsi
  , OutputRefusal (..)
  , sanitizeOutput
  , outputError
  , pyStrip
  , pyFirstWord
  , pyJsonLoadsBytes
    -- * Platform
  , observedPlatform
    -- * Sidecars
  , HelperSpec (..)
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
  , SidecarPool
  , newSidecarPool
  , closeSidecarPool
  , withSidecarPool
  , defaultSidecarPool
  , sidecarPoolPids
  , SidecarChannel
  , openSidecarChannel
  , channelSend
  , channelReceive
  , channelReceiveWithin
  , channelClose
  , channelAwaitEnd
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (IOException, SomeException, bracket, catch, finally, mask_, try)
import Control.Monad (filterM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error (AgenticusError)
import Petrus.Agenticus.Internal.Validate (encodeRefusal, pyIsSpace, utf8Length)
import Petrus.Agenticus.Runtime.Operation (runtimeProtocolError)
import Petrus.Agenticus.Runtime.Internal.Process (HelperSpec (..), Helper (..), Framing (..), spawnHelper, closeOnce, closeInput, stopReader, killGroup, awaitDrain, spawnPiped, waitExit, splitLines, micros)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Json.Python (PythonException)
import Petrus.Json.Python qualified as Python
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafePerformIO)
import Foreign.ForeignPtr (mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (castPtr)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hGetBufSome, hSetBinaryMode, hSetBuffering)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.Unistd (SystemID (..), getSystemID)
import System.Process
  ( ProcessHandle
  , getPid
  , getProcessExitCode
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
--
-- A surrogate code point passes through untouched ('J.fromCodePoints'),
-- and a text without ESC is returned as it is.
stripAnsi :: Text -> Text
stripAnsi value
  | T.any (== '\x1b') value = J.fromCodePoints (go (T.unpack value))
  | otherwise = value
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

-- | Why a provider's final text cannot be returned ('sanitizeOutput').
data OutputRefusal
  = -- | @str.encode()@'s @UnicodeEncodeError@ ('encodeRefusal').
    OutputUnencodable AgenticusError
  | -- | More UTF-8 bytes than the bound.
    OutputOverflow

-- | The hosts' final-text sanitizer: 'stripAnsi', every character @keep@
-- refuses replaced by U+FFFD, then @len(sanitized.encode()) > maximum@.
-- A lone surrogate survives every host's replacement (its code point is
-- above 159), so the measurement raises @UnicodeEncodeError@ first, at the
-- positions it has in the stripped text: the replacement keeps them all.
sanitizeOutput :: (Char -> Bool) -> Int -> Text -> Either OutputRefusal Text
sanitizeOutput keep maximum' value
  | Just refusal <- encodeRefusal stripped = Left (OutputUnencodable refusal)
  | utf8Length sanitized > maximum' = Left OutputOverflow
  | otherwise = Right sanitized
  where
    stripped = stripAnsi value
    sanitized = T.map (\c -> if keep c then c else '\xfffd') stripped

-- | The error an 'OutputRefusal' raises: the overflow is the given
-- @RuntimeProtocolError@ code.
outputError :: Text -> OutputRefusal -> AgenticusError
outputError overflow = \case
  OutputUnencodable refusal -> refusal
  OutputOverflow -> runtimeProtocolError overflow

-- | Python's @str.strip()@.
pyStrip :: Text -> Text
pyStrip = T.dropAround pyIsSpace

-- | @value.split(maxsplit=1)[0] if value else ""@ after a strip.
pyFirstWord :: Text -> Text
pyFirstWord value = T.takeWhile (not . pyIsSpace) (pyStrip value)

-- | @json.loads(bytes)@ (petrus-json's 'Python.loadsBytes': CPython's
-- @json.detect_encoding@, @surrogatepass@, then the scanner): the value,
-- with a lone surrogate kept as WTF-8 as CPython keeps it in a @str@, or
-- the exception CPython raises.
pyJsonLoadsBytes :: ByteString -> Either PythonException Json
pyJsonLoadsBytes = Python.loadsBytes

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

-- | One running sidecar process in its own session; its reader splits
-- stdout into lines.
newtype Sidecar = Sidecar Helper

sidecarPid :: Sidecar -> Maybe Int
sidecarPid (Sidecar h) = h.pid

-- | Start the sidecar, or 'Nothing' when it cannot be launched.
spawnSidecar :: HelperSpec -> IO (Maybe Sidecar)
spawnSidecar command = fmap Sidecar <$> spawnHelper Lines command

-- | @json.dumps(value, separators=(",", ":"))@ plus a newline.
sidecarFrame :: Json -> ByteString
sidecarFrame value = either (const "null") id (J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} value) <> "\n"

-- | Write one frame; 'False' when the pipe is gone.
sidecarSend :: Sidecar -> Json -> IO Bool
sidecarSend (Sidecar h) value = do
  sent <- try (B.hPut h.input (sidecarFrame value) >> hFlush h.input)
  pure $ case sent of
    Right () -> True
    Left (_ :: IOException) -> False

-- | The next frame, or 'Nothing' at end of output or for an undecodable
-- line.
sidecarReceive :: Sidecar -> IO (Maybe Json)
sidecarReceive (Sidecar h) =
  atomically (readTQueue h.received) >>= \case
    Nothing -> do
      atomically (unGetTQueue h.received Nothing)
      pure Nothing
    Just line -> pure (either (const Nothing) Just (J.parseJson J.surrogateRefusingLoads line))

-- | 'sidecarReceive' bounded by a number of seconds.
sidecarReceiveWithin :: Sidecar -> Double -> IO (Maybe Json)
sidecarReceiveWithin s seconds = maybe Nothing id <$> timeout (micros seconds) (sidecarReceive s)

-- | Close stdin, wait up to @grace@ seconds for a voluntary exit, then kill
-- the whole process group. 'True' when the process and its stderr drain
-- are proven gone.
sidecarClose :: Sidecar -> Double -> IO Bool
sidecarClose (Sidecar h) grace = closeOnce h $ do
  closeInput h
  exited <- waitExit h.process grace
  when (isNothing exited) (killGroup h)
  final <- maybe (waitExit h.process grace) (pure . Just) exited
  drained <- awaitDrain h grace
  stopReader h
  pure (isJust final && drained)

-- | Run a sidecar to completion with stdin closed, returning its exit code
-- and every frame it wrote, within @seconds@.
runSidecarOnce :: HelperSpec -> Double -> IO (Maybe (ExitCode, [Json]))
runSidecarOnce command seconds =
  spawnSidecar command >>= \case
    Nothing -> pure Nothing
    Just sidecar@(Sidecar h) -> do
      closeInput h
      collected <-
        timeout (micros seconds) (collect h [])
          `catch` \(_ :: SomeException) -> pure Nothing
      code <- waitExit h.process (if isJust collected then seconds else 0)
      void (sidecarClose sidecar 1)
      pure $ case (collected, code) of
        (Just values, Just exit) -> Just (exit, values)
        _ -> Nothing
  where
    collect h acc =
      atomically (readTQueue h.received) >>= \case
        Nothing -> pure (reverse acc)
        Just line -> case J.parseJson J.surrogateRefusingLoads line of
          Right value -> collect h (value : acc)
          Left _ -> collect h acc

-- ---------------------------------------------------------------------------
-- Shared sidecars

-- | One long-lived sidecar process serving many channels, so an SDK is
-- imported once per process, as upstream imports it once into its own
-- interpreter. Frames are @[channel, value]@ in both directions; @[channel]@
-- is the end of a channel (from Haskell: the end of the channel's input;
-- from the sidecar: the channel has finished its teardown).
data SharedSidecar = SharedSidecar
  { process :: ProcessHandle
  , pid :: Maybe Int
  , input :: Handle
  , writeLock :: MVar ()
  , slots :: TVar (Map Integer Slot)
  , alive :: TVar Bool
  -- ^ False once its output has ended (every channel is then ended too).
  , reaped :: TVar Bool
  -- ^ True once the process has been waited for.
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

-- | The shared sidecars one owner runs, at most one per command: every
-- channel opened for the same command shares its process, so an SDK is
-- imported once per pool. A sidecar that has died is replaced by the next
-- 'openSidecarChannel'. 'closeSidecarPool' stops them all.
newtype SidecarPool = SidecarPool (MVar (Maybe (Map SharedKey SharedSidecar)))

newSidecarPool :: IO SidecarPool
newSidecarPool = SidecarPool <$> newMVar (Just Map.empty)

-- | The pool the Claude and Amp hosts use unless given their own: one per
-- Haskell process (the reference imports each SDK once into its
-- interpreter), never closed; its sidecars end with the process, whose exit
-- closes their input.
defaultSidecarPool :: SidecarPool
defaultSidecarPool = unsafePerformIO newSidecarPool
{-# NOINLINE defaultSidecarPool #-}

-- | Close the pool: no channel opens on it again, and each sidecar's input
-- is ended (its open channels are torn down as at any end of input). A
-- sidecar not reaped within @grace@ seconds is killed with its whole
-- process group, and then reaped.
closeSidecarPool :: SidecarPool -> Double -> IO ()
closeSidecarPool (SidecarPool pool) grace = do
  known <- modifyMVar pool (\current -> pure (Nothing, maybe [] Map.elems current))
  forM_ known $ \s -> withMVar s.writeLock (const (hClose s.input)) `catch` \(_ :: IOException) -> pure ()
  forM_ known $ \s -> do
    reapedInTime <- timeout (micros grace) (atomically (readTVar s.reaped >>= check))
    when (isNothing reapedInTime) $
      mapM_ (\n -> signalProcessGroup sigKILL (fromIntegral n) `catch` \(_ :: IOException) -> pure ()) s.pid
    atomically (readTVar s.reaped >>= check)

-- | A private pool for the extent of an action, closed (with @grace@) after it.
withSidecarPool :: Double -> (SidecarPool -> IO a) -> IO a
withSidecarPool grace = bracket newSidecarPool (`closeSidecarPool` grace)

-- | The process ids of the pool's running sidecars.
sidecarPoolPids :: SidecarPool -> IO [Int]
sidecarPoolPids (SidecarPool pool) = do
  known <- maybe [] Map.elems <$> readMVar pool
  live <- filterM (readTVarIO . (.alive)) known
  pure [n | Just n <- map (.pid) live]

-- | Open a channel on the pool's sidecar for @command@, starting the
-- sidecar first when none is running (or the last one has died); 'Nothing'
-- when it cannot be launched or the pool is closed.
openSidecarChannel :: SidecarPool -> HelperSpec -> IO (Maybe SidecarChannel)
openSidecarChannel (SidecarPool pool) command = attempt (2 :: Int)
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
    running = mask_ . modifyMVar pool $ \case
      Nothing -> pure (Nothing, Nothing)
      Just known -> do
        current <- case Map.lookup key known of
          Just s -> do
            up <- readTVarIO s.alive
            -- A sidecar can have exited before its output's end is read:
            -- it is as dead as one whose end has been.
            exited <- isJust <$> getProcessExitCode s.process
            pure (if up && not exited then Just s else Nothing)
          Nothing -> pure Nothing
        case current of
          Just s -> pure (Just known, Just s)
          Nothing ->
            spawnShared command >>= \case
              Nothing -> pure (Just (Map.delete key known), Nothing)
              Just s -> pure (Just (Map.insert key s known), Just s)

spawnShared :: HelperSpec -> IO (Maybe SharedSidecar)
spawnShared command = do
  spawned <- spawnPiped command.executable command.arguments command.directory command.environment
  case spawned of
    Just (i, o, e, p) -> do
      mapM_ (`hSetBinaryMode` True) [i, o, e]
      hSetBuffering i (BlockBuffering Nothing)
      pid <- fmap fromIntegral <$> getPid p
      s <- SharedSidecar p pid i <$> newMVar () <*> newTVarIO Map.empty <*> newTVarIO True <*> newTVarIO False <*> newTVarIO 0
      _ <- forkIO (drain e)
      buffer <- mallocForeignPtrBytes readSize
      _ <- forkIO (readFrames s o buffer B.empty `finally` finish s p [i, o, e])
      pure (Just s)
    Nothing -> pure Nothing
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
    dispatch s line = case J.parseJson J.surrogateRefusingLoads line of
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
      atomically (writeTVar s.reaped True)

endSlot :: Slot -> STM ()
endSlot slot = do
  writeTQueue slot.inbox Nothing
  writeTVar slot.ended True

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
