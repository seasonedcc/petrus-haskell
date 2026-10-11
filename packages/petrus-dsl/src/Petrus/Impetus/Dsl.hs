{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The net authoring DSL (@petrus.impetus.dsl@): a typed front end that
-- lowers an authored specification to the kernel's canonical 'Net', plus the
-- handler and guard implementations keyed by canonical 'NetUri'.
--
-- The DSL has no wire format of its own. Its contract is the 'Net' it
-- produces — and therefore the Net-definition v3 projection — which is
-- byte-identical to what the reference DSL produces for the same model
-- (see @differential/dsl_corpus.py@).
--
-- = Authoring
--
-- A specification is authored by an 'Author' program and closed by
-- 'netSpec'. The program's rank-2 brand @s@ ties every node handle to the
-- specification that created it, so connecting nodes of two specifications
-- is a type error rather than a runtime refusal:
--
-- > orders :: Either DslError NetSpec
-- > orders = netSpec (named "orders") $ do
-- >   pending <- p "pending" >>= color "Order"
-- >   receipt <- p "receipt" >>= color "Receipt"
-- >   process <- t "process" >>= configure [handler "process"]
-- >   void $ pending ~> process ~> receipt
-- >   void $ pending ~> readArc {arcWeight = 2, arcFilter = Just (FilterSymbol "current")} ~> process
--
-- * 'p' and 't' address a node relative to the current 'scope' and register
--   it on first touch, so places and transitions keep first-touch order,
--   including touches made inside a '~>' expression.
-- * '~>' connects sources to targets (lists fan out source-major) and
--   returns its right operand, so chains compose left to right. An
--   'ArcSpec' between two operands is the arc inscription. Arcs only join a
--   place and a transition: anything else does not type-check.
-- * 'color' and 'configure' declare a node; repeating an identical
--   declaration is idempotent and a different one is refused. 'recolor' and
--   'override' change an existing declaration explicitly.
-- * 'scope' opens a path prefix; 'stamp' places a reusable specification at
--   the current (non-root) scope. Nodes addressed inside a stamp are the
--   stamped child's: configuring them records a destination override.
--
-- Every authoring step is atomic: a refused step leaves the specification
-- as it was, which 'attempt' makes observable.
module Petrus.Impetus.Dsl
  ( -- * Specifications
    NetSpec
  , Header
  , named
  , unnamed
  , withCompletion
  , netSpec
  , runNetSpec
  , specName
  , specCompletion
  , connections
  , Connection (..)
  , NodeRef (..)
  , nodeRefPath
    -- * Authoring
  , Author
  , DslError (..)
  , attempt
  , P
  , T
  , HasNodePath (..)
  , p
  , t
  , scope
  , stamp
    -- * Places
  , color
  , colored
  , recolor
  , placeColor
  , colorOf
    -- * Transitions
  , Field
  , handler
  , noHandler
  , guards
  , timers
  , configure
  , override
  , HandlerSpec
  , GuardSpec
  , handlerSymbol
  , guardSymbol
  , celGuard
  , direct
  , typedGuard
  , petriHandler
  , petriGuard
  , activityHandler
  , implementationName
  , guardImplementationName
    -- * Connections
  , (~>)
  , ArcSpec (..)
  , arc
  , readArc
  , inhibitArc
  , Pending
  , NodeKind (..)
  , Joins
  , Handles (..)
  , Source (..)
  , Target (..)
    -- * Building
  , BuiltNet (..)
  , build
  , flatten
  , withImplementations
    -- * Re-exported kernel vocabulary
  , ArcMode (..)
  , Cel
  , cel
  , unsafeCel
  , Color
  , CompletionDeclaration (..)
  , FilterDeclaration (..)
  , NetPath
  , Number (..)
  , Timer (..)
  ) where

import Control.Exception (Exception)
import Control.Monad (ap, foldM, forM, forM_, liftM, unless, when)
import Data.Foldable (toList)
import Data.Kind (Constraint, Type)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import GHC.TypeLits (ErrorMessage (..), TypeError)
import Petrus.Impetus.Binding (ActivityHandler, BoundHandler (..), Handler, Typed (..), TypedArgs, deriveTypedGuard, deriveTypedTransform)
import Petrus.Impetus.Instance (ImplementationRef (..), InstanceConfig (..))
import Petrus.Json.Python (pythonOptionalStrRepr, pythonStrRepr)
import Petrus.Impetus.Petrinet.Enabledness (Guard)
import Petrus.Impetus.Petrinet.Schema
  ( AnonymousDeclaration (..)
  , ArcMode (..)
  , Cel
  , Color
  , CompletionDeclaration (..)
  , FilterDeclaration (..)
  , GuardDeclaration (..)
  , HandlerDeclaration (..)
  , Net
  , NetPath
  , NetUri
  , Number (..)
  , Timer (..)
  , cel
  , guardUris
  , handlerUri
  , mkNet
  , netPath
  , netPathText
  , unsafeCel
  )
import Petrus.Impetus.Petrinet.Schema qualified as Schema

-- ---------------------------------------------------------------------------
-- Errors

-- | A refused authoring step or build, with the reference's message. The
-- reference raises these as @ValueError@ (its @TypeError@ cases are type
-- errors here, except where noted on the refusing function).
newtype DslError = DslError {message :: Text}
  deriving stock (Eq)

instance Show DslError where
  show (DslError text) = T.unpack text

instance Exception DslError

refuse :: Text -> Either DslError a
refuse = Left . DslError

fromKernel :: Either Text a -> Either DslError a
fromKernel = either refuse Right

-- ---------------------------------------------------------------------------
-- Implementations

data HandlerFlavor = PetriHandler | DirectHandler | ActivityFlavor
  deriving stock (Eq, Show)

data GuardFlavor = PetriGuard | TypedGuard
  deriving stock (Eq, Show)

-- | A transition handler: a named symbol (bound late, by the host) or an
-- implementation the build lowers and keys by the handler's canonical URI.
-- An implementation is identified by its flavor and display name: the
-- display name stands in for the reference's function identity and its
-- @__name__@, and like it never reaches the canonical net.
data HandlerSpec
  = HandlerNamed Text
  | HandlerImplemented Text HandlerFlavor (Net -> NetPath -> Either Text BoundHandler)

instance Eq HandlerSpec where
  HandlerNamed a == HandlerNamed b = a == b
  HandlerImplemented a f _ == HandlerImplemented b g _ = a == b && f == g
  _ == _ = False

instance Show HandlerSpec where
  show = \case
    HandlerNamed name -> T.unpack (pythonStrRepr name)
    HandlerImplemented name flavor _ -> "HandlerSpec(" <> show flavor <> ", " <> T.unpack (pythonStrRepr name) <> ")"

-- | A string literal is a named handler symbol.
instance IsString HandlerSpec where
  fromString = HandlerNamed . T.pack

-- | A transition guard: a named symbol, an inline CEL expression, or an
-- implementation (identified like a 'HandlerSpec').
data GuardSpec
  = GuardNamed Text
  | GuardInline Cel
  | GuardImplemented Text GuardFlavor (Net -> NetPath -> Either Text Guard)

instance Eq GuardSpec where
  GuardNamed a == GuardNamed b = a == b
  GuardInline a == GuardInline b = a == b
  GuardImplemented a f _ == GuardImplemented b g _ = a == b && f == g
  _ == _ = False

instance Show GuardSpec where
  show = \case
    GuardNamed name -> T.unpack (pythonStrRepr name)
    GuardInline expression -> show expression
    GuardImplemented name flavor _ -> "GuardSpec(" <> show flavor <> ", " <> T.unpack (pythonStrRepr name) <> ")"

-- | A string literal is a named guard symbol.
instance IsString GuardSpec where
  fromString = GuardNamed . T.pack

handlerSymbol :: Text -> HandlerSpec
handlerSymbol = HandlerNamed

guardSymbol :: Text -> GuardSpec
guardSymbol = GuardNamed

-- | An inline CEL guard (@Cel(...)@ in a guard tuple).
celGuard :: Cel -> GuardSpec
celGuard = GuardInline

-- | @direct(function)@: a pure typed transformation. Its parameters match
-- the transition's uniquely colored weight-one input arcs by color, and its
-- result goes to every output arc ("Petrus.Impetus.Binding"). The
-- reference's @converter=@ is the parameter and result types' 'Typed'
-- instances: decode a payload differently by giving it another type.
direct :: forall r. Typed r => Text -> TypedArgs r -> HandlerSpec
direct name args = HandlerImplemented name DirectHandler $ \net at ->
  PureHandler <$> deriveTypedTransform net at args

-- | @typed_guard(function)@, and the reference's bare-callable guard: a pure
-- typed predicate over the selected inputs.
typedGuard :: Text -> TypedArgs Bool -> GuardSpec
typedGuard name args = GuardImplemented name TypedGuard $ \net at -> deriveTypedGuard net at args

-- | @petri_handler(function)@: a Petri-aware handler, stored as given.
petriHandler :: Text -> Handler -> HandlerSpec
petriHandler name implementation = HandlerImplemented name PetriHandler (\_ _ -> Right (PureHandler implementation))

-- | @petri_guard(function)@: a Petri-aware guard, stored as given.
petriGuard :: Text -> Guard -> GuardSpec
petriGuard name implementation = GuardImplemented name PetriGuard (\_ _ -> Right implementation)

-- | A Petri-aware Activity bridge, stored as given. (The reference binds
-- Activity handlers after the build, by URI; this is the same binding made
-- at authoring time.)
activityHandler :: Text -> ActivityHandler -> HandlerSpec
activityHandler name implementation = HandlerImplemented name ActivityFlavor (\_ _ -> Right (ActivityBound implementation))

-- | The display name of an implemented handler.
implementationName :: HandlerSpec -> Maybe Text
implementationName = \case
  HandlerImplemented name _ _ -> Just name
  HandlerNamed _ -> Nothing

-- | The display name of an implemented guard.
guardImplementationName :: GuardSpec -> Maybe Text
guardImplementationName = \case
  GuardImplemented name _ _ -> Just name
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Transition configuration

-- | A transition's authored behavior (@_TransitionSpecValue@).
data Behavior = Behavior
  { handlerValue :: Maybe HandlerSpec
  , guardValues :: [GuardSpec]
  , timerValues :: [Timer]
  }
  deriving stock (Eq, Show)

emptyBehavior :: Behavior
emptyBehavior = Behavior Nothing [] []

-- | A destination override of an inherited transition: 'Nothing' keeps the
-- inherited field (@_UNSET@).
data Override = Override
  { handlerChange :: Maybe (Maybe HandlerSpec)
  , guardChange :: Maybe [GuardSpec]
  , timerChange :: Maybe [Timer]
  }

noOverride :: Override
noOverride = Override Nothing Nothing Nothing

-- | One field of a transition declaration.
data Field
  = HandlerField (Maybe HandlerSpec)
  | GuardsField [GuardSpec]
  | TimersField [Timer]

-- | @handler=...@.
handler :: HandlerSpec -> Field
handler = HandlerField . Just

-- | @handler=None@: with 'override', clears the handler.
noHandler :: Field
noHandler = HandlerField Nothing

-- | @guards=(...)@ in authored order; @[]@ clears with 'override'.
guards :: [GuardSpec] -> Field
guards = GuardsField

-- | @timers=(...)@; @[]@ clears with 'override'.
timers :: [Timer] -> Field
timers = TimersField

applyField :: Behavior -> Field -> Behavior
applyField b = \case
  HandlerField h -> b {handlerValue = h}
  GuardsField gs -> b {guardValues = gs}
  TimersField ts -> b {timerValues = ts}

overrideField :: Override -> Field -> Override
overrideField o = \case
  HandlerField h -> o {handlerChange = Just h}
  GuardsField gs -> o {guardChange = Just gs}
  TimersField ts -> o {timerChange = Just ts}

overrideBehavior :: Override -> Behavior -> Behavior
overrideBehavior o b =
  Behavior
    { handlerValue = fromMaybe b.handlerValue o.handlerChange
    , guardValues = fromMaybe b.guardValues o.guardChange
    , timerValues = fromMaybe b.timerValues o.timerChange
    }

mergeOverride :: Override -> Override -> Override
mergeOverride current new =
  Override
    { handlerChange = maybe current.handlerChange Just new.handlerChange
    , guardChange = maybe current.guardChange Just new.guardChange
    , timerChange = maybe current.timerChange Just new.timerChange
    }

-- ---------------------------------------------------------------------------
-- Arc inscriptions

-- | An authored arc inscription (@arc(...)@, @arc.read(...)@,
-- @arc.inhibit(...)@). Placed between the operands of '~>'.
data ArcSpec = ArcSpec
  { arcMode :: ArcMode
  , arcWeight :: Int
  , arcColor :: Maybe Color
  , arcFilter :: Maybe FilterDeclaration
  }
  deriving stock (Eq, Show)

-- | @arc()@: a weight-one consume arc.
arc :: ArcSpec
arc = ArcSpec Consume 1 Nothing Nothing

-- | @arc.read()@.
readArc :: ArcSpec
readArc = arc {arcMode = Read}

-- | @arc.inhibit()@.
inhibitArc :: ArcSpec
inhibitArc = arc {arcMode = Inhibit}

-- ---------------------------------------------------------------------------
-- Nodes and connections

-- | A place handle of the specification branded @s@.
newtype P (s :: Type) = P NetPath
  deriving stock (Eq, Ord, Show)

-- | A transition handle of the specification branded @s@.
newtype T (s :: Type) = T NetPath
  deriving stock (Eq, Ord, Show)

-- | The absolute path of a node within its specification (@abs(node)@).
class HasNodePath h where
  nodePath :: h -> NetPath

instance HasNodePath (P s) where
  nodePath (P at) = at

instance HasNodePath (T s) where
  nodePath (T at) = at

-- | An authored connection endpoint, outside any authoring program.
data NodeRef = PlaceRef NetPath | TransitionRef NetPath
  deriving stock (Eq, Ord, Show)

nodeRefPath :: NodeRef -> NetPath
nodeRefPath = \case
  PlaceRef at -> at
  TransitionRef at -> at

-- | One authored source-target connection and its inscription
-- (@ConnectionSpec@).
data Connection = Connection
  { source :: NodeRef
  , target :: NodeRef
  , inscription :: ArcSpec
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Specifications

-- | The authored log entries a build replays (@_events@).
data Event
  = PlaceEvent NetPath
  | TransitionEvent NetPath
  | ConnectionEvent Connection
  | StampEvent NetPath

-- | The mutable state of the reference's @NetSpec@, as a value.
data Body = Body
  { placeSet :: Set NetPath
  , placeOrder :: Seq NetPath
  , transitionSet :: Set NetPath
  , transitionOrder :: Seq NetPath
  , placeColors :: Map NetPath (Maybe Color)
  , transitionValues :: Map NetPath Behavior
  , placeOverrides :: Map NetPath (Maybe Color)
  , transitionOverrides :: Map NetPath Override
  , connectionLog :: Seq Connection
  , stamps :: Map NetPath NetSpec
  , events :: Seq Event
  }

emptyBody :: Body
emptyBody =
  Body
    { placeSet = Set.empty
    , placeOrder = Seq.empty
    , transitionSet = Set.empty
    , transitionOrder = Seq.empty
    , placeColors = Map.empty
    , transitionValues = Map.empty
    , placeOverrides = Map.empty
    , transitionOverrides = Map.empty
    , connectionLog = Seq.empty
    , stamps = Map.empty
    , events = Seq.empty
    }

-- | A specification's name and root completion (@NetSpec(name,
-- completion=...)@).
data Header = Header
  { headerName :: Maybe Text
  , headerCompletion :: Maybe CompletionDeclaration
  }
  deriving stock (Eq, Show)

-- | A named specification.
named :: Text -> Header
named name = Header (Just name) Nothing

-- | An anonymous specification.
unnamed :: Header
unnamed = Header Nothing Nothing

-- | Declare the root completion condition. A specification that declares
-- one can only be built as a root, never stamped.
withCompletion :: CompletionDeclaration -> Header -> Header
withCompletion completion header = header {headerCompletion = Just completion}

-- | One authored, immutable net definition, reusable as a root or as a
-- stamped child (@NetSpec@).
data NetSpec = NetSpec
  { header :: Header
  , body :: Body
  }

instance Show NetSpec where
  show spec =
    "NetSpec("
      <> T.unpack (pythonOptionalStrRepr spec.header.headerName)
      <> ", "
      <> show (Set.size spec.body.placeSet)
      <> "p, "
      <> show (Set.size spec.body.transitionSet)
      <> "t, "
      <> show (Seq.length spec.body.connectionLog)
      <> "c, "
      <> show (Map.size spec.body.stamps)
      <> "s)"

-- | The specification's name.
specName :: NetSpec -> Maybe Text
specName spec = spec.header.headerName

-- | The specification's root completion.
specCompletion :: NetSpec -> Maybe CompletionDeclaration
specCompletion spec = spec.header.headerCompletion

-- | The authored connections in authored order (@NetSpec.connections@).
connections :: NetSpec -> [Connection]
connections spec = toList spec.body.connectionLog

-- | Author and close one specification.
netSpec :: Header -> (forall s. Author s a) -> Either DslError NetSpec
netSpec header program = fst <$> runNetSpec header program

-- | Author one specification, also returning the program's result.
runNetSpec :: Header -> (forall s. Author s a) -> Either DslError (NetSpec, a)
runNetSpec header program = do
  case header.headerName of
    Just name
      | T.null name ->
          refuse ("net specification name must be a non-empty string or None, got " <> pythonStrRepr name)
    _ -> Right ()
  let Author run = program
  (result, finished) <- run [] emptyBody
  Right (NetSpec header finished, result)

-- ---------------------------------------------------------------------------
-- The authoring monad

-- | An authoring program over the specification branded @s@: a state
-- transformer of the specification under the current scope prefix, which
-- refuses atomically.
newtype Author (s :: Type) a = Author ([Text] -> Body -> Either DslError (a, Body))

instance Functor (Author s) where
  fmap = liftM

instance Applicative (Author s) where
  pure a = Author (\_ b -> Right (a, b))
  (<*>) = ap

instance Monad (Author s) where
  Author m >>= k = Author $ \prefix b -> do
    (a, b') <- m prefix b
    let Author n = k a
    n prefix b'

-- | Run a step; if it is refused, the specification is left exactly as it
-- was before the step and the refusal is returned.
attempt :: Author s a -> Author s (Either DslError a)
attempt (Author m) = Author $ \prefix b -> case m prefix b of
  Left err -> Right (Left err, b)
  Right (a, b') -> Right (Right a, b')

authorFail :: DslError -> Author s a
authorFail err = Author (\_ _ -> Left err)

liftEither :: Either DslError a -> Author s a
liftEither = either authorFail pure

getBody :: Author s Body
getBody = Author (\_ b -> Right (b, b))

putBody :: Body -> Author s ()
putBody b = Author (\_ _ -> Right ((), b))

getPrefix :: Author s [Text]
getPrefix = Author (\prefix b -> Right (prefix, b))

-- | Address a place relative to the current scope (@net.p.name@). The name
-- may be dotted. A place outside every stamp is registered on first touch.
p :: Text -> Author s (P s)
p name = do
  at <- resolve name
  b <- getBody
  putBody (touchPlace at b)
  pure (P at)

-- | Address a transition relative to the current scope (@net.t.name@).
t :: Text -> Author s (T s)
t name = do
  at <- resolve name
  b <- getBody
  putBody (touchTransition at b)
  pure (T at)

resolve :: Text -> Author s NetPath
resolve name = do
  prefix <- getPrefix
  liftEither (fromKernel (netPath (T.intercalate "." (prefix ++ [name]))))

-- | Author inside one more scope segment (@net.s.name@ / @net.s[name]@). The
-- segment must be one non-empty path segment.
scope :: Text -> Author s a -> Author s a
scope segment (Author inner)
  | T.null segment || T.any (== '.') segment =
      authorFail (DslError ("scope segment must be one non-empty path segment, got " <> pythonStrRepr segment))
  | otherwise = Author (\prefix b -> inner (prefix ++ [segment]) b)

-- | Stamp a reusable specification at the current scope
-- (@scope.stamp(source)@). Stamping the same scope again replaces the
-- stamped source and clears every destination override under it.
stamp :: NetSpec -> Author s ()
stamp source = do
  prefix <- getPrefix
  b <- getBody
  b' <- liftEither (stampBody prefix source b)
  putBody b'

touchPlace :: NetPath -> Body -> Body
touchPlace at b
  | isJust (stampFor b at) || Set.member at b.placeSet = b
  | otherwise =
      b
        { placeSet = Set.insert at b.placeSet
        , placeOrder = b.placeOrder Seq.|> at
        , events = b.events Seq.|> PlaceEvent at
        }

touchTransition :: NetPath -> Body -> Body
touchTransition at b
  | isJust (stampFor b at) || Set.member at b.transitionSet = b
  | otherwise =
      b
        { transitionSet = Set.insert at b.transitionSet
        , transitionOrder = b.transitionOrder Seq.|> at
        , events = b.events Seq.|> TransitionEvent at
        }

-- ---------------------------------------------------------------------------
-- Place configuration

-- | Declare a place's color (@net.p.name(Color)@); returns the same handle.
color :: Color -> P s -> Author s (P s)
color = colored . Just

-- | Declare a place's color, or declare it uncolored (@PlaceSpec(None)@).
-- Repeating the same declaration is a no-op; a different one is refused.
colored :: Maybe Color -> P s -> Author s (P s)
colored value node@(P at) = do
  b <- getBody
  (inherited, configured, existing) <- liftEither (lookupPlace b at)
  if inherited
    then do
      when (configured && existing /= value) $ alreadyColored existing
      putBody b {placeOverrides = Map.insert at value b.placeOverrides}
    else do
      forM_ (Map.lookup at b.placeColors) $ \prior -> when (prior /= value) (alreadyColored prior)
      putBody b {placeColors = Map.insert at value b.placeColors}
  pure node
  where
    alreadyColored existing =
      authorFail (DslError ("place " <> netPathText at <> " is already configured with color " <> pythonOptionalStrRepr existing))

-- | Change or clear an existing explicit or inherited place color
-- (@PlaceSpec.override(color=...)@).
recolor :: Maybe Color -> P s -> Author s (P s)
recolor value node@(P at) = do
  b <- getBody
  (inherited, configured, _) <- liftEither (lookupPlace b at)
  unless configured $
    authorFail (DslError ("place " <> netPathText at <> " has no explicit or inherited configuration to override"))
  putBody $
    if inherited
      then b {placeOverrides = Map.insert at value b.placeOverrides}
      else b {placeColors = Map.insert at value b.placeColors}
  pure node

-- | The place's configured color, if any (@PlaceSpec.color@).
placeColor :: P s -> Author s (Maybe Color)
placeColor (P at) = do
  b <- getBody
  (_, configured, value) <- liftEither (lookupPlace b at)
  pure (if configured then value else Nothing)

-- | The color a 'Typed' payload type names (the reference's class-as-color
-- adapter, @Order@ → @"Order"@).
colorOf :: forall a. Typed a => Color
colorOf = typedColor @a

-- ---------------------------------------------------------------------------
-- Transition configuration

-- | Declare a transition's behavior (@net.t.name(handler=..., guards=...,
-- timers=...)@); omitted fields take their defaults. Repeating the same
-- declaration is a no-op; a different one is refused.
configure :: [Field] -> T s -> Author s (T s)
configure fields node@(T at) = do
  let value = foldl applyField emptyBehavior fields
  b <- getBody
  (inherited, configured, existing) <- liftEither (lookupTransition b at)
  if inherited
    then do
      when (configured && existing /= value) conflict
      putBody
        b
          { transitionOverrides =
              Map.insert at (Override (Just value.handlerValue) (Just value.guardValues) (Just value.timerValues)) b.transitionOverrides
          }
    else do
      forM_ (Map.lookup at b.transitionValues) $ \prior -> when (prior /= value) conflict
      putBody b {transitionValues = Map.insert at value b.transitionValues}
  pure node
  where
    conflict =
      authorFail
        (DslError ("transition " <> netPathText at <> " is already configured; use transition.override(...) to change it"))

-- | Change only the given fields of an existing explicit or inherited
-- transition declaration (@TransitionSpec.override(...)@); 'noHandler' and
-- empty lists clear. At least one field is required.
override :: [Field] -> T s -> Author s (T s)
override fields node@(T at) = do
  b <- getBody
  (inherited, configured, _) <- liftEither (lookupTransition b at)
  unless configured $
    authorFail (DslError ("transition " <> netPathText at <> " has no explicit or inherited configuration to override"))
  when (null fields) $
    authorFail (DslError "transition override requires at least one of handler, guards, or timers")
  let change = foldl overrideField noOverride fields
  putBody $
    if inherited
      then
        let current = Map.findWithDefault noOverride at b.transitionOverrides
         in b {transitionOverrides = Map.insert at (mergeOverride current change) b.transitionOverrides}
      else b {transitionValues = Map.adjust (overrideBehavior change) at b.transitionValues}
  pure node

-- ---------------------------------------------------------------------------
-- Connections

-- | Which side of the bipartite graph a handle is on.
data NodeKind = PlaceKind | TransitionKind

-- | An arc joins a place and a transition.
type family Joins (k :: NodeKind) (k' :: NodeKind) :: Constraint where
  Joins 'PlaceKind 'TransitionKind = ()
  Joins 'TransitionKind 'PlaceKind = ()
  Joins 'PlaceKind 'PlaceKind =
    TypeError ('Text "an arc cannot connect a place to a place: connect a place and a transition")
  Joins 'TransitionKind 'TransitionKind =
    TypeError ('Text "an arc cannot connect a transition to a transition: connect a place and a transition")

-- | Node handles and lists of them (the reference's node or tuple of nodes).
class Handles (s :: Type) h | h -> s where
  type HandleKind h :: NodeKind
  handleRefs :: h -> [NodeRef]

instance Handles s (P s) where
  type HandleKind (P s) = 'PlaceKind
  handleRefs (P at) = [PlaceRef at]

instance Handles s (T s) where
  type HandleKind (T s) = 'TransitionKind
  handleRefs (T at) = [TransitionRef at]

instance Handles s h => Handles s [h] where
  type HandleKind [h] = HandleKind h
  handleRefs = concatMap handleRefs

instance Handles s h => Handles s (NonEmpty h) where
  type HandleKind (NonEmpty h) = HandleKind h
  handleRefs = concatMap handleRefs . toList

-- | Sources selected by an inscription, waiting for their targets
-- (@_PendingConnection@).
data Pending (s :: Type) (k :: NodeKind) = Pending (NonEmpty NodeRef) ArcSpec

-- | The left operand of '~>': handles, an authoring step yielding them, or
-- a pending inscription.
class Source (s :: Type) a | a -> s where
  type SourceKind a :: NodeKind
  sourceOf :: a -> Author s (NonEmpty NodeRef, Maybe ArcSpec)

handleSource :: Handles s h => h -> Author s (NonEmpty NodeRef, Maybe ArcSpec)
handleSource h = (\refs -> (refs, Nothing)) <$> nonEmptyRefs h

nonEmptyRefs :: Handles s h => h -> Author s (NonEmpty NodeRef)
nonEmptyRefs h = case NE.nonEmpty (handleRefs h) of
  Just refs -> pure refs
  Nothing -> authorFail (DslError "expected a node specification or non-empty tuple of them, got []")

instance Source s (P s) where
  type SourceKind (P s) = 'PlaceKind
  sourceOf = handleSource

instance Source s (T s) where
  type SourceKind (T s) = 'TransitionKind
  sourceOf = handleSource

instance Handles s h => Source s [h] where
  type SourceKind [h] = HandleKind h
  sourceOf = handleSource

instance Handles s h => Source s (NonEmpty h) where
  type SourceKind (NonEmpty h) = HandleKind h
  sourceOf = handleSource

instance Source s (Pending s k) where
  type SourceKind (Pending s k) = k
  sourceOf (Pending refs inscribed) = pure (refs, Just inscribed)

instance Source s x => Source s (Author s x) where
  type SourceKind (Author s x) = SourceKind x
  sourceOf step = step >>= sourceOf

-- | The right operand of '~>', given the sources' kind: handles (connected,
-- and returned), an authoring step yielding them, or an inscription
-- (returned as a 'Pending' connection).
class Target (s :: Type) (k :: NodeKind) b where
  type Arrival s k b :: Type
  arriveAt :: NonEmpty NodeRef -> Maybe ArcSpec -> b -> Author s (Arrival s k b)

handleArrival :: Handles s h => NonEmpty NodeRef -> Maybe ArcSpec -> h -> Author s h
handleArrival sources inscribed h = do
  targets <- nonEmptyRefs h
  connect sources targets (fromMaybe arc inscribed)
  pure h

instance (s ~ s', Joins k 'PlaceKind) => Target s k (P s') where
  type Arrival s k (P s') = P s'
  arriveAt = handleArrival

instance (s ~ s', Joins k 'TransitionKind) => Target s k (T s') where
  type Arrival s k (T s') = T s'
  arriveAt = handleArrival

instance (Handles s' h, s ~ s', Joins k (HandleKind h)) => Target s k [h] where
  type Arrival s k [h] = [h]
  arriveAt = handleArrival

instance (Handles s' h, s ~ s', Joins k (HandleKind h)) => Target s k (NonEmpty h) where
  type Arrival s k (NonEmpty h) = NonEmpty h
  arriveAt = handleArrival

instance Target s k ArcSpec where
  type Arrival s k ArcSpec = Pending s k
  arriveAt sources inscribed next = case inscribed of
    Nothing -> pure (Pending sources next)
    Just _ -> authorFail (DslError "expected a node specification or non-empty tuple of them, got ArcSpec")

instance (s ~ s', Target s k x) => Target s k (Author s' x) where
  type Arrival s k (Author s' x) = Arrival s k x
  arriveAt sources inscribed step = step >>= arriveAt @s @k sources inscribed

-- | Connect (@>>@). Evaluates the left operand, then the right one, then
-- adds one arc per source and target pair, source-major, and returns the
-- right operand so that @a ~> b ~> c@ connects @a@ to @b@ and then @b@ to
-- @c@. Between two operands, an 'ArcSpec' is the arcs' inscription
-- (@a ~> readArc ~> b@); otherwise the arc is 'arc'.
(~>) :: forall s a b. (Source s a, Target s (SourceKind a) b) => a -> b -> Author s (Arrival s (SourceKind a) b)
from ~> to = do
  (sources, inscribed) <- sourceOf from
  arriveAt @s @(SourceKind a) sources inscribed to

infixl 1 ~>

connect :: NonEmpty NodeRef -> NonEmpty NodeRef -> ArcSpec -> Author s ()
connect sources targets inscribed = do
  b <- getBody
  let additions = Seq.fromList [Connection s t' inscribed | s <- toList sources, t' <- toList targets]
  putBody
    b
      { connectionLog = b.connectionLog <> additions
      , events = b.events <> fmap ConnectionEvent additions
      }

-- ---------------------------------------------------------------------------
-- Stamps and lookups

label :: NetSpec -> Text
label spec = fromMaybe "<anonymous>" spec.header.headerName

scopeLabel :: [Text] -> Text
scopeLabel = \case
  [] -> "<root>"
  segments -> T.intercalate "." segments

-- | Whether a path lies within (or is) a prefix path, segment-wise.
within :: NetPath -> NetPath -> Bool
within at prefix =
  let a = netPathText at
      q = netPathText prefix
   in a == q || (q <> ".") `T.isPrefixOf` a

-- | The path below a prefix ('Nothing' when it is the prefix itself).
relative :: NetPath -> NetPath -> Maybe NetPath
relative at prefix
  | at == prefix = Nothing
  | otherwise = Just (unsafePath (T.drop (T.length (netPathText prefix) + 1) (netPathText at)))

prefixed :: [Text] -> NetPath -> NetPath
prefixed [] at = at
prefixed prefix at = unsafePath (T.intercalate "." prefix <> "." <> netPathText at)

unsafePath :: Text -> NetPath
unsafePath = either (error . T.unpack) id . netPath

-- | Every prefix of a path, longest first (the path itself included).
prefixesOf :: NetPath -> [NetPath]
prefixesOf at =
  let text = netPathText at
      cuts = [i | (i, c) <- zip [0 :: Int ..] (T.unpack text), c == '.']
   in at : [unsafePath (T.take i text) | i <- reverse cuts]

-- | The innermost stamp enclosing a path (@_stamp_for@).
stampFor :: Body -> NetPath -> Maybe (NetPath, NetSpec)
stampFor b at
  | Map.null b.stamps = Nothing
  | otherwise = case [(q, s) | q <- prefixesOf at, Just s <- [Map.lookup q b.stamps]] of
      found : _ -> Just found
      [] -> Nothing

-- | @(inherited, configured, color)@ of a place (@_lookup_place@).
lookupPlace :: Body -> NetPath -> Either DslError (Bool, Bool, Maybe Color)
lookupPlace b at = case stampFor b at of
  Nothing -> Right (False, Map.member at b.placeColors, join' (Map.lookup at b.placeColors))
  Just (stampPath, source) -> do
    let rel = relative at stampPath
        (exists, configured, value) = sourcePlace source.body rel
    unless exists $
      refuse
        ( "stamp of " <> label source <> " at " <> netPathText stampPath <> " has no place "
            <> maybe "None" netPathText rel
            <> " requested as "
            <> netPathText at
        )
    case Map.lookup at b.placeOverrides of
      Just overridden -> Right (True, True, overridden)
      Nothing -> Right (True, configured, value)

sourcePlace :: Body -> Maybe NetPath -> (Bool, Bool, Maybe Color)
sourcePlace _ Nothing = (False, False, Nothing)
sourcePlace b (Just at) = case stampFor b at of
  Nothing -> (Set.member at b.placeSet, Map.member at b.placeColors, join' (Map.lookup at b.placeColors))
  Just _ -> case lookupPlace b at of
    Left _ -> (False, False, Nothing)
    Right (_, configured, value) -> (True, configured, value)

-- | @(inherited, configured, behavior)@ of a transition
-- (@_lookup_transition@).
lookupTransition :: Body -> NetPath -> Either DslError (Bool, Bool, Behavior)
lookupTransition b at = case stampFor b at of
  Nothing ->
    Right (False, Map.member at b.transitionValues, Map.findWithDefault emptyBehavior at b.transitionValues)
  Just (stampPath, source) -> do
    let rel = relative at stampPath
        (exists, configured, value) = sourceTransition source.body rel
    unless exists $
      refuse
        ( "stamp of " <> label source <> " at " <> netPathText stampPath <> " has no transition "
            <> maybe "None" netPathText rel
            <> " requested as "
            <> netPathText at
        )
    case Map.lookup at b.transitionOverrides of
      Nothing -> Right (True, configured, value)
      Just change -> Right (True, True, overrideBehavior change value)

sourceTransition :: Body -> Maybe NetPath -> (Bool, Bool, Behavior)
sourceTransition _ Nothing = (False, False, emptyBehavior)
sourceTransition b (Just at) = case stampFor b at of
  Nothing ->
    ( Set.member at b.transitionSet
    , Map.member at b.transitionValues
    , Map.findWithDefault emptyBehavior at b.transitionValues
    )
  Just _ -> case lookupTransition b at of
    Left _ -> (False, False, emptyBehavior)
    Right (_, configured, value) -> (True, configured, value)

join' :: Maybe (Maybe a) -> Maybe a
join' = fromMaybe Nothing

stampBody :: [Text] -> NetSpec -> Body -> Either DslError Body
stampBody segments source b = do
  when (null segments) $
    refuse ("cannot stamp " <> label source <> " at <root>: reusable definitions require a non-root scope")
  let at = unsafePath (T.intercalate "." segments)
  forM_ (stampFor b at) $ \(enclosing, owner) ->
    when (enclosing /= at) $
      refuse
        ( "cannot stamp " <> label source <> " at " <> netPathText at <> ": scope belongs to " <> label owner
            <> " stamped at "
            <> netPathText enclosing
        )
  let occupiedPlaces = [q | q <- toList b.placeOrder, q `within` at]
      occupiedTransitions = [q | q <- toList b.transitionOrder, q `within` at]
      nested = [q | StampEvent q <- toList b.events, q /= at, q `within` at]
      owners =
        ["place " <> netPathText q | q <- occupiedPlaces]
          ++ ["transition " <> netPathText q | q <- occupiedTransitions]
          ++ ["stamp " <> netPathText q | q <- nested]
  unless (null owners) $
    refuse
      ("cannot stamp " <> label source <> " at " <> netPathText at <> ": destination already owns " <> T.intercalate ", " owners)
  let fresh = not (Map.member at b.stamps)
  Right
    b
      { stamps = Map.insert at source b.stamps
      , events = if fresh then b.events Seq.|> StampEvent at else b.events
      , placeOverrides = Map.filterWithKey (\q _ -> not (q `within` at)) b.placeOverrides
      , transitionOverrides = Map.filterWithKey (\q _ -> not (q `within` at)) b.transitionOverrides
      }

-- ---------------------------------------------------------------------------
-- Building

-- | One immutable canonical net and its implementations, keyed by canonical
-- URI (@BuiltNet@).
data BuiltNet = BuiltNet
  { net :: Net
  , handlers :: Map NetUri BoundHandler
  , guards :: Map NetUri Guard
  }

-- | Compose and lower a specification through the canonical 'Net'
-- constructor, which stays the validation boundary (@NetSpec.build()@).
build :: NetSpec -> Either DslError BuiltNet
build spec = do
  effective <- flatten spec
  let b = effective.body
  canonical <- canonicalNet effective
  lowered <- forM (Map.toList b.transitionValues) $ \(at, value) -> do
    h <- case value.handlerValue of
      Just (HandlerImplemented _ _ lower) -> case handlerUri canonical at of
        Just uri -> (\bound -> [(uri, bound)]) <$> fromKernel (lower canonical at)
        Nothing -> Right []
      _ -> Right []
    gs <- forM (zip value.guardValues (guardUris canonical at)) $ \case
      (GuardImplemented _ _ lower, uri) -> (\g -> [(uri, g)]) <$> fromKernel (lower canonical at)
      _ -> Right []
    Right (h, concat gs)
  Right
    BuiltNet
      { net = canonical
      , handlers = Map.fromList (concatMap fst lowered)
      , guards = Map.fromList (concatMap snd lowered)
      }

-- | The composed specification as one flat specification with no stamps
-- (@NetSpec.copy()@).
flatten :: NetSpec -> Either DslError NetSpec
flatten root = NetSpec root.header <$> compose root [] emptyBody

compose :: NetSpec -> [Text] -> Body -> Either DslError Body
compose source prefix effective0 = do
  when (not (null prefix) && isJust source.header.headerCompletion) $
    refuse
      ( "stamped net specification " <> label source <> " at " <> scopeLabel prefix
          <> " cannot declare root completion"
      )
  effective1 <- foldM step effective0 (toList source.body.events)
  effective2 <- foldM placeOverride effective1 (Map.keys source.body.placeOverrides)
  foldM transitionOverride effective2 (Map.keys source.body.transitionOverrides)
  where
    b = source.body
    step effective = \case
      PlaceEvent at -> do
        let q = prefixed prefix at
            touched = touchPlace q effective
        Right $ case Map.lookup at b.placeColors of
          Just value -> touched {placeColors = Map.insert q value touched.placeColors}
          Nothing -> touched
      TransitionEvent at -> do
        let q = prefixed prefix at
            touched = touchTransition q effective
        Right $ case Map.lookup at b.transitionValues of
          Just value -> touched {transitionValues = Map.insert q value touched.transitionValues}
          Nothing -> touched
      ConnectionEvent connection -> do
        requireEndpoints connection
        let from = rebase connection.source
            to = rebase connection.target
            touched = touchRef to (touchRef from effective)
            added = Connection from to connection.inscription
        Right
          touched
            { connectionLog = touched.connectionLog Seq.|> added
            , events = touched.events Seq.|> ConnectionEvent added
            }
      StampEvent at -> case Map.lookup at b.stamps of
        Just child -> compose child (prefix ++ Schema.netPathSegments at) effective
        Nothing -> Right effective
    placeOverride effective at = do
      (_, _, value) <- lookupPlace b at
      Right effective {placeColors = Map.insert (prefixed prefix at) value effective.placeColors}
    transitionOverride effective at = do
      (_, _, value) <- lookupTransition b at
      Right effective {transitionValues = Map.insert (prefixed prefix at) value effective.transitionValues}
    rebase = \case
      PlaceRef at -> PlaceRef (prefixed prefix at)
      TransitionRef at -> TransitionRef (prefixed prefix at)
    touchRef = \case
      PlaceRef at -> touchPlace at
      TransitionRef at -> touchTransition at
    requireEndpoints connection =
      forM_ [connection.source, connection.target] $ \node -> do
        let (exists, kind) = case node of
              PlaceRef at -> (let (e, _, _) = sourcePlace b (Just at) in e, "place")
              TransitionRef at -> (let (e, _, _) = sourceTransition b (Just at) in e, "transition")
        unless exists $
          refuse
            ( "net specification " <> label source <> " at " <> scopeLabel prefix
                <> " connection references missing "
                <> kind
                <> " "
                <> netPathText (prefixed prefix (nodeRefPath node))
            )

canonicalNet :: NetSpec -> Either DslError Net
canonicalNet spec =
  fromKernel . mkNet $
    Schema.NetSpec
      { Schema.places = [Schema.Place at (join' (Map.lookup at b.placeColors)) | at <- toList b.placeOrder]
      , Schema.transitions =
          [ Schema.Transition at (lowerHandler <$> value.handlerValue) (map lowerGuard value.guardValues) value.timerValues
          | at <- toList b.transitionOrder
          , let value = Map.findWithDefault emptyBehavior at b.transitionValues
          ]
      , Schema.arcs =
          [ Schema.Arc
              (nodeRefPath c.source)
              (nodeRefPath c.target)
              c.inscription.arcMode
              c.inscription.arcWeight
              c.inscription.arcColor
              c.inscription.arcFilter
          | c <- toList b.connectionLog
          ]
      , Schema.completion = spec.header.headerCompletion
      , Schema.name = spec.header.headerName
      }
  where
    b = spec.body
    lowerHandler = \case
      HandlerNamed name -> HandlerSymbol name
      HandlerImplemented name _ _ -> HandlerAnonymous (displayed name)
    lowerGuard = \case
      GuardNamed name -> GuardSymbol name
      GuardInline expression -> GuardCel expression
      GuardImplemented name _ _ -> GuardAnonymous (displayed name)
    displayed name = AnonymousDeclaration (if T.null name then Nothing else Just name)

-- | Bind a build's implementations into an Instance configuration, keyed by
-- their exact canonical URIs (added to any implementations already there).
withImplementations :: BuiltNet -> InstanceConfig -> InstanceConfig
withImplementations built cfg =
  cfg
    { handlerImplementations =
        Map.union (Map.mapKeys Exact built.handlers) cfg.handlerImplementations
    , guardImplementations =
        Map.union (Map.mapKeys Exact built.guards) cfg.guardImplementations
    }
