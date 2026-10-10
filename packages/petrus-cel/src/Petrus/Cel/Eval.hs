-- | cel-python's tree-walking evaluator (@celpy.evaluation.Evaluator@),
-- reproduced node by node.
--
-- cel-python keeps two error channels: a @CELEvalError@ /value/ that flows
-- through operators (absorbed by @||@ and @&&@ where the other side decides,
-- returned first by functions), and Python exceptions /raised/ out of an
-- operation, which each node catches only for the classes it names
-- (@TypeError@ at an operator becomes "found no matching overload ...", a
-- @KeyError@ at an index becomes "no such key", and so on) while every other
-- raise unwinds to the caller. Here the value channel is a 'VError' and the
-- raise channel is the @Left@ of 'Either' 'Exc', and every catch site
-- catches exactly what cel-python's does, so where an error surfaces, its
-- text, and whether it is a CEL error or a Python exception all match.
--
-- Deviations from the CEL specification that cel-python makes and this
-- module therefore reproduces include: a ternary's condition is tested for
-- Python truthiness before its type is checked; field initialisers evaluate
-- both branches of a ternary value and keep the condition
-- (@int{value: false ? 1 : 2}@ is 0); macros over a non-list iterate
-- whatever Python would (a map's keys, a string's characters); @all@ and
-- @exists@ can return a non-boolean; and identifiers fall back to the
-- function table (@size@ evaluates to the function itself).
module Petrus.Cel.Eval
  ( -- * Activations
    Activation
  , baseActivation
  , bindValues
  , validName
    -- * Evaluation
  , evaluate
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T

import Petrus.Cel.Literal (LiteralValue (..))
import Petrus.Cel.Ops
import Petrus.Cel.Python
import Petrus.Cel.Syntax
import Petrus.Cel.Value

-- ---------------------------------------------------------------------------
-- Activations

-- | The names an expression evaluates against: cel-python's activation
-- identifiers (one 'NameContainer'; the function table is fixed).
newtype Activation = Activation NameContainer

-- | The activation of a fresh @celpy.Environment()@: the well-known
-- @google.protobuf@ wrapper types as annotations.
baseActivation :: Activation
baseActivation = Activation [("google", containerReferent [("protobuf", containerReferent protobuf)])]
  where
    containerReferent c = emptyReferent {referentContainer = Just c}
    annotated cls = emptyReferent {referentAnnotation = Just cls}
    protobuf =
      [ ("Int32Value", annotated CIntType)
      , ("UInt32Value", annotated CUintType)
      , ("Int64Value", annotated CIntType)
      , ("UInt64Value", annotated CUintType)
      , ("FloatValue", annotated CDoubleType)
      , ("DoubleValue", annotated CDoubleType)
      , ("BoolValue", annotated CBoolType)
      , ("BytesValue", annotated CBytesType)
      , ("StringValue", annotated CStringType)
      , ("ListValue", annotated CListType)
      , ("Struct", annotated CMessageType)
      ]

-- | Does the name pass @NameContainer.load_values@' check
-- (@^\\.?IDENT(?:\\.IDENT)*$@, where @$@ also matches before a final
-- newline)?
validName :: Text -> Bool
validName name =
  let body = maybe name id (T.stripSuffix "\n" name)
      body' = maybe body id (T.stripPrefix "." body)
   in not (T.null body') && all validIdent (T.splitOn "." body')
  where
    validIdent t = case T.uncons t of
      Just (c, rest) -> (c == '_' || isAsciiLower c || isAsciiUpper c) && T.all identChar rest
      Nothing -> False
    identChar c = c == '_' || isAsciiLower c || isAsciiUpper c || isDigit c

-- | The identifiers @ident_pat.findall@ splits a valid name into.
nameParts :: Text -> [Text]
nameParts name = filter (not . T.null) (T.split (\c -> c == '.' || c == '\n') name)

-- | @NameContainer.load_values@: bind each name (a dotted name creates the
-- intermediate containers), in order. An invalid name raises
-- @ValueError: Invalid name ...@.
bindValues :: [(Text, Value)] -> Activation -> Either Exc Activation
bindValues values (Activation names) = Activation <$> foldl step (Right names) values
  where
    step acc (name, value) = do
      c <- acc
      if validName name
        then Right (load c (nameParts name) value)
        else Left (pyExc ValueError ("Invalid name " <> name))

load :: NameContainer -> [Text] -> Value -> NameContainer
load c path value = case path of
  [] -> c
  [final] -> upsert final (\r -> r {referentSetValue = Just value}) c
  p : rest -> upsert p (\r -> r {referentContainer = Just (load (maybe [] id (referentContainer r)) rest value)}) c

upsert :: Text -> (Referent -> Referent) -> NameContainer -> NameContainer
upsert key f = go
  where
    go = \case
      [] -> [(key, f emptyReferent)]
      (k, r) : rest
        | k == key -> (k, f r) : rest
        | otherwise -> (k, r) : go rest

-- | @Activation.resolve_variable@: an identifier, else a function.
resolveVariable :: Activation -> Text -> Maybe Value
resolveVariable (Activation names) name = case lookup name names of
  Just r -> Just (referentValue r)
  Nothing -> resolveFunction name

-- ---------------------------------------------------------------------------
-- Evaluation

type Result = Either Exc Value

-- | @Evaluator.evaluate@: the expression's value, or the exception it
-- raises (a 'VError' result is raised, as cel-python does).
evaluate :: Activation -> Expr -> Either Exc Value
evaluate act e =
  evalExpr act e >>= \case
    VError err -> Left (CelExc err)
    v -> Right v

errorValue :: Text -> Exc -> LarkTree -> Value
errorValue message ex tree = VError (celError message ex (Just (treeDump tree)))

typeRepr :: Value -> Text
typeRepr = classRepr . pyType

ruleRepr :: Text -> Text
ruleRepr rule = "Token('RULE', " <> strRepr rule <> ")"

-- | Catch the listed exception classes of an operation into a
-- @CELEvalError@ value, letting everything else propagate.
catching :: [(ExcClass, Exc -> Value)] -> Result -> Result
catching handlers = \case
  Left ex
    | (h : _) <- [h | (cls, h) <- handlers, isExcClass cls ex] -> Right (h ex)
  r -> r

evalExpr :: Activation -> Expr -> Result
evalExpr act node@(Expr c rest) = case rest of
  Nothing -> evalOr act c
  Just (m, r) -> do
    cond <- evalOr act c
    let false = VBool 0
        branch
          | truthy cond = (\l -> (l, false)) <$> evalOr act m
          | otherwise = (\x -> (false, x)) <$> evalExpr act r
        failed l x ex =
          Right
            ( errorValue
                ( "found no matching overload for _?_:_ applied to '(" <> typeRepr cond <> ", " <> typeRepr l <> ", "
                    <> typeRepr x
                    <> ")'"
                )
                ex
                (exprNode node)
            )
    case branch of
      Left ex
        | isExcClass TypeError ex -> failed false false ex
        | otherwise -> Left ex
      Right (l, x) -> case logicalCondition cond l x of
        Left ex | isExcClass TypeError ex -> failed l x ex
        other -> other

evalOr :: Activation -> ConditionalOr -> Result
evalOr act = \case
  OrBase a -> evalAnd act a
  node@(Or l r) -> do
    lv <- evalOr act l
    rv <- evalAnd act r
    catching [(TypeError, overload "_||_" lv rv (orNode node))] (logicalOr lv rv)

evalAnd :: Activation -> ConditionalAnd -> Result
evalAnd act = \case
  AndBase r -> evalRel act r
  node@(And l r) -> do
    lv <- evalAnd act l
    rv <- evalRel act r
    catching [(TypeError, overload "_&&_" lv rv (andNode node))] (logicalAnd lv rv)

overload :: Text -> Value -> Value -> LarkTree -> Exc -> Value
overload name lv rv tree ex =
  errorValue ("found no matching overload for " <> name <> " applied to '(" <> typeRepr lv <> ", " <> typeRepr rv <> ")'") ex tree

overflow :: LarkTree -> Exc -> Value
overflow = flip (errorValue "return error for overflow")

evalRel :: Activation -> Relation -> Result
evalRel act = \case
  RelBase a -> evalAdd act a
  node@(Rel op l r) -> do
    lv <- evalRel act l
    rv <- evalAdd act r
    let result = case op of
          RelIn -> operatorIn lv rv
          _ -> compared (cmpOf op) lv rv
    catching [(TypeError, overload (ruleRepr (relOpRule op)) lv rv (relNode node))] result
  where
    cmpOf = \case
      RelLt -> CmpLt
      RelLe -> CmpLe
      RelGe -> CmpGe
      RelGt -> CmpGt
      RelEq -> CmpEq
      RelNe -> CmpNe
      RelIn -> CmpEq

-- | cel-python's @boolean()@ comparison wrapper: error operands are
-- returned, the comparison's truthiness becomes a @BoolType@.
compared :: CmpOp -> Value -> Value -> Result
compared op a b = case (a, b) of
  (VError _, _) -> Right a
  (_, VError _) -> Right b
  _ -> (\r -> VBool (if r then 1 else 0)) <$> richCompare op a b

evalAdd :: Activation -> Addition -> Result
evalAdd act = \case
  AddBase m -> evalMul act m
  node@(Add op l r) -> do
    lv <- evalAdd act l
    rv <- evalMul act r
    let tree = addNode node
    catching
      [ (TypeError, overload (ruleRepr (addOpRule op)) lv rv tree)
      , (ValueError, overflow tree)
      , (OverflowError, overflow tree)
      ]
      (numberOp (if op == AddPlus then OpAdd else OpSub) lv rv)

evalMul :: Activation -> Multiplication -> Result
evalMul act = \case
  MulBase u -> evalUnary act u
  node@(Mul op l r) -> do
    lv <- evalMul act l
    rv <- evalUnary act r
    let tree = mulNode node
        numOp = case op of
          MulTimes -> OpMul
          MulDiv -> OpTrueDiv
          MulMod -> OpMod
    catching
      [ (TypeError, overload (ruleRepr (mulOpRule op)) lv rv tree)
      , (ZeroDivisionError, errorValue "modulus or divide by zero" `flip` tree)
      , (ValueError, overflow tree)
      , (OverflowError, overflow tree)
      ]
      (numberOp numOp lv rv)

evalUnary :: Activation -> Unary -> Result
evalUnary act = \case
  UnaryMember m -> evalMember act m
  node@(UnaryNot u) -> apply node "unary_not" logicalNot u
  node@(UnaryNeg u) -> apply node "unary_neg" negative u
  where
    apply node rule f u = do
      v <- evalUnary act u
      let tree = unaryNode node
      catching
        [ (TypeError, \ex -> errorValue ("found no matching overload for " <> ruleRepr rule <> " applied to '(" <> typeRepr v <> ")'") ex tree)
        , (ValueError, overflow tree)
        ]
        (f v)

macroNames :: [Text]
macroNames = ["map", "filter", "all", "exists", "exists_one", "reduce", "min"]

evalMember :: Activation -> Member -> Result
evalMember act member = case member of
  MemberPrimary p -> evalPrimary act p
  MemberDot m name -> do
    mv <- evalMember act m
    let tree = memberNode member
        noTreeArgs message cls = VError (celErrorWith message cls "None" (Just (treeDump tree)))
    case mv of
      VError _ -> Right mv
      VContainer c -> case lookup name c of
        Just r -> Right (referentValue r)
        Nothing ->
          Right
            ( noTreeArgs
                ("No " <> strRepr name <> " in bindings [" <> T.intercalate ", " (map strRepr (sort (map fst c))) <> "]")
                KeyError
            )
      VMessage kvs ->
        dictLookup kvs (PStr name) >>= \case
          Just v -> Right v
          Nothing -> Left (keyError (PStr name))
      VMap kvs ->
        dictLookup kvs (PStr name) >>= \case
          Just v -> Right v
          Nothing -> Right (noTreeArgs ("no such member in mapping: " <> strRepr name) KeyError)
      _ ->
        Right
          ( noTreeArgs
              (valueRepr mv <> " with type: '" <> typeRepr mv <> "' does not support field selection")
              TypeError
          )
  MemberDotArg m name args
    | name `elem` macroNames -> do
        mv <- evalMember act m
        case mv of
          VError _ -> Right mv
          _ -> evalMacro act member name args mv
    | otherwise -> do
        mv <- evalMember act m
        argList <- traverse (evalExprList act) args
        methodEval mv name argList
  MemberIndex m e -> do
    mv <- evalMember act m
    iv <- evalExpr act e
    let tree = memberNode member
    catching
      [ (TypeError, overload "_[_]" mv iv tree)
      , (KeyError, errorValue "no such key" `flip` tree)
      , (IndexError, errorValue "invalid_argument" `flip` tree)
      ]
      (getItem mv iv)
  MemberObject m fields -> do
    mv <- evalMember act m
    let tree = memberNode member
        constructed = catching [(TypeError, wrap), (ValueError, wrap)]
        wrap ex = errorValue (excArg0 ex) ex tree
    case fields of
      Nothing -> constructed (callValue mv [VNone])
      Just inits -> do
        message <- evalFieldInits act inits
        case mv of
          VError _ -> Right mv
          _ -> constructed (callValue mv [message])

-- | @fieldinits@: each value is the first child of its @expr@ node (so a
-- ternary evaluates all three parts and yields its condition); a repeated
-- label raises @ValueError@.
evalFieldInits :: Activation -> FieldInits -> Result
evalFieldInits act inits = VMessage . reverse <$> go [] (toList inits)
  where
    go acc = \case
      [] -> Right acc
      (name, Expr c rest) : more -> do
        v <- evalOr act c
        case rest of
          Nothing -> Right ()
          Just (m, r) -> evalOr act m >> evalExpr act r >> Right ()
        if any (\(k, _) -> asText k == Just name) acc
          then Left (pyExc ValueError ("Duplicate field label " <> strRepr name))
          else go ((VString name, v) : acc) more

-- | The @exprlist@ rule: every argument is evaluated; the first error
-- value, else the list.
evalExprList :: Activation -> ExprList -> Result
evalExprList act es = do
  values <- traverse (evalExpr act) (toList es)
  Right $ case [v | v@(VError _) <- values] of
    err : _ -> err
    [] -> VList values

-- | @Evaluator.method_eval@.
methodEval :: Value -> Text -> Maybe Value -> Result
methodEval object name exprlist = case resolveFunction name of
  Nothing ->
    Right (VError (celError ("undeclared reference to " <> strRepr name <> activationNote) (keyError (PStr name)) Nothing))
  Just function -> case (object, exprlist) of
    (VError _, _) -> Right object
    (_, Just err@(VError _)) -> Right err
    _ -> callCaught function (object : maybe [] listItems exprlist)
  where
    listItems = \case
      VList xs -> xs
      _ -> []

-- | Calling a function from @function_eval@ / @method_eval@:
-- @ValueError@ is an overflow, @TypeError@ and @AttributeError@ are "no
-- such overload".
callCaught :: Value -> [Value] -> Result
callCaught function args =
  catching
    [ (ValueError, \ex -> VError (celError "return error for overflow" ex Nothing))
    , (TypeError, noOverload)
    , (AttributeError, noOverload)
    ]
    (callValue function args)
  where
    noOverload ex = VError (celError "no such overload" ex Nothing)

-- | The activation dump cel-python appends to "undeclared reference"
-- errors (an object @repr@; abbreviated here, and cut by the corpus).
activationNote :: Text
activationNote = " (in activation '<Activation>')"

-- | The macros: @map@, @filter@, @all@, @exists@, @exists_one@, @reduce@,
-- @min@.
evalMacro :: Activation -> Member -> Text -> Maybe ExprList -> Value -> Result
evalMacro act node name args target = case name of
  "map" -> do
    (var, body) <- macroArgs
    items <- pyIter target
    VList <$> traverse (\v -> sub [(var, v)] body) items
  "filter" -> do
    (var, body) <- macroArgs
    items <- pyIter target
    kept <- traverse (\v -> (\r -> (v, truthy r)) <$> sub [(var, v)] body) items
    Right (VList [v | (v, True) <- kept])
  "all" -> shortCircuitFree logicalAnd (VBool 1)
  "exists" -> shortCircuitFree logicalOr (VBool 0)
  "exists_one" -> do
    (var, body) <- macroArgs
    items <- pyIter target
    hits <- traverse (\v -> truthy <$> sub [(var, v)] body) items
    Right (VBool (if length (filter id hits) == 1 then 1 else 0))
  "reduce" -> do
    (accVar, iterVar, initial, body) <- reduceArgs
    start <- evalExpr act initial
    items <- case pyIter target of
      Right xs -> Right xs
      Left _ -> Left (pyExc TypeError "reduce() arg 2 must support iteration")
    let step acc v = acc >>= \a -> sub [(accVar, a), (iterVar, v)] body
    foldl step (Right start) items
  _ -> do
    items <- pyIter target
    case items of
      [] ->
        Right
          ( errorValue
              "Attempt to reduce an empty sequence or a sequence with a None value"
              (pyExc ValueError "min() iterable argument is empty")
              (memberNode node)
          )
      first : rest ->
        let step acc v = acc >>= \current -> richCompare CmpLt v current >>= \less -> Right (if less then v else current)
         in foldl step (Right first) rest
  where
    sub bindings body = do
      act' <- bindValues bindings act
      evaluate act' body
    -- @all@ / @exists@: errors from the sub-expression become values, and
    -- the fold's TypeError becomes "no such overload".
    shortCircuitFree combine start = do
      (var, body) <- macroArgs
      items <- pyIter target
      let step acc v = do
            a <- acc
            y <- case sub [(var, v)] body of
              Left (CelExc err) -> Right (VError err)
              other -> other
            catching [(TypeError, \ex -> VError (celError "no such overload" ex Nothing))] (combine a y)
      foldl step (Right start) items
    argList = maybe [] toList args
    badMacro =
      pyExc
        CELSyntaxError
        ( "member_dot_arg ["
            <> T.intercalate ", " (map larkRepr (larkChildren (memberNode node)))
            <> "]: bad macro node"
        )
    larkChildren (LarkTree _ children) = children
    singleIdent e = case findIdents (exprNode e) of
      [v] -> Just v
      _ -> Nothing
    macroArgs = case args of
      Nothing -> Left (pyExc IndexError "list index out of range")
      Just _ -> case argList of
        [v, body] -> maybe (Left badMacro) (\x -> Right (x, body)) (singleIdent v)
        xs -> Left (unpackError 2 (length xs))
    reduceArgs = case args of
      Nothing -> Left (pyExc IndexError "list index out of range")
      Just _ -> case argList of
        [r, i, initial, body] -> case (singleIdent r, singleIdent i) of
          (Just rv, Just iv) -> Right (rv, iv, initial, body)
          _ -> Left badMacro
        xs -> Left (unpackError 4 (length xs))
    unpackError :: Int -> Int -> Exc
    unpackError expected got =
      pyExc
        ValueError
        ( (if got < expected then "not enough" else "too many")
            <> " values to unpack (expected "
            <> T.pack (show expected)
            <> ", got "
            <> T.pack (show got)
            <> ")"
        )

evalPrimary :: Activation -> Primary -> Result
evalPrimary act primary = case primary of
  PrimaryLiteral lit -> case literalValue lit of
    LitInt n -> Right (VInt n)
    LitUint n -> Right (VUint n)
    LitDouble d -> Right (VDouble d)
    LitString t -> Right (VString t)
    LitBytes b -> Right (VBytes b)
    LitBool b -> Right (VBool (if b then 1 else 0))
    LitNull -> Right VNone
    LitValueError message -> Right (errorValue message (pyExc ValueError message) (literalNode lit))
    LitTypeError message -> Left (pyExc TypeError message)
  PrimaryParen e -> evalExpr act e
  PrimaryList Nothing -> Right (VList [])
  PrimaryList (Just es) -> evalExprList act es
  PrimaryMap Nothing -> Right (VMap [])
  PrimaryMap (Just inits) ->
    let wrap ex = errorValue (excArg0 ex) ex tree
     in catching [(ValueError, wrap), (TypeError, wrap)] (evalMapInits act inits)
  PrimaryDotIdent name -> rootIdent name
  PrimaryDotIdentArg name args -> traverse (evalExprList act) args >> rootIdent name
  PrimaryIdentArg name args -> do
    let exprs = maybe [] toList args
    case name of
      "has" -> do
        values <- traverse (evalExpr act) exprs
        case values of
          VError _ : _ -> Right (VBool 0)
          _ : _ -> Right (VBool 1)
          [] -> Left (pyExc IndexError "list index out of range")
      "dyn" -> do
        values <- traverse (evalExpr act) exprs
        case values of
          v : _ -> Right v
          [] -> Left (pyExc IndexError "list index out of range")
      _ -> do
        values <- traverse (evalExpr act) exprs
        case resolveFunction name of
          Nothing ->
            Right (VError (celError ("undeclared reference to '" <> name <> "'" <> activationNote) (keyError (PStr name)) Nothing))
          Just function -> case [v | v@(VError _) <- values] of
            err : _ -> Right err
            [] -> callCaught function values
  PrimaryIdent name -> case resolveVariable act name of
    Just v -> Right v
    Nothing ->
      Right (errorValue ("undeclared reference to '" <> name <> "'" <> activationNote) (keyError (PStr name)) tree)
  where
    tree = primaryNode primary
    rootIdent name = case resolveVariable act name of
      Just v -> Right v
      Nothing -> Right (errorValue name (keyError (PStr name)) tree)

-- | @mapinits@: every key and value is evaluated, then the map is built;
-- a repeated key raises @ValueError@.
evalMapInits :: Activation -> MapInits -> Result
evalMapInits act inits = do
  pairs <- traverse (\(k, v) -> (,) <$> evalExpr act k <*> evalExpr act v) (toList inits)
  let insert acc (k, v) = do
        entries <- acc
        duplicate <- dictContains entries k
        if duplicate
          then Left (pyExc ValueError ("Duplicate key " <> valueRepr k))
          else dictSet entries k v
  VMap <$> foldl insert (Right []) pairs
