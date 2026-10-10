-- | One provider-neutral live composition around exactly one durable
-- Instance (a port of @petrus.engine@).
--
-- Import qualified:
--
-- > import Petrus.Engine qualified as Engine
-- >
-- > engine <- Engine.create net "order-1" store (inlineDispatch pool) Engine.defaultEngineOptions {Engine.marking = initial}
-- > outcome <- Engine.advance engine
--
-- 'create' and 'load' host backend-owned History stores; durable providers
-- compose through "Petrus.Engine.Provider". Every writing-door exception
-- poisons the Engine (later doors refuse); continue with a fresh 'load'.
--
-- 'advance' reconciles on the first call after a load — recorded
-- lifecycle cancellations are re-fenced, the outbox is redispatched from
-- the recorded invocations (prepare never re-runs), projection-pending
-- occurrences complete by projection alone, and pure in-flight occurrences
-- are driven to terminal — and then applies at most one action chosen by
-- the driving policy.
module Petrus.Engine
  ( -- * Engines
    Engine
  , create
  , load
  , EngineOptions (..)
  , defaultEngineOptions
    -- * Driving
  , advance
  , wait
  , DriveOutcome (..)
    -- * Writing doors
  , Delivered (..)
  , deliver
  , acceptDelivery
  , DeliveryAnswer (..)
  , AcceptedDelivery (..)
  , acceptedDelivery
  , completeDelivery
  , openScope
  , closeScope
  , resetScope
  , seal
  , close
    -- * Read doors
  , marking
  , status
  , inFlight
  , activeScopes
  , records
    -- * Policies
  , Action (..)
  , InFlightView (..)
  , Snapshot (..)
  , DrivingPolicy
  , chooseConservative
  , chooseThroughput
  , purePolicy
  , conservativePolicy
  , throughputPolicy
  , EngineSelection (..)
  , defaultSelection
    -- * Time and ingress
  , Clock (..)
  , simulatedClock
  , Sensor
  , Delivery (source, tokens, identity, scope)
  , delivery
    -- * Errors
  , EngineError (..)
  , engineErrorMessage
  ) where

import Petrus.Engine.Internal
import Petrus.Impetus.Instance (AcceptedDelivery (..), DeliveryAnswer (..), acceptedDelivery)
import Petrus.Engine.Vocabulary
