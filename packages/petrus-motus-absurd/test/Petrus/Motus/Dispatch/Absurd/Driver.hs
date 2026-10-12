-- | Running the reference's driver scripts under the pinned upstream
-- environment: one-shot runs that print one JSON document, and interactive
-- runs speaking JSON lines over stdin and stdout (terminated, or killed
-- hard, by exact process).
module Petrus.Motus.Dispatch.Absurd.Driver
  ( runDriver
  , runDriverJson
  , Interactive
  , withDriver
  , sendLine
  , receiveJson
  , killHard
  ) where

import Control.Exception (bracket, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Petrus.Json (Json, parseJson, surrogateRefusingLoads)
import Petrus.TestSupport (PythonFailure (..), pythonExecutable, upstreamPetrus)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , cleanupProcess
  , createProcess
  , getPid
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)

scriptProcess :: FilePath -> [String] -> IO CreateProcess
scriptProcess script arguments = do
  exe <- pythonExecutable
  root <- upstreamPetrus
  path <- makeAbsolute script
  pure (proc exe ("-I" : path : arguments)) {cwd = Just root}

-- | Run a script to completion and answer its stdout; a non-zero exit
-- raises 'PythonFailure'.
runDriver :: FilePath -> [String] -> IO ByteString
runDriver script arguments = do
  process <- scriptProcess script arguments
  bracket (createProcess process {std_out = CreatePipe}) cleanupProcess $ \case
    (_, Just output, _, handle) -> do
      hSetBinaryMode output True
      out <- BS.hGetContents output
      waitForProcess handle >>= \case
        ExitSuccess -> pure out
        ExitFailure n -> throwIO (PythonFailure (script <> " " <> unwords (take 1 arguments) <> " exited " <> show n) out "")
    _ -> error "createProcess did not return a stdout pipe"

-- | 'runDriver', its stdout parsed as one JSON document.
runDriverJson :: FilePath -> [String] -> IO Json
runDriverJson script arguments = runDriver script arguments >>= parsed

parsed :: ByteString -> IO Json
parsed bytes = either (\problem -> throwIO (PythonFailure ("invalid JSON: " <> problem) bytes "")) pure (parseJson surrogateRefusingLoads bytes)

-- | A running interactive script.
data Interactive = Interactive Handle Handle ProcessHandle

-- | Run an interactive script for the duration of an action; afterwards its
-- stdin is closed and the exact process is terminated and reaped.
withDriver :: FilePath -> [String] -> (Interactive -> IO a) -> IO a
withDriver script arguments action = do
  process <- scriptProcess script arguments
  bracket
    (createProcess process {std_in = CreatePipe, std_out = CreatePipe})
    cleanupProcess
    ( \case
        (Just input, Just output, _, handle) -> do
          hSetBuffering input LineBuffering
          hSetBinaryMode output True
          action (Interactive input output handle)
        _ -> error "createProcess did not return pipes"
    )

sendLine :: Interactive -> ByteString -> IO ()
sendLine (Interactive input _ _) line = BS.hPut input (line <> "\n") >> hFlush input

-- | Read one JSON line (30 s at most).
receiveJson :: Interactive -> IO Json
receiveJson (Interactive _ output _) =
  timeout 30000000 (BC.hGetLine output) >>= \case
    Just line -> parsed line
    Nothing -> throwIO (PythonFailure "the reference script printed nothing for 30 s" "" "")

-- | SIGKILL the script's exact process (no cleanup runs in it: its
-- PostgreSQL sessions simply drop) and reap it.
killHard :: Interactive -> IO ()
killHard (Interactive input _ handle) = do
  hClose input
  getPid handle >>= mapM_ (signalProcess sigKILL)
  _ <- waitForProcess handle
  pure ()
