{-# OPTIONS_GHC -Wno-orphans #-}

-- | Net structure: the declarative, language-neutral description of a net
-- (@petrus.impetus.petrinet.schema@).
--
-- * 'NetPath' — an immutable node address (a dotted path; a flat net uses a
--   single segment).
-- * 'NetUri' — the canonical ASCII address of one addressable part of a
--   flattened net (a declaration, an arc occurrence, an arc filter).
-- * 'ArcMode' — how an input arc participates in enablement.
-- * 'Cel' — an inline CEL expression, kept as data: the expression compiles at
--   the instance level through the CEL seam ("Petrus.Impetus.Binding").
-- * the declaration types — one per slot, so a slot can only hold the
--   encodings the reference admits there.
-- * 'Arc', 'Place', 'Transition' — the parts.
-- * 'Net' — the flattened net, built and validated once by 'mkNet', then
--   immutable, with its derived input/output indices and canonical URIs.
--
-- The reference validates each part in its own constructor and the whole in
-- @Net.__init__@. Here the parts are plain values and 'mkNet' is the single
-- construction-validation boundary: it runs every rule the reference runs,
-- with the reference's messages, so an invalid 'Net' cannot exist.
module Petrus.Impetus.Petrinet.Schema
  ( -- * Paths
    NetPath
  , netPath
  , netPathText
  , netPathSegments
  , lastSegment
  , firstSegment
  , segmentCount
    -- * URIs
  , NetUri
  , netUri
  , netUriText
  , UriOwner (..)
  , declarationUri
  , arcUri
  , arcFilterUri
    -- * Inscriptions and declarations
  , Color
  , Instant
  , Duration
  , Number (..)
  , ArcMode (..)
  , arcModeText
  , Cel
  , cel
  , unsafeCel
  , celExpression
  , AnonymousDeclaration (..)
  , anonymous
  , anonymousNamed
  , FilterDeclaration (..)
  , GuardDeclaration (..)
  , HandlerDeclaration (..)
  , CompletionDeclaration (..)
  , Timer (..)
    -- * Parts
  , Arc (..)
  , arc
  , withArcColor
  , arcAdmits
  , isConsume
  , isRead
  , isInhibit
  , Place (..)
  , place
  , coloredPlace
  , Transition (..)
  , transition
    -- * Nets
  , NetSpec (..)
  , netSpec
  , Net
  , mkNet
    -- * Construction steps
    -- | The checks 'mkNet' runs, one part at a time, for callers that build
    -- a net in the reference's lazy order (the Net-definition compiler).
  , validatePlace
  , validateTransition
  , checkDistinctNodes
  , resolveColor
  , netName
  , netCompletion
  , netPlaces
  , netPlaceOrder
  , netTransitions
  , netTransitionOrder
  , netArcs
  , lookupPlace
  , lookupTransition
  , hasPlace
  , hasTransition
  , inputs
  , inputPositions
  , outputs
  , isSource
  , sourceTransitions
  , arcUris
  , arcUriAt
  , filterUris
  , handlerUri
  , guardUris
  , handlerDeclarations
  , guardDeclarations
  , filterDeclarations
    -- * Diagnostics spellings
  , reprArc
  , reprGuardDeclaration
  , reprTimer
  , reprFilterDeclaration
  , reprCompletionDeclaration
  ) where

import Control.DeepSeq (NFData)
import Control.Monad (forM_, unless, when)
import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.Char (chr, isAlphaNum, isAscii, isHexDigit, isUpper, ord)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity.Number (Number (..))
import Petrus.Impetus.Internal.Repr

-- ---------------------------------------------------------------------------
-- Paths

-- | An immutable node address: a non-empty dotted string whose segments are
-- non-empty. The reference's @NetPath@ is a tuple of segments; because no
-- segment can contain the separator, the canonical dotted spelling identifies
-- the tuple exactly, so the path is stored as that spelling. 'Ord' is the
-- spelling's code-point order — the reference's @sorted(..., key=str)@.
newtype NetPath = NetPath Text
  deriving stock (Eq, Ord)
  deriving newtype (NFData)

instance Show NetPath where
  show (NetPath text) = T.unpack ("NetPath(" <> pyStr text <> ")")

-- | Literal paths for tests and examples; an invalid literal is a programming
-- error and fails loudly, exactly as @NetPath("")@ raises.
instance IsString NetPath where
  fromString value = either (error . T.unpack) id (netPath (T.pack value))

-- | Parse a dotted path.
netPath :: Text -> Either Text NetPath
netPath value
  | T.null value =
      Left ("NetPath requires a non-empty dotted string or a NetPath, got " <> pyStr value)
  | any T.null (T.splitOn "." value) =
      Left ("NetPath segments must be non-empty, got " <> pyStr value)
  | otherwise = Right (NetPath value)

-- | The canonical dotted spelling (@str(path)@).
netPathText :: NetPath -> Text
netPathText (NetPath text) = text

-- | The path's segments (@tuple(path)@).
netPathSegments :: NetPath -> [Text]
netPathSegments (NetPath text) = T.splitOn "." text

-- | The last segment (@path[-1]@), a node's local name.
lastSegment :: NetPath -> Text
lastSegment (NetPath text) = snd (T.breakOnEnd "." text)

-- | The first segment (@path[0]@), a node's outermost scope.
firstSegment :: NetPath -> Text
firstSegment (NetPath text) = fst (T.breakOn "." text)

-- | The number of segments (@len(path)@).
segmentCount :: NetPath -> Int
segmentCount (NetPath text) = T.count "." text + 1

-- ---------------------------------------------------------------------------
-- URIs

-- | Canonical ASCII address of one addressable part of a flattened net.
newtype NetUri = NetUri Text
  deriving stock (Eq, Ord)
  deriving newtype (NFData)

instance Show NetUri where
  show (NetUri text) = T.unpack ("NetUri(" <> pyStr text <> ")")

-- | The canonical spelling.
netUriText :: NetUri -> Text
netUriText (NetUri text) = text

-- | Admit a canonical URI spelling (@NetUri(value)@).
netUri :: Text -> Either Text NetUri
netUri value
  | T.null value || not (T.all isAscii value) =
      Left ("NetUri requires a non-empty canonical ASCII value, got " <> pyStr value)
  | not (any (`T.isPrefixOf` value) ["place:/", "transition:/", "arc:/"])
      || T.count "#" value > 1
      || T.any pythonIsSpace value
      || T.any (== '?') value
      || T.any (== '\\') value
      || badPercent value =
      Left ("invalid canonical NetUri " <> pyStr value)
  | otherwise = Right (NetUri value)
  where
    -- @re.search(r"%(?![0-9A-F]{2})", value)@
    badPercent text = case T.breakOn "%" text of
      (_, rest)
        | T.null rest -> False
        | otherwise ->
            let following = T.take 2 (T.drop 1 rest)
             in not (T.length following == 2 && T.all upperHex following) || badPercent (T.drop 1 rest)
    upperHex c = isHexDigit c && (not (isAlphaNumLetter c) || isUpper c)
    isAlphaNumLetter c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'

-- | CPython's @str.isspace@ over ASCII (which includes the information
-- separators U+001C..U+001F).
pythonIsSpace :: Char -> Bool
pythonIsSpace c = c `elem` [' ', '\t', '\n', '\r', '\x0b', '\x0c', '\x1c', '\x1d', '\x1e', '\x1f']

-- | The owner kind of a declaration URI.
data UriOwner = PlaceOwner | TransitionOwner
  deriving stock (Eq, Show)

-- | @NetUri.declaration(owner, path, declaration, name)@: address one
-- declaration anchored on a place or transition.
declarationUri :: UriOwner -> NetPath -> Text -> Maybe Text -> Either Text NetUri
declarationUri owner path declaration name = do
  when (T.null declaration || not (T.all isAscii declaration) || not (T.all isAlphaNum (T.filter (/= '-') declaration)) || T.null (T.filter (/= '-') declaration)) $
    Left ("declaration kind must be a non-empty ASCII name, got " <> pyStr declaration)
  when (name == Just "") $
    Left "declaration name must be a non-empty string or None, got ''"
  let ownerText = case owner of
        PlaceOwner -> "place"
        TransitionOwner -> "transition"
      encodedPath = T.intercalate "/" (map (quote "-._~") (netPathSegments path))
      fragment = case name of
        Nothing -> declaration
        Just n -> declaration <> ":" <> quote "-._~$" n
  netUri (ownerText <> ":/" <> encodedPath <> "#" <> fragment)

-- | @NetUri.arc(source, target, occurrence)@: address one directed arc,
-- optionally by its generated pair-local occurrence.
arcUri :: NetPath -> NetPath -> Maybe Int -> NetUri
arcUri source target occurrence =
  let encoded path = T.intercalate "/" (map (quote "-._~") (netPathSegments path))
      fragment = maybe "" (\n -> "#$" <> T.pack (show n)) occurrence
   in NetUri ("arc:/" <> encoded source <> "->/" <> encoded target <> fragment)

-- | @NetUri.arc_filter(arc)@: address the filter declaration anchored on an
-- arc occurrence.
arcFilterUri :: NetUri -> Either Text NetUri
arcFilterUri (NetUri value)
  | not ("arc:/" `T.isPrefixOf` value) =
      Left ("arc filter owner must be an arc NetUri, got " <> T.pack (show (NetUri value)))
  | otherwise = case T.breakOn "#" value of
      (base, rest)
        | T.null rest -> netUri (base <> "#filter")
        | otherwise ->
            let occurrence = T.drop 1 rest
             in if "$" `T.isPrefixOf` occurrence && T.length occurrence > 1 && T.all (\c -> c >= '0' && c <= '9') (T.drop 1 occurrence)
                  then netUri (base <> "#filter:" <> occurrence)
                  else Left ("arc filter owner must use a generated occurrence fragment, got " <> T.pack (show (NetUri value)))

-- | @urllib.parse.quote(text, safe=safe)@: percent-encode the UTF-8 bytes of
-- every character that is neither an ASCII alphanumeric, one of @_.-~@, nor
-- in @safe@, with uppercase hex digits.
quote :: String -> Text -> Text
quote safe text = T.concatMap encode text
  where
    encode c
      | isAscii c && (isAlphaNum c || c `elem` ("_.-~" :: String) || c `elem` safe) = T.singleton c
      | otherwise = T.concat (map byte (BS.unpack (TE.encodeUtf8 (T.singleton c))))
    byte w = T.pack ['%', hexDigit (fromIntegral w `shiftR` 4), hexDigit (fromIntegral w .&. 15)]
    hexDigit :: Int -> Char
    hexDigit n
      | n < 10 = chr (ord '0' + n)
      | otherwise = chr (ord 'A' + n - 10)

-- ---------------------------------------------------------------------------
-- Inscriptions and declarations

-- | A language-neutral nominal color name.
type Color = Text

-- | An instant on the instance's virtual clock. The reference admits any
-- totally ordered value; every durable spelling (History, the v3 time domain)
-- is a JSON number, and History keeps the int/float distinction (@10@ stays
-- integral, @0.5@ round-trips), so the Haskell clock is a 'Number'.
type Instant = Number

-- | A duration a 'Delay' adds to an instant (Python's @int + float@
-- promotion applies).
type Duration = Number

-- | How an input arc participates in enablement: consume removes tokens,
-- read peeks, inhibit gates on absence.
data ArcMode = Consume | Read | Inhibit
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The mode's wire spelling.
arcModeText :: ArcMode -> Text
arcModeText = \case
  Consume -> "consume"
  Read -> "read"
  Inhibit -> "inhibit"

-- | An inline CEL expression, kept as data. Its identity is the expression
-- text, never collapsed into a symbol name: the declaration types tag it.
newtype Cel = Cel Text
  deriving stock (Eq, Ord)

instance Show Cel where
  show (Cel expression) = T.unpack ("Cel(expression=" <> pyStr expression <> ")")

-- | Build an inline expression; it must be non-empty.
cel :: Text -> Either Text Cel
cel expression
  | T.null expression = Left "Cel requires a non-empty expression string, got ''"
  | otherwise = Right (Cel expression)

-- | An inline expression from a literal known to be non-empty.
unsafeCel :: Text -> Cel
unsafeCel = either (error . T.unpack) id . cel

celExpression :: Cel -> Text
celExpression (Cel expression) = expression

-- | A behavior declaration whose canonical identity comes from its owner and
-- position. The display name is presentation only: every anonymous
-- declaration compares equal, as the reference's @compare=False@ field does.
newtype AnonymousDeclaration = AnonymousDeclaration {displayName :: Maybe Text}

instance Eq AnonymousDeclaration where
  _ == _ = True

instance Show AnonymousDeclaration where
  show (AnonymousDeclaration name) = T.unpack ("AnonymousDeclaration(display_name=" <> pyOptStr name <> ")")

-- | @ANONYMOUS@.
anonymous :: AnonymousDeclaration
anonymous = AnonymousDeclaration Nothing

-- | @AnonymousDeclaration(display_name)@: the display name must be non-empty.
anonymousNamed :: Text -> Either Text AnonymousDeclaration
anonymousNamed name
  | T.null name = Left "anonymous declaration display name must be a non-empty string or None, got ''"
  | otherwise = Right (AnonymousDeclaration (Just name))

-- | An arc filter: a named symbol or an inline expression over one token.
data FilterDeclaration = FilterSymbol Text | FilterCel Cel
  deriving stock (Eq, Show)

-- | A transition guard: named, inline, or anonymous.
data GuardDeclaration = GuardSymbol Text | GuardCel Cel | GuardAnonymous AnonymousDeclaration
  deriving stock (Eq, Show)

-- | A transition handler: named or anonymous.
data HandlerDeclaration = HandlerSymbol Text | HandlerAnonymous AnonymousDeclaration
  deriving stock (Eq, Show)

-- | The net's completion condition: named or inline, over the marking.
data CompletionDeclaration = CompletionSymbol Text | CompletionCel Cel
  deriving stock (Eq, Show)

-- | A transition timer. A 'Delay' matures a binding at its youngest selected
-- token's entry instant plus the duration; an 'Until' at its instant.
data Timer = Delay Duration | Until Instant
  deriving stock (Eq, Show)

-- | The reference's @repr@ of a declaration value, for diagnostics.
reprFilterDeclaration :: FilterDeclaration -> Text
reprFilterDeclaration = \case
  FilterSymbol name -> pyStr name
  FilterCel expression -> T.pack (show expression)

reprGuardDeclaration :: GuardDeclaration -> Text
reprGuardDeclaration = \case
  GuardSymbol name -> pyStr name
  GuardCel expression -> T.pack (show expression)
  GuardAnonymous declaration -> T.pack (show declaration)

reprCompletionDeclaration :: CompletionDeclaration -> Text
reprCompletionDeclaration = \case
  CompletionSymbol name -> pyStr name
  CompletionCel expression -> T.pack (show expression)

reprTimer :: Timer -> Text
reprTimer = \case
  Delay duration -> "Delay(duration=" <> T.pack (show duration) <> ")"
  Until instant -> "Until(instant=" <> T.pack (show instant) <> ")"

-- ---------------------------------------------------------------------------
-- Parts

-- | A directed place/transition connection. Input arcs carry a mode, a
-- weight, a color, and an optional filter; on an output arc the color is the
-- routing contract and the mode is the unused consume default.
data Arc = Arc
  { source :: NetPath
  , target :: NetPath
  , mode :: ArcMode
  , weight :: Int
  , color :: Maybe Color
  , filter :: Maybe FilterDeclaration
  }
  deriving stock (Eq, Show)

-- | @Arc(source, target)@: a weight-one, untyped, unfiltered consume arc.
arc :: NetPath -> NetPath -> Arc
arc from to = Arc {source = from, target = to, mode = Consume, weight = 1, color = Nothing, filter = Nothing}

-- | Set an arc's color. (A record update of @color@ is ambiguous between
-- 'Arc' and 'Place', so the two parts each offer a builder.)
withArcColor :: Maybe Color -> Arc -> Arc
withArcColor c a = Arc a.source a.target a.mode a.weight c a.filter

-- | The nominal color match (@Arc.admits@): untyped matches anything, typed
-- matches its color only. A filter narrows input admission further; see
-- "Petrus.Impetus.Petrinet.Enabledness".
arcAdmits :: Arc -> Maybe Color -> Bool
arcAdmits value tokenColor = case value.color of
  Nothing -> True
  Just expected -> tokenColor == Just expected

isConsume, isRead, isInhibit :: Arc -> Bool
isConsume value = value.mode == Consume
isRead value = value.mode == Read
isInhibit value = value.mode == Inhibit

-- | The reference's arc rendering in diagnostics (@{source} -> {target}@).
reprArc :: Arc -> Text
reprArc value = netPathText value.source <> " -> " <> netPathText value.target

-- | A location that holds tokens, optionally declaring their nominal color.
data Place = Place
  { path :: NetPath
  , color :: Maybe Color
  }
  deriving stock (Eq, Show)

-- | @Place(path)@.
place :: NetPath -> Place
place at = Place {path = at, color = Nothing}

-- | @Place(path, color)@.
coloredPlace :: NetPath -> Color -> Place
coloredPlace at c = Place {path = at, color = Just c}

-- | A process step. The handler is a named or anonymous declaration bound
-- separately; guards compose as conjunction, and so do timers.
data Transition = Transition
  { path :: NetPath
  , handler :: Maybe HandlerDeclaration
  , guards :: [GuardDeclaration]
  , timers :: [Timer]
  }
  deriving stock (Eq, Show)

-- | @Transition(path)@.
transition :: NetPath -> Transition
transition at = Transition {path = at, handler = Nothing, guards = [], timers = []}

-- ---------------------------------------------------------------------------
-- Nets

-- | The authored parts of a net, in authored order.
data NetSpec = NetSpec
  { places :: [Place]
  , transitions :: [Transition]
  , arcs :: [Arc]
  , completion :: Maybe CompletionDeclaration
  , name :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | An unnamed spec with no completion condition.
netSpec :: [Place] -> [Transition] -> [Arc] -> NetSpec
netSpec ps ts as = NetSpec {places = ps, transitions = ts, arcs = as, completion = Nothing, name = Nothing}

-- | One input arc of a transition with its global position and its filter
-- identity.
data InputArc = InputArc Int Arc (Maybe NetUri)

-- | A flattened, validated net: places, transitions, place-color-resolved
-- arcs, and the derived indices and canonical identities.
data Net = Net
  { netName :: Maybe Text
  , netCompletion :: Maybe CompletionDeclaration
  , placeMap :: Map NetPath Place
  , placeOrder :: [NetPath]
  , transitionMap :: Map NetPath Transition
  , transitionOrder :: [NetPath]
  , resolvedArcs :: [Arc]
  , arcUriList :: [NetUri]
  , arcUriMap :: Map Int NetUri
  , filterUriList :: [Maybe NetUri]
  , inputMap :: Map NetPath [InputArc]
  , outputMap :: Map NetPath [Arc]
  , handlerUriMap :: Map NetPath NetUri
  , guardUriMap :: Map NetPath [NetUri]
  , handlerDeclarationList :: [(NetUri, HandlerDeclaration)]
  , guardDeclarationList :: [(NetUri, GuardDeclaration)]
  , filterDeclarationList :: [(NetUri, FilterDeclaration)]
  , sourceList :: [NetPath]
  }

instance Show Net where
  show net =
    "Net("
      ++ show (Map.size net.placeMap)
      ++ "p, "
      ++ show (Map.size net.transitionMap)
      ++ "t, "
      ++ show (length net.resolvedArcs)
      ++ "a)"

-- | The net's optional human name.
netName :: Net -> Maybe Text
netName net = net.netName

-- | The net's optional completion declaration.
netCompletion :: Net -> Maybe CompletionDeclaration
netCompletion net = net.netCompletion

-- | Places by path.
netPlaces :: Net -> Map NetPath Place
netPlaces net = net.placeMap

-- | Place paths in authored order.
netPlaceOrder :: Net -> [NetPath]
netPlaceOrder net = net.placeOrder

-- | Transitions by path.
netTransitions :: Net -> Map NetPath Transition
netTransitions net = net.transitionMap

-- | Transition paths in authored order.
netTransitionOrder :: Net -> [NetPath]
netTransitionOrder net = net.transitionOrder

-- | The resolved arcs in authored order.
netArcs :: Net -> [Arc]
netArcs net = net.resolvedArcs

lookupPlace :: NetPath -> Net -> Maybe Place
lookupPlace at net = Map.lookup at net.placeMap

lookupTransition :: NetPath -> Net -> Maybe Transition
lookupTransition at net = Map.lookup at net.transitionMap

hasPlace :: NetPath -> Net -> Bool
hasPlace at net = Map.member at net.placeMap

hasTransition :: NetPath -> Net -> Bool
hasTransition at net = Map.member at net.transitionMap

-- | Input arcs targeting a transition, in arc order.
inputs :: Net -> NetPath -> [Arc]
inputs net at = [value | InputArc _ value _ <- Map.findWithDefault [] at net.inputMap]

-- | Input arcs with their global positions and filter identities.
inputPositions :: Net -> NetPath -> [(Int, Arc, Maybe NetUri)]
inputPositions net at = [(position, value, uri) | InputArc position value uri <- Map.findWithDefault [] at net.inputMap]

-- | Output arcs leaving a transition, in arc order.
outputs :: Net -> NetPath -> [Arc]
outputs net at = Map.findWithDefault [] at net.outputMap

-- | A source transition has no input arcs; it fires only on external
-- delivery.
isSource :: Net -> NetPath -> Bool
isSource net at = not (Map.member at net.inputMap)

-- | The net's source transitions in stable (path) order.
sourceTransitions :: Net -> [NetPath]
sourceTransitions net = net.sourceList

-- | Canonical arc occurrence identities, position-aligned with 'netArcs'.
arcUris :: Net -> [NetUri]
arcUris net = net.arcUriList

-- | The canonical identity of the arc at a global position.
arcUriAt :: Net -> Int -> Maybe NetUri
arcUriAt net position = Map.lookup position net.arcUriMap

-- | Filter identities, position-aligned with 'netArcs'.
filterUris :: Net -> [Maybe NetUri]
filterUris net = net.filterUriList

-- | The canonical identity of a transition's declared handler.
handlerUri :: Net -> NetPath -> Maybe NetUri
handlerUri net at = Map.lookup at net.handlerUriMap

-- | Canonical identities of a transition's guards in authored order.
guardUris :: Net -> NetPath -> [NetUri]
guardUris net at = Map.findWithDefault [] at net.guardUriMap

handlerDeclarations :: Net -> [(NetUri, HandlerDeclaration)]
handlerDeclarations net = net.handlerDeclarationList

guardDeclarations :: Net -> [(NetUri, GuardDeclaration)]
guardDeclarations net = net.guardDeclarationList

filterDeclarations :: Net -> [(NetUri, FilterDeclaration)]
filterDeclarations net = net.filterDeclarationList

-- | Build and validate a net: every rule of the reference's part
-- constructors and of @Net.__init__@, in the reference's order of concern.
mkNet :: NetSpec -> Either Text Net
mkNet spec = do
  forM_ spec.completion $ \case
    CompletionSymbol symbol
      | T.null symbol || "$" `T.isPrefixOf` symbol ->
          Left ("completion symbol must be non-empty and cannot start with '$', got " <> pyStr symbol)
    _ -> Right ()
  when (spec.name == Just "") $ Left "net name must be a non-empty string, got ''"
  mapM_ validatePlace spec.places
  mapM_ validateTransition spec.transitions
  mapM_ validateArc spec.arcs
  checkDistinctNodes spec.places spec.transitions
  let placeList = [(p.path, p) | p <- spec.places]
      transitionList = [(t.path, t) | t <- spec.transitions]
      placeMap = Map.fromList placeList
      transitionMap = Map.fromList transitionList
  -- Behavior declaration identities, in transition order.
  handlerPairs <- fmap concat . mapM (\t -> case t.handler of
      Nothing -> Right []
      Just declaration -> do
        uri <- declarationUri TransitionOwner t.path "handler" Nothing
        Right [(t.path, uri, declaration)]) $ map snd (dedupe transitionList)
  guardPairs <- mapM (\t -> do
      uris <- mapM (\(position, guard) -> declarationUri TransitionOwner t.path "guard" (Just (guardName position guard))) (zip [0 :: Int ..] t.guards)
      Right (t.path, zip uris t.guards)) (map snd (dedupe transitionList))
  resolved <- mapM (resolveColor placeMap transitionMap) spec.arcs
  let pairKey value = (value.source, value.target)
      pairCounts = foldl' (\counts value -> Map.insertWith (+) (pairKey value) (1 :: Int) counts) Map.empty resolved
      (_, arcUriList) =
        foldl'
          ( \(positions, acc) value ->
              let key = pairKey value
                  position = Map.findWithDefault 0 key positions
                  occurrence = if Map.findWithDefault 0 key pairCounts > 1 then Just position else Nothing
               in (Map.insert key (position + 1) positions, arcUri value.source value.target occurrence : acc)
          )
          (Map.empty, [])
          resolved
      uris = reverse arcUriList
  filterUriList <- mapM (\(uri, value) -> if isJust value.filter then Just <$> arcFilterUri uri else Right Nothing) (zip uris resolved)
  let filterDeclarationList = [(uri, declaration) | (Just uri, Arc {filter = Just declaration}) <- zip filterUriList resolved]
      positioned = zip3 [0 :: Int ..] resolved filterUriList
  -- Input/output indices; modes and filters are input inscriptions.
  (inputAssoc, outputAssoc) <-
    foldl'
      ( \acc (position, value, filterUri) -> do
          (ins, outs) <- acc
          if Map.member value.source placeMap && Map.member value.target transitionMap
            then Right ((value.target, InputArc position value filterUri) : ins, outs)
            else do
              when (value.mode /= Consume) $
                Left ("mode on output arc " <> reprArc value <> ": modes are input inscriptions")
              when (isJust value.filter) $
                Left ("filter on output arc " <> reprArc value <> ": a filter is an input inscription")
              Right (ins, (value.source, value) : outs)
      )
      (Right ([], []))
      positioned
  let inputMap = Map.fromListWith (flip (++)) [(k, [v]) | (k, v) <- reverse inputAssoc]
      outputMap = Map.fromListWith (flip (++)) [(k, [v]) | (k, v) <- reverse outputAssoc]
      inputOrder = dedupeKeys (map fst (reverse inputAssoc))
  -- A handlerless transition whose inputs only read or inhibit would fire
  -- forever on an unchanging marking.
  forM_ inputOrder $ \at -> do
    let t = transitionMap Map.! at
        modes = [value.mode | InputArc _ value _ <- Map.findWithDefault [] at inputMap]
    when (not (isJust t.handler) && Consume `notElem` modes) $
      Left
        ( "transition "
            <> netPathText at
            <> ": a non-source transition with no consume input arc and no handler would fire forever consuming and producing nothing"
        )
  forM_ (map snd (dedupe transitionList)) $ \t -> do
    let source = not (Map.member t.path inputMap)
    when (source && not (null t.guards)) $
      Left
        ( "transition "
            <> netPathText t.path
            <> ": guards on a source transition cannot be honored — it fires only on external delivery, never through enabledness; found "
            <> pyList (map reprGuardDeclaration t.guards)
        )
    when (source && not (null t.timers)) $
      Left
        ( "transition "
            <> netPathText t.path
            <> ": timers on a source transition cannot be honored — it fires only on external delivery, never through enabledness; found "
            <> pyList (map reprTimer t.timers)
        )
    let anchored = or [True | Delay _ <- t.timers]
        anchors = or [value.mode /= Inhibit | InputArc _ value _ <- Map.findWithDefault [] t.path inputMap]
    when (anchored && not anchors) $
      Left
        ( "transition "
            <> netPathText t.path
            <> ": a duration timer has no anchor — every input arc is an inhibitor and absence has no entry instant; declare a consume or read input, or use an absolute Until timer"
        )
  Right
    Net
      { netName = spec.name
      , netCompletion = spec.completion
      , placeMap = placeMap
      , placeOrder = map fst (dedupe placeList)
      , transitionMap = transitionMap
      , transitionOrder = map fst (dedupe transitionList)
      , resolvedArcs = resolved
      , arcUriList = uris
      , arcUriMap = Map.fromList (zip [0 ..] uris)
      , filterUriList = filterUriList
      , inputMap = inputMap
      , outputMap = outputMap
      , handlerUriMap = Map.fromList [(at, uri) | (at, uri, _) <- handlerPairs]
      , guardUriMap = Map.fromList [(at, map fst pairs) | (at, pairs) <- guardPairs]
      , handlerDeclarationList = [(uri, declaration) | (_, uri, declaration) <- handlerPairs]
      , guardDeclarationList = concatMap snd guardPairs
      , filterDeclarationList = filterDeclarationList
      , sourceList = sort [at | at <- Map.keys transitionMap, not (Map.member at inputMap)]
      }
  where
    guardName position = \case
      GuardSymbol symbol -> symbol
      _ -> "$" <> T.pack (show position)
    dedupe :: [(NetPath, a)] -> [(NetPath, a)]
    dedupe = go Set.empty
      where
        go _ [] = []
        go seen ((k, v) : rest)
          | Set.member k seen = go seen rest
          | otherwise = (k, v) : go (Set.insert k seen) rest
    dedupeKeys = map fst . dedupe . map (\k -> (k, ()))

-- | @Net.__init__@'s node checks: unique place paths, unique transition
-- paths, and no path naming both a place and a transition.
checkDistinctNodes :: [Place] -> [Transition] -> Either Text ()
checkDistinctNodes places transitions = do
  let placeMap = Map.fromList [(p.path, p) | p <- places]
      transitionMap = Map.fromList [(t.path, t) | t <- transitions]
  when (Map.size placeMap /= length places) $ Left "duplicate place path"
  when (Map.size transitionMap /= length transitions) $ Left "duplicate transition path"
  let collisions = Map.keys (Map.intersection placeMap transitionMap)
  unless (null collisions) $
    Left ("place/transition name collision: " <> pyList (map (pyStr . netPathText) (sort collisions)))

-- | Compile a place color default onto an otherwise untyped incident arc.
resolveColor :: Map NetPath Place -> Map NetPath Transition -> Arc -> Either Text Arc
resolveColor placeMap transitionMap value = do
  owner <-
    if Map.member value.source placeMap && Map.member value.target transitionMap
      then Right (placeMap Map.! value.source)
      else
        if Map.member value.source transitionMap && Map.member value.target placeMap
          then Right (placeMap Map.! value.target)
          else Left ("arc must connect a place and a transition: " <> reprArc value)
  case (owner.color, value.color) of
    (Just placeColor, Just arcColor)
      | placeColor /= arcColor ->
          Left
            ( "arc "
                <> reprArc value
                <> " declares color "
                <> pyStr arcColor
                <> ", incompatible with place "
                <> netPathText owner.path
                <> " color "
                <> pyStr placeColor
            )
    (Just placeColor, Nothing) -> Right (withArcColor (Just placeColor) value)
    _ -> Right value

-- | @Place.__post_init__@.
validatePlace :: Place -> Either Text ()
validatePlace value = when (value.color == Just "") $
  Left ("place color must be a non-empty nominal color name or None, got '': " <> netPathText value.path)

-- | @Transition.__post_init__@ (and the anonymous display-name rule).
validateTransition :: Transition -> Either Text ()
validateTransition value = do
  let at = netPathText value.path
  -- The reference refuses an empty display name in
  -- @AnonymousDeclaration.__post_init__@; the constructor is open here, so
  -- the net boundary runs the same rule over every anonymous declaration.
  forM_ ([a | Just (HandlerAnonymous a) <- [value.handler]] ++ [a | GuardAnonymous a <- value.guards]) $ \a ->
    when (a.displayName == Just "") $
      Left "anonymous declaration display name must be a non-empty string or None, got ''"
  case value.handler of
    Just (HandlerSymbol symbol)
      | T.null symbol || "$" `T.isPrefixOf` symbol ->
          Left ("handler symbol must be non-empty and cannot start with '$', got " <> pyStr symbol <> ": " <> at)
    _ -> Right ()
  _ <-
    foldl'
      ( \acc guard -> do
          seen <- acc
          case guard of
            GuardSymbol symbol -> do
              when (T.null symbol || "$" `T.isPrefixOf` symbol) $
                Left ("guard symbol must be non-empty and cannot start with '$', got " <> pyStr symbol <> ": " <> at)
              when (Set.member symbol seen) $ Left ("duplicate named guard " <> pyStr symbol <> ": " <> at)
              Right (Set.insert symbol seen)
            _ -> Right seen
      )
      (Right Set.empty)
      value.guards
  Right ()

validateArc :: Arc -> Either Text ()
validateArc value = do
  when (value.weight < 1) $
    Left ("arc weight must be an integer >= 1, got " <> T.pack (show value.weight) <> ": " <> reprArc value)
  when (value.color == Just "") $
    Left ("arc color must be a non-empty nominal color name or None, got '': " <> reprArc value)
  case value.filter of
    Just (FilterSymbol symbol)
      | T.null symbol || "$" `T.isPrefixOf` symbol ->
          Left ("filter symbol must be non-empty and cannot start with '$', got " <> pyStr symbol <> ": " <> reprArc value)
    _ -> Right ()
