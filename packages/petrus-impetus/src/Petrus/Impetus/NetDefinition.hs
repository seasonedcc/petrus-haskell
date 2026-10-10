-- | The versioned, language-neutral flat Net definition, schema version 3
-- (@petrus.impetus.net_definition@, @spec/net-definition-v3.md@).
--
-- A v3 document is the canonical cross-system spelling of one complete,
-- flattened 'Net': sorted places and transitions with full paths, arcs in
-- semantic order with dense positions, declarations as symbols, inline CEL
-- text, or anonymous URIs, and an integer time domain. Four operations keep
-- the document and the runtime net in lockstep:
--
-- * 'parseNetDefinition' strictly admits exact wire bytes;
-- * 'serializeNetDefinition' writes the one canonical byte spelling;
-- * 'compileNetDefinition' builds the runtime 'Net' through 'mkNet', the one
--   semantic boundary, and insists the document is already exactly what the
--   net projects to;
-- * 'projectNetDefinition' projects a runtime net back to its document.
--
-- For every projectable net @n@ and admitted document @d@ these satisfy the
-- spec's laws: @project (compile (project n)) == project n@,
-- @project (compile d) == d@, @parse (serialize d) == d@, and
-- @serialize (parse (serialize d)) == serialize d@.
--
-- Every refusal is the reference's exact message. The reference admits
-- documents through strict Pydantic models and CPython's @json@ scanner, and
-- its messages embed both libraries' diagnostics, so the admission pipeline
-- here mirrors the reference's phases in order: UTF-8 decoding, JSON
-- scanning with the number/constant/duplicate hooks, the Unicode
-- scalar-value pass, model validation ("Petrus.Impetus.Internal.Pydantic"),
-- and compilation. CEL guards, filters, and completions stay 'Cel' data:
-- nothing here evaluates CEL.
module Petrus.Impetus.NetDefinition
  ( -- * Documents
    NetDefinitionV3 (..)
  , NetDefinitionBody (..)
  , TimeDomain (..)
  , PlaceDefinition (..)
  , TransitionDefinition (..)
  , ArcDefinition (..)
  , PureExpression (..)
  , HandlerDefinition (..)
  , GuardDefinition (..)
  , SymbolBehavior (..)
  , CelBehavior (..)
  , AnonymousBehavior (..)
  , TimerDefinition (..)
    -- * Interoperable integers
  , jsonSafeIntegerMin
  , jsonSafeIntegerMax
    -- * Wire format
  , parseNetDefinition
  , parseNetDefinitionText
  , parseNetDefinitionJson
  , serializeNetDefinition
    -- * Runtime nets
  , compileNetDefinition
  , projectNetDefinition
    -- * Model values
  , netDefinitionToJson
  , netDefinitionFromJson
    -- * Internals shared with "Petrus.Impetus.NetDocument"
  , validateDefinitionModel
  , dumpDefinition
  , compileAdmitted
  , canonicalPathError
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity.Number (reprNumber)
import Petrus.Impetus.Internal.PyJson
import Petrus.Impetus.Internal.Pydantic
import Petrus.Impetus.Petrinet.Schema
import Petrus.Json (Json (..), defaultDumps, dumps, dumpsText, indented, safeIntegerMax, safeIntegerMin)

-- ---------------------------------------------------------------------------
-- Documents

-- | One canonical flat, complete, implementation-free Net definition. The
-- envelope's @format@ (@"petrus-net-definition"@) and @version@ (@3@) are
-- constants of the type: a value of this type can only be a v3 document.
newtype NetDefinitionV3 = NetDefinitionV3 {definition :: NetDefinitionBody}
  deriving stock (Eq, Show)

-- | The v3 time domain. Instants and durations are exact integers in the
-- interoperable range; it is the only domain v3 defines.
data TimeDomain = IntegerTimeDomain
  deriving stock (Eq, Show)

-- | The flattened net. Places and transitions are sorted by Unicode scalar
-- value with unique paths; arcs keep semantic order with dense positions.
data NetDefinitionBody = NetDefinitionBody
  { name :: Maybe Text
  , timeDomain :: TimeDomain
  , places :: [PlaceDefinition]
  , transitions :: [TransitionDefinition]
  , arcs :: [ArcDefinition]
  , completion :: Maybe PureExpression
  }
  deriving stock (Eq, Show)

-- | A place: its full dotted path and optional nominal color.
data PlaceDefinition = PlaceDefinition
  { path :: Text
  , color :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | A transition: full path, handler, ordered guards, ordered timers.
data TransitionDefinition = TransitionDefinition
  { path :: Text
  , handler :: Maybe HandlerDefinition
  , guards :: [GuardDefinition]
  , timers :: [TimerDefinition]
  }
  deriving stock (Eq, Show)

-- | An arc. The color is the /effective/ color (a typed place's color is
-- already compiled onto every incident arc), and the position is the arc's
-- index: parallel arcs stay distinct by order alone.
data ArcDefinition = ArcDefinition
  { position :: Integer
  , source :: Text
  , target :: Text
  , mode :: ArcMode
  , weight :: Integer
  , color :: Maybe Text
  , filter :: Maybe PureExpression
  }
  deriving stock (Eq, Show)

-- | A pure expression (an arc filter or the completion condition): a named
-- symbol or inline CEL text. Pure expressions carry no URI in v3.
data PureExpression
  = -- | @{"kind": "symbol", "name": ...}@
    SymbolExpression Text
  | -- | @{"kind": "cel", "expression": ...}@
    CelExpression Text
  deriving stock (Eq, Show)

-- | A named behavior with its derived canonical URI.
data SymbolBehavior = SymbolBehavior
  { name :: Text
  , uri :: Text
  }
  deriving stock (Eq, Show)

-- | An inline CEL behavior with its derived canonical URI.
data CelBehavior = CelBehavior
  { expression :: Text
  , uri :: Text
  }
  deriving stock (Eq, Show)

-- | An anonymous behavior: its identity is its owner/occurrence URI alone.
newtype AnonymousBehavior = AnonymousBehavior {uri :: Text}
  deriving stock (Eq, Show)

-- | A transition handler: named or anonymous (CEL cannot handle).
data HandlerDefinition
  = SymbolHandler SymbolBehavior
  | AnonymousHandler AnonymousBehavior
  deriving stock (Eq, Show)

-- | A transition guard: named, inline CEL, or anonymous.
data GuardDefinition
  = SymbolGuard SymbolBehavior
  | CelGuard CelBehavior
  | AnonymousGuard AnonymousBehavior
  deriving stock (Eq, Show)

-- | A transition timer in the integer time domain.
data TimerDefinition
  = -- | @{"kind": "delay", "duration": n}@
    DelayDefinition Integer
  | -- | @{"kind": "until", "instant": n}@
    UntilDefinition Integer
  deriving stock (Eq, Show)

-- | The inclusive RFC 8259 interoperable integer range every v3 number
-- token, and every variable integer field, must respect.
jsonSafeIntegerMin, jsonSafeIntegerMax :: Integer
jsonSafeIntegerMin = safeIntegerMin
jsonSafeIntegerMax = safeIntegerMax

-- ---------------------------------------------------------------------------
-- Parsing

-- | Which reference exception a refusal is: a protocol refusal raised as
-- @NetDefinitionError@ verbatim, or a 'ValueError' the parser wraps.
data Refusal = Protocol Text | Wrapped Text

invalid :: Text -> Text
invalid = ("invalid Petrus Net-definition v3: " <>)

-- | @parse_net_definition(payload: bytes)@: strictly parse and semantically
-- admit one canonical v3 document.
parseNetDefinition :: ByteString -> Either Text NetDefinitionV3
parseNetDefinition payload = either (Left . invalid) parseNetDefinitionText (decodeUtf8Python payload)

-- | @parse_net_definition(payload: str)@.
parseNetDefinitionText :: Text -> Either Text NetDefinitionV3
parseNetDefinitionText text = do
  raw <- case loads definitionHooks text of
    Right raw -> Right raw
    Left (DecodeError message position) -> Left (invalid (decodeErrorText text message position))
    Left (HookError (Protocol message)) -> Left message
    Left (HookError (Wrapped message)) -> Left (invalid message)
  case validateUnicode raw of
    Right () -> Right ()
    Left SurrogateFound -> Left "JSON strings must contain Unicode scalar values"
    Left RecursionExceeded -> Left (invalid "maximum recursion depth exceeded")
  document <- first (invalid . renderValidationError "NetDefinitionV3") (validateDefinitionModel (fromRaw raw))
  _ <- compileAdmitted document
  Right document

-- | @parse_net_definition(json.dumps(value))@: admit a JSON value exactly as
-- the reference admits CPython's default spelling of it (so a float, an
-- out-of-range integer, a non-finite number, or a repeated member is
-- refused just as its token would be).
parseNetDefinitionJson :: Json -> Either Text NetDefinitionV3
parseNetDefinitionJson value = case dumpsText defaultDumps value of
  Right text -> parseNetDefinitionText text
  Left _ -> Left (invalid "non-finite JSON number")

-- The reference's @json.loads@ hooks: integer tokens only, inside the
-- interoperable range; no non-finite constants; no repeated members.
definitionHooks :: Hooks Refusal
definitionHooks =
  Hooks
    { parseInt = \token -> case defaultInt token of
        Left message -> Left (Wrapped message)
        Right value
          | value < jsonSafeIntegerMin || value > jsonSafeIntegerMax ->
              Left
                ( Protocol
                    ( "JSON integer "
                        <> T.pack token
                        <> " is outside the inclusive interoperable range ["
                        <> tshow jsonSafeIntegerMin
                        <> ", "
                        <> tshow jsonSafeIntegerMax
                        <> "]"
                    )
                )
          | otherwise -> Right value
    , parseFloat = \token -> Left (Protocol ("v3 JSON numbers must use integer token spelling, got " <> T.pack token))
    , parseConstant = \spelling -> Left (Protocol ("non-finite JSON number " <> T.pack spelling))
    , objectPairs = either (Left . Protocol) Right . noDuplicates
    }

-- | @object_pairs_hook@'s duplicate refusal, at the first repeated member.
noDuplicates :: [(String, Raw)] -> Either Text ()
noDuplicates = go Set.empty
  where
    go _ [] = Right ()
    go seen ((key, _) : rest)
      | Set.member key seen = Left ("duplicate JSON member " <> pyStringRepr key)
      | otherwise = go (Set.insert key seen) rest

data UnicodeFailure = SurrogateFound | RecursionExceeded

-- | @_validate_unicode@ with CPython's frame accounting: the reference's
-- recursive walk runs under the default recursion limit of 1000 frames, so
-- adversarial nesting fails with a 'RecursionError' at exactly the depth the
-- reference's does (counting the walk as called from a top-level caller:
-- the module frame and the parser's frame sit below it).
validateUnicode :: Raw -> Either UnicodeFailure ()
validateUnicode = go 3
  where
    go :: Int -> Raw -> Either UnicodeFailure ()
    go depth value
      | depth > 1000 = Left RecursionExceeded
      | otherwise = case value of
          RStr s -> string depth s
          RList items -> mapM_ (go (depth + 1)) items
          RDict members -> forM_ members $ \(key, item) -> do
            go (depth + 1) (RStr key)
            go (depth + 1) item
          _ -> Right ()
    -- The check runs in a generator expression: one more frame.
    string depth s
      | depth + 1 > 1000 = Left RecursionExceeded
      | any isSurrogate s = Left SurrogateFound
      | otherwise = Right ()

tshow :: Show a => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Model validation

-- | @NetDefinitionV3.model_validate(value, strict=True)@: the rendered
-- 'ValidationError' on refusal.
netDefinitionFromJson :: Json -> Either Text NetDefinitionV3
netDefinitionFromJson = first (renderValidationError "NetDefinitionV3") . validateDefinitionModel . fromJson

-- | The strict v3 model over a Python value.
validateDefinitionModel :: PV -> Validated NetDefinitionV3
validateDefinitionModel =
  model "NetDefinitionV3" ["format", "version", "definition"] $ \members whole ->
    (\_ _ body -> NetDefinitionV3 body)
      <$> required members whole "format" (literalStr ["petrus-net-definition"])
      <*> required members whole "version" (literalInt 3)
      <*> required members whole "definition" validateBody

validateBody :: PV -> Validated NetDefinitionBody
validateBody input =
  afterModel canonicalCollections input $
    model
      "NetDefinitionBody"
      ["name", "time_domain", "places", "transitions", "arcs", "completion"]
      ( \members whole ->
          (\n _ ps ts arcs' c -> NetDefinitionBody n IntegerTimeDomain ps ts arcs' c)
            <$> required members whole "name" (checked netName' (optional strictStr))
            <*> required members whole "time_domain" (literalStr ["integer"])
            <*> required members whole "places" (tupleOf validatePlace)
            <*> required members whole "transitions" (tupleOf validateTransition)
            <*> required members whole "arcs" (tupleOf validateArc)
            <*> required members whole "completion" (optional validatePure)
      )
      input
  where
    netName' = \case
      Just "" -> Just "Net name must be non-empty or null"
      _ -> Nothing

-- | The body's model validator: canonical collection order and positions.
canonicalCollections :: NetDefinitionBody -> Maybe Text
canonicalCollections body
  | not (strictlySorted [p.path | p <- body.places]) =
      Just "places must have unique paths sorted by Unicode scalar value"
  | not (strictlySorted [t.path | t <- body.transitions]) =
      Just "transitions must have unique paths sorted by Unicode scalar value"
  | [a.position | a <- body.arcs] /= [0 .. toInteger (length body.arcs) - 1] =
      Just "arc positions must be the dense ordered range [0, len(arcs))"
  | otherwise = Nothing
  where
    -- 'Text' orders by UTF-8 bytes, which is Unicode scalar-value order.
    strictlySorted paths = paths == sort paths && Set.size (Set.fromList paths) == length paths

validatePlace :: PV -> Validated PlaceDefinition
validatePlace =
  model "PlaceDefinition" ["path", "color"] $ \members whole ->
    PlaceDefinition
      <$> required members whole "path" (checked canonicalPathError strictStr)
      <*> required members whole "color" (checked (nonEmptyOrNull "place color must be non-empty or null") (optional strictStr))

validateTransition :: PV -> Validated TransitionDefinition
validateTransition =
  model "TransitionDefinition" ["path", "handler", "guards", "timers"] $ \members whole ->
    TransitionDefinition
      <$> required members whole "path" (checked canonicalPathError strictStr)
      <*> required
        members
        whole
        "handler"
        ( optional
            ( tagged
                [ ("symbol", fmap SymbolHandler . validateSymbolBehavior)
                , ("anonymous", fmap AnonymousHandler . validateAnonymousBehavior)
                ]
            )
        )
      <*> required
        members
        whole
        "guards"
        ( tupleOf
            ( tagged
                [ ("symbol", fmap SymbolGuard . validateSymbolBehavior)
                , ("cel", fmap CelGuard . validateCelBehavior)
                , ("anonymous", fmap AnonymousGuard . validateAnonymousBehavior)
                ]
            )
        )
      <*> required members whole "timers" (tupleOf (tagged [("delay", validateDelay), ("until", validateUntil)]))

validateArc :: PV -> Validated ArcDefinition
validateArc =
  model "ArcDefinition" ["position", "source", "target", "mode", "weight", "color", "filter"] $ \members whole ->
    ArcDefinition
      <$> required members whole "position" (intRange 0 jsonSafeIntegerMax)
      <*> required members whole "source" (checked canonicalPathError strictStr)
      <*> required members whole "target" (checked canonicalPathError strictStr)
      <*> required members whole "mode" (fmap arcMode . literalStr ["consume", "read", "inhibit"])
      <*> required members whole "weight" (intRange 1 jsonSafeIntegerMax)
      <*> required members whole "color" (checked (nonEmptyOrNull "arc color must be non-empty or null") (optional strictStr))
      <*> required members whole "filter" (optional validatePure)
  where
    arcMode = \case
      "read" -> Read
      "inhibit" -> Inhibit
      _ -> Consume

validatePure :: PV -> Validated PureExpression
validatePure =
  tagged
    [ ("symbol", model "SymbolExpression" ["kind", "name"] $ \members whole ->
        (\_ n -> SymbolExpression n)
          <$> required members whole "kind" (literalStr ["symbol"])
          <*> required members whole "name" (checked symbolName strictStr))
    , ("cel", model "CelExpression" ["kind", "expression"] $ \members whole ->
        (\_ e -> CelExpression e)
          <$> required members whole "kind" (literalStr ["cel"])
          <*> required members whole "expression" (checked celText strictStr))
    ]

validateSymbolBehavior :: PV -> Validated SymbolBehavior
validateSymbolBehavior =
  model "SymbolBehavior" ["kind", "name", "uri"] $ \members whole ->
    (\_ n u -> SymbolBehavior n u)
      <$> required members whole "kind" (literalStr ["symbol"])
      <*> required members whole "name" (checked symbolName strictStr)
      <*> required members whole "uri" strictStr

validateCelBehavior :: PV -> Validated CelBehavior
validateCelBehavior =
  model "CelBehavior" ["kind", "expression", "uri"] $ \members whole ->
    (\_ e u -> CelBehavior e u)
      <$> required members whole "kind" (literalStr ["cel"])
      <*> required members whole "expression" (checked celText strictStr)
      <*> required members whole "uri" strictStr

validateAnonymousBehavior :: PV -> Validated AnonymousBehavior
validateAnonymousBehavior =
  model "AnonymousBehavior" ["kind", "uri"] $ \members whole ->
    (\_ u -> AnonymousBehavior u)
      <$> required members whole "kind" (literalStr ["anonymous"])
      <*> required members whole "uri" strictStr

validateDelay :: PV -> Validated TimerDefinition
validateDelay =
  model "DelayDefinition" ["kind", "duration"] $ \members whole ->
    (\_ d -> DelayDefinition d)
      <$> required members whole "kind" (literalStr ["delay"])
      <*> required members whole "duration" (intRange jsonSafeIntegerMin jsonSafeIntegerMax)

validateUntil :: PV -> Validated TimerDefinition
validateUntil =
  model "UntilDefinition" ["kind", "instant"] $ \members whole ->
    (\_ i -> UntilDefinition i)
      <$> required members whole "kind" (literalStr ["until"])
      <*> required members whole "instant" (intRange jsonSafeIntegerMin jsonSafeIntegerMax)

symbolName :: Text -> Maybe Text
symbolName value
  | T.null value || "$" `T.isPrefixOf` value = Just "symbol name must be non-empty and cannot start with '$'"
  | otherwise = Nothing

celText :: Text -> Maybe Text
celText value
  | T.null value = Just "CEL expression must be non-empty"
  | otherwise = Nothing

nonEmptyOrNull :: Text -> Maybe Text -> Maybe Text
nonEmptyOrNull message = \case
  Just "" -> Just message
  _ -> Nothing

-- | The @NetPath(value)@ refusal for a path field, if any. (The reference
-- also refuses a spelling @str(NetPath(value))@ would change, which no
-- string can produce.)
canonicalPathError :: Text -> Maybe Text
canonicalPathError value
  | T.null value = Just ("NetPath requires a non-empty dotted string or a NetPath, got " <> pyStrRepr value)
  | any T.null (T.splitOn "." value) = Just ("NetPath segments must be non-empty, got " <> pyStrRepr value)
  | otherwise = Nothing

-- ---------------------------------------------------------------------------
-- Model dumps

-- | @model_dump(mode="json")@: the document as the JSON value the writer
-- serializes, members in field order.
netDefinitionToJson :: NetDefinitionV3 -> Json
netDefinitionToJson = pvJson . dumpDefinition False

-- | @model_dump(mode=...)@: with @tuples@, the Python-mode dump (tuple
-- fields as tuples), which the reference revalidates.
dumpDefinition :: Bool -> NetDefinitionV3 -> PV
dumpDefinition tuples document =
  PDict
    [ ("format", PStr "petrus-net-definition")
    , ("version", PInt 3)
    , ( "definition"
      , PDict
          [ ("name", maybe PNone PStr body.name)
          , ("time_domain", PStr "integer")
          , ("places", seqOf [PDict [("path", PStr p.path), ("color", optStr p.color)] | p <- body.places])
          , ("transitions", seqOf (map transitionPV body.transitions))
          , ("arcs", seqOf (map arcPV body.arcs))
          , ("completion", maybe PNone purePV body.completion)
          ]
      )
    ]
  where
    body = document.definition
    seqOf = if tuples then PTuple else PList
    optStr = maybe PNone PStr
    transitionPV t =
      PDict
        [ ("path", PStr t.path)
        , ("handler", maybe PNone handlerPV t.handler)
        , ("guards", seqOf (map guardPV t.guards))
        , ("timers", seqOf (map timerPV t.timers))
        ]
    handlerPV = \case
      SymbolHandler b -> symbolPV b
      AnonymousHandler b -> anonymousPV b
    guardPV = \case
      SymbolGuard b -> symbolPV b
      CelGuard b -> PDict [("kind", PStr "cel"), ("expression", PStr b.expression), ("uri", PStr b.uri)]
      AnonymousGuard b -> anonymousPV b
    symbolPV b = PDict [("kind", PStr "symbol"), ("name", PStr b.name), ("uri", PStr b.uri)]
    anonymousPV (AnonymousBehavior u) = PDict [("kind", PStr "anonymous"), ("uri", PStr u)]
    timerPV = \case
      DelayDefinition d -> PDict [("kind", PStr "delay"), ("duration", PInt d)]
      UntilDefinition i -> PDict [("kind", PStr "until"), ("instant", PInt i)]
    arcPV a =
      PDict
        [ ("position", PInt a.position)
        , ("source", PStr a.source)
        , ("target", PStr a.target)
        , ("mode", PStr (arcModeText a.mode))
        , ("weight", PInt a.weight)
        , ("color", optStr a.color)
        , ("filter", maybe PNone purePV a.filter)
        ]
    purePV = \case
      SymbolExpression n -> PDict [("kind", PStr "symbol"), ("name", PStr n)]
      CelExpression e -> PDict [("kind", PStr "cel"), ("expression", PStr e)]

-- | The JSON value of a dumped model.
pvJson :: PV -> Json
pvJson = \case
  PNone -> Null
  PBool b -> Bool b
  PInt i -> Int i
  PFloat d -> Float d
  PStr s -> String s
  PList items -> Array (map pvJson items)
  PTuple items -> Array (map pvJson items)
  PDict members -> Object [(k, pvJson v) | (k, v) <- members]
  PInstance _ text -> String text

-- ---------------------------------------------------------------------------
-- Serialization

-- | @serialize_net_definition@: validate and write the canonical bytes
-- (@json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)@ plus
-- one final newline).
serializeNetDefinition :: NetDefinitionV3 -> Either Text ByteString
serializeNetDefinition document = do
  _ <- compileNetDefinition document
  case dumps indented (netDefinitionToJson document) of
    Right bytes -> Right (bytes <> "\n")
    Left _ -> Left "cannot serialize Petrus Net-definition v3: Out of range float values are not JSON compliant"

-- ---------------------------------------------------------------------------
-- Compilation and projection

-- | @compile_net_definition@: build the runtime 'Net' and require the
-- document to be exactly the net's projection.
--
-- The reference validates every model field when a document is
-- constructed, so it never compiles a document with, say, a weight of zero
-- or an unsorted place list. A Haskell record carries no such guarantee, so
-- compilation first revalidates the document's Python-mode dump and refuses
-- it as parsing would (@invalid Petrus Net-definition v3: ...@).
compileNetDefinition :: NetDefinitionV3 -> Either Text Net
compileNetDefinition document = do
  admitted <-
    first (invalid . renderValidationError "NetDefinitionV3") (validateDefinitionModel (dumpDefinition True document))
  compileAdmitted admitted

-- | Compile a document whose fields are already admitted.
compileAdmitted :: NetDefinitionV3 -> Either Text Net
compileAdmitted document = do
  net <- first ("invalid Petrus Net-definition v3 semantics: " <>) (buildSpec document.definition >>= mkNet)
  projected <- projectNetDefinition net
  unless (projected == document) $
    Left "Petrus Net-definition v3 must already be canonical and exactly projectable"
  Right net

buildSpec :: NetDefinitionBody -> Either Text NetSpec
buildSpec body = do
  ps <- forM body.places $ \p -> do
    at' <- netPath p.path
    Right Place {path = at', color = p.color}
  ts <- forM body.transitions $ \t -> do
    at' <- netPath t.path
    gs <- forM t.guards $ \case
      SymbolGuard b -> Right (GuardSymbol b.name)
      CelGuard b -> GuardCel <$> cel b.expression
      AnonymousGuard _ -> Right (GuardAnonymous anonymous)
    Right
      Transition
        { path = at'
        , handler = fmap handlerDeclaration t.handler
        , guards = gs
        , timers = map timer t.timers
        }
  arcs' <- forM body.arcs $ \a -> do
    from <- netPath a.source
    to <- netPath a.target
    f <- traverse pureFilter a.filter
    Right Arc {source = from, target = to, mode = a.mode, weight = fromInteger a.weight, color = a.color, filter = f}
  c <- traverse pureCompletion body.completion
  Right NetSpec {places = ps, transitions = ts, arcs = arcs', completion = c, name = body.name}
  where
    handlerDeclaration = \case
      SymbolHandler b -> HandlerSymbol b.name
      AnonymousHandler _ -> HandlerAnonymous anonymous
    timer = \case
      DelayDefinition d -> Delay (IntNumber d)
      UntilDefinition i -> Until (IntNumber i)
    pureFilter = \case
      SymbolExpression n -> Right (FilterSymbol n)
      CelExpression e -> FilterCel <$> cel e
    pureCompletion = \case
      SymbolExpression n -> Right (CompletionSymbol n)
      CelExpression e -> CompletionCel <$> cel e

-- | @project_net_definition@: the net's exact v3 document. Refuses a timer
-- or weight the integer time domain cannot hold exactly.
projectNetDefinition :: Net -> Either Text NetDefinitionV3
projectNetDefinition net = do
  let ps = [PlaceDefinition (netPathText at') p.color | (at', p) <- Map.toAscList (netPlaces net)]
  ts <- forM (Map.toAscList (netTransitions net)) $ \(at', t) -> do
    h <- forM t.handler $ \declaration -> case handlerUri net at' of
      Nothing -> Left "declared handler has no URI"
      Just u -> Right $ case declaration of
        HandlerSymbol symbol -> SymbolHandler (SymbolBehavior symbol (netUriText u))
        HandlerAnonymous _ -> AnonymousHandler (AnonymousBehavior (netUriText u))
    let gs =
          [ case guard of
              GuardSymbol symbol -> SymbolGuard (SymbolBehavior symbol (netUriText u))
              GuardCel expression -> CelGuard (CelBehavior (celExpression expression) (netUriText u))
              GuardAnonymous _ -> AnonymousGuard (AnonymousBehavior (netUriText u))
          | (guard, u) <- zip t.guards (guardUris net at')
          ]
    tms <- forM t.timers $ \case
      Delay duration -> DelayDefinition <$> integer duration "Delay duration"
      Until instant -> UntilDefinition <$> integer instant "Until instant"
    Right (TransitionDefinition (netPathText at') h gs tms)
  arcs' <- forM (zip [0 :: Integer ..] (netArcs net)) $ \(position', a) -> do
    p <- integer (IntNumber position') "arc position"
    w <- integer (IntNumber (toInteger a.weight)) "arc weight"
    Right
      ArcDefinition
        { position = p
        , source = netPathText a.source
        , target = netPathText a.target
        , mode = a.mode
        , weight = w
        , color = a.color
        , filter = fmap projectFilter a.filter
        }
  Right
    NetDefinitionV3
      { definition =
          NetDefinitionBody
            { name = netName net
            , timeDomain = IntegerTimeDomain
            , places = ps
            , transitions = ts
            , arcs = arcs'
            , completion = fmap projectCompletion (netCompletion net)
            }
      }
  where
    projectFilter = \case
      FilterSymbol symbol -> SymbolExpression symbol
      FilterCel expression -> CelExpression (celExpression expression)
    projectCompletion = \case
      CompletionSymbol symbol -> SymbolExpression symbol
      CompletionCel expression -> CelExpression (celExpression expression)

-- | @_integer@: an exact integer inside the interoperable range.
integer :: Number -> Text -> Either Text Integer
integer value subject = case value of
  FloatNumber _ ->
    Left ("v3 integer time domain requires " <> subject <> " to be an integer, got " <> reprNumber value)
  IntNumber i -> do
    when (i < jsonSafeIntegerMin || i > jsonSafeIntegerMax) $
      Left
        ( "v3 "
            <> subject
            <> " "
            <> tshow i
            <> " is outside the inclusive interoperable range ["
            <> tshow jsonSafeIntegerMin
            <> ", "
            <> tshow jsonSafeIntegerMax
            <> "]"
        )
    Right i
