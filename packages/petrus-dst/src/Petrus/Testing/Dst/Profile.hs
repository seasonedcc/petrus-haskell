{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The seam between the DST World and the system under test.
--
-- A 'Profile' is the reference's @ScenarioProfile@ protocol (plus the
-- optional @resource_usage@ door of @ResourceScenarioProfile@) as a record
-- of doors over any monad @m@. The World calls exactly these doors, in the
-- reference's order, and nothing else: a Petrus Engine, an in-memory model,
-- or a recorded transcript plug in the same way.
--
-- Doors that receive the reference's @ScenarioContext@ run in 'Scenario',
-- which offers only the context services ('now', 'stableId', 'faults').
-- The context exists only while the World runs a door, so the reference's
-- run-time refusals of out-of-door use and of re-entering the interpreter
-- are unrepresentable here.
--
-- A door fails by returning a 'ProfileError'. The World never classifies a
-- profile failure as a deterministic World failure: only the World's own
-- budget and checker refusals become failure operations.
module Petrus.Testing.Dst.Profile
  ( -- * Profiles
    Profile (..)
  , Checker (..)
  , Check (..)
  , pureCheck
  , runChecker
  , ProfileError (..)
  , profileError

    -- * Doors
  , Door
  , Scenario (..)
  , ScenarioContext (..)
  , ActiveFault (..)
  , runScenario
  , door
  , raise
  , now
  , stableId
  , faults
  ) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.State.Strict (StateT, gets, modify', runStateT)
import Control.Monad.Trans.Class (MonadTrans (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json)
import Petrus.Testing.Dst.Types

-- | An exception raised by a profile door or checker: the Python exception
-- class name and its message.
data ProfileError = ProfileError
  { errorType :: Text
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

profileError :: Text -> Text -> ProfileError
profileError = ProfileError

-- | A door without the scenario context.
type Door m = ExceptT ProfileError m

-- | Deterministic services available only while a profile door runs.
data ScenarioContext = ScenarioContext
  { instant :: Integer
  , stableIds :: Map Text Integer
  , activeFaults :: [ActiveFault]
  }
  deriving stock (Eq, Show)

-- | One activated fault and how many times its target has been reached.
data ActiveFault = ActiveFault
  { fault :: Fault
  , seen :: Integer
  }
  deriving stock (Eq, Show)

-- | A door with the scenario context.
newtype Scenario m a = Scenario (ExceptT ProfileError (StateT ScenarioContext m) a)
  deriving newtype (Functor, Applicative, Monad, MonadError ProfileError, MonadIO)

instance MonadTrans Scenario where
  lift = Scenario . lift . lift

-- | Run a door against a context. The context survives a failure, as the
-- reference's World state does when a profile raises.
runScenario :: Scenario m a -> ScenarioContext -> m (Either ProfileError a, ScenarioContext)
runScenario (Scenario body) = runStateT (runExceptT body)

-- | Use a context-free door inside a context door.
door :: (Monad m) => Door m a -> Scenario m a
door body = Scenario (lift (lift (runExceptT body))) >>= either throwError pure

-- | Raise a profile exception.
raise :: (Monad m) => Text -> Text -> Scenario m a
raise t m = throwError (ProfileError t m)

-- | @ScenarioContext.now()@: the World's logical instant.
now :: (Monad m) => Scenario m Integer
now = Scenario (gets (\c -> c.instant))

-- | @ScenarioContext.stable_id(namespace)@: @namespace-00000001@, counting
-- per namespace from 1.
stableId :: (Monad m) => Text -> Scenario m Text
stableId namespace
  | not (isName namespace) = raise "ValueError" "stable id namespace must be a normalized non-empty name"
  | otherwise = Scenario $ do
      value <- gets (\c -> Map.findWithDefault 0 namespace c.stableIds + 1)
      modify' (\c -> c {stableIds = Map.insert namespace value c.stableIds})
      let digits = show value
      pure (namespace <> "-" <> T.pack (replicate (8 - length digits) '0' ++ digits))

-- | @ScenarioContext.faults(target)@: the activated faults whose occurrence
-- this reach of @target@ completes. Matched faults are consumed.
faults :: (Monad m) => Text -> Scenario m [Fault]
faults target
  | not (isName target) = raise "ValueError" "fault target must be a normalized non-empty name"
  | otherwise = Scenario $ do
      active <- gets (\c -> c.activeFaults)
      let step (matched, retained) a
            | a.fault.target == target =
                let a' = a {seen = a.seen + 1}
                 in if a'.seen == a.fault.occurrence then (a.fault : matched, retained) else (matched, a' : retained)
            | otherwise = (matched, a : retained)
          (matchedRev, retainedRev) = foldl step ([], []) active
      modify' (\c -> c {activeFaults = reverse retainedRev})
      pure (reverse matchedRev)

-- | One application-owned scenario profile (@ScenarioProfile@) over
-- opaque generations @g@.
data Profile m g = Profile
  { identity :: ProfileIdentity
  , validate :: Command -> Door m Command
  -- ^ Normalize one command; it must keep this profile's identity.
  , validateFault :: Fault -> Door m Fault
  , create :: Scenario m (GenerationStart g)
  , load :: Scenario m (GenerationStart g)
  -- ^ Reload a generation after an abrupt drop.
  , apply :: g -> Command -> Scenario m ApplyResult
  , observe :: g -> ObservationRequest -> Scenario m Json
  , dropGeneration :: g -> Door m ()
  -- ^ @drop@: abruptly abandon a generation at a crash cut.
  , closeGeneration :: g -> Door m ()
  -- ^ @close@: gracefully release a live generation.
  , resourceUsage :: Maybe (Maybe g -> Door m ResourceUsage)
  -- ^ @ResourceScenarioProfile.resource_usage@; required by version-4
  -- budgets.
  }

-- | One independent checker: a pure verdict over one observation.
data Checker = Checker
  { identity :: CheckerIdentity
  , request :: ObservationRequest
  , check :: Check
  }

-- | A checker's verdicts as a pure Mealy machine: the current memory and the
-- step from it and one observation to a verdict and the next memory.
--
-- The reference's checkers are objects, and one of them
-- (@GeneratedRuntimeAuthorityChecker@) keeps a dictionary across the checks
-- of one World. Here that memory is an explicit value the World threads from
-- one check to the next, starting from the checker's own initial memory in
-- every World or replay, so verdicts stay pure and independent of the
-- World's monad. A failure is the exception @check@ would raise.
data Check = forall s. Check s (s -> Observation -> Either ProfileError (CheckResult, s))

-- | A stateless check: the same pure verdict for every observation.
pureCheck :: (Observation -> Either ProfileError CheckResult) -> Check
pureCheck verdict = Check () (\() observation -> (,()) <$> verdict observation)

-- | Judge one observation: the verdict and the checker for the next one.
runChecker :: Checker -> Observation -> Either ProfileError (CheckResult, Checker)
runChecker checker observation = case checker.check of
  Check memory step -> do
    (result, memory') <- step memory observation
    pure (result, checker {check = Check memory' step})
