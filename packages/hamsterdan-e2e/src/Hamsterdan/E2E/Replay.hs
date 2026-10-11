-- | Replay a tier B tape into the Haskell host (docs/hamsterdan.md §5.2,
-- tier B step 2), the twin of @python/replay_python.py@.
--
-- The host is the real 'HostService' over the production GitHub client
-- stack ('newAppClients': App JWT, installation token, bounded transport),
-- sent to @python/tape_server.py@ through 'newPlainExchangeAt', with three
-- replayed seams the service already takes:
--
-- * 'replayRunner': the 'AgentRunner' answering from the tape's
--   @agents.jsonl@, keyed by @(kind, operation, attempt)@, failing on an
--   unknown key;
-- * 'replayPublisher': the Git publisher answering from
--   @publisher.jsonl@, in order (@ApplicationOptions.mutationPublisher@);
-- * the step clock: each step's recorded clock (@ServiceOptions.clock@).
--
-- 'runReplay' runs the tape's steps and returns the same report the Python
-- driver writes.
module Hamsterdan.E2E.Replay
  ( ReplayOptions (..)
  , runReplay
  , replayRunner
  , replayPublisher
  , raiseRecorded
  , RecordedError (..)
  ) where

import Control.Exception (Exception (..), SomeException (..), throwIO, try)
import Control.Monad (forM, forM_, join, unless, void, when)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isDigit)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Contract, renderDecodeError, validate)
import Hamsterdan.Contracts.Codec qualified as Codec
import Hamsterdan.E2E.Tape
import Hamsterdan.GitHub.Client (AppCredentials (..), ClientOptions (..), newAppClients)
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Http (newPlainExchangeAt)
import Hamsterdan.GitHub.Models (BoundaryKind (..), FailureClass, GitHubBoundaryError (..), InstallationInventory (..), failureClassName)
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agenticus (activateRoutes, claimRoute, closeRoutes, composeAgent, openAgentRouteStore, settleRoutes)
import Hamsterdan.Host.GitPublish (GitPublishError (..), GitPublishResult (..), GitReconciliation (..), OperationDisposition (..), PublicationCategory (BoundaryUnavailable), categoryName, operationDispositionText)
import Hamsterdan.Host.Service
  ( AgentCustody (..)
  , HostApplication (..)
  , HostService (..)
  , ServiceOptions (..)
  , gitHubHostClients
  , openHostService
  , serviceOptions
  , v5ApplicationFactory
  )
import Hamsterdan.Host.Service qualified as Host
import Hamsterdan.Host.V5.Application (ApplicationOptions (..))
import Hamsterdan.Host.V5.Mutation (MutationPublisher (..))
import Petrus.Json (Json (..))
import Petrus.Json.Python (pythonStr)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

data ReplayOptions = ReplayOptions
  { tape :: FilePath
  , root :: FilePath
  , githubPort :: Int
  , serverLog :: FilePath
  -- ^ The replay server's log, read to tell when a converge step is quiescent.
  , privateKey :: Text
  -- ^ Any App key: the replay server does not check the JWT.
  }

-- ---------------------------------------------------------------------------
-- Agents

type Key = (Text, Text, Integer)

-- | The replay 'AgentRunner' and its report (@ReplayRunner.report()@).
replayRunner :: Tape -> IO (AgentRunner, IO Json)
replayRunner tape = do
  keyed <- forM tape.agents $ \record -> (,[record]) <$> keyOf record
  calls <- newIORef (Map.fromListWith (flip (<>)) keyed :: Map Key [Json])
  logged <- newIORef []
  unknown <- newIORef []
  mismatches <- newIORef []
  let keyJson (kind, operation, attempt) = [("kind", String kind), ("operation", String operation), ("attempt", Int attempt)]
      call :: (Contract request, Contract result) => Text -> Text -> request -> Invocation -> IO result
      call kind url request invocation = do
        let key = (kind, invocation.operation, invocation.attempt)
        recorded <- atomicModifyIORef' calls $ \known -> case Map.lookup key known of
          Just (record : rest) -> (Map.insert key rest known, Just record)
          _ -> (known, Nothing)
        case recorded of
          Nothing -> do
            modifyIORef' unknown (<> [Object (keyJson key)])
            throwIO (protocolError ("replay: no recorded " <> kind <> " call for " <> invocation.operation <> " attempt " <> T.pack (show invocation.attempt)))
          Just record -> do
            sequence' <- field "seq" record
            modifyIORef' logged (<> [Object (keyJson key <> [("seq", sequence')])])
            let sent = Codec.dump request
            recordedRequest <- field "request" record
            repositoryUrl <- field "repository_url" record
            when (canonical sent /= canonical recordedRequest || String url /= repositoryUrl) $
              modifyIORef' mismatches (<> [Object (keyJson key <> [("recorded", recordedRequest), ("sent", sent)])])
            expectations <- field @[Bool] "is_current" record
            forM_ expectations $ \expected -> do
              observed <- fromMaybe (pure True) invocation.isCurrent
              when (observed /= expected) $
                modifyIORef' mismatches (<> [Object (keyJson key <> [("is_current", Array [Bool expected, Bool observed])])])
            optionalField "error" record >>= \case
              Nothing -> field "result" record >>= either (\problem -> throwIO (protocolError ("replay: recorded result refused: " <> renderDecodeError problem))) pure . validate
              Just failure -> raiseRecorded failure
      runner =
        AgentRunner
          { review = call "review"
          , converse = call "converse"
          , code = call "code"
          }
      report = do
        left <- readIORef calls
        known <- readIORef logged
        unknownCalls <- readIORef unknown
        mismatched <- readIORef mismatches
        pure $
          Object
            [ ("calls", Array known)
            , ("unknown", Array unknownCalls)
            , ("mismatches", Array mismatched)
            , ("unused", Array [Object (keyJson key) | (key, items) <- Map.toList left, _ <- items])
            ]
  pure (runner, report)
  where
    keyOf record = (,,) <$> field "kind" record <*> field "operation" record <*> field "attempt" record

-- | Throw the exception a tape recorded (@host_seams.raise_recorded@).
raiseRecorded :: Json -> IO a
raiseRecorded failure =
  field "class" failure >>= \case
    "AgentProtocolError" -> do
      reason <- field "reason" failure
      canceled <- field "canceled" failure
      timedOut <- field "timed_out" failure
      resultCategory <- category "result_category"
      cleanupCategory <- category "cleanup_category"
      throwIO AgentProtocolError {reason, canceled, timedOut, resultCategory, cleanupCategory}
    "GitPublishError" -> GitPublishError <$> named "category" categoryName [minBound .. maxBound] <*> field "reason" failure >>= throwIO
    name
      | name `elem` ["GitHubBoundaryError", "GitHubObjectWriteError"] -> do
          recordedMessage <- field "message" failure
          failureClass <- named "failure_class" failureClassName [minBound .. maxBound :: FailureClass]
          -- @GitHubBoundaryError.__init__@'s checks.
          providerStatus <- field "provider_status" failure
          unless (all (\status -> 100 <= status && status <= 599) providerStatus) $
            refused "provider_status" (maybe Null Int providerStatus)
          providerDetail <- field "provider_detail" failure
          unless (boundedDetail providerDetail) $ refused "provider_detail" (String providerDetail)
          throwIO
            GitHubBoundaryError
              { kind = if name == "GitHubObjectWriteError" then ObjectWrite else Boundary
              , message = recordedMessage
              , failureClass
              , providerStatus = fromInteger <$> providerStatus
              , providerDetail
              }
      | otherwise -> do
          reason <- optionalField "reason" failure
          throwIO (RecordedError name (maybe "" pythonStr reason))
  where
    category :: (Contract c) => Text -> IO (Maybe c)
    category key = field key failure >>= traverse (\value -> either (const (refused key value)) pure (validate value))
    named :: Text -> (c -> Text) -> [c] -> IO c
    named key spelling choices = do
      spelled <- field key failure
      maybe (refused key (String spelled)) pure (listToMaybe [c | c <- choices, spelling c == spelled])
    -- @re.fullmatch(r"[a-z0-9_.:-]+", detail)@, at most 96 characters.
    boundedDetail detail =
      not (T.null detail) && T.length detail <= 96 && T.all (\c -> isAsciiLower c || isDigit c || c `elem` ("_.:-" :: String)) detail

-- | A recorded exception of another class: Python's
-- @RuntimeError(f"recorded {kind}: {error.get('reason', '')}")@, its text
-- the same.
data RecordedError = RecordedError Text Text
  deriving stock (Show)

instance Exception RecordedError where
  displayException (RecordedError kind reason) = T.unpack ("recorded " <> kind <> ": " <> reason)

-- ---------------------------------------------------------------------------
-- The Git publisher

-- | The replay Git publisher and its report (@ReplayPublisher.report()@).
replayPublisher :: Tape -> IO (MutationPublisher, IO Json)
replayPublisher tape = do
  records <- newIORef tape.publisher
  logged <- newIORef []
  mismatches <- newIORef []
  let answer :: Text -> [(Text, Json)] -> (Json -> IO a) -> IO a
      answer method arguments decode = do
        next <- atomicModifyIORef' records $ \case
          record : rest -> (rest, Just record)
          [] -> ([], Nothing)
        case next of
          Nothing -> do
            modifyIORef' mismatches (<> [Object [("method", String method), ("arguments", Object arguments), ("recorded", Null)]])
            throwIO (GitPublishError BoundaryUnavailable "replay: no recorded publisher call")
          Just record -> do
            sequence' <- field "seq" record
            modifyIORef' logged (<> [Object [("method", String method), ("seq", sequence')]])
            recordedMethod <- field "method" record
            recordedArguments <- field "arguments" record
            when (recordedMethod /= String method || canonical recordedArguments /= canonical (Object arguments)) $
              modifyIORef' mismatches (<> [Object [("method", String method), ("arguments", Object arguments), ("recorded", record)]])
            optionalField "error" record >>= \case
              Nothing -> field "outcome" record >>= decode
              Just failure -> raiseRecorded failure
      keywords operation digest expectedHead baseHead mergeBase =
        [ ("operation", String operation)
        , ("payload_digest", String digest)
        , ("expected_head", String expectedHead)
        , ("base_head", String baseHead)
        , ("merge_base", Bool mergeBase)
        ]
      publisher =
        MutationPublisher
          { reconcile = \operation digest expectedHead baseHead mergeBase ->
              answer "reconcile" (keywords operation digest expectedHead baseHead mergeBase) $ \value -> do
                spelled <- field "disposition" value
                disposition <-
                  maybe (refused "disposition" (String spelled)) pure $
                    listToMaybe [d | d <- [OperationAbsent, OperationExisting], operationDispositionText d == spelled]
                GitReconciliation disposition <$> field "observed_head" value <*> field "commit" value <*> field "parents" value
          , publish = \result operation digest expectedHead baseHead mergeBase ->
              answer "publish" (keywords operation digest expectedHead baseHead mergeBase <> [("result", Codec.dump result)]) $ \value ->
                GitPublishResult <$> field "head" value <*> field "recovered" value
          }
      report = do
        left <- readIORef records
        known <- readIORef logged
        mismatched <- readIORef mismatches
        unused <- mapM (field "seq") left
        pure (Object [("calls", Array known), ("mismatches", Array mismatched), ("unused", Array unused)])
  pure (publisher, report)

-- ---------------------------------------------------------------------------
-- The host

-- | Replay the tape's steps into a fresh Haskell host on @root@ and report
-- per step whether it went as recorded, with the runner's and publisher's
-- reports (@replay_python.replay@). A step the recording raised on
-- (@raises@) must raise again with the same message.
runReplay :: ReplayOptions -> IO Json
runReplay options = do
  tape <- readTape options.tape
  settings <- field "config" tape.meta
  replaySecret <- field "replay_webhook_secret" settings
  appId <- field "app_id" settings
  appSlug <- field "app_slug" settings
  clientId <- field "client_id" settings
  accounts <- field "accounts" settings
  watchedAuthors <- fromMaybe [] <$> optionalField "watched_authors" settings
  let config =
        HostConfig
          { appId
          , appSlug = T.toCaseFold appSlug
          , clientId
          , accounts =
              [ AccountConfig account login [(rid, T.toCaseFold name) | (rid, name) <- repositories]
              | (account, login, repositories) <- accounts
              ]
          , statePath = options.root
          , watchedAuthors = Set.fromList watchedAuthors
          , privateKey = secret options.privateKey
          , webhookSecret = secret replaySecret
          }
  -- @meta.get("agent") or {}@
  agent <- fromMaybe (Object []) . join <$> optionalField "agent" tape.meta
  provider <- join <$> optionalField "provider" agent
  model <- join <$> optionalField "model" agent
  composition <- composeAgent Nothing provider model
  store <- openAgentRouteStore (options.root </> "agent-routes.sqlite3")
  activateRoutes store composition (options.root </> "applications")
  let custody =
        AgentCustody
          { claim = \operation -> void (claimRoute store operation composition)
          , settleOperations = settleRoutes store . Set.toList
          , close = closeRoutes store
          }
  exchange <- newPlainExchangeAt "127.0.0.1" options.githubPort
  appClients <-
    newAppClients
      AppCredentials {appId = config.appId, clientId = config.clientId, privateKey = options.privateKey}
      ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}
  (runner, runnerReport) <- replayRunner tape
  (publisher, publisherReport) <- replayPublisher tape
  clock <- newIORef =<< case tape.steps of
    first : _ -> field "clock" first
    [] -> pure 0
  runnerCalls <- newIORef (0 :: Int)
  publisherCalls <- newIORef (0 :: Int)
  let counted ref action = modifyIORef' ref (+ 1) >> action
      counting =
        AgentRunner
          { review = \u r i -> counted runnerCalls (runner.review u r i)
          , converse = \u r i -> counted runnerCalls (runner.converse u r i)
          , code = \u r i -> counted runnerCalls (runner.code u r i)
          }
      countingPublisher =
        MutationPublisher
          { reconcile = \a b c d e -> counted publisherCalls (publisher.reconcile a b c d e)
          , publish = \r a b c d e -> counted publisherCalls (publisher.publish r a b c d e)
          }
  workflowPath <- field "workflow_path" settings
  reminderDelay <- field "reminder_seconds" settings
  host <-
    openHostService
      config
      (serviceOptions counting custody)
        { clients = Just (gitHubHostClients appClients)
        , applicationFactory = \root' instanceId authority runner' applicationOptions ->
            v5ApplicationFactory root' instanceId authority runner' applicationOptions {mutationPublisher = Just countingPublisher}
        , clock = Just (readIORef clock)
        , workflowPath
        , reminderDelay
        }
  closed <- newIORef False
  let serverLines = do
        present <- doesFileExist options.serverLog
        if present then length . T.lines . TE.decodeUtf8Lenient <$> BS.readFile options.serverLog else pure 0
      quiet = (,,) <$> serverLines <*> readIORef runnerCalls <*> readIORef publisherCalls
      unresolved = do
        loaded <- readIORef host.loaded
        or <$> mapM (.app.hasUnresolvedPublication) (Map.elems loaded)
      run step op = case op of
        "registry" -> do
          inventories <- field "inventories" step
          void . Routing.reconcile host.registry $
            [InstallationInventory i a repositories | (i, a, repositories) <- inventories]
          pure []
        "deliver" -> do
          body <- TE.encodeUtf8 <$> field "body" step
          headers <- field "headers" step
          receipt <- Custody.receive host.custody (signedHeaders replaySecret headers body) body
          recorded <- field "disposition" step
          let disposition = dispositionName receipt.disposition
          pure [("disposition", String disposition), ("ok", Bool (String disposition == recorded))]
        "process" -> do
          delivery <- field "delivery" step
          waiting <- Custody.pending host.custody 100 Nothing
          case [item | item <- waiting, String item.deliveryId == delivery] of
            [item] -> Host.process host item >> pure []
            _ -> pure [("ok", Bool False)]
        "pump" -> do
          processed <- Host.pump host . fromInteger =<< field "limit" step
          recorded <- field "processed" step
          pure [("processed", Int (toInteger processed)), ("ok", Bool (Int (toInteger processed) == recorded))]
        "converge" -> do
          let go :: Int -> IO [(Text, Json)]
              go 0 = pure [("ok", Bool False)]
              go n = do
                before <- quiet
                processed <- Host.pump host 20
                after <- quiet
                pending <- unresolved
                if processed == 0 && before == after && not pending then pure [] else go (n - 1)
          go 50
        "sweep" -> do
          reconciled <- Host.sweep host =<< field "trigger" step
          pure [("reconciled", Int (toInteger reconciled))]
        "close" -> Host.close host >> writeIORef closed True >> pure []
        other -> pure [("ok", Bool False), ("error", String ("unknown step " <> other))]
  entries <- forM tape.steps $ \step -> do
    writeIORef clock =<< field "clock" step
    op <- field "op" step
    sequence' <- field "seq" step
    outcome <- try @SomeException (run step op)
    raises <- optionalField "raises" step
    let base = [("op", String op), ("seq", sequence')]
    pure . Object . okFirst base $ case (outcome, raises) of
      (Right fields, Nothing) -> fields
      (Right _, Just expected) -> [("ok", Bool False), ("error", String ("expected to raise: " <> expected))]
      (Left failure, Nothing) -> [("ok", Bool False), ("error", String (message failure))]
      (Left failure, Just expected) ->
        let raised = message failure
         in [("ok", Bool (raised == expected)), ("raised", String raised)]
  done <- readIORef closed
  when (not done) (Host.close host)
  agentsReport <- runnerReport
  publisherReport' <- publisherReport
  pure (Object [("steps", Array entries), ("agents", agentsReport), ("publisher", publisherReport')])
  where
    okFirst base fields = base <> [("ok", fromMaybe (Bool True) (lookup "ok" fields))] <> [entry | entry@(name, _) <- fields, name /= "ok"]

-- | The exception's own text (Python's @str(error)@), without the
-- backtrace 'SomeException' adds.
message :: SomeException -> Text
message (SomeException failure) = T.pack (displayException failure)
