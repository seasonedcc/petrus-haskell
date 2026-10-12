-- | The subset of CPython's @argparse@ the reference's process entry points
-- use, with its observable behavior: long options with @--name value@ or
-- @--name=value@, unique-prefix abbreviations, @choices@, @int@ and @float@
-- conversion at consumption time, @action="append"@, required options,
-- @-h@/@--help@, the usage and help layout (80 columns), and its error
-- report (usage plus @prog: error: message@ on stderr, exit status 2).
module Petrus.Motus.Internal.Argparse
  ( OptionKind (..)
  , OptionSpec (..)
  , option
  , ArgumentParser (..)
  , Parsed
  , ParseOutcome (..)
  , parseArguments
  , runParser
  , values
  , value
  , formatUsage
  , formatHelp
  , pythonInt
  , pythonFloat
  , exitWithMessage
  ) where

import Control.Monad (unless)
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Petrus.Json.Python (parsePythonFloat, parsePythonInt, pythonStrRepr)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, stderr, stdout)

-- | How an option's value is converted (and refused).
data OptionKind = TextOption | IntOption | FloatOption
  deriving stock (Eq, Show)

-- | One @add_argument("--name", ...)@ taking exactly one value.
data OptionSpec = OptionSpec
  { name :: Text
  , kind :: OptionKind
  , choices :: Maybe [Text]
  , required :: Bool
  , repeatable :: Bool
  , help :: Maybe Text
  }

-- | A plain optional text option.
option :: Text -> OptionSpec
option name = OptionSpec {name, kind = TextOption, choices = Nothing, required = False, repeatable = False, help = Nothing}

-- | @argparse.ArgumentParser(prog=..., description=...)@ (with @-h@).
data ArgumentParser = ArgumentParser
  { prog :: Text
  , description :: Maybe Text
  , options :: [OptionSpec]
  }

-- | The raw values given for each option, in command-line order.
type Parsed = Map Text [Text]

-- | Parsed values, a help request, or a usage error message.
data ParseOutcome = Parsed Parsed | HelpRequested | UsageError Text
  deriving stock (Eq, Show)

-- | Every value given for an option.
values :: Text -> Parsed -> [Text]
values key parsed = Map.findWithDefault [] key parsed

-- | The last value given for an option.
value :: Text -> Parsed -> Maybe Text
value key parsed = case values key parsed of
  [] -> Nothing
  given -> Just (last given)

-- | @int(text)@ (petrus-json's 'parsePythonInt' in base 10).
pythonInt :: Text -> Maybe Integer
pythonInt = parsePythonInt 10

-- | @float(text)@ (petrus-json's 'parsePythonFloat', the one @float()@
-- emulation).
pythonFloat :: Text -> Maybe Double
pythonFloat = parsePythonFloat

-- | Parse a command line as @parse_args@ would (stopping at the first
-- error, as it does).
parseArguments :: ArgumentParser -> [String] -> ParseOutcome
parseArguments parser arguments = either id id (go (map T.pack arguments) Map.empty [])
  where
    longNames = map (.name) parser.options
    find key = case [spec | spec <- parser.options, spec.name == key] of
      spec : _ -> Just spec
      [] -> Nothing
    negativeNumber text = case T.uncons text of
      Just ('-', rest) ->
        let (whole, fraction) = T.break (== '.') rest
         in (not (T.null whole) && T.all isDigit whole && T.null fraction)
              || (T.all isDigit whole && T.length fraction > 1 && T.all isDigit (T.drop 1 fraction))
      _ -> False
    -- The reference's _parse_optional: Left for a positional-like string,
    -- Right (Just (spec, explicit value)) for a known option, Right Nothing
    -- for an unknown option-like string, or an ambiguity error.
    classify :: Text -> Either Text (Either () (Maybe (Maybe OptionSpec, Maybe Text)))
    classify arg
      | T.null arg || T.head arg /= '-' = Right (Left ())
      | arg `elem` ["-h", "--help"] = Right (Right (Just (Nothing, Nothing)))
      | Just spec <- find arg = Right (Right (Just (Just spec, Nothing)))
      | T.length arg == 1 = Right (Left ())
      | (key, rest) <- T.breakOn "=" arg
      , not (T.null rest)
      , Just spec <- find key =
          Right (Right (Just (Just spec, Just (T.drop 1 rest))))
      | otherwise =
          let (key, rest) = T.breakOn "=" arg
              explicit = if T.null rest then Nothing else Just (T.drop 1 rest)
              matches =
                if "--" `T.isPrefixOf` key
                  then [n | n <- "--help" : longNames, key `T.isPrefixOf` n]
                  else []
           in case matches of
                [_, _] -> ambiguous key matches
                (_ : _ : _) -> ambiguous key matches
                [single]
                  | single == "--help" -> Right (Right (Just (Nothing, Nothing)))
                  | otherwise -> Right (Right (Just (find single, explicit)))
                []
                  | negativeNumber arg -> Right (Left ())
                  | T.any (== ' ') arg -> Right (Left ())
                  | otherwise -> Right (Right Nothing)
    ambiguous key matches =
      Left ("ambiguous option: " <> key <> " could match " <> T.intercalate ", " (order matches))
    order matches = [n | n <- "--help" : longNames, n `elem` matches]
    go :: [Text] -> Parsed -> [Text] -> Either ParseOutcome ParseOutcome
    go [] parsed extras = finish parsed extras
    go (arg : rest) parsed extras
      | arg == "--" = finish parsed (extras ++ rest)
      | otherwise = case classify arg of
          Left message -> Left (UsageError message)
          Right (Left ()) -> go rest parsed (extras ++ [arg])
          Right (Right Nothing) -> go rest parsed (extras ++ [arg])
          Right (Right (Just (Nothing, _))) -> Left HelpRequested
          Right (Right (Just (Just spec, Just explicit))) -> consume spec explicit rest parsed extras
          Right (Right (Just (Just spec, Nothing))) -> case rest of
            next : remaining
              | either (const False) (either (const True) (const False)) (classify next) && next /= "--" ->
                  consume spec next remaining parsed extras
            _ -> Left (UsageError ("argument " <> spec.name <> ": expected one argument"))
    consume spec given rest parsed extras = do
      let refuse message = Left (UsageError ("argument " <> spec.name <> ": " <> message))
      case spec.kind of
        IntOption | not (isJust (pythonInt given)) -> refuse ("invalid int value: " <> pythonStrRepr given)
        FloatOption | not (isJust (pythonFloat given)) -> refuse ("invalid float value: " <> pythonStrRepr given)
        _ -> Right ()
      case spec.choices of
        Just allowed
          | given `notElem` allowed ->
              refuse ("invalid choice: " <> pythonStrRepr given <> " (choose from " <> T.intercalate ", " (map pythonStrRepr allowed) <> ")")
        _ -> Right ()
      let stored = if spec.repeatable then Map.insertWith (flip (++)) spec.name [given] parsed else Map.insert spec.name [given] parsed
      go rest stored extras
    finish parsed extras = do
      let missing = [spec.name | spec <- parser.options, spec.required, not (Map.member spec.name parsed)]
      unless (null missing) $ Left (UsageError ("the following arguments are required: " <> T.intercalate ", " missing))
      unless (null extras) $ Left (UsageError ("unrecognized arguments: " <> T.unwords extras))
      Right (Parsed parsed)

-- | Parse, printing help (exit 0) or the usage error (exit 2) as the
-- reference does.
runParser :: ArgumentParser -> [String] -> IO Parsed
runParser parser arguments = case parseArguments parser arguments of
  Parsed parsed -> pure parsed
  HelpRequested -> TIO.putStr (formatHelp parser) >> hFlush stdout >> exitWith ExitSuccess
  UsageError message -> do
    TIO.hPutStr stderr (formatUsage parser <> parser.prog <> ": error: " <> message <> "\n")
    exitWith (ExitFailure 2)

-- | @raise SystemExit(message)@: the message on stderr, exit status 1.
exitWithMessage :: Text -> IO a
exitWithMessage message = TIO.hPutStrLn stderr message >> exitWith (ExitFailure 1)

textWidth :: Int
textWidth = 78

metavarOf :: OptionSpec -> Text
metavarOf spec = case spec.choices of
  Just allowed -> "{" <> T.intercalate "," allowed <> "}"
  Nothing -> T.toUpper (T.replace "-" "_" (T.drop 2 spec.name))

invocation :: OptionSpec -> Text
invocation spec = spec.name <> " " <> metavarOf spec

-- | @format_usage()@.
formatUsage :: ArgumentParser -> Text
formatUsage parser =
  let prefix = "usage: "
      parts = "[-h]" : [if spec.required then invocation spec else "[" <> invocation spec <> "]" | spec <- parser.options]
      single = prefix <> parser.prog <> " " <> T.unwords parts
   in if T.length single <= textWidth
        then single <> "\n"
        else
          let progLength = T.length parser.prog
              lines'
                | T.length prefix + progLength <= (3 * textWidth) `div` 4 =
                    let indent = T.replicate (T.length prefix + progLength + 1) " "
                     in case wrap (parser.prog : parts) indent (Just prefix) of
                          first : rest -> T.drop (T.length indent) first : rest
                          [] -> []
                | otherwise = parser.prog : wrap parts (T.replicate (T.length prefix) " ") Nothing
           in prefix <> T.intercalate "\n" lines' <> "\n"
  where
    wrap parts indent prefix =
      let indentLength = T.length indent
          start = maybe (indentLength - 1) (\p -> T.length p - 1) prefix
          step (done, line, len') part
            | len' + 1 + T.length part > textWidth && not (null line) =
                (done ++ [indent <> T.unwords line], [part], indentLength - 1 + T.length part + 1)
            | otherwise = (done, line ++ [part], len' + T.length part + 1)
          (finished, current, _) = foldl step ([], [], start) parts
       in if null current then finished else finished ++ [indent <> T.unwords current]

-- | @format_help()@.
formatHelp :: ArgumentParser -> Text
formatHelp parser =
  let rows = ("-h, --help", Just "show this help message and exit") : [(invocation spec, spec.help) | spec <- parser.options]
      maxLength = maximum (map (\(header, _) -> T.length header + 2) rows)
      helpPosition = min (maxLength + 2) 24
      helpWidth = max (textWidth - helpPosition) 11
      actionWidth = helpPosition - 2 - 2
      row (header, helpText) = case helpText of
        Nothing -> "  " <> header <> "\n"
        Just text
          | T.length header <= actionWidth ->
              let wrapped = wrapWords helpWidth text
               in "  " <> T.justifyLeft actionWidth ' ' header <> "  " <> T.intercalate ("\n" <> T.replicate helpPosition " ") wrapped <> "\n"
          | otherwise ->
              "  " <> header <> "\n" <> T.concat [T.replicate helpPosition " " <> line <> "\n" | line <- wrapWords helpWidth text]
   in formatUsage parser
        <> maybe "" (\d -> "\n" <> d <> "\n") parser.description
        <> "\noptions:\n"
        <> T.concat (map row rows)

wrapWords :: Int -> Text -> [Text]
wrapWords width text = reverse (finish (foldl step ([], []) (T.words text)))
  where
    step (done, current) word
      | null current = (done, [word])
      | T.length (T.unwords (reverse (word : current))) > width = (T.unwords (reverse current) : done, [word])
      | otherwise = (done, word : current)
    finish (done, current) = if null current then done else T.unwords (reverse current) : done
