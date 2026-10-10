-- | A test-local CEL compiler for the Instance specs that use inline CEL
-- guards and completion conditions.
--
-- The kernel never evaluates CEL: it hands each inline declaration to the
-- 'CelCompilers' seam with the scope it computed (a guard's consume/read
-- input places; the net's places for a completion) and refuses
-- construction with the compiler's 'Left' verbatim. The reference's adapter
-- is @petrus.impetus.binding.cel@; CEL itself is a separate package in the
-- Haskell port. This stub recognises exactly the expression strings the
-- ported tests use, declares each one's free variables, checks them against
-- the scope the kernel passed (so the kernel's scope computation is what is
-- under test), and answers with the reference adapter's messages. Any other
-- expression is refused, so a test cannot silently pass through the stub.
module Petrus.Impetus.CelStub
  ( celStub
  ) where

import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Impetus.Binding (CelCompilers (..), Completion)
import Petrus.Impetus.Internal.Repr (pyList, pyStr)
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))

-- | The place-keyed guard environment: each input place bound to the
-- binding's selected tokens from it, consumed selections first, read after.
type GuardEnvironment = Map.Map Text [Token]

guardEnvironment :: Binding -> GuardEnvironment
guardEnvironment b = Map.fromListWith (flip (++)) [(netPathText p, ts) | (p, ts) <- b.consumed ++ b.read]

-- | @name[0].data.key@ as an integer, with the reference adapter's
-- evaluation error for a black token (data @null@).
dataField :: Text -> Text -> GuardEnvironment -> Either Text Integer
dataField name key environment = case Map.findWithDefault [] name environment of
  t : _ -> case t.payload of
    Object members | Just (Int n) <- lookup key members -> Right n
    Null ->
      Left
        ( "CELEvalError(*(\"None with type: '<class 'NoneType'>' does not support field selection\", <class 'TypeError'>, None), tree="
            <> pyStr (name <> "[0].data." <> key)
            <> ")"
        )
    _ -> Left ("CELEvalError(no such member " <> pyStr key <> ")")
  [] -> Left "CELEvalError(index out of range)"

-- | @name[0].color == null@.
firstColorIsNull :: Text -> GuardEnvironment -> Either Text Bool
firstColorIsNull name environment = case Map.findWithDefault [] name environment of
  t : _ -> Right (t.color == Nothing)
  [] -> Left "CELEvalError(index out of range)"

-- | Each known guard expression: its free variables and its evaluation.
knownGuards :: Map.Map Text ([Text], GuardEnvironment -> Either Text Bool)
knownGuards =
  Map.fromList
    [ ("pending[0].data.amount >= 100", (["pending"], \e -> (>= 100) <$> dataField "pending" "amount" e))
    , ("pending[0].data.amount < 100", (["pending"], \e -> (< 100) <$> dataField "pending" "amount" e))
    , ( "pending[0].data.amount <= config[0].data.limit"
      , (["pending", "config"], \e -> (<=) <$> dataField "pending" "amount" e <*> dataField "config" "limit" e)
      )
    , ("p[0].data.n > 0", (["p"], \e -> (> 0) <$> dataField "p" "n" e))
    , ("p[0].data.n > 9", (["p"], \e -> (> 9) <$> dataField "p" "n" e))
    , ("p[0].data.n < 9", (["p"], \e -> (< 9) <$> dataField "p" "n" e))
    , ("p[0].data.amount >= 100", (["p"], \e -> (>= 100) <$> dataField "p" "amount" e))
    , ("size(out) == 0", (["out"], \e -> Right (null (Map.findWithDefault [] "out" e))))
    , ("size(q) == 0", (["q"], \e -> Right (null (Map.findWithDefault [] "q" e))))
    , ("p[0].color == null", (["p"], firstColorIsNull "p"))
    , ("q[0].color == null", (["q"], firstColorIsNull "q"))
    ]

-- | The reference's parse errors (the @celpy@ caret rendering), verbatim.
parseErrors :: Map.Map Text Text
parseErrors =
  Map.fromList
    [ ("p[0].data.amount >=", "p[0].data.amount >=\n                 ^\n")
    , ("size(b) ==", "size(b) ==\n        ^\n")
    ]

compileGuardStub :: Cel -> NetPath -> Set NetPath -> Either Text Guard
compileGuardStub declaration at scope = do
  let expression = celExpression declaration
  invalid expression "guard"
  (free, evaluate) <- maybe (unknownExpression expression) Right (Map.lookup expression knownGuards)
  let inScope = Set.map netPathText scope
      outside = sort [n | n <- free, not (Set.member n inScope)]
  if null outside
    then Right (evaluate . guardEnvironment)
    else
      Left
        ( "CEL guard " <> pyStr expression <> " on transition " <> netPathText at
            <> " references name(s) outside its consume/read input places "
            <> pyList (map pyStr (sort (Set.toList inScope)))
            <> ": "
            <> pyList (map pyStr outside)
        )

-- | Each known completion expression: its free variables and its
-- evaluation over the marking (@size(place)@ is the place's queue length).
knownCompletions :: Map.Map Text ([Text], Marking -> Either Text Bool)
knownCompletions =
  Map.fromList
    [ ("size(b) == 1", (["b"], \m -> Right (size "b" m == 1)))
    , ("size(b) >= 2", (["b"], \m -> Right (size "b" m >= 2)))
    , ("size(a) == 1", (["a"], \m -> Right (size "a" m == 1)))
    , ("size(doen) > 0", (["doen"], \m -> Right (size "doen" m > 0)))
    ]
  where
    size name m = length (placeTokens (either (error . show) id (netPath name)) m)

compileCompletionStub :: Cel -> [NetPath] -> Either Text Completion
compileCompletionStub declaration places = do
  let expression = celExpression declaration
  invalid expression "completion"
  (free, evaluate) <- maybe (unknownExpression expression) Right (Map.lookup expression knownCompletions)
  let unknown = sort [n | n <- free, n `notElem` map netPathText places]
  if null unknown
    then Right evaluate
    else Left ("CEL completion " <> pyStr expression <> " references unknown place(s): " <> pyList (map pyStr unknown))

invalid :: Text -> Text -> Either Text ()
invalid expression kind = case Map.lookup expression parseErrors of
  Just rendered -> Left ("invalid CEL " <> kind <> " " <> pyStr expression <> ": " <> rendered)
  Nothing -> Right ()

unknownExpression :: Text -> Either Text a
unknownExpression expression = Left ("CEL stub: no stub for expression " <> pyStr expression)

-- | The stub compilers (inline filters are not used by these specs).
celStub :: CelCompilers
celStub =
  CelCompilers
    { compileGuard = compileGuardStub
    , compileFilter = unknownExpression . celExpression
    , compileCompletion = compileCompletionStub
    }
