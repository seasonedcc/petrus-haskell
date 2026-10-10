-- | @tests/unit/host/test_binding.py@ (state ownership; the inactive
-- adapter cases live in "ApplicationSpec").
module BindingSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Hamsterdan.Host.Binding
import Petrus.Json (Json (..), parseJson, pythonLoads)
import System.Directory (createDirectory, createDirectoryIfMissing, createDirectoryLink, createFileLink)
import System.FilePath ((</>))
import Test.Hspec
import TestSupport

instance' :: Json
instance' = String "github:44:31:pr:7"

spec :: Spec
spec = describe "test_binding" $ do
  it "test_new_bindings_are_always_explicit_v5_and_identity_mismatches_fail_closed" . withTempRoot $ \tmp -> do
    let root = tmp </> "application"
    _ <- ensureInstanceBinding root "github:44:31:pr:7" "owner/repo" 7
    binding <- readInstanceBinding (root </> "binding.json")
    binding.topology `shouldBe` V5
    binding.legacy `shouldBe` False
    bytes <- BS.readFile (root </> "binding.json")
    bytes `shouldBe` "{\"instance_id\":\"github:44:31:pr:7\",\"pull_request\":7,\"repository\":\"owner/repo\",\"topology\":\"v5\"}"
    parseJson pythonLoads bytes
      `shouldBe` Right
        (Object [("instance_id", instance'), ("pull_request", Int 7), ("repository", String "owner/repo"), ("topology", String "v5")])
    ensureInstanceBinding root "github:44:31:pr:7" "owner/other" 7
      `shouldThrow` runtimeError "different PR Instance or topology"

  forM_ [(False, "unlabeled"), (True, "production")] $ \(explicit, label) ->
    it ("test_former_topology_binding_fails_closed_without_mutation[" <> label <> "]") . withTempRoot $ \tmp -> do
      let root = tmp </> "application"
      createDirectory root
      -- @json.dumps(payload)@ in insertion order.
      let encoded =
            "{\"instance_id\": \"github:44:31:pr:7\", \"repository\": \"owner/repo\", \"pull_request\": 7"
              <> (if explicit then ", \"topology\": \"production\"}" else "}")
      BS.writeFile (root </> "binding.json") encoded
      BS.writeFile (root </> "history.jsonl") "former topology history"
      ensureInstanceBinding root "github:44:31:pr:7" "owner/repo" 7
        `shouldThrow` runtimeError "different PR Instance or topology"
      BS.readFile (root </> "binding.json") `shouldReturn` encoded
      BS.readFile (root </> "history.jsonl") `shouldReturn` "former topology history"

  it "test_preflight_accepts_only_v5_state" . withTempRoot $ \tmp -> do
    let v5 = tmp </> "applications/44/31/8"
    _ <- ensureInstanceBinding v5 "github:44:31:pr:8" "owner/repo" 8
    BS.writeFile (v5 </> "history.jsonl") "v5"
    preflightV5State tmp
    let former = tmp </> "applications/44/31/7"
    createDirectory former
    BS.writeFile
      (former </> "binding.json")
      "{\"instance_id\": \"github:44:31:pr:7\", \"repository\": \"owner/repo\", \"pull_request\": 7, \"topology\": \"production\"}"
    BS.writeFile (former </> "history.jsonl") "production"
    preflightV5State tmp `shouldThrow` runtimeError "not compatible with the V5 readiness topology"

  it "test_preflight_rejects_unbound_history_and_symlinked_state_ancestry" . withTempRoot $ \tmp -> do
    let unbound = tmp </> "unbound/applications/44/31/7"
    createDirectoryIfMissing True unbound
    BS.writeFile (unbound </> "history.jsonl") "history"
    preflightV5State (tmp </> "unbound") `shouldThrow` runtimeError "binding is unreadable or malformed"

    let outside = tmp </> "outside/31/7"
    _ <- ensureInstanceBinding outside "github:44:31:pr:7" "owner/repo" 7
    BS.writeFile (outside </> "history.jsonl") "history"
    let applications = tmp </> "linked/applications"
    createDirectoryIfMissing True applications
    createDirectoryLink (tmp </> "outside") (applications </> "44")
    preflightV5State (tmp </> "linked") `shouldThrow` runtimeError "state root is malformed"

    let broken = tmp </> "broken"
    createDirectory broken
    createDirectoryLink (tmp </> "missing") (broken </> "applications")
    preflightV5State broken `shouldThrow` runtimeError "application state root is malformed"

    let emptyOutside = tmp </> "empty-outside"
    createDirectory emptyOutside
    let emptyApplications = tmp </> "empty-linked/applications"
    createDirectoryIfMissing True emptyApplications
    createDirectoryLink emptyOutside (emptyApplications </> "44")
    ensureInstanceBinding (emptyApplications </> "44/31/7") "github:44:31:pr:7" "owner/repo" 7
      `shouldThrow` runtimeError "state root is malformed"

    let symlinkedHistory = tmp </> "symlinked-history/applications/44/31/7"
    _ <- ensureInstanceBinding symlinkedHistory "github:44:31:pr:7" "owner/repo" 7
    let target = tmp </> "history-target"
    BS.writeFile target "history"
    createFileLink target (symlinkedHistory </> "history.jsonl")
    preflightV5State (tmp </> "symlinked-history") `shouldThrow` runtimeError "History is unreadable or malformed"
