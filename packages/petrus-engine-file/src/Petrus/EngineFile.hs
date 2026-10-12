-- | Petrus net files in petrus-engine's @fileVersion: "2"@ format (the
-- format petrus-viewer saves), with the reference's acceptance, refusals,
-- error texts and canonical spelling.
--
-- * 'fromFilename', 'fromJson', 'fromDict': @FlatNetFile.from_filename@,
--   @model_validate_json@ and @from_dict@.
-- * 'toJson': @FlatNetFile.to_json@, byte for byte.
-- * 'reformatContent': @petrus.cli.format_json.reformat_content@.
-- * 'loadFile', 'loadDict': @FlatNet.from_filename@ and @FlatNet.from_dict@
--   (refs inlined); 'toSchema' projects to the executable 'FlatSchema'.
-- * 'toKernel', 'loadKernelFile': that schema as a validated kernel net
--   ("Petrus.Impetus.Petrinet.Schema") and its initial marking.
module Petrus.EngineFile
  ( -- * Models
    module Petrus.EngineFile.Types
  , Value (..)
  , PythonException (..)

    -- * Reading one file
  , fromFilename
  , fromJson
  , fromDict
  , loads

    -- * Writing
  , toJson
  , toJsonBytes
  , reformatContent
  , defaultIndent
  , defaultMaxInline
  , formatMaxInline

    -- * Multi-file nets
  , Source (..)
  , loadFile
  , loadDict
  , mountedSources
  , resolve
  , toSchema

    -- * Kernel nets
  , KernelNet (..)
  , KernelError (..)
  , toKernel
  , loadKernelFile
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Petrus.EngineFile.Encode (toJson, toJsonBytes)
import Petrus.EngineFile.Kernel (KernelError (..), KernelNet (..), loadKernelFile, toKernel)
import Petrus.EngineFile.Loader
import Petrus.EngineFile.PyJson (pyJsonErrorClass, pyLoads, renderPyJsonError)
import Petrus.EngineFile.Types
import Petrus.Json.Python.Exception (PythonException (..), pythonError)
import Petrus.EngineFile.Value (Value (..))

-- | @to_json@'s default indent.
defaultIndent :: Int
defaultIndent = 2

-- | @to_json@'s default @max_inline@.
defaultMaxInline :: Int
defaultMaxInline = 100

-- | The format CLI's default @max_inline@.
formatMaxInline :: Int
formatMaxInline = 120

-- | @FlatNetFile.from_filename(path)@.
fromFilename :: Text -> IO (Either PythonException FlatNetFile)
fromFilename = readFileNet

-- | @FlatNetFile.model_validate_json(text)@ on a text's UTF-8 bytes.
fromJson :: ByteString -> Either PythonException FlatNetFile
fromJson = validateJsonText

-- | @FlatNetFile.from_dict(value)@ on objects @json.loads@ built.
fromDict :: Value -> Either PythonException FlatNetFile
fromDict = readDictNet

-- | @json.loads(text)@ on a text's UTF-8 bytes.
loads :: ByteString -> Either PythonException Value
loads bytes = case pyLoads bytes of
  Left e -> Left (pythonError (pyJsonErrorClass e) (renderPyJsonError e))
  Right v -> Right v

-- | @reformat_content(content, indent=, max_inline=)@: whether the content
-- changed, and the canonical spelling.
reformatContent :: Int -> Int -> ByteString -> Either PythonException (Bool, ByteString)
reformatContent indent maxInline content = do
  raw <- loads content
  file <- fromDict raw
  formatted <- toJsonBytes indent maxInline file
  Right (formatted /= content, formatted)

-- | @FlatNet.from_filename(path)@.
loadFile :: Text -> IO (Either PythonException FlatNet)
loadFile path = (>>= resolve False) <$> mountedSources (FileSource path)

-- | @FlatNet.from_dict(root, deps)@.
loadDict :: Value -> [(Text, Value)] -> Either PythonException FlatNet
loadDict root deps = mountedDict root deps >>= resolve True
