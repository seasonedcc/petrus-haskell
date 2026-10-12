-- | The typed syntax tree of a CEL expression.
--
-- The tree mirrors cel-python's lark grammar level by level (@expr@,
-- @conditionalor@, @conditionaland@, @relation@, @addition@,
-- @multiplication@, @unary@, @member@, @primary@): cel-python's results depend
-- on that exact shape (which sub-tree a ternary's middle is, what a macro's
-- first argument contains, which node an error is attached to), so the
-- grammar's quirks are kept in the types. For example the middle of a ternary
-- is a 'ConditionalOr', not an 'Expr', exactly as in cel-python's grammar.
--
-- 'toLark' projects a tree onto lark's generic shape, which is what
-- cel-python's own tree walks (@find_data@, @tree_dump@, error reprs) see.
module Petrus.Cel.Syntax
  ( -- * Expressions
    Expr (..)
  , ConditionalOr (..)
  , ConditionalAnd (..)
  , Relation (..)
  , RelOp (..)
  , Addition (..)
  , AddOp (..)
  , Multiplication (..)
  , MulOp (..)
  , Unary (..)
  , Member (..)
  , Primary (..)
  , ExprList
  , FieldInits
  , MapInits
  , Literal (..)
  , Ident
    -- * Lark projection
  , LarkTree (..)
  , LarkChild (..)
  , toLark
  , larkText
  , larkRepr
  , treeDump
  , findIdents
    -- * Node projections
  , exprNode
  , orNode
  , andNode
  , relNode
  , addNode
  , mulNode
  , unaryNode
  , memberNode
  , primaryNode
  , literalNode
  , relOpRule
  , addOpRule
  , mulOpRule
  ) where

import Data.Foldable (foldlM, toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as T

import Petrus.Cel.Literal (LiteralKind, LiteralValue, literalTokenType)
import Petrus.Json.Python (pythonStrRepr)

-- | An identifier token.
type Ident = Text

-- | @expr: conditionalor ["?" conditionalor ":" expr]@
data Expr = Expr ConditionalOr (Maybe (ConditionalOr, Expr))
  deriving stock (Eq, Show)

-- | @conditionalor: [conditionalor "||"] conditionaland@
data ConditionalOr
  = OrBase ConditionalAnd
  | Or ConditionalOr ConditionalAnd
  deriving stock (Eq, Show)

-- | @conditionaland: [conditionaland "&&"] relation@
data ConditionalAnd
  = AndBase Relation
  | And ConditionalAnd Relation
  deriving stock (Eq, Show)

-- | @relation: [relation_op] addition@
data Relation
  = RelBase Addition
  | Rel RelOp Relation Addition
  deriving stock (Eq, Show)

-- | Relational operators (@<@, @<=@, @>=@, @>@, @==@, @!=@, @in@).
data RelOp = RelLt | RelLe | RelGe | RelGt | RelEq | RelNe | RelIn
  deriving stock (Eq, Show, Enum, Bounded)

-- | @addition: [addition_op] multiplication@
data Addition
  = AddBase Multiplication
  | Add AddOp Addition Multiplication
  deriving stock (Eq, Show)

-- | Additive operators.
data AddOp = AddPlus | AddMinus
  deriving stock (Eq, Show, Enum, Bounded)

-- | @multiplication: [multiplication_op] unary@
data Multiplication
  = MulBase Unary
  | Mul MulOp Multiplication Unary
  deriving stock (Eq, Show)

-- | Multiplicative operators.
data MulOp = MulTimes | MulDiv | MulMod
  deriving stock (Eq, Show, Enum, Bounded)

-- | @unary: member | "!" unary | "-" unary@
data Unary
  = UnaryMember Member
  | UnaryNot Unary
  | UnaryNeg Unary
  deriving stock (Eq, Show)

-- | @member: member_dot | member_dot_arg | member_index | member_object | primary@
data Member
  = MemberPrimary Primary
  | -- | @member "." IDENT@
    MemberDot Member Ident
  | -- | @member "." IDENT "(" [exprlist] ")"@
    MemberDotArg Member Ident (Maybe ExprList)
  | -- | @member "[" expr "]"@
    MemberIndex Member Expr
  | -- | @member "{" [fieldinits] "}"@
    MemberObject Member (Maybe FieldInits)
  deriving stock (Eq, Show)

-- | @primary@ alternatives.
data Primary
  = PrimaryLiteral Literal
  | -- | @"." IDENT "(" [exprlist] ")"@
    PrimaryDotIdentArg Ident (Maybe ExprList)
  | -- | @"." IDENT@
    PrimaryDotIdent Ident
  | -- | @IDENT "(" [exprlist] ")"@
    PrimaryIdentArg Ident (Maybe ExprList)
  | PrimaryParen Expr
  | PrimaryList (Maybe ExprList)
  | PrimaryMap (Maybe MapInits)
  | PrimaryIdent Ident
  deriving stock (Eq, Show)

-- | @exprlist: expr ("," expr)*@
type ExprList = NonEmpty Expr

-- | @fieldinits: IDENT ":" expr ("," IDENT ":" expr)*@
type FieldInits = NonEmpty (Ident, Expr)

-- | @mapinits: expr ":" expr ("," expr ":" expr)*@
type MapInits = NonEmpty (Expr, Expr)

-- | A literal token: its kind, its exact source text, and its cooked value
-- (computed once, at parse time).
data Literal = Literal
  { literalKind :: LiteralKind
  , literalText :: Text
  , literalValue :: LiteralValue
  }
  deriving stock (Eq, Show)

-- | A lark tree: rule name and children.
data LarkTree = LarkTree Text [LarkChild]
  deriving stock (Eq, Show)

-- | A lark child: a sub-tree or a named token (type, value).
data LarkChild
  = LarkNode LarkTree
  | LarkToken Text Text
  deriving stock (Eq, Show)

-- | The lark rule name of a relational operator node.
relOpRule :: RelOp -> Text
relOpRule = \case
  RelLt -> "relation_lt"
  RelLe -> "relation_le"
  RelGe -> "relation_ge"
  RelGt -> "relation_gt"
  RelEq -> "relation_eq"
  RelNe -> "relation_ne"
  RelIn -> "relation_in"

-- | The lark rule name of an additive operator node.
addOpRule :: AddOp -> Text
addOpRule = \case
  AddPlus -> "addition_add"
  AddMinus -> "addition_sub"

-- | The lark rule name of a multiplicative operator node.
mulOpRule :: MulOp -> Text
mulOpRule = \case
  MulTimes -> "multiplication_mul"
  MulDiv -> "multiplication_div"
  MulMod -> "multiplication_mod"

node :: Text -> [LarkChild] -> LarkChild
node rule children = LarkNode (LarkTree rule children)

ident :: Text -> LarkChild
ident = LarkToken "IDENT"

asTree :: LarkChild -> LarkTree
asTree = \case
  LarkNode t -> t
  LarkToken ty _ -> LarkTree ty []

-- | The lark node of an @expr@.
exprNode :: Expr -> LarkTree
exprNode = asTree . exprL

-- | The lark node of a @conditionalor@.
orNode :: ConditionalOr -> LarkTree
orNode = asTree . orL

-- | The lark node of a @conditionaland@.
andNode :: ConditionalAnd -> LarkTree
andNode = asTree . andL

-- | The lark node of a @relation@.
relNode :: Relation -> LarkTree
relNode = asTree . relL

-- | The lark node of an @addition@.
addNode :: Addition -> LarkTree
addNode = asTree . addL

-- | The lark node of a @multiplication@.
mulNode :: Multiplication -> LarkTree
mulNode = asTree . mulL

-- | The lark node of a @unary@.
unaryNode :: Unary -> LarkTree
unaryNode = asTree . unaryL

-- | The lark node of a member form (@member_dot@, @member_index@, ...; a
-- 'MemberPrimary' gives its @primary@ node).
memberNode :: Member -> LarkTree
memberNode = asTree . memberInner

-- | The lark node of a @primary@.
primaryNode :: Primary -> LarkTree
primaryNode = asTree . primaryL

-- | The lark @literal@ node of a literal.
literalNode :: Literal -> LarkTree
literalNode lit = LarkTree "literal" [LarkToken (literalTokenType (literalKind lit)) (literalText lit)]

-- | The lark tree cel-python's parser builds for an expression.
toLark :: Expr -> LarkTree
toLark e = case exprL e of
  LarkNode t -> t
  LarkToken _ _ -> LarkTree "expr" []

exprL :: Expr -> LarkChild
exprL (Expr c rest) = node "expr" $ case rest of
  Nothing -> [orL c]
  Just (m, r) -> [orL c, orL m, exprL r]

orL :: ConditionalOr -> LarkChild
orL = \case
  OrBase a -> node "conditionalor" [andL a]
  Or l r -> node "conditionalor" [orL l, andL r]

andL :: ConditionalAnd -> LarkChild
andL = \case
  AndBase r -> node "conditionaland" [relL r]
  And l r -> node "conditionaland" [andL l, relL r]

relL :: Relation -> LarkChild
relL = \case
  RelBase a -> node "relation" [addL a]
  Rel op l r -> node "relation" [node (relOpRule op) [relL l], addL r]

addL :: Addition -> LarkChild
addL = \case
  AddBase m -> node "addition" [mulL m]
  Add op l r -> node "addition" [node (addOpRule op) [addL l], mulL r]

mulL :: Multiplication -> LarkChild
mulL = \case
  MulBase u -> node "multiplication" [unaryL u]
  Mul op l r -> node "multiplication" [node (mulOpRule op) [mulL l], unaryL r]

unaryL :: Unary -> LarkChild
unaryL = \case
  UnaryMember m -> node "unary" [memberL m]
  UnaryNot u -> node "unary" [node "unary_not" [], unaryL u]
  UnaryNeg u -> node "unary" [node "unary_neg" [], unaryL u]

memberL :: Member -> LarkChild
memberL m = node "member" [memberInner m]

memberInner :: Member -> LarkChild
memberInner = \case
  MemberPrimary p -> primaryL p
  MemberDot m name -> node "member_dot" [memberL m, ident name]
  MemberDotArg m name args -> node "member_dot_arg" ([memberL m, ident name] <> exprListL args)
  MemberIndex m e -> node "member_index" [memberL m, exprL e]
  MemberObject m fields -> node "member_object" ([memberL m] <> maybe [] (pure . fieldInitsL) fields)

exprListL :: Maybe ExprList -> [LarkChild]
exprListL = maybe [] (\es -> [node "exprlist" (map exprL (toList es))])

fieldInitsL :: FieldInits -> LarkChild
fieldInitsL fields = node "fieldinits" (concat [[ident name, exprL e] | (name, e) <- toList fields])

primaryL :: Primary -> LarkChild
primaryL p = node "primary" [inner]
  where
    inner = case p of
      PrimaryLiteral lit -> node "literal" [LarkToken (literalTokenType (literalKind lit)) (literalText lit)]
      PrimaryDotIdentArg name args -> node "dot_ident_arg" (ident name : exprListL args)
      PrimaryDotIdent name -> node "dot_ident" [ident name]
      PrimaryIdentArg name args -> node "ident_arg" (ident name : exprListL args)
      PrimaryParen e -> node "paren_expr" [exprL e]
      PrimaryList args -> node "list_lit" (exprListL args)
      PrimaryMap inits ->
        node "map_lit" (maybe [] (\kvs -> [node "mapinits" (concat [[exprL k, exprL v] | (k, v) <- toList kvs])]) inits)
      PrimaryIdent name -> node "ident" [ident name]

-- | The compact s-expression the corpus records for a tree:
-- @(rule child ...)@ with tokens as @TYPE"value"@ (JSON string syntax).
larkText :: LarkTree -> Text
larkText = T.concat . go
  where
    go (LarkTree rule children) = ["(", rule] <> concatMap child children <> [")"]
    child = \case
      LarkNode t -> " " : go t
      LarkToken ty value -> [" ", ty, jsonString value]

-- | Python's @json.dumps(text, ensure_ascii=False)@.
jsonString :: Text -> Text
jsonString t = "\"" <> T.concatMap esc t <> "\""
  where
    esc = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      '\b' -> "\\b"
      '\f' -> "\\f"
      c
        | c < ' ' -> T.pack ("\\u00" <> [hexDigit (fromEnum c `div` 16), hexDigit (fromEnum c `mod` 16)])
        | otherwise -> T.singleton c
    hexDigit n = "0123456789abcdef" !! n

-- | Python's @repr()@ of a lark tree:
-- @Tree(Token('RULE', 'name'), [children])@, tokens as @Token('TYPE', 'value')@.
larkRepr :: LarkChild -> Text
larkRepr = \case
  LarkNode (LarkTree rule children) ->
    "Tree(Token('RULE', " <> pythonStrRepr rule <> "), [" <> T.intercalate ", " (map larkRepr children) <> "])"
  LarkToken ty value -> "Token(" <> pythonStrRepr ty <> ", " <> pythonStrRepr value <> ")"

-- | celpy's @tree_dump@ (its @DumpAST@ visitor): a lossy, stack-based
-- re-rendering of a tree used inside @CELEvalError@ reprs. The visitor's
-- quirks are reproduced: @[]@ inside a larger expression wraps the previous
-- stack entry, and a message's field names are paired with its values in
-- reverse. So is its failure: where the visitor pops an empty stack, or
-- reads the first entry of one, Python raises @IndexError@, and 'Left'
-- carries that error's message.
treeDump :: LarkTree -> Either Text Text
treeDump t = visit t [] >>= \case
  x : _ -> Right x
  [] -> Left "list index out of range"
  where
    visit :: LarkTree -> [Text] -> Either Text [Text]
    visit tree@(LarkTree _ children) stack = do
      stack' <- foldlM (\s c -> case c of LarkNode sub -> visit sub s; LarkToken _ _ -> Right s) stack children
      step tree stack'
    tokenAt i children = case drop i children of
      LarkToken _ v : _ -> v
      _ -> ""
    pop = \case
      x : rest -> Right (x, rest)
      [] -> Left "pop from empty list"
    pops n stack
      | n <= (0 :: Int) = Right ([], stack)
      | otherwise = do
          (x, s1) <- pop stack
          (xs, s2) <- pops (n - 1) s1
          Right (x : xs, s2)
    binary sep stack = do
      (right, s1) <- pop stack
      (left, s2) <- pop s1
      Right ((left <> sep <> right) : s2)
    suffix s stack = do
      (left, rest) <- pop stack
      Right ((left <> s) : rest)
    -- @[f(x) for x in children if ...]@ only when the rule has more than one
    -- child: a single child is passed through.
    combining children f stack
      | length children == 1 = Right stack
      | otherwise = f stack
    optionalPop present stack = if present then pop stack else Right ("", stack)
    step (LarkTree rule children) stack = case rule of
      "expr" -> flip (combining children) stack $ \s -> do
        (right, s1) <- pop s
        (left, s2) <- pop s1
        (cond, s3) <- pop s2
        Right ((cond <> " ? " <> left <> " : " <> right) : s3)
      "conditionalor" -> combining children (binary " || ") stack
      "conditionaland" -> combining children (binary " && ") stack
      "relation" -> combining children (binary " ") stack
      "addition" -> combining children (binary " ") stack
      "multiplication" -> combining children (binary " ") stack
      "unary" -> combining children (binary " ") stack
      "relation_lt" -> suffix " < " stack
      "relation_le" -> suffix " <= " stack
      "relation_gt" -> suffix " > " stack
      "relation_ge" -> suffix " >= " stack
      "relation_eq" -> suffix " == " stack
      "relation_ne" -> suffix " != " stack
      "relation_in" -> suffix " in " stack
      "addition_add" -> suffix " + " stack
      "addition_sub" -> suffix " - " stack
      "multiplication_mul" -> suffix " * " stack
      "multiplication_div" -> suffix " / " stack
      "multiplication_mod" -> suffix " % " stack
      "unary_not" -> Right ("!" : stack)
      "unary_neg" -> Right ("-" : stack)
      "member_dot" -> Right $ case stack of
        left : rest -> (left <> "." <> tokenAt 1 children) : rest
        [] -> []
      "member_dot_arg" -> do
        (args, s1) <- optionalPop (length children == 3) stack
        (left, s2) <- pop s1
        Right ((left <> "." <> tokenAt 1 children <> "(" <> args <> ")") : s2)
      "member_index" -> do
        (right, s1) <- pop stack
        (left, s2) <- pop s1
        Right ((left <> "[" <> right <> "]") : s2)
      "member_object" -> do
        (fields, s1) <- optionalPop (length children == 2) stack
        (left, s2) <- pop s1
        Right ((left <> "{" <> fields <> "}") : s2)
      "dot_ident_arg" -> do
        (args, s1) <- optionalPop (length children == 2) stack
        Right (("." <> tokenAt 0 children <> "(" <> args <> ")") : s1)
      "dot_ident" -> Right (("." <> tokenAt 0 children) : stack)
      "ident_arg" -> do
        (args, s1) <- optionalPop (length children == 2) stack
        Right ((tokenAt 0 children <> "(" <> args <> ")") : s1)
      "ident" -> Right (tokenAt 0 children : stack)
      "paren_expr" -> Right $ case stack of
        left : rest -> ("(" <> left <> ")") : rest
        [] -> []
      "list_lit" -> Right $ case stack of
        left : rest -> ("[" <> left <> "]") : rest
        [] -> [""]
      "map_lit" -> Right $ case stack of
        left : rest -> ("{" <> left <> "}") : rest
        [] -> ["{}"]
      "exprlist" -> do
        (items, rest) <- pops (length children) stack
        Right (T.intercalate ", " (reverse items) : rest)
      "fieldinits" -> do
        -- Each name is paired with the next value popped (the last value
        -- first), and the pairs are then reversed.
        let names = [v | (i, LarkToken _ v) <- zip [0 :: Int ..] children, even i]
            pairs = length children `div` 2
        (values, rest) <- pops pairs stack
        Right (T.intercalate ", " (reverse [name <> ": " <> value | (name, value) <- zip names values]) : rest)
      "mapinits" -> do
        -- Each pair pops its value, then its key; the pairs are then reversed.
        (popped, rest) <- pops (2 * (length children `div` 2)) stack
        Right (T.intercalate ", " (reverse [k <> ": " <> v | (k, v) <- pairUp popped]) : rest)
      "literal" -> Right $ case children of
        LarkToken _ v : _ -> v : stack
        _ -> stack
      _ -> Right stack
    pairUp = \case
      v : k : rest -> (k, v) : pairUp rest
      _ -> []

-- | The @ident@ nodes of a tree in lark's @iter_subtrees@ order (deepest
-- level first, left to right within a level): the order of
-- @tree.find_data("ident")@.
findIdents :: LarkTree -> [Text]
findIdents root = concatMap identsOf (reverse levels)
  where
    levels = takeWhile (not . null) (iterate (concatMap subtrees) [root])
    subtrees (LarkTree _ children) = [t | LarkNode t <- children]
    identsOf = concatMap $ \case
      LarkTree "ident" (LarkToken _ name : _) -> [name]
      _ -> []
