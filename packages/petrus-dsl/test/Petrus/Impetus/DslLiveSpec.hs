-- | Live round trips through the pinned reference (not in the reference's
-- suite; the audit's IMP-4).
--
-- Every net the Haskell DSL builds for the differential corpus
-- ("Petrus.Impetus.Dsl.Corpus"), projected and serialized by Haskell as a
-- Net definition and as a Net document, is handed to the reference's own
-- @parse_net_definition@ and @parse_net_document@, which must accept it and
-- serialize it back byte for byte ("Petrus.TestSupport.Reference"). The
-- reference must be available: without it the group fails.
module Petrus.Impetus.DslLiveSpec (spec) where

import Control.Monad (forM)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Dsl.Corpus (corpus)
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.NetDocument (projectNetDocument, serializeNetDocument)
import Petrus.TestSupport.Reference
import Test.Hspec

spec :: Spec
spec = describe "live round trip through the pinned reference" $
  it "accepts and rewrites byte for byte the definition and document of every net the DSL builds" $ do
    let built = [(T.unpack name, b.net) | (name, Right b) <- corpus]
    length built `shouldSatisfy` (>= 20)
    payloads <- fmap concat . forM built $ \(name, net) -> do
      definition <- expectRight (projectNetDefinition net >>= serializeNetDefinition)
      document <- expectRight (projectNetDocument net Nothing Nothing >>= serializeNetDocument)
      pure [(name <> " definition", NetDefinitionSubject, definition), (name <> " document", NetDocumentSubject, document)]
    shouldRoundTripThroughReference payloads

expectRight :: Either Text a -> IO a
expectRight = either (fail . T.unpack) pure
