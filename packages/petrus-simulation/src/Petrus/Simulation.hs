-- | Bounded production of portable, implementation-free simulation results:
-- a port of @petrus.simulation@ (profile @implementation-free-v1@).
--
-- 'simulate' admits one fixed build and one initial marking under the
-- profile's bounds, runs one fresh Engine (instance @simulation@, an
-- in-memory History, a Dispatch that refuses all use, a simulated clock at
-- 0) for at most @max_actions@ actions, and returns one Net document, byte
-- for byte what the reference returns: one @simulated@ Timeline entry per
-- canonical History record, each with its complete marking and the record
-- in its metadata, the first entry also carrying the profile, the scenario
-- and the outcome.
--
-- Refusals are values. A 'ProfileError' is the reference's
-- @SimulationProfileError@ (the run is outside the profile), with the
-- reference's message; an 'UnexpectedError' is any other failure (the
-- reference raises another exception), with a diagnostic.
module Petrus.Simulation
  ( -- * Running
    simulate
  , simulateWith
  , SimulationError (..)
  , simulationErrorMessage

    -- * The profile
  , simulationProfile
  , simulationProfileWith
  , profileName

    -- * Bounds
  , SimulationBounds (..)
  , defaultBounds

    -- * Pieces
  , admit
  , maxActionsFromJson
  , forbiddenDispatch
  , SimulationProfileException (..)
  ) where

import Control.Exception (Exception (..), SomeAsyncException, SomeException, finally, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Cel.Impetus qualified as Cel
import Petrus.Engine qualified as Engine
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (InstanceCreated (..), Record (..))
import Petrus.Impetus.History.Replay (replayMarkings)
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Instance (statusText)
import Petrus.Impetus.NetDocument
  ( Provenance (..)
  , mkExecutionLineage
  , mkLineageEntry
  , placeMarkingFromJson
  , projectNetDocument
  , serializeNetDocument
  )
import Petrus.Impetus.Petrinet
  ( Arc (..)
  , ArcMode (..)
  , Cel
  , CompletionDeclaration (..)
  , FilterDeclaration (..)
  , GuardDeclaration (..)
  , Marking
  , Number (..)
  , Place (..)
  , Timer (..)
  , Token (..)
  , Transition (..)
  , celExpression
  , emptyMarking
  , hasPlace
  , hasTransition
  , lookupPlace
  , markingToList
  , netArcs
  , netCompletion
  , netPathText
  , netPlaceOrder
  , netPlaces
  , netTransitionOrder
  , netTransitions
  , placeTokens
  )
import Petrus.Json
  ( EncodeOptions (..)
  , Json (..)
  , compact
  , dumps
  , encodeErrorMessage
  )
import Petrus.Activity.Number (reprNumber)
import Petrus.Json.Python (pythonOptionalStrRepr, pythonRepr, pythonStrRepr)
import Petrus.Motus.Dispatch (Dispatch (..))
import Petrus.Observation qualified as Observation

-- ---------------------------------------------------------------------------
-- Bounds

-- | The profile's bounds (the reference's module constants). Tests lower
-- them as the reference's tests monkeypatch the constants.
data SimulationBounds = SimulationBounds
  { places :: Int
  , transitions :: Int
  , arcs :: Int
  , initialTokens :: Int
  , initialPayloadBytes :: Int
  , actions :: Int
  , retainedTokens :: Int
  , retainedPayloadBytes :: Int
  , historyRecords :: Int
  , historyPayloadBytes :: Int
  , resultBytes :: Int
  , candidateOffers :: Int
  -- ^ @MAX_CANDIDATE_OFFERS@, the profile's @reachable_input_scans@.
  , celBytes :: Int
  , definitionBytes :: Int
  , requestBodyBytes :: Int
  , connectionTimeoutSeconds :: Int
  }
  deriving stock (Eq, Show)

-- | @implementation-free-v1@'s bounds.
defaultBounds :: SimulationBounds
defaultBounds =
  SimulationBounds
    { places = 128
    , transitions = 128
    , arcs = 512
    , initialTokens = 512
    , initialPayloadBytes = 1000000
    , actions = 256
    , retainedTokens = 4096
    , retainedPayloadBytes = 4194304
    , historyRecords = 50000
    , historyPayloadBytes = 4194304
    , resultBytes = 4194304
    , candidateOffers = 10000
    , celBytes = 4096
    , definitionBytes = 1000000
    , requestBodyBytes = 1048576
    , connectionTimeoutSeconds = 5
    }

profileName :: Text
profileName = "implementation-free-v1"

-- ---------------------------------------------------------------------------
-- Errors

-- | Why a run produced no document.
data SimulationError
  = -- | @SimulationProfileError@: the run is outside the profile.
    ProfileError Text
  | -- | Any other failure (an Engine or projection refusal).
    UnexpectedError Text
  deriving stock (Eq, Show)

simulationErrorMessage :: SimulationError -> Text
simulationErrorMessage = \case
  ProfileError message -> message
  UnexpectedError message -> message

-- | A 'ProfileError' thrown across the Engine (by 'forbiddenDispatch').
newtype SimulationProfileException = SimulationProfileException Text
  deriving stock (Show)

instance Exception SimulationProfileException

refuse :: Text -> Either SimulationError a
refuse = Left . ProfileError

-- | @_ForbiddenDispatch@: every dispatch is a profile refusal; nothing is
-- ever collected.
forbiddenDispatch :: Dispatch
forbiddenDispatch =
  Dispatch
    { dispatch = \_ _ -> throwIO (SimulationProfileException "implementation-free-v1 forbids Dispatch use")
    , collect = pure []
    , cancel = Nothing
    }

-- ---------------------------------------------------------------------------
-- Encoding helpers

-- json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
canonical :: EncodeOptions
canonical = compact {sortKeys = True}

-- | @_encoded_size(value)@.
encodedSize :: Json -> Either Text Int
encodedSize value = either (Left . T.pack . encodeErrorMessage) (Right . BS.length) (dumps canonical value)

utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | The reference's @max_actions@ check for an untyped value (what a
-- caller holding JSON would pass): an integer, not a boolean, from 1
-- through the actions bound.
maxActionsFromJson :: SimulationBounds -> Json -> Either SimulationError Int
maxActionsFromJson bounds = \case
  Int n | 1 <= n && n <= toInteger bounds.actions -> Right (fromInteger n)
  other -> refuse ("max_actions must be an integer from 1 through " <> tshow bounds.actions <> ", got " <> pythonRepr other)

-- ---------------------------------------------------------------------------
-- Admission

-- | @_admit(built, initial_marking, max_actions)@: every profile check,
-- in the reference's order, before any Engine exists. Returns the
-- projected initial marking (the scenario's @initial_marking@) and the
-- marking to run.
admit :: SimulationBounds -> BuiltNet -> Marking -> Int -> Either SimulationError (Json, Marking)
admit bounds built initial maxActions = do
  unless (1 <= maxActions && maxActions <= bounds.actions) $
    refuse ("max_actions must be an integer from 1 through " <> tshow bounds.actions <> ", got " <> tshow maxActions)
  let net = built.net
      arcList = netArcs net
  forM_
    [ ("places", Map.size (netPlaces net), bounds.places)
    , ("transitions", Map.size (netTransitions net), bounds.transitions)
    , ("arcs", length arcList, bounds.arcs)
    ]
    $ \(label, actual, limit) ->
      when (actual > limit) $
        refuse ("implementation-free-v1 " <> label <> " limit is " <> tshow limit <> ", found " <> tshow actual)
  unless (Map.null built.handlers) $ refuse "implementation-free-v1 forbids BuiltNet handler implementations"
  unless (Map.null built.guards) $ refuse "implementation-free-v1 forbids BuiltNet guard implementations"
  let transitionList = [t | path <- netTransitionOrder net, Just t <- [Map.lookup path (netTransitions net)]]
  forM_ transitionList $ \transition -> do
    let path = netPathText transition.path
    when (isJust transition.handler) $
      refuse ("implementation-free-v1 requires transition " <> path <> " handler to be absent")
    forM_ transition.guards $ \case
      GuardCel expression -> checkCel bounds expression ("transition " <> path <> " guard")
      _ -> refuse ("implementation-free-v1 requires transition " <> path <> " guards to be inline Cel")
    forM_ transition.timers $ \timer -> do
      let (kind, value) = case timer of
            Delay duration -> ("Delay", duration)
            Until instant -> ("Until", instant)
      case value of
        IntNumber n | n >= 0 -> pure ()
        _ ->
          refuse
            ( "implementation-free-v1 requires transition "
                <> path
                <> " "
                <> kind
                <> " value to be an exact non-boolean non-negative integer, got "
                <> reprNumber value
            )
  forM_ (zip [0 :: Int ..] arcList) $ \(position, arc) -> do
    when (arc.weight /= 1) $
      refuse
        ( "implementation-free-v1 requires arc "
            <> tshow position
            <> " weight to be exact non-boolean integer 1, got "
            <> tshow arc.weight
        )
    case arc.filter of
      Nothing -> pure ()
      Just (FilterCel expression) -> checkCel bounds expression ("arc " <> tshow position <> " filter")
      Just (FilterSymbol _) -> refuse ("implementation-free-v1 requires arc " <> tshow position <> " filter to be inline Cel")
  forM_ (netTransitionOrder net) $ \path -> do
    let name = netPathText path
        selecting = [a | a <- arcList, a.target == path, hasPlace a.source net, a.mode == Consume || a.mode == Read]
        outputs = [a | a <- arcList, a.source == path, hasPlace a.target net]
    when (length selecting > 1) $
      refuse
        ( "implementation-free-v1 allows transition "
            <> name
            <> " at most one selecting input arc, found "
            <> tshow (length selecting)
        )
    case selecting of
      first : _ | first.mode /= Consume -> refuse ("implementation-free-v1 requires transition " <> name <> "'s selecting input arc to consume")
      _ -> pure ()
    when (length outputs > 1) $
      refuse ("implementation-free-v1 allows transition " <> name <> " at most one output arc, found " <> tshow (length outputs))
  case netCompletion net of
    Nothing -> pure ()
    Just (CompletionCel expression) -> checkCel bounds expression "completion"
    Just (CompletionSymbol _) -> refuse "implementation-free-v1 requires completion to be inline Cel"
  definitionSize <- either (refuse . ("canonical definition must be strict JSON-faithful: " <>)) Right $ do
    projected <- either (Left . Observation.observationErrorText) Right (Observation.definition net)
    encodedSize projected
  when (definitionSize > bounds.definitionBytes) $
    refuse
      ( "implementation-free-v1 canonical definition limit is "
          <> tshow bounds.definitionBytes
          <> " bytes, found "
          <> tshow definitionSize
      )
  let queues = markingToList initial
      tokenCount = sum (map (length . snd) queues)
  when (tokenCount > bounds.initialTokens) $
    refuse ("implementation-free-v1 initial token limit is " <> tshow bounds.initialTokens <> ", found " <> tshow tokenCount)
  forM_ queues $ \(place, tokens) -> do
    let name = netPathText place
    unless (hasPlace place net) $ refuse ("implementation-free-v1 initial marking names foreign place " <> name)
    forM_ tokens $ \token -> do
      case token.color of
        Just "" ->
          refuse ("implementation-free-v1 token color at " <> name <> " must be None or a nonempty exact str, got ''")
        _ -> pure ()
      case lookupPlace place net >>= (.color) of
        Just expected
          | token.color /= Just expected ->
              refuse
                ( "implementation-free-v1 token color "
                    <> pythonOptionalStrRepr token.color
                    <> " does not match place "
                    <> name
                    <> " color "
                    <> pythonStrRepr expected
                )
        _ -> pure ()
      -- _strict_detach: json.dumps(data, ensure_ascii=False, allow_nan=False)
      case dumps compact token.payload of
        Right _ -> pure ()
        Left refusal ->
          refuse ("initial token data at " <> name <> " must be strict JSON-faithful: " <> T.pack (encodeErrorMessage refusal))
  projected <- either (Left . UnexpectedError . Observation.observationErrorText) Right (Observation.marking initial)
  payloadSize <- either (Left . UnexpectedError) Right (encodedSize projected)
  when (payloadSize > bounds.initialPayloadBytes) $
    refuse
      ( "implementation-free-v1 initial token payload limit is "
          <> tshow bounds.initialPayloadBytes
          <> " bytes, found "
          <> tshow payloadSize
      )
  let incidence place = length [a | a <- arcList, a.source == place, hasTransition a.target net]
      maximumIncidence = maximum (0 : map incidence (netPlaceOrder net))
      scanBound = tokenCount * maximumIncidence
  when (scanBound > bounds.candidateOffers) $
    refuse
      ( "implementation-free-v1 reachable input-scan limit is "
          <> tshow bounds.candidateOffers
          <> ", found bound "
          <> tshow scanBound
          <> " from "
          <> tshow tokenCount
          <> " initial tokens and maximum place incidence "
          <> tshow maximumIncidence
      )
  pure (projected, initial)

checkCel :: SimulationBounds -> Cel -> Text -> Either SimulationError ()
checkCel bounds expression subject = do
  let size = utf8Length (celExpression expression)
  when (size > bounds.celBytes) $
    refuse
      ( "implementation-free-v1 CEL expression limit is "
          <> tshow bounds.celBytes
          <> " UTF-8 bytes; "
          <> subject
          <> " has "
          <> tshow size
      )

-- ---------------------------------------------------------------------------
-- The profile

-- | @simulation_profile(built)@: validate one fixed build (with an empty
-- marking and one action) and return its hosted-run profile.
simulationProfile :: BuiltNet -> Either SimulationError Json
simulationProfile = simulationProfileWith defaultBounds

simulationProfileWith :: SimulationBounds -> BuiltNet -> Either SimulationError Json
simulationProfileWith bounds built = do
  _ <- admit bounds built emptyMarking 1
  projected <- either (Left . UnexpectedError . Observation.observationErrorText) Right (Observation.definition built.net)
  pure $
    Object
      [ ("format", String "petrus-simulation-service-profile")
      , ("version", Int 1)
      , ("profile", String profileName)
      , ("definition", projected)
      , ( "bounds"
        , Object
            [ ("places", int bounds.places)
            , ("transitions", int bounds.transitions)
            , ("arcs", int bounds.arcs)
            , ("initial_tokens", int bounds.initialTokens)
            , ("initial_payload_bytes", int bounds.initialPayloadBytes)
            , ("actions", int bounds.actions)
            , ("retained_tokens", int bounds.retainedTokens)
            , ("retained_payload_bytes", int bounds.retainedPayloadBytes)
            , ("history_records", int bounds.historyRecords)
            , ("history_payload_bytes", int bounds.historyPayloadBytes)
            , ("result_bytes", int bounds.resultBytes)
            , ("reachable_input_scans", int bounds.candidateOffers)
            , ("cel_bytes", int bounds.celBytes)
            , ("definition_bytes", int bounds.definitionBytes)
            , ("request_body_bytes", int bounds.requestBodyBytes)
            , ("connection_timeout_seconds", int bounds.connectionTimeoutSeconds)
            , ("concurrent_simulations", Int 1)
            ]
        )
      ]
  where
    int = Int . toInteger

-- ---------------------------------------------------------------------------
-- Running

-- | @simulate(built, initial_marking, max_actions=…)@: run one fresh
-- bounded Engine and return one portable Net document.
simulate :: BuiltNet -> Marking -> Int -> IO (Either SimulationError ByteString)
simulate = simulateWith defaultBounds

simulateWith :: SimulationBounds -> BuiltNet -> Marking -> Int -> IO (Either SimulationError ByteString)
simulateWith bounds built initial maxActions = case admit bounds built initial maxActions of
  Left refusal -> pure (Left refusal)
  Right (projectedInitial, frozen) -> do
    outcome <- try (run bounds built projectedInitial frozen maxActions)
    case outcome of
      Right result -> pure result
      Left e
        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        | Just (SimulationProfileException message) <- fromException e -> pure (Left (ProfileError message))
        | Just (ProfileAbort message) <- fromException e -> pure (Left (ProfileError message))
        | otherwise -> pure (Left (UnexpectedError (T.pack (displayException (e :: SomeException)))))

-- A profile refusal raised from inside the run loop.
newtype ProfileAbort = ProfileAbort Text
  deriving stock (Show)

instance Exception ProfileAbort

abort :: Text -> IO a
abort = throwIO . ProfileAbort

unexpected :: Either Text a -> IO a
unexpected = either (throwIO . userError . T.unpack) pure

run :: SimulationBounds -> BuiltNet -> Json -> Marking -> Int -> IO (Either SimulationError ByteString)
run bounds built projectedInitial frozen maxActions = do
  let net = built.net
  store <- inMemoryHistoryStore
  clock <- Engine.simulatedClock (IntNumber 0)
  engine <-
    Engine.create
      net
      "simulation"
      store
      forbiddenDispatch
      Engine.defaultEngineOptions
        { Engine.marking = frozen
        , Engine.at = IntNumber 0
        , Engine.clock = Just clock
        , Engine.celCompilers = Cel.celCompilers
        }
  (`finally` Engine.close engine) $ do
    -- History payload already summed: (records counted, bytes).
    summed <- newIORef (0 :: Int, 0 :: Int)
    let inputArcs = [a.source | a <- netArcs net, hasPlace a.source net, hasTransition a.target net]
        checkResources = do
          current <- Engine.marking engine
          let queues = markingToList current
              retained = sum (map (length . snd) queues)
          when (retained > bounds.retainedTokens) $
            abort ("implementation-free-v1 retained token limit is " <> tshow bounds.retainedTokens <> ", found " <> tshow retained)
          _ <-
            foldM
              ( \total (place, tokens) -> do
                  let named = total + utf8Length (netPathText place)
                  foldM
                    ( \acc token -> do
                        size <- unexpected (encodedSize (Object [("color", maybe Null String token.color), ("data", token.payload)]))
                        let acc' = acc + size
                        when (acc' > bounds.retainedPayloadBytes) $
                          abort
                            ( "implementation-free-v1 retained token payload limit is "
                                <> tshow bounds.retainedPayloadBytes
                                <> " bytes, found more than that limit"
                            )
                        pure acc'
                    )
                    named
                    (toList tokens)
              )
              0
              queues
          history <- Engine.records engine
          let count = length history
          when (count > bounds.historyRecords) $
            abort ("implementation-free-v1 History record limit is " <> tshow bounds.historyRecords <> ", found " <> tshow count)
          (seen, bytes) <- readIORef summed
          total <-
            foldM
              ( \acc record -> do
                  size <- unexpected (encodedSize (encodeRecord record))
                  let acc' = acc + size
                  when (acc' > bounds.historyPayloadBytes) $
                    abort
                      ( "implementation-free-v1 History payload limit is "
                          <> tshow bounds.historyPayloadBytes
                          <> " bytes, found more than that limit"
                      )
                  pure acc'
              )
              bytes
              (drop seen history)
          writeIORef summed (count, total)
          busy <- Engine.inFlight engine
          unless (null busy) $ abort "implementation-free-v1 forbids in-flight work"
        checkInputScans = do
          current <- Engine.marking engine
          let scans = sum [length (placeTokens source current) | source <- inputArcs]
          when (scans > bounds.candidateOffers) $
            abort
              ( "implementation-free-v1 input-scan limit is "
                  <> tshow bounds.candidateOffers
                  <> " before advance, found "
                  <> tshow scans
              )
        loop applied
          | applied >= maxActions = pure (applied, "action_limit" :: Text)
          | otherwise = do
              checkInputScans
              outcome <- Engine.advance engine
              when outcome.waiting $ abort "implementation-free-v1 forbids waiting for external work"
              if not outcome.ready
                then pure (applied, "rest")
                else do
                  checkResources
                  loop (applied + 1)
    checkResources
    (applied, reason) <- loop 0
    history <- Engine.records engine
    instanceName <- case history of
      RInstanceCreated created : _ -> pure created.instanceId
      _ -> throwIO (userError "the first History record is not InstanceCreated")
    finalStatus <- Engine.status engine
    let summary =
          [ ("profile", String profileName)
          , ("instance", String instanceName)
          , ( "scenario"
            , Object [("start_instant", Int 0), ("initial_marking", projectedInitial), ("max_actions", Int (toInteger maxActions))]
            )
          , ("outcome", Object [("actions_applied", Int (toInteger applied)), ("reason", String reason)])
          , ("status", String (statusText finalStatus))
          ]
    markings <- unexpected (replayMarkings history)
    entries <- forM (zip3 [0 :: Integer ..] history markings) $ \(index, record, state) -> do
      projected <- unexpected (either (Left . Observation.observationErrorText) Right (Observation.marking state))
      placeMarkings <- case projected of
        Array items -> unexpected (traverse placeMarkingFromJson items)
        _ -> throwIO (userError "a projected marking is not an array")
      unexpected $
        mkLineageEntry
          index
          (if index == 0 then Nothing else Just (index - 1))
          Simulated
          placeMarkings
          ((if index == 0 then summary else []) ++ [("history_record", encodeRecord record)])
    lineage <- unexpected (mkExecutionLineage (toInteger (length entries) - 1) entries)
    document <- unexpected (projectNetDocument net Nothing (Just lineage))
    payload <- unexpected (serializeNetDocument document)
    pure $
      if BS.length payload > bounds.resultBytes
        then
          Left
            ( ProfileError
                ( "implementation-free-v1 serialized result limit is "
                    <> tshow bounds.resultBytes
                    <> " bytes, found "
                    <> tshow (BS.length payload)
                )
            )
        else Right payload
