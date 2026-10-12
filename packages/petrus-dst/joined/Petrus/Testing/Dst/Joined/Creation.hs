{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The joined initial-creation worlds: a port of the reference's
-- @tests/dst/joined_creation_world.py@ (its four profiles and stories; the
-- checkers live in "Petrus.Testing.Dst.Joined.Checkers").
--
-- Each profile creates or loads a real Absurd Engine over PostgreSQL
-- History only through the public Engine doors; the authority connection
-- is wrapped exactly as @JoinedCreationFaultConnection@ wraps psycopg's
-- @execute@, @commit@ and @rollback@: the commit that carries
-- @InstanceCreated@ may be refused before it reaches the server, or have
-- its acknowledgement lost after it did.
module Petrus.Testing.Dst.Joined.Creation
  ( Variant (..)
  , CreationGeneration (..)
  , CreationProfile (..)
  , creationProfile
  , creationBudget
  , buildCreationArtifact
  ) where

import Control.Exception (finally, onException, throwIO)
import Control.Monad (forM, unless, void, when)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd (AbsurdSession (..), absurdSession, defaultAbsurdEngineOptions, openAbsurdEngine)
import Petrus.Engine.Absurd qualified as Absurd
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Impetus.History.Records
  ( DeliveryRegistrationOpened (..)
  , InstanceCreated (..)
  , Record (..)
  , TokensInitialized (..)
  , recordName
  )
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common (engineCurrent, ensure, exactKeys, ioDoor, ioScenario, member, memberOf, path)
import Petrus.Testing.Dst.Joined.Checkers qualified as C
import Petrus.Testing.Dst.Joined.Identities qualified as Id
import Petrus.Testing.Dst.Joined.Support (payloadAbsent, probeRecords, pyEq, strs, withProbe)
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Json.Python.Exception (raised)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

-- | The four profile classes of the reference.
data Variant
  = -- | @JoinedCreationProfile@.
    Plain
  | -- | @JoinedCreationAckLossProfile@.
    PlainAckLoss
  | -- | @JoinedSourceCreationProfile@.
    Sourced
  | -- | @JoinedSourceCreationAckLossProfile@.
    SourcedAckLoss
  deriving stock (Eq, Show, Enum, Bounded)

sourced, losesAck :: Variant -> Bool
sourced v = v `elem` [Sourced, SourcedAckLoss]
losesAck v = v `elem` [PlainAckLoss, SourcedAckLoss]

-- | The class attributes.
data Config = Config
  { identity :: ProfileIdentity
  , instanceId :: Text
  , queue :: Text
  , faultName :: Text
  , faultTarget :: Text
  , faultDisposition :: FaultDisposition
  , observations :: [Text]
  }

configOf :: Variant -> Config
configOf = \case
  Plain ->
    Config
      Id.creationRefusalProfileIdentity
      plainInstance
      "dst_joined_creation"
      "history.commit-refuse"
      "instance_created"
      Refuse
      ["engine.joined-creation-authority", "joined-creation-absent", "joined-creation-recovered", "joined-creation-refused"]
  PlainAckLoss ->
    Config
      Id.creationAckLossProfileIdentity
      plainInstance
      "dst_joined_creation"
      "history.lose-ack"
      "instance_created_committed"
      Raise
      ["engine.joined-creation-authority", "joined-creation-ack-lost", "joined-creation-ack-recovered"]
  Sourced ->
    Config
      Id.creationSourceRefusalProfileIdentity
      sourceInstance
      "dst_joined_source_creation"
      "history.commit-refuse"
      "source_registration_initialized"
      Refuse
      [ "engine.joined-source-creation-authority"
      , "joined-source-creation-absent"
      , "joined-source-creation-recovered"
      , "joined-source-creation-refused"
      ]
  SourcedAckLoss ->
    Config
      Id.creationSourceAckLossProfileIdentity
      sourceInstance
      "dst_joined_source_creation"
      "history.lose-ack"
      "source_registration_initialized_committed"
      Raise
      ["engine.joined-source-creation-authority", "joined-source-creation-ack-lost", "joined-source-creation-ack-recovered"]

plainInstance, sourceInstance :: Text
plainInstance = "dst-world-joined-creation"
sourceInstance = "dst-world-joined-source-creation"

inputPlace, sourcePlace, outputPlace :: NetPath
inputPlace = path "input"
sourcePlace = path "source"
outputPlace = path "output"

netOf :: Text -> [NetPath] -> [Transition] -> [(NetPath, NetPath)] -> Net
netOf name places transitions arcs =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = map place places
        , transitions
        , arcs = map (uncurry arc) arcs
        , completion = Nothing
        , name = Just name
        }

-- | @creation_net()@ / @source_creation_net()@.
netFor :: Variant -> Net
netFor v
  | sourced v = netOf "dst-world-joined-source-creation" [outputPlace] [transition sourcePlace] [(sourcePlace, outputPlace)]
  | otherwise = netOf "dst-world-joined-creation" [inputPlace] [] []

-- | @WORLD_BUDGET@.
creationBudget :: SomeBudget
creationBudget =
  SomeBudget
    Budget
      { actions = 16
      , queuedCommands = 2
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 1
      , predicatePolls = 4
      , artifactBytes = 131072
      }

-- ---------------------------------------------------------------------------
-- JoinedCreationFaultConnection

data FaultConnection = FaultConnection
  { recordTypes :: IORef [Text]
  , refusal :: IORef (Maybe Text)
  , ackLoss :: IORef (Maybe Text)
  , attempts :: IORef [Json]
  }

newFaultConnection :: IORef [Json] -> IO FaultConnection
newFaultConnection attempts = do
  recordTypes <- newIORef []
  refusal <- newIORef Nothing
  ackLoss' <- newIORef Nothing
  pure FaultConnection {recordTypes, refusal, ackLoss = ackLoss', attempts}

-- | @refuse_creation_commit@ / @lose_creation_commit_ack@.
arm :: IORef (Maybe Text) -> Text -> Text -> IO ()
arm ref already message =
  readIORef ref >>= \case
    Just _ -> throwIO (raised "RuntimeError" already)
    Nothing -> writeIORef ref (Just message)

-- | @_attempt(accepted)@.
attemptOf :: FaultConnection -> Bool -> IO Json
attemptOf fc accepted = do
  types <- readIORef fc.recordTypes
  pure (Object [("accepted", Bool accepted), ("record_types", strs types)])

wrap :: FaultConnection -> AbsurdSession -> AbsurdSession
wrap fc session =
  session
    { Absurd.commit = do
        creation <- elem "InstanceCreated" <$> readIORef fc.recordTypes
        refused <- if creation then takeRef fc.refusal else pure Nothing
        case refused of
          Just message -> do
            attemptOf fc False >>= append fc.attempts
            throwIO (raised "OSError" message)
          Nothing -> pure ()
        session.commit
        when creation $ attemptOf fc True >>= append fc.attempts
        writeIORef fc.recordTypes []
        lost <- if creation then takeRef fc.ackLoss else pure Nothing
        mapM_ (throwIO . raised "OSError") lost
    , Absurd.rollback = session.rollback `finally` writeIORef fc.recordTypes []
    , observeHistory = \store ->
        let inner = session.observeHistory store
         in inner
              { extend = \batch -> do
                  inner.extend batch
                  modifyIORef' fc.recordTypes (<> map recordName batch)
              }
    }
  where
    takeRef ref = readIORef ref <* writeIORef ref Nothing
    append ref value = modifyIORef' ref (<> [value])

-- ---------------------------------------------------------------------------
-- Profiles

-- | @JoinedCreationGeneration@.
newtype CreationGeneration = CreationGeneration {engine :: IORef (Maybe Engine)}

-- | One profile instance and its profile-owned evidence.
data CreationProfile = CreationProfile
  { variant :: Variant
  , profile :: Profile IO CreationGeneration
  }

-- | @JoinedCreationProfile(dsn)@ and its subclasses.
creationProfile :: Variant -> ByteString -> IO CreationProfile
creationProfile variant dsn = do
  transactionAttempts <- newIORef []
  creationAttempts <- newIORef []
  commitRefusals <- newIORef (0 :: Integer)
  commitAckLosses <- newIORef (0 :: Integer)
  drops <- newIORef (0 :: Integer)
  closes <- newIORef (0 :: Integer)
  let cfg = configOf variant
      frontier = withProbe dsn $ \probe -> toInteger . length <$> probeRecords probe cfg.instanceId

      -- _open
      open create connection = do
        fc <- maybe (newFaultConnection transactionAttempts) pure connection
        authority <- Pg.connect dsn False
        listener <- Pg.connect dsn True `onFailure` Pg.close authority
        let options =
              Engine.defaultEngineOptions
                { Engine.marking =
                    if create && not (sourced variant)
                      then markingFromList [(inputPlace, [Token (Just "Initial") (Int 1)])]
                      else Engine.defaultEngineOptions.marking
                }
        openAbsurdEngine
          (wrap fc (absurdSession authority (Just listener)))
          (if create then CreateInstance else LoadInstance)
          (netFor variant)
          cfg.instanceId
          defaultAbsurdEngineOptions {Absurd.defaultQueue = cfg.queue}
          options

      -- _configure_fault
      configureFault = do
        matched <- faults cfg.faultTarget
        forM matched $ \f -> do
          when (f.name /= cfg.faultName || f.disposition /= cfg.faultDisposition) $
            raise "ValueError" ("unsupported joined-creation fault " <> pythonStrRepr f.name)
          unless (isObject f.payload && exactKeys ["message"] f.payload) $
            raise "ValueError" (cfg.faultName <> " requires an exact message payload")
          message <- case member "message" f.payload of
            String m -> pure m
            _ -> raise "ValueError" (cfg.faultName <> " message must be a string")
          liftIO (modifyIORef' (if f.name == "history.commit-refuse" then commitRefusals else commitAckLosses) (+ 1))
          pure (f.name, message)

      apply' g _ = do
        existing <- liftIO (readIORef g.engine)
        case existing of
          Just _ -> raise "RuntimeError" "joined creation generation already owns an Engine"
          Nothing -> pure ()
        expected <- configureFault
        fc <- liftIO (newFaultConnection transactionAttempts)
        ioScenario $
          mapM_
            ( \(name, message) ->
                if name == "history.commit-refuse"
                  then arm fc.refusal "joined creation commit refusal is already armed" message
                  else arm fc.ackLoss "joined creation acknowledgement loss is already armed" message
            )
            expected
        disposition <-
          catchError
            (ioScenario (open True (Just fc)) >>= \e -> liftIO (writeIORef g.engine (Just e)) >> pure Applied)
            ( \failure ->
                if failure.errorType == "OSError" && failure.errorMessage `elem` map snd expected
                  then pure RefusedExpected
                  else throwError failure
            )
        f <- ioScenario frontier
        let attempt = Object [("disposition", String (actionDispositionText disposition)), ("frontier", Int f)]
        liftIO (modifyIORef' creationAttempts (<> [attempt]))
        pure ApplyResult {disposition, value = attempt, scheduled = []}

      -- _observation_state
      state g = do
        records <- withProbe dsn (`probeRecords` cfg.instanceId)
        engine <- readIORef g.engine
        (engineRecords, engineTokens, current) <- case engine of
          Nothing -> pure ([], [], Nothing)
          Just e -> do
            rs <- Engine.records e
            m <- Engine.marking e
            current <- if sourced variant then Just <$> engineCurrent e else pure Nothing
            pure (map recordName rs, [t.payload | t <- toList (placeTokens inputPlace m)], current)
        tallies <- mapM readIORef [closes, commitAckLosses, commitRefusals]
        transactions <- readIORef transactionAttempts
        creations <- readIORef creationAttempts
        dropCount <- readIORef drops
        let base =
              [ ("canonical_instances", Array [String r.instanceId | RInstanceCreated r <- records])
              , ("canonical_tokens", Array [t.payload | RTokensInitialized r <- records, t <- r.tokens])
              , ("closes", Int (tallies !! 0))
              , ("commit_ack_losses", Int (tallies !! 1))
              , ("commit_refusals", Int (tallies !! 2))
              , ("creation_attempts", Array creations)
              , ("drops", Int dropCount)
              , ("engine_present", Bool (maybe False (const True) engine))
              , ("engine_record_types", strs engineRecords)
              , ("engine_tokens", Array engineTokens)
              , ("frontier", Int (toInteger (length records)))
              , ("record_types", strs (map recordName records))
              , ("transaction_attempts", Array transactions)
              ]
            registrations =
              [ ( "canonical_registrations"
                , Array
                    [ Object
                        [ ("key", String r.key)
                        , ("occurrence", maybe Null (Int . toInteger) r.occurrence)
                        , ("source", String (netPathText r.source))
                        ]
                    | RDeliveryRegistrationOpened r <- records
                    ]
                )
              , ("engine_armed", maybe (Array []) (member "armed") current)
              , ("engine_status", maybe Null (member "status") current)
              ]
        pure (Object (if sourced variant then base <> registrations else base))

      observe' g request = do
        unless (request.name `elem` cfg.observations) $
          raise "ValueError" ("unknown joined-creation observation " <> pythonStrRepr request.name)
        unless (payloadAbsent request.payload) $ raise "ValueError" "joined-creation observations do not accept parameters"
        ioScenario (state g)

      dispose g =
        readIORef g.engine >>= \case
          Just e -> Engine.close e `finally` writeIORef g.engine Nothing
          Nothing -> pure ()

      profile =
        Profile
          { identity = cfg.identity
          , validate = \c ->
              if c.name /= "engine.create" || not (pyEq c.payload (Object []))
                then throwError (ProfileError "ValueError" "joined-creation profile accepts only engine.create with an empty payload")
                else pure c
          , validateFault = \f ->
              if f.name /= cfg.faultName
                || f.target /= cfg.faultTarget
                || f.disposition /= cfg.faultDisposition
                || not (isObject f.payload && exactKeys ["message"] f.payload)
                || not (isString (member "message" f.payload))
                then throwError (ProfileError "ValueError" ("unsupported joined-creation fault for " <> cfg.identity.name))
                else pure f
          , create = do
              ref <- liftIO (newIORef Nothing)
              pure GenerationStart {generation = CreationGeneration ref, scheduled = []}
          , load = do
              f <- ioScenario frontier
              engine <- if f > 0 then Just <$> ioScenario (open False Nothing) else pure Nothing
              ref <- liftIO (newIORef engine)
              pure GenerationStart {generation = CreationGeneration ref, scheduled = []}
          , apply = apply'
          , observe = observe'
          , dropGeneration = \g -> ioDoor (modifyIORef' drops (+ 1) >> dispose g)
          , closeGeneration = \g -> ioDoor (modifyIORef' closes (+ 1) >> dispose g)
          , resourceUsage = Nothing
          }
  pure CreationProfile {variant, profile}
  where
    isObject = \case
      Object _ -> True
      _ -> False
    isString = \case
      String _ -> True
      _ -> False
    onFailure body cleanup = body `onException` cleanup

-- ---------------------------------------------------------------------------
-- Stories

type Story = WorldT IO CreationGeneration

is :: Observation -> Text -> Json -> Story ()
is o key expected = ensure (pyEq (memberOf key o) expected) ("observation " <> o.name <> " " <> key)

are :: Observation -> [(Text, Json)] -> Story ()
are o = mapM_ (uncurry (is o))

same :: Observation -> Observation -> Text -> Story ()
same o other key = is o key (memberOf key other)

-- | The four @build_joined_*creation_*_artifact(dsn)@ functions.
buildCreationArtifact :: Variant -> ByteString -> IO (Either DstFailure AnyArtifact)
buildCreationArtifact variant dsn = do
  p <- creationProfile variant dsn
  World.withWorld
    WorldConfig {profile = p.profile, budget = creationBudget, checkers = [checker], seed = Nothing, progress = Nothing}
    (story >> World.artifact scenarioId)
  where
    s = sourced variant
    prefix = if s then "joined-source-creation" else "joined-creation"
    cfg = configOf variant
    checker = if s then C.sourceCreationAuthorityChecker else C.creationAuthorityChecker
    scenarioId = prefix <> (if losesAck variant then "-ack-loss-world-v3" else "-commit-refusal-world-v3")
    types = strs (if s then ["InstanceCreated", "DeliveryRegistrationOpened"] else ["InstanceCreated", "TokensInitialized"])
    tx accepted = Object [("accepted", Bool accepted), ("record_types", types)]
    registrations = Array [Object [("key", String "default"), ("occurrence", Null), ("source", String "source")]]
    armedDefault = Array [Object [("key", String "default"), ("source", String "source")]]
    message
      | s && losesAck variant = "dst joined source registration initialization acknowledgement lost"
      | s = "dst joined source registration initialization commit refused"
      | losesAck variant = "dst joined creation acknowledgement lost"
      | otherwise = "dst joined creation commit refused"
    cut = T.replace "-" "_" prefix <> (if losesAck variant then "_committed_ack_lost" else "_commit_refused")
    create timeline expected = do
      result <- Timeline.command timeline "engine.create" (Object [])
      ensure (result.disposition == expected) ("engine.create disposition " <> actionDispositionText expected)
    -- The engine's own view agrees with the canonical History.
    engineAgrees o = do
      is o "engine_present" (Bool True)
      is o "engine_record_types" (memberOf "record_types" o)
      if s
        then are o [("engine_armed", armedDefault), ("engine_status", String "awaiting")]
        else is o "engine_tokens" (memberOf "canonical_tokens" o)
    story = do
      timeline <- World.timeline
      Timeline.activateFault
        timeline
        (Timeline.fault cfg.faultName cfg.faultTarget)
          { Timeline.disposition = cfg.faultDisposition
          , Timeline.payload = Object [("message", String message)]
          }
      create timeline RefusedExpected
      if losesAck variant
        then do
          lost <- Timeline.observe timeline (prefix <> "-ack-lost")
          are
            lost
            ( [ ("frontier", Int 2)
              , ("record_types", types)
              , ("canonical_instances", Array [String cfg.instanceId])
              , ("engine_present", Bool False)
              , ("commit_ack_losses", Int 1)
              , ("transaction_attempts", Array [tx True])
              ]
                <> if s then [("canonical_registrations", registrations)] else [("canonical_tokens", Array [Int 1]), ("commit_refusals", Int 0)]
            )
          Timeline.crash timeline cut
          void World.restart
          timeline' <- World.timeline
          recovered <- Timeline.observe timeline' (prefix <> "-ack-recovered")
          is recovered "frontier" (Int 2)
          mapM_ (same recovered lost) ["record_types", "canonical_instances", if s then "canonical_registrations" else "canonical_tokens"]
          engineAgrees recovered
          is recovered "creation_attempts" (Array [Object [("disposition", String (actionDispositionText RefusedExpected)), ("frontier", Int 2)]])
          same recovered lost "transaction_attempts"
          Timeline.finish timeline' ExternalWait
        else do
          refused <- Timeline.observe timeline (prefix <> "-refused")
          are
            refused
            ( [ ("frontier", Int 0)
              , ("record_types", Array [])
              , ("canonical_instances", Array [])
              , ("engine_present", Bool False)
              , ("transaction_attempts", Array [tx False])
              ]
                <> if s
                  then [("canonical_registrations", Array [])]
                  else [("canonical_tokens", Array []), ("commit_refusals", Int 1), ("commit_ack_losses", Int 0)]
            )
          Timeline.crash timeline cut
          void World.restart
          timeline' <- World.timeline
          absent <- Timeline.observe timeline' (prefix <> "-absent")
          are absent [("frontier", Int 0), ("engine_present", Bool False)]
          create timeline' Applied
          recovered <- Timeline.observe timeline' (prefix <> "-recovered")
          are
            recovered
            ( [ ("frontier", Int 2)
              , ("record_types", types)
              , ("canonical_instances", Array [String cfg.instanceId])
              , ("transaction_attempts", Array [tx False, tx True])
              ]
                <> if s then [("canonical_registrations", registrations)] else [("canonical_tokens", Array [Int 1])]
            )
          engineAgrees recovered
          Timeline.finish timeline' ExternalWait
