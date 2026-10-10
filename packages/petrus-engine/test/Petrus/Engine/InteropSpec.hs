-- | Engine interop with the pinned reference: the same Engine scenario over
-- JSONL writes byte-identical History in both implementations, and an
-- Instance one implementation left mid-flight (a crash with a dispatched
-- Activity outstanding) resumes in the other — reconcile redispatches the
-- recorded outbox, prepare never re-runs — to the same bytes.
--
-- Runs @test/interop/engine_interop.py@ under @upstream/petrus/.venv@, provisioned
-- by @scripts/upstream-python@ on first use; the examples fail, never skip,
-- when that environment cannot be provisioned.
module Petrus.Engine.InteropSpec (spec) where

import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.IORef
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.Engine.TestSupport (advanceUntilRest)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (withReference, runPython, withScratch)
import Petrus.Impetus.Petrinet (Marking)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import System.Directory (copyFile)
import System.FilePath ((</>))
import Test.Hspec

script :: FilePath
script = "test/interop/engine_interop.py"

created :: FilePath -> Dispatch -> IO (Engine.Engine, IORef Int)
created path port = do
  prepared <- newIORef 0
  store <- openJsonlHistoryStore path
  engine <- Engine.create orderNet orderIdentity store port (orderOptions prepared)
  deliverOrders engine 3
  pure (engine, prepared)

-- | @run PATH@.
runScenario :: FilePath -> IO ()
runScenario path = do
  (engine, _) <- orderActivities >>= created path
  void (advanceUntilRest engine)
  Engine.close engine

-- | @crash PATH@: the process "dies" with the first charge in flight.
crashScenario :: FilePath -> IO ()
crashScenario path = do
  pool <- newInMemoryDispatch
  (engine, _) <- created path (inMemoryDispatch pool)
  void (advanceUntilRest engine)
  length <$> Engine.inFlight engine `shouldReturn` 1

-- | @resume PATH@; answers how many times prepare ran.
resumeScenario :: FilePath -> IO Int
resumeScenario path = do
  prepared <- newIORef 0
  store <- openJsonlHistoryStore path
  port <- orderActivities
  engine <- Engine.load orderNet orderIdentity store port (orderOptions prepared)
  void (advanceUntilRest engine)
  Engine.close engine
  readIORef prepared

inspected :: String
inspected =
  "{\"done\": [[\"Settled\", {\"id\": \"o-1\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-2\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-3\", \"status\": \"captured\"}]]}\n66\n"

loadedMarking :: FilePath -> IO Marking
loadedMarking path = do
  store <- openJsonlHistoryStore path
  port <- inMemoryDispatch <$> newInMemoryDispatch
  prepared <- newIORef 0
  engine <- Engine.load orderNet orderIdentity store port (orderOptions prepared)
  m <- Engine.marking engine
  Engine.close engine
  pure m

spec :: Spec
spec = describe "Engine interop with the reference" $ do
  it "the same scenario writes byte-identical JSONL History in both implementations" $ withReference $ \python -> withScratch $ \dir -> do
    let reference = dir </> "reference.jsonl"
        ours = dir </> "haskell.jsonl"
    _ <- runPython python script ["run", reference]
    runScenario ours
    expected <- BS.readFile reference
    BS.readFile ours `shouldReturn` expected
    loadedMarking ours `shouldReturn` settledMarking 3
    runPython python script ["inspect", ours] `shouldReturn` inspected

  it "an Instance the reference left mid-flight resumes in Haskell to the reference's own resumed bytes" $ withReference $ \python -> withScratch $ \dir -> do
    let ours = dir </> "haskell-resumed.jsonl"
        reference = dir </> "reference-resumed.jsonl"
    _ <- runPython python script ["crash", ours]
    copyFile ours reference
    prepares <- resumeScenario ours
    prepares `shouldBe` 2 -- the in-flight charge's prepare never re-runs
    _ <- runPython python script ["resume", reference]
    expected <- BS.readFile reference
    BS.readFile ours `shouldReturn` expected
    runPython python script ["inspect", ours] `shouldReturn` inspected

  it "an Instance Haskell left mid-flight resumes in the reference to Haskell's own resumed bytes" $ withReference $ \python -> withScratch $ \dir -> do
    let theirs = dir </> "reference-resumed.jsonl"
        ours = dir </> "haskell-resumed.jsonl"
        referenceCrash = dir </> "reference-crash.jsonl"
    crashScenario theirs
    _ <- runPython python script ["crash", referenceCrash]
    crashed <- BS.readFile referenceCrash
    BS.readFile theirs `shouldReturn` crashed
    copyFile theirs ours
    _ <- runPython python script ["resume", theirs]
    _ <- resumeScenario ours
    expected <- BS.readFile ours
    BS.readFile theirs `shouldReturn` expected
    loadedMarking theirs `shouldReturn` settledMarking 3
