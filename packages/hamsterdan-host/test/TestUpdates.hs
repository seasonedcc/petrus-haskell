-- | Record updates whose field names other records in the specs share
-- (unambiguous here, where only these records are in scope).
module TestUpdates
  ( withRunner
  , withAgents
  , withClock
  , withTimers
  , identifiedComment
  ) where

import Hamsterdan.Agents.Protocol (AgentRunner)
import Hamsterdan.GitHub.Webhooks (Observation (..))
import Hamsterdan.Host.Service (AgentCustody, ServiceOptions (..))
import Petrus.Json (Json (..))

withRunner :: AgentRunner -> ServiceOptions -> ServiceOptions
withRunner runner options = options {runner}

withAgents :: AgentCustody -> ServiceOptions -> ServiceOptions
withAgents agents options = options {agents}

withClock :: IO Double -> ServiceOptions -> ServiceOptions
withClock clock options = options {clock = Just clock}

-- | @reminder_delay@, the timers' @time.time_ns@ and the runnable index's
-- clock.
withTimers :: Double -> IO Integer -> IO Double -> ServiceOptions -> ServiceOptions
withTimers reminderDelay timerClock runnableClock options =
  options {reminderDelay, timerClockUs = Just timerClock, runnableClock = Just runnableClock}

-- | @comment_id=9, actor_id=5@ on a comment observation.
identifiedComment :: Observation -> Observation
identifiedComment item = item {commentId = Int 9, actorId = Int 5}
