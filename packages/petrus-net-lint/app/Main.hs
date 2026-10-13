-- | @petrus-net-lint NET.json@: lint a net's definition, a Net-definition v3
-- or a Net document v1. It reads the declarations and waivers beside it,
-- @NET.declared.json@ and @NET.waivers.json@, when they exist, prints each
-- finding on a line, and exits 1 when there is any.
module Main (main) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Petrus.Impetus.NetDefinition (compileNetDefinition, parseNetDefinition)
import Petrus.Impetus.NetDocument (NetDocumentV1 (..), parseNetDocument)
import Petrus.Impetus.Petrinet.Schema (Net)
import Petrus.Net.Declared
import Petrus.Net.Lint
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (dropExtension)
import System.IO (stderr)

main :: IO ()
main =
  getArgs >>= \case
    [path] -> do
      net <- orStop =<< readNet path
      declared <- beside path ".declared.json" noDeclarations parseDeclared
      waivers <- beside path ".waivers.json" [] parseWaivers
      case lint net declared waivers of
        [] -> pure ()
        found -> mapM_ (T.putStrLn . renderFinding) found >> exitFailure
    _ -> T.hPutStrLn stderr "usage: petrus-net-lint NET.json" >> exitFailure

readNet :: FilePath -> IO (Either Text Net)
readNet path = do
  read' <- try (B.readFile path)
  pure $ case read' of
    Left (problem :: IOException) -> Left (T.pack path <> " can't be read: " <> T.pack (show problem))
    Right bytes -> netOf bytes
  where
    netOf bytes = case parseNetDefinition bytes of
      Right definition -> compileNetDefinition definition
      Left asDefinition -> case parseNetDocument bytes of
        Right document -> compileNetDefinition document.definition
        Left _ -> Left (T.pack path <> " is neither a Net-definition v3 nor a Net document v1: " <> asDefinition)

-- | The file beside the net with this suffix, read, or the default when it
-- doesn't exist.
beside :: FilePath -> String -> a -> (B.ByteString -> Either Text a) -> IO a
beside path suffix none parse = do
  let file = dropExtension path <> suffix
  exists <- doesFileExist file
  if exists then B.readFile file >>= orStop . either (Left . ((T.pack file <> ": ") <>)) Right . parse else pure none

orStop :: Either Text a -> IO a
orStop = either (\problem -> T.hPutStrLn stderr problem >> exitFailure) pure
