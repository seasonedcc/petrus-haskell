-- | A net's files, as the net tools read them: the net, a Net-definition v3
-- or a Net document v1, and its declarations and waivers beside it.
module Petrus.Net.Files
  ( readNet
  , readDeclared
  , readWaivers
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.NetDefinition (compileNetDefinition, parseNetDefinition)
import Petrus.Impetus.NetDocument (NetDocumentV1 (..), parseNetDocument)
import Petrus.Impetus.Petrinet.Schema (Net)
import Petrus.Net.Declared
import System.Directory (doesFileExist)
import System.FilePath (dropExtension)

readNet :: FilePath -> IO (Either Text Net)
readNet path = (>>= netOf) <$> readBytes path
  where
    netOf bytes = case parseNetDefinition bytes of
      Right definition -> compileNetDefinition definition
      Left asDefinition -> case parseNetDocument bytes of
        Right document -> compileNetDefinition document.definition
        Left _ -> Left (T.pack path <> " is neither a Net-definition v3 nor a Net document v1: " <> asDefinition)

-- | @NET.declared.json@ beside @NET.json@, or no declarations.
readDeclared :: FilePath -> IO (Either Text Declared)
readDeclared path = beside path ".declared.json" noDeclarations parseDeclared

-- | @NET.waivers.json@ beside @NET.json@, or no waivers.
readWaivers :: FilePath -> IO (Either Text [Waiver])
readWaivers path = beside path ".waivers.json" [] parseWaivers

beside :: FilePath -> String -> a -> (B.ByteString -> Either Text a) -> IO (Either Text a)
beside path suffix none parse = do
  let file = dropExtension path <> suffix
  exists <- doesFileExist file
  if exists
    then (>>= either (Left . ((T.pack file <> ": ") <>)) Right . parse) <$> readBytes file
    else pure (Right none)

readBytes :: FilePath -> IO (Either Text B.ByteString)
readBytes path =
  try (B.readFile path) >>= \case
    Left (problem :: IOException) -> pure (Left (T.pack path <> " can't be read: " <> T.pack (show problem)))
    Right bytes -> pure (Right bytes)
