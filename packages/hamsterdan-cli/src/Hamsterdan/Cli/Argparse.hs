{-# LANGUAGE CApiFFI #-}

-- | CPython 3.14's @argparse@, for the command lines Hamsterdan's operator
-- tools declare.
--
-- A 'Parser' is declared the way the reference declares its
-- @ArgumentParser@: options that store, append or set a flag, typed as
-- @str@, @int@ or @pathlib.Path@, with choices, defaults and required
-- markers, the automatic @-h/--help@, and one required group of
-- subcommands. 'parseArgs' then classifies and consumes the argument
-- strings exactly as @ArgumentParser.parse_args@ does (prefix
-- abbreviations, @--opt=value@, single-dash chaining, negative-number-like
-- values, @--@, subparsers and their unrecognized arguments), and returns
-- the same namespace or the same help, usage and error text, wrapped by
-- the same @HelpFormatter@ and @textwrap@ rules to the same width.
--
-- Help is never colored: the reference colors it only when the stream is a
-- terminal, and its plain text is what it writes to a pipe.
module Hamsterdan.Cli.Argparse
  ( -- * Declaring a parser
    Parser (..)
  , Action (..)
  , Behavior (..)
  , ValueType (..)
  , Value (..)
  , newParser
  , option
  , subcommands

    -- * Parsing
  , Namespace
  , Outcome (..)
  , parseArgs
  , lookupText
  , lookupInteger
  , lookupBool
  , lookupList

    -- * Formatting
  , formatUsage
  , formatHelp
  , wrap

    -- * Python semantics the parser relies on
  , pythonInt
  , pathText
  , terminalColumns
  , environmentColumns
  ) where

import Data.Array (Array, bounds, listArray, (!))
import Data.Char (GeneralCategory (..), generalCategory, isAlphaNum)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
import Foreign.C.Types (CInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)
import Hamsterdan.PyText qualified as Py
import Hamsterdan.PyLiteral (strRepr)

-- ---------------------------------------------------------------------------
-- Declarations

-- | How a value string is converted (@type=@).
data ValueType
  = -- | @str@ (no conversion).
    AsStr
  | -- | @int@: 'pythonInt', or @invalid int value@.
    AsInt
  | -- | @pathlib.Path@: never fails; the namespace holds @str(Path(value))@.
    AsPath
  deriving stock (Eq, Show)

-- | A namespace value.
data Value
  = None
  | Str Text
  | IntValue Integer
  | BoolValue Bool
  | List [Value]
  deriving stock (Eq, Show)

-- | What an action does with its arguments.
data Behavior
  = -- | @action="store"@.
    Store
  | -- | @action="append"@.
    Append
  | -- | @action="store_true"@.
    StoreTrue
  | -- | @action="help"@.
    ShowHelp
  | -- | @add_subparsers(dest=..., required=...)@ with its parsers, in
    -- @add_parser@ order.
    Subcommands [(Text, Parser)]
  deriving stock (Show)

-- | One @add_argument@.
data Action = Action
  { optionStrings :: [Text]
  -- ^ Empty for a positional.
  , dest :: Text
  , behavior :: Behavior
  , valueType :: ValueType
  , choices :: Maybe [Text]
  , required :: Bool
  , help :: Maybe Text
  , metavar :: Maybe Text
  , defaultValue :: Maybe Value
  -- ^ 'Nothing' is @argparse.SUPPRESS@.
  }
  deriving stock (Show)

-- | One @ArgumentParser@ (with @add_help=True@).
data Parser = Parser
  { prog :: Text
  , description :: Maybe Text
  , actions :: [Action]
  -- ^ In registration order, starting with @-h/--help@.
  }
  deriving stock (Show)

-- | @ArgumentParser(prog=..., description=...)@ followed by the given
-- @add_argument@ calls.
newParser :: Text -> Maybe Text -> [Action] -> Parser
newParser prog description declared =
  Parser
    { prog
    , description
    , actions =
        Action
          { optionStrings = ["-h", "--help"]
          , dest = "help"
          , behavior = ShowHelp
          , valueType = AsStr
          , choices = Nothing
          , required = False
          , help = Just "show this help message and exit"
          , metavar = Nothing
          , defaultValue = Nothing
          }
          : declared
    }

-- | @add_argument(*option_strings)@ with the default destination
-- (the first long option, dashes as underscores) and @action="store"@.
option :: [Text] -> Action
option strings =
  Action
    { optionStrings = strings
    , dest = T.replace "-" "_" (T.dropWhile (== '-') longest)
    , behavior = Store
    , valueType = AsStr
    , choices = Nothing
    , required = False
    , help = Nothing
    , metavar = Nothing
    , defaultValue = Just None
    }
  where
    longest = fromMaybe (headOr "" strings) (find ("--" `T.isPrefixOf`) strings)

-- | @add_subparsers(dest=dest, required=True)@ and one @add_parser(name)@
-- per entry. Each subparser's @prog@ is the parent's followed by its name.
subcommands :: Text -> Text -> [(Text, [Action])] -> Action
subcommands parentProg destination entries =
  Action
    { optionStrings = []
    , dest = destination
    , behavior = Subcommands [(name, newParser (parentProg <> " " <> name) Nothing declared) | (name, declared) <- entries]
    , valueType = AsStr
    , choices = Just (map fst entries)
    , required = True
    , help = Nothing
    , metavar = Nothing
    , defaultValue = Just None
    }

data Nargs = NargsOne | NargsZero | NargsParser
  deriving stock (Eq)

nargs :: Action -> Nargs
nargs action = case action.behavior of
  Store -> NargsOne
  Append -> NargsOne
  StoreTrue -> NargsZero
  ShowHelp -> NargsZero
  Subcommands _ -> NargsParser

-- ---------------------------------------------------------------------------
-- Parsing

-- | The parsed namespace: destination to value.
type Namespace = Map Text Value

-- | What @parser.parse_args(argv)@ does.
data Outcome
  = -- | The parse finished.
    Parsed Namespace
  | -- | The parser exited: the status, what it wrote to stdout and what it
    -- wrote to stderr (help: status 0 on stdout; errors: status 2 on
    -- stderr).
    Exited Int Text Text
  deriving stock (Eq, Show)

lookupText :: Text -> Namespace -> Maybe Text
lookupText key namespace = case Map.lookup key namespace of
  Just (Str text) -> Just text
  _ -> Nothing

lookupInteger :: Text -> Namespace -> Maybe Integer
lookupInteger key namespace = case Map.lookup key namespace of
  Just (IntValue value) -> Just value
  _ -> Nothing

lookupBool :: Text -> Namespace -> Bool
lookupBool key namespace = Map.lookup key namespace == Just (BoolValue True)

lookupList :: Text -> Namespace -> [Value]
lookupList key namespace = case Map.lookup key namespace of
  Just (List values) -> values
  _ -> []

-- | A parse that stops before finishing.
data Stop
  = -- | @argparse.ArgumentError@ (its @str@).
    ArgumentError Text
  | -- | @parser.exit(...)@ from a nested parser or the help action.
    Exit Int Text Text

type P = Either Stop

argumentError :: Action -> Text -> P a
argumentError action message = Left (ArgumentError (maybe message (\name -> "argument " <> name <> ": " <> message) (actionName action)))

-- | @_get_action_name@.
actionName :: Action -> Maybe Text
actionName action
  | not (null action.optionStrings) = Just (T.intercalate "/" action.optionStrings)
  | Just name <- action.metavar = Just name
  | otherwise = Just action.dest

-- | @parser.parse_args(argv)@ at a formatter width (@COLUMNS - 2@).
parseArgs :: Int -> Parser -> [Text] -> Outcome
parseArgs width parser argv = case parseKnownArgs width parser argv of
  Left (Exit status out err) -> Exited status out err
  Left (ArgumentError message) -> usageError width parser message
  Right (namespace, extras)
    | null extras -> Parsed namespace
    | otherwise -> usageError width parser ("unrecognized arguments: " <> T.unwords extras)

usageError :: Int -> Parser -> Text -> Outcome
usageError width parser message = Exited 2 "" (formatUsage width parser <> parser.prog <> ": error: " <> message <> "\n")

-- | @parse_known_args@: errors at this level already rendered with this
-- parser's usage.
parseKnownArgs :: Int -> Parser -> [Text] -> Either Stop (Namespace, [Text])
parseKnownArgs width parser argv =
  case parseKnownInner width parser argv defaults of
    Left (ArgumentError message) -> case usageError width parser message of
      Exited status out err -> Left (Exit status out err)
      Parsed _ -> Left (ArgumentError message)
    Left stop -> Left stop
    Right result -> Right result
  where
    defaults = Map.fromList [(action.dest, value) | action <- reverse parser.actions, Just value <- [action.defaultValue]]

-- | One interpretation of an option string: the action (if any), the
-- option string, the separator and the explicit argument.
type OptionTuple = (Maybe Int, Text, Maybe Text, Maybe Text)

data St = St
  { namespace :: Namespace
  , seen :: Set.Set Int
  , extras :: [Text]
  , positionals :: [Int]
  , unrecognized :: [Text]
  }

parseKnownInner :: Int -> Parser -> [Text] -> Namespace -> P (Namespace, [Text])
parseKnownInner width parser argStrings initial = do
  st <- mainLoop 0 St {namespace = initial, seen = Set.empty, extras = [], positionals = positionalIndices, unrecognized = []}
  let missing = [name | (index, action) <- indexed, not (Set.member index st.seen), action.required, Just name <- [actionName action]]
  if not (null missing)
    then Left (ArgumentError ("the following arguments are required: " <> T.intercalate ", " missing))
    else do
      converted <- convertDefaults st
      pure (converted, st.extras <> st.unrecognized)
  where
    indexed = zip [0 :: Int ..] parser.actions
    actionArray = listArray (0, length parser.actions - 1) parser.actions :: Array Int Action
    actionAt i = actionArray ! i
    positionalIndices = [index | (index, action) <- indexed, null action.optionStrings]
    optionMap = [(string, index) | (index, action) <- indexed, string <- action.optionStrings]
    argArray = listArray (0, length argStrings - 1) argStrings :: Array Int Text
    argAt i = argArray ! i
    slice from to = [argAt i | i <- [from .. to - 1]]
    count = length argStrings

    -- @_parse_optional@.
    parseOptional :: Text -> Maybe [OptionTuple]
    parseOptional arg
      | T.null arg = Nothing
      | T.head arg /= '-' = Nothing
      | Just index <- lookup arg optionMap = Just [(Just index, arg, Nothing, Nothing)]
      | T.length arg == 1 = Nothing
      | (name, rest) <- T.breakOn "=" arg
      , not (T.null rest)
      , Just index <- lookup name optionMap =
          Just [(Just index, name, Just "=", Just (T.drop 1 rest))]
      | tuples@(_ : _) <- optionTuples arg = Just tuples
      | negativeNumberLike arg = Nothing
      | T.any (== ' ') arg = Nothing
      | otherwise = Just [(Nothing, arg, Nothing, Nothing)]

    -- @re.match(r'-\.?\d', arg)@ (no option looks like a negative number).
    negativeNumberLike text = case T.unpack text of
      '-' : '.' : c : _ -> decimal c
      '-' : c : _ -> decimal c
      _ -> False
    decimal c = generalCategory c == DecimalNumber

    -- @_get_option_tuples@ (with @allow_abbrev=True@).
    optionTuples :: Text -> [OptionTuple]
    optionTuples arg
      | "--" `T.isPrefixOf` arg =
          [(Just index, string, sep, explicit) | (string, index) <- optionMap, prefix `T.isPrefixOf` string]
      | otherwise =
          [ if string == short then (Just index, string, Just "", Just (T.drop 2 arg)) else (Just index, string, sep, explicit)
          | (string, index) <- optionMap
          , string == short || prefix `T.isPrefixOf` string
          ]
      where
        (prefix, sep, explicit) = case T.breakOn "=" arg of
          (before, after) | not (T.null after) -> (before, Just "=", Just (T.drop 1 after))
          _ -> (arg, Nothing, Nothing)
        short = T.take 2 arg

    classified :: [Maybe [OptionTuple]]
    classified = go argStrings
      where
        go = \case
          [] -> []
          "--" : rest -> Nothing : map (const Nothing) rest
          arg : rest -> parseOptional arg : go rest

    patternString :: String
    patternString = go argStrings classified
      where
        go ("--" : rest) _ = '-' : map (const 'A') rest
        go (_ : rest) (c : cs) = (if isJust c then 'O' else 'A') : go rest cs
        go _ _ = []

    patternArray = listArray (0, count - 1) patternString :: Array Int Char
    patternFrom i = drop i patternString
    optionIndices = Map.fromList [(i, tuples) | (i, Just tuples) <- zip [0 ..] classified]
    maxOption = maybe (-1) fst (Map.lookupMax optionIndices)

    mainLoop :: Int -> St -> P St
    mainLoop start st
      | start <= maxOption = do
          let next = maybe maxOption fst (Map.lookupGE start optionIndices)
          if start /= next
            then do
              (st', end) <- consumePositionals start st
              if end > start then mainLoop end st' else afterPositionals end next st'
            else afterPositionals start next st
      | otherwise = do
          (st', stop) <- consumePositionals start st
          pure st' {extras = st'.extras <> drop stop argStrings}

    afterPositionals start next st = do
      (start', st') <-
        if Map.member start optionIndices
          then pure (start, st)
          else pure (next, st {extras = st.extras <> slice start next})
      (st'', stop) <- consumeOptional start' st'
      mainLoop stop st''

    -- @consume_optional@.
    consumeOptional :: Int -> St -> P (St, Int)
    consumeOptional start st = do
      let tuples = Map.findWithDefault [] start optionIndices
      case tuples of
        _ : _ : _ ->
          Left (ArgumentError ("ambiguous option: " <> argAt start <> " could match " <> T.intercalate ", " [s | (_, s, _, _) <- tuples]))
        [] -> pure (st, start + 1)
        [(Nothing, _, _, _)] -> pure (st {extras = st.extras <> [argAt start]}, start + 1)
        [(Just index, string, sep, explicit)] -> do
          (taken, stop, extra) <- chain index string sep explicit []
          st' <- foldlM (\s (i, args, optString) -> takeAction i args (Just optString) s) st taken
          pure (st' {extras = st'.extras <> extra}, stop)
      where
        chain index string sep explicit acc = do
          let action = actionAt index
          case explicit of
            Just ex -> do
              argCount <- matchArgument action "A"
              if argCount == 0 && T.index string 1 /= '-' && not (T.null ex)
                then
                  if maybe False (not . T.null) sep || T.head ex == '-'
                    then argumentError action ("ignored explicit argument " <> strRepr ex)
                    else do
                      let acc' = acc <> [(index, [], string)]
                          next = T.pack ['-', T.head ex]
                      case lookup next optionMap of
                        Just index' ->
                          let ex' = T.drop 1 ex
                              (sep', explicit')
                                | T.null ex' = (Nothing, Nothing)
                                | T.head ex' == '=' = (Just "=", Just (T.drop 1 ex'))
                                | otherwise = (Just "", Just ex')
                           in chain index' next sep' explicit' acc'
                        Nothing -> pure (acc', start + 1, ["-" <> ex])
                else
                  if argCount == 1
                    then pure (acc <> [(index, [ex], string)], start + 1, [])
                    else argumentError action ("ignored explicit argument " <> strRepr ex)
            Nothing -> do
              argCount <- matchArgument action (patternFrom (start + 1))
              pure (acc <> [(index, slice (start + 1) (start + 1 + argCount), string)], start + 1 + argCount, [])

    -- @_match_argument@ for an optional.
    matchArgument :: Action -> String -> P Int
    matchArgument action selected = case nargs action of
      NargsZero -> pure 0
      NargsOne -> case selected of
        'A' : _ -> pure 1
        _ -> argumentError action "expected one argument"
      NargsParser -> case selected of
        'A' : rest -> pure (1 + length (takeWhile (`elem` ("AO" :: String)) rest))
        _ -> argumentError action "expected at least one argument"

    -- @consume_positionals@.
    consumePositionals :: Int -> St -> P (St, Int)
    consumePositionals start st = do
      let counts = matchPartial (map actionAt st.positionals) (patternFrom start)
          go s position [] = pure (s, position)
          go s position ((index, argCount) : rest) = do
            let action = actionAt index
                args = slice position (position + argCount)
                cleaned = case nargs action of
                  NargsParser
                    | position < count && patternArray ! position == '-' -> removeFirst "--" args
                    | otherwise -> args
                  _
                    | '-' `elem` take argCount (patternFrom position) -> removeFirst "--" args
                    | otherwise -> args
            s' <- takeAction index cleaned Nothing s
            go s' (position + argCount) rest
      (st', end) <- go st start (zip st.positionals counts)
      pure (st' {positionals = drop (length counts) st'.positionals}, end)

    -- @take_action@.
    takeAction :: Int -> [Text] -> Maybe Text -> St -> P St
    takeAction index args _ st = do
      let action = actionAt index
          st' = st {seen = Set.insert index st.seen}
      case action.behavior of
        ShowHelp -> Left (Exit 0 (formatHelp width parser) "")
        StoreTrue -> pure st' {namespace = Map.insert action.dest (BoolValue True) st'.namespace}
        Store -> do
          value <- singleValue action args
          pure st' {namespace = Map.insert action.dest value st'.namespace}
        Append -> do
          value <- singleValue action args
          let previous = case Map.lookup action.dest st'.namespace of
                Just (List items) -> items
                _ -> []
          pure st' {namespace = Map.insert action.dest (List (previous <> [value])) st'.namespace}
        Subcommands parsers -> case args of
          [] -> pure st'
          name : rest -> do
            checkChoice action name
            let namespace = Map.insert action.dest (Str name) st'.namespace
            case lookup name parsers of
              Nothing -> pure st' {namespace}
              Just sub -> do
                (subNamespace, subExtras) <- parseKnownArgs width sub rest
                pure st' {namespace = Map.union subNamespace namespace, unrecognized = st'.unrecognized <> subExtras}

    singleValue action = \case
      [arg] -> do
        value <- convert action arg
        case value of
          Str text -> checkChoice action text
          IntValue i -> checkChoice action (T.pack (show i))
          _ -> pure ()
        pure value
      _ -> pure (List [])

    checkChoice action text = case action.choices of
      Just names
        | text `notElem` names ->
            argumentError action ("invalid choice: " <> strRepr text <> " (choose from " <> T.intercalate ", " (map strRepr names) <> ")")
      _ -> pure ()

    -- Defaults that are strings are converted by the action's type.
    convertDefaults st =
      foldlM
        ( \namespace (index, action) -> case action.defaultValue of
            Just (Str text)
              | not (Set.member index st.seen)
              , not action.required
              , Map.lookup action.dest namespace == Just (Str text)
              , action.valueType /= AsStr -> do
                  value <- convert action text
                  pure (Map.insert action.dest value namespace)
            _ -> pure namespace
        )
        st.namespace
        indexed

convert :: Action -> Text -> P Value
convert action text = case action.valueType of
  AsStr -> pure (Str text)
  AsPath -> pure (Str (pathText text))
  AsInt -> case pythonInt text of
    Just value -> pure (IntValue value)
    Nothing -> argumentError action ("invalid int value: " <> strRepr text)

-- | @_match_arguments_partial@ for the positional patterns.
matchPartial :: [Action] -> String -> [Int]
matchPartial actions selected = go (length actions)
  where
    go 0 = []
    go n = case matchSequence (map candidates (take n actions)) selected of
      Just (lengths, end)
        | end < length selected && selected !! end == 'O' -> reverse (dropWhile (== 0) (reverse lengths))
        | otherwise -> lengths
      Nothing -> go (n - 1)
    candidates action rest =
      let dashes = length (takeWhile (== '-') rest)
       in case drop dashes rest of
            'A' : after -> case nargs action of
              NargsParser -> [dashes + 1 + k | k <- [length after, length after - 1 .. 0]]
              _ -> let trailing = length (takeWhile (== '-') after) in [dashes + 1 + k | k <- [trailing, trailing - 1 .. 0]]
            _ -> []

-- | The first way (in the regular expression's backtracking order) to match
-- the patterns in sequence, with the total length matched.
matchSequence :: [String -> [Int]] -> String -> Maybe ([Int], Int)
matchSequence [] _ = Just ([], 0)
matchSequence (candidates : rest) selected =
  firstJust
    [ (\(lengths, total) -> (n : lengths, n + total)) <$> matchSequence rest (drop n selected)
    | n <- candidates selected
    ]
  where
    firstJust = foldr (\x acc -> maybe acc Just x) Nothing

removeFirst :: (Eq a) => a -> [a] -> [a]
removeFirst x = \case
  [] -> []
  y : ys
    | x == y -> ys
    | otherwise -> y : removeFirst x ys

foldlM :: (Monad m) => (b -> a -> m b) -> b -> [a] -> m b
foldlM step = go
  where
    go acc = \case
      [] -> pure acc
      x : xs -> step acc x >>= \acc' -> go acc' xs

headOr :: a -> [a] -> a
headOr fallback = \case
  x : _ -> x
  [] -> fallback

-- ---------------------------------------------------------------------------
-- Formatting

-- | @parser.format_usage()@ at a formatter width (@COLUMNS - 2@).
formatUsage :: Int -> Parser -> Text
formatUsage width parser = "usage: " <> usageBody width parser <> "\n"

-- | @_format_args@ for the action, with its default metavar.
formatArgs :: Action -> Text -> Text
formatArgs action fallback = case nargs action of
  NargsParser -> metavarFor action fallback <> " ..."
  _ -> metavarFor action fallback

metavarFor :: Action -> Text -> Text
metavarFor action fallback = case (action.metavar, action.choices) of
  (Just name, _) -> name
  (Nothing, Just names) -> "{" <> T.intercalate "," names <> "}"
  _ -> fallback

usageParts :: Parser -> ([Text], [Text])
usageParts parser = (map optionalPart optionals, map positionalPart positionals)
  where
    optionals = filter (not . null . (.optionStrings)) parser.actions
    positionals = filter (null . (.optionStrings)) parser.actions
    optionalPart action =
      let first = headOr "" action.optionStrings
          part = if nargs action == NargsZero then first else first <> " " <> formatArgs action (T.toUpper action.dest)
       in if action.required then part else "[" <> part <> "]"
    positionalPart action = formatArgs action action.dest

usageBody :: Int -> Parser -> Text
usageBody width parser
  | T.length prefix + T.length full <= textWidth = full
  | fromIntegral (T.length prefix + progLength) <= (0.75 * fromIntegral textWidth :: Double) =
      let indent = T.replicate (T.length prefix + progLength + 1) " "
          lines'
            | not (null optParts) = getLines (parser.prog : optParts) indent True <> getLines posParts indent False
            | not (null posParts) = getLines (parser.prog : posParts) indent True
            | otherwise = [parser.prog]
       in T.intercalate "\n" lines'
  | otherwise =
      let indent = T.replicate (T.length prefix) " "
          joined = getLines (optParts <> posParts) indent False
          lines' = if length joined > 1 then getLines optParts indent False <> getLines posParts indent False else joined
       in T.intercalate "\n" (parser.prog : lines')
  where
    prefix = "usage: " :: Text
    textWidth = width
    progLength = T.length parser.prog
    (optParts, posParts) = usageParts parser
    full = T.unwords (parser.prog : optParts <> posParts)
    getLines parts indent withPrefix =
      let indentLength = T.length indent
          start = if withPrefix then T.length prefix - 1 else indentLength - 1
          go [] line _ acc = reverse (if null line then acc else (indent <> T.unwords (reverse line)) : acc)
          go (part : rest) line lineLen acc
            | lineLen + 1 + T.length part > textWidth && not (null line) =
                go rest [part] (indentLength - 1 + T.length part + 1) ((indent <> T.unwords (reverse line)) : acc)
            | otherwise = go rest (part : line) (lineLen + T.length part + 1) acc
          result = go parts [] start []
       in if withPrefix
            then case result of
              first : others -> T.drop indentLength first : others
              [] -> []
            else result

-- | @parser.format_help()@ at a formatter width (@COLUMNS - 2@).
formatHelp :: Int -> Parser -> Text
formatHelp width parser =
  normalize $
    T.concat
      [ formatUsage width parser <> "\n"
      , maybe "" (\text -> T.intercalate "\n" (wrap (max width 11) (collapse text)) <> "\n\n") parser.description
      , section "positional arguments" positionals
      , section "options" optionals
      ]
  where
    positionals = filter (null . (.optionStrings)) parser.actions
    optionals = filter (not . null . (.optionStrings)) parser.actions
    maxHelpPosition = min 24 (max (width - 20) 4)
    invocation action
      | null action.optionStrings = metavarFor action action.dest
      | nargs action == NargsZero = T.intercalate ", " action.optionStrings
      | otherwise = T.intercalate ", " action.optionStrings <> " " <> formatArgs action (T.toUpper action.dest)
    actionMaxLength = maximum (0 : map ((+ 2) . T.length . invocation) parser.actions)
    helpPosition = min (actionMaxLength + 2) maxHelpPosition
    helpWidth = max (width - helpPosition) 11
    actionWidth = helpPosition - 2 - 2
    section _ [] = ""
    section heading items = "\n" <> heading <> ":\n" <> T.concat (map entry items) <> "\n"
    entry action =
      let header = invocation action
       in case action.help of
            Just text
              | not (T.null text) ->
                  let (first, indentFirst)
                        | T.length header <= actionWidth = ("  " <> T.justifyLeft actionWidth ' ' header <> "  ", 0)
                        | otherwise = ("  " <> header <> "\n", helpPosition)
                   in if T.null (T.strip text)
                        then if "\n" `T.isSuffixOf` first then first else first <> "\n"
                        else case wrap helpWidth (collapse text) of
                          [] -> first
                          line : others ->
                            first
                              <> T.replicate indentFirst " "
                              <> line
                              <> "\n"
                              <> T.concat [T.replicate helpPosition " " <> l <> "\n" | l <- others]
            _ -> "  " <> header <> "\n"
    normalize text = T.dropAround (== '\n') (collapseBreaks text) <> "\n"
    collapseBreaks text = case T.breakOn "\n\n\n" text of
      (before, after)
        | T.null after -> before
        | otherwise -> before <> "\n\n" <> collapseBreaks (T.dropWhile (== '\n') after)

-- | @re.sub(r'\s+', ' ', text, flags=re.ASCII).strip()@.
collapse :: Text -> Text
collapse = T.unwords . filter (not . T.null) . T.split asciiSpace
  where
    asciiSpace c = c `elem` (" \t\n\r\f\v" :: String)

-- | @textwrap.wrap(text, width)@ (default options: tabs expanded,
-- whitespace replaced, hyphenated words broken, long words broken,
-- whitespace dropped at line ends).
wrap :: Int -> Text -> [Text]
wrap width text = wrapChunks width (wordChunks (T.map munge text))
  where
    munge c = if c `elem` textwrapSpace then ' ' else c

textwrapSpace :: String
textwrapSpace = "\t\n\v\f\r "

-- | @TextWrapper.wordsep_re.split(text)@ without the empty pieces.
wordChunks :: Text -> [Text]
wordChunks text = go 0
  where
    len = T.length text
    chars = listArray (0, max 0 (len - 1)) (T.unpack text <> [' ' | len == 0]) :: Array Int Char
    at i
      | i >= 0 && i < len && i <= snd (bounds chars) = Just (chars ! i)
      | otherwise = Nothing
    is p i = maybe False p (at i)
    space c = c `elem` textwrapSpace
    word c = isAlphaNum c || c == '_'
    letter c = word c && generalCategory c /= DecimalNumber
    punct c = word c || c `elem` ("!\"'&.," <> "?" :: String)
    dashRun i = length (takeWhile (== '-') (mapMaybe at [i .. len - 1]))
    -- @(?=-{2,}\w)@ at @i@.
    emDashAhead i = let n = dashRun i in n >= 2 && is word (i + n)
    piece i n = T.take n (T.drop i text)
    go i
      | i >= len = []
      | is space i =
          let n = length (takeWhile space (mapMaybe at [i .. len - 1]))
           in piece i n : go (i + n)
      | is punct (i - 1) && emDashAhead i =
          let n = dashRun i in piece i n : go (i + n)
      | otherwise = let n = wordLength i 1 in piece i n : go (i + n)
    -- The lazy @nws+?@ followed by one of the three endings.
    wordLength i k =
      let p = i + k
          hyphenated =
            is (== '-') p
              && ((is letter (p - 2) && is letter (p - 1)) || (is letter (p - 3) && is (== '-') (p - 2) && is letter (p - 1)))
              && is letter (p + 1)
              && ((is (== '-') (p + 2) && is letter (p + 3)) || is letter (p + 2))
          ended = p >= len || is space p
          beforeEmDash = is punct (p - 1) && emDashAhead p
       in if hyphenated
            then k + 1
            else
              if ended || beforeEmDash
                then k
                else wordLength i (k + 1)

-- | @TextWrapper._wrap_chunks@ with empty indents.
wrapChunks :: Int -> [Text] -> [Text]
wrapChunks width = go []
  where
    blank = T.all Py.isSpace
    go lines' [] = reverse lines'
    go lines' chunks =
      let chunks' = case chunks of
            first : others | not (null lines') && blank first -> others
            _ -> chunks
          (line, used, rest) = fill chunks' [] 0
          (line', rest') = case rest of
            next : more | T.length next > width -> longWord next more line used
            _ -> (line, rest)
          trimmed = case reverse line' of
            final : others | blank final -> reverse others
            _ -> line'
       in if null chunks'
            then reverse lines'
            else go (if null trimmed then lines' else T.concat trimmed : lines') rest'
    fill [] line used = (reverse line, used, [])
    fill (chunk : rest) line used
      | used + T.length chunk <= width = fill rest (chunk : line) (used + T.length chunk)
      | otherwise = (reverse line, used, chunk : rest)
    longWord chunk more line used =
      let spaceLeft = if width < 1 then 1 else width - used
       in if spaceLeft > 0
            then
              let end
                    | T.length chunk > spaceLeft =
                        case T.findIndex (== '-') (T.reverse (T.take spaceLeft chunk)) of
                          Just fromEnd ->
                            let hyphen = spaceLeft - 1 - fromEnd
                             in if hyphen > 0 && T.any (/= '-') (T.take hyphen chunk) then hyphen + 1 else spaceLeft
                          Nothing -> spaceLeft
                    | otherwise = spaceLeft
               in (line <> [T.take end chunk], T.drop end chunk : more)
            else
              if null line
                then ([chunk], more)
                else (line, chunk : more)

-- ---------------------------------------------------------------------------
-- Python semantics

-- | @int(text)@ (base 10), with CPython's 4300-digit conversion limit.
pythonInt :: Text -> Maybe Integer
pythonInt text = do
  value <- Py.pyIntBase 10 text
  if T.length (T.filter (\c -> c /= '_' && not (Py.isSpace c) && c /= '+' && c /= '-') text) > 4300 then Nothing else Just value

-- | @str(pathlib.PurePosixPath(text))@: repeated slashes collapsed, @.@
-- components dropped, a trailing slash removed, @//@ kept as a root, and
-- the empty path spelled @.@.
pathText :: Text -> Text
pathText text
  | T.null text = "."
  | otherwise =
      let (root, rest)
            | "//" `T.isPrefixOf` text && not ("///" `T.isPrefixOf` text) = ("//", T.drop 2 text)
            | "/" `T.isPrefixOf` text = ("/", T.dropWhile (== '/') text)
            | otherwise = ("", text)
          parts = filter (\part -> not (T.null part) && part /= ".") (T.splitOn "/" rest)
          joined = root <> T.intercalate "/" parts
       in if T.null joined then "." else joined

-- | @shutil.get_terminal_size().columns@: @COLUMNS@ when it is a positive
-- integer, else the width of the terminal on standard output, else 80.
terminalColumns :: Map String String -> IO Int
terminalColumns environment =
  case environmentColumns environment of
    Just columns -> pure columns
    Nothing -> do
      measured <- windowColumns 1
      pure (if measured > 0 then measured else 80)

-- | @COLUMNS@, when it is a positive @int(...)@.
environmentColumns :: Map String String -> Maybe Int
environmentColumns environment =
  case Map.lookup "COLUMNS" environment >>= pythonInt . T.pack of
    Just columns | columns > 0 -> Just (fromInteger columns)
    _ -> Nothing

foreign import capi unsafe "sys/ioctl.h ioctl" c_ioctl :: CInt -> CULong -> Ptr Word16 -> IO CInt

foreign import capi "sys/ioctl.h value TIOCGWINSZ" tiocgwinsz :: CULong

windowColumns :: CInt -> IO Int
windowColumns fd = allocaBytes 8 $ \size -> do
  result <- c_ioctl fd tiocgwinsz size
  if result /= 0 then pure 0 else fromIntegral <$> peekElemOff size 1
