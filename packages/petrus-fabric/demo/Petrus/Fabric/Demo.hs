-- | The CV5 Fabric acceptance demo (upstream @scripts/cv5-fabric-demo.py@):
-- two Engines, a parent and a child, talking through Fabric, both split
-- across processes and co-located. The nets, handler names, envelopes,
-- Activity, environment variables, JSON events and printed lines are the
-- reference's, so either side of the split can be the reference's script
-- or this executable.
module Petrus.Fabric.Demo
  ( -- * Nets and handlers
    start
  , waiting
  , replies
  , done
  , sendT
  , replySource
  , joinT
  , requestSource
  , requests
  , respond
  , parentNet
  , childNet
  , requestEnvelope
  , handlersFor
  , engineOptions
    -- * Roles
  , SendActivity (..)
  , newSendActivity
  , sendActivityOf
  , LiveRole (..)
  , openRole
  , closeRole
  , drive
  , drainRole
  , invocations
  , custodyDroppingDispatch
  , bootstrap
  , historyTypes
  , replayInert
  , runLocal
  , runInFlightResume
    -- * The demo
  , RoleCommands (..)
  , run
  , subprocessRole
  , demoMain
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, finally, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import GHC.Clock (getMonotonicTime)
import Petrus.Cel.Impetus qualified as Cel
import Petrus.Engine (DriveOutcome (..), Engine, EngineOptions (..), defaultEngineOptions)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Postgres (createEngine, loadEngine)
import Petrus.Fabric
import Petrus.Fabric.Engine (engineInbox)
import Petrus.Fabric.Postgres
  ( PostgresFabric
  , discover
  , ensureFabricSchema
  , exposeSource
  , grant
  , inboxClient
  , issueCredential
  , offerService
  , pending
  , postgresFabric
  , registerProcess
  , submit
  )
import Petrus.Fabric.Send (asPythonFailure, sendActivity, sendInvocation)
import Petrus.HistoryStore.Postgres (ensureSchema, loadPostgresHistory)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult (..), handlerTokens)
import Petrus.Impetus.History.Records (DeliveryRegistration (..), recordName)
import Petrus.Impetus.Instance (ImplementationRef (..), Status (..), statusText)
import Petrus.Impetus.Instance.Firing (FiringOccurrence (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (Dispatch (..))
import Petrus.Motus.Dispatch.Inline (Activity, inlineDispatch, newInlineDispatch)
import Petrus.Postgres (Connection)
import Petrus.Postgres qualified as Pg
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (BufferMode (..), Handle, hFlush, hGetContents, hIsEOF, hPutStrLn, hSetBuffering, stderr, stdout)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
  )
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Nets

pathOf :: Text -> NetPath
pathOf = either (error . T.unpack) id . netPath

start, waiting, replies, done, sendT, replySource, joinT, requestSource, requests, respond :: NetPath
start = pathOf "start"
waiting = pathOf "waiting"
replies = pathOf "replies"
done = pathOf "done"
sendT = pathOf "send"
replySource = pathOf "reply"
joinT = pathOf "join"
requestSource = pathOf "request"
requests = pathOf "requests"
respond = pathOf "respond"

handled :: NetPath -> Text -> Transition
handled at symbol = (transition at) {handler = Just (HandlerSymbol symbol)}

colored :: NetPath -> NetPath -> Arc
colored from to = withArcColor (Just fabricEnvelopeColor) (arc from to)

completion :: Maybe CompletionDeclaration
completion = Just (CompletionCel (either (error . T.unpack) id (cel "size(done) != 0")))

parentNet :: Net
parentNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place [start, waiting, replies, done]
        , transitions = [handled sendT "send", handled replySource "reply", handled joinT "finish"]
        , arcs =
            [ arc start sendT
            , arc sendT waiting
            , colored replySource replies
            , arc waiting joinT
            , colored replies joinT
            , arc joinT done
            ]
        , completion
        , name = Nothing
        }

childNet :: Net
childNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place [requests, done]
        , transitions = [handled requestSource "request", handled respond "respond"]
        , arcs = [colored requestSource requests, arc requests respond, arc respond done]
        , completion
        , name = Nothing
        }

-- ---------------------------------------------------------------------------
-- Handlers

orFail :: Either FabricError a -> Either Text a
orFail = either (Left . errorMessage) Right

envelopeOf :: Token -> Either Text Envelope
envelopeOf t = orFail (envelopeFromData t.payload)

-- | @SendHandler(envelope, opens_reply=...)@.
sendHandler :: Envelope -> Bool -> BoundHandler
sendHandler e opensReply =
  ActivityBound
    ActivityHandler
      { prepare = \_ -> Right (sendInvocation e)
      , project = \_ result ->
          Right
            HandlerResult
              { tokens = if opensReply then [(waiting, [token "Waiting" result])] else [(done, [token "Done" result])]
              , opens = [DeliveryRegistration replySource e.correlation | opensReply]
              , closes = []
              }
      , projectFailure = Nothing
      }

single :: Binding -> Either Text Token
single binding = case bindingTokens binding of
  [t] -> Right t
  ts -> Left ("ValueError: too many values to unpack (expected 1, got " <> T.pack (show (length ts)) <> ")")

replyHandler :: BoundHandler
replyHandler = PureHandler $ \binding _ -> do
  t <- single binding
  e <- envelopeOf t
  Right (HandlerResult [(replies, [t])] [] [DeliveryRegistration replySource e.correlation])

finishHandler :: BoundHandler
finishHandler = PureHandler $ \binding _ -> do
  let ts = bindingTokens binding
  waitingToken <- maybe (Left "StopIteration") Right (lookupColor "Waiting" ts)
  replyToken <- maybe (Left "StopIteration") Right (lookupColor fabricEnvelopeColor ts)
  reply <- envelopeOf replyToken
  let expected = maybe Null id (lookupMember "correlation" waitingToken.payload)
  if String reply.correlation /= expected
    then Left ("reply correlation " <> pyRepr reply.correlation <> " does not answer the wait for " <> reprJson expected)
    else
      Right
        ( handlerTokens
            [ (done, [token "Done" (Object [("correlation", String reply.correlation), ("answer", maybe Null id (lookupMember "answer" reply.payload))])])
            ]
        )
  where
    lookupColor c = foldr (\t acc -> if t.color == Just c then Just t else acc) Nothing
    reprJson = \case
      String s -> pyRepr s
      other -> T.pack (show other)

requestHandler :: BoundHandler
requestHandler = PureHandler $ \binding _ -> do
  t <- single binding
  Right (HandlerResult [(requests, [t])] [] [DeliveryRegistration requestSource "default"])

-- | @ResponseHandler@: answer the request on its reply route.
responseHandler :: BoundHandler
responseHandler =
  ActivityBound
    ActivityHandler
      { prepare = \binding -> do
          first <- case bindingTokens binding of
            t : _ -> Right t
            [] -> Left "IndexError: tuple index out of range"
          request <- envelopeOf first
          replyTo <- maybe (Left "AssertionError") Right request.replyRoute
          reply <-
            orFail
              ( envelope
                  ("reply-" <> request.deliveryId)
                  request.recipient
                  replyTo.instanceId
                  replyTo.source
                  request.correlation
                  (Object [("answer", String "pong"), ("request", String request.deliveryId)])
                  Nothing
              )
          Right (sendInvocation reply)
      , project = \_ result -> Right (handlerTokens [(done, [token "Done" result])])
      , projectFailure = Nothing
      }

-- | @request_envelope(parent, child)@.
requestEnvelope :: Text -> Text -> Envelope
requestEnvelope parent child =
  either (error . T.unpack . errorMessage) id $ do
    back <- replyRoute parent "reply"
    envelope ("request-" <> parent) parent child "request" ("correlation-" <> parent) (Object [("question", String "ping")]) (Just back)

-- | @handlers(role, parent, child)@.
handlersFor :: Text -> Text -> Text -> Map.Map ImplementationRef BoundHandler
handlersFor role parent child
  | role == "parent" =
      Map.fromList
        [ (Symbol "send", sendHandler (requestEnvelope parent child) True)
        , (Symbol "reply", replyHandler)
        , (Symbol "finish", finishHandler)
        ]
  | otherwise = Map.fromList [(Symbol "request", requestHandler), (Symbol "respond", responseHandler)]

engineOptions :: Map.Map ImplementationRef BoundHandler -> EngineOptions
engineOptions hs = defaultEngineOptions {handlers = hs, celCompilers = Cel.celCompilers}

-- ---------------------------------------------------------------------------
-- The fabric.send Activity

-- | @SendActivity(dsn, instance, credential)@: its own autocommit
-- connection, a client bound to the sender, and an invocation count.
data SendActivity = SendActivity {connection :: Connection, client :: PostgresFabric, count :: IORef Int}

newSendActivity :: ByteString -> Text -> Text -> IO SendActivity
newSendActivity dsn authority credential = do
  c <- Pg.connect dsn True
  f <- postgresFabric c authority credential `onException` Pg.close c
  SendActivity c f <$> newIORef 0

-- | The Activity an inline Dispatch runs: the idempotency check, then the
-- count, then the submit (the reference's order).
sendActivityOf :: SendActivity -> Activity
sendActivityOf a inv _ =
  asPythonFailure (sendActivity (\e -> atomicModifyIORef' a.count (\n -> (n + 1, ())) >> submit a.client e) inv)

-- ---------------------------------------------------------------------------
-- Roles

data LiveRole = LiveRole
  { engine :: Engine
  , fabricConnection :: Connection
  , fabricClient :: PostgresFabric
  , inbox :: FabricInbox
  , activity :: SendActivity
  }

invocations :: LiveRole -> IO Int
invocations live = readIORef live.activity.count

-- | @open_role(...)@: load the role's Engine on its own joined connection
-- and wire its Fabric inbox.
openRole :: ByteString -> Text -> Text -> Text -> Text -> Text -> Maybe Dispatch -> IO LiveRole
openRole dsn role authority parent child credential dispatch = do
  activity <- newSendActivity dsn authority credential
  let closeActivity = Pg.close activity.connection
  flip onException closeActivity $ do
    port <- maybe (inlineDispatch <$> newInlineDispatch (Map.fromList [("fabric.send", sendActivityOf activity)])) pure dispatch
    connection <- Pg.connect dsn False
    engine <-
      loadEngine connection (if role == "parent" then parentNet else childNet) authority port (engineOptions (handlersFor role parent child))
    flip onException (Engine.close engine) $ do
      fabricConnection <- Pg.connect dsn True
      fabricClient <- postgresFabric fabricConnection authority credential `onException` Pg.close fabricConnection
      pure (LiveRole engine fabricConnection fabricClient (engineInbox (inboxClient fabricClient) engine) activity)

closeRole :: LiveRole -> IO ()
closeRole live = do
  Engine.close live.engine
  Pg.close live.fabricConnection
  Pg.close live.activity.connection

-- | @LiveRole.drive()@: advance until the Engine is not ready.
drive :: LiveRole -> IO DriveOutcome
drive live = go []
  where
    go acc = do
      outcome <- Engine.advance live.engine
      let acc' = acc <> outcome.firings
      if outcome.ready then go acc' else pure (DriveOutcome acc' outcome.waiting False outcome.nextMaturation)

drainRole :: LiveRole -> IO Int
drainRole live = length <$> drain live.inbox 100

-- | @CustodyDroppingDispatch@: acknowledge custody and never perform it.
custodyDroppingDispatch :: Dispatch
custodyDroppingDispatch = Dispatch {dispatch = \_ _ -> pure (), collect = pure [], cancel = Nothing}

-- | @bootstrap(dsn, parent, child, credentials)@.
bootstrap :: ByteString -> Text -> Text -> (Text -> Text) -> IO ()
bootstrap dsn parent child credentials = do
  Pg.withConnection dsn True $ \control -> do
    ensureSchema control
    ensureFabricSchema control
    forM_ [parent, child] $ \a -> registerProcess control a (credentials a)
    parentFabric <- postgresFabric control parent (credentials parent)
    childFabric <- postgresFabric control child (credentials child)
    exposeSource parentFabric "reply"
    exposeSource childFabric "request"
    offerService parentFabric "reply" "fabric.reply" (Object [("version", Int 1)])
    offerService childFabric "request" "fabric.request" (Object [("version", Int 1)])
    grant parentFabric child "reply"
    grant childFabric parent "request"
  empty <- inlineDispatch <$> newInlineDispatch Map.empty
  parentConnection <- Pg.connect dsn False
  parentEngine <-
    createEngine
      parentConnection
      parentNet
      parent
      empty
      (engineOptions (handlersFor "parent" parent child)) {marking = markingFromList [(start, [token "Start" (Object [("command", String "begin")])])]}
  Engine.seal parentEngine replySource `finally` Engine.close parentEngine
  childConnection <- Pg.connect dsn False
  childEngine <- createEngine childConnection childNet child empty (engineOptions (handlersFor "child" parent child))
  Engine.close childEngine

-- | @history_types(dsn, instance)@: the record class names, in order.
historyTypes :: ByteString -> Text -> IO [Text]
historyTypes dsn instanceId = Pg.withConnection dsn True $ \c -> map recordName . toList <$> loadPostgresHistory c instanceId

expect :: Bool -> String -> IO ()
expect condition what = unless condition (throwIO (userError ("AssertionError: " <> what)))

statusOf :: LiveRole -> IO Status
statusOf live = Engine.status live.engine

-- | @replay_inert(...)@: reopen a completed role and drive it; answers
-- (appended records, Activity invocations).
replayInert :: ByteString -> Text -> Text -> Text -> Text -> Text -> IO (Int, Int)
replayInert dsn role authority parent child credential =
  bracket (openRole dsn role authority parent child credential Nothing) closeRole $ \live -> do
    before <- length <$> Engine.records live.engine
    _ <- drive live
    statusOf live >>= \s -> expect (s == Completed) "replayed role is completed"
    after <- length <$> Engine.records live.engine
    (after - before,) <$> invocations live

-- | @run_local(...)@: both roles in this process.
runLocal :: ByteString -> Text -> Text -> (Text -> Text) -> IO ()
runLocal dsn parent child credentials = do
  bootstrap dsn parent child credentials
  bracket (openRole dsn "parent" parent parent child (credentials parent) Nothing) closeRole $ \parentRole ->
    bracket (openRole dsn "child" child parent child (credentials child) Nothing) closeRole $ \childRole -> do
      _ <- drive parentRole
      statusOf parentRole >>= \s -> expect (s == Awaiting) "parent awaiting"
      _ <- drainRole childRole
      _ <- drive childRole
      _ <- drainRole parentRole
      _ <- drive parentRole
      ps <- statusOf parentRole
      cs <- statusOf childRole
      expect (ps == Completed && cs == Completed) "both roles completed"

-- | @run_in_flight_resume(...)@: lose every child live object after
-- ActivityRequested, then finish from History alone.
runInFlightResume :: ByteString -> Text -> Text -> (Text -> Text) -> IO Int
runInFlightResume dsn parent child credentials = do
  bootstrap dsn parent child credentials
  bracket (openRole dsn "parent" parent parent child (credentials parent) Nothing) closeRole $ \parentRole -> do
    _ <- drive parentRole
    statusOf parentRole >>= \s -> expect (s == Awaiting) "parent awaiting"
    occurrence <-
      bracket (openRole dsn "child" child parent child (credentials child) (Just custodyDroppingDispatch)) closeRole $ \childRole -> do
        drained <- drainRole childRole
        expect (drained == 1) "child drained one delivery"
        outcome <- drive childRole
        expect outcome.waiting "child waits on its Activity"
        invocations childRole >>= \n -> expect (n == 0) "no invocation before the crash"
        Engine.inFlight childRole.engine >>= \case
          [o] -> do
            expect (o.binding.transition == respond) "the in-flight firing is respond"
            pure o.occurrence
          other -> throwIO (userError ("AssertionError: in flight " <> show (length other)))
    -- The crash boundary: every object derived over the child History is
    -- gone; reopen from History alone.
    bracket (openRole dsn "child" child parent child (credentials child) Nothing) closeRole $ \resumed -> do
      flight <- Engine.inFlight resumed.engine
      expect (map (.occurrence) flight == [occurrence]) "the same occurrence is in flight"
      expect (map (.binding.transition) flight == [respond]) "the resumed firing is respond"
      _ <- drive resumed
      _ <- drainRole parentRole
      _ <- drive parentRole
      rs <- statusOf resumed
      ps <- statusOf parentRole
      expect (rs == Completed && ps == Completed) "both roles completed"
      invocations resumed >>= \n -> expect (n == 1) "exactly one dispatch"
    pure occurrence

-- ---------------------------------------------------------------------------
-- Subprocess roles

emit :: [(Text, Json)] -> IO ()
emit members = do
  BC.putStrLn (either (error . show) id (dumps defaultDumps {sortKeys = True} (Object members)))
  hFlush stdout

-- | @subprocess_role()@: one role, configured by @IMPETUS_DEMO_*@.
subprocessRole :: IO ()
subprocessRole = do
  dsn <- BC.pack <$> getEnv "IMPETUS_DEMO_DSN"
  role <- T.pack <$> getEnv "IMPETUS_DEMO_ROLE"
  parent <- T.pack <$> getEnv "IMPETUS_DEMO_PARENT"
  child <- T.pack <$> getEnv "IMPETUS_DEMO_CHILD"
  credential <- T.pack <$> getEnv "IMPETUS_DEMO_CREDENTIAL"
  let authority = if role == "parent" then parent else child
  bracket (openRole dsn role authority parent child credential Nothing) closeRole $ \live -> do
    when (role == "parent") $ do
      _ <- drive live
      s <- statusOf live
      expect (s == Awaiting) "parent awaiting"
      emit [("event", String "parent_waiting"), ("status", String (statusText s))]
    deadline <- (+ 30) <$> getMonotonicTime
    let loop = do
          s <- statusOf live
          unless (s == Completed) $ do
            _ <- drainRole live
            _ <- drive live
            now <- getMonotonicTime
            when (now > deadline) (throwIO (userError ("TimeoutError: " <> T.unpack role <> " did not complete")))
            threadDelay 50000
            loop
    loop
    history <- length <$> Engine.records live.engine
    n <- invocations live
    emit [("event", String "role_completed"), ("role", String role), ("history", Int (toInteger history)), ("invocations", Int (toInteger n))]

-- | The commands that run each split role: by default this executable with
-- @--internal-role@; either may be another implementation's role entry
-- point (the reference's script, for one).
data RoleCommands = RoleCommands {parentCommand :: [String], childCommand :: [String]}

data RunningRole = RunningRole {process :: ProcessHandle, out :: Handle, errors :: MVar String}

startRole :: RoleCommands -> ByteString -> Text -> Text -> Text -> Text -> IO RunningRole
startRole commands dsn role parent child credential = do
  environment <- getEnvironment
  let command = if role == "parent" then commands.parentCommand else commands.childCommand
      overrides =
        [ ("IMPETUS_DEMO_DSN", BC.unpack dsn)
        , ("IMPETUS_DEMO_ROLE", T.unpack role)
        , ("IMPETUS_DEMO_PARENT", T.unpack parent)
        , ("IMPETUS_DEMO_CHILD", T.unpack child)
        , ("IMPETUS_DEMO_CREDENTIAL", T.unpack credential)
        ]
      env' = overrides <> [kv | kv@(k, _) <- environment, k `notElem` map fst overrides]
  case command of
    [] -> throwIO (userError "empty role command")
    exe : arguments -> do
      (_, Just o, Just e, handle) <- createProcess (proc exe arguments) {env = Just env', std_out = CreatePipe, std_err = CreatePipe}
      hSetBuffering o LineBuffering
      errs <- newEmptyMVar
      _ <- forkIO (hGetContents e >>= \s -> length s `seq` putMVar errs s)
      pure (RunningRole handle o errs)

-- | @wait_event(process, wanted)@.
waitEvent :: RunningRole -> Text -> IO Json
waitEvent running wanted = do
  seen <- newIORef []
  let loop = do
        eof <- hIsEOF running.out
        if eof
          then pure Nothing
          else do
            line <- BC.hGetLine running.out
            modifyIORef' seen (line :)
            case parseJson pythonLoads line of
              Right event | lookupMember "event" event == Just (String wanted) -> pure (Just event)
              _ -> loop
  found <- timeout 35000000 loop
  case found of
    Just (Just event) -> pure event
    _ -> do
      code <- getProcessExitCode running.process
      lines' <- reverse <$> readIORef seen
      errs <- maybe "" id <$> timeout 2000000 (readMVar running.errors)
      throwIO
        ( userError
            ( "subprocess failed waiting for "
                <> T.unpack wanted
                <> "; rc="
                <> show code
                <> " stdout="
                <> show lines'
                <> " stderr="
                <> errs
            )
        )

finishRole :: RunningRole -> IO ExitCode
finishRole running =
  timeout 5000000 (waitForProcess running.process) >>= \case
    Just code -> pure code
    Nothing -> terminateProcess running.process >> waitForProcess running.process

randomSuffix :: IO Text
randomSuffix = TE.decodeLatin1 . Base16.encode <$> (getRandomBytes 4 :: IO ByteString)

intOf :: Text -> Json -> Integer
intOf key value = case lookupMember key value of
  Just (Int n) -> n
  _ -> 0

textOf :: Text -> Json -> Text
textOf key value = case lookupMember key value of
  Just (String s) -> s
  _ -> ""

lower :: Bool -> Text
lower b = if b then "true" else "false"

credentialsFor :: [Text] -> IO (Text -> Text)
credentialsFor names = do
  pairs <- mapM (\n -> (n,) <$> issueCredential) names
  let table = Map.fromList pairs
  pure (\n -> Map.findWithDefault "" n table)

-- | @run(dsn)@: the whole acceptance scenario; prints the reference's lines.
run :: RoleCommands -> ByteString -> IO ()
run commands dsn = do
  suffix <- randomSuffix
  let splitParent = "split-parent-" <> suffix
      splitChild = "split-child-" <> suffix
  splitCredentials <- credentialsFor [splitParent, splitChild]
  bootstrap dsn splitParent splitChild splitCredentials
  discovered <- Pg.withConnection dsn True $ \c -> do
    f <- postgresFabric c splitParent (splitCredentials splitParent)
    discover f "fabric.request" (Just (Object [("version", Int 1)]))
  first <- case discovered of
    [d] -> pure d
    other -> throwIO (userError ("AssertionError: discovered " <> show (length other)))
  expect ((first.recipient, first.source) == (splitChild, "request")) "discovery finds the child's request source"
  parentProcess <- startRole commands dsn "parent" splitParent splitChild (splitCredentials splitParent)
  let stopping action = action `onException` terminateProcess parentProcess.process
  stopping $ do
    waitingEvent <- waitEvent parentProcess "parent_waiting"
    offlinePending <- Pg.withConnection dsn True $ \c -> do
      f <- postgresFabric c splitChild (splitCredentials splitChild)
      length <$> pending f 100
    expect (offlinePending == 1) "one pending request while the child is offline"
    childProcess <- startRole commands dsn "child" splitParent splitChild (splitCredentials splitChild)
    (childDone, parentDone) <- flip onException (terminateProcess childProcess.process) $ do
      childDone <- waitEvent childProcess "role_completed"
      parentDone <- waitEvent parentProcess "role_completed"
      childCode <- finishRole childProcess
      parentCode <- finishRole parentProcess
      expect (childCode == ExitSuccess && parentCode == ExitSuccess) "both role processes exit 0"
      pure (childDone, parentDone)
    duplicate <- Pg.withConnection dsn True $ \c -> do
      f <- postgresFabric c splitParent (splitCredentials splitParent)
      submit f (requestEnvelope splitParent splitChild)
    expect (duplicate.state == Accepted && duplicate.duplicate && duplicate.occurrence /= Nothing) "the duplicate request reports its acceptance"
    parentReplay <- replayInert dsn "parent" splitParent splitParent splitChild (splitCredentials splitParent)
    childReplay <- replayInert dsn "child" splitChild splitParent splitChild (splitCredentials splitChild)
    let crashParent = "crash-parent-" <> suffix
        crashChild = "crash-child-" <> suffix
    crashCredentials <- credentialsFor [crashParent, crashChild]
    resumedOccurrence <- runInFlightResume dsn crashParent crashChild crashCredentials
    let localParent = "local-parent-" <> suffix
        localChild = "local-child-" <> suffix
    localCredentials <- credentialsFor [localParent, localChild]
    runLocal dsn localParent localChild localCredentials
    shapes <- mapM (historyTypes dsn) [splitParent, localParent, splitChild, localChild]
    let shapeEqual = case shapes of
          [sp, lp, sc, lc] -> sp == lp && sc == lc
          _ -> False
    expect (shapeEqual && parentReplay == (0, 0) && childReplay == (0, 0)) "shapes equal and replay inert"
    let say = TIO.putStrLn
    say
      ( "authorities: parent="
          <> splitParent
          <> " history="
          <> tshow (intOf "history" parentDone)
          <> "; child="
          <> splitChild
          <> " history="
          <> tshow (intOf "history" childDone)
      )
    say ("parent: " <> textOf "status" waitingEvent <> " -> completed; child: completed")
    say ("discovery: " <> first.recipient <> "/" <> first.source <> " authorized")
    say ("offline pending count: " <> tshow offlinePending)
    say ("duplicate: accepted/" <> lower duplicate.duplicate <> " occurrence=" <> maybe "None" tshow duplicate.occurrence)
    say ("local/split semantic-shape equality: " <> lower shapeEqual)
    say
      ( "replay: parent appends="
          <> tshow (fst parentReplay)
          <> " invocations="
          <> tshow (snd parentReplay)
          <> "; child appends="
          <> tshow (fst childReplay)
          <> " invocations="
          <> tshow (snd childReplay)
      )
    say ("in-flight crash resume: occurrence=" <> tshow resumedOccurrence <> " dispatches=1 completed=true")
    say "overall: PASS"
    hFlush stdout
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

-- | The executable: @--dsn DSN@ runs the scenario; @--internal-role@ runs one
-- role from the environment; @--parent-command@ / @--child-command@ (each a
-- JSON array of strings) replace the split roles' command.
demoMain :: IO ()
demoMain = do
  arguments <- getArgs
  self <- getExecutablePath
  let flag name = lookup name (pairs arguments)
      commandOf name = case flag name of
        Nothing -> pure [self, "--internal-role"]
        Just raw -> case parseJson pythonLoads (BC.pack raw) of
          Right (Array items) | Just strings <- mapM stringOf items, not (null strings) -> pure strings
          _ -> hPutStrLn stderr (name <> " takes a JSON array of strings") >> exitFailure
      stringOf = \case
        String s -> Just (T.unpack s)
        _ -> Nothing
  if "--internal-role" `elem` arguments
    then subprocessRole
    else case flag "--dsn" of
      Nothing -> do
        hPutStrLn stderr "cv5-fabric-demo: pass --dsn (this executable does not start a PostgreSQL container)"
        exitFailure
      Just dsn -> do
        commands <- RoleCommands <$> commandOf "--parent-command" <*> commandOf "--child-command"
        result <- try (run commands (BC.pack dsn))
        case result of
          Right () -> pure ()
          Left (err :: SomeException) -> hPutStrLn stderr (show err) >> exitFailure
  where
    pairs (k : v : rest) = (k, v) : pairs (v : rest)
    pairs _ = []
