{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Petri-aware bindings between firing values and their implementations
-- (@petrus.impetus.binding@): the handler result envelope, the pure handler
-- and the impure 'ActivityHandler' contracts, the default 'passthrough',
-- the CEL compiler seam, and typed derivation.
--
-- __Purity is a type.__ The reference documents that a plain callable bound
-- to a handler symbol is a pure, deterministic projection and that impurity
-- has exactly one spelling, an @ActivityHandler@. Here a 'Handler' is a pure
-- function returning 'Either', and an 'ActivityHandler' is a record of pure
-- @prepare@/@project@ functions; the Instance classifies a transition by
-- which constructor of 'BoundHandler' it is bound to, never by inspecting
-- code. A 'Left' is the handler raising: its text is the failure the
-- Instance records.
--
-- __Typed derivation.__ The reference derives typed transforms and guards by
-- reflecting on a Python function's signature and dataclass annotations.
-- Haskell has no such reflection, so the same plan is spelled as an
-- applicative of named, typed parameters ('param'), each type naming its arc
-- colour through 'Typed'. The derivation rules and their messages are the
-- reference's; the cases that only exist because Python is dynamically
-- typed (a missing annotation, a non-dataclass annotation, a non-@bool@
-- guard result) are enforced by types.
module Petrus.Impetus.Binding
  ( -- * Handler results
    HandlerResult (..)
  , handlerTokens
  , deliveryRegistration
    -- * Handlers
  , Handler
  , ActivityHandler (..)
  , BoundHandler (..)
  , isActivityBound
  , HandlerCall (..)
  , HandlerObserver
  , passthrough
    -- * Completion conditions
  , Completion
    -- * The CEL seam
  , CelCompilers (..)
  , noCelCompilers
    -- * Derived Activity handlers
  , derivedActivityHandler
    -- * Typed derivation
  , Typed (..)
  , TypedArgs
  , param
  , deriveTypedTransform
  , deriveTypedGuard
  ) where

import Control.DeepSeq (NFData (..))
import Control.Monad (forM, forM_, unless, when)
import Data.List (find, findIndex)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailure, ActivityInvocation, invocation)
import Petrus.Impetus.History.Records (DeliveryRegistration (..))
import Petrus.Json.Python (pythonIntRepr, pythonStrRepr)
import Petrus.Impetus.Petrinet.Enabledness (Binding (..), Filter, Guard, bindingTokens)
import Petrus.Impetus.Petrinet.Marking (Marking, Token (..))
import Petrus.Impetus.Petrinet.Routing (route)
import Petrus.Impetus.Petrinet.Schema
import Petrus.Json (Json (..))

-- ---------------------------------------------------------------------------
-- Handler results

-- | Output tokens and delivery-registration effects returned by a handler.
-- The reference also accepts the bare token mapping as sugar; here that is
-- 'handlerTokens'.
data HandlerResult = HandlerResult
  { tokens :: [(NetPath, [Token])]
  , opens :: [DeliveryRegistration]
  , closes :: [DeliveryRegistration]
  }
  deriving stock (Eq, Show)

-- | Forcing a result is how the Instance turns a lazily raised error inside
-- a pure handler into a recorded failure before anything is appended.
instance NFData HandlerResult where
  rnf r = rnf r.tokens `seq` rnf [(d.source, d.key) | d <- r.opens ++ r.closes]

-- | A result carrying only tokens (the reference's bare-mapping sugar).
handlerTokens :: [(NetPath, [Token])] -> HandlerResult
handlerTokens produced = HandlerResult produced [] []

-- | @DeliveryRegistration(source, key)@ with its constructor rule.
deliveryRegistration :: NetPath -> Text -> Either Text DeliveryRegistration
deliveryRegistration source key
  | T.null key =
      Left "DeliveryRegistration requires a non-empty string key of the exact built-in type, got ''"
  | otherwise = Right (DeliveryRegistration source key)

-- ---------------------------------------------------------------------------
-- Handlers

-- | A pure projection: the firing binding and the transition's output arcs
-- to a result envelope. 'Left' is the handler raising; its text is the
-- recorded failure.
type Handler = Binding -> [Arc] -> Either Text HandlerResult

-- | The Petri-aware prepare/project bridge around one Activity invocation:
-- @prepare@ runs before the begin batch is appended (a failure is then a
-- code failure, never a net fact); @project@ maps the frozen terminal result
-- into the envelope; @projectFailure@ is the opt-in failure projection
-- (@FailureProjectingActivityHandler@).
data ActivityHandler = ActivityHandler
  { prepare :: Binding -> Either Text ActivityInvocation
  , project :: Binding -> Json -> Either Text HandlerResult
  , projectFailure :: Maybe (Binding -> ActivityFailure -> Either Text HandlerResult)
  }

-- | A transition's bound implementation, classified by construction.
data BoundHandler
  = PureHandler Handler
  | ActivityBound ActivityHandler

-- | One application of an 'ActivityHandler' function, as a writing door is
-- about to make it.
data HandlerCall
  = -- | @prepare@ for this binding.
    Preparing Binding
  | -- | @project@ of this binding's frozen result.
    Projecting Binding Json
  | -- | @project_failure@ of this binding's frozen failure.
    ProjectingFailure Binding ActivityFailure

-- | An effect the writing door runs immediately before it applies an
-- 'ActivityHandler' function: exactly once per application, in door order,
-- under the Instance's lock. A 'Left' is the call raising with that text,
-- exactly as if the handler had; the pure function is then not applied.
--
-- The reference's handlers are objects that may count their calls or read
-- an injected fault; here the handler stays a pure value and the host
-- supplies that behaviour once, as this observer (Engine and Instance
-- option @handlerObserver@).
type HandlerObserver = HandlerCall -> IO (Either Text ())

-- | Whether the binding is impure work.
isActivityBound :: BoundHandler -> Bool
isActivityBound = \case
  ActivityBound _ -> True
  PureHandler _ -> False

-- | Forward each consumed or delivered token through every admitting output
-- arc.
passthrough :: Handler
passthrough b outputArcs = Right (handlerTokens (route (bindingTokens b) outputArcs))

-- | A completion-condition implementation: a pure boolean over the marking;
-- 'Left' is an evaluation error (read as not holding, with a diagnostic).
type Completion = Marking -> Either Text Bool

-- ---------------------------------------------------------------------------
-- The CEL seam

-- | How inline 'Cel' declarations become implementations. The kernel never
-- evaluates CEL itself: an Instance is constructed with a record of
-- compilers (a CEL package supplies the real one), and a 'Left' is the
-- construction-time refusal of an invalid expression, which therefore never
-- runs.
data CelCompilers = CelCompilers
  { compileGuard :: Cel -> NetPath -> Set NetPath -> Either Text Guard
  -- ^ The expression, its transition, and the input places in scope.
  , compileFilter :: Cel -> Either Text Filter
  , compileCompletion :: Cel -> [NetPath] -> Either Text Completion
  -- ^ The expression and the net's places.
  }

-- | No CEL support: every inline expression is refused at construction.
noCelCompilers :: CelCompilers
noCelCompilers =
  CelCompilers
    { compileGuard = \expression _ _ -> Left (refusal expression)
    , compileFilter = Left . refusal
    , compileCompletion = \expression _ -> Left (refusal expression)
    }
  where
    refusal expression = "no CEL compiler is configured for inline expression " <> pythonStrRepr (celExpression expression)

-- ---------------------------------------------------------------------------
-- Derived Activity handlers

-- | @DerivedActivityHandler(net, transition, activity)@: derive the
-- prepare/project bridge from typed arcs. The Activity is given by its name,
-- its parameters with their colour (the reference reads the annotation's
-- nominal type name), and its result colour.
derivedActivityHandler :: Net -> NetPath -> Text -> [(Text, Color)] -> Color -> Either Text ActivityHandler
derivedActivityHandler net transitionPath activityName parameters resultColor = do
  unless (hasTransition transitionPath net) $
    Left ("cannot derive Activity handler for " <> at <> ": the transition is not in this net")
  let arcs = [a | a <- inputs net transitionPath, not (isInhibit a)]
      indexed = zip [0 :: Int ..] arcs
  matched <- foldlM' [] parameters $ \acc (name, color) -> do
    let matches = [(i, a) | (i, a) <- indexed, a.color == Just color]
    (index, a) <- case matches of
      [m] -> Right m
      _ ->
        Left
          ( prefix <> "parameter " <> pythonStrRepr name <> " (" <> color <> ") requires exactly one matching input arc, found "
              <> pythonIntRepr (length matches)
          )
    forM_ (find (\(_, i, _, _) -> i == index) acc) $ \(prior, _, _, _) ->
      Left
        ( prefix <> "parameter " <> pythonStrRepr name <> " (" <> color <> ") matches input arc "
            <> netPathText a.source
            <> " -> "
            <> netPathText a.target
            <> " already used by parameter "
            <> pythonStrRepr prior
        )
    when (a.weight /= 1) $
      Left
        ( prefix <> "parameter " <> pythonStrRepr name <> " (" <> color <> ") matches weight-" <> pythonIntRepr a.weight <> " arc "
            <> netPathText a.source
            <> " -> "
            <> netPathText a.target
            <> "; collection parameters are not supported"
        )
    let selectionIndex = length [c | c <- take index arcs, c.mode == a.mode]
    Right (acc ++ [(name, index, a, selectionIndex)])
  forM_ indexed $ \(i, a) -> case a.color of
    Just color
      | i `notElem` [index | (_, index, _, _) <- matched] ->
          Left
            ( prefix <> "typed input arc " <> netPathText a.source <> " -> " <> netPathText a.target <> " (" <> color
                <> ") matches no Activity parameter"
            )
    _ -> Right ()
  let outputArcs = outputs net transitionPath
      resultArcs = [a | a <- outputArcs, a.color == Just resultColor]
  when (null resultArcs) $
    Left (prefix <> "return type " <> resultColor <> " matches no output arc")
  forM_ (find (\a -> a.color /= Just resultColor) outputArcs) $ \a ->
    Left
      ( prefix <> "output arc " <> netPathText a.source <> " -> " <> netPathText a.target <> " ("
          <> maybe "untyped" id a.color
          <> ") matches no Activity return"
      )
  let prepare' b = do
        when (b.transition /= transitionPath) $
          Left
            ( "cannot prepare Activity " <> pythonStrRepr activityName <> " for " <> netPathText b.transition
                <> ": this derived handler belongs to "
                <> at
            )
        members <- forM matched $ \(name, _, a, selectionIndex) -> do
          let selections = if isRead a then b.read else b.consumed
              selected = if selectionIndex < length selections then Just (selections !! selectionIndex) else Nothing
          case selected of
            Just (place', [t]) | place' == a.source -> Right (name, t.payload)
            _ -> do
              let found = case selected of
                    Just (place', ts) | place' == a.source -> length ts
                    _ -> 0
              Left
                ( "cannot prepare Activity " <> pythonStrRepr activityName <> " for " <> netPathText b.transition
                    <> ": parameter "
                    <> pythonStrRepr name
                    <> " ("
                    <> maybe "None" id a.color
                    <> ") requires exactly one selected token from "
                    <> netPathText a.source
                    <> ", found "
                    <> pythonIntRepr found
                )
        Right (invocation activityName (objectOf members))
      project' _ result =
        let produced = Token (Just resultColor) result
         in Right (handlerTokens (coalesce [(a.target, [produced]) | a <- resultArcs]))
  Right (ActivityHandler prepare' project' Nothing)
  where
    at = netPathText transitionPath
    prefix = "cannot derive Activity handler for " <> at <> ": "

-- ---------------------------------------------------------------------------
-- Typed derivation

-- | A nominal payload type: its arc colour and its JSON conversions (the
-- reference's dataclass type name and payload converter).
class Typed a where
  typedColor :: Text
  toPayload :: a -> Json
  fromPayload :: Json -> Either Text a

-- | A typed parameter list: the named parameters in declaration order and
-- how to build the function's result from their decoded payloads.
data TypedArgs a = TypedArgs [(Text, Text)] ([Json] -> Either Text (a, [Json]))

instance Functor TypedArgs where
  fmap f (TypedArgs ps run) = TypedArgs ps (fmap (\(a, rest) -> (f a, rest)) . run)

instance Applicative TypedArgs where
  pure a = TypedArgs [] (\rest -> Right (a, rest))
  TypedArgs ps f <*> TypedArgs qs g =
    TypedArgs (ps ++ qs) $ \values -> do
      (h, rest) <- f values
      (a, rest') <- g rest
      Right (h a, rest')

-- | One named parameter of a typed function; its colour is the type's.
param :: forall p. Typed p => Text -> TypedArgs p
param name =
  TypedArgs [(name, typedColor @p)] $ \case
    value : rest -> (\decoded -> (decoded, rest)) <$> fromPayload @p value
    [] -> Left "typed argument list exhausted"

data TypedInput = TypedInput Text Arc Int

data TypedPlan = TypedPlan NetPath [TypedInput]

-- | Plan the inputs of a typed transform or guard over the transition's
-- uniquely coloured weight-one arcs.
derivePlan :: Text -> Net -> NetPath -> [(Text, Text)] -> Either Text TypedPlan
derivePlan subject net transitionPath parameters = do
  unless (hasTransition transitionPath net) $
    Left ("cannot derive " <> subject <> " for " <> at <> ": transition is not in this net")
  when (isSource net transitionPath) $
    Left ("cannot derive " <> subject <> " for " <> at <> ": source transitions are not supported")
  let arcs = [a | a <- inputs net transitionPath, not (isInhibit a)]
  forM_ arcs $ \a -> do
    when (a.color == Nothing) $
      Left ("cannot derive " <> subject <> " for " <> at <> ": input arc " <> netPathText a.source <> " is untyped")
    when (a.weight /= 1) $
      Left
        ( "cannot derive " <> subject <> " for " <> at <> ": input arc " <> netPathText a.source <> " has weight "
            <> pythonIntRepr a.weight
            <> "; collection parameters are not supported"
        )
  (planned, used) <- foldlM' ([], []) parameters $ \(acc, used) (name, color) -> do
    let matches = [i | (i, a) <- zip [0 :: Int ..] arcs, a.color == Just color]
    index <- case matches of
      [i] -> Right i
      _ ->
        Left
          ( "cannot derive " <> subject <> " for " <> at <> ": parameter " <> pythonStrRepr name <> " (" <> color
              <> ") requires exactly one matching input arc, found "
              <> pythonIntRepr (length matches)
          )
    let a = arcs !! index
    when (index `elem` used) $
      Left ("cannot derive " <> subject <> " for " <> at <> ": input arc " <> netPathText a.source <> " is reused")
    let selectionIndex = length [c | c <- take index arcs, c.mode == a.mode]
    Right (acc ++ [TypedInput name a selectionIndex], index : used)
  forM_ (zip [0 :: Int ..] arcs) $ \(i, a) ->
    unless (i `elem` used) $
      Left ("cannot derive " <> subject <> " for " <> at <> ": input arc " <> netPathText a.source <> " matches no parameter")
  Right (TypedPlan transitionPath planned)
  where
    at = netPathText transitionPath

-- | The selected payloads for a binding, in parameter order.
planArguments :: Text -> TypedPlan -> Binding -> Either Text [Json]
planArguments subject (TypedPlan transitionPath planned) b = do
  when (b.transition /= transitionPath) $
    Left
      ( subject <> " for " <> netPathText transitionPath <> " cannot handle binding for " <> netPathText b.transition
      )
  forM planned $ \(TypedInput name a selectionIndex) -> do
    let selections = if isRead a then b.read else b.consumed
        selected = if selectionIndex < length selections then Just (selections !! selectionIndex) else Nothing
    case selected of
      Just (place', [t]) | place' == a.source -> do
        when (t.color /= a.color) $
          Left
            ( subject <> " for " <> netPathText transitionPath <> " parameter " <> pythonStrRepr name <> " requires color "
                <> maybe "None" id a.color
                <> ", got "
                <> maybe "None" id t.color
            )
        Right t.payload
      _ -> do
        let found = case selected of
              Just (place', ts) | place' == a.source -> length ts
              _ -> 0
        Left
          ( subject <> " for " <> netPathText transitionPath <> " parameter " <> pythonStrRepr name
              <> " requires exactly one selected token from "
              <> netPathText a.source
              <> ", found "
              <> pythonIntRepr found
          )

-- | @derive_typed_transform(net, transition, function)@: adapt a typed
-- function over uniquely coloured weight-one arcs into a 'Handler' whose
-- result token goes to every output arc.
deriveTypedTransform :: forall r. Typed r => Net -> NetPath -> TypedArgs r -> Either Text Handler
deriveTypedTransform net transitionPath (TypedArgs parameters run) = do
  plan <- derivePlan "typed transform" net transitionPath parameters
  let color = typedColor @r
      outputArcs = outputs net transitionPath
  when (null outputArcs) $
    Left ("cannot derive typed transform for " <> at <> ": transition has no output arcs")
  forM_ outputArcs $ \a -> do
    when (a.color /= Just color) $
      Left
        ( "cannot derive typed transform for " <> at <> ": output arc " <> netPathText a.target <> " has color "
            <> maybe "untyped" id a.color
            <> ", expected "
            <> color
        )
    when (a.weight /= 1) $
      Left
        ( "cannot derive typed transform for " <> at <> ": output arc " <> netPathText a.target <> " has weight "
            <> pythonIntRepr a.weight
        )
  Right $ \b arcs -> do
    when (arcs /= outputArcs) $
      Left ("typed transform for " <> at <> " received output arcs that differ from derivation")
    values <- planArguments "typed transform" plan b
    (result, _) <- run values
    let encoded = toPayload result
    Right (handlerTokens (coalesce [(a.target, [Token a.color encoded]) | a <- outputArcs]))
  where
    at = netPathText transitionPath

-- | @derive_typed_guard(net, transition, function)@: adapt a typed predicate
-- over uniquely coloured weight-one arcs into a 'Guard'.
deriveTypedGuard :: Net -> NetPath -> TypedArgs Bool -> Either Text Guard
deriveTypedGuard net transitionPath (TypedArgs parameters run) = do
  plan <- derivePlan "typed guard" net transitionPath parameters
  Right $ \b -> do
    values <- planArguments "typed guard" plan b
    fst <$> run values

-- ---------------------------------------------------------------------------
-- Helpers

-- | Append routed tokens per destination, keeping first-routed order (the
-- reference's @routed.get(target, ()) + (token,)@).
coalesce :: [(NetPath, [Token])] -> [(NetPath, [Token])]
coalesce = foldl add []
  where
    add acc (p, ts) = case findIndex ((== p) . fst) acc of
      Just i -> [if j == i then (q, us ++ ts) else (q, us) | (j, (q, us)) <- zip [0 :: Int ..] acc]
      Nothing -> acc ++ [(p, ts)]

objectOf :: [(Text, Json)] -> Json
objectOf = Object

foldlM' :: b -> [a] -> (b -> a -> Either Text b) -> Either Text b
foldlM' z xs f = foldl (\acc x -> acc >>= \b -> f b x) (Right z) xs
