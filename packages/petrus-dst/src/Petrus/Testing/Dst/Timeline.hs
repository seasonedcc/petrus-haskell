{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The imperative authoring facade bound to one revocable generation
-- (the reference's @Timeline@). Import qualified:
--
-- > import Petrus.Testing.Dst.Timeline qualified as Timeline
-- >
-- > scenario = do
-- >   timeline <- World.timeline
-- >   _ <- Timeline.command timeline "enqueue" (Object [("item", String "a")])
-- >   Timeline.finish timeline Converged
module Petrus.Testing.Dst.Timeline
  ( Timeline (..)
  , timeline
  , command
  , FaultSpec (..)
  , fault
  , activateFault
  , observe
  , observeWith
  , runUntil
  , runUntilWith
  , crash
  , beginFair
  , finish
  ) where

import Data.Text (Text)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst.Internal.World (DstFailure (..), RunUntil (..), WorldT)
import Petrus.Testing.Dst.Internal.World qualified as World
import Petrus.Testing.Dst.Types

-- | A facade bound to one generation.
newtype Timeline = Timeline {generation :: Integer}
  deriving stock (Eq, Show)

-- | @World.timeline()@.
timeline :: (Monad m) => WorldT m g Timeline
timeline =
  World.generation
    >>= maybe
      (World.throwWorld (StaleGeneration "DST World has no live generation; restart before creating a Timeline"))
      (pure . Timeline)

-- | @Timeline.command(name, payload)@.
command :: (Monad m) => Timeline -> Text -> Json -> WorldT m g ApplyResult
command t name payload = do
  profile <- World.worldProfileIdentity
  World.submit Command {profile, name, payload} t.generation

-- | The keyword arguments of @Timeline.activate_fault@.
data FaultSpec = FaultSpec
  { name :: Text
  , target :: Text
  , occurrence :: Integer
  , disposition :: FaultDisposition
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | A fault with the reference's defaults: first occurrence, @raise@, no
-- payload.
fault :: Text -> Text -> FaultSpec
fault name target = FaultSpec {name, target, occurrence = 1, disposition = Raise, payload = Null}

-- | @Timeline.activate_fault(...)@.
activateFault :: (Monad m) => Timeline -> FaultSpec -> WorldT m g ()
activateFault t spec = do
  profile <- World.worldProfileIdentity
  World.activateFault
    Fault
      { profile
      , name = spec.name
      , target = spec.target
      , occurrence = spec.occurrence
      , disposition = spec.disposition
      , payload = spec.payload
      }
    t.generation

-- | @Timeline.observe(name)@.
observe :: (Monad m) => Timeline -> Text -> WorldT m g Observation
observe t name = observeWith t name Null

-- | @Timeline.observe(name, payload)@.
observeWith :: (Monad m) => Timeline -> Text -> Json -> WorldT m g Observation
observeWith t name payload = World.observe ObservationRequest {name, payload} t.generation False

-- | @Timeline.run_until(name, predicate)@: poll and step until the
-- predicate holds; refused as @RunUntilFailed@ when no work remains.
runUntil :: (Monad m) => Timeline -> Text -> (Observation -> Bool) -> WorldT m g Observation
runUntil t name = runUntilWith t name Null

-- | @Timeline.run_until(name, predicate, payload=payload)@.
runUntilWith :: (Monad m) => Timeline -> Text -> Json -> (Observation -> Bool) -> WorldT m g Observation
runUntilWith t name payload predicate = loop
  where
    request = ObservationRequest {name, payload}
    loop = do
      observation <- World.observe request t.generation True
      if predicate observation
        then pure observation
        else do
          remaining <- World.pendingCount
          if remaining == 0
            then do
              scheduled <- World.pending
              entries <- World.journal
              budget <- World.worldBudget
              World.throwWorld
                ( RunUntilFailed
                    RunUntil
                      { name
                      , disposition = DExternalWait
                      , observation
                      , pending = scheduled
                      , journal = entries
                      , budget
                      }
                )
            else World.step >> loop

-- | @Timeline.crash(cut)@.
crash :: (Monad m) => Timeline -> Text -> WorldT m g ()
crash t cut = World.crash cut t.generation

-- | @Timeline.begin_fair()@.
beginFair :: (Monad m) => Timeline -> WorldT m g ()
beginFair t = World.beginFair t.generation

-- | @Timeline.finish(disposition)@.
finish :: (Monad m) => Timeline -> AuthoredDisposition -> WorldT m g ()
finish t ending = World.finish ending t.generation
