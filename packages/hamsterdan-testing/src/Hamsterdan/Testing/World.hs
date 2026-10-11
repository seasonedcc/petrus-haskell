{-# LANGUAGE MultiWayIf #-}

-- | Deterministic external world around the real non-sharded V5 host
-- (@host/testing/readiness_world.py@).
--
-- Petrus DST ("Petrus.Testing.Dst") owns scheduling, crash generations,
-- checker cadence and strict replay. This module owns only Hamsterdan's
-- commands, the modeled provider truth ("Hamsterdan.Testing.World.Provider"),
-- detached observations, and the independent readiness comparison.
--
-- Every command result, observation and checker verdict is the
-- reference's JSON, so an artifact this World writes replays in the
-- reference's World with the same verdict and result bytes, and the
-- reverse.
module Hamsterdan.Testing.World
  ( -- * The profile
    ReadinessProfile (..)
  , Generation (..)
  , newReadinessProfile
  , readinessProfile
  , profileResourceUsage
  , droppedGenerationsAlive

    -- * The checker
  , readinessChecker
  , checkReadiness
  , stateRequest

    -- * The World
  , ReadinessWorld (..)
  , newReadinessWorld
  , newReadinessWorldWith
  , inWorld
  , timeline
  , restart
  , artifact
  , closeWorld

    -- * The Timeline facade
  , ReadinessTimeline (..)
  , command
  , pending
  , step
  , setPullRequest
  , PullRequest (..)
  , activePullRequest
  , setCi
  , setReview
  , setHumanComment
  , setAgentTerminal
  , emitWebhook
  , deliverWebhook
  , loseEffectResponse
  , faultEffect
  , faultGitPublication
  , advanceTime
  , revealEffect
  , observe
  , runUntil
  , crash
  , beginFair
  , converge

    -- * Replay
  , replayReadiness

    -- * JSON access
  , (.:)
  , deliveryUuid
  ) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (get, put)
import Control.Monad.Trans.Class (lift)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isHexDigit)
import Data.Foldable (toList)
import Data.IORef
import Data.List (find, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, mapMaybe)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Models (InstallationInventory (..))
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.GitHub.Webhooks (Receipt (..), WebhookRejected (..), dispositionName, sign)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agenticus (activateRoutes, claimRoute, closeRoutes, composeAgent, openAgentRouteStore, settleRoutes)
import Hamsterdan.Host.Python (isPythonException, mkdirPrivate)
import Hamsterdan.Host.Service
  ( AgentCustody (..)
  , CustodyOneResult (..)
  , HostService (..)
  , ServiceHooks
  , ServiceOptions (..)
  , openHostService
  , serviceOptions
  , v5ApplicationFactory
  )
import Hamsterdan.Host.Service qualified as Host
import Hamsterdan.Host.V5.Application (ApplicationOptions (..))
import Hamsterdan.Testing.Readiness (AuthorityClaim (..), Lifecycle (..), ReadinessExpectation, ReadinessFacts, dump, evaluate, loadJson)
import Hamsterdan.Testing.World.Contract
import Hamsterdan.Testing.World.Provider hiding (setHumanComment)
import Hamsterdan.Testing.World.Provider qualified as Provider
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Testing.Dst
  ( ActionDisposition (..)
  , AnyArtifact
  , AnyReplayResult
  , ApplyResult (..)
  , AuthoredDisposition (..)
  , BudgetV4
  , CheckResult (..)
  , Checker (..)
  , Command (..)
  , Door
  , DstFailure (..)
  , ExecuteOperation (..)
  , Fault (..)
  , FaultDisposition (..)
  , GenerationStart (..)
  , Observation (..)
  , ObservationRequest (..)
  , Profile (..)
  , ProfileError (..)
  , ResourceUsage (..)
  , Scenario (..)
  , ScenarioContext (..)
  , ScheduledCommand (..)
  , SomeBudget (..)
  , World
  , WorldConfig (..)
  , WorldT
  , emptyRegistry
  , raise
  , registerChecker
  , registerProfile
  , replay
  )
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getFileSize, listDirectory)
import System.FilePath (makeRelative, takeExtension, (</>))
import System.Mem (performMajorGC)
import System.Mem.Weak (Weak, deRefWeak)
import Text.Printf (printf)

-- ---------------------------------------------------------------------------
-- JSON access

-- | @value.get(key)@: the member, or @null@.
(.:) :: Json -> Text -> Json
value .: key = fromMaybe Null (lookupMember key value)

infixl 9 .:

int :: Integer -> Json
int = Int

str :: Json -> Maybe Text
str = \case
  String s -> Just s
  _ -> Nothing

intOf :: Json -> Maybe Integer
intOf = \case
  Int i -> Just i
  _ -> Nothing

arr :: Json -> [Json]
arr = \case
  Array xs -> xs
  _ -> []

isObject :: Json -> Bool
isObject = \case
  Object _ -> True
  _ -> False

showT :: (Show a) => a -> Text
showT = T.pack . show

-- | @str(uuid.UUID(int=n))@.
deliveryUuid :: Integer -> Text
deliveryUuid n =
  let hex = printf "%032x" n :: String
      (a, r1) = splitAt 8 hex
      (b, r2) = splitAt 4 r1
      (c, r3) = splitAt 4 r2
      (d, e) = splitAt 4 r3
   in T.pack (a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e)

-- | Whether @uuid.UUID(value)@ accepts a string.
validUuid :: Text -> Bool
validUuid value =
  let stripped = T.replace "uuid:" "" (T.replace "urn:" "" value)
      hex = T.replace "-" "" (T.dropAround (`elem` ("{}" :: String)) stripped)
   in T.length hex == 32 && T.all isHexDigit hex

-- ---------------------------------------------------------------------------
-- The profile

-- | @ReadinessScenarioProfile(root)@: the profile-owned state the
-- reference keeps on @self@, which outlives every generation.
data ReadinessProfile = ReadinessProfile
  { root :: FilePath
  , truth :: TruthRef
  , dropped :: IORef [Weak (IORef (Set (Text, Integer)))]
  , hostFollowups :: IORef Integer
  , instant :: IORef Integer
  -- ^ The World's instant as the last door saw it: the host's clock
  -- (@clock=lambda: float(context.now())@).
  , hostHooks :: IORef (Maybe ServiceHooks)
  -- ^ Test seam: hooks every new host generation installs (the
  -- reference's tests monkeypatch @HostService@ methods).
  }

-- | One opaque real host generation (@_Generation@).
data Generation = Generation
  { host :: HostService
  , context :: ContextHolder
  , proposed :: IORef (Set (Text, Integer))
  }

newReadinessProfile :: FilePath -> IO ReadinessProfile
newReadinessProfile root =
  ReadinessProfile root <$> newTruth <*> newIORef [] <*> newIORef 0 <*> newIORef 0 <*> newIORef Nothing

-- | @dropped_generations_alive()@.
droppedGenerationsAlive :: ReadinessProfile -> IO Int
droppedGenerationsAlive p = do
  performMajorGC
  weaks <- readIORef p.dropped
  length . filter isJust <$> mapM deRefWeak weaks

toProfileError :: PyError -> ProfileError
toProfileError (PyError cls message) = ProfileError cls message

-- | Run an IO body as a profile door: exceptions become the reference
-- class and message, and (with a holder) the World's context is held for
-- the adapters while the body runs.
contextDoor :: ReadinessProfile -> Maybe ContextHolder -> (Integer -> IO a) -> Scenario IO a
contextDoor p holder body = do
  context <- Scenario (lift get)
  liftIO (writeIORef p.instant context.instant)
  forM_ holder $ \h -> liftIO (writeIORef h (Just context))
  result <- liftIO (try @SomeException (body context.instant))
  forM_ holder $ \h -> do
    held <- liftIO (readIORef h)
    liftIO (writeIORef h Nothing)
    Scenario (lift (put (fromMaybe context held)))
  case result of
    Right value -> pure value
    Left e -> let (cls, message) = pyException e in raise cls message

plainDoor :: IO a -> ExceptTDoor a
plainDoor body = do
  result <- liftIO (try @SomeException body)
  case result of
    Right value -> pure value
    Left e -> let (cls, message) = pyException e in throwError (ProfileError cls message)

type ExceptTDoor a = Door IO a

-- | The profile over this state.
readinessProfile :: ReadinessProfile -> Profile IO Generation
readinessProfile p =
  Profile
    { identity = profileIdentity
    , validate = \c -> either (throwError . toProfileError) pure (validateCommand c)
    , validateFault = \f -> either (throwError . toProfileError) pure (validateFault f)
    , create = start p
    , load = start p
    , apply = applyCommand p
    , observe = \g request' -> do
        unless (request'.name == "readiness.state" && (request'.payload == Null || request'.payload == Object [])) $
          raise "ValueError" "readiness profile exposes only readiness.state without parameters"
        contextDoor p Nothing (readinessState p g)
    , dropGeneration = \g -> plainDoor $ do
        weak <- mkWeakIORef' g.proposed
        modifyIORef' p.dropped (<> [weak])
        Host.abort g.host
    , closeGeneration = \g -> plainDoor (Host.close g.host)
    , resourceUsage = Just (plainDoor . profileResourceUsage p)
    }
  where
    mkWeakIORef' ref = Data.IORef.mkWeakIORef ref (pure ())

-- | @validate(command)@.
validateCommand :: Command -> Either PyError Command
validateCommand c = do
  keys <- maybe (Left (PyError "ValueError" ("unknown readiness command " <> pyRepr c.name))) Right (Map.lookup c.name commandKeys)
  _ <- boundedJson c.payload (profileLimit "payload_bytes") c.name
  payload <- strictObject c.payload keys c.name
  let field k = fromMaybe Null (lookup k payload)
      name = c.name
      fails = Left . PyError "ValueError"
  when
    ( Set.notMember name hostCommands
        && name /= "readiness.time.advance"
        && name /= "readiness.github.webhook.deliver"
        && field "subject" /= String subject
    )
    $ fails "readiness command subject is outside this profile"
  if
    | name == "readiness.github.pr.set" -> do
        claim <- parseAuthority (field "authority")
        _ <- boundedText (String claim.head) "pull request head" (Just isSha)
        _ <- boundedText (String claim.base) "pull request base" (Just isSha)
        _ <- boundedText (String claim.policy) "pull request policy" (Just isPolicy)
        pure ()
    | name == "readiness.github.ci.set" -> do
        _ <- boundedText (field "head") "CI head" (Just isSha)
        required <- case field "required_checks" of
          Array xs | toInteger (length xs) <= profileLimit "checks" -> pure xs
          _ -> fails "required_checks must be a bounded list"
        names <- mapM (\x -> boundedText x "required check" (Just isName)) required
        when (Set.size (Set.fromList names) /= length names) $ fails "required_checks must be unique"
        items <- case field "checks" of
          Array xs | toInteger (length xs) <= profileLimit "checks" -> pure xs
          _ -> fails "checks must be a bounded list"
        forM_ items $ \item -> do
          check <- strictObject item (Set.fromList ["name", "run", "attempt", "status"]) name
          let at k = fromMaybe Null (lookup k check)
          _ <- boundedText (at "name") "check name" (Just isName)
          case (at "run", at "attempt") of
            (Int r, Int a) | r > 0 && a > 0 -> pure ()
            _ -> fails "check run and attempt must be positive integers"
          unless (at "status" `elem` map String ["queued", "running", "success", "failure", "canceled", "unavailable"]) $
            fails "unsupported CI status"
    | name == "readiness.github.review.set" -> do
        _ <- boundedText (field "head") "review head" (Just isSha)
        unless (field "status" `elem` map String ["pending", "clear", "blocking", "unable"]) $ fails "unsupported review status"
        case field "findings" of
          Array xs | toInteger (length xs) <= profileLimit "findings" -> pure ()
          _ -> fails "review findings must be a bounded list"
    | name == "readiness.github.human.review" -> do
        _ <- boundedText (field "reviewer") "reviewer" (Just isName)
        _ <- boundedText (field "head") "human review head" (Just isSha)
        case field "review" of
          Int r | r > 0 -> pure ()
          _ -> fails "human review identity must be positive"
        unless (field "state" `elem` map String ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]) $ fails "unsupported human review state"
    | name == "readiness.github.human.resolve_thread" -> do
        _ <- boundedText (field "thread") "review thread" (Just isName)
        _ <- boundedText (field "resolver") "thread resolver" (Just isName)
        case field "resolved" of
          Bool _ -> pure ()
          _ -> fails "thread resolution must be boolean"
    | name == "readiness.github.human.comment" -> do
        case field "comment" of
          Int i | i > 0 -> pure ()
          _ -> fails "comment identity must be positive"
        _ <- boundedText (field "author") "comment author" (Just isName)
        fixture <- boundedText (field "fixture") "comment fixture" (Just isName)
        unless (fixture == "change" || "recover:" `T.isPrefixOf` fixture) $ fails "unsupported human comment fixture"
        forM_ (T.stripPrefix "recover:" fixture) $ \operation ->
          boundedText (String operation) "recovery operation" (Just isOperation)
        when (field "digest" /= String (strictDigest (Object [("fixture", String fixture)]))) $
          fails "comment fixture digest does not match"
    | name == "readiness.agent.terminal" -> do
        _ <- boundedText (field "operation") "agent operation" (Just isOperation)
        case field "attempt" of
          Int a | a > 0 -> pure ()
          _ -> fails "agent attempt must be positive"
        unless (field "status" `elem` map String ["clear", "blocking", "unable", "changed", "unchanged"]) $
          fails "unsupported agent terminal status"
        fixture <- boundedText (field "fixture") "agent fixture" (Just isName)
        unless (fixture `elem` ["review", "conversation_change", "conversation_recover", "coding"]) $ fails "unsupported agent fixture"
        when (field "digest" /= String (strictDigest (Object [("fixture", String fixture), ("status", field "status")]))) $
          fails "agent fixture digest does not match"
    | name == "readiness.github.webhook.emit" -> do
        exactUuid (field "delivery")
        event <- boundedText (field "event") "webhook event" (Just isName)
        unless (Set.member event events) $ fails "unsupported webhook event"
        fixture <- boundedText (field "fixture") "webhook fixture" Nothing
        unless
          ( (event <> ":") `T.isPrefixOf` fixture
              && field "digest" == String (strictDigest (Object [("event", String event), ("fixture", String fixture)]))
          )
          $ fails "webhook fixture digest does not match"
    | name == "readiness.github.webhook.deliver" -> exactUuid (field "delivery")
    | name == "readiness.github.effect.reveal" -> () <$ boundedText (field "operation") "effect operation" (Just isName)
    | name == "readiness.time.advance" -> case field "seconds" of
        Int s | 0 < s && s <= 2000000 -> pure ()
        _ -> fails "logical time advance is outside the profile bound"
    | otherwise -> pure ()
  pure c
  where
    exactUuid = \case
      String s | validUuid s -> Right ()
      _ -> Left (PyError "ValueError" "webhook delivery must be an exact UUID")

pyRepr :: Text -> Text
pyRepr t = "'" <> t <> "'"

-- | @parse_authority(value)@.
parseAuthority :: Json -> Either PyError AuthorityClaim
parseAuthority value = either (Left . PyError "ValidationError") Right (loadJson value)

-- | @validate_fault(fault)@.
validateFault :: Fault -> Either PyError Fault
validateFault f = do
  _ <- boundedJson f.payload 4096 f.name
  let fails = Left . PyError "ValueError"
  if f.name == "readiness.git.publish"
    then do
      unless ("git:" `T.isPrefixOf` f.target && f.disposition == Raise) $ fails "unsupported readiness Git publication fault"
      _ <- boundedText (String (T.drop 4 f.target)) "Git publication operation" (Just isOperation)
      payload <- strictObject f.payload (Set.fromList ["cut"]) f.name
      unless (lookup "cut" payload == Just (String "ref_cas")) $ fails "unsupported readiness Git publication cut"
      pure f
    else do
      unless (f.name == "readiness.github.effect" && "effect:" `T.isPrefixOf` f.target && f.disposition == Raise) $
        fails "unsupported readiness fault"
      unless (Set.member (T.drop 7 f.target) effectKinds) $ fails "unsupported readiness effect target"
      payload <- strictObject f.payload (Set.fromList ["cut"]) f.name
      unless
        ( lookup "cut" payload
            `elem` map
              (Just . String)
              ["before_acceptance", "after_acceptance_before_response", "before_visibility", "identity_collision"]
        )
        $ fails "unsupported readiness effect cut"
      pure f

-- | @_config(root)@.
config :: FilePath -> HostConfig
config root =
  HostConfig
    { appId = 17
    , appSlug = "hamsterdan-test"
    , clientId
    , accounts = [AccountConfig 23 "Owner" [(31, "owner/repo")]]
    , statePath = root
    , watchedAuthors = mempty
    , privateKey = secret privateKey
    , webhookSecret = secret webhookSecret
    }

-- | @create@ / @load@: one real host generation (@_start@).
start :: ReadinessProfile -> Scenario IO (GenerationStart Generation)
start p = do
  generation <- contextDoor p Nothing $ \_ -> do
    createDirectoryIfMissing True p.root
    mkdirPrivate p.root
    agent <- composeAgent Nothing Nothing Nothing
    store <- openAgentRouteStore (p.root </> "agent-routes.sqlite3")
    activateRoutes store agent (p.root </> "applications")
    holder <- newContextHolder
    let custody =
          AgentCustody
            { claim = \operation -> () <$ claimRoute store operation agent
            , settleOperations = settleRoutes store . Set.toList
            , close = closeRoutes store
            }
        factory root' instanceId authority runner options =
          v5ApplicationFactory root' instanceId authority runner options {mutationPublisher = Just (modeledGitPublisher p.truth holder)}
    host <-
      openHostService
        (config p.root)
        (serviceOptions (agentRunner p.truth) custody)
          { clients = Just (providerClients (providerTransport p.truth holder))
          , applicationFactory = factory
          , reminderDelay = fromInteger reminderDelay
          , clock = Just (fromInteger <$> readIORef p.instant)
          }
    readIORef p.hostHooks >>= mapM_ (writeIORef host.hooks)
    _ <- Routing.reconcile host.registry [InstallationInventory 44 23 [(31, "owner/repo")]]
    proposed <- newIORef Set.empty
    pure Generation {host, context = holder, proposed}
  scheduled <- contextDoor p Nothing (followups p generation)
  pure GenerationStart {generation, scheduled}

hostCommand :: Text -> Command
hostCommand name = Command {profile = profileIdentity, name, payload = Object []}

-- | @apply(generation, command, context)@.
applyCommand :: ReadinessProfile -> Generation -> Command -> Scenario IO ApplyResult
applyCommand p g c = contextDoor p (Just g.context) $ \now -> do
  modifyIORef' g.proposed (Set.delete (c.name, now))
  when (Set.notMember c.name hostCommands && c.name /= "readiness.time.advance") $
    modifyIORef' p.truth (\t -> t {providerTruthChanges = t.providerTruthChanges + 1})
  (value, disposition) <- applyOne p g c now
  errors <- (.harnessErrors) <$> readIORef p.truth
  unless (null errors) $ throwPy "AssertionError" (last errors)
  scheduled <- followups p g now
  extra <-
    if c.name == "readiness.time.advance"
      then do
        let target = now + fromMaybe 0 (intOf (c.payload .: "seconds"))
            proposal = ("readiness.host.drive_one", target)
        seen <- Set.member proposal <$> readIORef g.proposed
        if seen
          then pure []
          else do
            modifyIORef' g.proposed (Set.insert proposal)
            modifyIORef' p.hostFollowups (+ 1)
            pure [ScheduledCommand {instant = target, command = hostCommand "readiness.host.drive_one"}]
      else pure []
  pure ApplyResult {disposition, value, scheduled = scheduled <> extra}

-- | @_apply(generation, command, context)@.
applyOne :: ReadinessProfile -> Generation -> Command -> Integer -> IO (Json, ActionDisposition)
applyOne p g c now = do
  let payload = c.payload
      field k = payload .: k
      ref = p.truth
  if
    | c.name == "readiness.github.pr.set" -> do
        claim <- either (\(PyError cls m) -> throwPy cls m) pure (parseAuthority (field "authority"))
        t <- readIORef ref
        let disposition = if claim == t.authority then Idempotent else Applied
        setAuthority ref claim
        pure (Object [("authority", dump claim)], disposition)
    | c.name == "readiness.github.ci.set" -> do
        required <- case field "required_checks" of
          Array xs | all (\x -> maybe False (not . T.null) (str x)) xs -> pure (mapMaybe str xs)
          _ -> throwPy "ValueError" "required_checks must be bounded names"
        items <- case field "checks" of
          Array xs -> pure xs
          _ -> throwPy "ValueError" "checks must be a list"
        normalized <- forM items $ \item -> do
          value <- either (\(PyError cls m) -> throwPy cls m) (pure . Object) (strictObject item (Set.fromList ["name", "run", "attempt", "status"]) c.name)
          unless (value .: "status" `elem` map String ["queued", "running", "success", "failure", "canceled", "unavailable"]) $
            throwPy "ValueError" "unsupported CI status"
          pure value
        modifyIORef' ref (\t -> t {requiredChecks = required, checks = normalized, reviewHead = fromMaybe "" (str (field "head"))})
        pure (Object [("checks", int (toInteger (length normalized)))], Applied)
    | c.name == "readiness.github.review.set" -> do
        found <- case field "findings" of
          Array xs -> pure xs
          _ -> throwPy "ValueError" "review findings must be a list"
        let status = field "status"
        unless (status `elem` map String ["pending", "clear", "blocking", "unable"]) $ throwPy "ValueError" "unsupported review status"
        modifyIORef' ref $ \t ->
          t
            { reviewHead = fromMaybe "" (str (field "head"))
            , reviewStatus = fromMaybe "" (str status)
            , findings = found
            , reviewTerminal = Just (Object [("kind", String "review"), ("status", status), ("findings", Array found)])
            }
        pure (Object [("status", status), ("findings", int (toInteger (length found)))], Applied)
    | c.name == "readiness.github.human.review" -> do
        let reviewer = fromMaybe "" (str (field "reviewer"))
            state = field "state"
        unless (state `elem` map String ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]) $ throwPy "ValueError" "unsupported human review state"
        modifyIORef' ref (\t -> t {humanReviews = Map.insert reviewer (T.pack (printf "%020d" now), fromMaybe "" (str state)) t.humanReviews})
        pure (Object [("reviewer", String reviewer), ("state", state)], Applied)
    | c.name == "readiness.github.human.resolve_thread" -> do
        let resolved = field "resolved" == Bool True
        modifyIORef' ref (\t -> t {reviewThreads = Map.insert (fromMaybe "" (str (field "thread"))) resolved t.reviewThreads})
        pure (Object [("thread", field "thread"), ("resolved", field "resolved")], Applied)
    | c.name == "readiness.github.human.comment" -> do
        Provider.setHumanComment ref (fromMaybe 0 (intOf (field "comment"))) (fromMaybe "" (str (field "author"))) (fromMaybe "" (str (field "fixture")))
        pure (Object [("comment", field "comment")], Applied)
    | c.name == "readiness.agent.terminal" -> do
        let operation = fromMaybe "" (str (field "operation"))
        modifyIORef' ref $ \t ->
          t
            { agentTerminals =
                Map.insert
                  operation
                  ( Object
                      [ ("kind", field "fixture")
                      , ("operation", String operation)
                      , ("attempt", field "attempt")
                      , ("status", field "status")
                      , ("findings", Array [])
                      ]
                  )
                  t.agentTerminals
            }
        pure (Object [("operation", field "operation"), ("status", field "status")], Applied)
    | c.name == "readiness.github.webhook.emit" -> do
        let delivery = fromMaybe "" (str (field "delivery"))
            event = fromMaybe "" (str (field "event"))
            fixture = fromMaybe "" (str (field "fixture"))
        when (field "digest" /= String (strictDigest (Object [("event", String event), ("fixture", String fixture)]))) $
          throwPy "ValueError" "webhook fixture digest does not match"
        t <- readIORef ref
        let action = T.drop 1 (snd (T.breakOn ":" fixture))
            comment = if event == "issue_comment" && not (null t.humanComments) then Just (last t.humanComments) else Nothing
            new = emitted delivery event action t.authority comment
        case Map.lookup delivery t.emittedDeliveries of
          Just existing
            | existing /= new -> pure (Object [("delivery", String delivery)], ActionQuarantined)
            | otherwise -> pure (Object [("delivery", String delivery)], Idempotent)
          Nothing -> do
            writeIORef ref t {emittedDeliveries = Map.insert delivery new t.emittedDeliveries}
            pure (Object [("delivery", String delivery)], Applied)
    | c.name == "readiness.github.webhook.deliver" -> do
        let delivery = fromMaybe "" (str (field "delivery"))
        t <- readIORef ref
        event <- maybe (throwPy "ValueError" "cannot deliver an unknown webhook") pure (Map.lookup delivery t.emittedDeliveries)
        let body = webhookBody event
            headers =
              [ ("content-type", "application/json")
              , ("content-length", showT (BS.length body))
              , ("x-hub-signature-256", sign webhookSecret body)
              , ("x-github-delivery", delivery)
              , ("x-github-event", event.event)
              ]
        outcome <- try @SomeException (Custody.receive g.host.custody headers body)
        modifyIORef' ref (\u -> u {deliveryAttempts = Map.insertWith (+) delivery 1 u.deliveryAttempts})
        receipt <- case outcome of
          Right receipt -> pure receipt
          Left e
            | Just (WebhookRejected _) <- fromException' e -> refused (400 :: Int)
            | isPythonException e -> refused (500 :: Int)
            | otherwise -> throwIO e
        let disposition = dispositionName receipt.disposition
        when (disposition /= "duplicate") $
          modifyIORef' ref (\u -> if delivery `elem` u.custodied then u else u {custodied = u.custodied <> [delivery]})
        pure
          ( Object [("delivery", String delivery), ("disposition", String disposition)]
          , if disposition == "duplicate" then Idempotent else Applied
          )
    | c.name == "readiness.github.effect.reveal" -> do
        let operation = fromMaybe "" (str (field "operation"))
        t <- readIORef ref
        case break (\e -> e.operation == operation) t.effects of
          (_, []) -> pure (Object [("operation", String operation)], RefusedExpected)
          (before, e : after) -> do
            writeIORef ref t {effects = before <> (e {visible = True} : after)}
            pure (Object [("operation", String operation)], Applied)
    | c.name == "readiness.time.advance" -> case field "seconds" of
        Int s | 0 < s && s <= 2000000 -> pure (Object [("target", int (now + s))], Applied)
        _ -> throwPy "ValueError" "logical time advance must be an integer from 1 through 2000000 seconds"
    | c.name == "readiness.host.custody_one" -> do
        t <- readIORef ref
        let admittedDeliveries = Set.fromList [e.delivery | e <- t.admitted]
            candidate =
              listToMaybe'
                [ e
                | d <- t.custodied
                , Set.notMember d admittedDeliveries
                , Just e <- [Map.lookup d t.emittedDeliveries]
                ]
            admission = t.authority
        writeIORef ref t {activeAdmission = candidate}
        observed <- Host.processOne g.host `onFailure` modifyIORef' ref (\u -> u {activeAdmission = Nothing})
        modifyIORef' ref (\u -> u {activeAdmission = Nothing})
        let expected = maybe Null (\e -> Object [("delivery", String e.delivery), ("disposition", String "completed")]) candidate
            observedValue = maybe Null (\o -> Object [("delivery", String o.deliveryId), ("disposition", String o.disposition)]) observed
        forM_ candidate $ \e -> when (observedValue == expected) $ admit ref e now (Just admission)
        modifyIORef' ref (\u -> u {custodyActions = u.custodyActions <> [Object [("expected", expected), ("observed", observedValue)]]})
        pure (Object [("custody", observedValue)], if isJust observed then Applied else RefusedExpected)
    | c.name == "readiness.host.activity_one" -> do
        bindReadinessEffectAuthorities p
        processed <- Host.runOneActivity g.host
        pure (Object [("processed", int (toInteger processed))], if processed /= 0 then Applied else RefusedExpected)
    | c.name == "readiness.host.drive_one" -> do
        processed <- Host.runDue g.host 1
        pure (Object [("processed", int (toInteger processed))], if processed /= 0 then Applied else RefusedExpected)
    | c.name == "readiness.host.reconcile_one" -> do
        processed <- Host.reconcileOne g.host "dst"
        t <- readIORef ref
        when (processed && (null t.admitted || (last t.admitted).authority /= t.authority)) $ do
          let identity = "github-reconcile:" <> showT (length t.admitted + 1)
          admit
            ref
            (emitted identity "reconciliation" "provider_snapshot" t.authority Nothing) {sourceIdentity = identity}
            now
            (Just t.authority)
        pure (Object [("processed", Bool processed)], if processed then Applied else RefusedExpected)
    | otherwise -> throwPy "AssertionError" ("validated command has no readiness implementation: " <> c.name)
  where
    refused status = throwPy "AssertionError" ("real webhook ingress refused safe fixture with status " <> showT status)
    listToMaybe' = \case
      x : _ -> Just x
      [] -> Nothing
    onFailure action cleanup = do
      result <- try @SomeException action
      either (\e -> cleanup >> throwIO e) pure result

fromException' :: SomeException -> Maybe WebhookRejected
fromException' = fromException

-- | @_followups(generation, context)@.
followups :: ReadinessProfile -> Generation -> Integer -> IO [ScheduledCommand]
followups p g now = do
  state <- Host.workState g.host
  let due = case state .: "runnable_due" of
        Float d -> Just (ceiling d :: Integer)
        Int i -> Just i
        _ -> Nothing
  activity <-
    if state .: "unresolved_activity" == Bool True
      then activityTerminalReady p
      else pure False
  let candidates =
        [ ("readiness.host.custody_one", state .: "pending_custody" == Bool True)
        , ("readiness.host.reconcile_one", state .: "unloaded_application" == Bool True)
        , ("readiness.host.drive_one", maybe False (<= now) due)
        , ("readiness.host.activity_one", activity)
        ]
  fmap catMaybes . forM candidates $ \(name, eligible) -> do
    seen <- Set.member (name, now) <$> readIORef g.proposed
    if not eligible || seen
      then pure Nothing
      else do
        modifyIORef' g.proposed (Set.insert (name, now))
        modifyIORef' p.hostFollowups (+ 1)
        pure (Just ScheduledCommand {instant = now, command = hostCommand name})

terminalRecords :: Set Text
terminalRecords = Set.fromList ["ActivityCompleted", "ActivityFailed", "ActivityTerminalQuarantined"]

recordKind :: Json -> Maybe Text
recordKind r = str (r .: "record")

-- | @_activity_terminal_ready()@.
activityTerminalReady :: ReadinessProfile -> IO Bool
activityTerminalReady p = do
  records <- historyRecords p.root
  t <- readIORef p.truth
  let terminal = [r .: "occurrence" | r <- records, maybe False (`Set.member` terminalRecords) (recordKind r)]
      outstanding = find (\r -> recordKind r == Just "ActivityRequested" && (r .: "occurrence") `notElem` terminal) records
  case outstanding of
    Nothing -> pure False
    Just requested
      | requested .: "activity" == String "review_agent" ->
          pure (maybe False (\v -> v .: "kind" == String "review") t.reviewTerminal)
      | requested .: "activity" /= String "git_gate" -> pure True
      | otherwise -> do
          let work = if isObject (requested .: "input") then requested .: "input" .: "work" else Null
              opKey = if isObject work then str (work .: "op_key") else Nothing
          case opKey of
            Nothing -> throwPy "TypeError" "V5 Git Activity request has no strict operation key"
            Just key
              | any (\pub -> pub.operation == key) t.gitPublications -> pure True
              | otherwise -> do
                  let operation = "mutation:owner/repo:pr:7:" <> key
                  pure $ case Map.lookup operation t.agentTerminals of
                    Just v -> v .: "kind" == String "coding" && v .: "operation" == String operation && v .: "attempt" == Int 1
                    Nothing -> False

-- | @_bind_readiness_effect_authorities()@.
bindReadinessEffectAuthorities :: ReadinessProfile -> IO ()
bindReadinessEffectAuthorities p = do
  records <- historyRecords p.root
  let terminal = Set.fromList [o | r <- records, maybe False (`Set.member` terminalRecords) (recordKind r), Just o <- [intOf (r .: "occurrence")]]
  forM_ records $ \r ->
    case intOf (r .: "occurrence") of
      Just occurrence
        | recordKind r == Just "ActivityRequested"
        , r .: "activity" == String "announce_gate"
        , Set.notMember occurrence terminal -> do
            let work = if isObject (r .: "input") then r .: "input" .: "work" else Null
            unless (isObject work) $ throwPy "TypeError" "V5 readiness Activity request has no strict work payload"
            t <- readIORef p.truth
            let operation = str (work .: "op")
                matches =
                  foldl
                    ( \acc e ->
                        let a = e.authority
                         in if isJust operation
                              && a.lifecycle == Active
                              && a.mergeable
                              && work .: "head" == String a.head
                              && work .: "base" == String a.base
                              && work .: "policy" == String a.policy
                              && sameBool (work .: "strict_base") a.strictBase
                              && sameBool (work .: "base_current") a.baseCurrent
                              && a `notElem` acc
                              then acc <> [a]
                              else acc
                    )
                    []
                    t.admitted
            case (operation, matches) of
              (Just op, [only]) -> bindEffectAuthority p.truth "readiness" op only
              _ -> throwPy "AssertionError" "V5 readiness Activity request has no unique independently admitted authority"
      _ -> pure ()
  where
    sameBool value b = value == Bool b && case value of Bool _ -> True; _ -> False

-- ---------------------------------------------------------------------------
-- Observation

stateRequest :: ObservationRequest
stateRequest = ObservationRequest {name = "readiness.state", payload = Object []}

-- | @_state(generation, instant)@.
readinessState :: ReadinessProfile -> Generation -> Integer -> IO Json
readinessState p g now = do
  t <- readIORef p.truth
  custody <- forM (Map.keys t.emittedDeliveries) $ \delivery ->
    (delivery,) . maybe Null String <$> Custody.status g.host.custody delivery
  let timers = expectedTimers t now
  facts <- either (throwPy "ValueError") pure (factsOf t timers)
  let expected = evaluate facts
  detached <- Host.subjectState g.host 44 31 7
  let hostState = fromMaybe (Object [("ready", Null), ("snapshot", Null)]) detached
      snapshot = hostState .: "snapshot"
      published = case (snapshot .: "phase", snapshot .: "incarnation") of
        (String "running", Int incarnation) | isObject snapshot ->
          let operation = "ready:" <> t.authority.head <> ":i" <> showT incarnation
           in any
                (\e -> e.kind == "readiness" && e.operation == operation && e.authority == t.authority && e.providerAuthorityAtAcceptance == t.authority)
                t.effects
        _ -> False
  (history, terminalOperations) <- historySummary p.root
  timerCustody' <- timerCustody p.root
  motus' <- motus p.root
  gitCustody' <- gitCustody p.root
  work <- Host.workState g.host
  usage <- profileResourceUsage p (Just g)
  let state =
        Object
          [ ("subject", String subject)
          , ("expected", dump expected)
          , ("facts", dump facts)
          , ("actual", Object [("readiness_published", Bool published)])
          , ("host", hostState)
          , ("provider", observation t)
          , ("custody", Object custody)
          , ("timer_expectations", Array timers)
          , ("timer_custody", timerCustody')
          , ("history", history)
          , ("motus", motus')
          , ("git_custody", gitCustody')
          , ("terminal_operations", Array (map String terminalOperations))
          , ("work", work)
          , ("bounds", Object [("limits", Object [(k, Int v) | (k, v) <- profileResourceLimits]), ("usage", Object [(k, Int v) | (k, v) <- Map.toAscList usage.values])])
          ]
  either (\(PyError cls m) -> throwPy cls m) (const (pure state)) (boundedJson state (profileLimit "observation_bytes") "readiness observation")

-- | @resource_usage(generation)@ (@_usage@).
profileResourceUsage :: ReadinessProfile -> Maybe Generation -> IO ResourceUsage
profileResourceUsage p generation = do
  history <- historyRecords p.root
  histories <- subjectFiles p.root "history.jsonl"
  historyBytes <- sum <$> mapM getFileSize histories
  (sqliteRows, sqliteBytes, counts) <- sqliteRetained p.root
  t <- readIORef p.truth
  droppedCount <- length <$> readIORef p.dropped
  followed <- readIORef p.hostFollowups
  proposals <- maybe (pure 0) (fmap Set.size . readIORef . (.proposed)) generation
  let occurrences kinds = Set.fromList [o | r <- history, maybe False (`Set.member` kinds) (recordKind r), Just o <- [intOf (r .: "occurrence")]]
      terminal = occurrences terminalRecords
      requested = occurrences (Set.singleton "ActivityRequested")
      count k = Map.findWithDefault 0 k counts
      len :: [a] -> Integer
      len = toInteger . length
  pure . ResourceUsage . Map.fromList $
    [ ("retained.host.history_bytes", historyBytes)
    , ("retained.host.history_records", len history)
    , ("retained.host.sqlite_bytes", sqliteBytes)
    , ("retained.host.sqlite_rows", sqliteRows)
    , ("retained.profile.dropped_generations", toInteger droppedCount)
    , ("retained.profile.followups", followed)
    , ("retained.provider.admissions", len t.admitted)
    , ("retained.provider.agent_operations", len t.agentCalls)
    , ("retained.provider.authorities", len t.authorities)
    , ("retained.provider.bytes", retainedBytes t)
    , ("retained.provider.calls", len t.calls)
    , ("retained.provider.checks", len t.checks)
    , ("retained.provider.collisions", len t.collisions)
    , ("retained.provider.comments", len t.comments)
    , ("retained.provider.custody_actions", len t.custodyActions)
    , ("retained.provider.delivery_attempts", sum (Map.elems t.deliveryAttempts))
    , ("retained.provider.effect_bindings", toInteger (Map.size t.effectAuthorities))
    , ("retained.provider.effects", len t.effects)
    , ("retained.provider.findings", len t.findings)
    , ("retained.provider.git_publications", len t.gitPublications)
    , ("retained.provider.git_reconciliations", t.gitReconciliations)
    , ("retained.provider.reviews", toInteger (Map.size t.humanReviews))
    , ("retained.provider.threads", toInteger (Map.size t.reviewThreads))
    , ("retained.provider.truth_changes", t.providerTruthChanges)
    , ("retained.provider.webhooks", toInteger (Map.size t.emittedDeliveries))
    , ("pending.host.activities", toInteger (Set.size (requested `Set.difference` terminal)))
    , ("pending.host.custody", count "inbox.pending")
    , ("pending.host.dispatch", count "impetus_local_dispatch.pending")
    , ("pending.host.runnable", count "wakes")
    , ("pending.host.timer_acks", count "v5_timer_operations.pending_ack")
    , ("pending.host.timer_maturities", count "v5_timers.pending_maturity")
    , ("pending.host.timers", count "v5_timers.armed")
    , ("pending.profile.proposals", toInteger proposals)
    ]

-- | The admitted authority generations: every distinct consecutive claim.
generationCount :: [Emitted] -> Integer
generationCount admitted = go Nothing admitted 0
  where
    go _ [] n = n
    go prior (e : rest) n = go (Just e.authority) rest (if Just e.authority /= prior then n + 1 else n)

-- | @_facts(timer_expectations)@, validated as the reference's
-- constructor validates it.
factsOf :: Truth -> [Json] -> Either Text ReadinessFacts
factsOf t timers = loadJson value
  where
    admissions = t.admitted
    admittedClaim = if null admissions then Null else dump (last admissions).authority
    reviewCalls = [c | c <- t.agentCalls, c .: "kind" == String "review"]
    review = case reviewCalls of
      [] -> Object []
      _ -> let latest = last reviewCalls in Object [("head", latest .: "head"), ("status", latest .: "status"), ("findings", Array [])]
    states = map snd (Map.elems t.humanReviews)
    approvals = toInteger (length (filter (== "APPROVED") states))
    changes = "CHANGES_REQUESTED" `elem` states
    (mutation, mutationEffect) = expectedMutation t
    effectKind k
      | k == "finding" = "findings"
      | k `elem` ["dashboard", "conversation", "readiness", "reminder", "rerun"] = k
      | otherwise = "dashboard"
    effects =
      [ Object
          [ ("kind", String (effectKind e.kind))
          , ("operation", String e.operation)
          , ("authority", dump e.authority)
          , ("content_digest", String e.contentDigest)
          , ("status", String (if e.recovered then "settled" else "accepted"))
          , ("provider_authority_at_acceptance", dump e.providerAuthorityAtAcceptance)
          , ("blocks_readiness", Bool False)
          ]
      | e <- t.effects
      ]
        <> maybe [] pure mutationEffect
    value =
      Object
        [ ("subject", String subject)
        , ("authority", Object [("generation", Int (generationCount admissions)), ("admitted", admittedClaim), ("provider", dump t.authority)])
        , ("admitted_observations", Array [String (identityOf' e) | e <- admissions])
        , ("ci", Object [("head", String t.reviewHead), ("required_checks", Array (map String t.requiredChecks)), ("checks", Array [Object [("name", c .: "name"), ("status", c .: "status")] | c <- t.checks])])
        , ("review", review)
        ,
          ( "human"
          , Object
              [ ("approvals", Int approvals)
              , ("required_approvals", Int 0)
              , ("changes_requested", Bool changes)
              , ("unresolved_conversations", Int (toInteger (length (filter not (Map.elems t.reviewThreads)))))
              ]
          )
        , ("mutation", mutation)
        , ("effects", Array effects)
        , ("timers", Array [Object [("identity", timer .: "identity"), ("status", timer .: "status"), ("blocks_readiness", Bool False)] | timer <- timers])
        ]

identityOf' :: Emitted -> Text
identityOf' e = if T.null e.sourceIdentity then "github-delivery:" <> e.delivery else e.sourceIdentity

-- | @_expected_mutation()@: mutation facts and the Git effect obligation.
expectedMutation :: Truth -> (Json, Maybe Json)
expectedMutation t =
  case [i | (i, e) <- zip [0 :: Int ..] t.admitted, Just c <- [e.comment], c .: "fixture" == String "change"] of
    [] -> (Object [], Nothing)
    positions ->
      let position = last positions
          change = t.admitted !! position
          comment = fromMaybe Null change.comment
          incarnation = generationCount (take (position + 1) t.admitted)
          identity = "github-delivery:" <> change.delivery
          operation = "push:comment:" <> jsonText (comment .: "id") <> ":" <> change.authority.head <> ":i" <> showT incarnation
          authorization =
            Object
              [ ("identity", String identity)
              , ("operation", String operation)
              , ("authority", dump change.authority)
              , ("intent", String "change")
              , ("intent_digest", String (strictDigest (Object [("fixture", comment .: "fixture")])))
              ]
       in case find (\pub -> pub.operation == operation) t.gitPublications of
            Nothing ->
              ( Object [("status", String "requested"), ("operation", String operation), ("head", String change.authority.head), ("authorization", authorization)]
              , Nothing
              )
            Just publication ->
              let latest = if null t.admitted then Nothing else Just (last t.admitted).authority
                  recovery = recoveryIdentity t operation False
                  recoveredWithGrant = publication.recovered && publication.recoveryIdentity == recovery && recovery /= ""
                  status
                    | publication.responseLost && not recoveredWithGrant = Just "ambiguous"
                    | maybe True (\a -> a.head /= publication.resultHead) latest = Just "accepted_pending_admission"
                    | otherwise = Nothing
               in case status of
                    Nothing -> (Object [], Nothing)
                    Just s ->
                      ( Object
                          [ ("status", String s)
                          , ("operation", String operation)
                          , ("head", String change.authority.head)
                          , ("result_head", String publication.resultHead)
                          , ("authorization", authorization)
                          ]
                      , Just $
                          Object
                            [ ("kind", String "git_mutation")
                            , ("operation", String operation)
                            , ("authority", dump change.authority)
                            , ("content_digest", String publication.payloadDigest)
                            , ("status", String (if s == "ambiguous" then "ambiguous" else "accepted"))
                            , ("provider_authority_at_acceptance", dump publication.authority)
                            , ("authorization", String identity)
                            , ("blocks_readiness", Bool False)
                            ]
                      )

-- | @str(value)@ of a JSON scalar.
jsonText :: Json -> Text
jsonText = \case
  String s -> s
  Int i -> showT i
  Null -> "None"
  Bool True -> "True"
  Bool False -> "False"
  other -> T.pack (show other)

data Timer = Timer
  { timerIdentity :: Text
  , timerIncarnation :: Integer
  , timerSequence :: Integer
  , timerHead :: Text
  , timerDueAt :: Integer
  , timerStatus :: Text
  , timerMaturedAt :: Maybe Integer
  }

data TimerFold = TimerFold
  { foldTimers :: Seq Timer
  , foldCurrent :: Maybe Int
  , foldPhase :: Text
  , foldHead :: Text
  , foldIncarnation :: Integer
  }

data Ordered = OAdmission Emitted | OReminder Effect

-- | @_expected_timers(instant)@: authored admissions and provider effects
-- folded into the expected reminder custody.
expectedTimers :: Truth -> Integer -> [Json]
expectedTimers t now = map timerJson (toList (finish (foldl visit initial ordered)).foldTimers)
  where
    initial = TimerFold {foldTimers = Seq.empty, foldCurrent = Nothing, foldPhase = "running", foldHead = "", foldIncarnation = 0}
    ordered =
      map snd . sortOn fst $
        [(e.semanticOrder, OAdmission e) | e <- t.admitted]
          <> [(e.semanticOrder, OReminder e) | e <- t.effects, e.kind == "reminder"]
    cancel s = case s.foldCurrent of
      Just i
        | (Seq.index s.foldTimers i).timerStatus `elem` ["scheduled", "due"] ->
            s {foldTimers = Seq.adjust' (\timer -> timer {timerStatus = "canceled"}) i s.foldTimers, foldCurrent = Nothing}
      _ -> s {foldCurrent = Nothing}
    arm at timerHead' sequenceNumber s =
      let timer =
            Timer
              { timerIdentity = "timer:" <> subject <> ":i" <> showT s.foldIncarnation <> ":s" <> showT sequenceNumber
              , timerIncarnation = s.foldIncarnation
              , timerSequence = sequenceNumber
              , timerHead = timerHead'
              , timerDueAt = at + reminderDelay
              , timerStatus = "scheduled"
              , timerMaturedAt = Nothing
              }
       in s {foldTimers = s.foldTimers |> timer, foldCurrent = Just (Seq.length s.foldTimers)}
    visit s = \case
      OAdmission event ->
        let claim = event.authority
         in if
              | claim.lifecycle `elem` [Closed, Merged] -> (cancel s) {foldPhase = "terminal"}
              | s.foldPhase == "terminal" -> s
              | otherwise ->
                  let moved
                        | s.foldPhase == "quiescent" = s {foldHead = claim.head}
                        | claim.head /= s.foldHead =
                            let s' = (cancel s) {foldIncarnation = s.foldIncarnation + 1, foldHead = claim.head, foldPhase = "running"}
                             in arm event.instant s'.foldHead 0 s'
                        | otherwise = s
                   in if
                        | claim.lifecycle == Draft -> (if moved.foldPhase == "running" then cancel moved else moved) {foldPhase = "quiescent"}
                        | moved.foldPhase == "quiescent" ->
                            let s' = moved {foldPhase = "running", foldIncarnation = moved.foldIncarnation + 1}
                             in arm event.instant s'.foldHead 0 s'
                        | otherwise -> moved
      OReminder effect ->
        let timerId = fromMaybe effect.operation (T.stripPrefix "reminder:" effect.operation)
         in case Seq.findIndexL (\timer -> timer.timerIdentity == timerId) s.foldTimers of
              Nothing -> s
              Just i
                | (Seq.index s.foldTimers i).timerStatus == "canceled" -> s
                | otherwise ->
                    let matched = Seq.index s.foldTimers i
                        s' = s {foldTimers = Seq.update i matched {timerStatus = "acknowledged", timerMaturedAt = Just effect.acceptedAt} s.foldTimers}
                     in if s.foldCurrent == Just i && s.foldPhase == "running"
                          then arm effect.acceptedAt matched.timerHead (matched.timerSequence + 1) s'
                          else s'
    finish s = case s.foldCurrent of
      Just i
        | let timer = Seq.index s.foldTimers i
        , timer.timerStatus == "scheduled"
        , timer.timerDueAt <= now ->
            arm now timer.timerHead (timer.timerSequence + 1) s {foldTimers = Seq.update i timer {timerStatus = "due", timerMaturedAt = Just now} s.foldTimers}
      _ -> s
    timerJson timer =
      Object
        [ ("identity", String timer.timerIdentity)
        , ("incarnation", Int timer.timerIncarnation)
        , ("sequence", Int timer.timerSequence)
        , ("head", String timer.timerHead)
        , ("due_at", Int timer.timerDueAt)
        , ("status", String timer.timerStatus)
        , ("matured_at", maybe Null Int timer.timerMaturedAt)
        ]

-- ---------------------------------------------------------------------------
-- Detached durable state

-- | @applications/*/*/*/<name>@, sorted.
subjectFiles :: FilePath -> FilePath -> IO [FilePath]
subjectFiles root name = do
  let applications = root </> "applications"
  exists <- doesDirectoryExist applications
  if not exists
    then pure []
    else do
      let children dir = do
            isDir <- doesDirectoryExist dir
            if isDir then map (dir </>) . sort <$> listDirectory dir else pure []
      level1 <- children applications
      level2 <- concat <$> mapM children level1
      level3 <- concat <$> mapM children level2
      filterM' doesFileExist (sort [dir </> name | dir <- level3])

filterM' :: (a -> IO Bool) -> [a] -> IO [a]
filterM' predicate = fmap catMaybes . mapM (\x -> predicate x >>= \keep -> pure (if keep then Just x else Nothing))

-- | @_history_records(root)@.
historyRecords :: FilePath -> IO [Json]
historyRecords root = do
  let path = root </> "applications" </> "44" </> "31" </> "7" </> "history.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bytes <- BS.readFile path
      forM (filter (not . BS.null) (BC.lines bytes)) $ \line ->
        either (\message -> throwPy "JSONDecodeError" (T.pack message)) pure (parseJson pythonLoads line)

-- | @_history(root)@: the History summary and the terminal operations.
historySummary :: FilePath -> IO (Json, [Text])
historySummary root = do
  records <- historyRecords root
  let summarize (requested0, terminal0, summary0, kinds0) record =
        let kind = maybe "" jsonText (lookupMember "record" record)
            occurrence = intOf (record .: "occurrence")
            operation
              | kind == "ActivityRequested"
              , Just _ <- occurrence
              , payload@(Object _) <- record .: "input" =
                  let work = fromMaybe (payload .: "command") (lookupMember "work" payload)
                   in if isObject work then work .: "operation" else Null
              | otherwise = Null
            requested' = case (occurrence, operation) of
              (Just o, String op) | kind == "ActivityRequested" -> Map.insert o op requested0
              _ -> requested0
            terminal' = case occurrence of
              Just o | Set.member kind terminalRecords -> Set.insert o terminal0
              _ -> terminal0
            entry = Object [("record", String kind), ("occurrence", maybe Null Int occurrence), ("operation", operation)]
         in (requested', terminal', summary0 |> entry, Map.insertWith (+) kind (1 :: Integer) kinds0)
      (requested, terminal, summary, kinds) = foldl summarize (Map.empty, Set.empty, Seq.empty, Map.empty) records
      tailEntries = toList (Seq.drop (Seq.length summary - 32) summary)
  pure
    ( Object
        [ ("records", Int (toInteger (length records)))
        , ("by_kind", Object [(k, Int n) | (k, n) <- Map.toAscList kinds])
        , ("digest", String (strictDigest (Array records)))
        , ("tail", Array tailEntries)
        ]
    , sort [op | (o, op) <- Map.toList requested, Set.member o terminal]
    )

-- | @_git_custody(root)@: V5 Git requests and terminals from History.
gitCustody :: FilePath -> IO Json
gitCustody root = do
  records <- historyRecords root
  let visit (requested, requests, terminals) record = do
        let occurrence = intOf (record .: "occurrence")
        if recordKind record == Just "ActivityRequested" && record .: "activity" == String "git_gate"
          then do
            let payload = record .: "input"
                work = if isObject payload then payload .: "work" else Null
            o <- case occurrence of
              Just o | isObject work -> pure o
              _ -> throwPy "RuntimeError" "V5 Git History request is malformed"
            operation <- maybe (throwPy "RuntimeError" "V5 Git History request has no strict operation key") pure (str (work .: "op_key"))
            pure
              ( Map.insert o operation requested
              , requests |> Object [("occurrence", Int o), ("operation", String operation), ("head", work .: "head"), ("base", work .: "base")]
              , terminals
              )
          else case (recordKind record, occurrence) of
            (Just kind, Just o)
              | Set.member kind terminalRecords
              , Just operation <- Map.lookup o requested -> do
                  let result = record .: "result"
                      variant = if isObject result then result .: "$variant" else record .: "record"
                      resultHead = if isObject result then result .: "new_head" else Null
                  pure
                    ( requested
                    , requests
                    , terminals |> Object [("occurrence", Int o), ("operation", String operation), ("variant", variant), ("result_head", resultHead)]
                    )
            _ -> pure (requested, requests, terminals)
  (_, requests, terminals) <- foldlM' visit (Map.empty, Seq.empty, Seq.empty) records
  pure (Object [("requests", Array (toList requests)), ("terminals", Array (toList terminals))])

foldlM' :: (b -> a -> IO b) -> b -> [a] -> IO b
foldlM' f = go
  where
    go acc [] = pure acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

withDatabase :: FilePath -> (Sql.Connection -> IO a) -> IO a
withDatabase path body = do
  connection <- Sql.open (T.pack path)
  result <- try @SomeException (body connection)
  Sql.close connection
  either throwIO pure result

tableNames :: Sql.Connection -> Text -> IO [Text]
tableNames connection sql = do
  rows <- Sql.query connection sql []
  pure [name | SQLText name : _ <- rows]

-- | @_whole_seconds(value, label)@.
wholeSeconds :: SQLData -> Text -> IO Integer
wholeSeconds value label = case value of
  SQLInteger n | n `mod` 1000000 == 0 -> pure (toInteger n `div` 1000000)
  _ -> throwPy "RuntimeError" (label <> " is not a deterministic whole second")

sqlInt :: SQLData -> Integer
sqlInt = \case
  SQLInteger n -> toInteger n
  SQLFloat d -> truncate d
  _ -> 0

sqlText :: SQLData -> Text
sqlText = \case
  SQLText s -> s
  SQLInteger n -> showT n
  SQLFloat d -> showT d
  SQLNull -> "None"
  SQLBlob b -> TE.decodeLatin1 b

-- | @_timer_custody(root)@: V5 timer custody without a marking or live
-- store.
timerCustody :: FilePath -> IO Json
timerCustody root = do
  paths <- subjectFiles root "timers.sqlite3"
  parts <- forM paths $ \path -> withDatabase path $ \db -> do
    names <- Set.fromList <$> tableNames db "SELECT name FROM sqlite_master WHERE type='table'"
    unless (Set.fromList ["v5_timer_operations", "v5_timers"] `Set.isSubsetOf` names) $
      throwPy "RuntimeError" "readiness timer custody store is incomplete"
    operationRows <-
      Sql.query db "SELECT operation,generation,applied_at_us,ack_delivered FROM v5_timer_operations ORDER BY generation,operation" []
    operations <- forM operationRows $ \case
      [operation, generation, appliedAt, acknowledged] -> do
        at <- wholeSeconds appliedAt "timer operation instant"
        pure $
          Object
            [ ("identity", String (sqlText operation))
            , ("generation", Int (sqlInt generation))
            , ("applied_at", Int at)
            , ("acknowledged", Bool (acknowledged == SQLInteger 1))
            ]
      _ -> throwPy "RuntimeError" "readiness timer custody store is incomplete"
    timerRows <-
      Sql.query
        db
        "SELECT timer_id,incarnation,sequence,head,due_at_us,state,matured_at_us,maturity_delivered FROM v5_timers ORDER BY incarnation,sequence,timer_id"
        []
    timers <- forM timerRows $ \case
      [identity, incarnation, sequenceNumber, timerHead, dueAt, state, maturedAt, delivered] -> do
        due <- wholeSeconds dueAt "timer deadline"
        matured <- case maturedAt of
          SQLNull -> pure Null
          value -> Int <$> wholeSeconds value "timer maturity instant"
        pure $
          Object
            [ ("identity", String (sqlText identity))
            , ("incarnation", Int (sqlInt incarnation))
            , ("sequence", Int (sqlInt sequenceNumber))
            , ("head", String (sqlText timerHead))
            , ("due_at", Int due)
            , ("state", String (sqlText state))
            , ("matured_at", matured)
            , ("maturity_delivered", Bool (delivered == SQLInteger 1))
            ]
      _ -> throwPy "RuntimeError" "readiness timer custody store is incomplete"
    pure (operations, timers)
  pure (Object [("operations", Array (concatMap fst parts)), ("timers", Array (concatMap snd parts))])

-- | Every @*.sqlite3@ file under a directory, recursively, sorted.
sqliteFiles :: FilePath -> IO [FilePath]
sqliteFiles dir = do
  entries <- sort <$> listDirectory dir
  fmap concat . forM entries $ \entry -> do
    let path = dir </> entry
    isDir <- doesDirectoryExist path
    isFile <- doesFileExist path
    if
      | isDir -> do
          nested <- sqliteFiles path
          pure ([path | isFile] <> nested)
      | isFile && takeExtension entry == ".sqlite3" -> pure [path]
      | otherwise -> pure []

-- | @_sqlite_retained(root)@: durable SQLite rows, scalar bytes, and the
-- named pending subsets.
sqliteRetained :: FilePath -> IO (Integer, Integer, Map Text Integer)
sqliteRetained root = do
  exists <- doesDirectoryExist root
  paths <- if exists then sqliteFiles root else pure []
  totals <- forM paths $ \path -> withDatabase path $ \db -> do
    tables <- tableNames db "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    perTable <- forM tables $ \table -> do
      let quoted = T.replace "\"" "\"\"" table
      columnRows <- Sql.query db ("PRAGMA table_info(\"" <> quoted <> "\")") []
      let columns = [sqlText name | _ : name : _ <- columnRows]
          scalarBytes = T.intercalate "+" ["length(CAST(quote(\"" <> T.replace "\"" "\"\"" column <> "\") AS BLOB))" | column <- columns]
      summary <- Sql.query db ("SELECT COUNT(*),COALESCE(SUM(" <> scalarBytes <> "),0) FROM \"" <> quoted <> "\"") []
      (rows, dataBytes) <- case summary of
        [[r, b]] -> pure (sqlInt r, sqlInt b)
        _ -> throwPy "RuntimeError" "SQLite table summary is malformed"
      let encoded = toInteger (BS.length (TE.encodeUtf8 (T.pack (makeRelative root path)))) + toInteger (BS.length (TE.encodeUtf8 table)) + dataBytes
          whereCount condition = do
            result <- Sql.query db ("SELECT COUNT(*) FROM \"" <> quoted <> "\" WHERE " <> condition) []
            pure $ case result of
              [[n]] -> sqlInt n
              _ -> 0
      extra <-
        if
          | table == "inbox" -> (\n -> [("inbox.pending", n)]) <$> whereCount "status='pending'"
          | table == "v5_timer_operations" -> (\n -> [("v5_timer_operations.pending_ack", n)]) <$> whereCount "ack_delivered=0"
          | table == "v5_timers" -> do
              matured <- whereCount "state='matured' AND maturity_delivered=0"
              armed <- whereCount "state='armed'"
              pure [("v5_timers.pending_maturity", matured), ("v5_timers.armed", armed)]
          | otherwise -> pure []
      pure (rows, encoded, (table, rows) : extra)
    dispatch <-
      if Set.fromList ["impetus_local_dispatch_tasks", "impetus_local_dispatch_terminals", "impetus_local_dispatch_cancellations"]
        `Set.isSubsetOf` Set.fromList tables
        then do
          result <-
            Sql.query
              db
              ( "SELECT COUNT(*) FROM impetus_local_dispatch_tasks AS task"
                  <> " LEFT JOIN impetus_local_dispatch_terminals AS terminal"
                  <> " USING(instance,occurrence)"
                  <> " LEFT JOIN impetus_local_dispatch_cancellations AS cancellation"
                  <> " USING(instance,occurrence)"
                  <> " WHERE terminal.occurrence IS NULL AND cancellation.occurrence IS NULL"
              )
              []
          pure [("impetus_local_dispatch.pending", case result of [[n]] -> sqlInt n; _ -> 0)]
        else pure []
    pure (sum [r | (r, _, _) <- perTable], sum [b | (_, b, _) <- perTable], concat [c | (_, _, c) <- perTable] <> dispatch)
  pure
    ( sum [r | (r, _, _) <- totals]
    , sum [b | (_, b, _) <- totals]
    , Map.fromListWith (+) (concat [c | (_, _, c) <- totals])
    )

-- | @_motus(root)@.
motus :: FilePath -> IO Json
motus root = do
  let path = root </> "activity-dispatch.sqlite3"
  exists <- doesFileExist path
  if not exists
    then pure (Object [("requests", Int 0), ("terminals", Int 0), ("cancellations", Int 0)])
    else withDatabase path $ \db -> do
      names <- Set.fromList <$> tableNames db "SELECT name FROM sqlite_master WHERE type='table'"
      let count table
            | Set.notMember table names = pure 0
            | otherwise = do
                result <- Sql.query db ("SELECT COUNT(*) FROM " <> table) []
                pure (case result of [[n]] -> sqlInt n; _ -> 0)
      requests <- count "impetus_local_dispatch_tasks"
      terminals <- count "impetus_local_dispatch_terminals"
      cancellations <- count "impetus_local_dispatch_cancellations"
      pure (Object [("requests", Int requests), ("terminals", Int terminals), ("cancellations", Int cancellations)])

-- ---------------------------------------------------------------------------
-- The checker

-- | @ReadinessChecker()@.
readinessChecker :: Checker
readinessChecker = Checker {identity = checkerIdentity, request = stateRequest, check = checkReadiness}

-- | @ReadinessChecker.check(observation)@.
checkReadiness :: Observation -> Either ProfileError CheckResult
checkReadiness o = do
  let state = o.value
      expected = state .: "expected"
      actual = state .: "actual"
      hostState = state .: "host"
      provider = state .: "provider"
      effects = arr (provider .: "effects")
      counts xs = Map.toAscList (Map.fromListWith (+) [(x, 1 :: Int) | x <- xs])
      duplicate = [op | (op, n) <- counts (mapMaybe (\e -> str (e .: "operation")) effects), n > 1]
      collisions = arr (provider .: "collisions")
      custodyMismatches =
        [ Object [("expected", a .: "expected"), ("observed", a .: "observed")]
        | a <- arr (provider .: "custody_actions")
        , a .: "expected" /= a .: "observed"
        ]
      duplicateTerminals = [op | (op, n) <- counts (mapMaybe str (arr (state .: "terminal_operations"))), n > 1]
      motus' = state .: "motus"
      terminalOverrun = fromMaybe 0 (intOf (motus' .: "terminals")) > fromMaybe 0 (intOf (motus' .: "requests"))
      violations = arr (expected .: "violations")
      work = state .: "work"
      facts = state .: "facts"
      authority = facts .: "authority"
      authorityLag = authority .: "admitted" /= authority .: "provider"
      snapshot = hostState .: "snapshot"
      unloaded = snapshot == Null && work .: "unloaded_application" == Bool True
      snapshotParity = unloaded || snapshotMatches (authority .: "admitted") snapshot
      observedReadiness = currentReadiness effects (authority .: "provider") snapshot
      actualParity = actual .: "readiness_published" == Bool observedReadiness
      disclosed = progressDisclosed work o.instant
      readinessParity =
        Bool observedReadiness == expected .: "ready"
          || (expected .: "ready" == Bool True && isBool (expected .: "ready") && not observedReadiness && disclosed)
      timerMismatches = timerCustodyMismatches state
      timerParity = null timerMismatches || disclosed
      gitMismatches = gitCustodyMismatches state disclosed
      gitParity = null gitMismatches
      neutral = hostState .: "ready" == Null
      readyParity = readinessParity && actualParity && neutral
      parity = readyParity && snapshotParity && timerParity && gitParity
  retained <- either (\(PyError cls m) -> Left (ProfileError cls m)) (Right . TE.decodeUtf8) (boundedJson state (profileLimit "observation_bytes") "checker observation")
  let sensitive =
        [ label
        | (label, value) <- [("client_id", clientId), ("private_key", privateKey), ("webhook_secret", webhookSecret)]
        , value `T.isInfixOf` retained
        ]
      passed =
        parity
          && null custodyMismatches
          && null duplicate
          && null collisions
          && null duplicateTerminals
          && not terminalOverrun
          && null sensitive
          && null violations
  pure
    CheckResult
      { passed
      , detail =
          Object
            [ ("parity", Bool parity)
            , ("ready_parity", Bool readyParity)
            , ("snapshot_parity", Bool snapshotParity)
            , ("timer_custody_parity", Bool timerParity)
            , ("timer_custody_mismatches", Array timerMismatches)
            , ("git_custody_parity", Bool gitParity)
            , ("git_custody_mismatches", Array gitMismatches)
            , ("authority_lag", Bool authorityLag)
            , ("expected_ready", expected .: "ready")
            , ("readiness_published", Bool observedReadiness)
            , ("progress_disclosed", Bool disclosed)
            , ("actual_parity", Bool actualParity)
            , ("neutral_host_verdict", Bool neutral)
            , ("custody_action_mismatches", Array custodyMismatches)
            , ("duplicate_acceptance", Array (map String duplicate))
            , ("effect_identity_collisions", Array collisions)
            , ("duplicate_terminal_projection", Array (map String duplicateTerminals))
            , ("terminal_overrun", Bool terminalOverrun)
            , ("sensitive_values", Array (map String sensitive))
            , ("violations", Array violations)
            ]
      }
  where
    isBool = \case
      Bool _ -> True
      _ -> False

-- | @_snapshot_matches(admitted, snapshot)@.
snapshotMatches :: Json -> Json -> Bool
snapshotMatches admitted snapshot
  | admitted == Null = snapshot == Null
  | not (isObject admitted) || not (isObject snapshot) = False
  | admitted .: "lifecycle" `elem` [String "closed", String "merged"] = snapshot .: "phase" == String "terminal"
  | otherwise =
      snapshot .: "phase" == String (if admitted .: "lifecycle" == String "draft" then "quiescent" else "running")
        && snapshot .: "head" == admitted .: "head"
        && snapshot .: "base_head" == admitted .: "base"
        && snapshot .: "policy_digest" == admitted .: "policy"

-- | @_current_readiness(effects, provider_authority, snapshot)@.
currentReadiness :: [Json] -> Json -> Json -> Bool
currentReadiness effects providerAuthority snapshot
  | not (isObject providerAuthority) || not (isObject snapshot) || snapshot .: "phase" /= String "running" = False
  | otherwise = case snapshot .: "incarnation" of
      Int incarnation ->
        let operation = "ready:" <> jsonText (providerAuthority .: "head") <> ":i" <> showT incarnation
         in any
              ( \e ->
                  e .: "kind" == String "readiness"
                    && e .: "operation" == String operation
                    && e .: "authority" == providerAuthority
                    && e .: "provider_authority_at_acceptance" == providerAuthority
              )
              effects
      _ -> False

-- | @_progress_disclosed(work, instant)@.
progressDisclosed :: Json -> Integer -> Bool
progressDisclosed work now =
  or
    [ work .: "pending_custody" == Bool True
    , work .: "unresolved_activity" == Bool True
    , work .: "unloaded_application" == Bool True
    , case work .: "runnable_due" of
        Int i -> i <= now
        Float d -> (ceiling d :: Integer) <= now
        _ -> False
    ]

-- | @_git_custody_mismatches(state, progress_disclosed)@.
gitCustodyMismatches :: Json -> Bool -> [Json]
gitCustodyMismatches state disclosed = acceptances <> concatMap perPublication publications
  where
    provider = state .: "provider"
    publications = arr (provider .: "git_publications")
    recoveries = arr (provider .: "admitted_recoveries")
    custody = state .: "git_custody"
    requests = arr (custody .: "requests")
    terminals = arr (custody .: "terminals")
    mismatch operation fieldName expected observed =
      Object [("operation", operation), ("field", String fieldName), ("expected", expected), ("observed", observed)]
    acceptances =
      [ mismatch (String op) "acceptances" (Int 1) (Int (toInteger n))
      | (op, n) <- Map.toAscList (Map.fromListWith (+) [(jsonText (pub .: "operation"), 1 :: Int) | pub <- publications])
      , n > 1
      ]
    perPublication pub =
      let operation = pub .: "operation"
          authority = pub .: "authority"
          identities = [r .: "identity" | r <- recoveries, r .: "operation" == operation]
          matchingRequests = [r | r <- requests, r .: "operation" == operation]
          recoveryCheck =
            [ mismatch operation "recovery_authorization" (Array identities) (pub .: "recovery_identity")
            | truthy (pub .: "recovered")
            , pub .: "recovery_identity" `notElem` identities
            ]
          requestCheck = [mismatch operation "request" (Bool True) (Bool False) | null matchingRequests]
          headCheck =
            [ mismatch operation "expected_head" (authority .: "head") (pub .: "expected_head")
            | pub .: "expected_head" /= authority .: "head"
            ]
          requestFields =
            [ mismatch operation ("request_" <> fieldName) (authority .: key) (r .: fieldName)
            | r <- matchingRequests
            , (fieldName, key) <- [("head", "head"), ("base", "base")]
            , r .: fieldName /= authority .: key
            ]
          matching = [terminal | terminal <- terminals, terminal .: "operation" == operation]
          expectedVariants
            | truthy (pub .: "response_lost") && truthy (pub .: "recovered") = ["FaultM", "Pushed"]
            | truthy (pub .: "response_lost") = ["FaultM"]
            | otherwise = ["Pushed"]
          observedVariants = [terminal .: "variant" | terminal <- matching]
          terminalChecks
            | disclosed = []
            | otherwise =
                [ mismatch operation "terminal" (Array (map String expectedVariants)) (Array observedVariants)
                | observedVariants /= map String expectedVariants
                ]
                  <> [ mismatch operation "requests" (Int (toInteger (length expectedVariants))) (Int (toInteger (length matchingRequests)))
                     | length matchingRequests /= length expectedVariants
                     ]
                  <> [ mismatch operation "terminal_result_head" expectedHead (terminal .: "result_head")
                     | terminal <- matching
                     , let expectedHead = if terminal .: "variant" == String "Pushed" then pub .: "result_head" else Null
                     , terminal .: "result_head" /= expectedHead
                     ]
       in recoveryCheck <> requestCheck <> headCheck <> requestFields <> terminalChecks

truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array xs -> not (null xs)
  Object xs -> not (null xs)

-- | @_timer_custody_mismatches(state)@.
timerCustodyMismatches :: Json -> [Json]
timerCustodyMismatches state = perTimer <> unexpected <> generationCheck <> acknowledgements
  where
    expected = arr (state .: "timer_expectations")
    custody = state .: "timer_custody"
    actual = arr (custody .: "timers")
    byIdentity = Map.fromList [(jsonText (timer .: "identity"), timer) | timer <- actual]
    mismatch identity fieldName e o = Object [("identity", identity), ("field", String fieldName), ("expected", e), ("observed", o)]
    compatible = \case
      "scheduled" -> ["armed"]
      "due" -> ["armed", "matured"]
      "acknowledged" -> ["matured"]
      "canceled" -> ["cancelled", "superseded", "retired"]
      _ -> [] :: [Text]
    perTimer = concatMap one expected
    one timer =
      let identity = timer .: "identity"
       in case Map.lookup (jsonText identity) byIdentity of
            Nothing -> [mismatch identity "presence" (Bool True) (Bool False)]
            Just observed ->
              let status = jsonText (timer .: "status")
               in [ mismatch identity attribute (timer .: attribute) (observed .: attribute)
                  | attribute <- ["incarnation", "sequence", "head", "due_at", "matured_at"]
                  , observed .: attribute /= timer .: attribute
                  ]
                    <> [ mismatch identity "status" (String status) (observed .: "state")
                       | observed .: "state" `notElem` map String (compatible status)
                       ]
                    <> [ mismatch identity "maturity_delivered" (Bool True) (observed .: "maturity_delivered")
                       | status == "acknowledged"
                       , observed .: "maturity_delivered" /= Bool True || not (isBoolJson (observed .: "maturity_delivered"))
                       ]
    expectedIdentities = Set.fromList [jsonText (timer .: "identity") | timer <- expected]
    unexpected =
      [ mismatch (String identity) "presence" (Bool False) (Bool True)
      | identity <- Set.toAscList (Map.keysSet byIdentity `Set.difference` expectedIdentities)
      ]
    operations = arr (custody .: "operations")
    generations = [op .: "generation" | op <- operations]
    expectedGenerations = map Int [1 .. toInteger (length operations)]
    generationCheck =
      [ mismatch (String "timer-operations") "generations" (Array expectedGenerations) (Array generations)
      | generations /= expectedGenerations
      ]
    acknowledgements =
      [ mismatch (op .: "identity") "acknowledged" (Bool True) (op .: "acknowledged")
      | op <- operations
      , op .: "acknowledged" /= Bool True || not (isBoolJson (op .: "acknowledged"))
      ]
    isBoolJson = \case
      Bool _ -> True
      _ -> False

-- ---------------------------------------------------------------------------
-- The World

-- | @ReadinessWorld(root, budget, seed=seed)@.
data ReadinessWorld = ReadinessWorld
  { profile :: ReadinessProfile
  , world :: IORef (World IO Generation)
  , delivery :: IORef Integer
  }

newReadinessWorld :: FilePath -> BudgetV4 -> Maybe Integer -> IO ReadinessWorld
newReadinessWorld root budget seed = newReadinessWorldWith root budget seed (const (pure ())) readinessChecker

-- | Construct with a hook that prepares the profile before the first
-- generation starts, and the checker to install (the reference's tests
-- monkeypatch @HostService@ and @ReadinessChecker.check@ before
-- constructing the World).
newReadinessWorldWith :: FilePath -> BudgetV4 -> Maybe Integer -> (ReadinessProfile -> IO ()) -> Checker -> IO ReadinessWorld
newReadinessWorldWith root budget seed prepare checker = do
  profile <- newReadinessProfile root
  prepare profile
  created <-
    World.newWorld
      WorldConfig
        { profile = readinessProfile profile
        , budget = SomeBudgetV4 budget
        , checkers = [checker]
        , seed
        , progress = Nothing
        }
  w <- either throwIO pure created
  ReadinessWorld profile <$> newIORef w <*> newIORef 0

-- | Run World operations; a refusal is thrown as 'DstFailure'.
inWorld :: ReadinessWorld -> WorldT IO Generation a -> IO a
inWorld rw body = do
  w <- readIORef rw.world
  (result, w') <- World.runWorldT body w
  writeIORef rw.world w'
  either throwIO pure result

-- | @timeline()@.
timeline :: ReadinessWorld -> IO ReadinessTimeline
timeline rw = ReadinessTimeline rw <$> inWorld rw World.timeline

-- | @restart()@.
restart :: ReadinessWorld -> IO ReadinessTimeline
restart rw = inWorld rw World.restart >> timeline rw

-- | @artifact(scenario_id)@.
artifact :: ReadinessWorld -> Text -> IO AnyArtifact
artifact rw scenarioId = inWorld rw (World.artifact scenarioId)

-- | @close()@.
closeWorld :: ReadinessWorld -> IO ()
closeWorld rw = inWorld rw World.close

-- | @ReadinessTimeline@: the business-readable facade over one revocable
-- Petrus Timeline.
data ReadinessTimeline = ReadinessTimeline
  { owner :: ReadinessWorld
  , timeline' :: Timeline.Timeline
  }

command :: ReadinessTimeline -> Text -> Json -> IO ApplyResult
command t name payload = inWorld t.owner (Timeline.command t.timeline' name payload)

requireCurrent :: ReadinessTimeline -> IO ()
requireCurrent t = do
  current <- inWorld t.owner World.generation
  when (current /= Just t.timeline'.generation) $
    throwIO (StaleGeneration ("readiness Timeline generation " <> showT t.timeline'.generation <> " is stale"))

pending :: ReadinessTimeline -> IO Bool
pending t = requireCurrent t >> ((> 0) <$> inWorld t.owner World.pendingCount)

step :: ReadinessTimeline -> IO ApplyResult
step t = requireCurrent t >> ((.result) <$> inWorld t.owner World.step)

-- | The keyword arguments of @set_pull_request@.
data PullRequest = PullRequest
  { head :: Text
  , base :: Text
  , policy :: Text
  , lifecycle :: Text
  , strictBase :: Bool
  , baseCurrent :: Bool
  , mergeable :: Bool
  }

-- | An active, mergeable, current pull request at a head.
activePullRequest :: Text -> PullRequest
activePullRequest h =
  PullRequest {head = h, base = baseSha, policy = readinessPolicyDigest, lifecycle = "active", strictBase = True, baseCurrent = True, mergeable = True}

setPullRequest :: ReadinessTimeline -> PullRequest -> IO ApplyResult
setPullRequest t pr =
  command t "readiness.github.pr.set" $
    Object
      [ ("subject", String subject)
      ,
        ( "authority"
        , Object
            [ ("installation", Int 44)
            , ("repository", Int 31)
            , ("pull_request", Int 7)
            , ("head", String pr.head)
            , ("base", String pr.base)
            , ("policy", String pr.policy)
            , ("lifecycle", String pr.lifecycle)
            , ("strict_base", Bool pr.strictBase)
            , ("base_current", Bool pr.baseCurrent)
            , ("mergeable", Bool pr.mergeable)
            ]
        )
      ]

setCi :: ReadinessTimeline -> Text -> [Text] -> [(Text, Text)] -> IO ApplyResult
setCi t h required checks =
  command t "readiness.github.ci.set" $
    Object
      [ ("subject", String subject)
      , ("head", String h)
      , ("required_checks", Array (map String required))
      , ("checks", Array [Object [("name", String n), ("run", Int 101), ("attempt", Int 1), ("status", String s)] | (n, s) <- Map.toAscList (Map.fromList checks)])
      ]

setReview :: ReadinessTimeline -> Text -> Text -> [Json] -> IO ApplyResult
setReview t h status found =
  command t "readiness.github.review.set" $
    Object [("subject", String subject), ("head", String h), ("status", String status), ("findings", Array found)]

setHumanComment :: ReadinessTimeline -> Integer -> Text -> Text -> IO ApplyResult
setHumanComment t comment fixture author =
  command t "readiness.github.human.comment" $
    Object
      [ ("subject", String subject)
      , ("comment", Int comment)
      , ("author", String author)
      , ("fixture", String fixture)
      , ("digest", String (strictDigest (Object [("fixture", String fixture)])))
      ]

setAgentTerminal :: ReadinessTimeline -> Text -> Text -> Text -> Integer -> IO ApplyResult
setAgentTerminal t operation fixture status attempt =
  command t "readiness.agent.terminal" $
    Object
      [ ("subject", String subject)
      , ("operation", String operation)
      , ("attempt", Int attempt)
      , ("status", String status)
      , ("fixture", String fixture)
      , ("digest", String (strictDigest (Object [("fixture", String fixture), ("status", String status)])))
      ]

-- | @emit_webhook(event, action=action)@: the delivery id.
emitWebhook :: ReadinessTimeline -> Text -> Text -> IO Text
emitWebhook t event action = do
  n <- atomicModifyIORef' t.owner.delivery (\d -> (d + 1, d + 1))
  let delivery = deliveryUuid n
      fixture = event <> ":" <> action
  _ <-
    command t "readiness.github.webhook.emit" $
      Object
        [ ("subject", String subject)
        , ("delivery", String delivery)
        , ("event", String event)
        , ("fixture", String fixture)
        , ("digest", String (strictDigest (Object [("event", String event), ("fixture", String fixture)])))
        ]
  pure delivery

deliverWebhook :: ReadinessTimeline -> Text -> IO ApplyResult
deliverWebhook t delivery = command t "readiness.github.webhook.deliver" (Object [("delivery", String delivery)])

loseEffectResponse :: ReadinessTimeline -> Text -> IO ()
loseEffectResponse t kind = faultEffect t kind "after_acceptance_before_response" 1

faultEffect :: ReadinessTimeline -> Text -> Text -> Integer -> IO ()
faultEffect t kind cut occurrence =
  inWorld t.owner . Timeline.activateFault t.timeline' $
    (Timeline.fault "readiness.github.effect" ("effect:" <> kind)) {Timeline.occurrence = occurrence, Timeline.payload = Object [("cut", String cut)]}

faultGitPublication :: ReadinessTimeline -> Text -> Text -> Integer -> IO ()
faultGitPublication t operation cut occurrence =
  inWorld t.owner . Timeline.activateFault t.timeline' $
    (Timeline.fault "readiness.git.publish" ("git:" <> operation)) {Timeline.occurrence = occurrence, Timeline.payload = Object [("cut", String cut)]}

-- | @advance_time(seconds)@: step until the World reaches the target.
advanceTime :: ReadinessTimeline -> Integer -> IO ApplyResult
advanceTime t seconds = do
  result <- command t "readiness.time.advance" (Object [("seconds", Int seconds)])
  let target = fromMaybe 0 (intOf (result.value .: "target"))
      loop = do
        now <- inWorld t.owner World.currentInstant
        when (now < target) (inWorld t.owner World.step >> loop)
  loop
  pure result

revealEffect :: ReadinessTimeline -> Text -> IO ApplyResult
revealEffect t operation = command t "readiness.github.effect.reveal" (Object [("subject", String subject), ("operation", String operation)])

observe :: ReadinessTimeline -> IO Observation
observe t = inWorld t.owner (Timeline.observeWith t.timeline' "readiness.state" (Object []))

-- | @run_until(name, predicate)@ over the observed state.
runUntil :: ReadinessTimeline -> Text -> (Json -> Bool) -> IO Observation
runUntil t _ predicate = inWorld t.owner (Timeline.runUntilWith t.timeline' "readiness.state" (Object []) (predicate . (.value)))

crash :: ReadinessTimeline -> Text -> IO ()
crash t cut = inWorld t.owner (Timeline.crash t.timeline' cut)

beginFair :: ReadinessTimeline -> IO ()
beginFair t = inWorld t.owner (Timeline.beginFair t.timeline')

-- | @converge()@: drain fairly, observe, and finish with the disposition
-- the independent expectation names.
converge :: ReadinessTimeline -> IO Observation
converge t = do
  beginFair t
  let drain = do
        remaining <- inWorld t.owner World.pendingCount
        when (remaining > 0) (inWorld t.owner World.step >> drain)
  drain
  o <- observe t
  let ending = case o.value .: "expected" .: "disposition" of
        String d
          | d `elem` ["ready", "terminal"] -> Converged
          | d == "quarantined" -> Quarantined
        _ -> Quiescent
  inWorld t.owner (Timeline.finish t.timeline' ending)
  pure o

-- | @replay_readiness(artifact, root)@.
replayReadiness :: AnyArtifact -> FilePath -> IO (Either DstFailure AnyReplayResult)
replayReadiness a root = do
  profile <- newReadinessProfile root
  case registerProfile (readinessProfile profile) emptyRegistry >>= registerChecker readinessChecker of
    Left failure -> pure (Left failure)
    Right registry -> replay registry a

_unused :: (ReadinessExpectation, Json -> Int, Maybe Int -> Bool)
_unused = (undefined, const 0, isNothing)
