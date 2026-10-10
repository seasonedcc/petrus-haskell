{-# LANGUAGE DeriveAnyClass #-}
-- | The petrus-engine models for @fileVersion: "2"@ net files
-- (@petrus.schema@) and the executable projection the loader builds
-- (@FlatNet@, @FlatSchema@).
--
-- Field order matches the pydantic models; the 'Eq' instances are the
-- models' Python equality (dicts compare as mappings, numbers across types,
-- NaN equals nothing).
module Petrus.EngineFile.Types
  ( -- * Paths
    NetPath (..)
  , Segment (..)
  , netPathFromText
  , netPathText
  , allText
  , appendPath
  , rootPath

    -- * Source file models
  , ArcKind (..)
  , arcKindText
  , Interface (..)
  , interfaceText
  , FlatArc (..)
  , PlaceDef (..)
  , TransitionDef (..)
  , RefEntry (..)
  , ViewState (..)
  , FlatNetFile (..)
  , Metadata

    -- * Resolved net
  , FlatNet (..)
  , ArcDef (..)
  , FlatSchema (..)

    -- * Python equality
  , pyEqFile
  , dictEq
  , pathEq
  ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.EngineFile.Duration (Timedelta)
import Petrus.EngineFile.Value (Value (..), pyEqWith)

-- | One element of a @NetPath@ tuple. Validation splits strings, so a
-- segment is a @str@ unless a JSON array put an array or object there.
data Segment
  = SegText !Text
  | -- | A Python @list@ or @dict@ segment.
    SegOther !Value
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq Segment where
  (==) = segmentEq False

segmentEq :: Bool -> Segment -> Segment -> Bool
segmentEq n a b = case (a, b) of
  (SegText x, SegText y) -> x == y
  (SegOther x, SegOther y) -> pyEqWith n x y
  _ -> False

-- | @petrus.types.NetPath@: a tuple of segments.
newtype NetPath = NetPath [Segment]
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq NetPath where
  (==) = pathEq False

pathEq :: Bool -> NetPath -> NetPath -> Bool
pathEq n (NetPath a) (NetPath b) = length a == length b && and (zipWith (segmentEq n) a b)

-- | @NetPath(str)@: split on dots, with @""@ the empty path.
netPathFromText :: Text -> NetPath
netPathFromText t
  | T.null t = NetPath []
  | otherwise = NetPath (map SegText (T.splitOn "." t))

-- | @str(path)@ when every segment is a string.
netPathText :: NetPath -> Maybe Text
netPathText (NetPath segments) = T.intercalate "." <$> traverse textOf segments
  where
    textOf = \case
      SegText t -> Just t
      SegOther _ -> Nothing

-- | Whether every segment is a string.
allText :: NetPath -> Bool
allText (NetPath segments) = all (\case SegText _ -> True; SegOther _ -> False) segments

-- | @path.append(suffix)@.
appendPath :: NetPath -> NetPath -> NetPath
appendPath (NetPath a) (NetPath b) = NetPath (a ++ b)

-- | @NetPath()@.
rootPath :: NetPath
rootPath = NetPath []

-- | @petrus.types.ArcKind@.
data ArcKind = Normal | Inhibitor | Read
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (NFData)

arcKindText :: ArcKind -> Text
arcKindText = \case
  Normal -> "normal"
  Inhibitor -> "inhibitor"
  Read -> "read"

-- | @PlaceDef.interface@'s literal values.
data Interface = InputInterface | OutputInterface | AwaitingInterface | ControlInterface
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (NFData)

interfaceText :: Interface -> Text
interfaceText = \case
  InputInterface -> "input"
  OutputInterface -> "output"
  AwaitingInterface -> "awaiting"
  ControlInterface -> "control"

-- | @dict[str, Any]@: members in Python dict order, values as Python
-- objects.
type Metadata = [(Text, Value)]

-- | @petrus.schema.FlatArc@.
data FlatArc = FlatArc
  { source :: NetPath
  , target :: NetPath
  , kind :: ArcKind
  , weight :: Integer
  , metadata :: Maybe Metadata
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq FlatArc where
  (==) = arcEq False

arcEq :: Bool -> FlatArc -> FlatArc -> Bool
arcEq n a b =
  pathEq n a.source b.source
    && pathEq n a.target b.target
    && a.kind == b.kind
    && a.weight == b.weight
    && maybeEq (dictEqWith n) a.metadata b.metadata

-- | @petrus.schema.PlaceDef@.
data PlaceDef = PlaceDef
  { initial :: Integer
  , label :: Maybe Text
  , interface :: Maybe Interface
  , metadata :: Maybe Metadata
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq PlaceDef where
  (==) = placeEq False

placeEq :: Bool -> PlaceDef -> PlaceDef -> Bool
placeEq n a b =
  a.initial == b.initial
    && a.label == b.label
    && a.interface == b.interface
    && maybeEq (dictEqWith n) a.metadata b.metadata

-- | @petrus.schema.TransitionDef@.
data TransitionDef = TransitionDef
  { handler :: Maybe Text
  , guard :: Maybe Text
  , label :: Maybe Text
  , metadata :: Maybe Metadata
  , delay :: Maybe Timedelta
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq TransitionDef where
  (==) = transitionEq False

transitionEq :: Bool -> TransitionDef -> TransitionDef -> Bool
transitionEq n a b =
  a.handler == b.handler
    && a.guard == b.guard
    && a.label == b.label
    && maybeEq (dictEqWith n) a.metadata b.metadata
    && a.delay == b.delay

-- | @petrus.schema.RefEntry@.
newtype RefEntry = RefEntry {ref :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | @petrus.schema.ViewState@.
data ViewState = ViewState
  { arcWaypoints :: Maybe [(Text, [(Double, Double)])]
  , layout :: [(NetPath, (Double, Double))]
  , zoom :: Double
  , pan :: (Double, Double)
  , selected :: [NetPath]
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

instance Eq ViewState where
  (==) = viewStateEq False

viewStateEq :: Bool -> ViewState -> ViewState -> Bool
viewStateEq n a b =
  maybeEq (pairsEq (listEq pointEq)) a.arcWaypoints b.arcWaypoints
    && pathPairsEq pointEq a.layout b.layout
    && floatEq a.zoom b.zoom
    && pointEq a.pan b.pan
    && listEq (pathEq n) a.selected b.selected
  where
    floatEq x y = x == y || (n && isNaN x && isNaN y)
    pointEq (x1, y1) (x2, y2) = floatEq x1 x2 && floatEq y1 y2

-- | @petrus.schema.FlatNetFile@.
data FlatNetFile = FlatNetFile
  { fileVersion :: Text
  , net :: Text
  , arcs :: [FlatArc]
  , places :: [(NetPath, PlaceDef)]
  , transitions :: [(NetPath, TransitionDef)]
  , refs :: [(NetPath, RefEntry)]
  , viewState :: Maybe ViewState
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

-- | Python @==@ between two validated files. The flag says whether every
-- NaN in them is one shared object (files validated from @json.loads@
-- objects), which the identity shortcut of container comparison makes equal
-- itself; floats jiter parses are distinct objects, so NaN equals nothing.
pyEqFile :: Bool -> FlatNetFile -> FlatNetFile -> Bool
pyEqFile n a b =
  a.fileVersion == b.fileVersion
    && a.net == b.net
    && listEq (arcEq n) a.arcs b.arcs
    && pathPairsEq (placeEq n) a.places b.places
    && pathPairsEq (transitionEq n) a.transitions b.transitions
    && pathPairsEq (==) a.refs b.refs
    && maybeEq (viewStateEq n) a.viewState b.viewState

instance Eq FlatNetFile where
  (==) = pyEqFile False

-- | @petrus.schema.FlatNet@: the refs-inlined net.
data FlatNet = FlatNet
  { net :: Text
  , arcs :: [FlatArc]
  , places :: [(NetPath, PlaceDef)]
  , transitions :: [(NetPath, TransitionDef)]
  , viewStates :: [(Text, ViewState)]
  , refOrigins :: [(Text, [NetPath])]
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

-- | @petrus.schema.ArcDef@ as @to_schema@ builds it.
data ArcDef = ArcDef
  { source :: NetPath
  , target :: NetPath
  , weight :: Integer
  , kind :: ArcKind
  , metadata :: Maybe Metadata
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

-- | @petrus.schema.FlatSchema@: absolute paths (prefixed with the net
-- name); arcs keyed by @(source, target)@ in dict order.
data FlatSchema = FlatSchema
  { name :: Text
  , places :: [(NetPath, PlaceDef)]
  , transitions :: [(NetPath, TransitionDef)]
  , arcs :: [((NetPath, NetPath), ArcDef)]
  , refToSubnets :: [(Text, [NetPath])]
  }
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

maybeEq :: (a -> a -> Bool) -> Maybe a -> Maybe a -> Bool
maybeEq f (Just a) (Just b) = f a b
maybeEq _ Nothing Nothing = True
maybeEq _ _ _ = False

-- | Two Python dicts with string keys.
dictEq :: [(Text, Value)] -> [(Text, Value)] -> Bool
dictEq = dictEqWith False

dictEqWith :: Bool -> [(Text, Value)] -> [(Text, Value)] -> Bool
dictEqWith n = pairsEq (pyEqWith n)

listEq :: (a -> a -> Bool) -> [a] -> [a] -> Bool
listEq f xs ys = length xs == length ys && and (zipWith f xs ys)

pairsEq :: (v -> v -> Bool) -> [(Text, v)] -> [(Text, v)] -> Bool
pairsEq f xs ys =
  length xs == length ys
    && let m = Map.fromList ys in all (\(k, v) -> maybe False (f v) (Map.lookup k m)) xs

-- Keys are string-segment paths (dict keys come from JSON strings), so they
-- compare by their text.
pathPairsEq :: (v -> v -> Bool) -> [(NetPath, v)] -> [(NetPath, v)] -> Bool
pathPairsEq f xs ys = pairsEq f (map keyed xs) (map keyed ys)
  where
    keyed (NetPath segments, v) = (T.pack (show [t | SegText t <- segments]), v)
