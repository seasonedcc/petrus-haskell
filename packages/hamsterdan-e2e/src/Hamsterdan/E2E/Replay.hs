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
  ) where

import Control.Exception (SomeException (..), displayException, throwIO, try)
import Control.Monad (forM, forM_, void, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
import Hamsterdan.Host.GitPublish (GitPublishError (..), GitPublishResult (..), GitReconciliation (..), OperationDisposition (..), PublicationCategory (BoundaryUnavailable), categoryName)
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
  calls <- newIORef (Map.fromListWith (flip (<>)) [(keyOf record, [record]) | record <- tape.agents] :: Map Key [Json])
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
            modifyIORef' logged (<> [Object (keyJson key <> [("seq", member "seq" record)])])
            let sent = Codec.dump request
            when (canonical sent /= canonical (member "request" record) || String url /= member "repository_url" record) $
              modifyIORef' mismatches (<> [Object (keyJson key <> [("recorded", member "request" record), ("sent", sent)])])
            forM_ (list (member "is_current" record)) $ \expected -> do
              observed <- fromMaybe (pure True) invocation.isCurrent
              when (Bool observed /= expected) $
                modifyIORef' mismatches (<> [Object (keyJson key <> [("is_current", Array [expected, Bool observed])])])
            case member "error" record of
              Null -> either (\problem -> throwIO (protocolError ("replay: recorded result refused: " <> renderDecodeError problem))) pure (validate (member "result" record))
              failure -> raiseRecorded failure
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
    keyOf record = (text (member "kind" record), text (member "operation" record), integer (member "attempt" record))

-- | Throw the exception a tape recorded.
raiseRecorded :: Json -> IO a
raiseRecorded failure = case text (member "class" failure) of
  "AgentProtocolError" ->
    throwIO
      AgentProtocolError
        { reason = text (member "reason" failure)
        , canceled = member "canceled" failure == Bool True
        , timedOut = member "timed_out" failure == Bool True
        , resultCategory = either (const Nothing) Just (validate (member "result_category" failure))
        , cleanupCategory = either (const Nothing) Just (validate (member "cleanup_category" failure))
        }
  "GitPublishError" ->
    case [c | c <- [minBound .. maxBound :: PublicationCategory], categoryName c == text (member "category" failure)] of
      category : _ -> throwIO (GitPublishError category (text (member "reason" failure)))
      [] -> ioError (userError ("replay: unknown publication category in " <> show failure))
  name
    | name `elem` ["GitHubBoundaryError", "GitHubObjectWriteError"] ->
        case [c | c <- [minBound .. maxBound :: FailureClass], failureClassName c == text (member "failure_class" failure)] of
          failureClass : _ ->
            throwIO
              GitHubBoundaryError
                { kind = if name == "GitHubObjectWriteError" then ObjectWrite else Boundary
                , message = text (member "message" failure)
                , failureClass
                , providerStatus = case member "provider_status" failure of
                    Int status -> Just (fromInteger status)
                    _ -> Nothing
                , providerDetail = text (member "provider_detail" failure)
                }
          [] -> ioError (userError ("replay: unknown failure class in " <> show failure))
    | otherwise -> ioError (userError ("replay: recorded " <> T.unpack name <> ": " <> T.unpack (text (member "reason" failure))))

-- ---------------------------------------------------------------------------
-- The Git publisher

-- | The replay Git publisher and its report (@ReplayPublisher.report()@).
replayPublisher :: Tape -> IO (MutationPublisher, IO Json)
replayPublisher tape = do
  records <- newIORef tape.publisher
  logged <- newIORef []
  mismatches <- newIORef []
  let answer :: Text -> [(Text, Json)] -> (Json -> a) -> IO a
      answer method arguments decode = do
        next <- atomicModifyIORef' records $ \case
          record : rest -> (rest, Just record)
          [] -> ([], Nothing)
        case next of
          Nothing -> do
            modifyIORef' mismatches (<> [Object [("method", String method), ("arguments", Object arguments), ("recorded", Null)]])
            throwIO (GitPublishError BoundaryUnavailable "replay: no recorded publisher call")
          Just record -> do
            modifyIORef' logged (<> [Object [("method", String method), ("seq", member "seq" record)]])
            when (member "method" record /= String method || canonical (member "arguments" record) /= canonical (Object arguments)) $
              modifyIORef' mismatches (<> [Object [("method", String method), ("arguments", Object arguments), ("recorded", record)]])
            case member "error" record of
              Null -> pure (decode (member "outcome" record))
              failure -> raiseRecorded failure
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
              answer "reconcile" (keywords operation digest expectedHead baseHead mergeBase) $ \value ->
                GitReconciliation
                  { disposition = if member "disposition" value == String "existing" then OperationExisting else OperationAbsent
                  , observedHead = text (member "observed_head" value)
                  , commit = text (member "commit" value)
                  , parents = map text (list (member "parents" value))
                  }
          , publish = \result operation digest expectedHead baseHead mergeBase ->
              answer "publish" (keywords operation digest expectedHead baseHead mergeBase <> [("result", Codec.dump result)]) $ \value ->
                GitPublishResult {head = text (member "head" value), recovered = member "recovered" value == Bool True}
          }
      report = do
        left <- readIORef records
        known <- readIORef logged
        mismatched <- readIORef mismatches
        pure (Object [("calls", Array known), ("mismatches", Array mismatched), ("unused", Array (map (member "seq") left))])
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
  let settings = member "config" tape.meta
      replaySecret = text (member "replay_webhook_secret" settings)
      agent = member "agent" tape.meta
      optionalText key = case member key agent of
        String value -> Just value
        _ -> Nothing
      config =
        HostConfig
          { appId = integer (member "app_id" settings)
          , appSlug = T.toCaseFold (text (member "app_slug" settings))
          , clientId = text (member "client_id" settings)
          , accounts =
              [ AccountConfig (integer account) (text login) [(integer rid, T.toCaseFold (text name)) | Array [rid, name] <- list repositories]
              | Array [account, login, repositories] <- list (member "accounts" settings)
              ]
          , statePath = options.root
          , watchedAuthors = Set.fromList (map text (list (member "watched_authors" settings)))
          , privateKey = secret options.privateKey
          , webhookSecret = secret replaySecret
          }
  composition <- composeAgent Nothing (optionalText "provider") (optionalText "model")
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
  clock <- newIORef (case tape.steps of first : _ -> number (member "clock" first); [] -> 0)
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
  host <-
    openHostService
      config
      (serviceOptions counting custody)
        { clients = Just (gitHubHostClients appClients)
        , applicationFactory = \root' instanceId authority runner' applicationOptions ->
            v5ApplicationFactory root' instanceId authority runner' applicationOptions {mutationPublisher = Just countingPublisher}
        , clock = Just (readIORef clock)
        , workflowPath = text (member "workflow_path" settings)
        , reminderDelay = number (member "reminder_seconds" settings)
        }
  closed <- newIORef False
  let serverLines = do
        present <- doesFileExist options.serverLog
        if present then length . T.lines . TE.decodeUtf8Lenient <$> BS.readFile options.serverLog else pure 0
      quiet = (,,) <$> serverLines <*> readIORef runnerCalls <*> readIORef publisherCalls
      unresolved = do
        loaded <- readIORef host.loaded
        or <$> mapM (.app.hasUnresolvedPublication) (Map.elems loaded)
      run step = case text (member "op" step) of
        "registry" -> do
          void . Routing.reconcile host.registry $
            [ InstallationInventory (integer i) (integer a) [(integer rid, text name) | Array [rid, name] <- list repositories]
            | Array [i, a, repositories] <- list (member "inventories" step)
            ]
          pure []
        "deliver" -> do
          let body = TE.encodeUtf8 (text (member "body" step))
          receipt <- Custody.receive host.custody (signedHeaders replaySecret (member "headers" step) body) body
          let disposition = dispositionName receipt.disposition
          pure [("disposition", String disposition), ("ok", Bool (String disposition == member "disposition" step))]
        "process" -> do
          waiting <- Custody.pending host.custody 100 Nothing
          case [item | item <- waiting, String item.deliveryId == member "delivery" step] of
            [item] -> Host.process host item >> pure []
            _ -> pure [("ok", Bool False)]
        "pump" -> do
          processed <- Host.pump host (fromInteger (integer (member "limit" step)))
          pure [("processed", Int (toInteger processed)), ("ok", Bool (Int (toInteger processed) == member "processed" step))]
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
          reconciled <- Host.sweep host (text (member "trigger" step))
          pure [("reconciled", Int (toInteger reconciled))]
        "close" -> Host.close host >> writeIORef closed True >> pure []
        other -> pure [("ok", Bool False), ("error", String ("unknown step " <> other))]
  entries <- forM tape.steps $ \step -> do
    writeIORef clock (number (member "clock" step))
    outcome <- try @SomeException (run step)
    let base = [("op", member "op" step), ("seq", member "seq" step)]
    pure . Object . okFirst base $ case (outcome, member "raises" step) of
      (Right fields, Null) -> fields
      (Right _, expected) -> [("ok", Bool False), ("error", String ("expected to raise: " <> text expected))]
      (Left failure, Null) -> [("ok", Bool False), ("error", String (message failure))]
      (Left failure, expected) ->
        let raised = message failure
         in [("ok", Bool (String raised == expected)), ("raised", String raised)]
  done <- readIORef closed
  when (not done) (Host.close host)
  agentsReport <- runnerReport
  publisherReport' <- publisherReport
  pure (Object [("steps", Array entries), ("agents", agentsReport), ("publisher", publisherReport')])
  where
    number = \case
      Int value -> fromInteger value
      Float value -> value
      _ -> 0
    okFirst base fields = base <> [("ok", fromMaybe (Bool True) (lookup "ok" fields))] <> [field | field@(name, _) <- fields, name /= "ok"]

-- | The exception's own text (Python's @str(error)@), without the
-- backtrace 'SomeException' adds.
message :: SomeException -> Text
message (SomeException failure) = T.pack (displayException failure)
