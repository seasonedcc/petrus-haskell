{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Shared pure-fold helpers for the V5 actor-loop topology
-- (@hamsterdan.readiness.net_v5.folding@).
--
-- Every V5 decision is a pure fold: hydrate the bound tokens into strict
-- workflow values, compute, and emit strict values on named targets.
--
-- Hydration follows the reference exactly: every bound token (read
-- selections first, then consumed ones, each in arc order) is validated
-- against the strict model its color names, after its JSON was re-spelled
-- with recursively sorted keys. So a token of an unknown color fails the
-- whole fold with @KeyError('Color')@, a malformed token with
-- @ValidationError()@, and dictionary-valued fields of every hydrated value
-- come back with sorted keys — which is observable in what a fold emits.
module Hamsterdan.Readiness.NetV5.Folding
  ( -- * Fold signature
    Fold
    -- * Hydration
  , Value (..)
  , hydrate
  , pick
  , values1
  , values2
  , values3
  , revive
  , sortKeysDeep
  , tokenColors
    -- * Emission
  , Emit
  , emit
  , route
    -- * Python failure texts
  , pyError
  , validationError
  , keyError
  , valueError
  , runtimeError
  , typeError
  ) where

import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Typeable (Typeable, cast)
import Hamsterdan.Contracts.Codec (Contract (..), Codec (..), dump, validate)
import Hamsterdan.Contracts.ReadinessV5
import Petrus.Impetus.Binding (HandlerResult, handlerTokens)
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..), pythonFailureText)
import Petrus.Impetus.Petrinet (Arc (..), Binding (..), Token (..), netPathText)
import Petrus.Json (Json (..))

-- | A V5 pure fold: the binding and the transition's output arcs.
type Fold = Binding -> [Arc] -> Either Text HandlerResult

-- | A hydrated workflow value of any registered color.
data Value where
  Value :: (Contract a, Typeable a) => a -> Value

entry :: forall a. (Contract a, Typeable a) => (Text, Json -> Maybe Value)
entry = (codecName (contract @a), either (const Nothing) (Just . Value) . validate @a)

-- | @_TOKEN_ADAPTERS@: every V5 workflow value class, by color.
registry :: Map.Map Text (Json -> Maybe Value)
registry =
  Map.fromList
    [ entry @ABlocked, entry @ADeferred, entry @AFault, entry @ALanded, entry @AMoved, entry @AWake
    , entry @AgentReview, entry @AnnounceCandidate, entry @AnnounceReq, entry @ArmReminder
    , entry @ArmedReminderClock, entry @ArmingReminderClock, entry @CancelReminder
    , entry @CancellingReminderClock, entry @ChecksFact, entry @ChecksFailure, entry @CiEnded
    , entry @CiState, entry @CloseFact, entry @CloseSeen, entry @CommentSeen, entry @ConvMemory
    , entry @DashBlocked, entry @DashDeferred, entry @DashEnded, entry @DashFault, entry @DashHeal
    , entry @DashLanded, entry @DashMemory, entry @DashReq, entry @DeclinedM, entry @DismissFact
    , entry @DraftSeen, entry @EmptyReview, entry @EscMoved, entry @FaultClearedFact, entry @FaultM
    , entry @FaultRaisedFact, entry @FindingsFact, entry @GateFact, entry @HeadSeen, entry @HeadWork
    , entry @HumanFact, entry @HumanSeen, entry @IntentFact, entry @Ladder, entry @LadderEnded
    , entry @LifeState, entry @MovedM, entry @MutEnded, entry @MutState, entry @MutWork
    , entry @MutationPendingFact, entry @MutationRequest, entry @MutationSettled
    , entry @MutationSettledFact, entry @NoReminderClock, entry @OverdueReminderClock
    , entry @ProvisionalHead, entry @PublicationDeferred, entry @Publishable, entry @Pushed
    , entry @ReadyEnded, entry @ReadySeen, entry @RecoverFact, entry @RemBlocked, entry @RemEnded
    , entry @RemFault, entry @RemLanded, entry @RemReq, entry @RemState, entry @ReminderCyclePaused
    , entry @ReminderCycleStarted, entry @ReminderTimer, entry @Replied, entry @ReplyBlocked
    , entry @ReplyFault, entry @ReplyReq, entry @RerunFault, entry @RerunLanded, entry @RerunMoved
    , entry @RerunReq, entry @ReviewBlocked, entry @ReviewEnded, entry @ReviewFact, entry @ReviewFault
    , entry @ReviewLanded, entry @ReviewMemory, entry @ReviewMoved, entry @RoundDeferred
    , entry @RoundMoved, entry @RoundOpen, entry @RoundUnable, entry @RoundWake, entry @RunSeen
    , entry @RunWork, entry @Snapshot, entry @SnoozeFact, entry @StateFact, entry @SummaryPending
    , entry @SummaryPublished, entry @TimerArmed, entry @TimerCancelled, entry @TimerCommand
    , entry @TimerCommandApplied, entry @TimerDue
    ]

-- | The registered token colors (the reference's 106 adapter names).
tokenColors :: [Text]
tokenColors = Map.keys registry

-- | @json.dumps(value, sort_keys=True)@ followed by a parse: every object's
-- members in code-point order of their keys.
sortKeysDeep :: Json -> Json
sortKeysDeep = \case
  Object members -> Object (sortOn fst [(k, sortKeysDeep v) | (k, v) <- members])
  Array items -> Array (map sortKeysDeep items)
  other -> other

-- | Hydrate every bound token, read selections first.
hydrate :: Binding -> Either Text [Value]
hydrate b = traverse one [tok | (_, selected) <- b.read ++ b.consumed, tok <- selected]
  where
    one tok = case tok.color of
      Nothing -> Left (pyError "KeyError" [PyNone])
      Just c -> case Map.lookup c registry of
        Nothing -> Left (keyError c)
        Just adapter -> maybe (Left validationError) Right (adapter (sortKeysDeep tok.payload))

-- | The first hydrated value of one type (@next(... isinstance ...)@).
pick :: forall a. (Typeable a) => [Value] -> Either Text a
pick hydrated = case [x | Value v <- hydrated, Just x <- [cast v]] of
  x : _ -> Right x
  [] -> Left (runtimeError "generator raised StopIteration")

values1 :: forall a. (Typeable a) => Binding -> Either Text a
values1 b = hydrate b >>= pick

values2 :: forall a b. (Typeable a, Typeable b) => Binding -> Either Text (a, b)
values2 b = do
  hs <- hydrate b
  (,) <$> pick hs <*> pick hs

values3 :: forall a b c. (Typeable a, Typeable b, Typeable c) => Binding -> Either Text (a, b, c)
values3 b = do
  hs <- hydrate b
  (,,) <$> pick hs <*> pick hs <*> pick hs

-- | Hydrate a strict workflow value from a JSON-faithful dict (a baton held
-- through a gate round inside a work token's @mem@).
revive :: forall a. (Contract a) => Json -> Either Text a
revive value = either (const (Left validationError)) Right (validate @a (sortKeysDeep value))

-- | One target's emitted values, already dumped.
type Emit = (Text, [Json])

-- | Emit strict values on one named target.
emit :: (Contract a) => Text -> [a] -> Emit
emit target xs = (target, map dump xs)

-- | Emit values only on the targets named in the mapping, in output-arc
-- order, each token colored by its arc. A target named twice in the
-- mapping keeps its first values; a fold that overrides a target replaces
-- it in place before routing.
route :: [Arc] -> [Emit] -> HandlerResult
route outs mapping =
  handlerTokens
    [ (a.target, [Token a.color v | v <- vs])
    | a <- toList outs
    , Just vs <- [lookup (netPathText a.target) mapping]
    ]

-- | The recorded text of a Python exception.
pyError :: Text -> [PythonArg] -> Text
pyError name args = pythonFailureText (PythonException name args)

-- | A pydantic @ValidationError@ (whose @args@ are empty).
validationError :: Text
validationError = pyError "ValidationError" []

keyError :: Text -> Text
keyError k = pyError "KeyError" [PyStr k]

valueError :: Text -> Text
valueError message = pyError "ValueError" [PyStr message]

runtimeError :: Text -> Text
runtimeError message = pyError "RuntimeError" [PyStr message]

typeError :: Text -> Text
typeError message = pyError "TypeError" [PyStr message]
