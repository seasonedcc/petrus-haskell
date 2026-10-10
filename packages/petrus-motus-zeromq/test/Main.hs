-- | The ZeroMQ transport against the reference's
-- @tests/petrus/motus/transport/test_zeromq_dispatch_transport.py@, plus
-- the cross-implementation interop suite. Re-executed with
-- 'serverModeVariable' set, the executable is instead one of the server
-- processes those tests start.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Petrus.Json (Json (..), defaultDumps, dumps)
import Petrus.Motus.Dispatch (WorkerDispatch (..))
import Petrus.Motus.Transport.ZeroMQ (fromFactory, maxMessageBytes, serveForever, waitReady)
import Petrus.Motus.Transport.ZeroMQ.Cli (serverMainWith)
import Petrus.Motus.Transport.ZeroMQ.InteropSpec qualified as InteropSpec
import Petrus.Motus.Transport.ZeroMQ.Support (localWorker, serverModeVariable)
import Petrus.Motus.Transport.ZeroMQ.TransportSpec qualified as TransportSpec
import System.Environment (getArgs, lookupEnv)
import System.IO (hFlush, stdout)
import Test.Hspec

main :: IO ()
main =
  lookupEnv serverModeVariable >>= \case
    Just "server" -> getArgs >>= serverMainWith "python -m petrus.motus.transport.zeromq"
    Just "delayed" -> getArgs >>= delayedCompletionServer
    _ -> hspec $ do
      describe "test_zeromq_dispatch_transport.py" TransportSpec.spec
      describe "ZeroMQ interop with the reference" InteropSpec.spec

-- | The reference's @_start_delayed_completion_server_process@ script: a
-- server whose completion commits, records that it did, and then hangs
-- for 10 s (so the client's reply is lost when the process is killed).
delayedCompletionServer :: [String] -> IO ()
delayedCompletionServer = \case
  [path, endpoint, committed] -> do
    let factory queues worker = do
          provider <- localWorker path queues worker
          pure
            provider
              { complete = \attempt result -> do
                  provider.complete attempt result
                  writeFile committed "committed"
                  threadDelay 10000000
              }
    server <- fromFactory (T.pack endpoint) factory maxMessageBytes
    void . forkIO $ do
      bound <- waitReady server 5
      case dumps defaultDumps (Object [("ready", Bool True), ("endpoint", String bound)]) of
        Right line -> BS.putStr (line <> "\n") >> hFlush stdout
        Left _ -> pure ()
    serveForever server
  arguments -> fail ("delayed server arguments: " <> show arguments)
