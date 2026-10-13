-- | The net lint (@README.md@): the signs of a net whose marking collapsed
-- into one token, found in a net's structure and its declarations.
--
-- A net is not a state machine with one central state. Its state is its
-- marking: which tokens sit in which places, spread across the net. A
-- process's concurrency, its waiting and its scarce resources live in the
-- net's places and transitions, never inside a token's data. Each rule
-- finds one way a net hides them, and says where.
--
-- The rules are heuristics. A finding a net's author can justify is waived,
-- in a file beside the net ("Petrus.Net.Declared"), with the reason and who
-- accepted it, and a waiver that no longer matches anything is a finding
-- itself, so waivers can't pile up.
module Petrus.Net.Lint
  ( Finding (..)
  , lint
  , findings
  , waivable
  , renderFinding
  ) where

import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Cel.Parse (parseCel)
import Petrus.Cel.Syntax
import Petrus.Impetus.Petrinet.Schema (Arc (..), ArcMode (..), FilterDeclaration (..), GuardDeclaration (..), Net, Transition (..), celExpression, netArcs, netPathText, netPlaces, netTransitions)
import Petrus.Net.Declared

-- | One sign, where it shows, and what to do about it.
data Finding = Finding
  { rule :: Text
  , at :: Text
  , message :: Text
  }
  deriving stock (Eq, Show)

renderFinding :: Finding -> Text
renderFinding f = f.rule <> " at " <> f.at <> ": " <> f.message

-- | The rules a waiver may accept. A mistake in the declarations, or a
-- waiver gone stale, is never waived: it is fixed.
waivable :: [Text]
waivable = ["single-token-s-net", "no-concurrency", "handler-choice", "undeclared-outcomes", "status-switch", "counted-resource", "lonely-place", "checked-once"]

-- | What the rules find, less what the waivers accept, with each waiver that
-- matches nothing, or names a rule no waiver may accept.
lint :: Net -> Declared -> [Waiver] -> [Finding]
lint net declared waivers =
  filter (not . waived) found
    <> [ Finding "stale-waiver" w.at ("no " <> w.rule <> " finding is left here to waive, so remove the waiver")
       | w <- waivers
       , w.rule `elem` waivable
       , not (any (matches w) found)
       ]
    <> [Finding "stale-waiver" w.at (w.rule <> " can't be waived: fix it instead") | w <- waivers, w.rule `notElem` waivable]
  where
    found = findings net declared
    matches w f = w.rule == f.rule && w.at == f.at
    waived f = f.rule `elem` waivable && any (`matches` f) [w | w <- waivers, w.rule `elem` waivable]

-- | Everything the rules find, before any waiver.
findings :: Net -> Declared -> [Finding]
findings net declared =
  concatMap ($ shape) [declarationMistakes declared, singleTokenSNet declared, noConcurrency, handlerChoice, undeclaredOutcomes declared, statusSwitch, countedResource, lonelyPlace declared, checkedOnce]
  where
    shape = shapeOf net declared

-- ---------------------------------------------------------------------------
-- The net's shape, by name

data Shape = Shape
  { places :: [Text]
  , transitions :: [Text]
  , consumes :: Map Text [(Text, Int)]
  , reads :: Map Text [Text]
  , inhibits :: Map Text [Text]
  , outputs :: Map Text [(Text, Int)]
  , filtered :: [(Text, Text, Text)]
  -- ^ Each filtered arc: its place, its transition, and its filter.
  , cels :: [(Text, Text)]
  -- ^ Each inline CEL guard and filter: its transition, and its text.
  , handled :: [Text]
  , outcomesOf :: Text -> [Outcome]
  }

shapeOf :: Net -> Declared -> Shape
shapeOf net declared =
  Shape
    { places
    , transitions
    , consumes = gather [(to, (from, a.weight)) | a <- arcs, a.mode == Consume, let from = name a.source; to = name a.target, from `elem` places]
    , reads = gather [(name a.target, name a.source) | a <- arcs, a.mode == Read]
    , inhibits = gather [(name a.target, name a.source) | a <- arcs, a.mode == Inhibit]
    , outputs
    , filtered = [(name a.source, name a.target, filterText f) | a <- arcs, Just f <- [a.filter]]
    , cels =
        [(name a.target, celExpression expression) | a <- arcs, Just (FilterCel expression) <- [a.filter]]
          <> [(name path, celExpression expression) | (path, t) <- Map.toList (netTransitions net), GuardCel expression <- t.guards]
    , handled = [name path | (path, t) <- Map.toList (netTransitions net), isJust t.handler]
    , outcomesOf = \t -> fromMaybe [Outcome {name = "fires", when = OnSuccess, puts = Map.fromListWith (+) (Map.findWithDefault [] t outputs)}] (Map.lookup t declared.outcomes)
    }
  where
    arcs = netArcs net
    name = netPathText
    places = map name (Map.keys (netPlaces net))
    transitions = map name (Map.keys (netTransitions net))
    outputs = gather [(name a.source, (name a.target, a.weight)) | a <- arcs, name a.source `elem` transitions]
    gather pairs = Map.fromListWith (flip (<>)) [(k, [v]) | (k, v) <- pairs]
    filterText = \case
      FilterSymbol s -> s
      FilterCel expression -> celExpression expression

at' :: Text -> Map Text [a] -> [a]
at' t = Map.findWithDefault [] t

inputsOf :: Shape -> Text -> [Text]
inputsOf s t = map fst (at' t s.consumes) <> at' t s.reads <> at' t s.inhibits

-- | A source: a transition with no input, which only deliveries fire.
deliveredOnly :: Shape -> Text -> Bool
deliveredOnly s t = null (inputsOf s t)

runsActivity :: Shape -> Text -> Bool
runsActivity s t = any (\o -> o.when == OnFailure) (s.outcomesOf t)

outputPlaces :: Shape -> Text -> [Text]
outputPlaces s t = nub (map fst (at' t s.outputs))

listed :: [Text] -> Text
listed = \case
  [] -> "nothing"
  [one] -> one
  many -> T.intercalate ", " (init many) <> " and " <> last many

-- ---------------------------------------------------------------------------
-- The rules

-- | Declarations that name what the net doesn't have.
declarationMistakes :: Declared -> Shape -> [Finding]
declarationMistakes declared s =
  [Finding "declaration" t "outcomes are declared for a transition the net doesn't have" | t <- Map.keys declared.outcomes, t `notElem` s.transitions]
    <> [ Finding "declaration" t ("its outcome " <> o.name <> " puts tokens in " <> p <> ", which isn't one of its output places")
       | (t, os) <- Map.toList declared.outcomes
       , t `elem` s.transitions
       , o <- os
       , p <- Map.keys o.puts
       , p `notElem` outputPlaces s t
       ]
    <> [Finding "declaration" p ("the " <> what <> " names a place the net doesn't have") | (what, ps) <- named, p <- ps, p `notElem` s.places]
    <> [ Finding "declaration" law.name ("counts " <> key <> ", but " <> T.drop 1 key <> " isn't a transition that runs an Activity")
       | law <- declared.laws
       , key <- Map.keys law.weights
       , "@" `T.isPrefixOf` key
       , let t = T.drop 1 key
       , t `notElem` s.transitions || not (runsActivity s t)
       ]
  where
    named =
      [("initial marking", Map.keys declared.initial), ("ingress", declared.ingress), ("final places", declared.finalPlaces)]
        <> [("final markings", Map.keys m) | m <- declared.finalMarkings]
        <> [("law " <> law.name, filter (not . ("@" `T.isPrefixOf`)) (Map.keys law.weights)) | law <- declared.laws]

-- | The marking collapsed into one token: each transition takes one token
-- and gives back at most one, and the net starts with at most one.
singleTokenSNet :: Declared -> Shape -> [Finding]
singleTokenSNet declared s
  | not (null steps)
      && all oneIn steps
      && all (\t -> all ((<= 1) . sum . (.puts)) (s.outcomesOf t)) steps
      && sum (Map.elems declared.initial) <= 1 =
      [ Finding
          "single-token-s-net"
          "net"
          "the marking has collapsed into one token: every transition takes one token and gives back at most one, so the process's state rides inside that token, and the net is a state machine. A net's state is its marking. Give each thing that happens at the same time its own token, each wait a join, and each scarce thing a place"
      ]
  | otherwise = []
  where
    steps = filter (not . deliveredOnly s) s.transitions
    oneIn t = case at' t s.consumes of
      [(_, 1)] -> True
      _ -> False

-- | No transition forks into two places or joins two.
noConcurrency :: Shape -> [Finding]
noConcurrency s
  | not (null s.transitions) && not (any joins s.transitions) && not (any forks s.transitions) =
      [ Finding
          "no-concurrency"
          "net"
          "no transition joins two places or forks into two, so nothing in this net waits on anything else, and nothing happens at the same time. A wait is a join: a transition that takes a token from each place it waits on"
      ]
  | otherwise = []
  where
    joins t = length (nub (map fst (at' t s.consumes))) >= 2
    forks t = any ((>= 2) . Map.size . Map.filter (> 0) . (.puts)) (s.outcomesOf t)

-- | A handler that fills one output place or another, by its own choice.
handlerChoice :: Shape -> [Finding]
handlerChoice s =
  [ Finding
      "handler-choice"
      t
      ( t
          <> "'s handler fills "
          <> T.intercalate ", or " (map (listed . Map.keys . Map.filter (> 0)) choices)
          <> ", one per firing. The choice lives in code, where the marking can't show it and no check can reach it. Make each branch a transition of its own, chosen by the marking: a guard, a filter, a read or an inhibitor arc. If it decides on data the marking can't hold, waive it and name that data"
      )
  | t <- s.transitions
  , let choices = nub [o.puts | o <- s.outcomesOf t, o.when == OnSuccess]
  , length choices >= 2
  ]

-- | A transition with two or more output places, and no word on which it
-- fills.
undeclaredOutcomes :: Declared -> Shape -> [Finding]
undeclaredOutcomes declared s =
  [ Finding
      "undeclared-outcomes"
      t
      ( t
          <> " has a handler and puts tokens in "
          <> listed (outputPlaces s t)
          <> ", but declares no outcomes, so nobody can tell whether it fills them together or chooses one. Declare its outcomes"
      )
  | t <- s.handled
  , length (outputPlaces s t) >= 2
  , not (Map.member t declared.outcomes)
  ]

-- | Tokens routed by a field of their data compared with constants.
statusSwitch :: Shape -> [Finding]
statusSwitch s = byFilters <> byFields
  where
    byFilters =
      [ Finding
          "status-switch"
          p
          ( listed (sort (nub [t | (_, t, _) <- arcs]))
              <> " take tokens from "
              <> p
              <> " by their filters, "
              <> listed (sort (nub [f | (_, _, f) <- arcs]))
              <> ". If the filters read where a token is in its process, the state lives in the token's data, not in the marking: give each state its own place. A kind fixed when the token is made and never rewritten isn't a status: waive it, and say so"
          )
      | p <- s.places
      , let arcs = [arc | arc@(from, _, _) <- s.filtered, from == p]
      , length (nub [f | (_, _, f) <- arcs]) >= 2
      ]
    byFields =
      [ Finding
          "status-switch"
          ("field " <> field)
          ( "guards and filters compare the token field "
              <> field
              <> " with "
              <> listed (sort constants)
              <> ", in "
              <> listed (sort (nub [t | (f, _, t) <- compared, f == field]))
              <> ". The process's state lives in the token's data, not in the marking: give each state its own place"
          )
      | field <- nub [f | (f, _, _) <- compared]
      , let constants = nub [c | (f, c, _) <- compared, f == field]
      , length constants >= 2
      ]
    compared =
      [ (field, constant, t)
      | (t, expression) <- s.cels
      , Right parsed <- [parseCel expression]
      , (op, l, r) <- comparisons parsed
      , op `elem` [RelEq, RelNe, RelIn]
      , (field, constant) <- fieldAndConstants l r
      ]
    fieldAndConstants l r = case operandOf l of
      Just left -> [(f, c) | Just f <- [fieldOf left], c <- constantsOf r] <> [(f, c) | Just f <- [fieldOf r], c <- constantsOf left]
      Nothing -> []

-- | A count kept inside a token: a field compared by size.
countedResource :: Shape -> [Finding]
countedResource s =
  [ Finding
      "counted-resource"
      t
      ( t
          <> " compares the token field "
          <> field
          <> " by size, which counts something inside a token. A scarce thing is tokens in a place, which a transition takes and gives back, and the marking shows how many are left"
      )
  | (t, field) <- nub found
  ]
  where
    found =
      [ (t, field)
      | (t, expression) <- s.cels
      , Right parsed <- [parseCel expression]
      , (op, l, r) <- comparisons parsed
      , op `elem` [RelLt, RelLe, RelGe, RelGt]
      , field <- maybe [] fieldsIn (operandOf l) <> fieldsIn r
      ]

-- | A place nothing fills, or nothing empties or checks.
lonelyPlace :: Declared -> Shape -> [Finding]
lonelyPlace declared s =
  [ Finding "lonely-place" p (p <> what <> ". Every place a token passes through is filled by a transition, by the initial marking, or by a caller as declared ingress, and is emptied by another, checked by a read or inhibitor arc as a standing fact, or declared a final place")
  | p <- s.places
  , p `notElem` declared.finalPlaces
  , let filled = p `elem` declared.ingress || Map.findWithDefault 0 p declared.initial > 0 || any (\t -> p `elem` outputPlaces s t) s.transitions
        emptied = any (\t -> p `elem` map fst (at' t s.consumes) || p `elem` at' t s.reads || p `elem` at' t s.inhibits) s.transitions
  , Just what <- [lonely filled emptied]
  ]
  where
    lonely filled emptied = case (filled, emptied) of
      (True, True) -> Nothing
      (True, False) -> Just " is filled but never emptied"
      (False, True) -> Just " is emptied but nothing fills it"
      (False, False) -> Just " is never filled, emptied or checked"

-- | A read or inhibitor arc on a transition that runs an Activity: it holds
-- only when the transition fires, not while the Activity runs.
checkedOnce :: Shape -> [Finding]
checkedOnce s =
  [ Finding
      "checked-once"
      t
      ( t
          <> " runs an Activity, and checks "
          <> listed (map (<> " (read)") (at' t s.reads) <> map (<> " (inhibitor)") (at' t s.inhibits))
          <> " only when it fires. Petrus doesn't hold a read or an inhibitor while the Activity runs, so the condition can change before it ends. Take a token to hold it, or check again where the Activity's outcome joins"
      )
  | t <- s.transitions
  , runsActivity s t
  , not (null (at' t s.reads) && null (at' t s.inhibits))
  ]

-- ---------------------------------------------------------------------------
-- CEL: the comparisons in an expression

comparisons :: Expr -> [(RelOp, Relation, Addition)]
comparisons (Expr c rest) = inOr c <> foldMap (\(m, r) -> inOr m <> comparisons r) rest
  where
    inOr = \case
      OrBase a -> inAnd a
      Or l r -> inOr l <> inAnd r
    inAnd = \case
      AndBase r -> inRel r
      And l r -> inAnd l <> inRel r
    inRel = \case
      RelBase a -> inAdd a
      Rel op l r -> (op, l, r) : inRel l <> inAdd r
    inAdd = \case
      AddBase m -> inMul m
      Add _ l r -> inAdd l <> inMul r
    inMul = \case
      MulBase u -> inUnary u
      Mul _ l r -> inMul l <> inUnary r
    inUnary = \case
      UnaryMember m -> inMember m
      UnaryNot u -> inUnary u
      UnaryNeg u -> inUnary u
    inMember = \case
      MemberPrimary p -> inPrimary p
      MemberDot m _ -> inMember m
      MemberDotArg m _ args -> inMember m <> inList args
      MemberIndex m e -> inMember m <> comparisons e
      MemberObject m fields -> inMember m <> foldMap (foldMap (comparisons . snd)) fields
    inPrimary = \case
      PrimaryDotIdentArg _ args -> inList args
      PrimaryIdentArg _ args -> inList args
      PrimaryParen e -> comparisons e
      PrimaryList args -> inList args
      PrimaryMap inits -> foldMap (foldMap (\(k, v) -> comparisons k <> comparisons v)) inits
      _ -> []
    inList = foldMap (foldMap comparisons)

-- | The left side of a comparison, when it is a plain operand.
operandOf :: Relation -> Maybe Addition
operandOf = \case
  RelBase a -> Just a
  Rel {} -> Nothing

memberOf :: Addition -> Maybe Member
memberOf = \case
  AddBase (MulBase (UnaryMember m)) -> Just m
  _ -> Nothing

-- | The field an operand reads: @token.status@ or @token["status"]@.
fieldOf :: Addition -> Maybe Text
fieldOf a = memberOf a >>= \case
  MemberDot _ field -> Just field
  MemberIndex _ e | [c] <- constantsOfExpr e -> Just (T.dropAround (`elem` ("\"'" :: String)) c)
  _ -> Nothing

-- | Every field an arithmetic operand reads.
fieldsIn :: Addition -> [Text]
fieldsIn = \case
  AddBase m -> inMul m
  Add _ l r -> fieldsIn l <> inMul r
  where
    inMul = \case
      MulBase u -> inUnary u
      Mul _ l r -> inMul l <> inUnary r
    inUnary = \case
      UnaryMember m -> maybe [] pure (fieldOf (AddBase (MulBase (UnaryMember m))))
      UnaryNot u -> inUnary u
      UnaryNeg u -> inUnary u

-- | The constants an operand is: one literal, or a list of them.
constantsOf :: Addition -> [Text]
constantsOf a = case memberOf a of
  Just (MemberPrimary (PrimaryLiteral lit)) -> [literalText lit]
  Just (MemberPrimary (PrimaryList (Just items))) -> concatMap constantsOfExpr (toList items)
  _ -> []

constantsOfExpr :: Expr -> [Text]
constantsOfExpr = \case
  Expr (OrBase (AndBase (RelBase a))) Nothing -> constantsOf a
  _ -> []
