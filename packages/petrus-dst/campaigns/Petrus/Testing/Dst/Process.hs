-- | The DST tooling's one child-process capture: @subprocess.run(...,
-- capture_output=True, timeout=...)@ and @Popen.communicate(timeout=...)@.
--
-- Both output streams drain on owned threads ('withAsync'), so a failing
-- read surfaces as that exception when the result is collected, never as a
-- blocked 'MVar', and an exception anywhere cancels both drains and cleans
-- the child up ('withCreateProcess').
module Petrus.Testing.Dst.Process
  ( Finish (..)
  , captureWithin
  , exitInt
  , killNow
  ) where

import Control.Concurrent.Async (wait, withAsync)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Posix.Process (exitInt)
import System.IO (Handle)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
import System.Timeout (timeout)

-- | How the child ended: on its own with this exit code, or past the
-- timeout, after the escalation that ended it.
data Finish a = Exited Int | Escalated a

-- | Run the child with both output streams piped and no stdin, wait up to
-- @micros@ for it, and on expiry run @escalate@ (which must end it). Then
-- collect everything both streams wrote, decoded as UTF-8 with replacement.
captureWithin :: CreateProcess -> Int -> (ProcessHandle -> IO a) -> IO (Finish a, Text, Text)
captureWithin config micros escalate =
  withCreateProcess config {std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe} $ \_ out err child ->
    withAsync (drain out) $ \stdoutText ->
      withAsync (drain err) $ \stderrText -> do
        finished <- timeout micros (waitForProcess child)
        finish <- maybe (Escalated <$> escalate child) (pure . Exited . exitInt) finished
        (finish,,) <$> wait stdoutText <*> wait stderrText

drain :: Maybe Handle -> IO Text
drain = maybe (pure "") (fmap TE.decodeUtf8Lenient . BS.hGetContents)

-- | @Popen.kill()@ then @wait()@, as @subprocess.run@ does on its timeout:
-- SIGKILL the child itself and reap it.
killNow :: ProcessHandle -> IO Int
killNow child = do
  getPid child >>= mapM_ (signalProcess sigKILL)
  exitInt <$> waitForProcess child
