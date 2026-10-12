{-# LANGUAGE MultiWayIf #-}

-- | The CV5.DS2 lifecycle acceptance demo (upstream
-- @scripts/cv5-lifecycle-demo.py@): a parent Engine spawns a child through
-- the retry-safe @process.spawn@ Activity (losing the first completion),
-- calls it over Fabric, ignores an unrelated reply, completes on the
-- correlated result, and a second pair completes on a correlated error.
-- Nets, handler names, invocations, environment variables and printed lines
-- are the reference's, so the child subprocess may be the reference's
-- script and this executable's orchestrator, or the reverse.
--
-- Two additions serve the cross-implementation checks and change nothing in
-- the scenario: @--child-command@ runs the child subprocess with another
-- implementation, and @--spawn-worker-command@ executes @process.spawn@ in
-- a worker of another implementation (@--internal-spawn-worker@ is this
-- implementation's worker; the protocol is one JSON object per line).
module Petrus.Processes.Demo
  ( -- * Nets and handlers
    callId
  , parentNet
  , childNet
  , callEnvelope
    -- * Dispatch and roles
  , DemoDispatch (..)
  , newDemoDispatch
  , demoDispatch
  , SendActivity (..)
  , newSendActivity
  , runSend
  , LiveAuthority (..)
  , openParent
  , openChild
  , closeAuthority
  , drive
  , drainAuthority
  , bootstrap
  , historySize
    -- * Spawning
  , CountingProvisioner (..)
  , countingProvisioner
  , workerRequest
  , spawnWorker
    -- * The demo
  , Commands (..)
  , run
  , runErrorCall
  , childSubprocess
  , demoMain
  ) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, finally, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Petrus.Activity (ActivityInvocation, ActivityInvocationFields (..), activityInvocation, defaultExecutionPolicy)
import Petrus.Motus.PythonException (ValueError (..), pythonException, pythonExceptionStr)
import Petrus.Motus.PythonException qualified as Python (PythonException (..))
import Petrus.Engine (DriveOutcome (..), Engine, EngineOptions (..), defaultEngineOptions)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres (createEngine, loadEngine)
import Petrus.Fabric
import Petrus.Fabric.Engine (engineInbox)
import Petrus.Fabric.Postgres (PostgresFabric, ensureFabricSchema, exposeSource, grant, inboxClient, issueCredential, pending, postgresFabric, registerProcess, submit)
import Petrus.Fabric.Send (sendInvocation, sendResult)
import Petrus.HistoryStore.Postgres (ensureSchema, loadPostgresHistory)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult (..), handlerTokens)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (ActivityCompleted (..), DeliveryRegistration (..), Record (..))
import Petrus.Impetus.Instance (ImplementationRef (..), Status (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..), compact, defaultDumps, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityOutcome (..), Dispatch (..))
import Petrus.Postgres (Connection, textArrayParam, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.Processes
import Petrus.Processes.Postgres (ensureLifecycleSchema, hmacChildCredential, postgresSpawnRegistry, referenceProvisioner, spawnRegistry)
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hIsEOF, hPutStrLn, hSetBuffering, stderr, stdin, stdout)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Nets

pathOf :: Text -> NetPath
pathOf = either (error . T.unpack) id . netPath

start, spawned, waiting, replies, unrelated, done, spawnT, callT, replySource, joinT, requests, childDone, requestSource, respond :: NetPath
start = pathOf "start"
spawned = pathOf "spawned"
waiting = pathOf "waiting"
replies = pathOf "replies"
unrelated = pathOf "unrelated"
done = pathOf "done"
spawnT = pathOf "spawn"
callT = pathOf "call"
replySource = pathOf "reply"
joinT = pathOf "join"
requests = pathOf "requests"
childDone = pathOf "child_done"
requestSource = pathOf "request"
respond = pathOf "respond"

callId :: Text
callId = "call/main"

handled :: NetPath -> Text -> Transition
handled at symbol = (transition at) {handler = Just (HandlerSymbol symbol)}

colored :: NetPath -> NetPath -> Arc
colored from to = withArcColor (Just fabricEnvelopeColor) (arc from to)

parentNet :: Bool -> Net
parentNet withSpawn =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place ([start, waiting, replies, unrelated, done] <> [spawned | withSpawn])
        , transitions = [handled spawnT "spawn" | withSpawn] <> [handled callT "call", handled replySource "reply", handled joinT "join"]
        , arcs = (if withSpawn then [arc start spawnT, arc spawnT spawned, arc spawned callT] else [arc start callT]) <> rest
        , completion = Just (CompletionSymbol "done")
        , name = Nothing
        }
  where
    rest =
      [ arc callT waiting
      , colored replySource replies
      , colored replySource unrelated
      , arc waiting joinT
      , colored replies joinT
      , arc joinT done
      ]

childNet :: Net
childNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place [requests, childDone]
        , transitions = [handled requestSource "request", handled respond "respond"]
        , arcs = [colored requestSource requests, arc requests respond, arc respond childDone]
        , completion = Just (CompletionSymbol "done")
        , name = Nothing
        }

-- | @completed(marking)@.
completed :: Marking -> Either Text Bool
completed m = Right (not (null (placeTokens done m)) || not (null (placeTokens childDone m)))

-- ---------------------------------------------------------------------------
-- Handlers

orFail :: Either FabricError a -> Either Text a
orFail = either (Left . errorMessage) Right

orThrowIO :: Either FabricError a -> IO a
orThrowIO = either throwIO pure

single :: Binding -> Either Text Token
single binding = case bindingTokens binding of
  [t] -> Right t
  ts -> Left ("ValueError: too many values to unpack (expected 1, got " <> T.pack (show (length ts)) <> ")")

spawnHandler :: SpawnSpec -> BoundHandler
spawnHandler spec =
  ActivityBound
    ActivityHandler
      { prepare = \_ -> spawnInvocation spec
      , project = \_ result -> do
          outcome <- orFail (spawnOutcomeFromData result)
          Right (handlerTokens [(spawned, [token "SpawnReady" (spawnOutcomeToData outcome)])])
      , projectFailure = Nothing
      }

callHandler :: Envelope -> BoundHandler
callHandler e =
  ActivityBound
    ActivityHandler
      { prepare = \_ -> sendInvocation e
      , project = \_ result ->
          Right
            HandlerResult
              { tokens = [(waiting, [token "CallWait" (Object [("call_id", String e.correlation), ("submission", result)])])]
              , opens = [DeliveryRegistration replySource e.correlation]
              , closes = []
              }
      , projectFailure = Nothing
      }

replyHandler :: Envelope -> BoundHandler
replyHandler request = PureHandler $ \binding _ -> do
  t <- single binding
  e <- orFail (envelopeFromData t.payload)
  let callOf = case e.payload of
        Object _ -> lookupMember "call_id" e.payload
        _ -> Nothing
  if callOf /= Just (String callId)
    then Right (handlerTokens [(unrelated, [t])])
    else do
      _ <- orFail (replyFromEnvelope e request)
      Right (HandlerResult [(replies, [t])] [] [DeliveryRegistration replySource e.correlation])

joinHandler :: BoundHandler
joinHandler = PureHandler $ \binding _ -> do
  t <- maybe (Left "StopIteration") Right (foldr (\x acc -> if x.color == Just fabricEnvelopeColor then Just x else acc) Nothing (bindingTokens binding))
  reply <- orFail (envelopeFromData t.payload)
  when (reply.correlation /= callId) (Left "join received an unrelated call reply")
  let kind = if lookupMember "kind" reply.payload == Just (String "process.call.result") then "result" else "error"
  Right (handlerTokens [(done, [token "CallDone" (Object [("call_id", String callId), ("outcome", String kind)])])])

requestHandler :: BoundHandler
requestHandler = PureHandler $ \binding _ -> do
  t <- single binding
  Right (HandlerResult [(requests, [t])] [] [DeliveryRegistration requestSource "default"])

respondHandler :: Text -> Text -> BoundHandler
respondHandler child outcome =
  ActivityBound
    ActivityHandler
      { prepare = \binding -> do
          first <- case bindingTokens binding of
            t : _ -> Right t
            [] -> Left "IndexError: tuple index out of range"
          request <- orFail (envelopeFromData first.payload)
          call <- orFail (callRequestFromData request.payload)
          reply <-
            orFail $
              if outcome == "result"
                then do
                  value <- callResult call.callId (Object [("answer", Int 42)])
                  resultEnvelope value request child Nothing
                else do
                  value <- callError call.callId "delegated-refusal" "child refused delegated work" Null
                  errorEnvelope value request child Nothing
          sendInvocation reply
      , project = \_ result -> Right (handlerTokens [(childDone, [token "CallDone" (Object [("submission", result), ("outcome", String outcome)])])])
      , projectFailure = Nothing
      }

parentHandlers :: SpawnSpec -> Envelope -> Bool -> Map ImplementationRef BoundHandler
parentHandlers spec e withSpawn =
  Map.fromList
    ( [(Symbol "call", callHandler e), (Symbol "reply", replyHandler e), (Symbol "join", joinHandler)]
        <> [(Symbol "spawn", spawnHandler spec) | withSpawn]
    )

-- | @call_envelope(parent, child)@.
callEnvelope :: Text -> Text -> Envelope
callEnvelope parent child =
  either (error . T.unpack . errorMessage) id $ do
    request <- callRequest callId "answer" (Object [("question", Int 42)])
    back <- replyRoute parent "reply"
    requestEnvelope request parent child "request" back Nothing

-- ---------------------------------------------------------------------------
-- Activities and dispatch

-- | The lifecycle demo's @SendActivity@.
data SendActivity = SendActivity {connection :: Connection, client :: PostgresFabric}

newSendActivity :: ByteString -> Text -> Text -> IO SendActivity
newSendActivity dsn authority credential = do
  c <- Pg.connect dsn True
  SendActivity c <$> (postgresFabric c authority credential `onException` Pg.close c)

runSend :: SendActivity -> ActivityInvocation -> IO Json
runSend a inv = do
  e <- orThrowIO (envelopeFromData inv.input)
  unless (inv.idempotency == Just e.ingressIdentity) $
    throwIO (InvalidValue "fabric.send idempotency must match the envelope identity")
  sendResult e <$> submit a.client e

closeSend :: SendActivity -> IO ()
closeSend a = Pg.close a.connection

-- | @DemoInlineDispatch@: execute now; optionally lose one post-effect
-- completion per named activity.
data DemoDispatch = DemoDispatch
  { activities :: Map Text (ActivityInvocation -> IO Json)
  , dropOnce :: Set Text
  , dropped :: IORef (Set Text)
  , completedOutcomes :: IORef [(Int, ActivityOutcome)]
  , dispatches :: IORef Int
  }

newDemoDispatch :: Map Text (ActivityInvocation -> IO Json) -> Set Text -> IO DemoDispatch
newDemoDispatch registry dropping = DemoDispatch registry dropping <$> newIORef Set.empty <*> newIORef [] <*> newIORef 0

demoDispatch :: DemoDispatch -> Dispatch
demoDispatch d =
  Dispatch
    { dispatch = \occurrence inv -> do
        modifyIORef' d.dispatches (+ 1)
        execute <- maybe (throwIO (userError ("KeyError: " <> show inv.activity))) pure (Map.lookup inv.activity d.activities)
        result <- execute inv
        already <- readIORef d.dropped
        if inv.activity `Set.member` d.dropOnce && not (inv.activity `Set.member` already)
          then modifyIORef' d.dropped (Set.insert inv.activity)
          else modifyIORef' d.completedOutcomes ((occurrence, Succeeded result) :)
    , collect = atomicModifyIORef' d.completedOutcomes (\xs -> ([], reverse xs))
    , cancel = Nothing
    }

-- ---------------------------------------------------------------------------
-- Authorities

data LiveAuthority = LiveAuthority
  { engine :: Engine
  , fabricConnection :: Connection
  , dispatcher :: DemoDispatch
  , inbox :: FabricInbox
  , send :: SendActivity
  }

closeAuthority :: LiveAuthority -> IO ()
closeAuthority live = do
  Engine.close live.engine
  Pg.close live.fabricConnection
  closeSend live.send

drive :: LiveAuthority -> IO DriveOutcome
drive live = go []
  where
    go acc = do
      outcome <- Engine.advance live.engine
      let acc' = acc <> outcome.firings
      if outcome.ready then go acc' else pure (DriveOutcome acc' outcome.waiting False outcome.nextMaturation)

drainAuthority :: LiveAuthority -> IO Int
drainAuthority live = length <$> drain live.inbox 100

options :: Map ImplementationRef BoundHandler -> EngineOptions
options hs = defaultEngineOptions {handlers = hs, completions = Map.fromList [("done", completed)]}

-- | @open_parent(...)@.
openParent :: ByteString -> Text -> Text -> SpawnSpec -> Envelope -> DemoDispatch -> SendActivity -> Bool -> Bool -> IO LiveAuthority
openParent dsn parent credential spec e dispatcher send create withSpawn =
  flip onException (closeSend send) $ do
    connection <- Pg.connect dsn False
    let base = options (parentHandlers spec e withSpawn)
        opts = if create then base {marking = markingFromList [(start, [token "Start" (Object [("call_id", String callId)])])]} else base
    engine <- (if create then createEngine else loadEngine) connection (parentNet withSpawn) parent (demoDispatch dispatcher) opts
    flip onException (Engine.close engine) $ do
      when create (Engine.seal engine replySource)
      fabricConnection <- Pg.connect dsn True
      client <- postgresFabric fabricConnection parent credential `onException` Pg.close fabricConnection
      pure (LiveAuthority engine fabricConnection dispatcher (engineInbox (inboxClient client) engine) send)

-- | @open_child(...)@.
openChild :: ByteString -> Text -> Text -> Text -> Text -> Bool -> IO LiveAuthority
openChild dsn _parent child credential outcome create = do
  send <- newSendActivity dsn child credential
  flip onException (closeSend send) $ do
    dispatcher <- newDemoDispatch (Map.fromList [("fabric.send", runSend send)]) Set.empty
    connection <- Pg.connect dsn False
    let opts = options (Map.fromList [(Symbol "request", requestHandler), (Symbol "respond", respondHandler child outcome)])
    engine <- (if create then createEngine else loadEngine) connection childNet child (demoDispatch dispatcher) opts
    flip onException (Engine.close engine) $ do
      fabricConnection <- Pg.connect dsn True
      client <- postgresFabric fabricConnection child credential `onException` Pg.close fabricConnection
      pure (LiveAuthority engine fabricConnection dispatcher (engineInbox (inboxClient client) engine) send)

expect :: Bool -> String -> IO ()
expect condition what = unless condition (throwIO (userError ("AssertionError: " <> what)))

statusOf :: LiveAuthority -> IO Status
statusOf live = Engine.status live.engine

-- | @child_subprocess()@: the child host, configured by
-- @IMPETUS_LIFECYCLE_*@.
childSubprocess :: IO ()
childSubprocess = do
  dsn <- BC.pack <$> getEnv "IMPETUS_LIFECYCLE_DSN"
  parent <- T.pack <$> getEnv "IMPETUS_LIFECYCLE_PARENT"
  child <- T.pack <$> getEnv "IMPETUS_LIFECYCLE_CHILD"
  credential <- T.pack <$> getEnv "IMPETUS_LIFECYCLE_CHILD_CREDENTIAL"
  outcome <- T.pack <$> getEnv "IMPETUS_LIFECYCLE_OUTCOME"
  bracket (openChild dsn parent child credential outcome True) closeAuthority $ \live -> do
    drained <- drainAuthority live
    expect (drained == 1) "the child drained one request"
    _ <- drive live
    statusOf live >>= \s -> expect (s == Completed) "the child completed"

-- | @history_size(dsn, instance)@.
historySize :: ByteString -> Text -> IO Int
historySize dsn instanceId = Pg.withConnection dsn True $ \c -> length <$> loadPostgresHistory c instanceId

-- | @bootstrap(dsn, *processes)@.
bootstrap :: ByteString -> [(Text, Text)] -> IO ()
bootstrap dsn processes = Pg.withConnection dsn True $ \c -> do
  ensureSchema c
  ensureFabricSchema c
  ensureLifecycleSchema c
  forM_ processes $ \(instanceId, credential) -> registerProcess c instanceId credential

-- ---------------------------------------------------------------------------
-- Spawning

-- | @DemoProvisioner@: the reference provisioning profile with HMAC child
-- credentials, counting its @ensure@ calls.
data CountingProvisioner = CountingProvisioner {provisioner :: ProcessProvisioner, ensureCalls :: IORef Int, childCredential :: Text -> Text}

countingProvisioner :: ByteString -> Text -> ByteString -> IO CountingProvisioner
countingProvisioner dsn parentCredential key = do
  calls <- newIORef 0
  let credentialOf = hmacChildCredential key
      inner = referenceProvisioner dsn parentCredential credentialOf
  pure (CountingProvisioner (ProcessProvisioner (\p -> modifyIORef' calls (+ 1) >> inner.ensure p)) calls credentialOf)

-- | One spawn-worker request (the protocol both implementations' workers
-- speak): the store, the parent's credential, the workspace key (hex) and
-- the invocation.
workerRequest :: ByteString -> Text -> Text -> ByteString -> ActivityInvocation -> Json
workerRequest dsn parent parentCredential key inv =
  Object
    [ ("dsn", String (TE.decodeUtf8 dsn))
    , ("parent", String parent)
    , ("parent_credential", String parentCredential)
    , ("workspace_key", String (TE.decodeLatin1 (Base16.encode key)))
    , ( "invocation"
      , Object
          [ ("activity", String inv.activity)
          , ("input", inv.input)
          , ("correlation", maybe Null String inv.correlation)
          , ("idempotency", maybe Null String inv.idempotency)
          ]
      )
    ]

-- | @--internal-spawn-worker@: execute @process.spawn@ requests from stdin,
-- one JSON object per line, answering @{"ok": outcome, "ensure_calls": n}@
-- or @{"error": message, "ensure_calls": n}@.
spawnWorker :: IO ()
spawnWorker = do
  hSetBuffering stdout LineBuffering
  let loop = do
        eof <- hIsEOF stdin
        unless eof $ do
          line <- BC.hGetLine stdin
          answer <- either (\e -> pure (Object [("error", String (T.pack e)), ("ensure_calls", Int 0)])) serve (parseJson pythonLoads line)
          BC.putStrLn (either (error . show) id (dumps compact answer))
          hFlush stdout
          loop
  loop
  where
    textAt key value = case lookupMember key value of
      Just (String s) -> s
      _ -> ""
    serve request = do
      let dsn = TE.encodeUtf8 (textAt "dsn" request)
          parent = textAt "parent" request
          credential = textAt "parent_credential" request
          key = either (const "") id (Base16.decode (TE.encodeUtf8 (textAt "workspace_key" request)))
          raw = maybe Null id (lookupMember "invocation" request)
          fields =
            ActivityInvocationFields
              { activity = textAt "activity" raw
              , input = maybe Null id (lookupMember "input" raw)
              , policy = defaultExecutionPolicy
              , correlation = case lookupMember "correlation" raw of Just (String s) -> Just s; _ -> Nothing
              , idempotency = case lookupMember "idempotency" raw of Just (String s) -> Just s; _ -> Nothing
              }
      counting <- countingProvisioner dsn credential key
      result <- try $ do
        inv <- either (throwIO . ValueError) pure (activityInvocation fields)
        Pg.withConnection dsn True $ \c -> do
          registry <- postgresSpawnRegistry c parent credential
          spawnActivity (spawnRegistry registry) counting.provisioner inv
      calls <- readIORef counting.ensureCalls
      pure $ case result of
        Right outcome -> Object [("ok", outcome), ("ensure_calls", Int (toInteger calls))]
        Left err -> Object [("error", String (pythonErrorLine err)), ("ensure_calls", Int (toInteger calls))]
    -- @f"{type(error).__name__}: {error}"@, as the reference's worker answers.
    pythonErrorLine err = let python = pythonException err in python.name <> ": " <> pythonExceptionStr python

-- | A running worker of some implementation, as a @process.spawn@ Activity.
data Worker = Worker {input :: Handle, output :: Handle, process :: ProcessHandle, lock :: MVar ()}

startWorker :: [String] -> IO Worker
startWorker command = case command of
  [] -> throwIO (userError "empty spawn-worker command")
  exe : arguments -> do
    (Just i, Just o, _, handle) <- createProcess (proc exe arguments) {std_in = CreatePipe, std_out = CreatePipe}
    hSetBuffering i LineBuffering
    Worker i o handle <$> newMVar ()

stopWorker :: Worker -> IO ()
stopWorker w = do
  _ <- try (hClose w.input) :: IO (Either SomeException ())
  timeout 5000000 (waitForProcess w.process) >>= \case
    Just _ -> pure ()
    Nothing -> terminateProcess w.process >> () <$ waitForProcess w.process

viaWorker :: Worker -> ByteString -> Text -> Text -> ByteString -> IORef Int -> ActivityInvocation -> IO Json
viaWorker w dsn parent credential key calls inv = withMVar w.lock $ \_ -> do
  BC.hPutStrLn w.input (either (error . show) id (dumps compact (workerRequest dsn parent credential key inv)))
  hFlush w.input
  line <- BC.hGetLine w.output
  answer <- either (throwIO . userError) pure (parseJson pythonLoads line)
  case lookupMember "ensure_calls" answer of
    Just (Int n) -> modifyIORef' calls (+ fromInteger n)
    _ -> pure ()
  case (lookupMember "ok" answer, lookupMember "error" answer) of
    (Just outcome, _) -> pure outcome
    (_, Just (String message)) -> throwIO (userError ("spawn worker: " <> T.unpack message))
    _ -> throwIO (userError ("spawn worker answered " <> BC.unpack line))

-- ---------------------------------------------------------------------------
-- The demo

-- | How the child host and the spawn Activity run: this executable by
-- default; either may be another implementation's.
data Commands = Commands {childCommand :: [String], spawnWorkerCommand :: Maybe [String]}

-- | @run_child(...)@.
runChild :: Commands -> ByteString -> Text -> Text -> Text -> Text -> IO ()
runChild commands dsn parent child credential outcome = do
  environment <- getEnvironment
  let overrides =
        [ ("IMPETUS_LIFECYCLE_DSN", BC.unpack dsn)
        , ("IMPETUS_LIFECYCLE_PARENT", T.unpack parent)
        , ("IMPETUS_LIFECYCLE_CHILD", T.unpack child)
        , ("IMPETUS_LIFECYCLE_CHILD_CREDENTIAL", T.unpack credential)
        , ("IMPETUS_LIFECYCLE_OUTCOME", T.unpack outcome)
        ]
      env' = overrides <> [kv | kv@(k, _) <- environment, k `notElem` map fst overrides]
  case commands.childCommand of
    [] -> throwIO (userError "empty child command")
    exe : arguments -> do
      result <- timeout 45000000 (readCreateProcessWithExitCode (proc exe arguments) {env = Just env'} "")
      case result of
        Just (ExitSuccess, _, _) -> pure ()
        Just (_, out, err) -> throwIO (userError ("RuntimeError: child process failed: " <> out <> "\n" <> err))
        Nothing -> throwIO (userError "TimeoutExpired: child process")

randomSuffix :: IO Text
randomSuffix = TE.decodeLatin1 . Base16.encode <$> (getRandomBytes 4 :: IO ByteString)

-- | @run_error_call(dsn, suffix)@.
runErrorCall :: Commands -> ByteString -> Text -> IO (Text, Text)
runErrorCall commands dsn suffix = do
  let parent = "error-parent-" <> suffix
      child = "error-child-" <> suffix
  parentCredential <- issueCredential
  childCredential' <- issueCredential
  bootstrap dsn [(parent, parentCredential), (child, childCredential')]
  Pg.withConnection dsn True $ \c -> do
    parentFabric <- postgresFabric c parent parentCredential
    childFabric <- postgresFabric c child childCredential'
    exposeSource parentFabric "reply"
    grant parentFabric child "reply"
    exposeSource childFabric "request"
    grant childFabric parent "request"
  placeholder <- orThrowIO (spawnSpec parent "unused" "call-only" "request" (Object []) (Object []) Nothing)
  let e = callEnvelope parent child
  send <- newSendActivity dsn parent parentCredential
  dispatcher <- newDemoDispatch (Map.fromList [("fabric.send", runSend send)]) Set.empty
  bracket (openParent dsn parent parentCredential placeholder e dispatcher send True False) closeAuthority $ \live -> do
    _ <- drive live
    statusOf live >>= \s -> expect (s == Awaiting) "the error caller awaits"
    runChild commands dsn parent child childCredential' "error"
    drained <- drainAuthority live
    expect (drained == 1) "the error reply was drained"
    _ <- drive live
    statusOf live >>= \s -> expect (s == Completed) "the error caller completed"
    marking <- Engine.marking live.engine
    case toList (placeTokens done marking) of
      t : _ -> expect (lookupMember "outcome" t.payload == Just (String "error")) "the outcome is error"
      [] -> expect False "a done token"
  pure (parent, child)

encodedRecords :: Engine -> IO Text
encodedRecords engine = do
  records <- Engine.records engine
  pure (T.concat [either (const "") TE.decodeUtf8 (dumps defaultDumps (encodeRecord r)) | r <- records])

-- | @run(dsn)@.
run :: Commands -> ByteString -> IO ()
run commands dsn = do
  suffix <- randomSuffix
  let parent = "lifecycle-parent-" <> suffix
  parentCredential <- issueCredential
  bootstrap dsn [(parent, parentCredential)]
  back <- orThrowIO (replyRoute parent "reply")
  spec <- orThrowIO (spawnSpec parent ("spawn-" <> suffix) "analysis-agent" "request" (Object [("protocol", String "call-v1")]) (Object [("role", String "agent")]) (Just back))
  let e = callEnvelope parent spec.child
  key <- getRandomBytes 32 :: IO ByteString
  counting <- countingProvisioner dsn parentCredential key
  bracket (Pg.connect dsn True) Pg.close $ \registryConnection -> do
    registry <- postgresSpawnRegistry registryConnection parent parentCredential
    worker <- traverse startWorker commands.spawnWorkerCommand
    flip finally (mapM_ stopWorker worker) $ do
      let spawn = case worker of
            Nothing -> spawnActivity (spawnRegistry registry) counting.provisioner
            Just w -> viaWorker w dsn parent parentCredential key counting.ensureCalls
          dispatcherWith send dropping = newDemoDispatch (Map.fromList [(spawnActivityName, spawn), ("fabric.send", runSend send)]) dropping
      -- The first host loses the spawn completion after the effect.
      firstSend <- newSendActivity dsn parent parentCredential
      firstDispatch <- dispatcherWith firstSend (Set.singleton spawnActivityName)
      bracket (openParent dsn parent parentCredential spec e firstDispatch firstSend True True) closeAuthority $ \first -> do
        _ <- drive first
        statusOf first >>= \s -> expect (s == Running) "the first host is running"
        Engine.inFlight first.engine >>= \flight -> expect (length flight == 1) "one firing in flight"
      historySize dsn spec.child >>= \n -> expect (n == 0) "the child History is empty"
      secondSend <- newSendActivity dsn parent parentCredential
      secondDispatch <- dispatcherWith secondSend Set.empty
      parentLive <- openParent dsn parent parentCredential spec e secondDispatch secondSend False True
      closed <- newIORef False
      let closeParent = do
            already <- atomicModifyIORef' closed (True,)
            unless already (closeAuthority parentLive)
      (claimCount, ensureCalls, pendingCount, spawnResults, replay, parentRecords, childRecords, childHistoryBefore) <- flip finally closeParent $ do
        _ <- drive parentLive
        statusOf parentLive >>= \s -> expect (s == Awaiting) "the parent awaits the call"
        let childCredential' = counting.childCredential spec.child
        (claimCount, registrations, pendingCount) <- Pg.withConnection dsn True $ \c -> do
          claims <- countOf c "SELECT count(*) FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s" [textParam parent, textParam spec.spawnId]
          regs <- countOf c "SELECT count(*) FROM impetus_fabric.processes WHERE instance_id = %s" [textParam spec.child]
          childFabric <- postgresFabric c spec.child childCredential'
          n <- length <$> pending childFabric 100
          pure (claims, regs, n)
        records <- Engine.records parentLive.engine
        let spawnResults = [r.result | RActivityCompleted r <- records, r.transition == spawnT]
        outcome <- case spawnResults of
          [r] -> orThrowIO (spawnOutcomeFromData r)
          other -> throwIO (userError ("AssertionError: spawn results " <> show (length other)))
        expect outcome.priorClaim "the recorded outcome is the prior claim"
        ensureCalls <- readIORef counting.ensureCalls
        expect ((claimCount, registrations, ensureCalls, pendingCount) == (1, 1, 2, 1)) ("claims, registrations, ensures, pending = " <> show (claimCount, registrations, ensureCalls, pendingCount))
        -- An unrelated reply is accepted and ignored.
        unrelatedRequest <- orThrowIO $ do
          r <- callRequest "unrelated" "noise" (Object [])
          requestEnvelope r parent spec.child "request" back Nothing
        unrelatedReply <- orThrowIO $ do
          r <- callResult "unrelated" (Object [("ignored", Bool True)])
          resultEnvelope r unrelatedRequest spec.child Nothing
        Pg.withConnection dsn True $ \c -> do
          childFabric <- postgresFabric c spec.child childCredential'
          () <$ submit childFabric unrelatedReply
        drainAuthority parentLive >>= \n -> expect (n == 1) "the unrelated reply was drained"
        _ <- drive parentLive
        statusOf parentLive >>= \s -> expect (s == Awaiting) "the parent still awaits"
        childHistoryBefore <- historySize dsn spec.child
        runChild commands dsn parent spec.child childCredential' "result"
        drainAuthority parentLive >>= \n -> expect (n == 1) "the result was drained"
        _ <- drive parentLive
        statusOf parentLive >>= \s -> expect (s == Completed) "the parent completed"
        parentBefore <- length <$> Engine.records parentLive.engine
        -- Replay: reopen both and drive; nothing is appended or dispatched.
        replaySend <- newSendActivity dsn parent parentCredential
        replayDispatch <- dispatcherWith replaySend Set.empty
        closeParent
        bracket (openParent dsn parent parentCredential spec e replayDispatch replaySend False True) closeAuthority $ \replayParent ->
          bracket (openChild dsn parent spec.child childCredential' "result" False) closeAuthority $ \childReplay -> do
            childBefore <- length <$> Engine.records childReplay.engine
            _ <- drive replayParent
            _ <- drive childReplay
            parentAfter <- length <$> Engine.records replayParent.engine
            childAfter <- length <$> Engine.records childReplay.engine
            parentDispatches <- readIORef replayDispatch.dispatches
            childDispatches <- readIORef childReplay.dispatcher.dispatches
            parentRecords <- encodedRecords replayParent.engine
            childRecords <- encodedRecords childReplay.engine
            pure
              ( claimCount
              , ensureCalls
              , pendingCount
              , spawnResults
              , (parentAfter - parentBefore, parentDispatches, childAfter - childBefore, childDispatches)
              , parentRecords
              , childRecords
              , childHistoryBefore
              )
      _ <- runErrorCall commands dsn suffix
      envelopes <- Pg.withConnection dsn True $ \c -> do
        rows <- Pg.query c "SELECT envelope::text FROM impetus_fabric.deliveries WHERE sender = ANY(%s)" [textArrayParam [parent, spec.child]]
        pure (T.concat [maybe "" TE.decodeUtf8 v | row <- rows, v <- row])
      let credential = counting.childCredential spec.child
          spawnText = T.concat [either (const "") TE.decodeUtf8 (dumps defaultDumps r) | r <- spawnResults]
          credentialAbsent = not (any (credential `T.isInfixOf`) [spawnText, envelopes, parentRecords, childRecords])
      expect (replay == (0, 0, 0, 0) && credentialAbsent) ("replay " <> show replay <> ", credential absent " <> show credentialAbsent)
      let say = TIO.putStrLn
      say ("spawn retry: claims=" <> tshow claimCount <> " ensure_calls=" <> tshow ensureCalls <> " prior_claim=true")
      say ("child history before host open: " <> tshow childHistoryBefore)
      say ("offline call: pending=" <> tshow pendingCount <> " parent=awaiting")
      say "unrelated correlation: parent=awaiting"
      say "correlated result: parent=completed child=completed"
      say "correlated error: parent=completed outcome=error"
      say "replay: parent appends=0 dispatches=0; child appends=0 dispatches=0"
      say ("credential absent from outcomes/envelopes/history: " <> (if credentialAbsent then "true" else "false"))
      say "overall: PASS"
      hFlush stdout
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show
    countOf c statement params =
      Pg.queryFirst c statement params >>= \case
        Just (Just v : _) -> pure (read (BC.unpack v) :: Int)
        _ -> pure 0

-- | The executable: @--dsn DSN@ runs the scenario; @--internal-child@ runs
-- the child host from the environment; @--internal-spawn-worker@ serves
-- @process.spawn@ on stdin; @--child-command@ and @--spawn-worker-command@
-- (each a JSON array of strings) substitute another implementation.
demoMain :: IO ()
demoMain = do
  arguments <- getArgs
  self <- getExecutablePath
  let flag name = lookup name (pairs arguments)
      commandOf name = case flag name of
        Nothing -> pure Nothing
        Just raw -> case parseJson pythonLoads (BC.pack raw) of
          Right (Array items) | Just strings <- mapM stringOf items, not (null strings) -> pure (Just strings)
          _ -> hPutStrLn stderr (name <> " takes a JSON array of strings") >> exitFailure
      stringOf = \case
        String s -> Just (T.unpack s)
        _ -> Nothing
  if
    | "--internal-child" `elem` arguments -> childSubprocess
    | "--internal-spawn-worker" `elem` arguments -> spawnWorker
    | otherwise -> case flag "--dsn" of
        Nothing -> do
          hPutStrLn stderr "cv5-lifecycle-demo: pass --dsn (this executable does not start a PostgreSQL container)"
          exitFailure
        Just dsn -> do
          child <- maybe [self, "--internal-child"] id <$> commandOf "--child-command"
          worker <- commandOf "--spawn-worker-command"
          result <- try (run (Commands child worker) (BC.pack dsn))
          case result of
            Right () -> pure ()
            Left (err :: SomeException) -> hPutStrLn stderr (show err) >> exitFailure
  where
    pairs (k : v : rest) = (k, v) : pairs (v : rest)
    pairs _ = []
