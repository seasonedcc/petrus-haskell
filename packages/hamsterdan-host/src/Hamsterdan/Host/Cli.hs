{-# LANGUAGE CApiFFI #-}

-- | The standalone host command line (@host/__main__.py@):
-- @serve@, @validate@, @inbox@, @requeue@ and @inspect-instance@.
--
-- The argument parser reproduces the reference's @argparse@ parser
-- (CPython 3.14) for this command line: the same classification of option
-- strings (prefix abbreviations, @--opt=value@, single-dash chaining,
-- negative-number-like positionals, @--@), the same conversions
-- (@int(...)@), the same messages, usage and help text wrapped to the same
-- width (@COLUMNS@, else the terminal, else 80, minus 2), the same streams
-- and exit statuses (help on stdout with 0, errors on stderr with 2).
module Hamsterdan.Host.Cli
  ( -- * The command line
    Arguments (..)
  , Parsed (..)
  , parseCommandLine
  , formatUsage
  , formatHelp
  , terminalColumns
  , environmentColumns
  , pythonFloat

    -- * @inspect-instance@
  , inspectInstance

    -- * Running
  , CliEnvironment (..)
  , productionEnvironment
  , runCli
  , handledMessage
  ) where

import Control.Exception (Exception (..), IOException, SomeException, finally, fromException, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (..), generalCategory, isDigit, ord, toLower)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16)
import Foreign.C.Types (CInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)
import Hamsterdan.Agents.Protocol (AgentRunner (..))
import Hamsterdan.Host.Agenticus (AgentCompositionError (..))
import Hamsterdan.Host.Agents (OwnedAgent, closeOwnedAgent, composeHostAgent, newOwnedAgent, productionAgentSeams)
import Petrus.Agenticus.Error (AgenticusError (..), errorClassName, isSubclassOf)
import Petrus.Agenticus.Error qualified as AE
import Hamsterdan.GitHub.Client (AppCredentials (..), ClientOptions, defaultClientOptions, newAppClients)
import Hamsterdan.GitHub.Config (ConfigurationError (..), HostConfig (..), fromEnvironment, revealSecret)
import Hamsterdan.GitHub.Http (ClientError (..), ClientErrorKind (..))
import Hamsterdan.GitHub.Models (ContractRefused (..), GitHubBoundaryError (..), InvalidRequest (..))
import Hamsterdan.GitHub.Python (PythonFault (..), isAscii, isPrintable, pyIntBase, utf8Length)
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.GitHub.Webhooks (Failure (..))
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Api (ServeOptions (..), serve)
import Hamsterdan.Host.Binding (InstanceBinding (..), parseInstanceBinding, preflightV5State, topologyText)
import Hamsterdan.Host.Service
  ( AgentCustody
  , HostService (..)
  , ServiceOptions (..)
  , gitHubHostClients
  , openHostService
  , qualificationFaultFromEnvironment
  , reconcileRegistration
  , serviceOptions
  )
import Hamsterdan.Host.Service qualified as Service
import Hamsterdan.PyLiteral (strRepr)
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText, parseJson, pythonLoads)
import Petrus.Json qualified as Json
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import System.Environment (unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hFlush, stderr, stdout)
import System.IO.Error (catchIOError, isEOFError)
import System.Posix.Files qualified as Posix
import System.Posix.IO qualified as PosixIO
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Signals (Handler (Default), Signal, installHandler, raiseSignal, sigTERM)

-- ---------------------------------------------------------------------------
-- The parser

-- | The parsed namespace.
data Arguments = Arguments
  { command :: Text
  , delivery :: Maybe Text
  , installation :: Maybe Integer
  , repository :: Maybe Integer
  , pullRequest :: Maybe Integer
  , host :: Text
  , port :: Integer
  }
  deriving stock (Eq, Show)

-- | What @parser().parse_args(argv)@ does.
data Parsed
  = -- | @-h@/@--help@: print 'formatHelp' to stdout and exit 0.
    ShowHelp
  | -- | @parser.error(message)@: usage and message on stderr, exit 2.
    ParseError Text
  | Parsed Arguments
  deriving stock (Eq, Show)

prog :: Text
prog = "python -m hamsterdan.host"

description :: Text
description = "Run or validate the Hamsterdan GitHub App host. Credentials are supplied by the selected Environment."

choices :: [Text]
choices = ["serve", "validate", "inbox", "requeue", "inspect-instance"]

-- | The optional actions, in registration order.
data Opt = Help | Delivery | Installation | Repository | Pr | Host | Port
  deriving stock (Eq, Ord, Show, Enum, Bounded)

optionStrings :: Opt -> [Text]
optionStrings = \case
  Help -> ["-h", "--help"]
  Delivery -> ["--delivery"]
  Installation -> ["--installation"]
  Repository -> ["--repository"]
  Pr -> ["--pr"]
  Host -> ["--host"]
  Port -> ["--port"]

takesValue :: Opt -> Bool
takesValue = (/= Help)

optionHelp :: Opt -> Maybe Text
optionHelp = \case
  Help -> Just "show this help message and exit"
  Delivery -> Just "canonical failed GitHub delivery UUID to requeue"
  _ -> Nothing

-- | @_option_string_actions@, in insertion order.
optionMap :: [(Text, Opt)]
optionMap = [(string, opt) | opt <- [minBound .. maxBound], string <- optionStrings opt]

actionName :: Opt -> Text
actionName = T.intercalate "/" . optionStrings

metavar :: Opt -> Text
metavar = \case
  Delivery -> "DELIVERY"
  Installation -> "INSTALLATION"
  Repository -> "REPOSITORY"
  Pr -> "PR"
  Host -> "HOST"
  Port -> "PORT"
  Help -> ""

-- | One interpretation of an option string: the action (if any), the
-- option string, the separator, and the explicit argument.
type OptionTuple = (Maybe Opt, Text, Maybe Text, Maybe Text)

-- | @_parse_optional@.
parseOptional :: Text -> Maybe [OptionTuple]
parseOptional arg
  | T.null arg = Nothing
  | T.head arg /= '-' = Nothing
  | Just opt <- lookup arg optionMap = Just [(Just opt, arg, Nothing, Nothing)]
  | T.length arg == 1 = Nothing
  | (name, rest) <- T.breakOn "=" arg
  , not (T.null rest)
  , Just opt <- lookup name optionMap =
      Just [(Just opt, name, Just "=", Just (T.drop 1 rest))]
  | tuples@(_ : _) <- optionTuples arg = Just tuples
  | negativeNumberLike arg = Nothing
  | T.any (== ' ') arg = Nothing
  | otherwise = Just [(Nothing, arg, Nothing, Nothing)]
  where
    -- @re.match(r'-\.?\d', arg)@ (@\d@: any Unicode decimal digit).
    negativeNumberLike text = case T.unpack text of
      '-' : '.' : c : _ -> decimal c
      '-' : c : _ -> decimal c
      _ -> False
    decimal c = generalCategory c == DecimalNumber

-- | @_get_option_tuples@ (abbreviations are allowed).
optionTuples :: Text -> [OptionTuple]
optionTuples arg
  | "--" `T.isPrefixOf` arg =
      [(Just opt, string, sep, explicit) | (string, opt) <- optionMap, prefix `T.isPrefixOf` string]
  | otherwise =
      [ if string == short then (Just opt, string, Just "", Just (T.drop 2 arg)) else (Just opt, string, sep, explicit)
      | (string, opt) <- optionMap
      , string == short || prefix `T.isPrefixOf` string
      ]
  where
    (prefix, sep, explicit) = case T.breakOn "=" arg of
      (before, after) | not (T.null after) -> (before, Just "=", Just (T.drop 1 after))
      _ -> (arg, Nothing, Nothing)
    short = T.take 2 arg

data Namespace = Namespace
  { values :: Map Opt Text
  , commandValue :: Maybe Text
  }

-- | A parse that stops: help, or an error.
type Parse = Either Parsed

argumentError :: Text -> Text -> Parse a
argumentError name message = Left (ParseError ("argument " <> name <> ": " <> message))

-- | @parser().parse_args(argv)@ under the given environment (the
-- @--host@ default is @HAMSTERDAN_HOST@ or @127.0.0.1@; the @--port@
-- default, @int(HAMSTERDAN_PORT or "8000")@, is passed in already
-- converted).
parseCommandLine :: Text -> Integer -> [Text] -> Parsed
parseCommandLine hostDefault portDefault argv =
  case run of
    Left stop -> stop
    -- parse_known_args reports a missing required argument before
    -- parse_args reports the extras.
    Right (ns, extras) -> case (finish ns, extras) of
      (Left stop, _) -> stop
      (Right _, _ : _) -> ParseError ("unrecognized arguments: " <> T.unwords extras)
      (Right arguments, []) -> Parsed arguments
  where
    strings = argv
    pattern' = classify argv
    indices = Map.fromList [(i, tuples) | (i, Just tuples) <- zip [0 ..] (tuplesOf argv)]
    maxOption = maybe (-1) fst (Map.lookupMax indices)

    tuplesOf = go
      where
        go = \case
          [] -> []
          "--" : rest -> Nothing : map (const Nothing) rest
          arg : rest -> parseOptional arg : go rest

    run :: Parse (Namespace, [Text])
    run = loop 0 (Namespace Map.empty Nothing) []

    loop start ns extras
      | start <= maxOption = do
          let next = fromMaybe maxOption (fst <$> Map.lookupGE start indices)
          if start /= next
            then do
              (ns', end) <- consumePositionals ns start
              if end > start
                then loop end ns' extras
                else afterPositionals end ns' extras next
            else afterPositionals start ns extras next
      | otherwise = do
          (ns', stop) <- consumePositionals ns start
          pure (ns', extras <> drop stop strings)

    afterPositionals start ns extras next
      | Map.member start indices = do
          (ns', stop, extras') <- consumeOptional ns start
          loop stop ns' (extras <> extras')
      | otherwise = do
          let skipped = take (next - start) (drop start strings)
          (ns', stop, extras') <- consumeOptional ns next
          loop stop ns' (extras <> skipped <> extras')

    -- @consume_positionals@ for the single positional @command@
    -- (@nargs=None@: the pattern @-*A-*@).
    consumePositionals ns start
      | isJust ns.commandValue = pure (ns, start)
      | otherwise =
          let rest = drop start pattern'
              dashes = length (takeWhile (== '-') rest)
           in case drop dashes rest of
                'A' : after -> do
                  let count = dashes + 1 + length (takeWhile (== '-') after)
                      args = take count (drop start strings)
                      cleaned = if '-' `elem` take count rest then removeFirst "--" args else args
                  value <- case cleaned of
                    [single] -> pure single
                    _ -> Left (ParseError "internal: positional match")
                  unless (value `elem` choices) $
                    argumentError "command" ("invalid choice: " <> strRepr value <> " (choose from " <> T.intercalate ", " (map strRepr choices) <> ")")
                  pure (ns {commandValue = Just value}, start + count)
                _ -> pure (ns, start)

    -- @consume_optional@: returns the namespace, the index after the
    -- option, and any extras it produced.
    consumeOptional ns start = do
      let tuples = indices Map.! start
      when (length tuples > 1) $
        Left (ParseError ("ambiguous option: " <> (strings !! start) <> " could match " <> T.intercalate ", " [s | (_, s, _, _) <- tuples]))
      (action0, string0, sep0, explicit0) <- case tuples of
        first : _ -> pure first
        [] -> Left (ParseError "internal: option tuples")
      case action0 of
        Nothing -> pure (ns, start + 1, [strings !! start])
        Just opt0 -> do
          (taken, stop, extras) <- chain opt0 string0 sep0 explicit0 []
          ns' <- foldlM' takeAction ns taken
          pure (ns', stop, extras)
      where
        chain opt string sep explicit acc = case explicit of
          Just ex
            | not (takesValue opt) && T.index string 1 /= '-' && not (T.null ex) ->
                if maybe False (not . T.null) sep || T.head ex == '-'
                  then argumentError (actionName opt) ("ignored explicit argument " <> strRepr ex)
                  else do
                    let acc' = acc <> [(opt, Nothing)]
                        next = T.pack ['-', T.head ex]
                    case lookup next optionMap of
                      Just opt' ->
                        let ex' = T.drop 1 ex
                            (sep', explicit')
                              | T.null ex' = (Nothing, Nothing)
                              | T.head ex' == '=' = (Just "=", Just (T.drop 1 ex'))
                              | otherwise = (Just "", Just ex')
                         in chain opt' next sep' explicit' acc'
                      Nothing -> pure (acc', start + 1, ["-" <> ex])
            | takesValue opt -> pure (acc <> [(opt, Just ex)], start + 1, [])
            | otherwise -> argumentError (actionName opt) ("ignored explicit argument " <> strRepr ex)
          Nothing
            | takesValue opt -> case drop (start + 1) pattern' of
                'A' : _ -> pure (acc <> [(opt, Just (strings !! (start + 1)))], start + 2, [])
                _ -> argumentError (actionName opt) "expected one argument"
            | otherwise -> pure (acc <> [(opt, Nothing)], start + 1, [])

    takeAction ns (opt, value) = case (opt, value) of
      (Help, _) -> Left ShowHelp
      (_, Just text)
        | opt `elem` [Installation, Repository, Pr, Port] ->
            case pythonInt text of
              Just _ -> pure ns {values = Map.insert opt text ns.values}
              Nothing -> argumentError (actionName opt) ("invalid int value: " <> strRepr text)
        | otherwise -> pure ns {values = Map.insert opt text ns.values}
      _ -> pure ns

    finish ns = case ns.commandValue of
      Nothing -> Left (ParseError "the following arguments are required: command")
      Just command ->
        let int opt = Map.lookup opt ns.values >>= pythonInt
         in Right
              Arguments
                { command
                , delivery = Map.lookup Delivery ns.values
                , installation = int Installation
                , repository = int Repository
                , pullRequest = int Pr
                , host = Map.findWithDefault hostDefault Host ns.values
                , port = fromMaybe portDefault (int Port)
                }


foldlM' :: (Monad m) => (b -> a -> m b) -> b -> [a] -> m b
foldlM' step = go
  where
    go acc = \case
      [] -> pure acc
      x : xs -> step acc x >>= \acc' -> go acc' xs

removeFirst :: (Eq a) => a -> [a] -> [a]
removeFirst x = \case
  [] -> []
  y : ys
    | x == y -> ys
    | otherwise -> y : removeFirst x ys

-- | The @O@/@A@/@-@ pattern of the argument strings.
classify :: [Text] -> String
classify = \case
  [] -> []
  "--" : rest -> '-' : map (const 'A') rest
  arg : rest -> (if isJust (parseOptional arg) then 'O' else 'A') : classify rest

-- | @int(text)@ (base 10), with CPython's 4300-digit conversion limit.
pythonInt :: Text -> Maybe Integer
pythonInt text = do
  value <- pyIntBase 10 text
  if T.length (T.filter (\c -> c /= '_' && not (Py.isSpace c) && c /= '+' && c /= '-') text) > 4300 then Nothing else Just value

-- ---------------------------------------------------------------------------
-- Help

-- | @parser.format_usage()@ at a formatter width.
formatUsage :: Int -> Text
formatUsage width = "usage: " <> usageBody width <> "\n"

usageBody :: Int -> Text
usageBody width
  | T.length prefix + T.length full <= textWidth = full
  | fromIntegral (T.length prefix + T.length prog) <= (0.75 :: Double) * fromIntegral textWidth =
      let indent = T.replicate (T.length prefix + T.length prog + 1) " "
       in T.intercalate "\n" (getLines (prog : optParts) indent True <> getLines posParts indent False)
  | otherwise =
      let indent = T.replicate (T.length prefix) " "
          joined = getLines (optParts <> posParts) indent False
          lines' = if length joined > 1 then getLines optParts indent False <> getLines posParts indent False else joined
       in T.intercalate "\n" (prog : lines')
  where
    prefix = "usage: " :: Text
    textWidth = width
    optParts = [if takesValue opt then "[" <> firstString opt <> " " <> metavar opt <> "]" else "[" <> firstString opt <> "]" | opt <- [minBound .. maxBound]]
    firstString opt = case optionStrings opt of
      first : _ -> first
      [] -> ""
    posParts = [choicesMetavar]
    full = T.unwords (prog : optParts <> posParts)
    getLines parts indent withPrefix =
      let indentLength = T.length indent
          start = if withPrefix then T.length prefix - 1 else indentLength - 1
          go [] line _ acc = reverse (if null line then acc else (indent <> T.unwords (reverse line)) : acc)
          go (part : rest) line lineLen acc
            | lineLen + 1 + T.length part > textWidth && not (null line) =
                go rest [part] (indentLength - 1 + T.length part + 1) ((indent <> T.unwords (reverse line)) : acc)
            | otherwise = go rest (part : line) (lineLen + T.length part + 1) acc
          result = go parts [] start []
       in if withPrefix then case result of
            first : others -> T.drop indentLength first : others
            [] -> []
          else result

choicesMetavar :: Text
choicesMetavar = "{" <> T.intercalate "," choices <> "}"

-- | @parser.format_help()@ at a formatter width (@columns - 2@).
formatHelp :: Int -> Text
formatHelp width =
  normalize $
    T.concat
      [ formatUsage width <> "\n"
      , fillText (max width 11) "" description <> "\n\n"
      , section "positional arguments" [entry choicesMetavar Nothing]
      , section "options" [entry (invocation opt) (optionHelp opt) | opt <- [minBound .. maxBound]]
      ]
  where
    maxHelpPosition = min 24 (max (width - 20) 4)
    invocation opt =
      if takesValue opt
        then T.intercalate ", " (optionStrings opt) <> " " <> metavar opt
        else T.intercalate ", " (optionStrings opt)
    actionMaxLength = maximum (map ((+ 2) . T.length) (choicesMetavar : map invocation [minBound .. maxBound]))
    helpPosition = min (actionMaxLength + 2) maxHelpPosition
    helpWidth = max (width - helpPosition) 11
    actionWidth = helpPosition - 2 - 2
    section heading items = "\n" <> heading <> ":\n" <> T.concat items <> "\n"
    entry header = \case
      Nothing -> "  " <> header <> "\n"
      Just help ->
        let (first, indentFirst)
              | T.length header <= actionWidth = ("  " <> T.justifyLeft actionWidth ' ' header <> "  ", 0)
              | otherwise = ("  " <> header <> "\n", helpPosition)
            helpLines = wrapText helpWidth (collapse help)
         in case helpLines of
              [] -> first <> "\n"
              line : others ->
                first
                  <> T.replicate indentFirst " "
                  <> line
                  <> "\n"
                  <> T.concat [T.replicate helpPosition " " <> l <> "\n" | l <- others]
    normalize text = T.dropAround (== '\n') (collapseBreaks text) <> "\n"
    collapseBreaks text = case T.breakOn "\n\n\n" text of
      (before, after)
        | T.null after -> before
        | otherwise -> before <> "\n\n" <> collapseBreaks (T.dropWhile (== '\n') after)

-- | @re.sub(r'\s+', ' ', text, flags=re.ASCII).strip()@.
collapse :: Text -> Text
collapse = T.unwords . T.split asciiSpace . T.strip
  where
    asciiSpace c = c `elem` (" \t\n\r\f\v" :: String)

-- | @textwrap.fill(text, width, initial_indent=indent,
-- subsequent_indent=indent)@ of collapsed text.
fillText :: Int -> Text -> Text -> Text
fillText width indent text = T.intercalate "\n" (map (indent <>) (wrapIndented (width - T.length indent) (collapse text)))

wrapText :: Int -> Text -> [Text]
wrapText = wrapIndented

-- | @textwrap.wrap@ with an indent's width already removed, for text
-- without hyphens or tabs (single spaces between words).
wrapIndented :: Int -> Text -> [Text]
wrapIndented width text = go (chunks text) []
  where
    chunks t = filter (not . T.null) (T.groupBy (\a b -> (a == ' ') == (b == ' ')) t)
    go [] acc = reverse acc
    go remaining acc =
      let remaining' = if not (null acc) then dropLeadingSpace remaining else remaining
          (line, rest) = fill remaining' [] 0
          (line', rest') = case rest of
            chunk : more
              | T.length chunk > width -> breakLong chunk more line
            _ -> (line, rest)
          trimmed = case reverse line' of
            lastChunk : others | T.all (== ' ') lastChunk -> reverse others
            _ -> line'
       in if null remaining'
            then reverse acc
            else go rest' (if null trimmed then acc else T.concat trimmed : acc)
    dropLeadingSpace = \case
      chunk : rest | T.all (== ' ') chunk -> rest
      other -> other
    fill [] line _ = (line, [])
    fill (chunk : rest) line len
      | len + T.length chunk <= width = fill rest (line <> [chunk]) (len + T.length chunk)
      | otherwise = (line, chunk : rest)
    breakLong chunk more line =
      let used = sum (map T.length line)
          spaceLeft = if width < 1 then 1 else width - used
       in (line <> [T.take spaceLeft chunk], T.drop spaceLeft chunk : more)

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

-- | @float(text)@: 'Left' with CPython's message when it does not convert.
pythonFloat :: Text -> Either Text Double
pythonFloat original = maybe (Left ("could not convert string to float: " <> strRepr original)) Right (parse (T.unpack (T.map ascii (Py.strip original))))
  where
    ascii c
      | c > '\x7f' && generalCategory c == DecimalNumber = toEnum (ord '0' + digitValue c)
      | Py.isSpace c = ' '
      | otherwise = c
    digitValue c = (ord c - runStart (ord c)) `mod` 10
    runStart n = if n > 0 && generalCategory (toEnum (n - 1)) == DecimalNumber then runStart (n - 1) else n
    parse text = do
      let (sign, unsigned) = case text of
            '-' : rest -> (negate, rest)
            '+' : rest -> (id, rest)
            _ -> (id, text)
      case map toLower unsigned of
        "inf" -> Just (sign (1 / 0))
        "infinity" -> Just (sign (1 / 0))
        "nan" -> Just (sign (0 / 0))
        _ -> sign <$> decimal unsigned
    decimal text = do
      (whole, rest) <- digitsOf text True
      (fraction, rest') <- case rest of
        '.' : after -> digitsOf after True
        _ -> Just ("", rest)
      when (null whole && null fraction) Nothing
      when (null whole && take 1 rest /= ".") Nothing
      exponent' <- case rest' of
        [] -> Just 0
        e : after | e `elem` ("eE" :: String) -> do
          let (esign, digitsText) = case after of
                '-' : more -> (negate, more)
                '+' : more -> (id, more)
                _ -> (id, after)
          (digits, leftover) <- digitsOf digitsText False
          unless (null leftover && not (null digits)) Nothing
          Just (esign (read digits :: Integer))
        _ -> Nothing
      let mantissa = read ('0' : whole <> fraction) :: Integer
          scale = exponent' - toInteger (length fraction)
          magnitude = toInteger (length (show mantissa)) + scale
      pure $
        if mantissa == 0
          then 0
          else
            if magnitude > 400
              then 1 / 0
              else
                if magnitude < -400
                  then 0
                  else fromRational (fromInteger mantissa * (10 ^^ scale))
    -- Digits with single underscores between them; 'Nothing' for a
    -- misplaced underscore.
    digitsOf text _ =
      let (run, rest) = span (\c -> isDigit c || c == '_') text
       in if valid run then Just (filter (/= '_') run, rest) else Nothing
    valid run = not ("__" `T.isInfixOf` T.pack run) && take 1 run /= "_" && take 1 (reverse run) /= "_"

-- ---------------------------------------------------------------------------
-- inspect-instance

maxHistoryBytes, maxBindingBytes, maxIdentifierBytes :: Int
maxHistoryBytes = 16 * 1024 * 1024
maxBindingBytes = 4096
maxIdentifierBytes = 1024

-- | @_read_bounded_regular(path, limit)@.
readBoundedRegular :: FilePath -> Int -> IO ByteString
readBoundedRegular path limit = do
  outcome <- try @IOException $ do
    info <- Posix.getSymbolicLinkStatus path
    let size = fromIntegral (Posix.fileSize info) :: Integer
    when (Posix.isSymbolicLink info || not (Posix.isRegularFile info) || not (0 < size && size <= toInteger limit)) $
      throwIO (ValueError "Instance state file is not a bounded regular file")
    fd <- PosixIO.openFd path PosixIO.ReadOnly PosixIO.defaultFileFlags {PosixIO.nofollow = True}
    ( do
        before <- Posix.getFdStatus fd
        let readLoop chunks total = do
              let wanted = min 65536 (limit + 1 - total)
              chunk <- if wanted <= 0 then pure "" else readChunk fd wanted
              if BS.null chunk
                then pure (BS.concat (reverse chunks))
                else do
                  let total' = total + BS.length chunk
                  when (total' > limit) $ throwIO (ValueError "Instance state file is not a bounded regular file")
                  readLoop (chunk : chunks) total'
        bytes <- readLoop [] 0
        after <- Posix.getFdStatus fd
        pure (before, after, bytes)
      )
      `finally` PosixIO.closeFd fd
  case outcome of
    Left _ -> throwIO (ValueError "Instance state cannot be inspected safely")
    Right (before, after, bytes) -> do
      let identity s = (Posix.deviceID s, Posix.fileID s, Posix.fileSize s, Posix.modificationTimeHiRes s)
      when (identity before /= identity after || toInteger (BS.length bytes) /= toInteger (Posix.fileSize before)) $
        throwIO (ValueError "Instance state changed during inspection")
      pure bytes
  where
    -- @os.read@: an empty read at end of file.
    readChunk fd wanted = PosixBS.fdRead fd (fromIntegral wanted) `catchIOError` \e -> if isEOFError e then pure "" else throwIO e

-- | @_require_real_directories(paths)@.
requireRealDirectories :: [FilePath] -> IO ()
requireRealDirectories paths = do
  outcome <- try @IOException $ forM paths $ \path -> do
    info <- Posix.getSymbolicLinkStatus path
    pure (Posix.isSymbolicLink info || not (Posix.isDirectory info))
  case outcome of
    Left _ -> throwIO (ValueError "Instance state cannot be inspected safely")
    Right flags -> when (or flags) $ throwIO (ValueError "Instance state path is not a real directory")

-- | @_identifier(value, error)@.
identifier :: Json -> Text -> IO Text
identifier value message = case value of
  String text
    | 0 < utf8Length text && utf8Length text <= maxIdentifierBytes && isAscii text && isPrintable text -> pure text
  _ -> throwIO (ValueError message)

-- | @str.splitlines()@.
splitLines :: Text -> [Text]
splitLines text
  | T.null text = []
  | otherwise =
      let (line, rest) = T.break boundary text
       in line : case T.uncons rest of
            Nothing -> []
            Just ('\r', more) | Just ('\n', after) <- T.uncons more -> splitLines after
            Just (_, more) -> splitLines more
  where
    boundary c = c `elem` ("\n\r\v\f\x1c\x1d\x1e\x85\x2028\x2029" :: String)

-- | A History instant: an @int@ or a finite @float@ (never a @bool@).
data Instant = IntInstant Integer | FloatInstant Double

instantValue :: Instant -> Rational
instantValue = \case
  IntInstant i -> fromInteger i
  FloatInstant d -> toRational d

instantJson :: Instant -> Json
instantJson = \case
  IntInstant i -> Int i
  FloatInstant d -> Float d

-- | @inspect_instance(state_path, installation_id, repository_id,
-- pull_request)@: a bounded, payload-free summary of one Instance's state.
inspectInstance :: FilePath -> Integer -> Integer -> Integer -> IO Json
inspectInstance statePath installationId repositoryId pullRequest = do
  when (minimum [installationId, repositoryId, pullRequest] <= 0) $
    throwIO (ValueError "Instance identifiers must be positive")
  let applications = statePath </> "applications"
      installationPath = applications </> show installationId
      repositoryPath = installationPath </> show repositoryId
      root = repositoryPath </> show pullRequest
  requireRealDirectories [statePath, applications, installationPath, repositoryPath, root]
  raw <- readBoundedRegular (root </> "history.jsonl") maxHistoryBytes
  boundBytes <- readBoundedRegular (root </> "binding.json") maxBindingBytes
  let unsafe = ValueError "Instance state cannot be inspected safely"
      decode bytes = either (const (throwIO unsafe)) pure (TE.decodeUtf8' bytes)
      loads text = either (const (throwIO unsafe)) pure (parseJson pythonLoads (TE.encodeUtf8 text))
  boundValue <- decode boundBytes >>= loads
  records <- decode raw >>= mapM loads . splitLines
  bound <- either (const (throwIO (ValueError "Instance state binding is malformed"))) pure (parseInstanceBinding boundValue)
  let wellFormed = \case
        Object members | Just (String _) <- lookup' "record" members -> True
        _ -> False
  when (bound.pullRequest /= pullRequest || null records || not (all wellFormed records)) $
    throwIO (ValueError "Instance state binding or History is malformed")
  let expected = "github:" <> tshow installationId <> ":" <> tshow repositoryId <> ":pr:" <> tshow pullRequest
  instanceId <- identifier (String bound.instanceId) "Instance identity is malformed"
  repository <- identifier (String bound.repository) "Instance repository is malformed"
  when (instanceId /= expected) $
    throwIO (ValueError "Instance state binding does not match its selected path")
  requested <- newIORef Map.empty
  completed <- newIORef Set.empty
  failed <- newIORef Set.empty
  firingFailed <- newIORef Set.empty
  lastInstant <- newIORef (IntInstant 0)
  let malformedInstant = throwIO (ValueError "Instance History instant is malformed")
  mapM_
    ( \case
        Object members -> do
          instant <- case fromMaybe (Int 0) (lookup' "instant" members) of
            Int i
              | abs i > maxFloatInteger -> throwIO (PythonException "OverflowError" [PyStr "int too large to convert to float"])
              | otherwise -> pure (IntInstant i)
            Float d
              | isNaN d || isInfinite d -> malformedInstant
              | otherwise -> pure (FloatInstant d)
            _ -> malformedInstant
          modifyIORef' lastInstant (\current -> if instantValue instant > instantValue current then instant else current)
          let occurrence = case lookup' "occurrence" members of
                Just (Int i) -> Just i
                _ -> Nothing
              recordName = case lookup' "record" members of
                Just (String name) -> name
                _ -> ""
          case recordName of
            "ActivityRequested" -> do
              key <- case occurrence of
                Just i | i > 0 -> pure i
                _ -> throwIO (ValueError "Instance Activity identity is malformed")
              let input = lookup' "input" members
                  work = case input of
                    Just (Object fields) -> case lookup' "work" fields of
                      Just value -> Just value
                      Nothing -> lookup' "command" fields
                    _ -> Nothing
                  operation = case work of
                    Just (Object fields) -> fromMaybe Null (lookup' "operation" fields)
                    _ -> Null
              transition <- identifier (fromMaybe Null (lookup' "transition" members)) "Activity identifiers are malformed"
              activity <- identifier (fromMaybe Null (lookup' "activity" members)) "Activity identifiers are malformed"
              operation' <- identifier operation "Activity operation is malformed"
              modifyIORef'
                requested
                ( Map.insert
                    key
                    ( Object
                        [ ("occurrence", Int key)
                        , ("transition", String transition)
                        , ("activity", String activity)
                        , ("operation", String operation')
                        ]
                    )
                )
            "ActivityCompleted" | Just i <- occurrence -> modifyIORef' completed (Set.insert i)
            "ActivityFailed" | Just i <- occurrence -> modifyIORef' failed (Set.insert i)
            "FiringFailed" | Just i <- occurrence -> modifyIORef' firingFailed (Set.insert i)
            _ -> pure ()
        _ -> pure ()
    )
    records
  requestedMap <- readIORef requested
  completedSet <- readIORef completed
  failedSet <- readIORef failed
  firingSet <- readIORef firingFailed
  final <- readIORef lastInstant
  let unresolved =
        [ entry
        | (key, entry) <- Map.toAscList requestedMap
        , not (Set.member key completedSet || Set.member key failedSet)
        ]
  when (length unresolved > 1000) $
    throwIO (ValueError "Instance unresolved Activity inventory exceeds its bound")
  pure $
    Object
      [ ("command", String "inspect-instance")
      , ("instance_id", String instanceId)
      , ("repository", String repository)
      , ("pull_request", Int pullRequest)
      , ("topology", String (topologyText bound.topology))
      , ("record_count", Int (toInteger (length records)))
      , ("last_instant", instantJson final)
      ,
        ( "activities"
        , Object
            [ ("requested", Int (toInteger (Map.size requestedMap)))
            , ("completed", Int (toInteger (Set.size completedSet)))
            , ("failed", Int (toInteger (Set.size failedSet)))
            , ("firing_failed", Int (toInteger (Set.size firingSet)))
            , ("unresolved", Array unresolved)
            ]
        )
      , ("ok", Bool True)
      ]
  where
    -- The largest integer @float()@ converts without @OverflowError@.
    maxFloatInteger = truncate (1.7976931348623157e308 :: Double) :: Integer

-- | @dict.get@: duplicate members resolve to the last one, as
-- @json.loads@ builds the dict.
lookup' :: Text -> [(Text, Json)] -> Maybe Json
lookup' key members = lookup key (reverse members)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Running

-- | Everything the command line takes from its process, as seams.
data CliEnvironment = CliEnvironment
  { environment :: Map String String
  -- ^ @os.environ@.
  , forgetSecrets :: IO ()
  -- ^ @os.environ.pop@ of the two GitHub secrets once the configuration
  -- holds them.
  , loadConfig :: IO HostConfig
  -- ^ @HostConfig.from_environment()@.
  , clientOptions :: IO ClientOptions
  -- ^ The GitHub network (@GitHubAppClients(config)@'s transport).
  , composeAgent :: OwnedAgent -> FilePath -> IO (AgentRunner, AgentCustody)
  -- ^ The agent composition over the state path (the Pi installation,
  -- @compose_agent@, the route store, the workspace receiver and the Pi
  -- runtime); called only for the commands that open the service. Each
  -- resource is recorded in the 'OwnedAgent' as soon as it exists, so
  -- startup cleanup releases it when the service never opens.
  , columns :: IO Int
  -- ^ @shutil.get_terminal_size().columns@.
  , output :: Handle
  , errors :: Handle
  , onServing :: Int -> IO ()
  -- ^ Called once @serve@ listens, with the port.
  , reraise :: Signal -> IO ()
  -- ^ After SIGTERM stopped @serve@ gracefully: uvicorn's
  -- @signal.raise_signal@ with the previous (default) handler restored. In
  -- the process ('productionEnvironment') the default action, so the
  -- process ends by SIGTERM as the reference's does; 'runCli' returns
  -- @128 + 15@ only when this returns.
  }

-- | The process's own environment: the real network, the real Pi A2
-- composition, standard streams.
productionEnvironment :: Map String String -> CliEnvironment
productionEnvironment environment =
  CliEnvironment
    { environment
    , forgetSecrets = mapM_ unsetEnv ["HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"]
    , loadConfig = fromEnvironment environment
    , clientOptions = defaultClientOptions
    , composeAgent = \owned ->
        composeHostAgent
          productionAgentSeams
          owned
          [ (T.pack name, T.pack value)
          | (name, value) <- Map.toList environment
          , name `notElem` ["HAMSTERDAN_GITHUB_PRIVATE_KEY", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"]
          ]
          (unsetEnv "HAMSTERDAN_PI_API_KEY")
    , columns = terminalColumns environment
    , output = stdout
    , errors = stderr
    , onServing = \_ -> pure ()
    , reraise = \signal -> installHandler signal Default Nothing >> raiseSignal signal
    }

-- | Why the reference's @except (ConfigurationError, RuntimeError,
-- ValueError)@ catches a failure, as @str(error)@; 'Nothing' for the
-- failures it lets escape.
handledMessage :: SomeException -> Maybe Text
handledMessage e
  | Just (ConfigurationError m) <- fromException e = Just m
  | Just (RuntimeError m) <- fromException e = Just m
  | Just (ValueError m) <- fromException e = Just m
  | Just (AgentCompositionError m) <- fromException e = Just m
  | Just (failure :: AgenticusError) <- fromException e
  , any (failure.errorClass `isSubclassOf`) [AE.ValueError, AE.RuntimeError] =
      Just failure.errorMessage
  | Just (boundaryError :: GitHubBoundaryError) <- fromException e = Just boundaryError.message
  | Just (ContractRefused m) <- fromException e = Just m
  | Just (InvalidRequest m) <- fromException e = Just m
  | Just (failure :: ClientError) <- fromException e
  , failure.kind `elem` [ValueKind, RuntimeKind] =
      Just failure.detail
  | Just (fault :: PythonFault) <- fromException e
  , fault.pythonClass == "ValueError" =
      Just fault.pythonDetail
  | Just (PythonException name args) <- fromException e
  , name `elem` ["ValueError", "RuntimeError", "UnicodeDecodeError", "JSONDecodeError"] =
      Just (case args of [PyStr m] -> m; _ -> "")
  | otherwise = Nothing

-- | @main()@ with @sys.argv[1:]@; the exit status.
runCli :: CliEnvironment -> [Text] -> IO ExitCode
runCli env argv = do
  width <- subtract 2 <$> env.columns
  let say handle text = BS.hPut handle (TE.encodeUtf8 text) >> hFlush handle
      usageError message = do
        say env.errors (formatUsage width <> prog <> ": error: " <> message <> "\n")
        pure (ExitFailure 2)
      escaped e = do
        say env.errors (uncaughtText e)
        pure (ExitFailure 1)
      hostDefault = maybe "127.0.0.1" T.pack (Map.lookup "HAMSTERDAN_HOST" env.environment)
      portText = maybe "8000" T.pack (Map.lookup "HAMSTERDAN_PORT" env.environment)
  case pythonInt portText of
    Nothing -> escaped (toException (PythonException "ValueError" [PyStr ("invalid literal for int() with base 10: " <> strRepr portText)]))
    Just portDefault -> case parseCommandLine hostDefault portDefault argv of
      ShowHelp -> say env.output (formatHelp width) >> pure ExitSuccess
      ParseError message -> usageError message
      Parsed arguments
        | arguments.command == "requeue" && maybe True T.null arguments.delivery -> usageError "requeue requires --delivery"
        | arguments.command == "inspect-instance" && any isNothing [arguments.installation, arguments.repository, arguments.pullRequest] ->
            usageError "inspect-instance requires --installation, --repository, and --pr"
        | otherwise -> do
            service <- newIORef Nothing
            owned <- newOwnedAgent
            let body = do
                  config <- env.loadConfig
                  env.forgetSecrets
                  case (arguments.command, arguments.installation, arguments.repository, arguments.pullRequest) of
                    ("inspect-instance", Just i, Just r, Just p) -> do
                      result <- inspectInstance config.statePath i r p
                      say env.output (dumpsSorted result <> "\n")
                      pure ExitSuccess
                    _ -> do
                      when (Map.member "HAMSTERDAN_READINESS_TOPOLOGY" env.environment) $
                        throwIO (ValueError "HAMSTERDAN_READINESS_TOPOLOGY is retired; remove it to run the V5 topology")
                      preflightV5State config.statePath
                      (runner, agents) <- env.composeAgent owned config.statePath
                      options <- env.clientOptions
                      appClients <-
                        newAppClients
                          AppCredentials {appId = config.appId, clientId = config.clientId, privateKey = revealSecret config.privateKey}
                          options
                      let workflowPath = maybe ".github/workflows/ci.yml" T.pack (Map.lookup "HAMSTERDAN_WORKFLOW_PATH" env.environment)
                      reminderDelay <-
                        either (throwIO . ValueError) pure $
                          pythonFloat (maybe "259200" T.pack (Map.lookup "HAMSTERDAN_REMINDER_SECONDS" env.environment))
                      qualificationFault <- qualificationFaultFromEnvironment (T.pack <$> Map.lookup "HAMSTERDAN_QUALIFICATION_FAULT" env.environment)
                      opened <-
                        openHostService
                          config
                          (serviceOptions runner agents)
                            { clients = Just (gitHubHostClients appClients)
                            , workflowPath
                            , reminderDelay
                            , qualificationFault
                            }
                      writeIORef service (Just opened)
                      command opened
                command opened = case arguments.command of
                  "validate" -> do
                    result <- reconcileRegistration opened
                    say env.output (dumpsSorted result <> "\n")
                    pure ExitSuccess
                  "inbox" -> do
                    counts <- Custody.counts opened.custody
                    failures <- Custody.failures opened.custody 100
                    let failureJson failure =
                          Object
                            [ ("delivery_id", String failure.deliveryId)
                            , ("event", String failure.event)
                            , ("attempts", Int (toInteger failure.attempts))
                            , ("error_class", maybe Null String failure.errorClass)
                            , ("reason", maybe Null String failure.reason)
                            ]
                    say env.output $
                      dumpsSorted
                        ( Object
                            [ ("counts", Object [(name, Int (toInteger count)) | (name, count) <- Map.toList counts])
                            , ("failures", Array (map failureJson failures))
                            ]
                        )
                        <> "\n"
                    pure ExitSuccess
                  "requeue" -> do
                    let deliveryId = fromMaybe "" arguments.delivery
                    requeued <- Custody.requeue opened.custody deliveryId
                    say env.output (dumpsSorted (Object [("delivery_id", String deliveryId), ("requeued", Bool requeued)]) <> "\n")
                    pure (if requeued then ExitSuccess else ExitFailure 1)
                  _ -> do
                    served <-
                      try @IOException $
                        serve
                          opened
                          ServeOptions
                            { host = T.unpack arguments.host
                            , port = fromInteger arguments.port
                            , onStarted = env.onServing (fromInteger arguments.port)
                            }
                    case served of
                      Left _ -> pure (ExitFailure 3)
                      -- SIGTERM, raised again: the default action, at once
                      -- (the @finally@ never runs; the lifespan has already
                      -- closed the service).
                      Right (Just signal)
                        | signal == sigTERM -> do
                            env.reraise signal
                            pure (ExitFailure (128 + fromIntegral signal))
                      -- SIGINT, raised again under @asyncio.run@'s own
                      -- handler, which only cancels uvicorn's main task, by
                      -- then finished: @uvicorn.run@ returns, the @finally@
                      -- runs, status 0.
                      Right _ -> pure ExitSuccess
                -- @finally: _close_owned_resources(service, pi_runtime,
                -- route_store)@, after the @except@ clause has printed its
                -- usage error.
                cleanup = do
                  opened <- readIORef service
                  try @SomeException (closeOwnedAgent (Service.close <$> opened) owned)
            outcome <- try @SomeException body
            settled <- case outcome of
              Right code -> pure (Right code)
              Left e
                | Just message <- handledMessage e -> Right <$> usageError message
                | Just (code :: ExitCode) <- fromException e -> pure (Right code)
                | otherwise -> pure (Left e)
            closing <- cleanup
            case closing of
              Left failure -> escaped failure
              Right () -> either escaped pure settled
  where
    dumpsSorted value = either (const "null") id (dumpsText defaultDumps {Json.sortKeys = True} value)

-- | What an uncaught exception prints (the reference prints a traceback
-- ending in this line).
uncaughtText :: SomeException -> Text
uncaughtText e = case fromException e of
  Just (PythonException name args) -> name <> ": " <> (case args of [PyStr m] -> m; _ -> "") <> "\n"
  _ -> case fromException e of
    Just (RuntimeError m) -> "RuntimeError: " <> m <> "\n"
    _ -> case fromException e of
      Just (failure :: AgenticusError) -> errorClassName failure.errorClass <> ": " <> failure.errorMessage <> "\n"
      _ -> T.pack (displayException e) <> "\n"
