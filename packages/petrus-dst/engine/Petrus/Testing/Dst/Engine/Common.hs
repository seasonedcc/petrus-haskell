{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Shared plumbing of the Engine-backed DST worlds (the Haskell twins of
-- the reference's @tests/dst/*_world.py@ profiles).
--
-- * 'WorldTime' and 'worldClock': the reference's @WorldClock@, an Engine
--   'Clock' that can observe only the World's current logical instant. The
--   reference captures the @ScenarioContext@; here every door copies the
--   context's instant into a cell the clock reads ('syncTime'), which is
--   the same value because the World never moves time inside a door.
-- * 'PyException': an exception the profiles' own adapters raise with a
--   Python class name and @str()@ (@OSError(message)@ from a refusing
--   History or Dispatch).
-- * 'pythonError': how an exception escaping an Engine door reads in the
--   reference — its class and @str()@ — so the profiles compare expected
--   faults exactly as @isinstance(error, kind) and str(error) == message@.
-- * Engine reads: 'engineSnapshot' (the reference's @Engine.snapshot()@,
--   built on the observation seam) and History helpers.
module Petrus.Testing.Dst.Engine.Common
  ( -- * World time
    WorldTime
  , newWorldTime
  , syncTime
  , worldClock
  , worldProviderMs
    -- * Exceptions
  , PyException (..)
  , pythonError
  , runtimeErrorText
  , ioDoor
  , ioScenario
  , orRaise
    -- * Engine reads
  , engineSnapshot
  , engineCurrent
  , currentMember
  , recordTypes
  , historyLength
  , policyJson
  , invocationView
    -- * JSON helpers
  , jsonInt
  , select
  , exactKeys
  , member
  , lookupInt
  , isPositiveInt
  , digestOf
  , countOf
    -- * Story helpers
  , ensure
  , memberOf
  , atKey
  ) where

import Control.Exception (Exception (..), SomeException, fromException, throwIO, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), ExecutionPolicy)
import Petrus.Activity.Number (Number (..))
import Petrus.Engine (Clock (..), Engine, EngineError (..))
import Petrus.Engine.Observation (observeEngine)
import Petrus.Impetus.History.Records (FieldValue (FPolicy), encodeFieldValue, recordName)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Json (Json (..), lookupMember)
import Petrus.Observation qualified as Observation
import Petrus.Testing.Dst
import Petrus.Testing.Dst.PyRepr (pyStrRepr)
import Petrus.Testing.Dst.World qualified as World

-- ---------------------------------------------------------------------------
-- World time

-- | The World's logical instant, as last seen by a door.
newtype WorldTime = WorldTime (IORef Integer)

newWorldTime :: IO WorldTime
newWorldTime = WorldTime <$> newIORef 0

-- | Copy the door's context instant into the cell.
syncTime :: WorldTime -> Scenario IO Integer
syncTime (WorldTime ref) = do
  instant <- now
  liftIO (writeIORef ref instant)
  pure instant

-- | @WorldClock(context)@: @now()@ is the World instant; @observe(i)@ is the
-- World instant when it has reached @i@, else 'Nothing'.
worldClock :: WorldTime -> Clock
worldClock (WorldTime ref) =
  Clock
    { now = IntNumber <$> readIORef ref
    , observe = \instant -> do
        current <- readIORef ref
        pure (if IntNumber current >= instant then Just (IntNumber current) else Nothing)
    }

-- | @WorldProviderClock.now_ms()@: provider milliseconds from the World
-- instant.
worldProviderMs :: WorldTime -> IO Integer
worldProviderMs (WorldTime ref) = (* 1000) <$> readIORef ref

-- ---------------------------------------------------------------------------
-- Exceptions

-- | A Python exception raised by a profile-owned adapter: class and
-- @str()@.
data PyException = PyException Text Text
  deriving stock (Eq, Show)

instance Exception PyException where
  displayException (PyException cls message) = T.unpack (cls <> ": " <> message)

-- | The reference's @(type(error).__name__, str(error))@ for an exception
-- escaping an Engine door. A handler failure carries the recorded
-- @FiringFailed.error@ (@Class('message')@); the reference re-raises the
-- handler's own exception, whose class and @str()@ that text spells.
pythonError :: SomeException -> (Text, Text)
pythonError e
  | Just (PyException cls message) <- fromException e = (cls, message)
  | Just engineError <- fromException e = case engineError of
      EngineValueError m -> ("ValueError", m)
      EngineTypeError m -> ("TypeError", m)
      EngineRuntimeError m -> ("RuntimeError", m)
      EngineHandlerFailed t -> handlerText t
  | Just failure <- fromException e = (failureClass failure, failureMessage failure)
  | otherwise = (T.pack (takeWhile (/= ' ') (show e)), T.pack (displayException e))

-- | Split @Class('message')@ (a single-argument Python repr whose argument
-- is a plain quoted string without escapes) into its class and message.
handlerText :: Text -> (Text, Text)
handlerText t = case T.breakOn "(" t of
  (cls, rest)
    | Just inner <- T.stripPrefix "(" rest >>= T.stripSuffix ")"
    , Just message <- unquote inner ->
        (cls, message)
  _ -> ("Exception", t)
  where
    unquote s = case T.uncons s of
      Just (q, body)
        | q == '\'' || q == '"'
        , Just content <- T.stripSuffix (T.singleton q) body
        , not (T.any (== '\\') content) ->
            Just content
      _ -> Nothing

-- | The recorded @FiringFailed.error@ of @raise RuntimeError(message)@.
runtimeErrorText :: Text -> Text
runtimeErrorText message = "RuntimeError(" <> pyStrRepr message <> ")"

-- | Run IO inside a context-free door, turning any exception into the
-- Python exception the reference would propagate from the door.
ioDoor :: IO a -> Door IO a
ioDoor body =
  liftIO (try body) >>= \case
    Right value -> pure value
    Left e -> let (cls, message) = pythonError e in throwError (ProfileError cls message)

-- | 'ioDoor' inside a context door.
ioScenario :: IO a -> Scenario IO a
ioScenario = door . ioDoor

-- | Raise a profile exception from a 'Left'.
orRaise :: Text -> Either Text a -> Scenario IO a
orRaise cls = either (raise cls) pure

-- ---------------------------------------------------------------------------
-- Engine reads

-- | @engine.snapshot()@: the protocol-v1 snapshot, read coherently under the
-- Engine's monitor.
engineSnapshot :: Engine -> IO Json
engineSnapshot engine =
  observeEngine engine $ \inst history -> do
    observed <- Observation.captureInstance inst
    either throwIO pure (Observation.snapshot (Observation.Observation observed history))

-- | @engine.snapshot()["current"]@ as members.
engineCurrent :: Engine -> IO Json
engineCurrent engine = member "current" <$> engineSnapshot engine

currentMember :: Text -> Json -> Json
currentMember = member

-- | @[type(record).__name__ for record in history.records]@.
recordTypes :: HistoryStore -> IO [Text]
recordTypes store = map recordName . toList <$> store.snapshot

-- | @len(history)@.
historyLength :: HistoryStore -> IO Integer
historyLength store = toInteger <$> store.count

-- | @asdict(invocation.policy)@.
policyJson :: ExecutionPolicy -> Json
policyJson = encodeFieldValue . FPolicy

-- | The detached invocation view the profiles record.
invocationView :: Int -> ActivityInvocation -> [(Text, Json)]
invocationView occurrence inv =
  [ ("activity", String inv.activity)
  , ("correlation", maybe Null String inv.correlation)
  , ("idempotency", maybe Null String inv.idempotency)
  , ("input", inv.input)
  , ("occurrence", Int (toInteger occurrence))
  , ("policy", policyJson inv.policy)
  ]

-- ---------------------------------------------------------------------------
-- JSON helpers

jsonInt :: Integral a => a -> Json
jsonInt = Int . toInteger

-- | @{field: state[field] for field in fields}@.
select :: [Text] -> [(Text, Json)] -> Json
select fields state = Object [(f, maybe Null id (lookup f state)) | f <- fields]

-- | @type(payload) is dict and set(payload) == keys@.
exactKeys :: [Text] -> Json -> Bool
exactKeys keys = \case
  Object members -> sort (map fst members) == sort keys && length members == length keys
  _ -> False

member :: Text -> Json -> Json
member key value = maybe Null id (lookupMember key value)

-- | An exact integer (never a bool or a float).
lookupInt :: Text -> Json -> Maybe Integer
lookupInt key value = case lookupMember key value of
  Just (Int n) -> Just n
  _ -> Nothing

-- | @not isinstance(x, bool) and isinstance(x, int) and x >= 1@.
isPositiveInt :: Json -> Bool
isPositiveInt = \case
  Int n -> n >= 1
  _ -> False

digestOf :: Json -> Text
digestOf value = either (error . T.unpack) id (digestJson value)

-- | @records.count(name)@.
countOf :: Text -> [Json] -> Int
countOf name = length . filter (== String name)

-- ---------------------------------------------------------------------------
-- Story helpers

-- | A story's @assert@: refuse as @AssertionError@ inside the World.
ensure :: (Monad m) => Bool -> Text -> WorldT m g ()
ensure ok message = if ok then pure () else World.throwWorld (ContractViolation "AssertionError" message)

-- | @observation.value[key]@.
memberOf :: Text -> Observation -> Json
memberOf key o = member key o.value

-- | @value[key]@ of a JSON object.
atKey :: Text -> Json -> Json
atKey = member
