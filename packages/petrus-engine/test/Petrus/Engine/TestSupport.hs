{-# OPTIONS_GHC -fno-full-laziness -fno-cse #-}

-- | Shared helpers for the Engine specs: the reference tests' fixtures
-- (@Bridge@, @_TransactionalHistory@, @_scripted@, @advance_until_rest@)
-- spelled for Haskell, and selectors for the reference's exception types.
module Petrus.Engine.TestSupport
  ( -- * Driving
    advanceUntilRest
    -- * Counting pure callbacks
  , counting
  , Bridge (..)
  , newBridge
  , newBridgeWith
    -- * Dispatch
  , inlineOf
    -- * Sensors and deliveries
  , scripted
  , mkDelivery
  , mkScopedDelivery
    -- * Joined-transaction History
  , TransactionalHistory (..)
  , newTransactionalHistory
  , txCommit
  , txRollback
  , txCommitted
  , txPending
  , txResources
    -- * Implementations
  , symbols
    -- * Exception selectors
  , valueError
  , typeError
  , runtimeError
  , handlerFailed
  , anyEngineError
  , messageOf
  ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailure, invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Provider (EngineResources (..), defaultResources)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records (Record)
import Petrus.Impetus.HistoryStore (CommitMode (..), HistoryStore (..))
import Petrus.Impetus.Instance (DeliveryScope, FiringOutcome, ImplementationRef (..))
import Petrus.Impetus.Petrinet (Binding, NetPath, Token (..), bindingTokens)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.Inline (Activity, inlineDispatch, newInlineDispatch)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (Selector)

-- ---------------------------------------------------------------------------
-- Driving

-- | @advance_until_rest@: pump one-action turns until the Engine reports
-- wait, sleep, or stop; the firings accumulate, the posture is the last
-- turn's ('ready' is then 'False').
advanceUntilRest :: Engine.Engine -> IO Engine.DriveOutcome
advanceUntilRest engine = go []
  where
    go :: [[FiringOutcome]] -> IO Engine.DriveOutcome
    go acc = do
      outcome <- Engine.advance engine
      let acc' = outcome.firings : acc
      if outcome.ready
        then go acc'
        else pure (Engine.DriveOutcome (concat (reverse acc')) outcome.waiting False outcome.nextMaturation)

-- ---------------------------------------------------------------------------
-- Counting

-- | Count each application of a pure callback (the reference handlers'
-- @self.prepared += 1@). The bump happens when the kernel evaluates the
-- application, which it does exactly once per call. unsafePerformIO
-- (NOINLINE) is the point: it observes a pure callback being evaluated,
-- including the ones 'EngineOptions.handlerObserver' does not see (pure
-- handlers, selection proposals).
counting :: IORef Int -> (x -> y) -> x -> y
counting ref f x = unsafePerformIO $ do
  atomicModifyIORef' ref (\n -> (n + 1, ()))
  pure (f x)
{-# NOINLINE counting #-}

-- | The reference tests' counting @Bridge@ ActivityHandler: prepare names
-- its activity with the binding's first token's data as input; project
-- deposits @Token("Done", result)@ to the output place.
data Bridge = Bridge
  { prepared :: IORef Int
  , projected :: IORef Int
  , handler :: BoundHandler
  }

-- | @Bridge(activity, out)@.
newBridge :: Text -> NetPath -> IO Bridge
newBridge activity out = newBridgeWith activity out Nothing

-- | @Bridge@ with an optional failure projector.
newBridgeWith :: Text -> NetPath -> Maybe (Binding -> ActivityFailureValue -> Either Text HandlerResult) -> IO Bridge
newBridgeWith activity out failureProjector = do
  preparedRef <- newIORef 0
  projectedRef <- newIORef 0
  let prepare' b = case bindingTokens b of
        first : _ -> invocation activity first.payload
        [] -> Left "IndexError('tuple index out of range')"
      project' (_b, result) = Right (handlerTokens [(out, [Token (Just "Done") result])])
  pure
    Bridge
      { prepared = preparedRef
      , projected = projectedRef
      , handler =
          ActivityBound
            ActivityHandler
              { prepare = counting preparedRef prepare'
              , project = \b result -> counting projectedRef project' (b, result)
              , projectFailure = failureProjector
              }
      }

type ActivityFailureValue = ActivityFailure

-- ---------------------------------------------------------------------------
-- Dispatch

-- | @InlineDispatch({name: activity, ...})@ as a 'Dispatch'.
inlineOf :: [(Text, Activity)] -> IO Dispatch
inlineOf activities = inlineDispatch <$> newInlineDispatch (Map.fromList activities)

-- ---------------------------------------------------------------------------
-- Sensors

-- | @_scripted(*rounds)@: each observation returns the next round; consulting
-- it past its script fails the test.
scripted :: [[Engine.Delivery]] -> IO Engine.Sensor
scripted rounds = do
  remaining <- newIORef rounds
  pure $
    atomicModifyIORef' remaining (\case [] -> ([], Nothing); r : rs -> (rs, Just r)) >>= \case
      Just r -> pure r
      Nothing -> throwIO (ErrorCall "sensor consulted past its script")

-- | @Delivery(source, tokens, identity=identity)@ for a valid parcel.
mkDelivery :: NetPath -> [Token] -> Text -> Engine.Delivery
mkDelivery source tokens identity = mkScopedDelivery source tokens identity Nothing

-- | @Delivery(source, tokens, identity=identity, scope=scope)@ for a valid
-- parcel.
mkScopedDelivery :: NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Engine.Delivery
mkScopedDelivery source tokens identity scope =
  either (error . T.unpack) id (Engine.delivery source tokens identity scope)

-- ---------------------------------------------------------------------------
-- Joined-transaction History

-- | @_TransactionalHistory@: hermetic read-own-writes History with explicit
-- commit/rollback fate.
data TransactionalHistory = TransactionalHistory
  { store :: HistoryStore
  , committedRef :: IORef [Record]
  , pendingRef :: IORef [Record]
  , commits :: IORef Int
  , refuse :: IORef (Set Int)
  -- ^ Commit ordinals (1-based) that raise @RuntimeError("commit N refused")@.
  , rollbacks :: IORef Int
  }

newTransactionalHistory :: IO TransactionalHistory
newTransactionalHistory = do
  committedRef <- newIORef []
  pendingRef <- newIORef []
  commits <- newIORef 0
  refuse <- newIORef Set.empty
  rollbacks <- newIORef 0
  let everything = (<>) <$> readIORef committedRef <*> readIORef pendingRef
      store =
        HistoryStore
          { snapshot = Seq.fromList <$> everything
          , count = length <$> everything
          , extend = \batch -> modifyIORef' pendingRef (<> batch)
          , mode = JoinedTransaction
          }
  pure TransactionalHistory {store, committedRef, pendingRef, commits, refuse, rollbacks}

-- | @history.commit()@.
txCommit :: TransactionalHistory -> IO ()
txCommit tx = do
  n <- atomicModifyIORef' tx.commits (\c -> (c + 1, c + 1))
  refused <- Set.member n <$> readIORef tx.refuse
  if refused
    then throwIO (Engine.EngineRuntimeError ("commit " <> T.pack (show n) <> " refused"))
    else do
      held <- readIORef tx.pendingRef
      modifyIORef' tx.committedRef (<> held)
      writeIORef tx.pendingRef []

-- | @history.rollback()@.
txRollback :: TransactionalHistory -> IO ()
txRollback tx = do
  modifyIORef' tx.rollbacks (+ 1)
  writeIORef tx.pendingRef []

txCommitted, txPending :: TransactionalHistory -> IO [Record]
txCommitted tx = readIORef tx.committedRef
txPending tx = readIORef tx.pendingRef

-- | @_EngineResources(commit=history.commit, rollback=history.rollback,
-- release=release)@.
txResources :: TransactionalHistory -> IO () -> EngineResources
txResources tx release = defaultResources {commit = Just (txCommit tx), rollback = txRollback tx, release}

-- ---------------------------------------------------------------------------
-- Implementations

-- | Implementations keyed by local symbol (@handlers={"name": ...}@).
symbols :: [(Text, a)] -> Map ImplementationRef a
symbols xs = Map.fromList [(Symbol k, v) | (k, v) <- xs]

-- ---------------------------------------------------------------------------
-- Selectors

-- | @pytest.raises(ValueError, match=fragment)@ (substring match).
valueError :: Text -> Selector Engine.EngineError
valueError fragment = \case
  Engine.EngineValueError m -> fragment `T.isInfixOf` m
  _ -> False

-- | @pytest.raises(TypeError, match=fragment)@.
typeError :: Text -> Selector Engine.EngineError
typeError fragment = \case
  Engine.EngineTypeError m -> fragment `T.isInfixOf` m
  _ -> False

-- | @pytest.raises(RuntimeError, match=fragment)@.
runtimeError :: Text -> Selector Engine.EngineError
runtimeError fragment = \case
  Engine.EngineRuntimeError m -> fragment `T.isInfixOf` m
  _ -> False

-- | A pure handler's failure whose recorded text contains the fragment.
handlerFailed :: Text -> Selector Engine.EngineError
handlerFailed fragment = \case
  Engine.EngineHandlerFailed m -> fragment `T.isInfixOf` m
  _ -> False

-- | Any Engine error whose message contains the fragment.
anyEngineError :: Text -> Selector Engine.EngineError
anyEngineError fragment e = fragment `T.isInfixOf` Engine.engineErrorMessage e

-- | The error's message.
messageOf :: Engine.EngineError -> Text
messageOf = Engine.engineErrorMessage
