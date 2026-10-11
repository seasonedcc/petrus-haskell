-- | The Engine-level tests of
-- @tests/petrus/motus/dispatch/test_local_dispatch.py@: the Engine composed
-- over a JSONL History and the durable Local Dispatch, across the
-- split-store crash windows.
module Petrus.Engine.LocalDispatchSpec (spec) where

import Control.Exception (IOException)
import Data.IORef
import Data.List (isInfixOf)
import Data.Text.Encoding qualified as TE
import Data.Text qualified as T
import Petrus.Activity (ActivityFailureFields (..), ActivityInvocation (..))
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport (counting, runtimeError, symbols)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), handlerTokens)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (DeliveryScope (..), FiringOutcome (..))
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt (..), AttemptFailure (..), Dispatch (..))
import Petrus.Motus.Dispatch.Local (LocalDispatchClock (..), LocalDispatchOptions (..), defaultLocalDispatchOptions, toDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport (callWith, closingScratch, failure, fixedWorker, openScratchDispatch, parsedJson, rawExec, requireClaim, withScratch)
import System.FilePath ((</>))
import Test.Hspec

-- | @_CountingActivity(poison_prepare=...)@.
data Counting = Counting
  { prepared :: IORef Int
  , projected :: IORef Int
  , handler :: BoundHandler
  }

newCounting :: Bool -> IO Counting
newCounting poison = do
  preparedRef <- newIORef 0
  projectedRef <- newIORef 0
  let prepare' binding
        | poison = Left "AssertionError('reconciliation reran Activity prepare')"
        | first : _ <- bindingTokens binding = Right (callWith "work" 2 30 first.payload id)
        | otherwise = Left "IndexError('tuple index out of range')"
      project' (_binding, result) = Right (handlerTokens [(np "done", [tokD "Done" result])])
  pure
    Counting
      { prepared = preparedRef
      , projected = projectedRef
      , handler =
          ActivityBound
            ActivityHandler
              { prepare = counting preparedRef prepare'
              , project = \binding result -> counting projectedRef project' (binding, result)
              , projectFailure = Nothing
              }
      }

options :: Counting -> Engine.EngineOptions
options handler' = Engine.defaultEngineOptions {Engine.handlers = symbols [("activity", handler'.handler)]}

-- | @_activity_engine(tmp_path, handler, load=..., history=...)@.
activityEngine :: FilePath -> Counting -> Bool -> Maybe HistoryStore -> IO Engine.Engine
activityEngine dir handler' load history = do
  let net =
        netOf
          [place (np "ready"), place (np "done")]
          [Transition (np "activity") (Just (HandlerSymbol "activity")) [] []]
          [arc (np "ready") (np "activity"), arc (np "activity") (np "done")]
  store <- maybe (openJsonlHistoryStore (dir </> "history.jsonl")) pure history
  dispatch <- toDispatch <$> openScratchDispatch (dir </> "dispatch.db") "split-store" defaultLocalDispatchOptions
  if load
    then Engine.load net "split-store" store dispatch (options handler')
    else
      Engine.create
        net
        "split-store"
        store
        dispatch
        (options handler') {Engine.marking = markingFromList [(np "ready", [tokD "Input" (Int 7)])]}

-- | @_RefuseActivityCompleted(history)@: refuses the first batch carrying
-- an ActivityCompleted, once.
refuseActivityCompleted :: HistoryStore -> IO HistoryStore
refuseActivityCompleted inner = do
  refused <- newIORef False
  let extend' batch = do
        already <- readIORef refused
        if not already && any isActivityCompleted batch
          then do
            writeIORef refused True
            ioError (userError "injected ActivityCompleted append refusal")
          else inner.extend batch
  pure inner {extend = extend'}

isActivityCompleted :: Record -> Bool
isActivityCompleted = \case RActivityCompleted _ -> True; _ -> False

occurrenceOf :: ActivityAttempt -> Int
occurrenceOf attempt = case parsedJson (TE.encodeUtf8 attempt.attemptId) of
  Array [_, Int occurrence] -> fromInteger occurrence
  other -> error ("unexpected attempt id " <> show other)

ioErrorContaining :: String -> Selector IOException
ioErrorContaining fragment e = fragment `isInfixOf` show e

spec :: Spec
spec = do
  it "engine reconciles canonical request missing from local custody" $ withScratch $ \dir -> closingScratch dir $ do
    originalHandler <- newCounting False
    original <- activityEngine dir originalHandler False Nothing
    ((.ready) <$> Engine.advance original) `shouldReturn` True
    [request] <- (\rs -> [r | RActivityRequested r <- rs]) <$> Engine.records original
    Engine.close original

    -- Reproduce the split-store crash state: canonical outbox fact committed,
    -- while the independently durable Local custody publication is absent.
    rawExec (dir </> "dispatch.db") "DELETE FROM impetus_local_dispatch_tasks WHERE instance='split-store'"

    poison <- newCounting True
    resumed <- activityEngine dir poison True Nothing
    ((.waiting) <$> Engine.advance resumed) `shouldReturn` True
    attempt <- fixedWorker (dir </> "dispatch.db") "worker" >>= requireClaim

    attempt.invocation
      `shouldBe` ActivityInvocation
        { activity = request.activity
        , input = request.input
        , policy = request.policy
        , correlation = Just request.correlation
        , idempotency = Just request.idempotency
        }
    readIORef poison.prepared `shouldReturn` 0
    (fixedWorker (dir </> "dispatch.db") "other" >>= Local.claim) `shouldReturn` Nothing

  it "engine close fences claimed local attempt and canonically quarantines its late result" $ withScratch $ \dir -> closingScratch dir $ do
    let source = np "source"
        net =
          netOf
            [place (np "ready"), place (np "done")]
            [transition source, Transition (np "work") (Just (HandlerSymbol "activity")) [] []]
            [arc source (np "ready"), arc (np "ready") (np "work"), arc (np "work") (np "done")]
    history <- openJsonlHistoryStore (dir </> "history.jsonl")
    local <- openScratchDispatch (dir </> "dispatch.db") "scoped-local" defaultLocalDispatchOptions
    handler' <- newCounting False
    engine <- Engine.create net "scoped-local" history (toDispatch local) (options handler')
    scope <- Engine.openScope engine "draft"
    _ <- Engine.deliver engine source [tokD "Input" (Int 7)] "draft-7" (Just (ScopeGeneration scope))
    _ <- Engine.advance engine
    custody <- fixedWorker local.path "worker"
    attempt <- requireClaim custody

    _ <- Engine.closeScope engine scope
    Local.complete custody attempt (Object [("effect", String "ambiguous")])
    _ <- Engine.advance engine

    quarantined <- (\rs -> [q | RActivityTerminalQuarantined q <- rs]) <$> Engine.records engine
    map (.occurrence) quarantined `shouldBe` [occurrenceOf attempt]
    markingNull <$> Engine.marking engine `shouldReturn` True

  it "engine recollects terminal result after canonical acceptance refusal" $ withScratch $ \dir -> closingScratch dir $ do
    handler' <- newCounting False
    durable <- openJsonlHistoryStore (dir </> "history.jsonl")
    refusing <- refuseActivityCompleted durable
    original <- activityEngine dir handler' False (Just refusing)
    ((.ready) <$> Engine.advance original) `shouldReturn` True
    custody <- fixedWorker (dir </> "dispatch.db") "worker"
    attempt <- requireClaim custody
    let occurrence = occurrenceOf attempt
        terminal = Object [("status", String "durably-complete")]
    Local.complete custody attempt terminal

    Engine.advance original `shouldThrow` ioErrorContaining "injected ActivityCompleted append refusal"
    Engine.advance original `shouldThrow` runtimeError "Engine is poisoned"
    readIORef handler'.prepared `shouldReturn` 1

    recoveredHandler <- newCounting True
    recovered <- activityEngine dir recoveredHandler True Nothing
    outcome <- Engine.advance recovered
    stored <- openJsonlHistoryStore (dir </> "history.jsonl") >>= Store.records

    map (.occurrence) outcome.firings `shouldBe` [occurrence]
    readIORef recoveredHandler.prepared `shouldReturn` 0
    readIORef recoveredHandler.projected `shouldReturn` 1
    [c.result | RActivityCompleted c <- stored] `shouldBe` [terminal]
    length [() | RFiringCompleted _ <- stored] `shouldBe` 1
    Engine.inFlight recovered `shouldReturn` []

  -- The DST worlds (tests/dst/retry_world.py, generated_runtime_world.py)
  -- consume Local Dispatch through exactly this shape: a world provider
  -- clock (logical seconds to milliseconds), the public dispatch door
  -- wrapped (RefusingLocalDispatch), a fresh labelled worker per claim, a
  -- retryable failure with retry_after=0, and a close after each report.
  it "the DST worlds' consumer shape: world clock, wrapped dispatch door, a worker per claim" $ withScratch $ \dir -> closingScratch dir $ do
    seconds <- newIORef (5 :: Integer)
    local <-
      openScratchDispatch
        (dir </> "dispatch.db")
        "split-store"
        defaultLocalDispatchOptions {clock = Just (LocalDispatchClock ((* 1000) <$> readIORef seconds))}
    accepted <- newIORef []
    refuseNext <- newIORef (Just "injected pre-custody refusal")
    let door = toDispatch local
        wrapped =
          door
            { dispatch = \occurrence inv ->
                readIORef refuseNext >>= \case
                  Just message -> writeIORef refuseNext Nothing >> modifyIORef accepted ((occurrence, False) :) >> ioError (userError message)
                  Nothing -> door.dispatch occurrence inv >> modifyIORef accepted ((occurrence, True) :)
            }
    handler' <- newCounting False
    let net =
          netOf
            [place (np "ready"), place (np "done")]
            [Transition (np "activity") (Just (HandlerSymbol "activity")) [] []]
            [arc (np "ready") (np "activity"), arc (np "activity") (np "done")]
    history <- openJsonlHistoryStore (dir </> "history.jsonl")
    refused <-
      Engine.create net "split-store" history wrapped (options handler') {Engine.marking = markingFromList [(np "ready", [tokD "Input" (Int 7)])]}
    Engine.advance refused `shouldThrow` ioErrorContaining "injected pre-custody refusal"
    Engine.close refused

    -- The next generation reconciles the committed outbox fact through the
    -- same wrapped door; prepare never re-runs.
    reloaded <- openJsonlHistoryStore (dir </> "history.jsonl")
    engine <- Engine.load net "split-store" reloaded wrapped (options handler')
    ((.waiting) <$> Engine.advance engine) `shouldReturn` True
    [(occurrence, True), (refusedOccurrence, False)] <- readIORef accepted
    refusedOccurrence `shouldBe` occurrence
    readIORef handler'.prepared `shouldReturn` 1

    first <- Local.worker local ["default"] (Just "dst-worker-1")
    a1 <- requireClaim first
    (a1.epoch, T.takeWhile (/= ':') a1.claimant, a1.instance', a1.queue) `shouldBe` ("1", "dst-worker-1", Just "split-store", "default")
    Local.fail first a1 (FailureClassified (failure (ActivityFailureFields "transient" "Unavailable" Null True (Just (IntNumber 0)))))
    Local.close first

    second <- Local.worker local ["default"] (Just "dst-worker-2")
    a2 <- requireClaim second
    (a2.epoch, occurrenceOf a2) `shouldBe` ("2", occurrence)
    Local.complete second a2 (Object [("total", Int 7)])
    Local.close second

    writeIORef seconds 6
    outcome <- Engine.advance engine
    map (.occurrence) outcome.firings `shouldBe` [occurrence]
    readIORef handler'.projected `shouldReturn` 1
    Engine.close engine
