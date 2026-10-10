-- | Every Net-definition and Net-document fixture of the pinned reference's
-- @spec/@ directory, discovered rather than listed so a new fixture is never
-- silently skipped. Valid fixtures parse and re-serialize byte-identically
-- (every spec fixture is canonical); invalid ones (named @*-invalid-*@) are
-- refused with the reference's exact message. Net definitions embedded in
-- the golden traces are admitted and project back to the same value.
module Petrus.Impetus.SpecFixturesSpec (spec) where

import Control.Monad (forM, forM_, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.NetDocument
import Petrus.Impetus.TestSupport
import Petrus.Impetus.WireSupport
import Petrus.Json (Json (..), lookupMember)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (makeRelative, takeFileName, (</>))
import Test.Hspec

-- | The reference's refusal of each negative fixture.
refusals :: [(FilePath, Text)]
refusals =
  [ ("net-definition-v3-invalid-integer.json", "JSON integer 9007199254740992 is outside the inclusive interoperable range [-9007199254740991, 9007199254740991]")
  ,
    ( "net-definition-v3-invalid-utf16-order.json"
    , "invalid Petrus Net-definition v3: 1 validation error for NetDefinitionV3\ndefinition\n  Value error, places must have unique paths sorted by Unicode scalar value [type=value_error, input_value={'name': 'invalid-utf16-o... [], 'completion': None}, input_type=dict]\n    For further information visit https://errors.pydantic.dev/2.13/v/value_error"
    )
  , ("net-document-v1-invalid-foreign-view.json", "view contains foreign definition node 'foreign'")
  , ("net-document-v1-invalid-lineage.json", "lineage.entries[3].marking[0].place names foreign place 'foreign'")
  ]

jsonFiles :: FilePath -> IO [FilePath]
jsonFiles directory = do
  names <- sort <$> listDirectory directory
  fmap concat . forM names $ \name -> do
    let path = directory </> name
    isDirectory <- doesDirectoryExist path
    if isDirectory
      then jsonFiles path
      else pure [path | ".json" `isSuffixOf` name]

data Fixture = Fixture {path :: FilePath, bytes :: BS.ByteString, value :: Json}

spec :: Spec
spec = describe "spec/ fixtures" $ do
  let root = specFile ""
  fixtures <- runIO $ do
    paths <- jsonFiles root
    forM paths $ \path -> do
      bytes <- BS.readFile path
      pure Fixture {path = makeRelative root path, bytes, value = mustJson bytes}
  let formatOf f = lookupMember "format" f.value
      definitions = [f | f <- fixtures, formatOf f == Just (String "petrus-net-definition")]
      documents = [f | f <- fixtures, formatOf f == Just (String "petrus-net-document")]
      traces = [(f, net) | f <- fixtures, Just net@(Object _) <- [lookupMember "net" f.value]]

  it "finds every kind of fixture" $ do
    length definitions `shouldSatisfy` (>= 4)
    length documents `shouldSatisfy` (>= 7)
    length traces `shouldSatisfy` (>= 8)
    let negatives = [takeFileName f.path | f <- definitions <> documents, "-invalid-" `isInfixOf` f.path]
    sort negatives `shouldBe` sort (map fst refusals)

  describe "Net definitions" $
    forM_ definitions $ \f -> it f.path (check parseNetDefinition serializeNetDefinition f)

  describe "Net documents" $
    forM_ documents $ \f -> it f.path $ do
      check parseNetDocument serializeNetDocument f
      unless ("-invalid-" `isInfixOf` f.path) $ do
        document <- expectRight (parseNetDocument f.bytes)
        definition <- expectRight (serializeNetDefinition document.definition)
        -- The identity is the digest of the embedded definition's canonical
        -- bytes, independent of the view and lineage.
        definitionIdentity document `shouldBe` Right (hexDigest definition)
        definitionIdentity document {view = Nothing, lineage = Nothing} `shouldBe` Right (hexDigest definition)

  describe "Net definitions embedded in golden traces" $
    forM_ traces $ \(f, net) -> it (f.path <> "#net") $ do
      document <- expectRight (parseNetDefinitionJson net)
      netDefinitionToJson document `shouldBe` net
      compiled <- expectRight (compileNetDefinition document)
      projectNetDefinition compiled `shouldBe` Right document
  where
    check :: (Show a) => (BS.ByteString -> Either Text a) -> (a -> Either Text BS.ByteString) -> Fixture -> Expectation
    check parse serialize f = case lookup (takeFileName f.path) refusals of
      Just message -> parse f.bytes `shouldFailWith` message
      Nothing -> (parse f.bytes >>= serialize) `shouldBe` Right f.bytes

hexDigest :: BS.ByteString -> Text
hexDigest = T.pack . concatMap (\w -> let h = showHex w "" in if length h == 1 then '0' : h else h) . BS.unpack . SHA256.hash
