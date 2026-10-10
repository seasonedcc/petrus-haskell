-- | Portable Petrus Net documents, version 1, with optional view and
-- execution lineage (@petrus.impetus.net_document@,
-- @spec/net-document-v1.md@).
--
-- A Net document is the one portable Petrus file: exactly one canonical
-- Net-definition v3 envelope (the semantic authority), optionally a
-- /Layout/ (@view@: authored node positions) and a /Timeline/ (@lineage@: a
-- flat, forkable sequence of complete sparse markings). The same shape
-- covers a static design, a production observation, a simulation, and a
-- manually forked hypothesis.
--
-- * 'parseNetDocument' strictly admits exact wire bytes;
-- * 'serializeNetDocument' writes the canonical bytes, omitting absent
--   components;
-- * 'projectNetDocument' projects a runtime 'Net' plus optional positions and
--   lineage;
-- * 'definitionIdentity' is the Net identity: the lowercase SHA-256 of the
--   embedded definition's canonical bytes, which layout and lineage never
--   change.
--
-- Refusals are the reference's exact messages (see
-- "Petrus.Impetus.NetDefinition" for how the CPython and Pydantic
-- diagnostics they embed are reproduced).
module Petrus.Impetus.NetDocument
  ( -- * Documents
    NetDocumentV1 (..)
  , PortableViewV1 (..)
  , NodePosition (..)
  , ExecutionLineage (..)
  , LineageEntry (..)
  , Provenance (..)
  , provenanceText
  , PlaceMarking (..)
  , MarkingToken (..)
  , mkMarkingToken
  , mkLineageEntry
    -- * Wire format
  , parseNetDocument
  , parseNetDocumentText
  , parseNetDocumentJson
  , serializeNetDocument
    -- * Runtime nets and identity
  , projectNetDocument
  , definitionIdentity
    -- * Model values
  , netDocumentToJson
  , netDocumentFromJson
  ) where

import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Activity.Number (Number (..), reprNumber)
import Petrus.Impetus.Internal.PyJson
import Petrus.Impetus.Internal.Pydantic
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.Petrinet.Schema (Net)
import Petrus.Json (Json (..), defaultDumps, dumps, dumpsText, indented, safeIntegerMax, safeIntegerMin)

-- ---------------------------------------------------------------------------
-- Documents

-- | One Net definition with optional view data and execution lineage. The
-- envelope's @format@ (@"petrus-net-document"@) and @version@ (@1@) are
-- constants of the type. An absent component is 'Nothing' and is omitted
-- from the wire, never written as @null@.
data NetDocumentV1 = NetDocumentV1
  { definition :: NetDefinitionV3
  , view :: Maybe PortableViewV1
  , lineage :: Maybe ExecutionLineage
  }
  deriving stock (Eq, Show)

-- | A partial, portable set of authored node positions (view version 1),
-- unique and sorted by Unicode scalar value.
newtype PortableViewV1 = PortableViewV1 {nodes :: [NodePosition]}
  deriving stock (Eq, Show)

-- | One canonical node's presentation position: finite JSON numbers, which
-- may be fractional.
data NodePosition = NodePosition
  { node :: Text
  , x :: Number
  , y :: Number
  }
  deriving stock (Eq, Show)

-- | One flat, forkable sequence of complete sparse markings. @head@ names
-- the currently selected entry, not necessarily the last.
data ExecutionLineage = ExecutionLineage
  { head :: Integer
  , entries :: [LineageEntry]
  }
  deriving stock (Eq, Show)

-- | How an entry's marking was obtained.
data Provenance
  = -- | Projected from a real runtime History state.
    Observed
  | -- | Computed under Net and implementation semantics.
    Simulated
  | -- | Authored directly by a person.
    Manual
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The provenance's wire spelling.
provenanceText :: Provenance -> Text
provenanceText = \case
  Observed -> "observed"
  Simulated -> "simulated"
  Manual -> "manual"

-- | One dense, self-contained marking in a backward-linked lineage. The
-- metadata is non-authoritative strict JSON (an object's members in order).
data LineageEntry = LineageEntry
  { id :: Integer
  , parent :: Maybe Integer
  , provenance :: Provenance
  , marking :: [PlaceMarking]
  , metadata :: [(Text, Json)]
  }
  deriving stock (Show)

-- | Python model equality: metadata compares as a mapping.
instance Eq LineageEntry where
  a == b =
    a.id == b.id
      && a.parent == b.parent
      && a.provenance == b.provenance
      && a.marking == b.marking
      && Object a.metadata == Object b.metadata

-- | The nonempty token queue one place holds.
data PlaceMarking = PlaceMarking
  { place :: Text
  , tokens :: [MarkingToken]
  }
  deriving stock (Eq, Show)

-- | One token of a portable sparse marking: its color and strict-JSON data
-- (the wire's @data@ member).
data MarkingToken = MarkingToken
  { color :: Maybe Text
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | @MarkingToken(color=..., data=...)@: the token data must already be
-- strict JSON (finite numbers, integral numbers in the safe range).
mkMarkingToken :: Maybe Text -> Json -> Either Text MarkingToken
mkMarkingToken c value =
  first (renderValidationError "MarkingToken") $
    validateToken (PDict [("color", maybe PNone PStr c), ("data", fromJson value)])

-- | @LineageEntry(id=..., parent=..., provenance=..., marking=...,
-- metadata=...)@: every field validated as the reference's model does.
mkLineageEntry :: Integer -> Maybe Integer -> Provenance -> [PlaceMarking] -> [(Text, Json)] -> Either Text LineageEntry
mkLineageEntry i p prov m meta =
  first (renderValidationError "LineageEntry") $
    validateEntry (dumpEntry True (LineageEntry i p prov m meta))

-- ---------------------------------------------------------------------------
-- Parsing

data Refusal = Protocol Text | Wrapped Text

invalid :: Text -> Text
invalid = ("invalid Petrus Net document v1: " <>)

-- | @parse_net_document(payload: bytes)@: strictly parse and semantically
-- admit one portable Net document.
parseNetDocument :: ByteString -> Either Text NetDocumentV1
parseNetDocument payload = either (Left . invalid) parseNetDocumentText (decodeUtf8Python payload)

-- | @parse_net_document(payload: str)@.
parseNetDocumentText :: Text -> Either Text NetDocumentV1
parseNetDocumentText text = do
  raw <- case loads documentHooks text of
    Right raw -> Right raw
    Left (DecodeError message position) -> Left (invalid (decodeErrorText text message position))
    Left (HookError (Protocol message)) -> Left message
    Left (HookError (Wrapped message)) -> Left (invalid message)
  first invalid (strictJson (Just 3) (rawNode raw))
  case raw of
    RDict members -> forM_ ["view", "lineage"] $ \component ->
      case lookup (T.unpack component) members of
        Just RNull -> Left (component <> " must be absent or an object, not null")
        _ -> Right ()
    _ -> Right ()
  document <- first (invalid . renderValidationError "NetDocumentV1") (validateDocumentModel (fromRaw raw))
  first (refusal invalid) (validateDocument document)
  Right document

-- | @parse_net_document(json.dumps(value))@.
parseNetDocumentJson :: Json -> Either Text NetDocumentV1
parseNetDocumentJson value = case dumpsText defaultDumps value of
  Right text -> parseNetDocumentText text
  Left _ -> Left (invalid "non-finite JSON number")

-- The reference's hooks: no non-finite constants, no repeated members.
-- Numbers keep CPython's defaults (strict JSON admission runs afterwards).
documentHooks :: Hooks Refusal
documentHooks =
  Hooks
    { parseInt = first Wrapped . defaultInt
    , parseFloat = Right . defaultFloat
    , parseConstant = \spelling -> Left (Protocol ("non-finite JSON number " <> T.pack spelling))
    , objectPairs = noDuplicates
    }
  where
    noDuplicates = go Set.empty
    go _ [] = Right ()
    go seen ((key, _) : rest)
      | Set.member key seen = Left (Protocol ("duplicate JSON member " <> pyStringRepr key))
      | otherwise = go (Set.insert key seen) rest

-- ---------------------------------------------------------------------------
-- Strict JSON

-- | A JSON-shaped value as @_strict_json@ inspects it.
data Node
  = NNull
  | NBool
  | NInt Integer
  | NFloat Double
  | -- | Whether the string holds a lone surrogate.
    NStr Bool
  | NList [Node]
  | NDict [(Bool, Node)]
  | -- | Any other Python type, by name.
    NOther Text

rawNode :: Raw -> Node
rawNode = \case
  RNull -> NNull
  RBool _ -> NBool
  RInt i -> NInt i
  RFloat d -> NFloat d
  RStr s -> NStr (any isSurrogate s)
  RList items -> NList (map rawNode items)
  RDict members -> NDict [(any isSurrogate k, rawNode v) | (k, v) <- members]

pvNode :: PV -> Node
pvNode = \case
  PNone -> NNull
  PBool _ -> NBool
  PInt i -> NInt i
  PFloat d -> NFloat d
  PStr _ -> NStr False
  PList items -> NList (map pvNode items)
  PTuple _ -> NOther "tuple"
  PDict members -> NDict [(False, pvNode v) | (_, v) <- members]
  PInstance name _ -> NOther name

-- | @_strict_json@: strings are Unicode scalar values, numbers are finite,
-- and integral numbers are JavaScript-safe. Given the root call's frame
-- depth, the walk also fails exactly where the reference's recursive walk
-- exceeds CPython's default recursion limit (each container costs two
-- frames, each string or number check one more).
strictJson :: Maybe Int -> Node -> Either Text ()
strictJson root = go root
  where
    deeper = fmap (+ 1)
    enter = \case
      Just depth | depth > 1000 -> Left "maximum recursion depth exceeded"
      _ -> Right ()
    go depth node = do
      enter depth
      case node of
        NNull -> Right ()
        NBool -> Right ()
        NInt i -> enter (deeper depth) >> safe (toRational i)
        NFloat d -> do
          enter (deeper depth)
          when (isNaN d || isInfinite d) (Left "JSON numbers must be finite")
          let r = toRational d
          when (fromInteger (truncate r) == r) (safe r)
        NStr bad -> do
          enter (deeper depth)
          when bad (Left "JSON strings must contain Unicode scalar values")
        NList items -> do
          enter (deeper depth)
          mapM_ (go (deeper (deeper depth))) items
        NDict members -> do
          enter (deeper depth)
          forM_ members $ \(badKey, item) -> do
            go (deeper (deeper depth)) (NStr badKey)
            go (deeper (deeper depth)) item
        NOther name -> Left ("value of type " <> name <> " is not strict JSON")
    safe r =
      unless (r >= fromInteger safeIntegerMin && r <= fromInteger safeIntegerMax) $
        Left "integral JSON numbers must be within the JavaScript safe-integer range"

-- ---------------------------------------------------------------------------
-- Model validation

-- | @NetDocumentV1.model_validate(value, strict=True)@.
netDocumentFromJson :: Json -> Either Text NetDocumentV1
netDocumentFromJson = first (renderValidationError "NetDocumentV1") . validateDocumentModel . fromJson

validateDocumentModel :: PV -> Validated NetDocumentV1
validateDocumentModel =
  model "NetDocumentV1" ["format", "version", "definition", "view", "lineage"] $ \members whole ->
    (\_ _ d v l -> NetDocumentV1 d v l)
      <$> required members whole "format" (literalStr ["petrus-net-document"])
      <*> required members whole "version" versionOne
      <*> required members whole "definition" validateDefinitionModel
      <*> defaulted members "view" Nothing (optional validateView)
      <*> defaulted members "lineage" Nothing (optional validateLineage)

-- | @_version_one@: exactly the integer @1@ (never @True@ or @1.0@).
versionOne :: PV -> Validated Integer
versionOne = \case
  PInt 1 -> Right 1
  other -> Left [valueError "version must be the integer 1" other]

validateView :: PV -> Validated PortableViewV1
validateView input =
  afterModel canonicalNodes input $
    model
      "PortableViewV1"
      ["version", "nodes"]
      ( \members whole ->
          (\_ ns -> PortableViewV1 ns)
            <$> required members whole "version" versionOne
            <*> required members whole "nodes" (tupleOf validateNode)
      )
      input

-- | The view's model validator.
canonicalNodes :: PortableViewV1 -> Maybe Text
canonicalNodes v
  | Set.size (Set.fromList paths) /= length paths = Just "view node paths must be unique"
  | paths /= sort paths = Just "view nodes must be sorted by Unicode scalar value"
  | otherwise = Nothing
  where
    paths = [n.node | n <- v.nodes]

validateNode :: PV -> Validated NodePosition
validateNode =
  model "NodePosition" ["node", "x", "y"] $ \members whole ->
    NodePosition
      <$> required members whole "node" (checked canonicalPathError strictStr)
      <*> required members whole "x" coordinate
      <*> required members whole "y" coordinate

-- | @_coordinate@: a finite JSON number (an integer too large for a double
-- is not finite).
coordinate :: PV -> Validated Number
coordinate = \case
  value@(PInt i)
    | finite (fromRational (toRational i)) -> Right (IntNumber i)
    | otherwise -> notFinite value
  value@(PFloat d)
    | finite d -> Right (FloatNumber d)
    | otherwise -> notFinite value
  other -> Left [valueError "coordinate must be a JSON number" other]
  where
    finite :: Double -> Bool
    finite d = not (isNaN d || isInfinite d)
    notFinite value = Left [valueError "coordinate must be a finite interoperable JSON number" value]

validateLineage :: PV -> Validated ExecutionLineage
validateLineage =
  model "ExecutionLineage" ["head", "entries"] $ \members whole ->
    ExecutionLineage
      <$> required members whole "head" (intRange 0 safeIntegerMax)
      <*> required members whole "entries" (tupleOf validateEntry)

validateEntry :: PV -> Validated LineageEntry
validateEntry =
  model "LineageEntry" ["id", "parent", "provenance", "marking", "metadata"] $ \members whole ->
    LineageEntry
      <$> required members whole "id" (intRange 0 safeIntegerMax)
      <*> required members whole "parent" (optional (intRange 0 safeIntegerMax))
      <*> required members whole "provenance" (fmap toProvenance . literalStr ["observed", "simulated", "manual"])
      <*> required members whole "marking" (tupleOf validatePlaceMarking)
      <*> required members whole "metadata" validateMetadata
  where
    toProvenance = \case
      "observed" -> Observed
      "simulated" -> Simulated
      _ -> Manual

-- | @_metadata@: an object of strict JSON.
validateMetadata :: PV -> Validated [(Text, Json)]
validateMetadata = \case
  value@(PDict members) -> case strictJson Nothing (pvNode value) of
    Left message -> Left [valueError message value]
    Right () -> Right [(k, pvJson v) | (k, v) <- members]
  other -> Left [valueError "metadata must be an object" other]

validatePlaceMarking :: PV -> Validated PlaceMarking
validatePlaceMarking =
  model "PlaceMarking" ["place", "tokens"] $ \members whole ->
    PlaceMarking
      <$> required members whole "place" (checked canonicalPathError strictStr)
      <*> required members whole "tokens" (tupleOf validateToken)

validateToken :: PV -> Validated MarkingToken
validateToken =
  model "MarkingToken" ["color", "data"] $ \members whole ->
    MarkingToken
      <$> required members whole "color" (optional strictStr)
      <*> required members whole "data" strictData
  where
    strictData value = case strictJson Nothing (pvNode value) of
      Left message -> Left [valueError message value]
      Right () -> Right (pvJson value)

-- ---------------------------------------------------------------------------
-- Semantic admission

-- | A refusal raised as @NetDocumentError@ verbatim, or a 'ValueError'
-- (a Net-definition refusal) the caller wraps with its own context.
data DocumentRefusal = DocumentRefusal Text | ValueRefusal Text

refusal :: (Text -> Text) -> DocumentRefusal -> Text
refusal wrap = \case
  DocumentRefusal message -> message
  ValueRefusal message -> wrap message

-- | @_validate_document@: the definition compiles, the view names only
-- definition nodes, and the lineage is a dense backward-linked sequence of
-- valid sparse markings.
validateDocument :: NetDocumentV1 -> Either DocumentRefusal ()
validateDocument document = do
  _ <- first ValueRefusal (compileAdmitted document.definition)
  let body = document.definition.definition
  forM_ document.view $ \v -> do
    let known = Set.fromList ([p.path | p <- body.places] ++ [t.path | t <- body.transitions])
    case [n.node | n <- v.nodes, not (Set.member n.node known)] of
      stranger : _ -> Left (DocumentRefusal ("view contains foreign definition node " <> pyStrRepr stranger))
      [] -> Right ()
  forM_ document.lineage $ \l -> first DocumentRefusal (validateLineageSemantics body l)

validateLineageSemantics :: NetDefinitionBody -> ExecutionLineage -> Either Text ()
validateLineageSemantics body l = do
  when (null l.entries) $ Left "lineage.entries must be nonempty"
  when (l.head >= toInteger (length l.entries)) $ Left "lineage.head must name an existing entry"
  forM_ (zip [0 :: Integer ..] l.entries) $ \(index, entry) -> do
    let at' = "lineage.entries[" <> tshow index <> "]"
    when (entry.id /= index) $ Left (at' <> ".id must equal its array index")
    if index == 0
      then when (isJust entry.parent) $ Left "lineage.entries[0] must be the sole root with parent null"
      else case entry.parent of
        Just p | p < index -> Right ()
        _ -> Left (at' <> ".parent must be a smaller entry id")
    validateMarking body entry.marking (at' <> ".marking")

-- | @_marking@: a sparse marking over the definition's places.
validateMarking :: NetDefinitionBody -> [PlaceMarking] -> Text -> Either Text ()
validateMarking body value at' = do
  let placeColors = Map.fromList [(p.path, p.color) | p <- body.places]
      names = [entry.place | entry <- value]
  when (names /= sort names) $ Left (at' <> " places must be sorted by Unicode scalar value")
  when (Set.size (Set.fromList names) /= length names) $ Left (at' <> " places must be unique")
  forM_ (zip [0 :: Int ..] value) $ \(index, entry) -> do
    let itemAt = at' <> "[" <> tshow index <> "]"
    placeColor <- case Map.lookup entry.place placeColors of
      Nothing -> Left (itemAt <> ".place names foreign place " <> pyStrRepr entry.place)
      Just c -> Right c
    when (null entry.tokens) $ Left (itemAt <> ".tokens must be nonempty in sparse marking form")
    forM_ (zip [0 :: Int ..] entry.tokens) $ \(tokenIndex, token) -> do
      let tokenAt = itemAt <> ".tokens[" <> tshow tokenIndex <> "]"
      when (token.color == Just "") $ Left (tokenAt <> ".color must be a nonempty string or null")
      case placeColor of
        Just expected
          | token.color /= Just expected ->
              Left
                ( tokenAt
                    <> ".color "
                    <> maybe "None" pyStrRepr token.color
                    <> " does not match place "
                    <> pyStrRepr entry.place
                    <> " color "
                    <> pyStrRepr expected
                )
        _ -> Right ()

tshow :: Show a => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Model dumps and serialization

-- | @model_dump(mode=...)@; with @tuples@, the Python-mode dump. Absent
-- components are @None@ here, as in the reference's dump.
dumpDocument :: Bool -> NetDocumentV1 -> PV
dumpDocument tuples document =
  PDict
    [ ("format", PStr "petrus-net-document")
    , ("version", PInt 1)
    , ("definition", dumpDefinition tuples document.definition)
    , ("view", maybe PNone viewPV document.view)
    , ("lineage", maybe PNone (dumpLineage tuples) document.lineage)
    ]
  where
    viewPV v =
      PDict
        [ ("version", PInt 1)
        , ("nodes", (if tuples then PTuple else PList) [PDict [("node", PStr n.node), ("x", numberPV n.x), ("y", numberPV n.y)] | n <- v.nodes])
        ]

dumpLineage :: Bool -> ExecutionLineage -> PV
dumpLineage tuples l =
  PDict [("head", PInt l.head), ("entries", (if tuples then PTuple else PList) (map (dumpEntry tuples) l.entries))]

dumpEntry :: Bool -> LineageEntry -> PV
dumpEntry tuples entry =
  PDict
    [ ("id", PInt entry.id)
    , ("parent", maybe PNone PInt entry.parent)
    , ("provenance", PStr (provenanceText entry.provenance))
    , ("marking", seqOf [PDict [("place", PStr m.place), ("tokens", seqOf (map tokenPV m.tokens))] | m <- entry.marking])
    , ("metadata", PDict [(k, fromJson v) | (k, v) <- entry.metadata])
    ]
  where
    seqOf = if tuples then PTuple else PList
    tokenPV t = PDict [("color", maybe PNone PStr t.color), ("data", fromJson t.payload)]

numberPV :: Number -> PV
numberPV = \case
  IntNumber i -> PInt i
  FloatNumber d -> PFloat d

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

-- | The document's JSON value exactly as the writer serializes it: absent
-- components are omitted rather than @null@.
netDocumentToJson :: NetDocumentV1 -> Json
netDocumentToJson = pvJson . writerValue

writerValue :: NetDocumentV1 -> PV
writerValue document = case dumpDocument False document of
  PDict members -> PDict [(k, v) | (k, v) <- members, not (absent k)]
  other -> other
  where
    absent k = (k == "view" && not (isJust document.view)) || (k == "lineage" && not (isJust document.lineage))

-- | @serialize_net_document@: revalidate, admit, and write the canonical
-- bytes (two-space indentation, one final newline).
serializeNetDocument :: NetDocumentV1 -> Either Text ByteString
serializeNetDocument document = do
  validated <- first (cannot . renderValidationError "NetDocumentV1") (validateDocumentModel (dumpDocument True document))
  first (refusal cannot) (validateDocument validated)
  let value = writerValue validated
  first cannot (strictJson (Just 3) (pvNode value))
  case dumps indented (pvJson value) of
    Right bytes -> Right (bytes <> "\n")
    Left _ -> Left (cannot "Out of range float values are not JSON compliant")
  where
    cannot = ("cannot serialize Petrus Net document v1: " <>)

-- ---------------------------------------------------------------------------
-- Projection and identity

-- | @project_net_document(net, positions, lineage=...)@: project a runtime
-- net with optional node positions (keyed by dotted path; any order) and an
-- optional lineage.
--
-- The reference validates a lineage when it is constructed; a Haskell
-- record is unchecked, so the lineage is validated here first, as an
-- @ExecutionLineage@ model.
projectNetDocument :: Net -> Maybe [(Text, (Number, Number))] -> Maybe ExecutionLineage -> Either Text NetDocumentV1
projectNetDocument net positions lineage' = do
  checkedLineage <- forM lineage' $ \l ->
    first (cannot . renderValidationError "ExecutionLineage") (validateLineage (dumpLineage True l))
  view' <- forM positions $ \ps -> do
    ns <- forM (sortOn fst ps) $ \(n, (px, py)) ->
      first (cannot . renderValidationError "NodePosition") $
        validateNode (PDict [("node", PStr n), ("x", numberPV px), ("y", numberPV py)])
    let input' = PDict [("version", PInt 1), ("nodes", PTuple (map instancePV ns))]
    first (cannot . renderValidationError "PortableViewV1") (afterModel canonicalNodes input' (Right (PortableViewV1 ns)))
  definition' <- first cannot (projectNetDefinition net)
  let document = NetDocumentV1 definition' view' checkedLineage
  first (refusal cannot) (validateDocument document)
  Right document
  where
    cannot = ("cannot project Petrus Net document v1: " <>)
    instancePV n =
      PInstance
        "NodePosition"
        ("NodePosition(node=" <> pyStrRepr n.node <> ", x=" <> reprNumber n.x <> ", y=" <> reprNumber n.y <> ")")

-- | @definition_identity@: the lowercase SHA-256 of the embedded
-- definition's canonical bytes. View and lineage never enter it.
definitionIdentity :: NetDocumentV1 -> Either Text Text
definitionIdentity document = hexDigest . SHA256.hash <$> serializeNetDefinition document.definition
  where
    hexDigest = T.concat . map byte . BS.unpack
    byte w = let digits = showHex w "" in T.pack (replicate (2 - length digits) '0' ++ digits)
