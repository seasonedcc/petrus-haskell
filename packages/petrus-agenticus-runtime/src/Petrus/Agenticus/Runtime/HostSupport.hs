-- | Pieces shared by the provider-managed hosts (Amp, Claude, Codex) that
-- have no single upstream module: CPython-faithful text helpers, the
-- observed platform, and a newline-delimited JSON sidecar process.
--
-- Amp and Claude drive Python SDKs upstream. Here a small verbatim-shaped
-- Python sidecar (shipped as a data file) hosts the SDK and speaks one
-- compact JSON value per line on stdin and stdout; 'Sidecar' is the
-- Haskell end of that pipe.
module Petrus.Agenticus.Runtime.HostSupport
  ( -- * Text
    stripAnsi
  , pyStrip
  , pyFirstWord
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
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Exception (IOException, SomeException, catch, finally, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Internal.Validate (pyIsSpace)
import Petrus.Agenticus.Runtime.Pi (micros, waitExit)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
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
