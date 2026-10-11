-- | The durable Local host and Thread projection for the Net-owned agent
-- loop (@petrus.agenticus.runtime.agent_net_runner@).
--
-- The runner schedules nothing itself: Engine History alone orders the
-- loop. The runner projects each committed fact into Thread accounting
-- exactly once. Each fact is a model-phase append, a Hands result, a
-- terminal, an Activity failure, or an Activity found in flight after a
-- reload. Each projection goes through a compare-and-save repository, and
-- the Episode Attachment is settled before the Thread records the outcome.
module Petrus.Agenticus.Runtime.AgentNetRunner
  ( -- * Projection values
    HaltCode (..)
  , haltCodeText
  , ProjectedAppend (occurrence, outputReference, continuationReference)
  , mkProjectedAppend
  , projectedAppendToData
  , projectedAppendFromData
  , ProjectedHands (occurrence, callId)
  , mkProjectedHands
  , projectedHandsToData
  , projectedHandsFromData
  , AgentNetAttachmentFence (episodeId, attachmentId, attachmentEpoch, grantEpoch)
  , mkAgentNetAttachmentFence
  , attachmentFenceToData
  , attachmentFenceFromData
  , AgentNetHalt (code, activity, occurrence)
  , mkAgentNetHalt
  , haltToData
  , haltFromData
  , AgentNetThreadProjection (instanceId, initial, thread, attachment, appends, hands, terminal, halt)
  , mkAgentNetThreadProjection
  , projectionSettled
  , projectionToData
  , projectionFromData
    -- * Thread repositories
  , AgentNetThreadRepository (..)
  , jsonThreadRepository
  , runnerThreadRepository
    -- * The Hands Activity
  , agentNetHandsActivity
    -- * The runner
  , AgentNetRunner
  , createRunner
  , createRunnerWith
  , loadRunner
  , loadRunnerWith
  , runnerEngine
  , runnerHistory
  , runnerProjection
  , runnerThread
  , runnerSettled
  , advance
  , drain
  , closeRunner
  ) where

import Control.Exception (IOException, SomeException, catch, finally, fromException, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Foldable (toList)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Attachment.Binding (AttachmentCoordinates (..), BindingSettlement (..))
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorIdentity (..))
import Petrus.Agenticus.Catalog.Resolution (snapshotDescriptor)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolResult (..), capabilityScopedHands, toolMethodText, toolResultToModelData)
import Petrus.Agenticus.Internal.Exception
import Petrus.Json.Python (pythonRepr, pythonStrListRepr)
import Petrus.Agenticus.Hands.Gateway (HandsAdapter, HandsGateway, submit)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), currentGrant)
import Petrus.Agenticus.Program.AgentNet
  ( LoopState (..)
  , ModelResult (..)
  , ModelSettlement (..)
  , Proposal (..)
  , Terminal (..)
  , TerminalCode (..)
  , agentAsNetContinuationDescriptor
  , agentAsNetProgram
  , agentNet
  , agentNetOptions
  , done
  , handsActivity
  , initialMarking
  , loopStateFromData
  , loopStateToData
  , modelPhaseActivity
  , modelResultFromData
  , modelResultFromModelData
  , modelResultToData
  , modelSettlementFromData
  , proposalFromData
  , terminalFromData
  , terminalToData
  )
import Petrus.Agenticus.Runtime.Profiles (TerritoryProfile (..), agentAsNetA5Local, territoryIdentity)
import Petrus.Agenticus.Thread.Continuation (Continuation (..), ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (lifecycleIdText, mkContinuationId, mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle
  ( Episode (..)
  , EpisodeOutcome (..)
  , Thread (..)
  , ThreadCancellation (..)
  , ThreadSettlement (..)
  , Turn (..)
  , TurnOutcome (..)
  , acceptAppend
  , episodeBudget
  , requestCancellation
  , settleEpisode
  , settleTurn
  , startEpisode
  , startTurn
  , threadFromData
  , threadToData
  )
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..))
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityFailed (..), ActivityRequested (..), Record (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance.Firing (FiringOccurrence (..))
import Petrus.Impetus.Petrinet (Token (..))
import Petrus.Impetus.Petrinet.Marking (placeTokens)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Dispatch.Inline (Activity, inlineDispatch, newInlineDispatch)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.IO qualified as PIO
import System.Posix.IO.ByteString qualified as PIOB
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

schemaVersion :: Integer
schemaVersion = 1

threadFile, historyFile :: FilePath
threadFile = "thread.json"
historyFile = "history.jsonl"

runnerError :: Text -> IO a
runnerError = throwAgenticus AgentNetRunnerError

orThrow :: Either AgenticusError a -> IO a
orThrow = either throwIO pure

-- ---------------------------------------------------------------------------
-- Shared validation

-- | @_exact@: an object with exactly these string keys.
exact :: [Text] -> Text -> Json -> Either AgenticusError [(Text, Json)]
exact fields label = \case
  Object members | sort (map fst members) == sort fields && length members == length fields -> Right members
  _ -> Left (valueError (label <> " requires exact fields " <> pythonStrListRepr (sort fields)))

field :: Text -> [(Text, Json)] -> Json
field key members = maybe Null id (lookup key members)

-- | @_positive@: a positive integer (never a boolean).
positive :: Text -> Json -> Either AgenticusError Integer
positive label = \case
  Int n | n > 0 -> Right n
  _ -> Left (valueError (label <> " must be a positive integer"))

positiveInt :: Text -> Integer -> Either AgenticusError Integer
positiveInt label n
  | n > 0 = Right n
  | otherwise = Left (valueError (label <> " must be a positive integer"))

-- | @_activity@: only the two Agent-as-a-Net Activities.
activityName :: Json -> Either AgenticusError Text
activityName = \case
  String a | a `elem` [modelPhaseActivity, handsActivity] -> Right a
  _ -> Left (valueError "Agent-as-a-Net halt activity is unsupported")

utf8Bytes :: Text -> Int
utf8Bytes = B.length . TE.encodeUtf8

-- | A string field read as the reference's @cast(str, ...)@ followed by the
-- constructor's own check: a non-string fails that check.
stringOr :: Json -> Either AgenticusError Text -> Either AgenticusError Text
stringOr value failure = case value of
  String t -> Right t
  _ -> failure

-- ---------------------------------------------------------------------------
-- Halt codes

data HaltCode = Indeterminate | ActivityFailedHalt
  deriving stock (Eq, Ord, Show, Enum, Bounded)

haltCodeText :: HaltCode -> Text
haltCodeText = \case
  Indeterminate -> "indeterminate"
  ActivityFailedHalt -> "activity-failed"

parseHaltCode :: Json -> Either AgenticusError HaltCode
parseHaltCode value = case [c | c <- [minBound .. maxBound], String (haltCodeText c) == value] of
  c : _ -> Right c
  [] -> Left (valueError (pythonRepr value <> " is not a valid HaltCode"))

-- ---------------------------------------------------------------------------
-- Projected appends

-- | One committed model-phase append projected into Thread accounting.
data ProjectedAppend = ProjectedAppend
  { occurrence :: Integer
  , outputReference :: Text
  , continuationReference :: Text
  }
  deriving stock (Eq, Show)

mkProjectedAppend :: Integer -> Text -> Text -> Either AgenticusError ProjectedAppend
mkProjectedAppend o out cont = do
  _ <- positiveInt "projected append occurrence" o
  forM_ [("output_reference", out), ("continuation_reference", cont)] $ \(name, value) ->
    when (T.null value || utf8Bytes value > 512) $
      Left (valueError ("projected append " <> name <> " must be a bounded non-empty reference"))
  pure (ProjectedAppend o out cont)

projectedAppendToData :: ProjectedAppend -> Json
projectedAppendToData p =
  Object
    [ ("occurrence", Int p.occurrence)
    , ("output_reference", String p.outputReference)
    , ("continuation_reference", String p.continuationReference)
    ]

projectedAppendFromData :: Json -> Either AgenticusError ProjectedAppend
projectedAppendFromData raw = do
  value <- exact ["occurrence", "output_reference", "continuation_reference"] "projected append" raw
  o <- positive "projected append occurrence" (field "occurrence" value)
  out <- stringOr (field "output_reference" value) (Left (valueError "projected append output_reference must be a bounded non-empty reference"))
  cont <-
    stringOr
      (field "continuation_reference" value)
      (Left (valueError "projected append continuation_reference must be a bounded non-empty reference"))
  mkProjectedAppend o out cont

-- ---------------------------------------------------------------------------
-- Projected Hands results

-- | One committed Hands result observed by the Thread projector.
data ProjectedHands = ProjectedHands
  { occurrence :: Integer
  , callId :: Text
  }
  deriving stock (Eq, Show)

mkProjectedHands :: Integer -> Text -> Either AgenticusError ProjectedHands
mkProjectedHands o c = do
  _ <- positiveInt "projected Hands occurrence" o
  when (T.null c || utf8Bytes c > 256) $ Left (valueError "projected Hands call_id must be bounded non-empty text")
  pure (ProjectedHands o c)

projectedHandsToData :: ProjectedHands -> Json
projectedHandsToData p = Object [("occurrence", Int p.occurrence), ("call_id", String p.callId)]

projectedHandsFromData :: Json -> Either AgenticusError ProjectedHands
projectedHandsFromData raw = do
  value <- exact ["occurrence", "call_id"] "projected Hands result" raw
  o <- positive "projected Hands occurrence" (field "occurrence" value)
  c <- stringOr (field "call_id" value) (Left (valueError "projected Hands call_id must be bounded non-empty text"))
  mkProjectedHands o c

-- ---------------------------------------------------------------------------
-- Attachment fences

-- | The exact host-only Attachment coordinates expected across
-- reconstruction.
data AgentNetAttachmentFence = AgentNetAttachmentFence
  { episodeId :: Text
  , attachmentId :: Text
  , attachmentEpoch :: Integer
  , grantEpoch :: Integer
  }
  deriving stock (Eq, Show)

mkAgentNetAttachmentFence :: Text -> Text -> Integer -> Integer -> Either AgenticusError AgentNetAttachmentFence
mkAgentNetAttachmentFence e a ae ge = do
  forM_ [("episode_id", e), ("attachment_id", a)] $ \(name, value) ->
    when (T.null value || utf8Bytes value > 256) $
      Left (valueError ("Agent-as-a-Net " <> name <> " must be bounded non-empty text"))
  _ <- positiveInt "Agent-as-a-Net attachment_epoch" ae
  _ <- positiveInt "Agent-as-a-Net grant_epoch" ge
  pure (AgentNetAttachmentFence e a ae ge)

attachmentFenceToData :: AgentNetAttachmentFence -> Json
attachmentFenceToData f =
  Object
    [ ("episode_id", String f.episodeId)
    , ("attachment_id", String f.attachmentId)
    , ("attachment_epoch", Int f.attachmentEpoch)
    , ("grant_epoch", Int f.grantEpoch)
    ]

attachmentFenceFromData :: Json -> Either AgenticusError AgentNetAttachmentFence
attachmentFenceFromData raw = do
  value <- exact ["episode_id", "attachment_id", "attachment_epoch", "grant_epoch"] "Agent-as-a-Net Attachment fence" raw
  -- Arguments evaluate in order: the two epochs are checked before the
  -- constructor checks the strings.
  ae <- positive "Agent-as-a-Net attachment_epoch" (field "attachment_epoch" value)
  ge <- positive "Agent-as-a-Net grant_epoch" (field "grant_epoch" value)
  e <- stringOr (field "episode_id" value) (Left (valueError "Agent-as-a-Net episode_id must be bounded non-empty text"))
  a <- stringOr (field "attachment_id" value) (Left (valueError "Agent-as-a-Net attachment_id must be bounded non-empty text"))
  mkAgentNetAttachmentFence e a ae ge

-- ---------------------------------------------------------------------------
-- Halts

data AgentNetHalt = AgentNetHalt
  { code :: HaltCode
  , activity :: Text
  , occurrence :: Integer
  }
  deriving stock (Eq, Show)

mkAgentNetHalt :: HaltCode -> Text -> Integer -> Either AgenticusError AgentNetHalt
mkAgentNetHalt c a o = AgentNetHalt c <$> activityName (String a) <*> positiveInt "halt occurrence" o

haltToData :: AgentNetHalt -> Json
haltToData h = Object [("code", String (haltCodeText h.code)), ("activity", String h.activity), ("occurrence", Int h.occurrence)]

haltFromData :: Json -> Either AgenticusError AgentNetHalt
haltFromData raw = do
  value <- exact ["code", "activity", "occurrence"] "Agent-as-a-Net halt" raw
  AgentNetHalt
    <$> parseHaltCode (field "code" value)
    <*> activityName (field "activity" value)
    <*> positive "halt occurrence" (field "occurrence" value)

-- ---------------------------------------------------------------------------
-- The projection

-- | The durable Thread authority plus its idempotent History projection
-- cursor.
data AgentNetThreadProjection = AgentNetThreadProjection
  { instanceId :: Text
  , initial :: LoopState
  , thread :: Thread
  , attachment :: AgentNetAttachmentFence
  , appends :: [ProjectedAppend]
  , hands :: [ProjectedHands]
  , terminal :: Maybe Terminal
  , halt :: Maybe AgentNetHalt
  }
  deriving stock (Eq, Show)

mkAgentNetThreadProjection
  :: Text
  -> LoopState
  -> Thread
  -> AgentNetAttachmentFence
  -> [ProjectedAppend]
  -> [ProjectedHands]
  -> Maybe Terminal
  -> Maybe AgentNetHalt
  -> Either AgenticusError AgentNetThreadProjection
mkAgentNetThreadProjection i ini t a ap hs term h = do
  when (T.null i || utf8Bytes i > 256) $ Left (valueError "Agent-as-a-Net instance_id must be bounded non-empty text")
  when (a.episodeId /= ini.episodeId || a.grantEpoch /= ini.grantEpoch) $
    Left (valueError "Agent-as-a-Net Attachment fence does not match the initial loop state")
  let occurrences = map (.occurrence) ap <> map (.occurrence) hs
  when (Set.size (Set.fromList occurrences) /= length occurrences) $
    Left (valueError "one Activity occurrence may be projected only once")
  when (map (.occurrence) ap /= sort (map (.occurrence) ap)) $
    Left (valueError "projected appends must retain History order")
  when (map (.occurrence) hs /= sort (map (.occurrence) hs)) $
    Left (valueError "projected Hands facts must retain History order")
  when (isJust term && isJust h) $ Left (valueError "Agent-as-a-Net projection cannot be terminal and halted")
  episode <- case Seq.viewr t.episodes of
    _ Seq.:> e | lifecycleIdText e.id == ini.episodeId -> Right e
    _ -> Left (valueError "projected Thread final Episode does not match the initial loop state")
  case Seq.viewr episode.turns of
    _ Seq.:> turn | lifecycleIdText turn.id == ini.turnId -> pure ()
    _ -> Left (valueError "projected Thread final Turn does not match the initial loop state")
  when (episode.acceptedAppends /= toInteger (length ap)) $
    Left (valueError "projected append cursor must equal Thread accepted-append accounting")
  when (isJust episode.settlement /= (isJust term || isJust h)) $
    Left (valueError "projected Thread settles exactly with one terminal or halt fact")
  pure (AgentNetThreadProjection i ini t a ap hs term h)

projectionSettled :: AgentNetThreadProjection -> Bool
projectionSettled p = isJust p.terminal || isJust p.halt

projectionToData :: AgentNetThreadProjection -> Json
projectionToData p =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("instance_id", String p.instanceId)
    , ("initial", loopStateToData p.initial)
    , ("thread", threadToData p.thread)
    , ("attachment", attachmentFenceToData p.attachment)
    , ("appends", Array (map projectedAppendToData p.appends))
    , ("hands", Array (map projectedHandsToData p.hands))
    , ("terminal", maybe Null terminalToData p.terminal)
    , ("halt", maybe Null haltToData p.halt)
    ]

projectionFromData :: Json -> Either AgenticusError AgentNetThreadProjection
projectionFromData raw = do
  value <-
    exact
      ["schema_version", "instance_id", "initial", "thread", "attachment", "appends", "hands", "terminal", "halt"]
      "Agent-as-a-Net Thread projection"
      raw
  case field "schema_version" value of
    Int 1 -> pure ()
    _ -> Left (valueError "Agent-as-a-Net Thread projection schema_version must be integer 1")
  (appendItems, handsItems) <- case (field "appends" value, field "hands" value) of
    (Array a, Array h) -> Right (a, h)
    _ -> Left (typeError "Agent-as-a-Net projection cursors must be arrays")
  ini <- loopStateFromData (field "initial" value)
  t <- threadFromData (field "thread" value)
  fence <- attachmentFenceFromData (field "attachment" value)
  ap <- traverse projectedAppendFromData appendItems
  hs <- traverse projectedHandsFromData handsItems
  term <- case field "terminal" value of
    Null -> Right Nothing
    other -> Just <$> terminalFromData other
  h <- case field "halt" value of
    Null -> Right Nothing
    other -> Just <$> haltFromData other
  i <- stringOr (field "instance_id" value) (Left (valueError "Agent-as-a-Net instance_id must be bounded non-empty text"))
  mkAgentNetThreadProjection i ini t fence ap hs term h

-- ---------------------------------------------------------------------------
-- Repositories

-- | The compare-and-save Thread projection boundary, separate from payload
-- custody.
data AgentNetThreadRepository = AgentNetThreadRepository
  { load :: IO (Maybe AgentNetThreadProjection)
  , save :: Maybe AgentNetThreadProjection -> AgentNetThreadProjection -> IO ()
  }

-- | Single-writer atomic JSON persistence for one Local runner's Thread
-- (@JsonAgentNetThreadRepository@).
jsonThreadRepository :: FilePath -> AgentNetThreadRepository
jsonThreadRepository path' = AgentNetThreadRepository {load = loadJson, save = saveJson}
  where
    loadJson = do
      exists <- doesFileExist path'
      if not exists
        then pure Nothing
        else do
          decoded <- try (B.readFile path') >>= \case
            Left (_ :: IOException) -> pure Nothing
            Right bytes -> pure (decodeProjection bytes)
          maybe (runnerError "durable Thread projection is unreadable") (pure . Just) decoded
    saveJson expected value = do
      current <- loadJson
      when (current /= expected) $ runnerError "durable Thread projection changed concurrently"
      encoded <- either (const (runnerError "durable Thread projection is not JSON-serializable")) pure (J.dumps compact (projectionToData value))
      let parent = takeDirectory path'
      createDirectoryIfMissing True parent
      suffix <- hexToken
      let temporary = parent </> ("." <> takeFileName path' <> "." <> suffix <> ".tmp")
      ( do
          fd <- PIO.openFd temporary PIO.WriteOnly PIO.defaultFileFlags {PIO.creat = Just 0o600, PIO.exclusive = True}
          (writeAllFd fd encoded >> fileSynchronise fd) `finally` PIO.closeFd fd
          renameFile temporary path'
          dir <- PIO.openFd parent PIO.ReadOnly PIO.defaultFileFlags
          fileSynchronise dir `finally` PIO.closeFd dir
        )
        `onException` (removeFile temporary `catch` \(_ :: IOException) -> pure ())
    compact =
      J.defaultDumps
        { J.itemSeparator = Just ","
        , J.keySeparator = ":"
        , J.sortKeys = True
        , J.allowNan = False
        }

decodeProjection :: ByteString -> Maybe AgentNetThreadProjection
decodeProjection bytes = case TE.decodeUtf8' bytes of
  Left _ -> Nothing
  Right _ -> case J.parseJson J.pythonLoads bytes of
    Left _ -> Nothing
    Right value -> either (const Nothing) Just (projectionFromData value)

writeAllFd :: Fd -> ByteString -> IO ()
writeAllFd fd bytes = unless (B.null bytes) $ do
  n <- fromIntegral <$> PIOB.fdWrite fd bytes
  writeAllFd fd (B.drop n bytes)

-- | @uuid4().hex@-shaped randomness for a temporary name.
hexToken :: IO String
hexToken = do
  bytes <- getRandomBytes 16 :: IO ByteString
  pure (concatMap byteHex (B.unpack bytes))
  where
    byteHex w = [digits !! fromIntegral (w `div` 16), digits !! fromIntegral (w `mod` 16)]
    digits = "0123456789abcdef"

-- ---------------------------------------------------------------------------
-- The Hands Activity

-- | Execute one current proposal through one current Episode Attachment
-- (@AgentNetHandsActivity@). The gateway opens lazily on the first call.
agentNetHandsActivity :: EpisodeAttachment -> HandsAdapter -> IO Activity
agentNetHandsActivity attachment' adapter = do
  gatewayRef <- newIORef (Nothing :: Maybe HandsGateway)
  pure $ \invocation context -> do
    when (invocation.activity /= handsActivity) $ runnerError "Hands Activity identity mismatch"
    value <- orThrow (exact ["version", "proposal", "grant_epoch"] "Hands Activity input" invocation.input)
    case field "version" value of
      Int 1 -> pure ()
      _ -> runnerError "Hands Activity input version mismatch"
    proposal <- orThrow (proposalFromData (field "proposal" value))
    grantEpoch' <- orThrow (positive "Hands Activity grant_epoch" (field "grant_epoch" value))
    coords <- coordinates attachment'
    grant <- currentGrant (grants attachment')
    case grant of
      Just g
        | g.grantEpoch == grantEpoch'
            && g.attachmentId == coords.attachmentId
            && g.attachmentEpoch == coords.attachmentEpoch ->
            pure ()
      _ -> runnerError "Hands Activity grant is not current"
    beat <- trySync (context.heartbeat (Just (Object [("phase", String "hands")])))
    case beat of
      Left _ -> runnerError "Hands Activity ownership is stale"
      Right _ -> pure ()
    gw <-
      readIORef gatewayRef >>= \case
        Just existing -> pure existing
        Nothing -> do
          opened <- gateway attachment' adapter 256
          writeIORef gatewayRef (Just opened)
          pure opened
    result <-
      submit
        gw
        ( Object
            [ ("version", Int schemaVersion)
            , ("call_id", String proposal.id)
            , ("episode_id", String coords.episodeId)
            , ("attachment_id", String coords.attachmentId)
            , ("attachment_epoch", Int coords.attachmentEpoch)
            , ("grant_epoch", Int grantEpoch')
            , ("method", String proposal.method)
            , ("params", proposal.params)
            ]
        )
    when
      ( result.callId /= proposal.id
          || result.attachmentId /= coords.attachmentId
          || result.epoch /= coords.attachmentEpoch
      )
      $ runnerError "Hands Activity result fence mismatch"
    projected <- orThrow (modelResultFromModelData (String proposal.id) (toolResultToModelData result))
    pure (Object [("version", Int schemaVersion), ("result", modelResultToData projected)])

-- ---------------------------------------------------------------------------
-- The runner

-- | The single-writer Local host whose Engine History alone schedules the
-- loop.
data AgentNetRunner = AgentNetRunner
  { engine :: Engine.Engine
  , history :: HistoryStore
  , repository :: AgentNetThreadRepository
  , projection :: IORef AgentNetThreadProjection
  , attachment :: EpisodeAttachment
  }

runnerEngine :: AgentNetRunner -> Engine.Engine
runnerEngine r = r.engine

runnerHistory :: AgentNetRunner -> HistoryStore
runnerHistory r = r.history

runnerProjection :: AgentNetRunner -> IO AgentNetThreadProjection
runnerProjection r = readIORef r.projection

runnerThread :: AgentNetRunner -> IO Thread
runnerThread r = (.thread) <$> readIORef r.projection

runnerSettled :: AgentNetRunner -> IO Bool
runnerSettled r = projectionSettled <$> readIORef r.projection

-- | The JSON Thread repository a runner rooted at this directory uses.
runnerThreadRepository :: FilePath -> AgentNetThreadRepository
runnerThreadRepository root = jsonThreadRepository (root </> threadFile)

-- | @AgentNetRunner.create@: start the Episode and Turn, save the first
-- projection, then host a fresh Engine.
createRunner
  :: FilePath
  -> Text
  -> Thread
  -> LoopState
  -> EpisodeAttachment
  -> Activity
  -> HandsAdapter
  -> IO AgentNetRunner
createRunner root = createRunnerWith (runnerThreadRepository root) root

-- | 'createRunner' over a given Thread repository (the reference's
-- @repository=@ argument).
createRunnerWith
  :: AgentNetThreadRepository
  -> FilePath
  -> Text
  -> Thread
  -> LoopState
  -> EpisodeAttachment
  -> Activity
  -> HandsAdapter
  -> IO AgentNetRunner
createRunnerWith repository' root instanceId' thread' initial' attachment' modelActivity adapter = do
  existing <- repository'.load
  historyExists <- doesFileExist (root </> historyFile)
  when (isJust existing || historyExists) $ runnerError "Agent-as-a-Net runner already exists; load it instead"
  validateInitial thread' initial' attachment'
  episodeId' <- orThrow (mkEpisodeId initial'.episodeId)
  turnId' <- orThrow (mkTurnId initial'.turnId)
  running <-
    orThrow $
      startEpisode episodeId' agentAsNetProgram agentAsNetA5Local.identity (episodeBudget 1 initial'.phaseLimit) thread'
        >>= startTurn turnId'
  fence <- attachmentFence initial' attachment'
  projection' <- orThrow (mkAgentNetThreadProjection instanceId' initial' running fence [] [] Nothing Nothing)
  repository'.save Nothing projection'
  openRunner root repository' projection' attachment' modelActivity adapter

-- | @AgentNetRunner.load@.
loadRunner :: FilePath -> EpisodeAttachment -> Activity -> HandsAdapter -> IO AgentNetRunner
loadRunner root = loadRunnerWith (runnerThreadRepository root) root

-- | 'loadRunner' over a given Thread repository.
loadRunnerWith :: AgentNetThreadRepository -> FilePath -> EpisodeAttachment -> Activity -> HandsAdapter -> IO AgentNetRunner
loadRunnerWith repository' root attachment' modelActivity adapter = do
  projection' <-
    repository'.load >>= maybe (runnerError "Agent-as-a-Net Thread projection does not exist") pure
  -- A crash may land after verified Attachment settlement but before the
  -- corresponding Thread save. Validate the immutable profile coordinates
  -- here; opening consumes terminal and ambiguity facts first and requires a
  -- live grant only if the reconstructed run remains active.
  validateAttachment projection'.initial attachment' (Just projection'.attachment) False
  openRunner root repository' projection' attachment' modelActivity adapter

openRunner
  :: FilePath
  -> AgentNetThreadRepository
  -> AgentNetThreadProjection
  -> EpisodeAttachment
  -> Activity
  -> HandsAdapter
  -> IO AgentNetRunner
openRunner root repository' projection' attachment' modelActivity adapter = do
  createDirectoryIfMissing True root
  store <- openJsonlHistoryStore (root </> historyFile)
  hands' <- agentNetHandsActivity attachment' adapter
  port <- inlineDispatch <$> newInlineDispatch (Map.fromList [(modelPhaseActivity, modelActivity), (handsActivity, hands')])
  recorded <- store.count
  engine' <-
    if recorded > 0
      then Engine.load agentNet projection'.instanceId store port (agentNetOptions Engine.defaultEngineOptions)
      else
        Engine.create
          agentNet
          projection'.instanceId
          store
          port
          (agentNetOptions Engine.defaultEngineOptions {Engine.marking = initialMarking projection'.initial})
  projectionRef <- newIORef projection'
  let runner = AgentNetRunner engine' store repository' projectionRef attachment'
  ( do
      projectCommitted runner
      settleRecordedFailure runner
      settleTerminal runner
      fenceReconstructedActivities runner
      current <- readIORef runner.projection
      unless (projectionSettled current) $
        validateAttachment current.initial attachment' (Just current.attachment) True
    )
    `onException` Engine.close engine'
  pure runner

validateInitial :: Thread -> LoopState -> EpisodeAttachment -> IO ()
validateInitial thread' initial' attachment' = do
  when (initial'.phase /= 1 || initial'.toolCount /= 0 || not (null initial'.results)) $
    runnerError "initial loop state must begin at the first empty phase"
  case Seq.viewr thread'.episodes of
    _ Seq.:> e | isNothing e.settlement -> runnerError "initial Thread already has an active Episode"
    _ -> pure ()
  case thread'.continuation of
    Nothing ->
      when (isJust initial'.outputRef || isJust initial'.continuationRef) $
        runnerError "fresh Thread cannot start from opaque prior references"
    Just c ->
      when (initial'.continuationRef /= Just c.stateReference || isNothing initial'.outputRef) $
        runnerError "initial references do not match the Thread Continuation lineage"
  validateAttachment initial' attachment' Nothing True

validateAttachment :: LoopState -> EpisodeAttachment -> Maybe AgentNetAttachmentFence -> Bool -> IO ()
validateAttachment initial' attachment' expected requireGrant = do
  let snapshot = episodeSnapshot attachment'
      runtime = snapshotDescriptor agentAsNetA5Local.identity.kind snapshot
      hands' = snapshotDescriptor capabilityScopedHands.identity.kind snapshot
      local = territoryIdentity Local
      territory = snapshotDescriptor local.kind snapshot
      mismatch = runnerError "Episode Attachment or grant does not match the Local loop state"
  grant <- currentGrant (grants attachment')
  coords <- coordinates attachment'
  when
    ( lifecycleIdText (episodeId attachment') /= initial'.episodeId
        || runtime /= Just agentAsNetA5Local
        || hands' /= Just capabilityScopedHands
        || maybe True (\t -> t.identity /= local) territory
    )
    mismatch
  case expected of
    Just fence
      | fence.episodeId /= coords.episodeId
          || fence.attachmentId /= coords.attachmentId
          || fence.attachmentEpoch /= coords.attachmentEpoch
          || fence.grantEpoch /= initial'.grantEpoch ->
          mismatch
    _ -> pure ()
  when requireGrant $ case grant of
    Just g
      | g.grantEpoch == initial'.grantEpoch
          && Set.fromList initial'.capabilities == Set.map toolMethodText g.capabilities
          && initial'.toolLimit <= g.maxCalls ->
          pure ()
    _ -> mismatch

attachmentFence :: LoopState -> EpisodeAttachment -> IO AgentNetAttachmentFence
attachmentFence initial' attachment' = do
  coords <- coordinates attachment'
  orThrow (mkAgentNetAttachmentFence coords.episodeId coords.attachmentId coords.attachmentEpoch initial'.grantEpoch)

-- | Advance the Engine one action and project what it committed.
advance :: AgentNetRunner -> IO Engine.DriveOutcome
advance r = do
  current <- readIORef r.projection
  when (projectionSettled current) $ runnerError "settled Agent-as-a-Net runner cannot advance"
  validateAttachment current.initial r.attachment (Just current.attachment) True
  outcome <-
    Engine.advance r.engine `catch` \(failure :: SomeException) ->
      if isRuntimeError failure
        then do
          projectCommitted r
          settleRecordedFailure r
          throwIO failure
        else throwIO failure
  projectCommitted r
  settleRecordedFailure r
  settleTerminal r
  pure outcome

-- | The reference's @except RuntimeError@: Engine runtime failures and
-- Agenticus errors whose class descends from @RuntimeError@.
isRuntimeError :: SomeException -> Bool
isRuntimeError failure
  | Just (Engine.EngineRuntimeError _) <- fromException failure = True
  | Just (e :: AgenticusError) <- fromException failure = e.errorClass `isSubclassOf` RuntimeError
  | otherwise = False

-- | Advance until the projection settles (@max_actions@ bounds the loop).
drain :: AgentNetRunner -> Integer -> IO AgentNetThreadProjection
drain r maxActions = do
  _ <- orThrow (positiveInt "Agent-as-a-Net max_actions" maxActions)
  go maxActions
  where
    go 0 = runnerError "Agent-as-a-Net action bound exhausted"
    go n = do
      current <- readIORef r.projection
      if projectionSettled current
        then pure current
        else do
          outcome <- advance r
          unless outcome.ready $ do
            flying <- Engine.inFlight r.engine
            if not (null flying)
              then runnerError "Agent-as-a-Net runner is waiting for external Activity custody"
              else runnerError "Agent-as-a-Net runner stopped before a terminal fact"
          go (n - 1)

closeRunner :: AgentNetRunner -> IO ()
closeRunner r = Engine.close r.engine

saveProjection :: AgentNetRunner -> AgentNetThreadProjection -> IO ()
saveProjection r next = do
  current <- readIORef r.projection
  r.repository.save (Just current) next
  writeIORef r.projection next

-- | @dataclasses.replace@: rebuild through the validating constructor.
rebuild :: AgentNetThreadProjection -> IO AgentNetThreadProjection
rebuild p = orThrow (mkAgentNetThreadProjection p.instanceId p.initial p.thread p.attachment p.appends p.hands p.terminal p.halt)

historyRecords :: AgentNetRunner -> IO [Record]
historyRecords r = toList <$> r.history.snapshot

requestsByOccurrence :: [Record] -> Map.Map Int ActivityRequested
requestsByOccurrence records' = Map.fromList [(a.occurrence, a) | RActivityRequested a <- records']

projectCommitted :: AgentNetRunner -> IO ()
projectCommitted r = do
  records' <- historyRecords r
  let requests = requestsByOccurrence records'
  forM_ [c | RActivityCompleted c <- records'] $ \record -> do
    requested <- maybe (runnerError "Activity completion has no recorded request") pure (Map.lookup record.occurrence requests)
    current <- readIORef r.projection
    let occurrence' = toInteger record.occurrence
    if
      | requested.activity == modelPhaseActivity -> do
          settled' <- orThrow (modelSettlementFromData record.result)
          when ((settled'.state.episodeId, settled'.state.turnId) /= (current.initial.episodeId, current.initial.turnId)) $
            runnerError "committed model settlement names stale Thread coordinates"
          projected <- orThrow (mkProjectedAppend occurrence' settled'.outputRef settled'.continuationRef)
          case [p | p <- current.appends, p.occurrence == occurrence'] of
            prior : _ ->
              when (prior /= projected) $ runnerError "committed model append conflicts with its Thread projection"
            [] -> do
              when (projectionSettled current) $ runnerError "new model append follows settled Thread projection"
              turnId' <- orThrow (mkTurnId current.initial.turnId)
              thread' <- orThrow (acceptAppend turnId' current.thread)
              next <- rebuild current {thread = thread', appends = current.appends <> [projected]}
              saveProjection r next
      | requested.activity == handsActivity -> do
          result <- handsResult requested record.result
          projected <- orThrow (mkProjectedHands occurrence' result)
          case [p | p <- current.hands, p.occurrence == occurrence'] of
            prior : _ ->
              when (prior /= projected) $ runnerError "committed Hands result conflicts with its Thread projection"
            [] -> do
              when (projectionSettled current) $ runnerError "new Hands result follows settled Thread projection"
              next <- rebuild current {hands = current.hands <> [projected]}
              saveProjection r next
      | otherwise -> runnerError "Agent-as-a-Net History contains an unsupported Activity"

-- | The proposal id a committed Hands result settles.
handsResult :: ActivityRequested -> Json -> IO Text
handsResult requested result = do
  request <- orThrow (exact ["version", "proposal", "grant_epoch"] "recorded Hands request" requested.input)
  proposal <- orThrow (proposalFromData (field "proposal" request))
  value <- orThrow (exact ["version", "result"] "committed Hands result" result)
  case field "version" value of
    Int 1 -> pure ()
    _ -> runnerError "committed Hands result version mismatch"
  settled' <- orThrow (modelResultFromData (field "result" value))
  when (settled'.id /= proposal.id) $ runnerError "committed Hands result names another proposal"
  pure settled'.id

settleRecordedFailure :: AgentNetRunner -> IO ()
settleRecordedFailure r = do
  current <- readIORef r.projection
  unless (projectionSettled current) $ do
    records' <- historyRecords r
    let requests = requestsByOccurrence records'
    case reverse [f | RActivityFailed f <- records'] of
      [] -> pure ()
      failure : _ -> do
        requested <- maybe (runnerError "Activity failure has no recorded request") pure (Map.lookup failure.occurrence requests)
        activity' <- orThrow (activityName (String requested.activity))
        settleAttachment r (Just "activity-failed")
        turnId' <- orThrow (mkTurnId current.initial.turnId)
        thread' <- orThrow (settleTurn turnId' TurnFailed current.thread >>= fmap (.thread) . settleEpisode EpisodeFailed Nothing)
        halt' <- orThrow (mkAgentNetHalt ActivityFailedHalt activity' (toInteger failure.occurrence))
        next <- rebuild current {thread = thread', halt = Just halt'}
        saveProjection r next

settleTerminal :: AgentNetRunner -> IO ()
settleTerminal r = do
  marking' <- Engine.marking r.engine
  case toList (placeTokens done marking') of
    [] -> pure ()
    [token] | token.color == Just "Terminal" -> do
      terminal' <- orThrow (terminalFromData token.payload)
      current <- readIORef r.projection
      when ((terminal'.episodeId, terminal'.turnId) /= (current.initial.episodeId, current.initial.turnId)) $
        runnerError "terminal fact names stale Thread coordinates"
      case current.terminal of
        Just recorded ->
          when (recorded /= terminal') $ runnerError "terminal fact conflicts with its Thread projection"
        Nothing -> do
          when (isJust current.halt) $ runnerError "terminal fact follows a settled halt"
          final <- case reverse current.appends of
            [] -> runnerError "terminal fact has no committed model append"
            item : _ -> pure item
          when ((terminal'.outputRef, terminal'.continuationRef) /= (final.outputReference, final.continuationReference)) $
            runnerError "terminal references do not match the final committed append"
          turnId' <- orThrow (mkTurnId terminal'.turnId)
          (thread', episodeOutcome) <-
            if terminal'.code == Cancelled
              then do
                settleAttachment r (Just "agent-cancelled")
                cancelled <- orThrow (requestCancellation current.thread)
                settledTurn <- orThrow (settleTurn turnId' TurnCancelled cancelled.thread)
                pure (settledTurn, EpisodeCancelled)
              else do
                settleAttachment r Nothing
                let turnOutcome = if terminal'.code == Failed then TurnFailed else TurnCompleted
                settledTurn <- orThrow (settleTurn turnId' turnOutcome current.thread)
                let outcome = case terminal'.code of
                      Completed -> EpisodeCompleted
                      PhaseBudget -> EpisodeBudgetExhausted
                      ToolBudget -> EpisodeBudgetExhausted
                      _ -> EpisodeFailed
                pure (settledTurn, outcome)
          next' <- continuationFor current terminal'
          settledThread <- orThrow ((.thread) <$> settleEpisode episodeOutcome (Just next') thread')
          next <- rebuild current {thread = settledThread, terminal = Just terminal'}
          saveProjection r next
    _ -> runnerError "Agent-as-a-Net terminal marking is invalid"

continuationFor :: AgentNetThreadProjection -> Terminal -> IO Continuation
continuationFor p terminal' = do
  let threadText = lifecycleIdText p.thread.id
      digest = T.pack (show (hash (TE.encodeUtf8 (threadText <> "\0" <> terminal'.episodeId <> "\0" <> terminal'.continuationRef)) :: Digest SHA256))
  identity' <- orThrow (mkContinuationId ("agent-net:" <> digest))
  orThrow (mkContinuation identity' p.thread.id agentAsNetContinuationDescriptor terminal'.continuationRef ContinuationAvailable)

fenceReconstructedActivities :: AgentNetRunner -> IO ()
fenceReconstructedActivities r = do
  current <- readIORef r.projection
  unless (projectionSettled current) $ do
    records' <- Engine.records r.engine
    flying <- Engine.inFlight r.engine
    let completed = Set.fromList [c.occurrence | RActivityCompleted c <- records']
        ambiguous = [o | o <- flying, isJust o.invocation, not (Set.member o.occurrence completed)]
    case ambiguous of
      [] -> pure ()
      [occurrence'] -> do
        invocation <- maybe (runnerError "reconstructed Activity has no invocation") pure occurrence'.invocation
        activity' <- orThrow (activityName (String invocation.activity))
        settleAttachment r (Just "reconstruction-indeterminate")
        turnId' <- orThrow (mkTurnId current.initial.turnId)
        thread' <-
          orThrow (settleTurn turnId' TurnIndeterminate current.thread >>= fmap (.thread) . settleEpisode EpisodeIndeterminate Nothing)
        halt' <- orThrow (mkAgentNetHalt Indeterminate activity' (toInteger occurrence'.occurrence))
        next <- rebuild current {thread = thread', halt = Just halt'}
        saveProjection r next
      _ -> runnerError "sequential Agent-as-a-Net History reconstructed multiple Activities"

settleAttachment :: AgentNetRunner -> Maybe Text -> IO ()
settleAttachment r cancelReason = do
  alreadySettled <- settled r.attachment
  record <-
    if alreadySettled
      then lastSettlement r.attachment
      else do
        uncertain <- custodyUncertain r.attachment
        when uncertain $ runnerError "Episode Attachment cleanup custody is uncertain"
        forM_ cancelReason (cancel r.attachment)
        Just <$> settle r.attachment 30
  case record of
    Just s | s.settlement.verified -> pure ()
    _ -> runnerError "Episode Attachment settlement was not independently verified"
