-- | "Petrus.Agenticus.Internal.Sqlite" opens connections as CPython's
-- @sqlite3.connect@ does: a connection that meets a locked database waits
-- for it (the default @timeout=5.0@), and only an explicit zero timeout
-- fails at once. A ledger shared with a reference process (or another
-- connection checkpointing) is then read the way the reference reads it.
module Petrus.Agenticus.SqliteSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (bracket, finally, try)
import Data.IORef
import Petrus.Agenticus.ConnectionSupport (withScratch)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite
import Petrus.TestSupport.Python (python)
import System.FilePath ((</>))
import Test.Hspec

-- | A database whose only other connection holds an exclusive lock until
-- the action ends, or until the delay (in microseconds) the action passes
-- to its release callback has elapsed.
withLockedDatabase :: (FilePath -> (Int -> IO ()) -> IO a) -> IO a
withLockedDatabase action = withScratch $ \tmp -> do
  let path = tmp </> "locked.db"
  bracket (openDatabase path) closeDatabase $ \holder -> do
    execute_ holder "CREATE TABLE t(x INTEGER)"
    execute_ holder "BEGIN EXCLUSIVE"
    released <- newEmptyMVar
    scheduled <- newIORef False
    let release delay = do
          writeIORef scheduled True
          () <$ forkIO ((threadDelay delay >> execute_ holder "COMMIT") `finally` putMVar released ())
        settle = readIORef scheduled >>= \case
          True -> takeMVar released
          False -> execute_ holder "COMMIT"
    action path release `finally` settle

count :: Database -> IO (Maybe [SqlValue])
count database = bracket (prepareStatement database "SELECT count(*) FROM t") finalizeStatement (`queryRow` [])

spec :: Spec
spec = describe "SQLite connections (sqlite3.connect semantics)" $ do
  it "a new connection waits on a locked database, as sqlite3.connect's default timeout does" $
    withLockedDatabase $ \path release -> do
      release 300000
      bracket (openDatabase path) closeDatabase count `shouldReturn` Just [SQLInteger 0]

  it "the reference's sqlite3.connect waits on the same lock" $
    withLockedDatabase $ \path release -> do
      release 300000
      python "import sqlite3, sys\nprint(sqlite3.connect(sys.argv[1]).execute('SELECT count(*) FROM t').fetchone()[0])" [path]
        `shouldReturn` "0\n"

  it "with a zero busy timeout fails at once with OperationalError, as sqlite3.connect(timeout=0) does" $
    withLockedDatabase $ \path _ -> do
      outcome <- bracket (openDatabase path) closeDatabase $ \reader -> do
        setBusyTimeout reader 0
        try (count reader)
      case outcome of
        Left (AgenticusError cls message) -> (cls, message) `shouldBe` (OtherError "OperationalError", "database is locked")
        Right rows -> expectationFailure ("read a locked database: " <> show rows)
      python
        "import sqlite3, sys\ntry:\n    sqlite3.connect(sys.argv[1], timeout=0).execute('SELECT count(*) FROM t')\nexcept sqlite3.Error as e:\n    print(type(e).__name__, e)"
        [path]
        `shouldReturn` "OperationalError database is locked\n"
