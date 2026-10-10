-- | @petrus-format-json@: @python -m petrus.cli.format_json@.
--
-- > petrus-format-json nets/net_*.json                  # format in place
-- > petrus-format-json --fail-on-change nets/net_*.json # exit 1 when anything changed
-- > cat net.json | petrus-format-json                   # stdin to stdout
-- > petrus-format-json --infile in.json --outfile out.json
--
-- With paths, each file is reformatted in place (only when it changes) and
-- @reformatted: PATH@ is printed for each changed file. Without paths, one
-- input stream is formatted to one output stream, written only when it
-- changes. An exception ends the run with exit status 1 and its last
-- traceback line on stderr; a usage error exits 2.
module Main (main) where

import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isSpace)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile (PyException (..), formatMaxInline, reformatContent)
import Petrus.EngineFile.PyText (decodeText, pathText, purePath, readBytes, readText, writeBytes)
import Petrus.Json.PythonText (pythonStrRepr)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hPutStrLn, hSetBinaryMode, stderr, stdin, stdout)

data Stream = Std | Named Text

data Options = Options
  { paths :: [Text]
  , infile :: Stream
  , outfile :: Stream
  , indent :: Int
  , maxInline :: Int
  , failOnChange :: Bool
  }

prog :: String
prog = "petrus-format-json"

usage :: String
usage =
  "usage: "
    <> prog
    <> " [-h] [--infile INFILE] [--outfile OUTFILE] [--indent INDENT] [--max-inline MAX_INLINE] [--fail-on-change] [paths ...]"

help :: String
help =
  unlines
    [ usage
    , ""
    , "Format Petrus net JSON files."
    , ""
    , "positional arguments:"
    , "  paths                 JSON file paths to format in-place"
    , ""
    , "options:"
    , "  -h, --help            show this help message and exit"
    , "  --infile INFILE       Single-file input stream (default: stdin; ignored when paths are provided)"
    , "  --outfile OUTFILE     Single-file output stream (default: stdout; ignored when paths are provided)"
    , "  --indent INDENT       Indent size (default: 2)"
    , "  --max-inline MAX_INLINE"
    , "                        Max chars for one-line objects/lists (default: 120)"
    , "  --fail-on-change      Exit with code 1 when any input is reformatted"
    ]

-- | Command-line errors argparse reports (exit status 2).
usageError :: String -> IO a
usageError message = do
  hPutStrLn stderr usage
  hPutStrLn stderr (prog <> ": error: " <> message)
  exitWith (ExitFailure 2)

-- | An exception escaping @cli()@: its last traceback line, exit status 1.
raise :: PyException -> IO a
raise e = do
  hFlush stdout
  BS.hPut stderr (TE.encodeUtf8 (qualified e.exceptionClass <> ": " <> e.message <> "\n"))
  exitWith (ExitFailure 1)
  where
    qualified = \case
      "ValidationError" -> "pydantic_core._pydantic_core.ValidationError"
      "PydanticSerializationError" -> "pydantic_core._pydantic_core.PydanticSerializationError"
      "JSONDecodeError" -> "json.decoder.JSONDecodeError"
      other -> other

options :: [String]
options = ["--help", "--infile", "--outfile", "--indent", "--max-inline", "--fail-on-change"]

-- | argparse's parse, opening @FileType@ arguments as they are met (an
-- @--outfile@ is created or truncated even when nothing is written).
parseArgs :: [String] -> IO Options
parseArgs = go Options {paths = [], infile = Std, outfile = Std, indent = 2, maxInline = formatMaxInline, failOnChange = False} False
  where
    go o _ [] = pure o {paths = reverse o.paths}
    go o True (a : rest) = go o {paths = T.pack a : o.paths} True rest
    go o False (a : rest)
      | a == "--" = go o True rest
      | a == "-h" = putStr help >> exitWith ExitSuccess
      | "--" `isPrefixOf` a = do
          let (flag, inlineValue) = case break (== '=') a of
                (f, '=' : v) -> (f, Just v)
                (f, _) -> (f, Nothing)
          option <- resolve flag
          case option of
            "--help" -> putStr help >> exitWith ExitSuccess
            "--fail-on-change" -> case inlineValue of
              Just _ -> usageError ("argument --fail-on-change: ignored explicit argument " <> show' (maybe "" id inlineValue))
              Nothing -> go o {failOnChange = True} False rest
            _ -> do
              (value, rest') <- case (inlineValue, rest) of
                (Just v, _) -> pure (v, rest)
                (Nothing, v : more) | not (looksLikeOption v) -> pure (v, more)
                _ -> usageError ("argument " <> option <> ": expected one argument")
              o' <- apply o option value
              go o' False rest'
      | "-" `isPrefixOf` a && a /= "-" && not (isNegativeNumber a) = usageError ("unrecognized arguments: " <> a)
      | otherwise = go o {paths = T.pack a : o.paths} False rest
    resolve flag
      | flag `elem` options = pure flag
      | otherwise = case filter (flag `isPrefixOf`) options of
          [one] -> pure one
          [] -> usageError ("unrecognized arguments: " <> flag)
          many -> usageError ("ambiguous option: " <> flag <> " could match " <> commaList many)
    commaList = foldr1 (\x y -> x <> ", " <> y)
    looksLikeOption v = "-" `isPrefixOf` v && v /= "-" && not (isNegativeNumber v)
    isNegativeNumber v = case v of
      '-' : digits@(_ : _) -> all (\c -> isDigit c || c == '.') digits
      _ -> False
    apply o option value = case option of
      "--indent" -> (\n -> o {indent = n}) <$> intArg option value
      "--max-inline" -> (\n -> o {maxInline = n}) <$> intArg option value
      "--infile" -> do
        stream <- openRead value
        pure o {infile = stream}
      "--outfile" -> do
        stream <- openWrite value
        pure o {outfile = stream}
      _ -> usageError ("unrecognized arguments: " <> option)
    intArg option value = maybe (usageError ("argument " <> option <> ": invalid int value: " <> show' value)) pure (pyInt value)
    openRead value
      | value == "-" = pure Std
      | otherwise = do
          result <- readBytes (T.pack value)
          case result of
            Left e -> usageError ("argument --infile: can't open '" <> value <> "': " <> T.unpack e.message)
            Right _ -> pure (Named (T.pack value))
    openWrite value
      | value == "-" = pure Std
      | otherwise = do
          result <- writeBytes (T.pack value) BS.empty
          case result of
            Left e -> usageError ("argument --outfile: can't open '" <> value <> "': " <> T.unpack e.message)
            Right () -> pure (Named (T.pack value))
    show' = T.unpack . pythonStrRepr . T.pack

-- | Python's @int(str)@ for ASCII digits: surrounding whitespace, a sign,
-- and single underscores between digits.
pyInt :: String -> Maybe Int
pyInt raw = case dropWhile isSpace (reverse (dropWhile isSpace (reverse raw))) of
  '-' : ds -> negate <$> digits ds
  '+' : ds -> digits ds
  ds -> digits ds
  where
    digits ds
      | null ds || head' ds == '_' || last ds == '_' = Nothing
      | "__" `T.isInfixOf` T.pack ds = Nothing
      | all (\c -> isDigit c || c == '_') ds = Just (read (filter (/= '_') ds))
      | otherwise = Nothing
    head' = \case
      c : _ -> c
      [] -> ' '

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  o <- getArgs >>= parseArgs
  if null o.paths
    then do
      content <- case o.infile of
        Std -> BS.getContents
        Named path -> readText path >>= either raise pure
      changed <- formatOne o content (writeStream o.outfile)
      exitWith (status o changed)
    else do
      changed <- fmap concat $ mapM (formatPath o) o.paths
      forM_ changed $ \label -> BS.putStr (TE.encodeUtf8 ("reformatted: " <> label <> "\n"))
      exitWith (status o (not (null changed)))
  where
    status o changed = if changed && o.failOnChange then ExitFailure 1 else ExitSuccess
    formatPath o raw = do
      let label = pathText (purePath raw)
      content <- readText label >>= either raise pure
      changed <- formatOne o content (\bytes -> writeBytes label bytes >>= either raise pure)
      pure [label | changed]
    writeStream = \case
      Std -> BS.putStr
      Named path -> \bytes -> writeBytes path bytes >>= either raise pure

-- | @reformat_content@ and the write when it changed.
formatOne :: Options -> ByteString -> (ByteString -> IO ()) -> IO Bool
formatOne o content write = do
  -- stdin is read as text without newline translation; it must still be
  -- UTF-8.
  text <- either raise pure (validUtf8 content)
  (changed, formatted) <- either raise pure (reformatContent o.indent o.maxInline text)
  when changed (write formatted)
  pure changed
  where
    validUtf8 bytes = case decodeText bytes of
      Left e -> Left e
      Right _ -> Right bytes
