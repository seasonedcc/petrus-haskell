-- | The behavioral checks on a net's skeleton (@README.md@): every marking
-- a small scenario can reach, explored in full.
--
-- The skeleton is the net with its colors abstracted away. A place holds a
-- count of tokens, and every filter and guard is taken to hold, so a
-- transition is enabled when each consume and read arc finds as many tokens
-- as its weight, and each inhibited place is empty. What a firing puts is
-- one of the outcomes its author declares ("Petrus.Net.Declared"). A
-- transition with a failure outcome runs an Activity: it takes its inputs
-- when it starts, is in flight as @\@transition@, and puts one outcome when
-- it ends, so other transitions fire in between.
--
-- Each scenario starts from the declared initial marking, and delivers to
-- source transitions and ingress places as many times as it says, at any
-- moment. Over every marking it reaches, the checks are:
--
-- * every declared law keeps its total;
-- * every marking where nothing can happen is one the net may rest in;
-- * from every marking, one the net may rest in can still be reached.
--
-- A marking the net may rest in has every delivery made, and matches a
-- declared final marking, ignoring final places, with no Activity in
-- flight. With no final markings declared, it holds tokens only in final
-- places.
module Petrus.Net.Check
  ( Limits (..)
  , defaultLimits
  , Problem (..)
  , Report (..)
  , Checked (..)
  , check
  , renderChecked
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq (..))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Petrinet.Schema (Arc (..), ArcMode (..), Net, netArcs, netPathText, netTransitions)
import Petrus.Net.Declared
import Petrus.Net.Lint (Finding (..), findings)

-- | How far the exploration goes before it stops and says so.
data Limits = Limits
  { markings :: Int
  , tokens :: Int
  -- ^ The most tokens any place may hold before the net counts as unbounded.
  }
  deriving stock (Eq, Show)

defaultLimits :: Limits
defaultLimits = Limits {markings = 200000, tokens = 32}

-- | One way the net fails a check, with the firings that lead there from
-- the scenario's start.
data Problem = Problem
  { rule :: Text
  , message :: Text
  , trace :: [Text]
  }
  deriving stock (Eq, Show)

data Report = Report
  { scenario :: Text
  , reached :: Int
  , problems :: [Problem]
  }
  deriving stock (Eq, Show)

data Checked = Checked
  { reports :: [Report]
  , invariants :: Either Text [Map Text Integer]
  -- ^ The net's minimal semi-positive P-invariants, over its places and
  -- its Activities in flight.
  }
  deriving stock (Eq, Show)

-- | Check every scenario, or the initial marking alone when none is
-- declared. A mistake in the declarations is the only problem reported
-- then, since the checks would read them wrong.
check :: Limits -> Net -> Declared -> Checked
check limits net declared = case [f | f <- findings net declared, f.rule == "declaration"] of
  [] ->
    Checked
      { reports = map (explore limits skeleton declared) scenarios
      , invariants = invariantsOf skeleton
      }
  mistakes ->
    Checked
      { reports = [Report "the declarations" 0 [Problem "declaration" (f.at <> ": " <> f.message) [] | f <- mistakes]]
      , invariants = Right []
      }
  where
    skeleton = skeletonOf net declared
    scenarios = case declared.scenarios of
      [] -> [Scenario {name = "the initial marking", deliver = Map.empty}]
      declaredOnes -> declaredOnes

-- ---------------------------------------------------------------------------
-- The skeleton

data Step = Step
  { name :: Text
  , takes :: [(Text, Int)]
  , needs :: [(Text, Int)]
  , blockers :: [Text]
  , ends :: [(Text, Map Text Int)]
  -- ^ Each outcome's name and what it puts.
  , activity :: Bool
  }

newtype Skeleton = Skeleton {steps :: Map Text Step}

skeletonOf :: Net -> Declared -> Skeleton
skeletonOf net declared = Skeleton (Map.fromList [(t, stepOf t) | t <- map netPathText (Map.keys (netTransitions net))])
  where
    arcs = netArcs net
    inputs mode t = [(netPathText a.source, a.weight) | a <- arcs, a.mode == mode, netPathText a.target == t]
    outputs t = Map.fromListWith (+) [(netPathText a.target, a.weight) | a <- arcs, netPathText a.source == t]
    stepOf t =
      let declaredOutcomes = Map.lookup t declared.outcomes
       in Step
            { name = t
            , takes = inputs Consume t
            , needs = inputs Read t
            , blockers = map fst (inputs Inhibit t)
            , ends = maybe [("fires", outputs t)] (map (\o -> (o.name, o.puts))) declaredOutcomes
            , activity = any (any (\o -> o.when == OnFailure)) declaredOutcomes
            }

isSource :: Step -> Bool
isSource s = null s.takes && null s.needs && null s.blockers

-- ---------------------------------------------------------------------------
-- Markings

-- | Tokens in each place, firings in flight as @\@transition@, and the
-- deliveries still to come as @+name@. Only counts above zero are kept.
type Marking = Map Text Int

add :: Text -> Int -> Marking -> Marking
add key n = Map.alter (\count -> let total = fromMaybe 0 count + n in if total == 0 then Nothing else Just total) key

countOf :: Text -> Marking -> Int
countOf key = Map.findWithDefault 0 key

inFlight :: Text -> Text
inFlight t = "@" <> t

pending :: Text -> Text
pending k = "+" <> k

-- | Every move from a marking: its label and the marking it leads to.
moves :: Skeleton -> Declared -> Marking -> [(Text, Marking)]
moves skeleton declared m = deliveries <> firings <> endings
  where
    deliveries =
      concat
        [ case Map.lookup k skeleton.steps of
            Just s | isSource s -> fire s ("deliver to " <> k) (add (pending k) (-1) m)
            _ -> [("deliver to " <> k, add k 1 (add (pending k) (-1) m)) | k `elem` declared.ingress]
        | (key, _) <- Map.toList m
        , Just k <- [T.stripPrefix "+" key]
        ]
    firings = concat [fire s s.name m | s <- Map.elems skeleton.steps, not (isSource s), enabled s]
    enabled s =
      all (\(p, w) -> countOf p m >= w) (s.takes <> s.needs)
        && all (\p -> countOf p m == 0) s.blockers
    fire s label from =
      let taken = foldl' (\acc (p, w) -> add p (-w) acc) from s.takes
       in if s.activity
            then [("start " <> label, add (inFlight s.name) 1 taken)]
            else [(labelled label s outcome, putAll puts taken) | (outcome, puts) <- s.ends]
    endings =
      [ (s.name <> " ends: " <> outcome, putAll puts (add (inFlight s.name) (-1) m))
      | s <- Map.elems skeleton.steps
      , s.activity
      , countOf (inFlight s.name) m > 0
      , (outcome, puts) <- s.ends
      ]
    labelled label s outcome = if length s.ends > 1 then label <> ": " <> outcome else label
    putAll puts start = Map.foldlWithKey' (\acc p n -> add p n acc) start puts

-- | Whether the net may rest in a marking.
atRest :: Declared -> Marking -> Bool
atRest declared m = not (any ("+" `T.isPrefixOf`) (Map.keys m)) && case declared.finalMarkings of
  [] -> Map.null rest
  finals -> any (\final -> rest == Map.filter (> 0) (Map.withoutKeys final finalPlaces)) finals
  where
    finalPlaces = Set.fromList declared.finalPlaces
    rest = Map.withoutKeys m finalPlaces

render :: Marking -> Text
render m
  | Map.null m = "nothing anywhere"
  | otherwise = T.intercalate ", " [k <> ": " <> T.pack (show n) | (k, n) <- Map.toList m]

-- ---------------------------------------------------------------------------
-- Exploring a scenario

data Explored = Explored
  { parents :: Map Marking (Maybe (Marking, Text))
  , next :: Map Marking [Marking]
  , order :: [Marking]
  -- ^ In the order they were reached, so the first is the closest.
  , stopped :: Maybe Problem
  }

explore :: Limits -> Skeleton -> Declared -> Scenario -> Report
explore limits skeleton declared scenario =
  Report
    { scenario = scenario.name
    , reached = Map.size explored.parents
    , problems = maybe checks pure explored.stopped
    }
  where
    start = Map.filter (> 0) (Map.unionWith (+) declared.initial (Map.mapKeys pending scenario.deliver))
    explored = search limits skeleton declared start
    reached' = reverse explored.order
    traceTo m = case Map.lookup m explored.parents of
      Just (Just (before, label)) -> traceTo before <> [label]
      _ -> []
    checks = lawBreaks <> deadlocks <> unsettled
    lawBreaks =
      take 1 $
        [ Problem "law" (law.name <> " adds up to " <> T.pack (show total) <> ", not " <> T.pack (show law.total) <> ", in " <> render m) (traceTo m)
        | law <- declared.laws
        , m <- reached'
        , let total = sum [w * countOf key m | (key, w) <- Map.toList law.weights]
        , total /= law.total
        ]
    deadlocks = take 1 [Problem "deadlock" ("nothing can happen, and the net may not rest in " <> render m) (traceTo m) | m <- reached', null (Map.findWithDefault [] m explored.next), not (atRest declared m)]
    canSettle = settling explored (filter (atRest declared) reached')
    unsettled = take 1 [Problem "never-rests" ("from " <> render m <> ", no marking the net may rest in can be reached") (traceTo m) | m <- reached', not (Set.member m canSettle)]

-- | Breadth first, so each marking's trace is a shortest one.
search :: Limits -> Skeleton -> Declared -> Marking -> Explored
search limits skeleton declared start = go (Seq.singleton start) (Map.singleton start Nothing) Map.empty [start]
  where
    go Empty parents next order = Explored {parents, next, order, stopped = Nothing}
    go (m :<| queue) parents next order =
      let followers = moves skeleton declared m
          fresh = [(label, m') | (label, m') <- followers, not (Map.member m' parents)]
          firstOfEach = Map.toList (Map.fromListWith (\_ earlier -> earlier) [(m', label) | (label, m') <- fresh])
          parents' = foldl' (\acc (m', label) -> Map.insert m' (Just (m, label)) acc) parents firstOfEach
          next' = Map.insert m (map snd followers) next
          order' = reverse (map fst firstOfEach) <> order
          overfull = [m' | (m', _) <- firstOfEach, any (> limits.tokens) (Map.elems (Map.filterWithKey (\k _ -> not ("+" `T.isPrefixOf` k)) m'))]
       in case overfull of
            (m' : _) ->
              Explored {parents = parents', next = next', order = order', stopped = Just (Problem "unbounded" ("a place holds more than " <> T.pack (show limits.tokens) <> " tokens: " <> render m') (traceOf parents' m'))}
            []
              | Map.size parents' > limits.markings ->
                  Explored {parents = parents', next = next', order = order', stopped = Just (Problem "too-large" ("more than " <> T.pack (show limits.markings) <> " markings; try a smaller scenario") [])}
              | otherwise -> go (foldl' (Seq.|>) queue (map fst firstOfEach)) parents' next' order'
    traceOf parents m = case Map.lookup m parents of
      Just (Just (before, label)) -> traceOf parents before <> [label]
      _ -> []

-- | Every marking from which one in @targets@ can be reached.
settling :: Explored -> [Marking] -> Set Marking
settling explored targets = go (Set.fromList targets) targets
  where
    before = Map.fromListWith (<>) [(m', [m]) | (m, ms) <- Map.toList explored.next, m' <- ms]
    go seen [] = seen
    go seen (m : rest) =
      let new = [p | p <- Map.findWithDefault [] m before, not (Set.member p seen)]
       in go (foldl' (flip Set.insert) seen new) (new <> rest)

-- ---------------------------------------------------------------------------
-- P-invariants

-- | The minimal semi-positive P-invariants, by Farkas' algorithm, over the
-- net's places and its Activities in flight. Source transitions are left
-- out, since a caller's deliveries add tokens no law keeps.
invariantsOf :: Skeleton -> Either Text [Map Text Integer]
invariantsOf skeleton = go (zip incidence (map unit [0 .. length rows - 1])) columns
  where
    steps = filter (not . isSource) (Map.elems skeleton.steps)
    effects =
      concat
        [ if s.activity
            then (Map.insert (inFlight s.name) 1 (taken s)) : [Map.insert (inFlight s.name) (-1) (puts' p) | (_, p) <- s.ends]
            else [Map.unionWith (+) (taken s) (puts' p) | (_, p) <- s.ends]
        | s <- steps
        ]
    taken s = Map.fromListWith (+) [(p, negate (toInteger w)) | (p, w) <- s.takes]
    puts' = Map.map toInteger
    rows = Set.toList (Set.fromList (concatMap Map.keys effects))
    columns = [0 .. length effects - 1]
    incidence = [[Map.findWithDefault 0 r e | e <- effects] | r <- rows]
    unit i = [if j == i then 1 else 0 | j <- [0 .. length rows - 1]]
    go current [] = Right [Map.fromList [(r, y) | (r, y) <- zip rows ys, y /= 0] | (_, ys) <- current]
    go current (j : later)
      | length combined > 5000 = Left "too many to list"
      | otherwise = go (minimal combined) later
      where
        zeros = [row | row@(cs, _) <- current, cs !! j == 0]
        positives = [row | row@(cs, _) <- current, cs !! j > 0]
        negatives = [row | row@(cs, _) <- current, cs !! j < 0]
        combined = zeros <> [normalize (combine p n) | p <- positives, n <- negatives]
        combine (pc, py) (nc, ny) =
          let a = negate (nc !! j)
              b = pc !! j
           in (zipWith (\x y -> a * x + b * y) pc nc, zipWith (\x y -> a * x + b * y) py ny)
    normalize (cs, ys) = let g = foldl' gcd 0 (cs <> ys) in if g <= 1 then (cs, ys) else (map (`div` g) cs, map (`div` g) ys)
    support (_, ys) = Set.fromList [i | (i, y) <- zip [0 :: Int ..] ys, y /= 0]
    minimal rows' =
      let unique = Map.elems (Map.fromList [(snd r, r) | r <- rows'])
       in [r | r <- unique, not (any (\o -> snd o /= snd r && support o `Set.isSubsetOf` support r) unique)]

-- ---------------------------------------------------------------------------
-- Rendering

renderChecked :: Checked -> [Text]
renderChecked checked =
  concatMap report checked.reports
    <> case checked.invariants of
      Left why -> ["P-invariants: " <> why]
      Right [] -> ["P-invariants: none"]
      Right found -> "P-invariants:" : map (("  " <>) . invariant) found
  where
    report r = case r.problems of
      [] -> [r.scenario <> ": " <> T.pack (show r.reached) <> " markings, every check holds"]
      problems -> concatMap (problem r) problems
    problem r p =
      (p.rule <> " in " <> r.scenario <> ": " <> p.message)
        : map ("  " <>) (if null p.trace then ["(at the start)" | p.rule /= "too-large" && p.rule /= "declaration"] else p.trace)
    invariant m = T.intercalate " + " [weighted w k | (k, w) <- Map.toList m] <> " stays constant"
    weighted w k = if w == 1 then k else T.pack (show w) <> "·" <> k
