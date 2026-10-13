{-# LANGUAGE MultiWayIf #-}

-- | Python literals: CPython's @repr()@ and @ast.literal_eval@ for the values
-- Hamsterdan stores as text.
--
-- Hamsterdan's dashboard keeps its entry log as @f"{kind}:{body}"@ (a dict's
-- @repr@) and its projection digest as
-- @f"{kind}:{sorted(body.items())!r}"@; the board parses entries back with
-- @ast.literal_eval@. Both directions must agree with CPython character for
-- character, or durable digests drift and the board misreads its own log.
--
-- The modeled values are exactly what those bodies can hold: @None@, @bool@,
-- @int@, @float@, @str@, @list@, @tuple@, and @dict@. The parser accepts the
-- full literal syntax of those types (string prefixes, triple quotes, every
-- escape except @\\N{...}@, implicit concatenation, all integer bases,
-- underscores, comments, line continuations, trailing commas) and reports
-- 'Unsupported' for literals CPython would accept but whose values are not
-- modeled (@bytes@, @complex@, @set@, @Ellipsis@, @\\N{...}@ escapes). An
-- escaped lone surrogate (@'\\udc80'@) is kept in its @str@ (WTF-8,
-- "Petrus.Json.Wtf8"), as CPython keeps it; a raw one in the source is the
-- @UnicodeEncodeError@ CPython's compiler raises encoding the source.
module Hamsterdan.PyLiteral
  ( -- * Values
    PyValue (..)
  , pyEq
  , fromJson
  , toJson

    -- * Printing (@repr@)
  , repr
  , dictEntry
  , sortedItemsDigest

    -- * Parsing (@ast.literal_eval@)
  , literalEval
  , LiteralError (..)
  , LiteralErrorKind (..)
  ) where

import Control.Monad (when)
import Data.Char (chr, isAlpha, isAlphaNum, isDigit, isHexDigit, isOctDigit, ord, toLower)
import Data.Array (Array, listArray, (!))
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (pythonDict)
import Petrus.Json (Json)
import Petrus.Json qualified as Json
import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.Python.JsonRepr (jsonItemsRepr, jsonRepr)
import Petrus.Json.Python (PyNumber (..), pyNumberEq, pythonDoubleRepr, pythonExceptionStr, pythonStrRepr, unicodeEncodeError, utf8EncodeFailure)
import Petrus.Json.Wtf8 (fromCodePoints)

-- | A Python value of a modeled type. 'LitDict' keeps insertion order and
-- never holds two Python-equal keys. The constructors carry a @Lit@ prefix
-- so that a module can use them beside petrus-json's
-- 'Petrus.Json.Python.PyObject' (whose @PyStr@, @PyList@ and others name
-- the wider object model) without qualification.
data PyValue
  = LitNone
  | LitBool Bool
  | LitInt Integer
  | LitFloat Double
  | LitStr Text
  | LitList [PyValue]
  | LitTuple [PyValue]
  | LitDict [(PyValue, PyValue)]
  deriving stock (Eq, Show)

-- | Python's @==@: numbers compare by value across @bool@, @int@, and
-- @float@ (exactly, as CPython does); NaN equals nothing; lists and tuples
-- never equal each other; dicts compare as mappings.
pyEq :: PyValue -> PyValue -> Bool
pyEq left right = case (numeric left, numeric right) of
  (Just a, Just b) -> pyNumberEq a b
  (Just _, Nothing) -> False
  (Nothing, Just _) -> False
  (Nothing, Nothing) -> case (left, right) of
    (LitNone, LitNone) -> True
    (LitStr a, LitStr b) -> a == b
    (LitList a, LitList b) -> sameLength a b && and (zipWith pyEq a b)
    (LitTuple a, LitTuple b) -> sameLength a b && and (zipWith pyEq a b)
    (LitDict a, LitDict b) ->
      sameLength a b
        && all (\(key, value) -> maybe False (pyEq value) (lookupKey key b)) a
    _ -> False
  where
    sameLength a b = length a == length b

-- | The number a value is, for @==@ (petrus-json's numeric core).
numeric :: PyValue -> Maybe PyNumber
numeric = \case
  LitBool value -> Just (PyExact (if value then 1 else 0))
  LitInt value -> Just (PyExact value)
  LitFloat value -> Just (PyInexact value)
  _ -> Nothing

lookupKey :: PyValue -> [(PyValue, PyValue)] -> Maybe PyValue
lookupKey key = fmap snd . findFirst (pyEq key . fst)
  where
    findFirst predicate = foldr (\item rest -> if predicate item then Just item else rest) Nothing

-- | A JSON value as Python's @json.loads@ returns it.
fromJson :: Json -> PyValue
fromJson = \case
  Json.Null -> LitNone
  Json.Bool value -> LitBool value
  Json.Int value -> LitInt value
  Json.Float value -> LitFloat value
  Json.String value -> LitStr value
  Json.Array values -> LitList (map fromJson values)
  Json.Object members -> LitDict [(LitStr key, fromJson value) | (key, value) <- pythonDict members]

-- | The JSON value @json.dumps@ would write, when every dict key is a
-- string (tuples become arrays, as in @json.dumps@).
toJson :: PyValue -> Maybe Json
toJson = \case
  LitNone -> Just Json.Null
  LitBool value -> Just (Json.Bool value)
  LitInt value -> Just (Json.Int value)
  LitFloat value -> Just (Json.Float value)
  LitStr value -> Just (Json.String value)
  LitList values -> Json.Array <$> traverse toJson values
  LitTuple values -> Json.Array <$> traverse toJson values
  LitDict members -> Json.Object <$> traverse member members
  where
    member (LitStr key, value) = (key,) <$> toJson value
    member _ = Nothing

-- * Printing -----------------------------------------------------------------

-- The printer emits a difference list of text chunks that one 'T.concat'
-- (a single allocation and copy) joins; plain runs of a string are emitted as
-- slices of the original text, never character by character.
type Chunks = [Text] -> [Text]

-- | CPython's @repr(value)@.
repr :: PyValue -> Text
repr value = T.concat (reprChunks value [])

reprChunks :: PyValue -> Chunks
reprChunks = \case
  LitNone -> ("None" :)
  LitBool True -> ("True" :)
  LitBool False -> ("False" :)
  LitInt value -> (intText value :)
  LitFloat value -> (pythonDoubleRepr value :)
  LitStr value -> strChunks value
  LitList values -> ("[" :) . commaSeparated (map reprChunks values) . ("]" :)
  LitTuple [single] -> ("(" :) . reprChunks single . (",)" :)
  LitTuple values -> ("(" :) . commaSeparated (map reprChunks values) . (")" :)
  LitDict members -> dictChunks [(reprChunks key, reprChunks value) | (key, value) <- members]

dictChunks :: [(Chunks, Chunks)] -> Chunks
dictChunks members = ("{" :) . commaSeparated [key . (": " :) . value | (key, value) <- members] . ("}" :)

commaSeparated :: [Chunks] -> Chunks
commaSeparated = \case
  [] -> id
  first : rest -> first . foldr (\item more -> (", " :) . item . more) id rest

intText :: Integer -> Text
intText value
  | value >= 0 && value < smallIntCount = smallInts ! fromInteger value
  | otherwise = T.pack (show value)

-- | The spellings of the small non-negative integers (counts, flags, run
-- attempts), computed once.
smallInts :: Array Int Text
smallInts = listArray (0, fromInteger smallIntCount - 1) [T.pack (show i) | i <- [0 .. smallIntCount - 1]]

smallIntCount :: Integer
smallIntCount = 1024

strChunks :: Text -> Chunks
strChunks value = (pythonStrRepr value :)

-- | A dashboard entry: @f"{kind}:{body}"@ for a JSON object body.
dictEntry :: Text -> [(Text, Json)] -> Text
dictEntry kind body = T.concat [kind, ":", jsonRepr (Json.Object body)]

-- | A dashboard digest: @f"{kind}:{sorted(body.items())!r}"@. Keys of a
-- JSON object are distinct strings, so the sort is by key alone (code point
-- order, which UTF-8 byte order preserves).
sortedItemsDigest :: Text -> [(Text, Json)] -> Text
sortedItemsDigest kind body = T.concat [kind, ":", jsonItemsRepr (sortOn fst (pythonDict body))]

-- * Parsing ------------------------------------------------------------------

-- | How @ast.literal_eval@ would end.
data LiteralErrorKind
  = -- | CPython raises @SyntaxError@ or @ValueError@ (malformed node).
    Malformed
  | -- | CPython raises @TypeError@: an unhashable dict key.
    Unhashable
  | -- | CPython returns a value of a type this module does not model.
    Unsupported
  deriving stock (Eq, Show)

-- | Why a text is not a modeled literal.
data LiteralError = LiteralError
  { errorKind :: LiteralErrorKind
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

-- | The syntax tree of the literal subset, before conversion.
data Expr
  = EConst PyValue
  | ETuple [Expr]
  | EList [Expr]
  | EDict [(Expr, Expr)]
  | ESigned Bool Expr
  | -- | A real number plus or minus an imaginary one (a complex literal).
    EBinary Expr Expr
  | EImaginary
  | ESet [Expr]
  | -- | A node CPython's @_convert@ refuses (a name, an f-string, ...).
    EName Text
  | -- | A literal of a type this module does not model.
    EUnsupported Text

-- | @ast.literal_eval(source)@.
literalEval :: Text -> Either LiteralError PyValue
literalEval source = do
  mapM_ (malformed . pythonExceptionStr . unicodeEncodeError source) (utf8EncodeFailure source)
  when (T.any (== '\0') source) $ malformed "source code string cannot contain null bytes"
  let prepared = translateNewlines (T.dropWhile (\c -> c == ' ' || c == '\t') source)
  (expr, rest) <- runP topLevel prepared
  if T.null rest then convert expr else malformed "invalid syntax"

-- CPython's string tokenizer reads @\\r\\n@ and lone @\\r@ as @\\n@.
translateNewlines :: Text -> Text
translateNewlines text
  | T.any (== '\r') text = T.replace "\r" "\n" (T.replace "\r\n" "\n" text)
  | otherwise = text

malformed :: Text -> Either LiteralError a
malformed = Left . LiteralError Malformed

unsupported :: Text -> Either LiteralError a
unsupported = Left . LiteralError Unsupported

-- ** Conversion (the @_convert@ walk)

convert :: Expr -> Either LiteralError PyValue
convert = \case
  EConst value -> Right value
  ETuple elements -> LitTuple <$> traverse convert elements
  EList elements -> LitList <$> traverse convert elements
  EDict members -> LitDict <$> insertAll ([], Set.empty) members
  ESigned negative operand -> case operand of
    EConst (LitInt value) -> Right (LitInt (if negative then negate value else value))
    EConst (LitFloat value) -> Right (LitFloat (if negative then negate value else value))
    EImaginary -> unsupported "complex is not a modeled value"
    _ -> malformed "malformed node or string"
  EBinary left right
    | realNumber left, EImaginary <- right -> unsupported "complex is not a modeled value"
    | otherwise -> malformed "malformed node or string"
  EImaginary -> unsupported "complex is not a modeled value"
  -- set(map(_convert, elts)): each element is converted, then hashed.
  ESet elements -> do
    mapM_ (\element -> convert element >>= \value -> when (not (hashable value)) (Left (unhashableError "a set element" value))) elements
    unsupported "set is not a modeled value"
  EName _ -> malformed "malformed node or string"
  EUnsupported what -> unsupported (what <> " is not a modeled value")
  where
    realNumber = \case
      EConst (LitInt _) -> True
      EConst (LitFloat _) -> True
      ESigned _ (EConst (LitInt _)) -> True
      ESigned _ (EConst (LitFloat _)) -> True
      _ -> False
    -- dict(zip(map(_convert, keys), map(_convert, values))): key, value,
    -- insert (hashing the key), in source order.
    insertAll (acc, _) [] = Right (reverse acc)
    insertAll state ((keyExpr, valueExpr) : rest) = do
      key <- convert keyExpr
      value <- convert valueExpr
      when (not (hashable key)) $ Left (unhashableError "a dict key" key)
      insertAll (insert key value state) rest
    -- String keys (the common case) are found through a set; other keys
    -- by Python equality.
    insert key value (acc, strings)
      | present = ([if pyEq key existing then (existing, value) else pair | pair@(existing, _) <- acc], strings)
      | LitStr text <- key = ((key, value) : acc, Set.insert text strings)
      | otherwise = ((key, value) : acc, strings)
      where
        present = case key of
          LitStr text -> Set.member text strings
          _ -> any (pyEq key . fst) acc

-- | CPython 3.14's text: @cannot use 'tuple' as a dict key (unhashable
-- type: 'list')@ names the rejected value's type, then the first
-- unhashable type its hash reached.
unhashableError :: Text -> PyValue -> LiteralError
unhashableError role value =
  LiteralError Unhashable ("cannot use '" <> typeName value <> "' as " <> role <> " (unhashable type: '" <> typeName (culprit value) <> "')")
  where
    culprit = \case
      LitTuple elements | (bad : _) <- filter (not . hashable) elements -> culprit bad
      other -> other
    typeName = \case
      LitList _ -> "list"
      LitDict _ -> "dict"
      LitTuple _ -> "tuple"
      _ -> "object"

hashable :: PyValue -> Bool
hashable = \case
  LitList _ -> False
  LitDict _ -> False
  LitTuple elements -> all hashable elements
  _ -> True

-- ** Parser

newtype P a = P {runP :: Text -> Either LiteralError (a, Text)}

instance Functor P where
  fmap f (P run) = P (fmap (\(a, rest) -> (f a, rest)) . run)

instance Applicative P where
  pure value = P (\input -> Right (value, input))
  P runF <*> P runA = P $ \input -> do
    (f, rest) <- runF input
    (a, rest') <- runA rest
    Right (f a, rest')

instance Monad P where
  P run >>= next = P $ \input -> do
    (a, rest) <- run input
    runP (next a) rest

failP :: LiteralErrorKind -> Text -> P a
failP kind message = P (const (Left (LiteralError kind message)))

syntax :: Text -> P a
syntax = failP Malformed

peekP :: P Text
peekP = P (\input -> Right (input, input))

setP :: Text -> P ()
setP rest = P (const (Right ((), rest)))

-- | Bracket nesting deeper than this is a tokenizer error in CPython.
maxNesting :: Int
maxNesting = 200

-- Whitespace between tokens. Inside brackets newlines are insignificant;
-- at the top level they end the logical line.
skipSpace :: Int -> P ()
skipSpace depth = peekP >>= setP . go
  where
    go text = case T.uncons text of
      Just (c, rest)
        | c == ' ' || c == '\t' || c == '\f' -> go rest
        | c == '#' -> go (T.dropWhile (/= '\n') rest)
        | c == '\\', Just ('\n', after) <- T.uncons rest -> go after
        | c == '\n' && depth > 0 -> go rest
      _ -> text

-- Leading blank lines and comments; an indented first token is an
-- IndentationError.
skipLeading :: P ()
skipLeading = peekP >>= either (P . const . Left) setP . go False
  where
    go afterNewline text =
      let line = T.dropWhile (\c -> c == ' ' || c == '\t' || c == '\f') text
          indented = afterNewline && T.length (T.takeWhile (\c -> c == ' ' || c == '\t') text) > 0
       in case T.uncons line of
            Nothing -> Right line
            Just ('#', _) -> case T.uncons (T.dropWhile (/= '\n') line) of
              Just (_, rest) -> go True rest
              Nothing -> Right T.empty
            Just ('\n', rest) -> go True rest
            _
              | indented -> Left (LiteralError Malformed "unexpected indent")
              | otherwise -> Right line

-- Trailing newlines, blank lines, and comments after the expression.
skipTrailing :: P ()
skipTrailing = do
  skipSpace 0
  rest <- peekP
  case T.uncons rest of
    Just ('\n', after) -> setP after >> skipTrailing
    _ -> pure ()

topLevel :: P Expr
topLevel = do
  skipLeading
  rest <- peekP
  when (T.null rest) $ syntax "invalid syntax"
  expr <- expressionList 0
  skipTrailing
  pure expr

-- @a@, or a parenthesis-free tuple @a, b,@.
expressionList :: Int -> P Expr
expressionList depth = do
  first <- expression depth
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Just (',', after) -> setP after >> (ETuple . (first :) <$> tupleTail)
    _ -> pure first
  where
    tupleTail = do
      skipSpace depth
      rest <- peekP
      if startsExpression rest
        then do
          item <- expression depth
          skipSpace depth
          next <- peekP
          case T.uncons next of
            Just (',', after) -> setP after >> ((item :) <$> tupleTail)
            _ -> pure [item]
        else pure []

startsExpression :: Text -> Bool
startsExpression text = case T.uncons text of
  Just (c, rest) ->
    c `elem` ("([{'\"+-" :: String)
      || isDigit c
      || (c == '.' && maybe False (isDigit . fst) (T.uncons rest))
      || isAlpha c
      || c == '_'
  Nothing -> False

-- An operand, optionally followed by @+@/@-@ chains (only a real number
-- plus or minus an imaginary one converts; any other chain is a malformed
-- node, as in CPython).
expression :: Int -> P Expr
expression depth = do
  left <- unary depth
  chain left
  where
    chain left = do
      skipSpace depth
      rest <- peekP
      case T.uncons rest of
        Just (c, after) | c == '+' || c == '-' -> do
          setP after
          right <- unary depth
          case left of
            EBinary {} -> chain (EName "binary operation")
            EName "binary operation" -> chain left
            _ -> chain (EBinary left right)
        _ -> pure left

unary :: Int -> P Expr
unary depth = do
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Just (c, after)
      | c == '-' || c == '+' -> do
          setP after
          ESigned (c == '-') <$> unary depth
    _ -> primary depth

primary :: Int -> P Expr
primary depth = do
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Nothing -> syntax "unexpected EOF"
    Just (c, after)
      | c == '(' -> open after >> parenthesized (depth + 1)
      | c == '[' -> open after >> (EList <$> items (depth + 1) ']')
      | c == '{' -> open after >> braced (depth + 1)
      | isDigit c -> number
      | c == '.' -> case T.uncons after of
          Just (d, _) | isDigit d -> number
          Just ('.', more) | Just ('.', afterDots) <- T.uncons more -> setP afterDots >> pure (EUnsupported "Ellipsis")
          _ -> syntax "invalid syntax"
      | c == '\'' || c == '"' -> stringLiterals depth
      | isAlpha c || c == '_' -> word depth
      | otherwise -> syntax "invalid character"
  where
    open after = do
      when (depth >= maxNesting) $ syntax "too many nested parentheses"
      setP after

parenthesized :: Int -> P Expr
parenthesized depth = do
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Just (')', after) -> setP after >> pure (ETuple [])
    _ -> do
      first <- expression depth
      skipSpace depth
      next <- peekP
      case T.uncons next of
        Just (')', after) -> setP after >> pure first
        Just (',', after) -> setP after >> (ETuple . (first :) <$> items depth ')')
        _ -> syntax "invalid syntax"

-- Comma-separated items up to the closing bracket, trailing comma allowed.
items :: Int -> Char -> P [Expr]
items depth close = do
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Just (c, after) | c == close -> setP after >> pure []
    _ -> do
      item <- expression depth
      skipSpace depth
      next <- peekP
      case T.uncons next of
        Just (c, after)
          | c == close -> setP after >> pure [item]
          | c == ',' -> setP after >> ((item :) <$> items depth close)
        _ -> syntax "invalid syntax"

braced :: Int -> P Expr
braced depth = do
  skipSpace depth
  rest <- peekP
  case T.uncons rest of
    Just ('}', after) -> setP after >> pure (EDict [])
    _ -> do
      key <- expression depth
      skipSpace depth
      next <- peekP
      case T.uncons next of
        Just (':', after) -> do
          setP after
          value <- expression depth
          EDict . ((key, value) :) <$> members
        Just (c, after)
          | c == '}' -> setP after >> pure (ESet [key])
          | c == ',' -> setP after >> (ESet . (key :) <$> items depth '}')
        _ -> syntax "invalid syntax"
  where
    members = do
      skipSpace depth
      rest <- peekP
      case T.uncons rest of
        Just ('}', after) -> setP after >> pure []
        Just (',', after) -> do
          setP after
          skipSpace depth
          more <- peekP
          case T.uncons more of
            Just ('}', after') -> setP after' >> pure []
            _ -> do
              key <- expression depth
              skipSpace depth
              colon <- peekP
              case T.uncons colon of
                Just (':', after') -> do
                  setP after'
                  value <- expression depth
                  ((key, value) :) <$> members
                _ -> syntax "invalid syntax"
        _ -> syntax "invalid syntax"

-- Names, keywords, and string prefixes.
word :: Int -> P Expr
word depth = do
  rest <- peekP
  let (name, after) = T.span (\c -> isAlphaNum c || c == '_') rest
  case T.uncons after of
    Just (q, _) | q == '\'' || q == '"', isPrefix name -> stringLiterals depth
    _ -> do
      setP after
      case name of
        "True" -> pure (EConst (LitBool True))
        "False" -> pure (EConst (LitBool False))
        "None" -> pure (EConst LitNone)
        _ -> do
          skipSpace depth
          next <- peekP
          case T.uncons next of
            Just ('(', call) -> do
              let inner = T.dropWhile (`elem` (" \t\n\f" :: String)) call
              case (name, T.uncons inner) of
                ("set", Just (')', afterCall)) -> setP afterCall >> pure (EUnsupported "set")
                _ -> syntax "malformed node or string"
            _ -> pure (EName name)

isPrefix :: Text -> Bool
isPrefix name = T.toLower name `elem` ["r", "u", "b", "br", "rb", "f", "fr", "rf", "t", "tr", "rt"]

-- One or more adjacent string literals, concatenated.
stringLiterals :: Int -> P Expr
stringLiterals depth = do
  first <- stringLiteral
  rest <- more
  let pieces = first : rest
      bytes = [() | PieceBytes <- pieces]
  if
    | not (null bytes) && length bytes /= length pieces -> syntax "cannot mix bytes and nonbytes literals"
    | not (null bytes) -> pure (EUnsupported "bytes")
    | or [True | PieceFormat <- pieces] -> pure (EName "f-string")
    | (what : _) <- [what | PieceUnsupported what <- pieces] -> pure (EUnsupported what)
    | otherwise -> pure (EConst (LitStr (T.concat [text | PieceText text <- pieces])))
  where
    more = do
      skipSpace depth
      next <- peekP
      if startsString next then (:) <$> stringLiteral <*> more else pure []

startsString :: Text -> Bool
startsString text =
  let (name, after) = T.span (\c -> isAlphaNum c || c == '_') text
   in case T.uncons after of
        Just (q, _) | q == '\'' || q == '"' -> T.null name || isPrefix name
        _ -> False

-- One literal of a concatenation.
data Piece = PieceText Text | PieceBytes | PieceFormat | PieceUnsupported Text

-- A single literal. Bytes and f/t-strings are only refused after the whole
-- concatenation is read, as in CPython.
stringLiteral :: P Piece
stringLiteral = do
  rest <- peekP
  let (prefix, afterPrefix) = T.span isAlpha rest
      lowered = T.map toLower prefix
      raw = T.any (== 'r') lowered
  case T.uncons afterPrefix of
    Just (q, _) -> do
      let triple = T.replicate 3 (T.singleton q)
          isTriple = triple `T.isPrefixOf` afterPrefix
          delimiter = if isTriple then triple else T.singleton q
      (body, after) <- either (P . const . Left) pure (scanString isTriple delimiter (T.drop (T.length delimiter) afterPrefix))
      setP after
      if
        | T.any (`elem` ("ft" :: String)) lowered -> pure PieceFormat
        | T.any (== 'b') lowered -> pure PieceBytes
        | raw -> pure (PieceText body)
        | otherwise -> case unescape body of
            Right decoded -> pure (PieceText decoded)
            Left (LiteralError Unsupported what) -> pure (PieceUnsupported what)
            Left problem -> P (const (Left problem))
    Nothing -> syntax "invalid syntax"

-- The raw body of a string up to its closing delimiter: a backslash always
-- takes the next character with it.
scanString :: Bool -> Text -> Text -> Either LiteralError (Text, Text)
scanString isTriple delimiter = go []
  where
    go acc text
      | delimiter `T.isPrefixOf` text = Right (T.concat (reverse acc), T.drop (T.length delimiter) text)
      | otherwise =
          let (chunk, rest) = T.break stop text
           in case T.uncons rest of
                Nothing -> malformed "unterminated string literal"
                Just ('\\', after) -> case T.uncons after of
                  Just (escaped, after') -> go (T.pack ['\\', escaped] : chunk : acc) after'
                  Nothing -> malformed "unterminated string literal"
                Just ('\n', after)
                  | isTriple -> go ("\n" : chunk : acc) after
                  | otherwise -> malformed "unterminated string literal"
                Just (c, after)
                  | delimiter `T.isPrefixOf` rest -> go (chunk : acc) rest
                  | otherwise -> go (T.singleton c : chunk : acc) after
    first = T.head delimiter
    stop c = c == '\\' || c == '\n' || c == first

-- Escape processing for a non-raw @str@ literal.
unescape :: Text -> Either LiteralError Text
unescape body
  | not (T.any (== '\\') body) = Right body
  | otherwise = fromCodePoints <$> go (T.unpack body)
  where
    go [] = Right []
    go ('\\' : rest) = escape rest
    go (c : rest) = (c :) <$> go rest
    escape = \case
      '\n' : rest -> go rest
      '\\' : rest -> ('\\' :) <$> go rest
      '\'' : rest -> ('\'' :) <$> go rest
      '"' : rest -> ('"' :) <$> go rest
      'a' : rest -> ('\a' :) <$> go rest
      'b' : rest -> ('\b' :) <$> go rest
      'f' : rest -> ('\f' :) <$> go rest
      'n' : rest -> ('\n' :) <$> go rest
      'r' : rest -> ('\r' :) <$> go rest
      't' : rest -> ('\t' :) <$> go rest
      'v' : rest -> ('\v' :) <$> go rest
      'x' : rest -> fixed 2 "\\xXX" rest
      'u' : rest -> fixed 4 "\\uXXXX" rest
      'U' : rest -> fixed 8 "\\UXXXXXXXX" rest
      -- A well-formed \N{name}: CPython resolves the name in its Unicode
      -- database, which this module does not carry.
      'N' : '{' : rest
        | (name, '}' : _) <- break (== '}') rest, not (null name), all (\c -> isAlphaNum c || c `elem` (" -" :: String)) name ->
            unsupported "\\N{...} escape"
      'N' : _ -> malformed "malformed \\N character escape"
      rest@(c : _) | isOctDigit c ->
        let (digits, after) = span isOctDigit (take 3 rest)
            value = foldl (\acc d -> acc * 8 + digitValue d) 0 digits
         in (chr value :) <$> go (after ++ drop 3 rest)
      rest -> ('\\' :) <$> go rest
    fixed width name rest =
      let digits = takeWhile isHexDigit (take width rest)
       in if length digits < width
            then malformed ("truncated " <> name <> " escape")
            else
              let value = foldl (\acc d -> acc * 16 + digitValue d) 0 digits
               in if
                    | value > 0x10FFFF -> malformed "illegal Unicode character"
                    | otherwise -> (chr value :) <$> go (drop width rest)
    digitValue d
      | isDigit d = ord d - ord '0'
      | otherwise = ord (toLower d) - ord 'a' + 10

-- ** Numbers

number :: P Expr
number = do
  rest <- peekP
  case T.unpack (T.take 2 rest) of
    ['0', base] | toLower base `elem` ("xob" :: String) -> radix (toLower base) (T.drop 2 rest)
    _ -> decimal rest
  where
    radix base text = do
      let valid = case base of
            'x' -> isHexDigit
            'o' -> isOctDigit
            _ -> (`elem` ("01" :: String))
          radixValue = case base of
            'x' -> 16
            'o' -> 8
            _ -> 2
          (token, after) = T.span (\c -> valid c || c == '_') text
      digits <- either (P . const . Left) pure (underscored True valid token)
      when (T.null digits) $ syntax "invalid literal"
      endOfNumber after
      setP after
      pure (EConst (LitInt (T.foldl' (\acc d -> acc * radixValue + toInteger (hexValue d)) 0 digits)))
    hexValue d
      | isDigit d = ord d - ord '0'
      | otherwise = ord (toLower d) - ord 'a' + 10
    decimal text = do
      let (whole, afterWhole) = T.span (\c -> isDigit c || c == '_') text
      wholeDigits <- either (P . const . Left) pure (underscored False isDigit whole)
      (fraction, afterFraction, hasPoint) <- case T.uncons afterWhole of
        Just ('.', more) -> do
          let (frac, afterFrac) = T.span (\c -> isDigit c || c == '_') more
          fracDigits <- if T.null frac then pure "" else either (P . const . Left) pure (underscored False isDigit frac)
          pure (fracDigits, afterFrac, True)
        _ -> pure ("", afterWhole, False)
      when (T.null wholeDigits && T.null fraction) $ syntax "invalid syntax"
      (power, afterExponent, hasExponent) <- case T.uncons afterFraction of
        Just (e, more) | e == 'e' || e == 'E' -> do
          let (sign, unsigned) = case T.uncons more of
                Just (s, digits) | s == '+' || s == '-' -> (if s == '-' then -1 else 1, digits)
                _ -> (1 :: Integer, more)
              (expDigits, afterExp) = T.span (\c -> isDigit c || c == '_') unsigned
          cleaned <- either (P . const . Left) pure (underscored False isDigit expDigits)
          when (T.null cleaned) $ syntax "invalid decimal literal"
          pure (sign * read (T.unpack cleaned), afterExp, True)
        _ -> pure (0, afterFraction, False)
      case T.uncons afterExponent of
        Just (j, afterImaginary) | j == 'j' || j == 'J' -> do
          endOfNumber afterImaginary
          setP afterImaginary
          pure EImaginary
        _ -> do
          endOfNumber afterExponent
          setP afterExponent
          real hasPoint hasExponent wholeDigits fraction power
    real hasPoint hasExponent wholeDigits fraction power =
      if hasPoint || hasExponent
        then pure (EConst (LitFloat (decimalToDouble wholeDigits fraction power)))
        else do
          when (T.length wholeDigits > 1 && T.head wholeDigits == '0' && T.any (/= '0') wholeDigits) $
            syntax "leading zeros in decimal integer literals are not permitted"
          -- CPython counts the digits of the value, not leading zeros.
          when (T.length (T.dropWhile (== '0') wholeDigits) > maxIntStrDigits) $
            syntax "Exceeds the limit (4300 digits) for integer string conversion"
          pure (EConst (LitInt (read (T.unpack wholeDigits))))
    endOfNumber after = case T.uncons after of
      Just (c, _) | isAlphaNum c || c == '_' -> syntax "invalid decimal literal"
      _ -> pure ()

-- Digits with single underscores between them; returns the digits alone.
-- A radix literal may put an underscore right after its @0x@/@0o@/@0b@.
underscored :: Bool -> (Char -> Bool) -> Text -> Either LiteralError Text
underscored leadingAllowed _ token
  | T.null token = Right token
  | T.head token == '_' && not leadingAllowed = malformed "invalid literal"
  | "__" `T.isInfixOf` token || T.last token == '_' = malformed "invalid literal"
  | otherwise = Right (T.filter (/= '_') token)

-- Correctly rounded decimal-to-double conversion (as CPython's @float()@),
-- deciding far-out-of-range magnitudes without building huge rationals.
decimalToDouble :: Text -> Text -> Integer -> Double
decimalToDouble whole fraction power =
  let digits = T.dropWhile (== '0') (whole <> fraction)
      scale = power - toInteger (T.length fraction)
      magnitude = toInteger (T.length digits) + scale
   in if
        | T.null digits -> 0
        | magnitude > 400 -> 1 / 0
        | magnitude < -400 -> 0
        | otherwise -> fromRational (fromInteger (read (T.unpack digits)) * (10 ^^ scale))
