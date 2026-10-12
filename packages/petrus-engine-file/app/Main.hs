-- | @petrus-format-json@: @python -m petrus.cli.format_json@.
--
-- > petrus-format-json nets/net_*.json                  # format in place
-- > petrus-format-json --fail-on-change nets/net_*.json # exit 1 when anything changed
-- > cat net.json | petrus-format-json                   # stdin to stdout
-- > petrus-format-json --infile in.json --outfile out.json
--
-- The command line is the reference's @argparse@ declaration, parsed by
-- petrus-argparse (which opens @--infile@ and @--outfile@ while parsing, as
-- @argparse.FileType@ does). With paths, each file is reformatted in place
-- (only when it changes) and @reformatted: PATH@ is printed for each
-- changed file. Without paths, one input stream is formatted to one output
-- stream, written only when it changes. An exception ends the run with
-- exit status 1 and its last traceback line on stderr; a usage error exits
-- 2.
module Main (main) where

import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Argparse
  ( ArgumentParser (..)
  , FileMode (..)
  , Stream (..)
  , constant
  , defaulted
  , file
  , getArguments
  , help
  , int
  , path
  , positionals
  , runArgumentParser
  )
import Petrus.EngineFile (PythonException (..), formatMaxInline, reformatContent)
import Petrus.EngineFile.PyText (decodeText, readText, writeBytes)
import Petrus.Json.Python.Decode (utf8EncodeFailure)
import Petrus.Json.Python.Exception (pythonExceptionStr, unicodeEncodeError)
import Petrus.Json.Python.Fs (utf8BackslashReplace)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hSetBinaryMode, stderr, stdin, stdout)

data Options = Options
  { paths :: [Text]
  , infile :: Stream
  , outfile :: Stream
  , indent :: Integer
  , maxInline :: Integer
  , failOnChange :: Integer
  }

-- | @format_json.parse@'s parser.
formatJson :: ArgumentParser Options
formatJson =
  ArgumentParser "petrus-format-json" (Just "Format Petrus net JSON files.") $
    Options
      <$> positionals path "paths" [help "JSON file paths to format in-place"]
      <*> defaulted (file ForReading) ["--infile"] StandardStream [help "Single-file input stream (default: stdin; ignored when paths are provided)"]
      <*> defaulted (file ForWriting) ["--outfile"] StandardStream [help "Single-file output stream (default: stdout; ignored when paths are provided)"]
      <*> defaulted int ["--indent"] 2 [help "Indent size (default: 2)"]
      <*> defaulted int ["--max-inline"] (toInteger formatMaxInline) [help "Max chars for one-line objects/lists (default: 120)"]
      <*> constant int ["--fail-on-change"] 1 0 [help "Exit with code 1 when any input is reformatted"]

-- | An exception escaping @cli()@: its last traceback line, exit status 1.
raise :: PythonException -> IO a
raise e = do
  hFlush stdout
  BS.hPut stderr (utf8BackslashReplace (qualified e.name <> ": " <> pythonExceptionStr e <> "\n"))
  exitWith (ExitFailure 1)
  where
    qualified = \case
      "ValidationError" -> "pydantic_core._pydantic_core.ValidationError"
      "PydanticSerializationError" -> "pydantic_core._pydantic_core.PydanticSerializationError"
      "JSONDecodeError" -> "json.decoder.JSONDecodeError"
      other -> other

-- | @print(text)@ to a UTF-8 standard output, which refuses a lone
-- surrogate (a file name argv could not decode) with
-- @UnicodeEncodeError@.
printLine :: Text -> IO ()
printLine text = case utf8EncodeFailure text of
  Just failure -> raise (unicodeEncodeError text failure)
  Nothing -> BS.putStr (TE.encodeUtf8 text <> "\n")

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  o <- getArguments >>= runArgumentParser formatJson
  if null o.paths
    then do
      content <- case o.infile of
        StandardStream -> BS.getContents
        NamedFile name -> readText name >>= either raise pure
      changed <- formatOne o content (writeStream o.outfile)
      exitWith (status o changed)
    else do
      changed <- concat <$> mapM (formatPath o) o.paths
      forM_ changed $ \label -> printLine ("reformatted: " <> label)
      exitWith (status o (not (null changed)))
  where
    status o changed
      | changed && o.failOnChange /= 0 = ExitFailure (fromInteger o.failOnChange)
      | otherwise = ExitSuccess
    formatPath o label = do
      content <- readText label >>= either raise pure
      changed <- formatOne o content (\bytes -> writeBytes label bytes >>= either raise pure)
      pure [label | changed]
    writeStream = \case
      StandardStream -> BS.putStr
      NamedFile name -> \bytes -> writeBytes name bytes >>= either raise pure

-- | @reformat_content@ and the write when it changed.
formatOne :: Options -> ByteString -> (ByteString -> IO ()) -> IO Bool
formatOne o content write = do
  -- stdin is read as text without newline translation; it must still be
  -- UTF-8.
  text <- either raise pure (validUtf8 content)
  (changed, formatted) <- either raise pure (reformatContent (fromInteger o.indent) (fromInteger o.maxInline) text)
  when changed (write formatted)
  pure changed
  where
    validUtf8 bytes = case decodeText bytes of
      Left e -> Left e
      Right _ -> Right bytes
