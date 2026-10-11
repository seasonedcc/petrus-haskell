{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Haskell ports of the toy profiles and checkers of the reference's
-- @tests/dst/test_world.py@ (and of the extra @FaultQueueProfile@ in
-- @scripts/world_stories.py@). The Python generation is the profile's
-- shared value list, so the generation here is @()@ and the list lives in
-- the profile's 'Queue' state.
module Toy
  ( Queue (..)
  , newQueue
  , queueValues
  , queueCloses
  , queueIdentity
  , resourceQueueIdentity
  , faultQueueIdentity
  , queueProfile
  , resourceQueueProfile
  , incompleteResourceProfile
  , raisingReservedExceptionProfile
  , faultQueueProfile
  , rejectingChecker
  , rejectBadValueChecker
  , passingBadValueChecker
  , raisingReservedExceptionChecker
  , budget
  , resourceBudget
  , budgetV4
  , digestOf
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst

-- | The profile-owned state the Python toys keep on @self@.
data Queue = Queue
  { values :: IORef [Text]
  , closes :: IORef Int
  }

newQueue :: IO Queue
newQueue = Queue <$> newIORef [] <*> newIORef 0

queueValues :: Queue -> IO [Text]
queueValues q = readIORef q.values

queueCloses :: Queue -> IO Int
queueCloses q = readIORef q.closes

digestOf :: Json -> Text
digestOf value = either (error . show) id (digestJson value)

queueIdentity :: ProfileIdentity
queueIdentity =
  Identity
    { name = "petrus.testing.queue-proof"
    , version = 1
    , digest = digestOf (Object [("command", String "queue.record"), ("observation", String "queue.state")])
    }

resourceQueueIdentity :: ProfileIdentity
resourceQueueIdentity =
  Identity
    { name = "petrus.testing.resource-queue-proof"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("command", String "queue.record")
              , ("observation", String "queue.state")
              , ("resources", Array [String "retained.values"])
              ]
          )
    }

faultQueueIdentity :: ProfileIdentity
faultQueueIdentity =
  Identity
    { name = "petrus.testing.fault-queue-proof"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("command", String "queue.record")
              , ("fault", String "queue.apply")
              , ("observation", String "queue.state")
              ]
          )
    }

valuesJson :: [Text] -> Json
valuesJson vs = Array (map String vs)

-- | @QueueProfile@.
queueProfile :: Queue -> Profile IO ()
queueProfile = queueProfileAs queueIdentity

-- | The queue toy under a given identity (Python subclasses override the
-- @identity@ class attribute).
queueProfileAs :: ProfileIdentity -> Queue -> Profile IO ()
queueProfileAs identity q =
  Profile
    { identity
    , validate = \c -> case c.payload of
        Object _ | c.name == "queue.record" -> pure c
        _ -> throwProfile "ValueError" "queue proof accepts only queue.record objects"
    , validateFault = \_ -> throwProfile "ValueError" "queue proof does not accept faults"
    , create = do
        first <- stableId "queue"
        second <- stableId "queue"
        pure
          GenerationStart
            { generation = ()
            , scheduled = [scheduledRecord identity 5 first, scheduledRecord identity 5 second]
            }
    , load = pure GenerationStart {generation = (), scheduled = []}
    , apply = \() c -> do
        identifier <- payloadId c
        vs <- liftIO (modifyIORef' q.values (<> [identifier]) >> readIORef q.values)
        pure ApplyResult {disposition = Applied, value = Object [("values", valuesJson vs)], scheduled = []}
    , observe = \() request ->
        if request.name /= "queue.state"
          then raise "ValueError" "unknown queue proof observation"
          else do
            vs <- liftIO (readIORef q.values)
            pure (Object [("values", valuesJson vs)])
    , dropGeneration = \() -> pure ()
    , closeGeneration = \() -> liftIO (modifyIORef' q.closes (+ 1))
    , resourceUsage = Nothing
    }

scheduledRecord :: ProfileIdentity -> Integer -> Text -> ScheduledCommand
scheduledRecord identity at identifier =
  ScheduledCommand
    { instant = at
    , command = Command {profile = identity, name = "queue.record", payload = Object [("id", String identifier)]}
    }

payloadId :: Command -> Scenario IO Text
payloadId c = case lookupMember "id" c.payload of
  Just (String s) -> pure s
  _ -> raise "AssertionError" ""

throwProfile :: Text -> Text -> Door IO a
throwProfile t m = throwError (ProfileError t m)

-- | @ResourceQueueProfile@.
resourceQueueProfile :: Queue -> Profile IO ()
resourceQueueProfile q =
  (queueProfileAs resourceQueueIdentity q)
    { resourceUsage = Just $ \generation -> do
        vs <- liftIO (readIORef q.values)
        pure (ResourceUsage (Map.singleton "retained.values" (maybe 0 (const (toInteger (length vs))) generation)))
    }

-- | The test-local @IncompleteResourceProfile@.
incompleteResourceProfile :: Queue -> Profile IO ()
incompleteResourceProfile q =
  (resourceQueueProfile q) {resourceUsage = Just (\_ -> pure (ResourceUsage (Map.singleton "retained.other" 0)))}

-- | @RaisingReservedExceptionProfile@: its @apply@ raises the World's own
-- exception class, which must not become a failure operation.
raisingReservedExceptionProfile :: Queue -> Profile IO ()
raisingReservedExceptionProfile q =
  (queueProfile q) {apply = \_ _ -> raise "BudgetExhausted" "DST budget 'profile-owned' exhausted at limit 1"}

-- | @FaultQueueProfile@ of @scripts/world_stories.py@.
faultQueueProfile :: Queue -> Profile IO ()
faultQueueProfile q =
  (queueProfileAs faultQueueIdentity q)
    { validateFault = \f ->
        if f.target /= "queue.apply"
          then throwProfile "ValueError" "fault queue proof faults only target queue.apply"
          else pure f
    , apply = \() c -> do
        identifier <- payloadId c
        matched <- faults "queue.apply"
        at <- now
        if any (\f -> f.disposition == Refuse) matched
          then pure ApplyResult {disposition = RefusedExpected, value = Object [("refused", String identifier), ("at", Int at)], scheduled = []}
          else do
            vs <- liftIO (modifyIORef' q.values (<> [identifier]) >> readIORef q.values)
            let again = [scheduledRecord faultQueueIdentity (at + 1) (identifier <> "-again") | any (\f -> f.disposition == Duplicate) matched]
            pure ApplyResult {disposition = Applied, value = Object [("values", valuesJson vs), ("at", Int at)], scheduled = again}
    }

queueStateRequest :: ObservationRequest
queueStateRequest = ObservationRequest {name = "queue.state", payload = Object []}

observedValues :: Observation -> Either ProfileError [Json]
observedValues o = case lookupMember "values" o.value of
  Just (Array vs) -> Right vs
  _ -> Left (ProfileError "AssertionError" "")

-- | @RejectingChecker@.
rejectingChecker :: Checker
rejectingChecker =
  Checker
    { identity =
        Identity {name = "petrus.testing.rejecting-checker", version = 1, digest = digestOf (Object [("result", String "reject")])}
    , request = queueStateRequest
    , check = pureCheck $ \o -> Right CheckResult {passed = False, detail = Object [("values", o.value)]}
    }

badValueIdentity :: CheckerIdentity
badValueIdentity =
  Identity
    { name = "petrus.testing.reject-bad-value"
    , version = 1
    , digest = digestOf (Object [("property", String "queue values never contain bad")])
    }

-- | @RejectBadValueChecker@.
rejectBadValueChecker :: Checker
rejectBadValueChecker =
  Checker
    { identity = badValueIdentity
    , request = queueStateRequest
    , check = pureCheck $ \o -> do
        vs <- observedValues o
        Right CheckResult {passed = String "bad" `notElem` vs, detail = Object [("values", Array vs)]}
    }

-- | @PassingBadValueChecker@: the same identity, always passing.
passingBadValueChecker :: Checker
passingBadValueChecker =
  Checker
    { identity = badValueIdentity
    , request = queueStateRequest
    , check = pureCheck $ \o -> do
        vs <- observedValues o
        Right CheckResult {passed = True, detail = Object [("values", Array vs)]}
    }

-- | @RaisingReservedExceptionChecker@.
raisingReservedExceptionChecker :: Checker
raisingReservedExceptionChecker =
  Checker
    { identity =
        Identity
          { name = "petrus.testing.raises-reserved-exception"
          , version = 1
          , digest = digestOf (Object [("bug", String "raises instead of returning a check result")])
          }
    , request = queueStateRequest
    , check = pureCheck $ \o -> do
        vs <- observedValues o
        if null vs
          then Right CheckResult {passed = True, detail = Object [("values", Array vs)]}
          else Left (ProfileError "InvariantViolation" "checker implementation raised the reserved exception")
    }

-- | A version-3 budget with a 65536-byte artifact limit.
budget :: Integer -> Integer -> Integer -> Integer -> Integer -> Integer -> SomeBudget
budget actions queuedCommands timerAdvances logicalInstant reloads predicatePolls =
  SomeBudget Budget {actions, queuedCommands, timerAdvances, logicalInstant, reloads, predicatePolls, artifactBytes = 65536}

-- | @resource_budget(limit)@.
resourceBudget :: Integer -> SomeBudget
resourceBudget = budgetV4 (budget 8 2 1 5 0 2)

-- | A version-4 budget over the given limits with one @retained.values@
-- resource.
budgetV4 :: SomeBudget -> Integer -> SomeBudget
budgetV4 limits limit = SomeBudgetV4 BudgetV4 {limits = budgetLimits limits, profileResources = Map.singleton "retained.values" limit}
