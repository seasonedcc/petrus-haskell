-- | Shared History fixtures for the History specs: the reference's
-- @every_record_category@ and its @reopen@ backend fixture.
module Petrus.Impetus.HistorySupport
  ( everyRecordCategory
  , newReopen
  , jsonLine
  ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Foldable (toList)
import Data.IORef
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ExecutionPolicyFields (..), executionPolicy)
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Scope (lifecycleScope)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json

-- | @every_record_category()@ (test_persistence.py): one constructed
-- instance of every category in the kernel's Record union, in the
-- reference's order.
everyRecordCategory :: [Record]
everyRecordCategory =
  [ RInstanceCreated (InstanceCreated "instance-7f" (Just "order-fulfillment") 0)
  , RTokensInitialized (TokensInitialized p [token', black] 0 [] Nothing)
  , RScopeOpened (ScopeOpened firstScope 0)
  , RScopeClosed (ScopeClosed firstScope [] [] 1)
  , RScopeReset (ScopeReset firstScope secondScope [] [] 1)
  , RDeliveryRegistrationOpened (DeliveryRegistrationOpened t "default" Nothing 0)
  , RExternalEventDelivered (ExternalEventDelivered t [token'] "occurrence-1" 1 Nothing 1)
  , RScopedDeliveryDropped (ScopedDeliveryDropped t [token'] "closed-1" firstScope 1)
  , RScopedDeliveryQuarantined (ScopedDeliveryQuarantined t [token'] "uncertain-1" (QuarantineName "draft") 1)
  , RCandidateSelected (CandidateSelected t 2 2)
  , RFiringBegun (FiringBegun t 2 Nothing 2)
  , RTokensConsumed (TokensConsumed p [token'] 2 [] Nothing 2)
  , RTokensRead (TokensRead p [black] 2 [] Nothing 2)
  , RTimerMatured (TimerMatured 2 3)
  , RActivityRequested
      (ActivityRequested t "charge_card" (Object [("amount", Int 100)]) policy "order-77" "occurrence-2" 2 Nothing 3)
  , RActivityCompleted (ActivityCompleted t (Object [("status", String "captured")]) 2 4)
  , RActivityTerminalQuarantined
      ( ActivityTerminalQuarantined
          t
          (Object [("kind", String "completed"), ("value", Object [("status", String "late")])])
          firstScope
          3
          4
      )
  , RTokensProduced (TokensProduced p [token'] 2 [] Nothing 4)
  , RDeliveryRegistrationClosed (DeliveryRegistrationClosed t "default" (Just 2) 4)
  , RFiringCompleted (FiringCompleted t 2 4)
  , RActivityFailed (ActivityFailed t "TimeoutError('gone')" "ActivityError" Null False Nothing 1 5)
  , RFiringFailed (FiringFailed t "boom" 1 5)
  ]
  where
    p = np "p"
    t = np "t"
    token' = tokD "issue" (Object [("id", String "goose"), ("passed", Bool True)])
    firstScope = either (error . show) id (lifecycleScope "draft" 1)
    secondScope = either (error . show) id (lifecycleScope "draft" 2)
    -- ExecutionPolicy(attempts=2, heartbeat_timeout=45), every other field
    -- at its default.
    policy = either (error . show) id (executionPolicy (ExecutionPolicyFields 2 45 0 2 60 0 Nothing Nothing))

-- | @json.dumps(encode_record(record))@ with @allow_nan=False@: one durable
-- line of the schema-5 spelling.
jsonLine :: Record -> Either EncodeError Text
jsonLine = dumpsText defaultDumps {allowNan = False} . encodeRecord

-- | The reference's @reopen@ fixture (test_history_backends.py) over the
-- kernel's own seam: a storage of schema-5 JSON lines, and a zero-argument
-- factory whose each call loads a FRESH 'Store.mirroredHistoryStore' over
-- that storage — the kill-and-reload move. A batch encodes whole before
-- anything reaches the storage; a refused write throws, so nothing enters
-- the mirror either. The durable JSONL, SQLite, and Postgres backends this
-- stands in for live in other packages.
newReopen :: IO (IO HistoryStore)
newReopen = do
  storage <- newIORef (Seq.empty :: Seq Text)
  pure $ do
    stored <- readIORef storage
    loaded <- either (throwIO . ErrorCall . T.unpack) pure (mapM decodeLine (toList stored))
    Store.mirroredHistoryStore Store.BackendOwned (Seq.fromList loaded) $ \_ batch -> do
      encoded <- either throwIO pure (mapM encodeLine batch)
      modifyIORef' storage (<> Seq.fromList encoded)
      pure (map (const Store.Entered) batch)
  where
    encodeLine record = case jsonLine record of
      Left err -> Left (ErrorCall ("cannot encode " <> T.unpack (recordName record) <> ": " <> show err))
      Right line -> Right line
    decodeLine line = case parseJson pythonLoads (TE.encodeUtf8 line) of
      Left err -> Left (T.pack err)
      Right payload -> decodeRecord payload
