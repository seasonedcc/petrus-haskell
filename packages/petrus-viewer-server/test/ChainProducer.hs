-- | Test fixture: a Haskell Petrus Engine observed over
-- observation-protocol-v1 (petrus-observation-http), driven over stdin.
--
-- Usage: petrus-viewer-server-test --chain-producer INSTANCE
--
-- (The test executable doubles as the producer process: an executable of
-- this package cannot depend on petrus-observation-http, whose own tests
-- use this package's @petrus@ executable as a build tool.)
--
-- Creates the chain Net @a -> t1 -> b -> t2 -> c -> t3 -> d@ (name
-- @viewer-chain@) with one token in @a@, serves it on an ephemeral
-- loopback port, and prints that port. Each stdin line @advance@ runs one
-- 'Engine.advance' and prints the number of firings it applied; end of
-- input closes the Engine and the server. The Python twin is
-- @test/chain_producer.py@ (the same Net through the pinned upstream
-- reference), so the viewer can be pointed at either producer in the same
-- scenario.
module ChainProducer (serveChain) where

import Control.Monad (unless)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet (NetSpec (..), Token (..), arc, markingFromList, mkNet, netSpec, place, transition)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Observation.Http (engineDoors, observationHandler, observationServerConfig, serverPort, withRunningServer)
import System.Exit (die)
import System.IO (BufferMode (..), hSetBuffering, isEOF, stdout)

serveChain :: T.Text -> IO ()
serveChain instanceId = do
  hSetBuffering stdout LineBuffering
  let spec =
        (netSpec
          (map place ["a", "b", "c", "d"])
          (map transition ["t1", "t2", "t3"])
          [arc "a" "t1", arc "t1" "b", arc "b" "t2", arc "t2" "c", arc "c" "t3", arc "t3" "d"])
          { name = Just "viewer-chain" }
  net <- either (die . T.unpack) pure (mkNet spec)
  store <- inMemoryHistoryStore
  dispatch <- inMemoryDispatch <$> newInMemoryDispatch
  engine <-
    Engine.create net instanceId store dispatch
      Engine.defaultEngineOptions {Engine.marking = markingFromList [("a", [Token (Just "value") (Object [("n", Int 1)])])]}
  withRunningServer (observationServerConfig "127.0.0.1" 0) (observationHandler (engineDoors engine)) $ \server -> do
    print =<< serverPort server
    let loop = do
          eof <- isEOF
          unless eof $ do
            line <- getLine
            case words line of
              ["advance"] -> do
                Engine.DriveOutcome {Engine.firings = fired} <- Engine.advance engine
                print (length fired)
              _ -> putStrLn ("unknown command: " <> line)
            loop
    loop
  Engine.close engine
