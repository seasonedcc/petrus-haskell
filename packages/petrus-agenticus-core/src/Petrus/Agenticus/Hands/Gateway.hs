-- | One common capability-scoped gateway path for every version-1 Hands call
-- (@petrus.agenticus.hands.gateway@).
--
-- Every request follows request -> direct precheck -> adapter/stage ->
-- serialized postcheck -> commit/discard -> exact result.  Prechecks run
-- before any adapter or provider crossing and leave adapter, stage, commit,
-- and target counters flat.  The postcheck and each commit run under the
-- 'Barrier' shared with attachment transition and cleanup, so a transition
-- can never advance while a commit is active and a staged write can never
-- commit past the fence.
module Petrus.Agenticus.Hands.Gateway
  ( -- * The shared barrier
    Barrier
  , newBarrier
  , withBarrier
  , holdsBarrier
    -- * Adapter values
  , ShellOutcome (returncode, stdout, stderr, truncated)
  , mkShellOutcome
  , StagedWrite (callId, path, digest)
  , mkStagedWrite
  , TestOutcome (passed, evidenceDigest)
  , mkTestOutcome
  , HandsAdapter (..)
    -- * Fences and seams
  , CallFence (open, aborted, deadline)
  , mkCallFence
  , callFence
  , CallFenceSource (..)
  , ResultAdmission (..)
  , TargetCurrency (..)
    -- * Evidence
  , CallEvidence (..)
  , GatewayCounters (..)
    -- * The gateway
  , GatewayConfig (..)
  , gatewayConfig
  , HandsGateway
  , newHandsGateway
  , gatewayEpisodeId
  , gatewayAttachmentId
  , gatewayAttachmentEpoch
  , gatewayGrants
  , submit
  , drain
  , cleanupStages
  , counters
  , evidence
  ) where

import Control.Concurrent (ThreadId, myThreadId, yield)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeException, evaluate, mask, mask_, onException, throwIO)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract
import Petrus.Agenticus.Hands.Grants
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- ---------------------------------------------------------------------------
-- Barrier

-- | The one reentrant barrier Hands calls and attachment transition share
-- (upstream's @RLock@).
--
-- A thread already inside 'withBarrier' may enter it again: the gateway's
-- write commit holds the barrier around its postcheck, the postcheck takes
-- it again, and a 'CallFenceSource' owned by the attachment may take it a
-- third time to read the epoch it guards.  Another thread waits until the
-- owner's outermost 'withBarrier' returns: it retries briefly, then parks
-- (parked waiters are served in FIFO order).
--
-- Intended use: the Episode Attachment creates one barrier per attachment
-- with 'newBarrier', passes it to every gateway it opens, and wraps its own
-- transition, cancellation and settlement steps in 'withBarrier'.  Holding
-- the barrier therefore excludes every gateway postcheck and commit of that
-- attachment.
data Barrier = Barrier
  { lock :: MVar ()
  , owner :: IORef (Maybe ThreadId)
  -- ^ written only by the holder, so a thread reading its own id here
  -- holds the lock
  }

newBarrier :: IO Barrier
newBarrier = Barrier <$> newMVar () <*> newIORef Nothing

-- | Run the action holding the barrier, re-entering when this thread already
-- holds it.  Waiting to acquire is interruptible; the hold is released on
-- every exit, including exceptions.
withBarrier :: Barrier -> IO a -> IO a
withBarrier barrier' action = do
  me <- myThreadId
  held <- (== Just me) <$> readIORef barrier'.owner
  if held
    then action
    else mask $ \restore -> do
      acquire (64 :: Int)
      writeIORef barrier'.owner (Just me)
      result <- restore action `onException` release
      release
      pure result
  where
    release = writeIORef barrier'.owner Nothing >> putMVar barrier'.lock ()
    -- Holds are short, so retry a bounded number of times (yielding to
    -- this capability's other threads) before parking: a parked waiter is
    -- woken across capabilities, which costs far more than the hold itself.
    acquire spins
      | spins <= 0 = takeMVar barrier'.lock
      | otherwise =
          tryTakeMVar barrier'.lock >>= \case
            Just () -> pure ()
            Nothing -> yield >> acquire (spins - 1)

-- | Whether the calling thread currently holds the barrier.
holdsBarrier :: Barrier -> IO Bool
holdsBarrier barrier' = do
  me <- myThreadId
  (== Just me) <$> readIORef barrier'.owner

-- ---------------------------------------------------------------------------
-- Adapter values

boundedValue :: Text -> Bool -> Bool -> Text -> Either AgenticusError Text
boundedValue name empty controls value
  | (not empty && T.null value) || utf8Length value > maxDataTextBytes || (not controls && hasControl value) =
      Left (valueError (name <> " must be a bounded string without control characters"))
  | otherwise = Right value

digestValue :: Text -> Text -> Either AgenticusError Text
digestValue name value
  | T.length value == 64 && T.all (`elem` ("0123456789abcdef" :: String)) value = Right value
  | otherwise = Left (valueError (name <> " must be a lowercase SHA-256 digest"))

-- | Bounded, provider-neutral process outcome; never raw provider state.
data ShellOutcome = ShellOutcome
  { returncode :: Integer
  , stdout :: Text
  , stderr :: Text
  , truncated :: Bool
  }
  deriving stock (Eq, Show)

mkShellOutcome :: Integer -> Text -> Text -> Bool -> Either AgenticusError ShellOutcome
mkShellOutcome code out err cut = do
  o <- boundedValue "shell outcome stdout" True True out
  e <- boundedValue "shell outcome stderr" True True err
  Right (ShellOutcome code o e cut)

-- | One authoritative stage token; the stage lives outside every final
-- target.
data StagedWrite = StagedWrite
  { callId :: Text
  , path :: Text
  , digest :: Text
  }
  deriving stock (Eq, Show)

mkStagedWrite :: Text -> Text -> Text -> Either AgenticusError StagedWrite
mkStagedWrite call path' digest' =
  StagedWrite
    <$> boundedValue "staged write call_id" False False call
    <*> boundedValue "staged write path" False False path'
    <*> digestValue "staged write digest" digest'

-- | One fixed-verifier outcome with digest evidence only.
data TestOutcome = TestOutcome
  { passed :: Bool
  , evidenceDigest :: Text
  }
  deriving stock (Eq, Show)

mkTestOutcome :: Bool -> Text -> Either AgenticusError TestOutcome
mkTestOutcome passed' digest' = TestOutcome passed' <$> digestValue "test outcome evidence_digest" digest'

-- | Provider-neutral workspace operations behind the gateway.
--
-- Adapters expose authoritative stage/commit/discard operations and bounded
-- digest or text evidence.  They never expose raw provider state, sessions,
-- credentials, or unbounded output.  A synchronous exception from any
-- operation is a provider failure; asynchronous exceptions propagate.
data HandsAdapter = HandsAdapter
  { read :: Text -> IO Text
  , search :: Text -> Text -> IO [Text]
  , shell :: [Text] -> Text -> IO ShellOutcome
  , stageWrite :: Text -> Text -> Text -> IO StagedWrite
  -- ^ call id, path, content
  , commitWrite :: StagedWrite -> IO Text
  -- ^ the committed digest
  , discardWrite :: StagedWrite -> IO ()
  , runTest :: IO TestOutcome
  , discardAllStages :: IO Int
  }

-- ---------------------------------------------------------------------------
-- Fences and seams

-- | One snapshot of the dynamic attachment state a call must satisfy.
data CallFence = CallFence
  { open :: Bool
  , aborted :: Bool
  , deadline :: Double
  }
  deriving stock (Eq, Show)

mkCallFence :: Bool -> Bool -> Double -> Either AgenticusError CallFence
mkCallFence open' aborted' deadline'
  | isNaN deadline' || isInfinite deadline' = Left (valueError "call fence deadline must be a finite number")
  | otherwise = Right (CallFence open' aborted' deadline')

-- | 'mkCallFence' for known-valid literals.
callFence :: Bool -> Bool -> Double -> CallFence
callFence o a d = either (error . T.unpack . errorMessage) id (mkCallFence o a d)

-- | The current attachment gate; refreshed again under the barrier (the
-- snapshot may itself take the barrier, which is reentrant).
newtype CallFenceSource = CallFenceSource {snapshot :: IO CallFence}

-- | DS2 admission seam; a stale, revoked, or removed fence answers 'False'.
newtype ResultAdmission = ResultAdmission {admit :: Text -> IO Bool}

-- | Host target-head seam consulted under the barrier before a write commit.
newtype TargetCurrency = TargetCurrency {isCurrent :: IO Bool}

-- ---------------------------------------------------------------------------
-- Evidence

-- | One bounded finalized call fact for host sensors; secret-free by shape.
data CallEvidence = CallEvidence
  { sequence :: Int
  , callId :: Text
  , episodeId :: Text
  , method :: Maybe ToolMethod
  , ok :: Bool
  , category :: Maybe RejectionCategory
  , epoch :: Integer
  }
  deriving stock (Eq, Show)

-- | Exact request, rejection, stage, commit, and mutation accounting.
data GatewayCounters = GatewayCounters
  { requests :: Int
  , rejections :: Map RejectionCategory Int
  , adapterEntries :: Int
  , stages :: Int
  , commits :: Int
  , stageDiscards :: Int
  , stageDiscardFailures :: Int
  , targetMutations :: Int
  , resultsAdmitted :: Int
  }
  deriving stock (Eq, Show)

emptyCounters :: GatewayCounters
emptyCounters = GatewayCounters 0 Map.empty 0 0 0 0 0 0 0

-- ---------------------------------------------------------------------------
-- The gateway

-- | The keyword arguments of @HandsGateway(...)@.
data GatewayConfig = GatewayConfig
  { episodeId :: Text
  , adapter :: HandsAdapter
  , grants :: GrantLedger
  , fence :: CallFenceSource
  , barrier :: Barrier
  , admission :: Maybe ResultAdmission
  , target :: Maybe TargetCurrency
  , clock :: IO Double
  -- ^ seconds; 'getMonotonicTime' by default (@time.monotonic@)
  , maxEvidence :: Int
  , maxGatewayCalls :: Int
  -- ^ the call-ledger bound (upstream @max_calls@)
  }

-- | The required arguments, with no admission or target seam, the monotonic
-- clock, and the upstream bounds of 256 evidence entries and 256 calls.
gatewayConfig :: Text -> HandsAdapter -> GrantLedger -> CallFenceSource -> Barrier -> GatewayConfig
gatewayConfig episode adapter' grants' fence' barrier' =
  GatewayConfig
    { episodeId = episode
    , adapter = adapter'
    , grants = grants'
    , fence = fence'
    , barrier = barrier'
    , admission = Nothing
    , target = Nothing
    , clock = getMonotonicTime
    , maxEvidence = 256
    , maxGatewayCalls = 256
    }

-- | One claimed call: its immutable request and either the signal exact
-- waiters block on or its published result.
data Entry = Entry
  { request :: ToolRequest
  , state :: EntryState
  }

data EntryState
  = Pending (MVar ())
  -- ^ filled when the claim is published or abandoned
  | Done ToolResult

-- | The single-flight call ledger plus the in-flight count 'drain' waits on.
data Calls = Calls
  { ledger :: Map Text Entry
  , inFlight :: Int
  }

data Stats = Stats
  { counted :: GatewayCounters
  , lastSequence :: Int
  , recent :: Seq CallEvidence
  }

-- | The single gateway for one Episode Attachment epoch.  No local fallback
-- exists.
data HandsGateway = HandsGateway
  { config :: GatewayConfig
  , calls :: IORef Calls
  , drained :: TVar Int
  -- ^ bumped whenever the in-flight count returns to zero
  , stats :: IORef Stats
  }

newHandsGateway :: GatewayConfig -> IO HandsGateway
newHandsGateway cfg = do
  when (cfg.maxEvidence <= 0) $ throwAgenticus ValueError "gateway max_evidence must be a positive integer"
  when (cfg.maxGatewayCalls <= 0) $ throwAgenticus ValueError "gateway max_calls must be a positive integer"
  _ <- throwLeft (gatewayIdentity cfg.episodeId)
  HandsGateway cfg
    <$> newIORef (Calls Map.empty 0)
    <*> newTVarIO 0
    <*> newIORef (Stats emptyCounters 0 Seq.empty)
  where
    gatewayIdentity value = do
      v <- boundedValue "gateway episode_id" False False value
      if utf8Length v > maxTextBytes then Left (valueError "gateway episode_id must be a bounded identity string") else Right v

gatewayEpisodeId :: HandsGateway -> Text
gatewayEpisodeId gw = gw.config.episodeId

gatewayAttachmentId :: HandsGateway -> Text
gatewayAttachmentId gw = gw.config.grants.attachmentId

gatewayAttachmentEpoch :: HandsGateway -> Integer
gatewayAttachmentEpoch gw = gw.config.grants.attachmentEpoch

gatewayGrants :: HandsGateway -> GrantLedger
gatewayGrants gw = gw.config.grants

counters :: HandsGateway -> IO GatewayCounters
counters gw = (.counted) <$> readIORef gw.stats

evidence :: HandsGateway -> IO [CallEvidence]
evidence gw = toList . (.recent) <$> readIORef gw.stats

count :: HandsGateway -> (GatewayCounters -> GatewayCounters) -> IO ()
count gw f = atomicModifyIORef' gw.stats $ \s -> (s {counted = f s.counted}, ())

-- | Wait until no call is between its claim and its finalized result.
-- 'True' when drained; 'False' when the timeout (seconds, measured on the
-- gateway clock) passed first.
drain :: HandsGateway -> Double -> IO Bool
drain gw timeout = do
  start <- gw.config.clock
  let deadline' = start + timeout
      loop = do
        seen <- readTVarIO gw.drained
        pending <- (.inFlight) <$> readIORef gw.calls
        if pending == 0
          then pure True
          else do
            now <- gw.config.clock
            let remaining = deadline' - now
            if remaining <= 0
              then pure False
              else do
                timer <- registerDelay (toMicros remaining)
                notified <-
                  atomically $
                    (readTVar gw.drained >>= \g -> check (g /= seen) >> pure True)
                      `orElse` (readTVar timer >>= check >> pure False)
                if notified then loop else (== 0) . (.inFlight) <$> readIORef gw.calls
  loop
  where
    toMicros seconds = max 1 (floor (min seconds 2000 * 1e6))

-- | Remove every outstanding adapter stage as part of attachment settlement.
cleanupStages :: HandsGateway -> IO Int
cleanupStages gw = do
  removed <- gw.config.adapter.discardAllStages
  when (removed < 0) $ throwAgenticus TypeError "adapter discard_all_stages must return a non-negative stage count"
  count gw $ \c -> c {stageDiscards = c.stageDiscards + removed}
  pure removed

-- | What 'claim' settles on. Waiting for an in-flight duplicate is
-- 'Lookup''s extra case, internal to 'claim''s retry loop.
data Claim
  = Claimed (MVar ())
  | Prior ToolResult
  | Conflict
  | LedgerFull

-- | One look at the ledger: a settled claim, or the signal of an exact
-- in-flight duplicate to wait for.
data Lookup = Settled Claim | Waiting (MVar ())

-- | Run one request through the complete common path and return its exact
-- result.  Throws @ToolCallConflict@ when the call identity names a
-- materially different request.
submit :: HandsGateway -> Json -> IO ToolResult
submit gw data' = do
  count gw $ \c -> c {requests = c.requests + 1}
  case parseToolRequest data' of
    Left rejection -> rejectUnparsed gw data' rejection
    Right request -> mask $ \restore -> do
      claimed <- restore (claim gw request)
      case claimed of
        Prior result -> pure result
        Conflict -> throwIO toolCallConflict
        LedgerFull -> restore (finalizeError gw request (toolError CategoryBudget "call ledger budget is exhausted"))
        Claimed signal -> restore (runClaimed gw request signal) `onException` abandon gw request signal

-- | Claim the call identity, or wait for an exact in-flight duplicate to
-- publish (or abandon) and look again.  A fresh claim is registered with its
-- in-flight count in one atomic step, so settlement drains every claimed
-- call, including one between its initial fence check and adapter entry.
claim :: HandsGateway -> ToolRequest -> IO Claim
claim gw request = do
  signal <- newEmptyMVar
  decision <- mask_ $ atomicModifyIORef' gw.calls $ \current ->
    case Map.lookup request.callId current.ledger of
      Nothing
        | Map.size current.ledger >= gw.config.maxGatewayCalls -> (current, Settled LedgerFull)
        | otherwise ->
            ( current {ledger = Map.insert request.callId (Entry request (Pending signal)) current.ledger, inFlight = current.inFlight + 1}
            , Settled (Claimed signal)
            )
      Just found
        | found.request /= request -> (current, Settled Conflict)
        | Done result <- found.state -> (current, Settled (Prior result))
        | Pending other <- found.state -> (current, Waiting other)
  case decision of
    Waiting other -> readMVar other >> claim gw request
    Settled settled -> pure settled

-- | Leave the in-flight set: replace or remove the claim, wake its exact
-- waiters, and wake 'drain' when nothing is left in flight.
settle :: HandsGateway -> ToolRequest -> MVar () -> (Map Text Entry -> Map Text Entry) -> IO ()
settle gw request signal update = do
  left <- atomicModifyIORef' gw.calls $ \c -> case Map.lookup request.callId c.ledger of
    Just found
      | Pending own <- found.state
      , own == signal ->
          (c {ledger = update c.ledger, inFlight = c.inFlight - 1}, Just (c.inFlight - 1))
    _ -> (c, Nothing)
  case left of
    Nothing -> pure ()
    Just remaining -> do
      _ <- tryPutMVar signal ()
      when (remaining == 0) $ atomically (modifyTVar' gw.drained (+ 1))

publish :: HandsGateway -> ToolRequest -> MVar () -> ToolResult -> IO ()
publish gw request signal result = settle gw request signal (Map.insert request.callId (Entry request (Done result)))

-- | Remove a claim whose primary failed with an exception, so an exact
-- waiter can reclaim it.
abandon :: HandsGateway -> ToolRequest -> MVar () -> IO ()
abandon gw request signal = settle gw request signal (Map.delete request.callId)

runClaimed :: HandsGateway -> ToolRequest -> MVar () -> IO ToolResult
runClaimed gw request signal = do
  checked <- precheck gw request
  result <- case checked of
    Just failure -> finalizeError gw request failure
    Nothing ->
      tryConsumeGrant gw.config.grants request.grantEpoch >>= \case
        Left e
          | e `isInstanceOf` GrantBudgetExhausted -> finalizeError gw request (toolError CategoryBudget "grant call budget is exhausted")
          | otherwise -> finalizeError gw request (toolError CategoryStaleEpoch "grant is not current")
        Right grant -> execute gw request grant
  publish gw request signal result
  pure result

-- | A synchronous exception becomes 'Left'; asynchronous ones propagate.
-- | 'trySync' of the result forced to weak head normal form.
tryForced :: IO a -> IO (Either SomeException a)
tryForced action = trySync (action >>= evaluate)

-- | Direct prechecks; adapter, stage, commit, and target counters stay flat.
precheck :: HandsGateway -> ToolRequest -> IO (Maybe ToolError)
precheck gw request
  | request.episodeId /= gw.config.episodeId
      || request.attachmentId /= gatewayAttachmentId gw
      || request.attachmentEpoch /= gatewayAttachmentEpoch gw =
      pure (Just (toolError CategoryStaleEpoch "episode, attachment identity, or epoch is not current"))
  | otherwise =
      tryForced gw.config.fence.snapshot >>= \case
        Left _ -> pure (Just providerError)
        Right fence'
          | not fence'.open -> pure (Just (toolError CategoryPostFence "attachment admission is closed"))
          | fence'.aborted -> pure (Just (toolError CategoryAborted "attachment is cancelled"))
          | otherwise ->
              currentGrant gw.config.grants >>= \case
                Just grant | grant.grantEpoch == request.grantEpoch -> do
                  now <- gw.config.clock
                  pure $
                    if now > min fence'.deadline grant.deadline
                      then Just (toolError CategoryDeadline "call deadline has passed")
                      else precheckPolicy request grant
                _ -> pure (Just (toolError CategoryStaleEpoch "grant is not current"))

precheckPolicy :: ToolRequest -> CapabilityGrant -> Maybe ToolError
precheckPolicy request grant = case request.params of
  ParamsWrite p
    | not (permits grant WorkspaceWrite) -> Just (toolError CategoryWrite "no current write grant")
    | not (permitsWritePath grant p.path) -> Just (toolError CategoryPath "path is not writable under the current grant")
    | otherwise -> Nothing
  params'
    | not (permits grant request.method) -> Just (toolError CategoryCapability "capability is not granted")
    | ParamsShell p <- params'
    , not (p.argv `elem` grant.allowedArgv) ->
        Just (toolError CategoryArgv "argv is not allowed under the current grant")
    | otherwise -> Nothing

maxSearchResults :: Int
maxSearchResults = 64

execute :: HandsGateway -> ToolRequest -> CapabilityGrant -> IO ToolResult
execute gw request grant = do
  count gw $ \c -> c {adapterEntries = c.adapterEntries + 1}
  case request.params of
    ParamsWrite p -> executeWrite gw request grant p
    params' ->
      tryForced (perform gw.config.adapter params') >>= \case
        Right (Just fields) ->
          postcheck gw request grant False >>= \case
            Just failure -> finalizeError gw request failure
            Nothing -> finalizeData gw request fields
        _ -> finalizeError gw request providerError

-- | The adapter crossing; 'Nothing' for a malformed adapter result.
perform :: HandsAdapter -> ToolParams -> IO (Maybe Fields)
perform adapter' = \case
  ParamsRead p -> do
    content' <- adapter'.read p.path
    pure (Just [("content", String content')])
  ParamsSearch p -> do
    matches <- adapter'.search p.query p.path
    _ <- evaluate (foldr seq () matches)
    pure $
      if length matches > maxSearchResults
        then Nothing
        else Just [("matches", Array (map String matches))]
  ParamsShell p -> do
    outcome <- adapter'.shell p.argv p.cwd
    pure $
      Just
        [ ("returncode", Int outcome.returncode)
        , ("stdout", String outcome.stdout)
        , ("stderr", String outcome.stderr)
        , ("truncated", Bool outcome.truncated)
        ]
  ParamsTest -> do
    outcome <- adapter'.runTest
    pure (Just [("passed", Bool outcome.passed), ("digest", String outcome.evidenceDigest)])
  ParamsWrite _ -> pure Nothing

executeWrite :: HandsGateway -> ToolRequest -> CapabilityGrant -> WriteParams -> IO ToolResult
executeWrite gw request grant p =
  tryForced (gw.config.adapter.stageWrite request.callId p.path p.content) >>= \case
    Left _ -> finalizeError gw request providerError
    Right staged -> do
      count gw $ \c -> c {stages = c.stages + 1}
      if staged.callId /= request.callId || staged.path /= p.path
        then discard gw staged >> finalizeError gw request providerError
        else do
          outcome <- withBarrier gw.config.barrier $
            postcheck gw request grant True >>= \case
              Just failure -> do
                discarded <- discard gw staged
                pure (Left (if discarded then failure else providerError))
              Nothing ->
                tryForced (gw.config.adapter.commitWrite staged) >>= \case
                  Left _ -> discard gw staged >> pure (Left providerError)
                  Right digest' -> do
                    count gw $ \c -> c {commits = c.commits + 1, targetMutations = c.targetMutations + 1}
                    pure (if digest' /= staged.digest then Left providerError else Right digest')
          case outcome of
            Left failure -> finalizeError gw request failure
            Right digest' -> finalizeData gw request [("committed", Bool True), ("digest", String digest')]

-- | Refresh every fence under the barrier before exactly one commit or
-- admission.
postcheck :: HandsGateway -> ToolRequest -> CapabilityGrant -> Bool -> IO (Maybe ToolError)
postcheck gw request grant write = withBarrier gw.config.barrier $
  tryForced gw.config.fence.snapshot >>= \case
    Left _ -> pure (Just providerError)
    Right fence'
      | not fence'.open -> pure (Just (toolError CategoryPostFence "attachment fence closed after staging"))
      | fence'.aborted -> pure (Just (toolError CategoryAborted "attachment cancelled before commit"))
      | otherwise -> do
          current <- currentGrant gw.config.grants
          if maybe True (\g -> g.grantEpoch /= grant.grantEpoch) current
            then pure (Just (toolError CategoryStaleEpoch "grant replaced before commit"))
            else do
              now <- gw.config.clock
              if now > min fence'.deadline grant.deadline
                then pure (Just (toolError CategoryDeadline "deadline passed before commit"))
                else do
                  admitted <- maybe (pure True) (\a -> seam (a.admit request.callId)) gw.config.admission
                  if not admitted
                    then pure (Just (toolError CategoryAuthority "connection admission rejected the result"))
                    else do
                      current' <- if write then maybe (pure True) (\t -> seam t.isCurrent) gw.config.target else pure True
                      pure (if current' then Nothing else Just (toolError CategoryPostFence "target head is no longer current"))
  where
    seam action = either (const False) id <$> tryForced action

discard :: HandsGateway -> StagedWrite -> IO Bool
discard gw staged =
  tryForced (gw.config.adapter.discardWrite staged) >>= \case
    Left _ -> do
      count gw $ \c -> c {stageDiscardFailures = c.stageDiscardFailures + 1}
      pure False
    Right () -> do
      count gw $ \c -> c {stageDiscards = c.stageDiscards + 1}
      pure True

rejectUnparsed :: HandsGateway -> Json -> ToolRequestRejected -> IO ToolResult
rejectUnparsed gw data' rejection = do
  let (call, episode) = salvagedIdentity data'
      failure = toolError rejection.category rejection.detail
  record gw call episode Nothing False (Just failure.category)
  either throwIO pure (mkToolResult call (gatewayAttachmentId gw) (gatewayAttachmentEpoch gw) False Nothing (Just failure))

finalizeError :: HandsGateway -> ToolRequest -> ToolError -> IO ToolResult
finalizeError gw request failure = do
  result <- either throwIO pure (mkToolResult request.callId (gatewayAttachmentId gw) (gatewayAttachmentEpoch gw) False Nothing (Just failure))
  record gw request.callId request.episodeId (Just request.method) False (Just failure.category)
  pure result

-- | Finalize successful data; data outside the strict bounds is a provider
-- failure.
finalizeData :: HandsGateway -> ToolRequest -> Fields -> IO ToolResult
finalizeData gw request fields =
  case mkToolResult request.callId (gatewayAttachmentId gw) (gatewayAttachmentEpoch gw) True (Just fields) Nothing of
    Left e
      | e `isInstanceOf` TypeError || e `isInstanceOf` ValueError -> finalizeError gw request providerError
      | otherwise -> throwIO e
    Right result -> do
      record gw request.callId request.episodeId (Just request.method) True Nothing
      pure result

record :: HandsGateway -> Text -> Text -> Maybe ToolMethod -> Bool -> Maybe RejectionCategory -> IO ()
record gw call episode method' ok' category' = atomicModifyIORef' gw.stats $ \s ->
  let next = s.lastSequence + 1
      entry = CallEvidence next call episode method' ok' category' (gatewayAttachmentEpoch gw)
      appended = s.recent |> entry
      bounded = if Seq.length appended > gw.config.maxEvidence then Seq.drop 1 appended else appended
      c = s.counted
      c' =
        c
          { rejections = maybe c.rejections (\k -> Map.insertWith (+) k 1 c.rejections) category'
          , resultsAdmitted = if ok' then c.resultsAdmitted + 1 else c.resultsAdmitted
          }
   in (Stats c' next bounded, ())

toolError :: RejectionCategory -> Text -> ToolError
toolError c d = either (error . T.unpack . errorMessage) id (mkToolError c d)

providerError :: ToolError
providerError = toolError CategoryProvider "provider operation failed"
