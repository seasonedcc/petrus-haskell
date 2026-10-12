-- | Shared fixtures for the Absurd Dispatch specs: the reference's
-- @absurd_dsn@ / @observer@ / @authority@ / @listener@ / @queue@ fixtures
-- and the raw-engine helpers of @test_absurd_adapter.py@ (@claim_one@,
-- @complete@, @fail@, @task_rows@, @queue_state@, @assert_no_target_task@,
-- @publish@).
module Petrus.Motus.Dispatch.Absurd.Support
  ( -- * Fixtures
    absurdSpec
  , withConn
  , withObserver
  , withAuthority
  , freshQueue
  , freshName
  , dsnOf

    -- * Values
  , invocationFor
  , probe
  , adapterOver
  , adapterWith

    -- * Raw engine calls
  , claimOne
  , completeRaw
  , failRaw
  , spawnRaw
  , publish
  , taskRows
  , queueState
  , assertNoTargetTask
  , scalar
  , rowsOf
  , queueExists

    -- * Expectations
  , runtimeMatching
  , valueMatching
  , matchesInOrder
  , jsonOf
  , textOf
  ) where

import Control.Exception (bracket)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Json.Python (uuid4Hex)
import Petrus.Motus.Dispatch (DispatchError (..))
import Petrus.Motus.Dispatch.Absurd
import Petrus.Postgres (Connection, Param, intParam, jsonbParam, query, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), postgresSpec)
import Test.Hspec
import Petrus.TestSupport (valid)

-- | The reference's @absurd_dsn@ session fixture: one scratch database
-- with the Absurd schema ensured (the Impetus schema the reference also
-- provisions there is not used by these specs); pending without
-- @PETRUS_TEST_POSTGRES@.
absurdSpec :: SpecWith PostgresTarget -> Spec
absurdSpec = postgresSpec . beforeAllWith prepare
  where
    prepare target = do
      withConn target True ensureAbsurdSchema
      pure target

dsnOf :: PostgresTarget -> ByteString
dsnOf = targetUrl

withConn :: PostgresTarget -> Bool -> (Connection -> IO a) -> IO a
withConn target mode = bracket (Pg.connect (targetUrl target) mode) Pg.close

-- | @observer@: an autocommit connection.
withObserver :: PostgresTarget -> (Connection -> IO a) -> IO a
withObserver target = withConn target True

-- | @authority@: a join-mode connection.
withAuthority :: PostgresTarget -> (Connection -> IO a) -> IO a
withAuthority target = withConn target False

-- | @f"{prefix}{uuid4().hex[:8]}"@.
freshName :: Text -> IO Text
freshName prefix = (prefix <>) . T.take 8 <$> uuid4Hex

-- | @queue@: a fresh queue per test.
freshQueue :: IO Text
freshQueue = freshName "q_"

-- | @invocation_for(queue, attempts=..., payload=...)@.
invocationFor :: Int -> Json -> IO ActivityInvocation
invocationFor attempts payload = do
  effect <- freshName "effect-"
  let policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = toInteger attempts})
  pure . valid . activityInvocation $
    ActivityInvocationFields
      { activity = "probe_activity"
      , input = Object [("payload", payload)]
      , policy
      , correlation = Nothing
      , idempotency = Just effect
      }

-- | @ActivityInvocation("probe_activity")@.
probe :: ActivityInvocation
probe = valid (invocation "probe_activity" Null)

-- | @adapter_over(connection, default_queue=queue)@ with a fresh instance.
adapterOver :: Connection -> Text -> IO AbsurdDispatch
adapterOver connection queue = adapterWith connection defaultAbsurdDispatchOptions {defaultQueue = queue}

adapterWith :: Connection -> AbsurdDispatchOptions -> IO AbsurdDispatch
adapterWith connection options = do
  instanceId <- freshName "adapter-"
  absurdDispatch connection instanceId options

-- | @claim_one@: @(run_id, task_id, attempt)@.
claimOne :: Connection -> Text -> Text -> Int -> IO (Text, Text, Int)
claimOne connection queue worker timeout = do
  rows' <-
    query
      connection
      "SELECT run_id, task_id, attempt FROM absurd.claim_task(%s, %s, %s, 1)"
      [textParam queue, textParam worker, intParam (fromIntegral timeout)]
  case rows' of
    [Just r, Just t, Just a] : _ -> pure (decode r, decode t, read (BC.unpack a))
    _ -> expectationFailure ("nothing claimable on " <> T.unpack queue) >> error "unreachable"

-- | @complete(connection, queue, run_id, result)@.
completeRaw :: Connection -> Text -> Text -> Json -> IO ()
completeRaw connection queue run result =
  Pg.execute_ connection "SELECT absurd.complete_run(%s, %s, %s)" [textParam queue, textParam run, jsonb result]

-- | @fail(connection, queue, run_id, name, message)@: a raw SDK-shaped
-- failure.
failRaw :: Connection -> Text -> Text -> Text -> Text -> IO ()
failRaw connection queue run name message =
  Pg.execute_
    connection
    "SELECT absurd.fail_run(%s, %s, %s, NULL)"
    [textParam queue, textParam run, jsonb (Object [("name", String name), ("message", String message)])]

-- | A raw @absurd.spawn_task(queue, name, params, options)@.
spawnRaw :: Connection -> Text -> ActivityInvocation -> Json -> IO ()
spawnRaw connection queue inv options =
  Pg.execute_
    connection
    "SELECT absurd.spawn_task(%s, %s, %s, %s)"
    [textParam queue, textParam inv.activity, jsonb (encodeInvocation inv), jsonb options]

-- | @publish@: dispatch through the joined transaction, then commit.
publish :: AbsurdDispatch -> Connection -> Int -> ActivityInvocation -> IO ()
publish adapter connection occurrence inv = dispatch adapter occurrence inv >> Pg.commit connection

-- | @task_rows@: @(task_id, state, attempts)@ under the adapter's key.
taskRows :: Connection -> Text -> AbsurdDispatch -> Int -> IO [(Text, Text, Int)]
taskRows connection queue adapter occurrence = do
  rows' <-
    query
      connection
      (Pg.sql ("SELECT task_id, state, attempts FROM absurd.t_" <> queue <> " WHERE idempotency_key = %s"))
      [textParam (publicationKey adapter.instance' occurrence)]
  pure [(decode t, decode s, read (BC.unpack a)) | [Just t, Just s, Just a] <- rows']

-- | @queue_state@: @(state, first_started_at, last_attempt_run)@.
queueState :: Connection -> Text -> Text -> IO (Maybe (Text, Maybe Text, Maybe Text))
queueState connection queue key = do
  rows' <-
    query
      connection
      (Pg.sql ("SELECT state, first_started_at, last_attempt_run::text FROM absurd." <> Pg.quoteIdentifier ("t_" <> queue) <> " WHERE idempotency_key = %s"))
      [textParam key]
  pure $ case rows' of
    [Just s, started, run] : _ -> Just (decode s, decode <$> started, decode <$> run)
    _ -> Nothing

queueExists :: Connection -> Text -> IO Bool
queueExists connection queue =
  not . null <$> query connection "SELECT 1 FROM absurd.list_queues() WHERE queue_name = %s" [textParam queue]

-- | @assert_no_target_task@: no live task under the key at the target.
assertNoTargetTask :: Connection -> Text -> Text -> IO ()
assertNoTargetTask connection queue key = do
  exists <- queueExists connection queue
  when exists $ do
    n <-
      scalar
        connection
        (Pg.sql ("SELECT count(*) FROM absurd." <> Pg.quoteIdentifier ("t_" <> queue) <> " WHERE idempotency_key = %s AND state != 'cancelled'"))
        [textParam key]
    n `shouldBe` Just "0"

-- | The first column of the first row, as text.
scalar :: Connection -> Pg.Sql -> [Param] -> IO (Maybe Text)
scalar connection statement params =
  query connection statement params >>= \case
    (value : _) : _ -> pure (decode <$> value)
    _ -> pure Nothing

-- | Every row, as text.
rowsOf :: Connection -> Pg.Sql -> [Param] -> IO [[Maybe Text]]
rowsOf connection statement params = map (map (fmap decode)) <$> query connection statement params

jsonOf :: Text -> Json
jsonOf = either error id . parseJson pythonLoads . TE.encodeUtf8

textOf :: Maybe Text -> Text
textOf = maybe "" id

decode :: ByteString -> Text
decode = TE.decodeUtf8

jsonb :: Json -> Param
jsonb = either (error . show) id . jsonbParam

-- | @re.search@ of literal pieces joined by @.*@.
matchesInOrder :: [Text] -> Text -> Bool
matchesInOrder [] _ = True
matchesInOrder (piece : rest) haystack = case T.breakOn piece haystack of
  (_, found)
    | T.null found && not (T.null piece) -> False
    | otherwise -> matchesInOrder rest (T.drop (T.length piece) found)

-- | @pytest.raises(RuntimeError, match=...)@.
runtimeMatching :: [Text] -> Selector AbsurdError
runtimeMatching pieces (AbsurdError message) = matchesInOrder pieces message

-- | @pytest.raises(ValueError, match=...)@.
valueMatching :: [Text] -> Selector DispatchError
valueMatching pieces (DispatchError message) = matchesInOrder pieces message
