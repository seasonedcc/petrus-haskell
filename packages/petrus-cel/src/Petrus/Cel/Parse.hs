-- | A pure parser for CEL source text, producing the typed tree of
-- "Petrus.Cel.Syntax".
--
-- cel-python parses with a lark LALR(1) parser and a /contextual/ lexer: the
-- set of terminals tried at each point depends on the parser state. This
-- module reproduces that with a recursive-descent parser whose lexer takes a
-- 'Mode', and it reproduces which input is accepted and where errors are
-- reported. The cel-python behaviours that follow from its lexer, and that
-- deviate from the CEL specification, are deliberate:
--
-- * where an operand is expected, @-1@ is a single (negative) integer literal,
--   while after an operand @-@ is subtraction;
-- * after an operand, @in@ matches as a prefix, so @a inx@ means @a in x@;
-- * there is no @!=@ terminal where an operand is expected, and keywords
--   such as @in@, @as@, or @if@ are ordinary identifiers there;
-- * after a dot, @null@ and @in@ are field names, but @true@/@false@ are
--   rejected (cel-python turns them into boolean tokens with no position, so
--   such errors have no line or column);
-- * @{@ may follow any member (@1{}@ parses);
-- * string literals end at the first closing quote reachable by Python's
--   backtracking regex, so @\"\\\"@ is a one-character string;
-- * @0X1@, @1e@ and @1.size()@ split into several tokens, as the regexes do.
module Petrus.Cel.Parse
  ( ParseError (..)
  , parseCel
  ) where

import Control.Monad (ap, liftM)
import Data.Array (Array)
import Data.Array qualified as A
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T

import Petrus.Cel.Literal (LiteralKind (..), cookLiteral)
import Petrus.Cel.Syntax

-- | A syntax error. The position is 1-based (lines count @\\n@ only, columns
-- count code points). It is absent exactly when cel-python reports none: when
-- the offending token is a @true@/@false@ literal (or, at end of input, when
-- the last token was one).
data ParseError = ParseError
  { parseErrorLine :: Maybe Int
  , parseErrorColumn :: Maybe Int
  , parseErrorMessage :: Text
  -- ^ @str()@ of cel-python's @CELParseError@: lark's @get_context@, the
  -- source line around the error and a caret under it.
  }
  deriving stock (Eq, Show)

-- | Which terminals the lexer tries (the contextual lexer's parser states,
-- grouped by the terminals that matter).
data Mode
  = -- | An operand may start here: literals, identifiers, @!@, @-@, @.@,
    -- brackets, and closing brackets of empty lists.
    Operand
  | -- | After an operand: operators, @.@, brackets, separators.
    PostOperand
  | -- | Only an identifier (or a closing bracket) is acceptable.
    Name
  deriving stock (Eq)

data TokKind
  = TLit LiteralKind
  | TIdent
  | TBang
  | TDot
  | TLBrace
  | TRBrace
  | TLPar
  | TRPar
  | TLSqb
  | TRSqb
  | TMinus
  | TPlus
  | TStar
  | TSlash
  | TPercent
  | TOr
  | TAnd
  | TRel RelOp
  | TQuestion
  | TColon
  | TComma
  | -- | End of input.
    TEnd
  | -- | Nothing acceptable in this mode lexes here.
    TBad
  deriving stock (Eq)

data Tok = Tok
  { tokKind :: TokKind
  , tokStart :: Int
  , tokEnd :: Int
  , tokNoPosition :: Bool
  -- ^ cel-python's @true@/@false@ tokens carry no position.
  }

-- | The source as an array of code points, and its length.
data Input = Input (UArray Int Char) Int

inputLength :: Input -> Int
inputLength (Input _ n) = n

charAt :: Input -> Int -> Maybe Char
charAt (Input chars n) i
  | i >= 0 && i < n = Just (chars ! i)
  | otherwise = Nothing
{-# INLINE charAt #-}

is :: Input -> Int -> Char -> Bool
is input i c = charAt input i == Just c
{-# INLINE is #-}

slice :: Input -> Int -> Int -> Text
slice input from to = T.pack [c | i <- [from .. to - 1], Just c <- [charAt input i]]

-- | Skip ignored text: whitespace @[\\t\\n\\f\\r ]@ and @//@ comments.
skipIgnored :: Input -> Int -> Int
skipIgnored input = go
  where
    go i = case charAt input i of
      Just c | c `elem` ("\t\n\f\r " :: String) -> go (i + 1)
      Just '/' | is input (i + 1) '/' -> go (lineEnd (i + 2))
      _ -> i
    lineEnd i = case charAt input i of
      Just '\n' -> i
      Just _ -> lineEnd (i + 1)
      Nothing -> i

isIdentStart, isIdentChar :: Char -> Bool
isIdentStart c = c == '_' || isAsciiLower c || isAsciiUpper c
isIdentChar c = isIdentStart c || isDigit c

-- | The end of an @IDENT@ match at @i@.
identEnd :: Input -> Int -> Maybe Int
identEnd input i = case charAt input i of
  Just c | isIdentStart c -> Just (go (i + 1))
  _ -> Nothing
  where
    go j = case charAt input j of
      Just c | isIdentChar c -> go (j + 1)
      _ -> j

countWhile :: Input -> (Char -> Bool) -> Int -> Int
countWhile input p = go 0
  where
    go k i = case charAt input i of
      Just c | p c -> go (k + 1) (i + 1)
      _ -> k

-- | Where a quoted string whose body starts at @start@ ends, following the
-- lazy, ordered-alternation regex of cel-python's grammar. The escape
-- alternatives other than @\\\\[abfnrtv\"'\\\\]@ never consume a quote or a
-- backslash after their leading backslash, so they are equivalent to
-- consuming one character at a time and are not spelled out.
stringEnd :: Input -> Bool -> Char -> Int -> Maybe Int
stringEnd input multiline quote start = result start
  where
    limit
      | multiline = inputLength input
      | otherwise = start + countWhile input (/= '\n') start
    memo :: Array Int (Maybe Int)
    memo = A.listArray (start, limit) (map step [start .. limit])
    result p
      | p > limit = Nothing
      | otherwise = memo A.! p
    closeLength = if multiline then 3 else 1
    closesAt p = all (\k -> is input (p + k) quote) [0 .. closeLength - 1]
    step p
      | closesAt p = Just (p + closeLength)
      | otherwise = case charAt input p of
          Nothing -> Nothing
          Just c ->
            let viaEscape
                  | c == '\\', Just e <- charAt input (p + 1), e `elem` ("abfnrtv\"'\\" :: String) = result (p + 2)
                  | otherwise = Nothing
                viaChar
                  | c == '\n' && not multiline = Nothing
                  | otherwise = result (p + 1)
             in maybe viaChar Just viaEscape

-- | A (possibly raw) string literal at @i@, multi-line or not.
stringAt :: Input -> Bool -> Int -> Maybe Int
stringAt input multiline i =
  let body = if charAt input i `elem` [Just 'r', Just 'R'] then i + 1 else i
   in case charAt input body of
        Just q | q == '"' || q == '\'' ->
          if multiline
            then
              if is input (body + 1) q && is input (body + 2) q
                then stringEnd input True q (body + 3)
                else Nothing
            else stringEnd input False q (body + 1)
        _ -> Nothing

-- | @FLOAT_LIT@: @-?D+.D*E?@, then @-?D*.D+E?@, then @-?D+E@.
floatAt :: Input -> Int -> Maybe Int
floatAt input i =
  let q = if is input i '-' then i + 1 else i
      d1 = countWhile input isDigit q
      afterDigits = q + d1
      exponentEnd r = case charAt input r of
        Just e | e == 'e' || e == 'E' ->
          let s = if charAt input (r + 1) `elem` [Just '+', Just '-'] then r + 2 else r + 1
              k = countWhile input isDigit s
           in if k > 0 then Just (s + k) else Nothing
        _ -> Nothing
      optionalExponent r = maybe r id (exponentEnd r)
   in if d1 > 0 && is input afterDigits '.'
        then Just (optionalExponent (afterDigits + 1 + countWhile input isDigit (afterDigits + 1)))
        else
          if d1 == 0 && is input q '.' && countWhile input isDigit (q + 1) > 0
            then Just (optionalExponent (q + 1 + countWhile input isDigit (q + 1)))
            else if d1 > 0 then exponentEnd afterDigits else Nothing

-- | @INT_LIT@'s two alternatives: @-?0x[0-9a-fA-F]+@ and @-?[0-9]+@.
intAlternatives :: Input -> Int -> [Int]
intAlternatives input i =
  let q = if is input i '-' then i + 1 else i
      hexDigits = countWhile input isHexDigit (q + 2)
      decimal = countWhile input isDigit q
   in [q + 2 + hexDigits | is input q '0', is input (q + 1) 'x', hexDigits > 0]
        <> [q + decimal | decimal > 0]

uintAt :: Input -> Int -> Maybe Int
uintAt input i =
  case [e + 1 | e <- intAlternatives input i, charAt input e `elem` [Just 'u', Just 'U']] of
    e : _ -> Just e
    [] -> Nothing

intAt :: Input -> Int -> Maybe Int
intAt input i = case intAlternatives input i of
  e : _ -> Just e
  [] -> Nothing

-- | Lex one token at @i@ (already past ignored text) in a mode.
lexAt :: Input -> Mode -> Int -> Tok
lexAt input mode i
  | i >= inputLength input = Tok TEnd i i False
  | otherwise = case mode of
      Operand -> firstOf (operandLexers <> closers) bad
      PostOperand -> firstOf (postOperandLexers <> closers) bad
      Name -> firstOf (nameLexer : closers) bad
  where
    tok kind end = Tok kind i end False
    firstOf lexers fallback = case [t | lexer <- lexers, Just t <- [lexer]] of
      t : _ -> t
      [] -> fallback
    -- When nothing in the mode matches, lark retries with every terminal to
    -- build its error; that retry yields a position-less boolean token when
    -- the identifier regex matches exactly @true@ or @false@.
    bad = Tok TBad i i (identText `elem` [Just "true", Just "false"])
    identText = slice input i <$> identEnd input i
    literal kind end = Just (tok (TLit kind) end)
    operandLexers =
      [ if charAt input i `elem` [Just 'b', Just 'B']
          then case stringAt input True (i + 1) of
            Just e -> literal BytesLiteral e
            Nothing -> stringAt input False (i + 1) >>= literal BytesLiteral
          else Nothing
      , stringAt input True i >>= literal MultilineStringLiteral
      , stringAt input False i >>= literal StringLiteral
      , floatAt input i >>= literal FloatLiteral
      , uintAt input i >>= literal UintLiteral
      , intAt input i >>= literal IntLiteral
      , identEnd input i >>= \e -> case slice input i e of
          "true" -> Just (Tok (TLit BoolLiteral) i e True)
          "false" -> Just (Tok (TLit BoolLiteral) i e True)
          "null" -> literal NullLiteral e
          _ -> Just (tok TIdent e)
      , punct '!' TBang
      , punct '.' TDot
      , punct '{' TLBrace
      , punct '(' TLPar
      , punct '[' TLSqb
      , punct '-' TMinus
      ]
    nameLexer = identEnd input i >>= \e -> case slice input i e of
      "true" -> Just (Tok (TLit BoolLiteral) i e True)
      "false" -> Just (Tok (TLit BoolLiteral) i e True)
      _ -> Just (tok TIdent e)
    closers = [punct '}' TRBrace, punct ')' TRPar, punct ']' TRSqb]
    postOperandLexers =
      [ two "!=" (TRel RelNe)
      , two "&&" TAnd
      , two "<=" (TRel RelLe)
      , two "==" (TRel RelEq)
      , two ">=" (TRel RelGe)
      , two "in" (TRel RelIn)
      , two "||" TOr
      , punct '<' (TRel RelLt)
      , punct '>' (TRel RelGt)
      , punct '+' TPlus
      , punct '-' TMinus
      , punct '*' TStar
      , punct '/' TSlash
      , punct '%' TPercent
      , punct '?' TQuestion
      , punct ':' TColon
      , punct ',' TComma
      , punct '.' TDot
      , punct '[' TLSqb
      , punct '{' TLBrace
      , punct '(' TLPar
      ]
    punct c kind = if is input i c then Just (tok kind (i + 1)) else Nothing
    two [a, b] kind = if is input i a && is input (i + 1) b then Just (tok kind (i + 2)) else Nothing
    two _ _ = Nothing

-- Parser monad -----------------------------------------------------------

data St = St
  { stOffset :: Int
  , stLast :: Maybe (Int, Bool)
  -- ^ Start and position-lessness of the last consumed token.
  }

newtype P a = P (Input -> St -> Either ParseError (a, St))

instance Functor P where
  fmap = liftM

instance Applicative P where
  pure a = P (\_ st -> Right (a, st))
  (<*>) = ap

instance Monad P where
  P m >>= k = P $ \input st -> case m input st of
    Left e -> Left e
    Right (a, st') -> let P m' = k a in m' input st'

peek :: Mode -> P Tok
peek mode = P $ \input st -> Right (lexAt input mode (skipIgnored input (stOffset st)), st)

advance :: Tok -> P ()
advance t = P $ \_ _ -> Right ((), St (tokEnd t) (Just (tokStart t, tokNoPosition t)))

-- | Fail at a token, positioned the way lark reports it.
unexpected :: Tok -> P a
unexpected t = P $ \input st ->
  let (position, offset) = case tokKind t of
        TEnd -> case stLast st of
          Nothing -> (Just (1, 1), 0)
          Just (_, True) -> (Nothing, 0)
          Just (start, False) -> (Just (lineColumn input start), start)
        _
          | tokNoPosition t -> (Nothing, 0)
          | otherwise -> (Just (lineColumn input (tokStart t)), tokStart t)
   in Left (ParseError (fst <$> position) (snd <$> position) (errorContext input offset))

-- | lark's @UnexpectedInput.get_context(text)@ (span 40): up to 40
-- characters either side of the error on its line, and a caret below.
errorContext :: Input -> Int -> Text
errorContext input pos =
  let before = T.takeWhileEnd (/= '\n') (slice input (max 0 (pos - 40)) pos)
      after = T.takeWhile (/= '\n') (slice input pos (pos + 40))
   in before <> after <> "\n" <> T.replicate (expandedLength before) " " <> "^\n"
  where
    -- @len(before.expandtabs())@: tabs to multiples of 8, @\\r@ restarts
    -- the column (and still counts as a character).
    expandedLength = snd . T.foldl' step (0 :: Int, 0 :: Int)
    step (column, total) = \case
      '\t' -> let w = 8 - column `mod` 8 in (column + w, total + w)
      '\r' -> (0, total + 1)
      _ -> (column + 1, total + 1)

lineColumn :: Input -> Int -> (Int, Int)
lineColumn input offset =
  let newlines = [i | i <- [0 .. offset - 1], is input i '\n']
      lastNewline = if null newlines then -1 else last newlines
   in (1 + length newlines, offset - lastNewline)

tokenText :: Tok -> P Text
tokenText t = P $ \input st -> Right (slice input (tokStart t) (tokEnd t), st)

expect :: Mode -> TokKind -> P ()
expect mode kind = do
  t <- peek mode
  if tokKind t == kind then advance t else unexpected t

-- | Parse CEL source text.
parseCel :: Text -> Either ParseError Expr
parseCel source =
  let chars = T.unpack source
      n = length chars
      input = Input (listArray (0, max 0 n - 1) chars) n
      P run = do
        e <- expr
        t <- peek PostOperand
        if tokKind t == TEnd then pure e else unexpected t
   in fst <$> run input (St 0 Nothing)

expr :: P Expr
expr = do
  c <- conditionalOr
  t <- peek PostOperand
  if tokKind t == TQuestion
    then do
      advance t
      middle <- conditionalOr
      expect PostOperand TColon
      rest <- expr
      pure (Expr c (Just (middle, rest)))
    else pure (Expr c Nothing)

-- | A left-associative binary level.
leftAssoc :: P b -> (TokKind -> Maybe op) -> (op -> a -> b -> a) -> (b -> a) -> P a
leftAssoc operand operator combine base = operand >>= go . base
  where
    go acc = do
      t <- peek PostOperand
      case operator (tokKind t) of
        Just op -> do
          advance t
          right <- operand
          go (combine op acc right)
        Nothing -> pure acc

conditionalOr :: P ConditionalOr
conditionalOr =
  leftAssoc conditionalAnd (\k -> if k == TOr then Just () else Nothing) (\() l r -> Or l r) OrBase

conditionalAnd :: P ConditionalAnd
conditionalAnd =
  leftAssoc relation (\k -> if k == TAnd then Just () else Nothing) (\() l r -> And l r) AndBase

relation :: P Relation
relation = leftAssoc addition (\case TRel op -> Just op; _ -> Nothing) Rel RelBase

addition :: P Addition
addition =
  leftAssoc
    multiplication
    (\case TPlus -> Just AddPlus; TMinus -> Just AddMinus; _ -> Nothing)
    Add
    AddBase

multiplication :: P Multiplication
multiplication =
  leftAssoc
    unary
    (\case TStar -> Just MulTimes; TSlash -> Just MulDiv; TPercent -> Just MulMod; _ -> Nothing)
    Mul
    MulBase

unary :: P Unary
unary = do
  t <- peek Operand
  case tokKind t of
    TBang -> advance t >> UnaryNot <$> unary
    TMinus -> advance t >> UnaryNeg <$> unary
    _ -> UnaryMember <$> member

member :: P Member
member = primary >>= go . MemberPrimary
  where
    go m = do
      t <- peek PostOperand
      case tokKind t of
        TDot -> do
          advance t
          name <- identifier
          call <- peek PostOperand
          if tokKind call == TLPar
            then do
              advance call
              args <- argumentsUntil TRPar
              go (MemberDotArg m name args)
            else go (MemberDot m name)
        TLSqb -> do
          advance t
          index <- expr
          expect PostOperand TRSqb
          go (MemberIndex m index)
        TLBrace -> do
          advance t
          fields <- fieldInits
          go (MemberObject m fields)
        _ -> pure m

identifier :: P Ident
identifier = do
  t <- peek Name
  if tokKind t == TIdent then advance t >> tokenText t else unexpected t

primary :: P Primary
primary = do
  t <- peek Operand
  case tokKind t of
    TLit kind -> do
      advance t
      text <- tokenText t
      pure (PrimaryLiteral (Literal kind text (cookLiteral kind text)))
    TDot -> do
      advance t
      name <- identifier
      call <- peek PostOperand
      if tokKind call == TLPar
        then advance call >> PrimaryDotIdentArg name <$> argumentsUntil TRPar
        else pure (PrimaryDotIdent name)
    TIdent -> do
      advance t
      name <- tokenText t
      call <- peek PostOperand
      if tokKind call == TLPar
        then advance call >> PrimaryIdentArg name <$> argumentsUntil TRPar
        else pure (PrimaryIdent name)
    TLPar -> do
      advance t
      e <- expr
      expect PostOperand TRPar
      pure (PrimaryParen e)
    TLSqb -> advance t >> PrimaryList <$> argumentsUntil TRSqb
    TLBrace -> do
      advance t
      close <- peek Operand
      if tokKind close == TRBrace
        then advance close >> pure (PrimaryMap Nothing)
        else do
          inits <- sepBy1 mapInit
          expect PostOperand TRBrace
          pure (PrimaryMap (Just inits))
    _ -> unexpected t
  where
    mapInit = do
      k <- expr
      expect PostOperand TColon
      v <- expr
      pure (k, v)

-- | An optional @exprlist@ followed by a closing bracket.
argumentsUntil :: TokKind -> P (Maybe ExprList)
argumentsUntil closer = do
  t <- peek Operand
  if tokKind t == closer
    then advance t >> pure Nothing
    else do
      es <- sepBy1 expr
      expect PostOperand closer
      pure (Just es)

-- | @item ("," item)*@
sepBy1 :: P a -> P (NonEmpty a)
sepBy1 item = do
  first <- item
  rest <- go
  pure (first :| rest)
  where
    go = do
      t <- peek PostOperand
      if tokKind t == TComma
        then advance t >> ((:) <$> item <*> go)
        else pure []

-- | The body of @member "{" [fieldinits] "}"@, including the closing brace.
fieldInits :: P (Maybe FieldInits)
fieldInits = do
  t <- peek Name
  if tokKind t == TRBrace
    then advance t >> pure Nothing
    else do
      fields <- sepBy1 field
      expect PostOperand TRBrace
      pure (Just fields)
  where
    field = do
      name <- identifier
      expect PostOperand TColon
      value <- expr
      pure (name, value)
