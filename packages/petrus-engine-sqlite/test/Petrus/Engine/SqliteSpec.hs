-- | The port of @tests/petrus/engine/test_sqlite_engine.py@ (SQLite Engine
-- ownership, fencing, and resource behavior), plus the composition's edges
-- the upstream file leaves to the store and the Engine suites.
module Petrus.Engine.SqliteSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (isInfixOf)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.Engine.Sqlite
import Petrus.Engine.SqliteSupport
import Petrus.Engine.TestSupport (advanceUntilRest, runtimeError, symbols, valueError)
import Petrus.HistoryStore.Sqlite (HistoryStoreError (..), SqliteHistoryStore (..), withSqliteHistoryStore, writerFencePaths)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), handlerTokens)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Motus.Dispatch.Local (defaultLocalDispatchOptions, toDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport (callWith, closingScratch, fixedWorker, openScratchDispatch, rawQuery, requireClaim)
import Petrus.Sqlite.Connection (SQLData (..))
import System.Directory (doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Posix.IO (closeFd, createPipe, fdToHandle)
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Posix.Process (ProcessStatus (..), exitImmediately, forkProcess, getProcessStatus)
import Test.Hspec

-- | @create_engine(path, _empty_net(), instance, dispatch=InlineDispatch({}))@.
createEmpty :: FilePath -> T.Text -> IO Engine.Engine
createEmpty path instanceId = noActivities >>= \port -> createEngine path emptyNet instanceId port Engine.defaultEngineOptions

-- | @load_engine(path, _empty_net(), instance, dispatch=InlineDispatch({}))@.
loadEmpty :: FilePath -> T.Text -> IO Engine.Engine
loadEmpty path instanceId = noActivities >>= \port -> loadEngine path emptyNet instanceId port Engine.defaultEngineOptions

-- | @pytest.raises(RuntimeError, match="second canonical writer")@.
secondWriter :: Selector FenceError
secondWriter failure = case failure of
  SecondWriter {} -> "second canonical writer" `isInfixOf` fenceErrorMessage failure
  _ -> False

spec :: Spec
spec = do
  describe "test_sqlite_engine.py" $ do
    it "fenced engine refuses same database and instance then releases" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      first <- createEmpty path "one"
      loadEmpty path "one" `shouldThrow` secondWriter
      Engine.close first
      resumed <- loadEmpty path "one"
      Engine.close resumed
      [lock] <- listDirectory (dir </> ".impetus-sqlite-locks")
      doesFileExist (dir </> ".impetus-sqlite-locks" </> lock) `shouldReturn` True

    it "fenced engines scope authority by database and instance" $ withScratch $ \dir -> do
      one <- createEmpty (dir </> "shared.sqlite3") "one"
      two <- createEmpty (dir </> "shared.sqlite3") "two"
      other <- createEmpty (dir </> "other.sqlite3") "one"
      mapM_ Engine.close [one, two, other]

    it "writing door poison releases sqlite resources" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      engine <- createEmpty path "one"
      Engine.seal engine (np "missing") `shouldThrow` valueError "cannot seal missing: not a transition of this net"
      resumed <- loadEmpty path "one"
      Engine.close resumed
      Engine.close engine

    it "spawned process contention and holder death release" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withRole "hold" [path, "one"] $ \holder -> do
        roleLine holder `shouldReturn` "ready"
        answer <- withRole "try-load" [path, "one"] roleLine
        BC.takeWhile (/= ':') answer `shouldBe` "RuntimeError"
      -- leaving withRole terminated the holder (SIGTERM) and reaped it
      reopened <- loadEmpty path "one"
      Engine.close reopened

    it "forked engine refuses and child does not retain fence" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      engine <- createEmpty path "one"
      (fromChild, childWrites) <- createPipe
      (childReads, toChild) <- createPipe
      child <- forkProcess $ do
        -- the child uses raw descriptors only: no Handle, no IO manager
        answer <- try (Engine.status engine)
        let line = either refusalLine (const "no refusal") answer
        _ <- fdWrite childWrites (line <> "\n")
        _ <- fdRead childReads 4
        exitImmediately ExitSuccess
      closeFd childWrites
      closeFd childReads
      replies <- fdToHandle fromChild
      line <- BC.hGetLine replies
      let (kind, message) = BC.breakSubstring ": " line
      kind `shouldBe` "RuntimeError"
      message `shouldSatisfy` BS.isInfixOf "inherited across fork"
      Engine.close engine
      reopened <- loadEmpty path "one"
      Engine.close reopened
      void (fdWrite toChild "exit")
      getProcessStatus True False child `shouldReturn` Just (Exited ExitSuccess)
      hClose replies
      closeFd toChild

  describe "beyond upstream" $ do
    it "an empty instance id is refused before anything is created" $ withScratch $ \dir -> do
      createEmpty (dir </> "history.sqlite3") "" `shouldThrow` (== EmptyInstance)
      fenceErrorMessage EmptyInstance `shouldBe` "SQLite Engine requires a non-empty string instance id, got ''"
      listDirectory dir `shouldReturn` []

    it "create refuses an existing Instance and releases the fence" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      createEmpty path "one" >>= Engine.close
      createEmpty path "one" `shouldThrow` valueError "cannot create Instance 'one': canonical history already exists"
      loadEmpty path "one" >>= Engine.close

    it "load refuses an absent Instance and releases the fence" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      loadEmpty path "one" `shouldThrow` valueError "cannot load Instance 'one': canonical history does not exist"
      createEmpty path "one" >>= Engine.close

    it "a refused History file releases the fence" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      createEmpty path "one" >>= Engine.close
      withSqliteHistoryStore path "one" (const (pure ()))
      void (rawQuery path "UPDATE impetus_history_events SET event_id = 'corrupt' WHERE position = 0" [])
      loadEmpty path "one" `shouldThrow` \(HistoryStoreError m) -> "non-dense or has corrupt event identity" `T.isInfixOf` m
      -- the fence is free again
      (_, lockPath) <- writerFencePaths path "one"
      doesFileExist lockPath `shouldReturn` True
      void (rawQuery path "UPDATE impetus_history_events SET event_id = 'one:0' WHERE position = 0" [])
      loadEmpty path "one" >>= Engine.close

    it "close is idempotent and every later door refuses" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      engine <- createEmpty path "one"
      Engine.close engine
      Engine.close engine
      Engine.status engine `shouldThrow` runtimeError "this Engine is closed; create or load a new Engine before observing or driving"
      loadEmpty path "one" >>= Engine.close

    it "a poisoned Engine releases the fence while it still refuses every door" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      engine <- createEmpty path "one"
      Engine.seal engine (np "missing") `shouldThrow` valueError "cannot seal missing: not a transition of this net"
      Engine.status engine
        `shouldThrow` runtimeError
          "this Engine is poisoned after a writing door failed (ValueError('cannot seal missing: not a transition of this net')): History, Instance, Dispatch, and the advancement lane may have advanced together — continue through a fresh Engine.load or provider load function"
      other <- loadEmpty path "one"
      Engine.status engine `shouldThrow` runtimeError "this Engine is poisoned"
      Engine.close other

    it "the order scenario runs, crashes mid-flight and resumes over SQLite" $ withScratch $ \dir -> do
      let path = dir </> "orders.sqlite3"
      prepared <- newIORef 0
      pool <- newInMemoryDispatch
      crashed <- createEngine path orderNet orderIdentity (inMemoryDispatch pool) (orderOptions prepared)
      deliverOrders crashed 3
      void (advanceUntilRest crashed)
      length <$> Engine.inFlight crashed `shouldReturn` 1
      Engine.close crashed
      resumedPrepares <- newIORef 0
      port <- orderActivities
      resumed <- loadEngine path orderNet orderIdentity port (orderOptions resumedPrepares)
      void (advanceUntilRest resumed)
      Engine.marking resumed `shouldReturn` settledMarking 3
      records <- Engine.records resumed
      Engine.close resumed
      length records `shouldBe` 66
      readIORef resumedPrepares `shouldReturn` 2
      withSqliteHistoryStore path orderIdentity (Store.records . (.history)) `shouldReturn` records

    it "the Engine, its History and the Local Dispatch share one database file" $ withScratch $ \dir -> closingScratch dir $ do
      let path = dir </> "application.db"
          net =
            netOf
              [place (np "ready"), place (np "done")]
              [Transition (np "work") (Just (HandlerSymbol "work")) [] []]
              [arc (np "ready") (np "work"), arc (np "work") (np "done")]
          handler' =
            ActivityBound
              ActivityHandler
                { prepare = \binding -> case bindingTokens binding of
                    first : _ -> Right (callWith "work" 2 30 first.payload id)
                    [] -> Left "IndexError('tuple index out of range')"
                , project = \_ result -> Right (handlerTokens [(np "done", [tokD "Done" result])])
                , projectFailure = Nothing
                }
          options = Engine.defaultEngineOptions {Engine.handlers = symbols [("work", handler')]}
      local <- openScratchDispatch path "one" defaultLocalDispatchOptions
      engine <- createEngine path net "one" (toDispatch local) options {Engine.marking = markingFromList [(np "ready", [tokD "Input" (Int 7)])]}
      ((.ready) <$> Engine.advance engine) `shouldReturn` True
      worker <- fixedWorker path "worker"
      attempt <- requireClaim worker
      attempt.invocation.input `shouldBe` Object [("value", Int 7)]
      Local.complete worker attempt (Object [("status", String "done")])
      void (advanceUntilRest engine)
      Engine.marking engine `shouldReturn` markingFromList [(np "done", [tokD "Done" (Object [("status", String "done")])])]
      Engine.close engine
      names <- map (\case [SQLText name] -> name; _ -> "") <$> rawQuery path "SELECT name FROM sqlite_master WHERE type = 'table'" []
      forM_ ["impetus_history_events", "impetus_history_schema", "impetus_local_dispatch_tasks"] $ \table ->
        names `shouldSatisfy` elem table
      -- and the History reloads through a fresh Engine
      local' <- openScratchDispatch path "one" defaultLocalDispatchOptions
      reloaded <- loadEngine path net "one" (toDispatch local') options
      done <- Engine.records reloaded
      length [() | RActivityCompleted _ <- done] `shouldBe` 1
      Engine.close reloaded

    it "a holder in another process and a Haskell contender: the refusal text" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withRole "hold" [path, "one"] $ \holder -> do
        roleLine holder `shouldReturn` "ready"
        answer <- outcomeLine (loadEmpty path "one" >>= Engine.close)
        (database, _) <- writerFencePaths path "one"
        answer `shouldBe` BC.pack ("RuntimeError: refusing second canonical writer for Instance 'one' in SQLite database " <> database)
        sendRole holder ""
        roleLine holder `shouldReturn` "released"
      loadEmpty path "one" >>= Engine.close
