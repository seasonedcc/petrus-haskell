{-# LANGUAGE AllowAmbiguousTypes #-}

-- | @tests/unit/host/test_host_architecture.py@: credential isolation at the
-- host-agent contract. Upstream reads the dataclass fields; here the field
-- set is every member the request codecs dump (they dump every field, in
-- declaration order, under its Python name).
module ArchitectureSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol (CodingRequest, ConversationRequest, ReviewRequest)
import Hamsterdan.Contracts.Codec (Contract, dump, validate)
import Petrus.Json (Json (..))
import Test.Hspec

spec :: Spec
spec = describe "test_host_architecture" $
  it "test_agent_requests_are_credential_free" $ do
    review <- fieldsOf @ReviewRequest (common <> [("diff_path", String "diff")])
    conversation <-
      fieldsOf @ConversationRequest
        ( common
            <> [ ("comment_context", Object [])
               , ("actor", Object [])
               , ("dashboard", Object [])
               , ("gates", Array [])
               , ("findings", Array [])
               , ("allowed_intents", Array [])
               ]
        )
    coding <- fieldsOf @CodingRequest (("kind", String "repair") : ("ref", String "feature") : common)
    let requestFields = Set.fromList (map T.toCaseFold (review <> conversation <> coding))
    Set.size requestFields `shouldSatisfy` (> 10)
    mapM_
      (\forbidden -> Set.member forbidden requestFields `shouldBe` False)
      ["github_token", "installation_token", "private_key", "credential"]
  where
    common =
      [ ("repository", String "owner/repo")
      , ("pull_request", Int 7)
      , ("epoch", Int 1)
      , ("head", String "a")
      , ("base", String "b")
      ]

fieldsOf :: forall a. (Contract a) => [(Text, Json)] -> IO [Text]
fieldsOf members = case validate @a (Object members) of
  Left problem -> fail (show problem)
  Right value -> case dump value of
    Object dumped -> pure (map fst dumped)
    other -> fail (show other)
