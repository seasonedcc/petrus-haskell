{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Exact replay of expanded artifacts through the same World interpreter
-- (the reference's @ScenarioRegistry@ and @replay@).
module Petrus.Testing.Dst.Replay
  ( -- * Registry
    Registry
  , SomeProfile (..)
  , emptyRegistry
  , registerProfile
  , registerChecker
  , registryProfile
  , registryCheckers

    -- * Replay
  , replay
  , replayOperations
  ) where

import Control.Monad (when)
import Data.Sequence qualified as Seq
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Testing.Dst.Codec (journalDigest)
import Petrus.Testing.Dst.Internal.World hiding (artifact)
import Petrus.Testing.Dst.Profile
import Petrus.Testing.Dst.PyRepr
import Petrus.Testing.Dst.Types

-- | A profile with its generation type hidden, so one registry holds
-- profiles of every generation type.
data SomeProfile m = forall g. SomeProfile (Profile m g)

-- | An explicit fail-closed registry of replay profiles and checkers.
data Registry m = Registry
  { profiles :: Map IdentityKey (SomeProfile m)
  , checkers :: Map IdentityKey Checker
  }

emptyRegistry :: Registry m
emptyRegistry = Registry {profiles = Map.empty, checkers = Map.empty}

-- | @register_profile@; refuses a duplicate identity.
registerProfile :: Profile m g -> Registry m -> Either DstFailure (Registry m)
registerProfile profile registry
  | Map.member key registry.profiles =
      Left (ContractViolation "ValueError" ("DST profile identity is already registered: " <> identityStr profile.identity))
  | otherwise = Right Registry {profiles = Map.insert key (SomeProfile profile) registry.profiles, checkers = registry.checkers}
  where
    key = identityKey profile.identity

-- | @register_checker@; refuses a duplicate identity.
registerChecker :: Checker -> Registry m -> Either DstFailure (Registry m)
registerChecker checker registry
  | Map.member key registry.checkers =
      Left (ContractViolation "ValueError" ("DST checker identity is already registered: " <> identityStr checker.identity))
  | otherwise = Right Registry {profiles = registry.profiles, checkers = Map.insert key checker registry.checkers}
  where
    key = identityKey checker.identity

-- | @ScenarioRegistry.profile(identity)@.
registryProfile :: ProfileIdentity -> Registry m -> Either DstFailure (SomeProfile m)
registryProfile identity registry = case Map.lookup (identityKey identity) registry.profiles of
  Just profile -> Right profile
  Nothing -> Left (ContractViolation "ValueError" ("DST artifact profile is not registered exactly: " <> identityStr identity))

-- | @ScenarioRegistry.checkers(manifest)@.
registryCheckers :: [CheckerIdentity] -> Registry m -> Either DstFailure [Checker]
registryCheckers manifest registry = traverse resolve manifest
  where
    resolve identity = case Map.lookup (identityKey identity) registry.checkers of
      Just checker -> Right checker
      Nothing -> Left (ContractViolation "ValueError" ("DST artifact checker is not registered exactly: " <> identityStr identity))

-- | @replay(artifact, registry)@: rebuild an unseeded World from the
-- registry, re-run every expanded operation, and require the exact
-- operations, disposition, checker results, and journal digest. The World
-- is always closed afterwards.
replay :: (Monad m) => Registry m -> AnyArtifact -> m (Either DstFailure AnyReplayResult)
replay registry artifact = case resolved of
  Left failure -> pure (Left failure)
  Right (SomeProfile profile, checkers) ->
    withWorld
      WorldConfig {profile, budget = artifactBudget artifact, checkers, seed = Nothing, progress = Nothing}
      (replayOperations artifact >> verify)
  where
    resolved = do
      profile <- registryProfile (artifactProfile artifact) registry
      checkers <- registryCheckers (artifactCheckers artifact) registry
      Right (profile, checkers)
    verify :: (Monad m) => WorldT m g AnyReplayResult
    verify = do
      ending <- disposition >>= maybe (throwWorld (ReplayMismatch "DST replay ended without an explicit disposition")) pure
      let expectedEnding = artifactExpectedDisposition artifact
      when (ending /= expectedEnding) $
        throwWorld
          ( ReplayMismatch
              ( "DST disposition diverged: expected "
                  <> pyStrRepr (dispositionText expectedEnding)
                  <> ", observed "
                  <> pyStrRepr (dispositionText ending)
              )
          )
      entries <- journal
      when ([e | e <- entries, e.kind == JCheck] /= artifactExpectedChecks artifact) $
        throwWorld (ReplayMismatch "DST replay checker results diverged from the expanded artifact")
      let digest = journalDigest entries
      when (digest /= artifactJournalDigest artifact) $
        throwWorld (ReplayMismatch "DST replay journal digest diverged")
      count <- toInteger <$> operationCount
      let entryCount = toInteger (length entries)
      pure $ case artifact of
        ArtifactV1 a ->
          ReplayV1
            ReplayResultV1
              { scenarioId = a.scenarioId
              , disposition = a.expected.disposition
              , operations = count
              , journalEntries = entryCount
              , journalDigest = digest
              }
        _ ->
          ReplayV2
            ReplayResult
              { scenarioId = artifactScenarioId artifact
              , disposition = ending
              , failure = artifactExpectedFailure artifact
              , operations = count
              , journalEntries = entryCount
              , journalDigest = digest
              }

-- | @_replay_operations@: walk the expanded operations, requiring each
-- attempt to reproduce exactly its expected slice.
replayOperations :: (Monad m) => AnyArtifact -> WorldT m g ()
replayOperations artifact = walk 0
  where
    expectedAll = Seq.fromList (artifactOperations artifact)
    total = Seq.length expectedAll
    walk position
      | position >= total = pure ()
      | otherwise = do
          let expected = Seq.index expectedAll position
              pairedFailure = case Seq.lookup (position + 1) expectedAll of
                Just (Failed f) | f.acceptedOperations == 1 -> True
                _ -> False
          before <- operationCount
          outcome <- tryWorld (replayOperation expected)
          failed <- case outcome of
            Right () -> pure False
            Left (BudgetExhausted _ _) -> pure True
            Left (InvariantViolation _) -> pure True
            Left other -> throwWorld other
          actual <- operationsFrom before
          let expectedSlice = foldr (:) [] (Seq.take (length actual) (Seq.drop before expectedAll))
          when (null actual || actual /= expectedSlice) $
            throwWorld
              ( ReplayMismatch
                  ( "DST operation "
                      <> tshow (operationPosition expected)
                      <> " diverged: expected "
                      <> pyRepr (PyTuple (map toPy expectedSlice))
                      <> ", observed "
                      <> pyRepr (PyTuple (map toPy actual))
                  )
              )
          let position' = position + length actual
          if failed
            then case reverse actual of
              Failed _ : _ | position' == total -> pure ()
              _ -> throwWorld (ReplayMismatch "DST replay failed outside its exact terminal failure operation")
            else do
              when pairedFailure $
                throwWorld
                  ( ReplayMismatch
                      ("DST operation " <> tshow (operationPosition expected) <> " did not reproduce its terminal failed attempt")
                  )
              when (length actual /= 1 || isFailure expected) $
                throwWorld
                  (ReplayMismatch ("DST expected failure operation " <> tshow (operationPosition expected) <> " did not fail"))
              walk position'
    isFailure = \case
      Failed _ -> True
      _ -> False

replayOperation :: (Monad m) => ExpandedOperation -> WorldT m g ()
replayOperation = \case
  Accepted (OpExecute o)
    | o.source == Authored -> () <$ submit o.command o.generation
    | otherwise -> () <$ step
  Accepted (OpFault o) -> activateFault o.fault o.generation
  Accepted (OpObserve o) -> () <$ observe o.request o.observation.generation o.poll
  Accepted (OpCrash o) -> crash o.cut o.generation
  Accepted (OpRestart _) -> () <$ restart
  Accepted (OpFair o) -> beginFair o.generation
  Accepted (OpFinish o) -> finish o.disposition o.generation
  Failed o -> replayAttempt o.attempt

replayAttempt :: (Monad m) => OperationAttempt -> WorldT m g ()
replayAttempt = \case
  ASubmit a -> () <$ submit a.command a.generation
  AStep -> () <$ step
  AFault a -> activateFault a.fault a.generation
  AObserve a -> () <$ observe a.request a.generation a.poll
  ACrash a -> crash a.cut a.generation
  ARestart -> () <$ restart
  AFair a -> beginFair a.generation
  AFinish a -> finish a.disposition a.generation

tshow :: (Show a) => a -> Text
tshow = T.pack . show
