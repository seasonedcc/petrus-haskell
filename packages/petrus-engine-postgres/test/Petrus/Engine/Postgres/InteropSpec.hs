-- | PostgreSQL Engine interop with the pinned reference: Haskell Engines
-- and the reference's @petrus.engine.postgres@ Engines take turns on one
-- Instance in one scratch database — each loads what the other wrote and
-- extends it; the authority fence excludes the other language's writer
-- (and a dead holder's session releases it); a failure or a refused commit
-- in one language is decided by a fresh load in the other; and a doorbell
-- Dispatch built on the joined seam ("Petrus.Engine.Postgres.Joined", the
-- shape the Absurd provider takes) rings @impetus_dispatch@ for a
-- reference listener only when the Engine commits, while the reference's
-- @impetus_results@ NOTIFY wakes 'Engine.wait'.
--
-- Runs @test/interop/postgres_engine_interop.py@ (and the History suite's
-- listener) under the pinned @upstream/petrus/.venv@; pending without
-- @PETRUS_TEST_POSTGRES@.
module Petrus.Engine.Postgres.InteropSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO, try)
import Control.Monad (void, when)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Engine (DeliveryAnswer (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres
import Petrus.Engine.Postgres.Joined (JoinedProvider, closeBoth, joinedProvider, openJoinedEngine)
import Petrus.Engine.Postgres.Joined qualified as J
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Engine.TestSupport (Bridge (..), inlineOf, newBridge, symbols)
import Petrus.HistoryStore.Postgres.Support
import Petrus.Impetus.Binding (BoundHandler (..), handlerTokens)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records
import Petrus.Impetus.Instance (AcceptedDelivery (..), PriorAcknowledgement (..), firingOccurrenceIdInt)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (netOf, np, tokD)
import Petrus.Json (Json (..), lookupMember, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch (ActivityOutcome (..), Dispatch (..))
import Petrus.Postgres
  ( Connection
  , FenceError (..)
  , autocommit
  , dispatchChannel
  , execute_
  , fenceErrorMessage
  , fenceKey
  , isClosed
  , listen
  , notify
  , pollWithDoorbell
  , query
  , resultsChannel
  , textParam
  )
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget, postgresSpec)
import Test.Hspec

script, listener :: FilePath
script = "test/interop/postgres_engine_interop.py"
listener = "../petrus-history-postgres/test/interop/postgres_history_interop.py"

py :: PostgresTarget -> [String] -> IO BC.ByteString
py target arguments = runScript script (dsnArgument target : arguments)

pyJson :: PostgresTarget -> [String] -> IO Json
pyJson target arguments = runScriptJson script (dsnArgument target : arguments)

source', output, queue, work, done :: NetPath
source' = np "source"
output = np "output"
queue = np "queue"
work = np "work"
done = np "done"

providerNet :: Net
providerNet = netOf [place output] [transition source'] [arc source' output]

projectNet :: Net
projectNet = netOf [place output] [Transition source' (Just (HandlerSymbol "project")) [] []] [arc source' output]

eventToken :: Token
eventToken = tokD "Event" (Int 7)

forward :: BoundHandler
forward = PureHandler (\binding _ -> Right (handlerTokens [(output, bindingTokens binding)]))

joinedOn :: PostgresTarget -> IO Connection
joinedOn target = connectTo target False

openOn :: OpenMode -> PostgresTarget -> Net -> Text -> Engine.EngineOptions -> IO Engine
openOn mode target net instanceId options = do
  connection <- joinedOn target
  port <- inlineOf []
  openPostgresEngine (postgresSession connection) mode net instanceId port options

-- | The reference script's state shape for a Haskell Engine.
stateOf :: Engine -> IO Json
stateOf engine = do
  n <- length . placeTokens output <$> Engine.marking engine
  recs <- Engine.records engine
  pure (Object [("output", Int (toInteger n)), ("records", Array (map encodeRecord recs))])

member :: Text -> Json -> Json
member key value = maybe Null id (lookupMember key value)

spec :: Spec
spec = postgresSpec $ describe "PostgreSQL Engine interop with the reference" $ do
  aroundWith (\action target -> withPgConnection target (\_ -> action target)) $ do
    describe "taking turns on one Instance" turnsSpec
    describe "the authority fence across languages" fenceSpec
    describe "failure fates decided across languages" fateSpec
    describe "the joined seam's doorbells across languages" doorbellSpec

turnsSpec :: SpecWith PostgresTarget
turnsSpec = do
  it "an Instance the reference created loads in Haskell, which extends it; the reference loads the result" $ \target -> do
    instanceId <- freshInstance "interop-engine-py"
    created <- pyJson target ["create", T.unpack instanceId, "py-first"]
    member "output" created `shouldBe` Int 1
    engine <- openOn LoadInstance target providerNet instanceId Engine.defaultEngineOptions
    (Array . map encodeRecord <$> Engine.records engine) `shouldReturn` member "records" created
    _ <- Engine.deliver engine source' [black] "hs-second" Nothing
    ours <- stateOf engine
    Engine.close engine
    member "output" ours `shouldBe` Int 2
    pyJson target ["inspect", T.unpack instanceId] `shouldReturn` ours

  it "an Instance Haskell created loads in the reference, which extends it; Haskell loads the result" $ \target -> do
    instanceId <- freshInstance "interop-engine-hs"
    engine <- openOn CreateInstance target providerNet instanceId Engine.defaultEngineOptions
    _ <- Engine.deliver engine source' [black] "hs-first" Nothing
    Engine.close engine
    theirs <- pyJson target ["load-deliver", T.unpack instanceId, "py-second"]
    member "output" theirs `shouldBe` Int 2
    resumed <- openOn LoadInstance target providerNet instanceId Engine.defaultEngineOptions
    stateOf resumed `shouldReturn` theirs
    -- the reference's identity is remembered across the language boundary
    Engine.deliver resumed source' [black] "py-second" Nothing >>= \case
      Engine.DeliveryPrior prior -> prior.identity `shouldBe` "py-second"
      other -> expectationFailure ("expected a prior acknowledgement, got " <> show other)
    Engine.close resumed

fenceSpec :: SpecWith PostgresTarget
fenceSpec = do
  it "both languages derive the same fence key" $ \target -> do
    let instances = ["order-1", "pedido-ção", "x"]
    keys <- mapM (\i -> pyJson target ["fence-key", T.unpack i]) instances
    keys `shouldBe` [either (error . show) (Int . toInteger) (fenceKey i) | i <- instances]

  it "a reference Engine's fence refuses a Haskell writer before History loads, closing its connection, until the reference closes" $ \target -> do
    instanceId <- freshInstance "interop-fence-py"
    void (py target ["create", T.unpack instanceId, "first"])
    withScript script [dsnArgument target, "hold", T.unpack instanceId] $ \running -> do
      receiveJson running `shouldReturn` String "held"
      connection <- joinedOn target
      port <- inlineOf []
      openPostgresEngine (postgresSession connection) LoadInstance providerNet instanceId port Engine.defaultEngineOptions
        `shouldThrow` (== FenceHeld instanceId)
      isClosed connection `shouldReturn` True
      send running "close"
      receiveJson running `shouldReturn` String "closed"
    engine <- openOn LoadInstance target providerNet instanceId Engine.defaultEngineOptions
    Engine.close engine

  it "a Haskell Engine's fence refuses a reference writer with the reference's own message, until Haskell closes" $ \target -> do
    instanceId <- freshInstance "interop-fence-hs"
    engine <- openOn CreateInstance target providerNet instanceId Engine.defaultEngineOptions
    refused <- pyJson target ["try-load", T.unpack instanceId]
    refused
      `shouldBe` Object
        [ ("error", String ("RuntimeError: " <> fenceErrorMessage (FenceHeld instanceId)))
        , ("closed", Bool True)
        ]
    Engine.close engine
    pyJson target ["try-load", T.unpack instanceId] `shouldReturn` Object [("loaded", Bool True), ("closed", Bool True)]

  it "a reference holder killed outright releases the fence with its session" $ \target -> do
    instanceId <- freshInstance "interop-fence-killed"
    void (py target ["create", T.unpack instanceId, "first"])
    withScript script [dsnArgument target, "hold", T.unpack instanceId] $ \running -> do
      receiveJson running `shouldReturn` String "held"
      killHard running
    engine <- retrying 10 (openOn LoadInstance target providerNet instanceId Engine.defaultEngineOptions)
    Engine.close engine

  it "a Haskell holder whose connection drops releases the fence for the reference" $ \target -> do
    instanceId <- freshInstance "interop-fence-dropped"
    connection <- joinedOn target
    port <- inlineOf []
    engine <- openPostgresEngine (postgresSession connection) CreateInstance providerNet instanceId port Engine.defaultEngineOptions
    member "error" <$> pyJson target ["try-load", T.unpack instanceId] `shouldNotReturn` Null
    Pg.close connection -- the session ends without the Engine's release
    pyJson target ["try-load", T.unpack instanceId] `shouldReturn` Object [("loaded", Bool True), ("closed", Bool True)]
    Engine.close engine

-- | Retry while the fence is still held (a killed session's backend may
-- take a moment to notice), up to the given number of seconds.
retrying :: Double -> IO a -> IO a
retrying seconds action = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop =
        try action >>= \case
          Right value -> pure value
          Left (failure :: FenceError) -> do
            now <- getMonotonicTime
            when (now > deadline) (throwIO failure)
            threadDelay 50000
            loop
  loop

fateSpec :: SpecWith PostgresTarget
fateSpec = do
  it "a projection failure the reference committed is acknowledged exactly by a Haskell load" $ \target -> do
    instanceId <- freshInstance "interop-fate-py"
    void (py target ["fail-projection", T.unpack instanceId])
    engine <- openOn LoadInstance target projectNet instanceId Engine.defaultEngineOptions {Engine.handlers = symbols [("project", forward)]}
    recs <- Engine.records engine
    case reverse recs of
      RFiringFailed f : _ -> f.error `shouldBe` "RuntimeError('projection failed')"
      _ -> expectationFailure "expected a trailing FiringFailed"
    Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing
      `shouldReturn` DeliveryPrior (PriorAcknowledgement "event-7" 1)
    Engine.close engine

  it "a projection failure Haskell committed is acknowledged exactly by a reference load" $ \target -> do
    instanceId <- freshInstance "interop-fate-hs"
    engine <-
      openOn CreateInstance target projectNet instanceId Engine.defaultEngineOptions
        { Engine.handlers = symbols [("project", PureHandler (\_ _ -> Left "RuntimeError('projection failed')"))]
        }
    DeliveryAccepted accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing
    void (try @Engine.EngineError (Engine.completeDelivery engine accepted))
    pyJson target ["prior", T.unpack instanceId]
      `shouldReturn` Object [("identity", String "event-7"), ("occurrence", Int 1), ("output", Int 0)]

  it "an acceptance whose Haskell completion commit was refused is completed exactly by the reference" $ \target -> do
    instanceId <- freshInstance "interop-retry"
    connection <- joinedOn target
    refuse <- newIORef False
    let session = postgresSession connection
        refusing =
          session
            { commit = do
                r <- readIORef refuse
                if r then writeIORef refuse False >> ioError (userError "completion commit refused") else session.commit
            }
    port <- inlineOf []
    engine <- openPostgresEngine refusing CreateInstance providerNet instanceId port Engine.defaultEngineOptions
    DeliveryAccepted accepted <- Engine.acceptDelivery engine source' [eventToken] "event-7" Nothing
    writeIORef refuse True
    void (try @IOError (Engine.completeDelivery engine accepted))
    isClosed connection `shouldReturn` True
    retried <- pyJson target ["retry-acceptance", T.unpack instanceId]
    member "accepted" retried `shouldBe` Int (toInteger (firingOccurrenceIdInt accepted.occurrence))
    member "completed" retried `shouldBe` Int (toInteger (firingOccurrenceIdInt accepted.occurrence))
    member "output" retried `shouldBe` Int 1
    resumed <- openOn LoadInstance target providerNet instanceId Engine.defaultEngineOptions
    stateOf resumed `shouldReturn` Object [("output", Int 1), ("records", member "records" retried)]
    Engine.close resumed

-- ---------------------------------------------------------------------------
-- The joined seam's doorbells

-- | A Dispatch on the joined seam shaped like Absurd's: 'dispatch' rings
-- @impetus_dispatch@ on the joined connection (so the doorbell commits or
-- vanishes with the Engine's batch); results are rows in
-- @public.interop_results@ probed and collected on the dedicated autocommit
-- listen connection; the wake hint is 'pollWithDoorbell' on
-- @impetus_results@.
doorbellProvider :: Connection -> Connection -> Text -> Double -> IO JoinedProvider
doorbellProvider joinedConnection listening instanceId pollInterval = do
  collected <- newIORef Set.empty
  listeningYet <- newIORef False
  let pendingResults = do
        raw <- query listening "SELECT occurrence, result::text FROM public.interop_results WHERE instance_id = %s ORDER BY occurrence" [textParam instanceId]
        seen <- readIORef collected
        pure
          [ (occurrence, either error id (parseJson surrogateRefusingLoads result))
          | [Just o, Just result] <- raw
          , let occurrence = read (BC.unpack o) :: Int
          , not (Set.member occurrence seen)
          ]
      port =
        Dispatch
          { dispatch = \_ _ -> notify joinedConnection dispatchChannel "default"
          , collect = do
              ready <- pendingResults
              modifyIORef' collected (Set.union (Set.fromList (map fst ready)))
              pure [(occurrence, Succeeded value) | (occurrence, value) <- ready]
          , cancel = Nothing
          }
      hint seconds = do
        started <- readIORef listeningYet
        when (not started) (listen listening resultsChannel >> writeIORef listeningYet True)
        pollWithDoorbell pollInterval (Just listening) seconds (not . null <$> pendingResults)
  pure
    (joinedProvider joinedConnection port)
      { J.validate = do
          joinedAuto <- autocommit joinedConnection
          listenAuto <- autocommit listening
          when (joinedAuto || not listenAuto) (throwIO (Engine.EngineValueError "the doorbell provider needs a joined and an autocommit listen connection"))
      , J.closeConnections = closeBoth listening joinedConnection
      , J.compose = \_ -> pure (port, Just hint)
      }

activityNet :: Net
activityNet =
  netOf
    [place queue, place done]
    [transition source', Transition work (Just (HandlerSymbol "bridge")) [] []]
    [arc source' queue, arc queue work, arc work done]

doorbellSpec :: SpecWith PostgresTarget
doorbellSpec = do
  it "the Engine's dispatch doorbell reaches a reference listener only when the Engine commits, and the reference's results doorbell wakes Engine.wait" $ \target ->
    withPg target True $ \setup -> do
      execute_ setup "CREATE TABLE IF NOT EXISTS public.interop_results (instance_id text NOT NULL, occurrence int NOT NULL, result jsonb NOT NULL)" []
      instanceId <- freshInstance "interop-doorbell"
      withScript listener [dsnArgument target, "listen", T.unpack dispatchChannel] $ \running -> do
        receiveJson running `shouldReturn` String "ready"
        let drain seconds = send running ("drain " <> BC.pack (show (seconds :: Double))) >> receiveJson running
            options bridge = Engine.defaultEngineOptions {Engine.handlers = symbols [("bridge", bridge.handler)]}

        -- 1. The begin + dispatch batch's commit is refused: no doorbell.
        refused <- newIORef False
        firstJoined <- connectTo target False
        firstListen <- connectTo target True
        provider <- doorbellProvider firstJoined firstListen instanceId 5
        bridge <- newBridge "charge" done
        let refusing =
              provider
                { J.commit = do
                    r <- readIORef refused
                    if r then ioError (userError "dispatch commit refused") else provider.commit
                }
        engine <- openJoinedEngine refusing CreateInstance activityNet instanceId (options bridge)
        _ <- Engine.deliver engine source' [tokD "Order" (Int 3)] "order-3" Nothing
        writeIORef refused True
        -- conservative driving: the first turn selects, the next begins
        -- and dispatches (its commit is the refused one)
        firstTurn <- try @IOError (Engine.advance engine)
        secondTurn <- either (pure . Left) (const (try @IOError (Engine.advance engine))) firstTurn
        either (\e -> show e `shouldContain` "dispatch commit refused") (const (expectationFailure "no commit was refused")) secondTurn
        drain 0.5 `shouldReturn` Array []
        isClosed firstJoined `shouldReturn` True
        isClosed firstListen `shouldReturn` True

        -- 2. A fresh load dispatches again; the doorbell rings once, on commit.
        secondJoined <- connectTo target False
        secondListen <- connectTo target True
        provider' <- doorbellProvider secondJoined secondListen instanceId 5
        bridge' <- newBridge "charge" done
        resumed <- openJoinedEngine provider' LoadInstance activityNet instanceId (options bridge')
        let pumpUntilWaiting n = do
              outcome <- Engine.advance resumed
              if outcome.waiting || n <= (0 :: Int) then pure outcome else pumpUntilWaiting (n - 1)
        outcome <- pumpUntilWaiting 10
        outcome.waiting `shouldBe` True
        drain 2 `shouldReturn` Array [Array [String dispatchChannel, String "default"]]
        recs <- Engine.records resumed
        let requested = [r.occurrence | RActivityRequested r <- recs]
        length requested `shouldBe` 1

        -- 3. The reference's results doorbell wakes Engine.wait well before
        -- the 5 s poll tick.
        Engine.wait resumed 0.2 `shouldReturn` False
        occurrence <- case requested of
          [o] -> pure o
          _ -> expectationFailure "expected one requested activity" >> pure 0
        started <- getMonotonicTime
        void (py target ["ring-results", T.unpack instanceId, show occurrence, "{\"status\": \"captured\"}"])
        Engine.wait resumed 10 `shouldReturn` True
        elapsed <- subtract started <$> getMonotonicTime
        elapsed `shouldSatisfy` (< 3)
        _ <- Engine.advance resumed
        toList . placeTokens done <$> Engine.marking resumed
          `shouldReturn` [tokD "Done" (Object [("status", String "captured")])]
        Engine.close resumed
        isClosed secondJoined `shouldReturn` True
        isClosed secondListen `shouldReturn` True

  it "the joined seam closes both connections and frees the fence when a provider precondition refuses" $ \target -> do
    instanceId <- freshInstance "interop-doorbell-refused"
    joinedConnection <- connectTo target False
    notAutocommit <- connectTo target False
    provider <- doorbellProvider joinedConnection notAutocommit instanceId 0.25
    openJoinedEngine provider CreateInstance activityNet instanceId Engine.defaultEngineOptions
      `shouldThrow` (\case Engine.EngineValueError _ -> True; _ -> False)
    isClosed joinedConnection `shouldReturn` True
    isClosed notAutocommit `shouldReturn` True
    pyJson target ["try-load", T.unpack instanceId] >>= \answer ->
      member "error" answer `shouldSatisfy` \case
        String m -> "does not exist" `T.isInfixOf` m
        _ -> False
