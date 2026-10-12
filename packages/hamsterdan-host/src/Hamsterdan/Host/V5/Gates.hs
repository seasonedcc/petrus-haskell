{-# LANGUAGE PatternSynonyms #-}

-- | Provider-backed publication gates for the V5 topology
-- (@host/v5/gates.py@).
--
-- Each gate executes ONE comment publication against the
-- 'PublicationProvider' surface and classifies its own outcome into the
-- exact typed terminals the V5 topology routes by color:
--
-- 1. lookup-first reconciliation happens before any fence or failure
--    mode: a crash after the provider held the effect reconciles landed;
-- 2. fenced gates (announce, findings publish) compare every claimed
--    authority field via the claim port; reply, reminder, and dashboard
--    carry no fence by design;
-- 3. @GitHubBoundaryError@ and a proven capability denial classify
--    Blocked; an identity collision, an unclassifiable provider terminal,
--    or an unrecognized returned status classify Fault;
-- 4. reply and reminder identities are operation-scoped.
--
-- Classified outcomes return as typed terminals ('Variant's). Only an
-- exception the reference would not catch propagates.
module Hamsterdan.Host.V5.Gates
  ( -- * Ports
    PublicationProvider (..)
  , publicationProvider
  , Recipients
  , V5PublicationGates (..)
  , publicationGates
  , UnstagedCustodyError (..)

    -- * Gates
  , replyGate
  , reminderGate
  , announceGate
  , publishGate
  , dashGate

    -- * Helpers
  , announceBody
  , announceCompatible
  , findingOperation
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM, void)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (Contract, Object, spelling)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Effects (CommentPublisher)
import Hamsterdan.GitHub.Effects qualified as Effects
import Hamsterdan.GitHub.Models (FailureClass (..), FindingPublication (..), GitHubBoundaryError (..), PublicationResult (..), PublicationStatus (..), publicationStatusText)
import Hamsterdan.Python qualified as Py
import Hamsterdan.Host.Errors (Caught (..), UnstagedCustodyError (..), catchGate)
import Hamsterdan.Host.Python (pattern TypeError, ValueError (..), raisePython, sha256HexText)
import Hamsterdan.Host.V5.Claim (ClaimReader, CurrentClaim (..))
import Hamsterdan.Readiness.NetV5.Board (renderBoard)
import Hamsterdan.Readiness.NetV5.Gating (Variant, markerOperation, variantOf)
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Json (Json (..), jsonTypeName)
import Petrus.Json.PythonText (pythonStrRepr)

-- | The @CommentPublisher@ surface the gates bind to (fakes in tests).
data PublicationProvider = PublicationProvider
  { find :: Text -> Text -> Text -> Text -> [Text] -> IO (Maybe PublicationResult)
  -- ^ @find(kind, operation, head, body, compatible_bodies=...)@
  , immutable :: Text -> Text -> Integer -> Text -> Text -> Maybe Text -> [Text] -> IO PublicationResult
  -- ^ @immutable(kind, operation, epoch, head, body, authority_operation=, compatible_bodies=)@
  , immutableOperation :: Text -> Text -> Text -> IO (Integer, Text) -> [Text] -> IO PublicationResult
  -- ^ @immutable_operation(kind, operation, body, context=, compatible_bodies=)@
  , dashboard :: Text -> Integer -> Text -> Text -> IO PublicationResult
  -- ^ @dashboard(operation, epoch, head, body)@
  , reminderOperation :: Text -> IO (Integer, Text, Maybe Text, Text) -> IO PublicationResult
  -- ^ @reminder_operation(operation, context=)@
  , finding :: FindingPublication -> Integer -> Text -> Maybe Text -> IO PublicationResult
  -- ^ @finding(operation, epoch, head, text, path=, line=, ..., authority_operation=)@
  , findings :: Integer -> Text -> [FindingPublication] -> Text -> IO [PublicationResult]
  -- ^ @findings(epoch, head, findings, authority_operation=)@
  , findingFind :: Text -> Text -> IO (Maybe PublicationResult)
  -- ^ @finding_find(operation, head)@
  }

-- | The real @CommentPublisher@ as a provider.
publicationProvider :: CommentPublisher -> PublicationProvider
publicationProvider pub =
  PublicationProvider
    { find = Effects.findPublication pub
    , immutable = Effects.immutable pub
    , immutableOperation = Effects.immutableOperation pub
    , dashboard = Effects.dashboard pub
    , reminderOperation = Effects.reminderOperation pub
    , finding = Effects.publishFinding pub
    , findings = Effects.publishFindings pub
    , findingFind = Effects.findingFind pub
    }

-- | A port yielding the current @(reviewer, author)@.
type Recipients = IO (Maybe Text, Text)

-- | @V5PublicationGates(publisher, claim, recipients, dashboard_phase,
-- resolve_stale_threads)@.
data V5PublicationGates = V5PublicationGates
  { publisher :: PublicationProvider
  , claim :: ClaimReader
  , recipients :: Recipients
  , dashboardPhase :: IO Phase
  , resolveStaleThreads :: Maybe (Text -> IO Int)
  }

-- | The gates with the reference's defaults (@dashboard_phase@ always
-- @running@, no stale-thread resolution).
publicationGates :: PublicationProvider -> ClaimReader -> Recipients -> V5PublicationGates
publicationGates publisher claim recipients =
  V5PublicationGates {publisher, claim, recipients, dashboardPhase = pure PhaseRunning, resolveStaleThreads = Nothing}

announceBody :: Text
announceBody =
  "## Hamsterdan readiness advisory\n\n"
    <> "All observed gates are ready. Clean. Humans keep merge authority; Dan never merges PRs."

announceCompatible :: [Text]
announceCompatible =
  ["## Hamsterdan readiness advisory\n\nAll observed gates are ready. Advisory only; Hamsterdan does not merge PRs."]

held, dashHeld :: [PublicationStatus]
held = [PublicationCreated, PublicationExisting]
dashHeld = [PublicationCreated, PublicationExisting, PublicationUpdated]

data Unproven = Proven | UnprovenBlocked | UnprovenFault Text

-- | @_unproven(result, held)@.
unproven :: [PublicationStatus] -> PublicationResult -> Unproven
unproven heldStatuses result
  | not result.capabilityAvailable = UnprovenBlocked
  | result.status `elem` heldStatuses = Proven
  | otherwise = UnprovenFault ("unclassified publication status " <> pythonStrRepr (publicationStatusText result.status))

v :: (Contract a) => a -> Variant
v = variantOf

-- ---------------------------------------------------------------------------
-- reply: unfenced, immutable, identity @reply:{id}@

replyGate :: V5PublicationGates -> ReplyReq -> IO Variant
replyGate g work = do
  let context = do
        current <- g.claim
        pure (current.incarnation, current.head)
      blocked = v ReplyBlocked {id = work.id, text = work.text}
      fault reason = v ReplyFault {id = work.id, text = work.text, reason}
  outcome <-
    catchGate
      (Right <$> g.publisher.immutableOperation "conversation" ("reply:" <> work.id) work.text context [])
      ( pure . Left . \case
          CaughtUnstaged _ -> blocked
          CaughtBoundary _ -> blocked
          CaughtRerunRefused reason -> fault reason
          CaughtFault reason -> fault reason
      )
  pure $ case outcome of
    Left terminal -> terminal
    Right result -> case unproven held result of
      UnprovenBlocked -> blocked
      UnprovenFault reason -> fault reason
      Proven -> v Replied {id = work.id, text = work.text}

-- ---------------------------------------------------------------------------
-- reminder: unfenced, immutable, identity @reminder:{timer_id}@

reminderGate :: V5PublicationGates -> RemReq -> IO Variant
reminderGate g work = do
  let context = do
        current <- g.claim
        (reviewer, author) <- g.recipients
        pure (current.incarnation, current.head, reviewer, author)
      blocked = v RemBlocked {timerId = work.timerId}
      fault reason = v RemFault {timerId = work.timerId, reason}
  outcome <-
    catchGate
      (Right <$> g.publisher.reminderOperation ("reminder:" <> work.timerId) context)
      ( pure . Left . \case
          CaughtUnstaged _ -> blocked
          CaughtBoundary _ -> blocked
          CaughtRerunRefused reason -> fault reason
          CaughtFault reason -> fault reason
      )
  pure $ case outcome of
    Left terminal -> terminal
    Right result -> case unproven held result of
      UnprovenBlocked -> blocked
      UnprovenFault reason -> fault reason
      Proven -> v RemLanded {timerId = work.timerId}

-- ---------------------------------------------------------------------------
-- announce: full claim fence, immutable, identity in @work.op@

announceGate :: V5PublicationGates -> AnnounceReq -> IO Variant
announceGate g work = do
  let expected = CurrentClaim PhaseRunning work.incarnation work.head work.base work.policy
      landed = v ALanded {incarnation = work.incarnation, head = work.head}
      blocked = v ABlocked {incarnation = work.incarnation, head = work.head, base = work.base, policy = work.policy}
      fault reason = v AFault {op = work.op, incarnation = work.incarnation, reason}
      body = do
        found <- g.publisher.find "readiness" work.op work.head announceBody announceCompatible
        case found of
          Just _ -> pure (Left landed)
          Nothing -> do
            current <- g.claim
            if (work.strictBase && not work.baseCurrent) || current /= expected
              then
                pure . Left $
                  v
                    AMoved
                      { incarnation = work.incarnation
                      , observedHead = current.head
                      , observedBase = current.base
                      , observedPolicy = current.policy
                      , observedIncarnation = current.incarnation
                      , observedPhase = spelling current.phase
                      }
              else do
                result <- g.publisher.immutable "readiness" work.op work.incarnation work.head announceBody Nothing announceCompatible
                mapM_ (\resolve -> void (resolve work.head)) g.resolveStaleThreads
                pure (Right result)
  outcome <-
    catchGate body $
      pure . Left . \case
        CaughtUnstaged blocker ->
          v
            ADeferred
              { op = work.op
              , incarnation = work.incarnation
              , head = work.head
              , base = work.base
              , policy = work.policy
              , strictBase = work.strictBase
              , baseCurrent = work.baseCurrent
              , blocker
              }
        CaughtBoundary _ -> blocked
        CaughtRerunRefused reason -> fault reason
        CaughtFault reason -> fault reason
  pure $ case outcome of
    Left terminal -> terminal
    Right result -> case unproven held result of
      UnprovenBlocked -> blocked
      UnprovenFault reason -> fault reason
      Proven -> landed

-- ---------------------------------------------------------------------------
-- findings publish: full claim fence, one identity per finding

-- | @_finding_operation(op, finding)@: the round operation plus the
-- finding's own id, or its digest when the marker grammar cannot carry it.
findingOperation :: Text -> Object -> Text
findingOperation op finding =
  let identifier = Py.str (fromMaybe (String "") (lookup "id" finding))
      candidate = op <> ":" <> identifier
   in if markerOperation candidate then candidate else op <> ":" <> T.take 16 (sha256HexText identifier)

getJ :: Text -> Object -> Json
getJ key = fromMaybe Null . lookup key

-- | @int(value)@, raising the reference's exception.
pyInt :: Json -> IO Integer
pyInt = \case
  Int i -> pure i
  Bool b -> pure (if b then 1 else 0)
  Float d
    | isNaN d -> throwIO (ValueError "cannot convert float NaN to integer")
    | isInfinite d -> throwIO (PythonException "OverflowError" [])
    | otherwise -> pure (truncate d)
  String s -> maybe (throwIO (ValueError ("invalid literal for int() with base 10: " <> pythonStrRepr s))) pure (Py.pyIntBase 10 s)
  other -> throwIO (TypeError ("int() argument must be a string, a bytes-like object or a real number, not '" <> jsonTypeName other <> "'"))

-- | @_finding_arguments(finding)@ as a publication of @operation@ and
-- @text@.
findingPublication :: Text -> Object -> IO FindingPublication
findingPublication operation finding = do
  items <- case lookup "related_locations" finding of
    Nothing -> pure []
    Just (Array xs) -> pure xs
    Just (String s) -> pure (map (String . T.singleton) (T.unpack s))
    Just (Object members) -> pure (map (String . fst) members)
    Just other -> throwIO (TypeError ("'" <> jsonTypeName other <> "' object is not iterable"))
  related <-
    fmap concat . forM items $ \case
      Object item
        | Py.truthy (getJ "path" item) && Py.truthy (getJ "line" item) -> do
            line <- pyInt (getJ "line" item)
            pure [(Py.str (getJ "path" item), line)]
      _ -> pure []
  let path = getJ "path" finding
  line <- pyInt (orZero (getJ "line" finding))
  pure
    FindingPublication
      { operation
      , text = Py.str (fromMaybe (String "") (lookup "body" finding))
      , path = Py.str (if Py.truthy path then path else String "")
      , line
      , relatedLocations = related
      , suggestion = Py.str (let s = getJ "suggestion" finding in if Py.truthy s then s else String "")
      , link = ""
      }
  where
    orZero value = if Py.truthy value then value else Int 0

anchored :: Object -> Bool
anchored finding = Py.truthy (getJ "path" finding) && Py.truthy (getJ "line" finding)

failureClassOf :: FailureClass -> ProviderFailureClass
failureClassOf = \case
  TransportAmbiguity -> FailureTransportAmbiguity
  TransientHttpRejection -> FailureTransientHttpRejection
  CapabilityDenial -> FailureCapabilityDenial
  PayloadRejection -> FailurePayloadRejection
  ProviderRejection -> FailureProviderRejection

publishGate :: V5PublicationGates -> Publishable -> IO Variant
publishGate g work = do
  let expected = CurrentClaim PhaseRunning work.incarnation work.head work.base work.policy
      landed = v ReviewLanded {head = work.head, incarnation = work.incarnation, findings = work.findings, effect = work.effect, mem = work.mem}
      blocked failure status detail =
        v
          ReviewBlocked
            { head = work.head
            , base = work.base
            , policy = work.policy
            , incarnation = work.incarnation
            , findings = work.findings
            , effect = work.effect
            , op = work.op
            , failureClass = failure
            , providerStatus = status
            , providerDetail = detail
            , mem = work.mem
            }
      denied = blocked FailureCapabilityDenial Nothing "none"
      fault reason = v ReviewFault {reason, mem = work.mem}
      firstUnproven = \case
        [] -> Nothing
        result : rest -> case unproven held result of
          Proven -> firstUnproven rest
          UnprovenBlocked -> Just denied
          UnprovenFault reason -> Just (fault reason)
      plain = \case
        [] -> pure Nothing
        finding : rest -> do
          publication <- findingPublication (findingOperation work.op finding) finding
          result <- g.publisher.finding publication work.incarnation work.head (Just work.op)
          case firstUnproven [result] of
            Just terminal -> pure (Just terminal)
            Nothing -> plain rest
      resolve = mapM_ (\r -> void (r work.head)) g.resolveStaleThreads
      body = do
        pending <-
          fmap concat . forM work.findings $ \finding -> do
            found <- g.publisher.findingFind (findingOperation work.op finding) work.head
            pure [finding | Nothing <- [found]]
        let clearing = null work.findings && maybe False (const True) g.resolveStaleThreads
        if null pending && not clearing
          then pure landed
          else do
            current <- g.claim
            if current /= expected
              then do
                let phase = current.phase
                pure $
                  v
                    ReviewMoved
                      { head = work.head
                      , observed = current.head
                      , observedBase = current.base
                      , observedPolicy = current.policy
                      , observedIncarnation = current.incarnation
                      , observedPhase = phase
                      , findings = work.findings
                      , mem = work.mem
                      }
              else
                if null pending
                  then resolve >> pure landed
                  else do
                    batch <-
                      forM [f | f <- pending, anchored f] $ \finding ->
                        findingPublication (findingOperation work.op finding) finding
                    results <- if null batch then pure [] else g.publisher.findings work.incarnation work.head batch work.op
                    case firstUnproven results of
                      Just terminal -> pure terminal
                      Nothing -> do
                        stopped <- plain [f | f <- pending, not (anchored f)]
                        case stopped of
                          Just terminal -> pure terminal
                          Nothing -> resolve >> pure landed
  catchGate body $
    pure . \case
      CaughtUnstaged blocker ->
        v
          PublicationDeferred
            { operation = work.op
            , head = work.head
            , base = work.base
            , policy = work.policy
            , incarnation = work.incarnation
            , findings = work.findings
            , effect = work.effect
            , mem = work.mem
            , attempt = 1
            , blocker
            }
      CaughtBoundary e -> blocked (failureClassOf e.failureClass) (fromIntegral <$> e.providerStatus) e.providerDetail
      CaughtRerunRefused reason -> fault reason
      CaughtFault reason -> fault reason

-- ---------------------------------------------------------------------------
-- dashboard: unfenced idempotent upsert, digest identity

dashGate :: V5PublicationGates -> DashReq -> IO Variant
dashGate g work = do
  phase <- g.dashboardPhase
  let blocked = v DashBlocked {entries = work.entries, digest = work.digest, desiredEntries = work.desiredEntries, desiredDigest = work.desiredDigest}
      fault reason =
        v DashFault {entries = work.entries, digest = work.digest, desiredEntries = work.desiredEntries, desiredDigest = work.desiredDigest, reason}
  if phase == PhaseQuiescent
    then
      pure $
        v
          DashDeferred
            { entries = work.entries
            , digest = work.digest
            , desiredEntries = work.desiredEntries
            , desiredDigest = work.desiredDigest
            , landed = work.landed
            , blocked = work.blocked
            , faulted = work.faulted
            }
    else do
      board <- either raisePython pure (renderBoard work.entries)
      outcome <-
        catchGate
          (Right <$> g.publisher.dashboard ("dash:" <> work.digest) 0 (T.replicate 40 "0") board)
          ( pure . Left . \case
              CaughtUnstaged _ -> blocked
              CaughtBoundary _ -> blocked
              CaughtRerunRefused reason -> fault reason
              CaughtFault reason -> fault reason
          )
      pure $ case outcome of
        Left terminal -> terminal
        Right result -> case unproven dashHeld result of
          UnprovenBlocked -> blocked
          UnprovenFault reason -> fault reason
          Proven -> v DashLanded {entries = work.entries, digest = work.digest, desiredEntries = work.desiredEntries, desiredDigest = work.desiredDigest}
