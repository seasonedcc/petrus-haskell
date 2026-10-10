-- | SQLite Engine interop with the pinned reference
-- (@test/interop/engine_sqlite_interop.py@):
--
-- * the order scenario writes identical History rows in both
--   implementations (every column but @recorded_at@, and the DDL text);
-- * an Instance one side left mid-flight (a crash with a dispatched Activity
--   outstanding) resumes in the other to the same rows, prepare never
--   re-running;
-- * the writer fence excludes across languages in both directions, with the
--   same refusal text, and a holder's death releases it.
module Petrus.Engine.SqliteInteropSpec (spec) where

import Control.Monad (void)
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.Engine.Sqlite
import Petrus.Engine.SqliteSupport
import Petrus.Engine.TestSupport (advanceUntilRest)
import Petrus.HistoryStore.Sqlite (writerFencePaths)
import Petrus.Impetus.Petrinet (Marking)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.TestSupport.Python (expectLine, sendLine)
import System.Directory (copyFile, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

created :: FilePath -> Dispatch -> IO Engine.Engine
created path port = do
  prepared <- newIORef 0
  engine <- createEngine path orderNet orderIdentity port (orderOptions prepared)
  deliverOrders engine 3
  pure engine

-- | @run PATH@.
runScenario :: FilePath -> IO ()
runScenario path = do
  engine <- orderActivities >>= created path
  void (advanceUntilRest engine)
  Engine.close engine

-- | @crash PATH@: the Engine is abandoned with the first charge in flight;
-- closing releases the fence and the connection as a dead process would,
-- writing nothing.
crashScenario :: FilePath -> IO ()
crashScenario path = do
  pool <- newInMemoryDispatch
  engine <- created path (inMemoryDispatch pool)
  void (advanceUntilRest engine)
  length <$> Engine.inFlight engine `shouldReturn` 1
  Engine.close engine

-- | @resume PATH@; answers how many times prepare ran.
resumeScenario :: FilePath -> IO Int
resumeScenario path = do
  prepared <- newIORef 0
  port <- orderActivities
  engine <- loadEngine path orderNet orderIdentity port (orderOptions prepared)
  void (advanceUntilRest engine)
  Engine.close engine
  readIORef prepared

loadedMarking :: FilePath -> IO Marking
loadedMarking path = do
  port <- inMemoryDispatch <$> newInMemoryDispatch
  prepared <- newIORef 0
  engine <- loadEngine path orderNet orderIdentity port (orderOptions prepared)
  m <- Engine.marking engine
  Engine.close engine
  pure m

inspected :: BC.ByteString
inspected =
  "{\"done\": [[\"Settled\", {\"id\": \"o-1\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-2\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-3\", \"status\": \"captured\"}]]}\n66\n"

dumped :: FilePath -> IO BC.ByteString
dumped path = engineReference ["dump", path]

spec :: Spec
spec = describe "SQLite Engine interop with the reference" $ do
  it "the same scenario writes identical History rows in both implementations" $ withScratch $ \dir -> do
    let reference = dir </> "reference.sqlite3"
        ours = dir </> "haskell.sqlite3"
    void (engineReference ["run", reference])
    runScenario ours
    expected <- dumped reference
    dumped ours `shouldReturn` expected
    loadedMarking reference `shouldReturn` settledMarking 3
    engineReference ["inspect", ours] `shouldReturn` inspected

  it "an Instance the reference left mid-flight resumes in Haskell to the reference's own resumed rows" $ withScratch $ \dir -> do
    let ours = dir </> "haskell-resumed.sqlite3"
        reference = dir </> "reference-resumed.sqlite3"
    void (engineReference ["crash", ours])
    -- the reference died without closing: the WAL is copied along
    copyDatabase ours reference
    prepares <- resumeScenario ours
    prepares `shouldBe` 2 -- the in-flight charge's prepare never re-runs
    void (engineReference ["resume", reference])
    expected <- dumped reference
    dumped ours `shouldReturn` expected
    engineReference ["inspect", ours] `shouldReturn` inspected

  it "an Instance Haskell left mid-flight resumes in the reference to Haskell's own resumed rows" $ withScratch $ \dir -> do
    let theirs = dir </> "reference-resumed.sqlite3"
        ours = dir </> "haskell-resumed.sqlite3"
        referenceCrash = dir </> "reference-crash.sqlite3"
    crashScenario theirs
    void (engineReference ["crash", referenceCrash])
    crashed <- dumped referenceCrash
    dumped theirs `shouldReturn` crashed
    copyDatabase theirs ours
    void (engineReference ["resume", theirs])
    void (resumeScenario ours)
    expected <- dumped ours
    dumped theirs `shouldReturn` expected
    loadedMarking theirs `shouldReturn` settledMarking 3

  it "a reference Engine holds the fence against a Haskell Engine, with the reference's refusal text" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    withEngineReference ["hold", path, "one"] $ \holder -> do
      expectLine holder "ready"
      refusal <- outcomeLine (loadEmpty path)
      expected <- engineReference ["try-load", path, "one"]
      refusal <> "\n" `shouldBe` expected
      (database, _) <- writerFencePaths path "one"
      refusal `shouldBe` BC.pack ("RuntimeError: refusing second canonical writer for Instance 'one' in SQLite database " <> database)
      -- another Instance in the same file is free
      outcomeLine (createEmpty path "two") `shouldReturn` "opened"
      sendLine holder ""
      expectLine holder "released"
    outcomeLine (loadEmpty path) `shouldReturn` "opened"

  it "a Haskell Engine holds the fence against a reference Engine" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    engine <- noActivities >>= \port -> createEngine path emptyNet "one" port Engine.defaultEngineOptions
    answer <- engineReference ["try-load", path, "one"]
    (database, _) <- writerFencePaths path "one"
    answer `shouldBe` BC.pack ("RuntimeError: refusing second canonical writer for Instance 'one' in SQLite database " <> database <> "\n")
    Engine.close engine
    engineReference ["try-load", path, "one"] `shouldReturn` "opened\n"

  it "a dead holder of either language releases the fence to the other" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    -- a Haskell holder process, killed while holding
    withRole "hold" [path, "one"] $ \holder -> do
      roleLine holder `shouldReturn` "ready"
      BC.takeWhile (/= ':') <$> engineReference ["try-load", path, "one"] `shouldReturn` "RuntimeError"
    engineReference ["try-load", path, "one"] `shouldReturn` "opened\n"
    -- a reference holder, killed while holding
    withEngineReference ["hold", dir </> "other.sqlite3", "one"] $ \holder -> do
      expectLine holder "ready"
      BC.takeWhile (/= ':') <$> outcomeLine (loadEmpty (dir </> "other.sqlite3")) `shouldReturn` "RuntimeError"
    outcomeLine (loadEmpty (dir </> "other.sqlite3")) `shouldReturn` "opened"
  where
    loadEmpty path = noActivities >>= \port -> loadEngine path emptyNet "one" port Engine.defaultEngineOptions >>= Engine.close
    createEmpty path instanceId = noActivities >>= \port -> createEngine path emptyNet instanceId port Engine.defaultEngineOptions >>= Engine.close

-- | Copy a database with its WAL (and shared-memory index), as a crashed
-- process leaves them.
copyDatabase :: FilePath -> FilePath -> IO ()
copyDatabase from to = do
  copyFile from to
  let sidecar suffix = do
        present <- doesFileExist (from <> suffix)
        if present then copyFile (from <> suffix) (to <> suffix) else pure ()
  sidecar "-wal"
