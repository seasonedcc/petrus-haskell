-- | CPython 3.14's @argparse@, declared and decoded as one typed value.
--
-- An @'Arg' a@ is a list of @add_argument@ calls together with how their
-- namespace decodes to an @a@. Each primitive ('option', 'required',
-- 'defaulted', 'flag', 'constant', 'appended', 'positional', 'positionals',
-- 'subcommands') declares
-- one action and reads back the destination it declared, through the
-- 'Type' that also converts its strings. So a destination cannot be
-- misspelled between the declaration and the read, and a value cannot be
-- read at another type. 'Arg' is 'Applicative': a command line is its
-- arguments in declaration order, combined into a record.
--
-- > data Options = Options {host :: Text, port :: Integer, verbose :: Bool}
-- >
-- > options :: ArgumentParser Options
-- > options =
-- >   ArgumentParser "prog" Nothing $
-- >     Options
-- >       <$> defaulted str ["--host"] "127.0.0.1" [help "address to bind"]
-- >       <*> defaulted int ["--port"] 8000 []
-- >       <*> flag ["--verbose"] []
--
-- 'parse' then does what @parse_args@ does ("Petrus.Argparse.Parser"):
-- the decoded value, or the help, usage and error text with the exit
-- status. 'runArgumentParser' does it in the process, over the arguments
-- 'getArguments' decodes as CPython decodes @sys.argv@.
module Petrus.Argparse
  ( -- * Declaring a command line
    ArgumentParser (..)
  , Arg
  , Type
  , str
  , int
  , float
  , path
  , FileMode (..)
  , Stream (..)
  , file
  , choice
  , oneOf
  , Modifier
  , help
  , metavar
  , dest
  , option
  , required
  , defaulted
  , flag
  , constant
  , appended
  , positional
  , positionals
  , subcommands

    -- * Parsing
  , Formatting (..)
  , Outcome (..)
  , parse
  , parser
  , errorText
  , formattingOf
  , formattingFor
  , getArguments
  , runArgumentParser
  , exitWithMessage

    -- * The terminal
  , canColorize
  , terminalColumns
  , environmentColumns

    -- * Python semantics
  , pythonInt
  , pythonFloat
  , pathText
  ) where

import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Tuple (swap)
import Petrus.Argparse.Parser
  ( Action (..)
  , Behavior (..)
  , FileMode (..)
  , Formatting (..)
  , Namespace
  , Outcome (..)
  , Parser
  , Value (..)
  , ValueType (..)
  , canColorize
  , colorTheme
  , environmentColumns
  , newParser
  , parseArgs
  , parseArgsIO
  , pathText
  , plainTheme
  , pythonFloat
  , pythonInt
  , terminalColumns
  )
import Petrus.Argparse.Parser qualified as Parser
import Petrus.Json.Python.Fs (fsDecode, utf8BackslashReplace)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (Handle, hFlush, hIsTerminalDevice, stderr, stdout)
import System.Posix.Env.ByteString qualified as Posix

-- | @argparse.ArgumentParser(prog=..., description=...)@ with its
-- arguments.
data ArgumentParser a = ArgumentParser
  { prog :: Text
  , description :: Maybe Text
  , arguments :: Arg a
  }

-- | Some @add_argument@ calls and how their namespace decodes.
data Arg a = Arg
  { declare :: Text -> [Action]
  -- ^ The actions, given the parser's @prog@ (a subparser's @prog@ is its
  -- parent's followed by its name).
  , decode :: Namespace -> Maybe a
  -- ^ 'Nothing' only for a namespace another parser produced.
  }

instance Functor Arg where
  fmap f arg = arg {decode = fmap f . arg.decode}

instance Applicative Arg where
  pure value = Arg {declare = const [], decode = const (Just value)}
  left <*> right =
    Arg
      { declare = \prog -> left.declare prog <> right.declare prog
      , decode = \namespace -> left.decode namespace <*> right.decode namespace
      }

-- | An argument's @type=@ (and @choices=@): how a string converts, and the
-- namespace value it reads back as.
data Type a = Type
  { conversion :: ValueType
  , names :: Maybe [Text]
  , fromValue :: Value -> Maybe a
  , toValue :: a -> Value
  }

-- | @type=str@.
str :: Type Text
str = Type {conversion = AsStr, names = Nothing, fromValue = \case Str text -> Just text; _ -> Nothing, toValue = Str}

-- | @type=int@ ('pythonInt').
int :: Type Integer
int = Type {conversion = AsInt, names = Nothing, fromValue = \case IntValue value -> Just value; _ -> Nothing, toValue = IntValue}

-- | @type=float@ ('pythonFloat').
float :: Type Double
float = Type {conversion = AsFloat, names = Nothing, fromValue = \case FloatValue value -> Just value; _ -> Nothing, toValue = FloatValue}

-- | @type=pathlib.Path@, read back as @str(path)@ ('pathText').
path :: Type Text
path = str {conversion = AsPath}

-- | An @argparse.FileType@ file: the standard stream (@-@) or a named
-- file, which the parse opened ('runArgumentParser').
data Stream = StandardStream | NamedFile Text
  deriving stock (Eq, Show)

-- | @type=argparse.FileType(mode)@, read back by name.
file :: FileMode -> Type Stream
file mode =
  Type
    { conversion = AsFile mode
    , names = Nothing
    , fromValue = \case File _ name -> Just (maybe StandardStream NamedFile name); _ -> Nothing
    , toValue = File mode . \case StandardStream -> Nothing; NamedFile name -> Just name
    }

-- | @choices=@ over strings, each read back as its value.
choice :: (Eq a) => [(Text, a)] -> Type a
choice table =
  Type
    { conversion = AsStr
    , names = Just (map fst table)
    , fromValue = \case Str name -> lookup name table; _ -> Nothing
    , toValue = maybe None Str . (`lookup` map swap table)
    }

-- | @choices=@ over strings, read back as the string.
oneOf :: [Text] -> Type Text
oneOf given = choice [(name, name) | name <- given]

-- | A keyword of @add_argument@ that does not change what is read back.
newtype Modifier = Modifier (Action -> Action)

-- | @help=@.
help :: Text -> Modifier
help text = Modifier (\action -> action {help = Just text})

-- | @metavar=@.
metavar :: Text -> Modifier
metavar name = Modifier (\action -> action {metavar = Just name})

-- | @dest=@.
dest :: Text -> Modifier
dest name = Modifier (\action -> action {dest = name})

-- | One action, its modifiers applied, read back by its own destination.
declared :: Action -> [Modifier] -> (Maybe Value -> Maybe a) -> Arg a
declared base modifiers reader =
  Arg {declare = const [action], decode = reader . Map.lookup action.dest}
  where
    action = foldl (\current (Modifier modify) -> modify current) base modifiers

typed :: Type a -> [Text] -> Action
typed ty strings = (Parser.option strings) {valueType = ty.conversion, choices = ty.names}

-- | @add_argument(*strings, type=...)@: 'Nothing' when it is not given.
option :: Type a -> [Text] -> [Modifier] -> Arg (Maybe a)
option ty strings modifiers = declared (typed ty strings) modifiers $ \case
  Nothing -> Just Nothing
  Just None -> Just Nothing
  Just value -> Just <$> ty.fromValue value

-- | @add_argument(*strings, type=..., required=True)@.
required :: Type a -> [Text] -> [Modifier] -> Arg a
required ty strings modifiers = declared (typed ty strings) {required = True} modifiers (>>= ty.fromValue)

-- | @add_argument(*strings, type=..., default=value)@.
defaulted :: Type a -> [Text] -> a -> [Modifier] -> Arg a
defaulted ty strings value modifiers = declared (typed ty strings) {defaultValue = Just (ty.toValue value)} modifiers (>>= ty.fromValue)

-- | @add_argument(*strings, action="store_true")@.
flag :: [Text] -> [Modifier] -> Arg Bool
flag strings modifiers =
  declared (Parser.option strings) {behavior = StoreTrue, defaultValue = Just (BoolValue False)} modifiers $ \case
    Just (BoolValue value) -> Just value
    _ -> Nothing

-- | @add_argument(*strings, action="store_const", const=value,
-- default=fallback)@, read back at the type of both.
constant :: Type a -> [Text] -> a -> a -> [Modifier] -> Arg a
constant ty strings value fallback modifiers =
  declared (Parser.option strings) {behavior = StoreConst (ty.toValue value), defaultValue = Just (ty.toValue fallback)} modifiers (>>= ty.fromValue)

-- | @add_argument(*strings, type=..., action="append", default=[])@: every
-- value given, in order.
appended :: Type a -> [Text] -> [Modifier] -> Arg [a]
appended ty strings modifiers =
  declared (typed ty strings) {behavior = Append, defaultValue = Just (List [])} modifiers $ \case
    Just (List values) -> traverse ty.fromValue values
    _ -> Nothing

-- | @add_argument(name, type=...)@: a required positional.
positional :: Type a -> Text -> [Modifier] -> Arg a
positional ty name modifiers = declared (Parser.positional name) {valueType = ty.conversion, choices = ty.names} modifiers (>>= ty.fromValue)

-- | @add_argument(name, type=..., nargs="*")@: every value given, in
-- order, none required.
positionals :: Type a -> Text -> [Modifier] -> Arg [a]
positionals ty name modifiers =
  declared (Parser.positional name) {behavior = StoreAll, required = False, valueType = ty.conversion, choices = ty.names} modifiers $ \case
    Just (List values) -> traverse ty.fromValue values
    _ -> Nothing

-- | @add_subparsers(dest=name, required=True)@ with one @add_parser@ per
-- entry, in order; the namespace decodes by the chosen entry's arguments.
subcommands :: Text -> [(Text, Arg a)] -> Arg a
subcommands name entries =
  Arg
    { declare = \prog -> [Parser.subcommands prog name [(entry, arg.declare (prog <> " " <> entry)) | (entry, arg) <- entries]]
    , decode = \namespace -> case Map.lookup name namespace of
        Just (Str chosen) -> lookup chosen entries >>= \arg -> arg.decode namespace
        _ -> Nothing
    }

-- | The parser's declarations ("Petrus.Argparse.Parser").
parser :: ArgumentParser a -> Parser
parser declaration = newParser declaration.prog declaration.description (declaration.arguments.declare declaration.prog)

-- | @parser.parse_args(argv)@, decoded, when every @FileType@ argument
-- opens.
parse :: Formatting -> ArgumentParser a -> [Text] -> Outcome a
parse formatting declaration = decoded formatting declaration . parseArgs formatting (parser declaration)

decoded :: Formatting -> ArgumentParser a -> Outcome Namespace -> Outcome a
decoded formatting declaration = \case
  Exited status out err -> Exited status out err
  Parsed namespace -> case declaration.arguments.decode namespace of
    Just value -> Parsed value
    -- Unreachable: the namespace comes from these declarations.
    Nothing -> Exited 2 "" (errorText formatting declaration "the parsed arguments do not decode")

-- | What @parser.error(message)@ writes to stderr before it exits 2.
errorText :: Formatting -> ArgumentParser a -> Text -> Text
errorText formatting declaration = Parser.errorText formatting (parser declaration)

-- | The formatting of a process with this environment, given the columns
-- @shutil.get_terminal_size()@ reports and whether standard output is a
-- terminal: the width less 2, and colors when 'canColorize' allows them.
formattingOf :: Map String String -> Int -> Bool -> Formatting
formattingOf environment columns terminal =
  Formatting {width = columns - 2, theme = if canColorize environment terminal then colorTheme else plainTheme}

-- | 'formattingOf' for a process writing to this standard output.
formattingFor :: Map String String -> Handle -> IO Formatting
formattingFor environment output = formattingOf environment <$> terminalColumns environment <*> hIsTerminalDevice output

-- | The process's arguments as CPython decodes @sys.argv@: UTF-8 with
-- @surrogateescape@, so an undecodable byte is kept as a lone surrogate
-- and names the same file again.
getArguments :: IO [Text]
getArguments = map fsDecode <$> Posix.getArgs

-- | @parser.parse_args(argv)@ in the process, opening its @FileType@
-- files: the decoded value, or the help (stdout, exit 0) or the usage
-- error (stderr, exit 2) as the reference prints them. Standard error is
-- written as CPython writes it, a lone surrogate as @\\udcXX@.
runArgumentParser :: ArgumentParser a -> [Text] -> IO a
runArgumentParser declaration argv = do
  environment <- Map.fromList <$> getEnvironment
  formatting <- formattingFor environment stdout
  outcome <- decoded formatting declaration <$> parseArgsIO formatting (parser declaration) argv
  case outcome of
    Parsed value -> pure value
    Exited status out err -> do
      BS.hPut stdout (TE.encodeUtf8 out)
      hFlush stdout
      BS.hPut stderr (utf8BackslashReplace err)
      exitWith (if status == 0 then ExitSuccess else ExitFailure status)

-- | @raise SystemExit(message)@: the message on stderr, exit status 1.
exitWithMessage :: Text -> IO a
exitWithMessage message = BS.hPut stderr (utf8BackslashReplace (message <> "\n")) >> exitWith (ExitFailure 1)
