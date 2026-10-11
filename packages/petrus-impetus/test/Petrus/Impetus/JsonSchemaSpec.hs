-- | The JSON Schema of the Net definition and Net document, byte for byte.
--
-- @differential/net_definition_v3.schema.json@ and
-- @differential/net_document_v1.schema.json@ are the reference's
-- @NetDefinitionV3.model_json_schema()@ and
-- @NetDocumentV1.model_json_schema()@ as @json.dumps(schema, indent=2)@ plus
-- a newline, written by @differential/json_schema.py@ at the pin
-- (@LiveSpec@ regenerates them with the pinned reference and compares).
module Petrus.Impetus.JsonSchemaSpec (spec, schemaBytes) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Petrus.Impetus.NetDefinition (netDefinitionV3JsonSchema)
import Petrus.Impetus.NetDefinitionCorpusSpec (findPackageFile)
import Petrus.Impetus.NetDocument (netDocumentV1JsonSchema)
import Petrus.Json (Json, defaultDumps, dumps, indent)
import Test.Hspec

-- | The Haskell schema spelled as the generator spells the reference's.
schemaBytes :: Json -> ByteString
schemaBytes schema = either (error . show) (<> "\n") (dumps defaultDumps {indent = Just 2} schema)

spec :: Spec
spec = describe "Petrus.Impetus JSON Schema differential corpus (model_json_schema)" $ do
  let check file schema = it (file <> " is the reference's model_json_schema(), byte for byte") $ do
        path <- findPackageFile ["differential/" <> file, "packages/petrus-impetus/differential/" <> file]
        expected <- BS.readFile path
        schemaBytes schema `shouldBe` expected
  check "net_definition_v3.schema.json" netDefinitionV3JsonSchema
  check "net_document_v1.schema.json" netDocumentV1JsonSchema
