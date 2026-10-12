{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE MultiWayIf #-}

-- | Variant-routing activity gates for the V5 actor-loop topology
-- (@net_v5/gating.py@).
--
-- Every world touch in V5 is a gate: an Activity that classifies its own
-- outcome into typed terminals (e.g. @RerunLanded | RerunMoved |
-- RerunFault@). The engine routes tokens by color and silently drops
-- tokens no arc admits, so gates split the responsibility honestly:
--
-- * 'encodeVariant' makes the concrete variant durable — the worker
--   boundary stamps @$variant@ into the JSON-faithful result, refusing
--   unlisted types loudly;
-- * the routing handler's @project@ reads the durable discriminator and
--   targets exactly the matching variant place, raising loudly on
--   anything unexpected.
--
-- The reference reads a gate's request type and result union off the
-- Activity function's annotations. A Haskell 'ActivityDefinition' carries
-- no annotations, so a 'GateDefinition' states them: the single
-- parameter's request 'Annotation' and the result union's member colors.
module Hamsterdan.Readiness.NetV5.Gating
  ( -- * The @$variant@ converter
    Variant (..)
  , variantOf
  , encodeVariant
  , variantPayloadConverter
  , decodeDataclass
    -- * Gate definitions
  , Annotation (..)
  , annotation
  , annotationColor
  , GateDefinition (..)
  , GateFlavor (..)
  , gateFlavor
  , durablePublicationGates
  , identifiedInlineGates
  , gatePolicy
    -- * Routing handlers
  , VariantRouting
  , variantRouting
  , routingHandler
  , prepareRouting
  , projectRouting
  , wireGates
    -- * Operation grammars
  , markerOperation
  , graphicOperation
  ) where

import Control.Monad (forM, unless, when)
import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable, cast)
import Hamsterdan.Contracts.Codec (Codec (..), Contract (..), colorOf, dump, validate)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding (PythonException, pyError, runtimeError, typeError, valueError)
import Hamsterdan.Readiness.NetV5.Py (pyRepr, typeName)
import Petrus.Activity
  ( ActivityDefinition (..)
  , ActivityFailure
  , ActivityFailureFields (..)
  , ActivityInvocation
  , ActivityInvocationFields (..)
  , ExecutionPolicy
  , activityInvocation
  , PayloadConverter
  , declarationName
  , defaultExecutionPolicy
  , failureFields
  , invocation
  , jsonPayloadConverter
  )
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult, derivedActivityHandler, handlerTokens)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Instance.FailureText (PyObject (..), pythonFailureText)
import Petrus.Impetus.Petrinet (Arc (..), Binding (..), NetPath, Token (..), netPathText)
import Petrus.Impetus.Petrinet.Schema (Net, handlerUri, inputs, netPath, outputs)
import Petrus.Json (Json (..))

-- ---------------------------------------------------------------------------
-- The $variant converter

-- | A concrete union member: its class name and its fields
-- (@type(value).__name__@ and @asdict(value)@).
data Variant = Variant
  { name :: Text
  , fields :: Json
  }
  deriving stock (Eq, Show)

-- | The variant of a strict workflow value.
variantOf :: forall a. (Contract a) => a -> Variant
variantOf value = Variant (colorOf value) (dump value)

-- | @VariantPayloadConverter.encode(value, A | B | ...)@: the value must be
-- exactly one of the union's members; its payload gains the @$variant@
-- discriminator first.
encodeVariant :: [Text] -> Variant -> Either PythonException Json
encodeVariant members value
  | value.name `notElem` members =
      Left
        ( valueError
            ( "union activity result must be exactly one of " <> pyRepr (Array (map String (sort members)))
                <> ", got "
                <> value.name
                <> " — subclasses and unlisted types have no routing arc"
            )
        )
  | otherwise = case value.fields of
      Object members' -> Right (Object (("$variant", String value.name) : members'))
      other -> Left (typeError ("asdict() should be called on dataclass instances, got " <> typeName other))

-- | The worker-boundary converter of a gate Activity. A Haskell
-- 'PayloadConverter' is untyped (JSON to JSON), so it is the JSON-faithful
-- converter; the union stamping is 'encodeVariant', which a gate's
-- implementation applies to its result.
variantPayloadConverter :: PayloadConverter
variantPayloadConverter = jsonPayloadConverter

-- | @DataclassPayloadConverter.decode(value, T)@: a mapping, filtered to
-- the dataclass's fields, constructed strictly.
decodeDataclass :: forall a. (Contract a) => Json -> Either PythonException a
decodeDataclass value = case value of
  Object members ->
    let accepted = (contract @a).codecFields
     in either (const (Left (pyError "ValidationError" []))) Right (validate @a (Object [m | m@(k, _) <- members, k `elem` accepted]))
  other ->
    Left
      ( valueError
          ("Activity payload for dataclass " <> (contract @a).codecName <> " must be a mapping, got " <> typeName other)
      )

-- ---------------------------------------------------------------------------
-- Gate definitions

-- | A parameter's annotation: a strict workflow type.
data Annotation where
  Annotation :: (Contract a, Typeable a) => Proxy a -> Annotation

annotation :: forall a. (Contract a, Typeable a) => Annotation
annotation = Annotation (Proxy @a)

-- | The annotation's class name (its token color).
annotationColor :: Annotation -> Text
annotationColor (Annotation (_ :: Proxy a)) = (contract @a).codecName

-- | A gate Activity with the signature the reference reads off its
-- function: the parameters' annotations and the result union's members.
data GateDefinition = GateDefinition
  { activity :: ActivityDefinition
  , parameters :: [(Text, Annotation)]
  , result :: [Text]
  }

-- | Which handler a gate binds (@wire_gates@).
data GateFlavor = DurablePublication | IdentifiedInline | PlainRouting
  deriving stock (Eq, Show)

durablePublicationGates :: [Text]
durablePublicationGates = ["reply_gate", "dash_gate", "announce_gate"]

identifiedInlineGates :: [Text]
identifiedInlineGates = ["review_agent", "publish_gate", "rerun_gate", "git_gate", "reminder_gate"]

gateFlavor :: Text -> GateFlavor
gateFlavor name
  | name `elem` durablePublicationGates = DurablePublication
  | name `elem` identifiedInlineGates = IdentifiedInline
  | otherwise = PlainRouting

-- | @ExecutionPolicy(attempts=1)@, the policy both identified flavors pin.
gatePolicy :: ExecutionPolicy
gatePolicy = defaultExecutionPolicy

-- ---------------------------------------------------------------------------
-- Routing handlers

-- | A constructed @VariantRoutingActivityHandler@ (or one of its two
-- subclasses, by 'GateFlavor').
data VariantRouting = VariantRouting
  { flavor :: GateFlavor
  , transition :: NetPath
  , definition :: GateDefinition
  , variants :: [Text]
  , parameter :: Text
  , request :: Annotation
  , source :: NetPath
  , targets :: [(Text, NetPath)]
  }

pyList :: [Text] -> Text
pyList = pyRepr . Array . map String

-- | Construct and validate a routing handler (@__post_init__@): one
-- parameter, exactly one input arc of its color, and exactly one output
-- arc per declared variant. Refusals are the reference's @ValueError@
-- messages.
variantRouting :: GateFlavor -> Net -> NetPath -> GateDefinition -> [Text] -> Either Text VariantRouting
variantRouting flavor net transition definition variants = do
  (parameter, request) <- case definition.parameters of
    [one] -> Right one
    [] -> Left "not enough values to unpack (expected 1, got 0)"
    many -> Left ("too many values to unpack (expected 1, got " <> T.pack (show (length many)) <> ")")
  let color = annotationColor request
      at = netPathText transition
      matching = [a | a <- inputs net transition, a.color == Just color]
  source <- case matching of
    [one] -> Right one.source
    _ ->
      Left
        ( "variant routing for " <> at <> ": parameter " <> pyRepr (String parameter) <> " (" <> color
            <> ") requires exactly one input arc, found "
            <> T.pack (show (length matching))
        )
  targets <-
    foldlM' [] (outputs net transition) $ \acc a -> do
      let arcColor = maybe Null String a.color
      variant <- case a.color of
        Just c | c `elem` variants -> Right c
        _ ->
          Left
            ( "variant routing for " <> at <> ": output arc to " <> netPathText a.target <> " carries "
                <> pyRepr arcColor
                <> ", not a declared variant of "
                <> pyList variants
            )
      when (variant `elem` map fst acc) $
        Left ("variant routing for " <> at <> ": variant " <> pyRepr arcColor <> " has two output arcs")
      Right (acc ++ [(variant, a.target)])
  let missing = [v | v <- variants, v `notElem` map fst targets]
  unless (null missing) $
    Left ("variant routing for " <> at <> ": no output arc for " <> pyList missing)
  Right VariantRouting {flavor, transition, definition, variants, parameter, request, source, targets}
  where
    foldlM' z xs f = go z xs
      where
        go acc [] = Right acc
        go acc (y : ys) = f acc y >>= \acc' -> go acc' ys

-- | The plain prepare: the single consumed token, as the parameter.
basePrepare :: VariantRouting -> Binding -> Either PythonException ActivityInvocation
basePrepare r b = case b.consumed of
  [(place, tokens)]
    | place /= r.source || length tokens /= 1 ->
        Left
          ( valueError
              ( "variant routing for " <> netPathText r.transition <> ": expected one token from "
                  <> netPathText r.source
                  <> ", got "
                  <> T.pack (show (length tokens))
                  <> " from "
                  <> netPathText place
              )
          )
    | otherwise -> case tokens of
        [tok] -> first valueError (invocation (declarationName r.definition.activity.declaration) (Object [(r.parameter, tok.payload)]))
        _ -> Left (valueError "unreachable")
  [] -> Left (valueError "not enough values to unpack (expected 1, got 0)")
  many -> Left (valueError ("too many values to unpack (expected 1, got " <> T.pack (show (length many)) <> ")"))

-- | A decoded request: one of the gate request types.
data Request where
  Request :: (Contract a, Typeable a) => a -> Request

decodeRequest :: VariantRouting -> ActivityInvocation -> Either PythonException Request
decodeRequest r inv = case r.request of
  Annotation (_ :: Proxy a) -> do
    value <- case inv.input of
      Object members -> maybe (Left (pyError "KeyError" [PyStr r.parameter])) Right (lookup r.parameter members)
      _ -> Left (typeError "invocation input is not a mapping")
    Request <$> decodeDataclass @a value

requestName :: Request -> Text
requestName (Request value) = colorOf value

as' :: forall b. (Typeable b) => Request -> Maybe b
as' (Request value) = cast value

-- | The prepare of the routing handler's flavor.
prepareRouting :: VariantRouting -> Binding -> Either PythonException ActivityInvocation
prepareRouting r b = do
  inv <- basePrepare r b
  case r.flavor of
    PlainRouting -> Right inv
    DurablePublication -> do
      req <- decodeRequest r inv
      operation <- durableOperation req
      identified operation inv
    IdentifiedInline -> do
      req <- decodeRequest r inv
      let name = declarationName r.definition.activity.declaration
      operation <- inlineOperation name req
      let grammar = if name `elem` ["publish_gate", "rerun_gate", "reminder_gate"] then markerOperation else graphicOperation
      unless (grammar operation) $
        Left (valueError ("V5 identified inline gate " <> pyRepr (String name) <> " operation identity is malformed"))
      identified operation inv
  where
    identified operation inv =
      first valueError (activityInvocation (ActivityInvocationFields inv.activity inv.input gatePolicy (Just operation) (Just operation)))

durableOperation :: Request -> Either PythonException Text
durableOperation req
  | Just (q :: ReplyReq) <- as' req = Right ("reply:" <> q.id)
  | Just (q :: DashReq) <- as' req = Right ("dash:" <> q.digest)
  | Just (q :: AnnounceReq) <- as' req = Right q.op
  | otherwise = Left (typeError ("Durable publication gate received unsupported request " <> requestName req))

inlineOperation :: Text -> Request -> Either PythonException Text
inlineOperation name req
  | name == "review_agent", Just (q :: RoundOpen) <- as' req = Right q.operation
  | name == "publish_gate", Just (q :: Publishable) <- as' req =
      if q.effect /= q.op
        then Left (valueError "V5 findings publication effect differs from its operation identity")
        else Right q.op
  | name == "rerun_gate", Just (q :: RerunReq) <- as' req = Right q.op
  | name == "reminder_gate", Just (q :: RemReq) <- as' req =
      if markerOperation q.timerId
        then Right ("reminder:" <> q.timerId)
        else Left (valueError "V5 identified inline gate 'reminder_gate' operation identity is malformed")
  | name == "git_gate", Just (q :: MutWork) <- as' req = Right q.opKey
  | otherwise =
      Left (typeError ("Identified inline gate " <> pyRepr (String name) <> " received unsupported request " <> requestName req))

-- | @project@: route the durable result to its variant's place.
projectRouting :: VariantRouting -> Binding -> Json -> Either PythonException HandlerResult
projectRouting r _ result = case result of
  Object members | Just variant <- lookup "$variant" members -> do
    let payload = Object [m | m@(k, _) <- members, k /= "$variant"]
    target <- case variant of
      String v | Just t <- lookup v r.targets -> Right (v, t)
      Array _ -> Left (typeError "cannot use 'list' as a dict key (unhashable type: 'list')")
      Object _ -> Left (typeError "cannot use 'dict' as a dict key (unhashable type: 'dict')")
      _ ->
        Left
          ( valueError
              ( "variant routing for " <> netPathText r.transition <> ": result variant " <> pyRepr variant
                  <> " is not one of "
                  <> pyList (map fst r.targets)
                  <> " — refusing the runtime's silent drop"
              )
          )
    let (color, place) = target
    Right (handlerTokens [(place, [Token (Just color) payload])])
  _ ->
    Left
      ( valueError
          ( "variant routing for " <> netPathText r.transition
              <> ": durable result lacks the '$variant' discriminator — was the activity declared with VariantPayloadConverter?"
          )
      )

-- | The durable flavor's @project_failure@: only an expired claim
-- (@DeadlineExceeded@) projects, as the request's blocked variant.
projectDurableFailure :: VariantRouting -> Binding -> ActivityFailure -> Either PythonException HandlerResult
projectDurableFailure r b failure = do
  let kind = (failureFields failure).failureKind
      name = declarationName r.definition.activity.declaration
  when (kind /= "DeadlineExceeded") $
    Left (runtimeError (kind <> " failure for durable V5 publication " <> pyRepr (String name) <> " cannot be projected"))
  inv <- basePrepare r b
  req <- decodeRequest r inv
  blocked <-
    if
      | Just (q :: ReplyReq) <- as' req -> Right (variantOf ReplyBlocked {id = q.id, text = q.text})
      | Just (q :: DashReq) <- as' req ->
          Right
            ( variantOf
                DashBlocked {entries = q.entries, digest = q.digest, desiredEntries = q.desiredEntries, desiredDigest = q.desiredDigest}
            )
      | Just (q :: AnnounceReq) <- as' req ->
          Right (variantOf ABlocked {incarnation = q.incarnation, head = q.head, base = q.base, policy = q.policy})
      | otherwise -> Left (typeError ("Durable publication gate received unsupported request " <> requestName req))
  encoded <- encodeVariant r.definition.result blocked
  projectRouting r b encoded

-- | The impure handler of a constructed routing gate; its exceptions
-- become the firing's failure text here.
routingHandler :: VariantRouting -> ActivityHandler
routingHandler r =
  ActivityHandler
    { prepare = first pythonFailureText . prepareRouting r
    , project = \b -> first pythonFailureText . projectRouting r b
    , projectFailure = case r.flavor of
        DurablePublication -> Just (\b -> first pythonFailureText . projectDurableFailure r b)
        _ -> Nothing
    }

-- | @wire_gates(built, gates, definitions, derived)@: bind each gate
-- transition's handler identity to its routing handler (and each derived
-- gate to the stock derived handler), over the built net's own handlers.
wireGates ::
  BuiltNet ->
  [(Text, (Text, [Text]))] ->
  Map Text GateDefinition ->
  [(Text, Text)] ->
  Either Text (Map ImplementationRef BoundHandler)
wireGates built gates definitions derived = do
  let own = Map.fromList [(Exact uri, h) | (uri, h) <- Map.toList built.handlers]
  routed <- forM gates $ \(path, (name, variants)) -> do
    transition <- netPath path
    uri <- maybe (Left ("transition " <> path <> " has no handler identity")) Right (handlerUri built.net transition)
    definition <- maybe (Left (pythonFailureText (pyError "KeyError" [PyStr name]))) Right (Map.lookup name definitions)
    r <- variantRouting (gateFlavor name) built.net transition definition variants
    Right (Exact uri, ActivityBound (routingHandler r))
  stock <- forM derived $ \(path, name) -> do
    transition <- netPath path
    uri <- maybe (Left ("transition " <> path <> " has no handler identity")) Right (handlerUri built.net transition)
    definition <- maybe (Left (pythonFailureText (pyError "KeyError" [PyStr name]))) Right (Map.lookup name definitions)
    resultColor <- case definition.result of
      [one] -> Right one
      _ -> Left ("derived gate " <> name <> " requires exactly one result color")
    h <-
      derivedActivityHandler
        built.net
        transition
        (declarationName definition.activity.declaration)
        [(p, annotationColor a) | (p, a) <- definition.parameters]
        resultColor
    Right (Exact uri, ActivityBound h)
  Right (Map.union (Map.fromList (routed ++ stock)) own)

-- ---------------------------------------------------------------------------
-- Operation grammars

-- | @[A-Za-z0-9][A-Za-z0-9._:-]{0,127}@, matched whole.
markerOperation :: Text -> Bool
markerOperation s = case T.uncons s of
  Just (c, rest) -> alnum c && T.length rest <= 127 && T.all (\x -> alnum x || x `elem` ("._:-" :: String)) rest
  Nothing -> False
  where
    alnum x = isAsciiLower x || isAsciiUpper x || isDigit x

-- | @[!-~]{1,1024}@, matched whole.
graphicOperation :: Text -> Bool
graphicOperation s = not (T.null s) && T.length s <= 1024 && T.all (\c -> ord c >= 0x21 && ord c <= 0x7e) s
