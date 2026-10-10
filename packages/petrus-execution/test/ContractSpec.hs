-- | Value-level contract: ports of the validation halves of
-- @test_execution_contract.py@ and @test_private_execution_substrate.py@.
module ContractSpec (spec) where

import Data.ByteString qualified as B
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Internal.Common
import Test.Hspec

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

leftMessage :: Either ExecutionError a -> Maybe (ErrorKind, Text)
leftMessage = \case
  Left err -> Just (errorKind err, errorMessage err)
  Right _ -> Nothing

matches :: Text -> Either ExecutionError a -> Bool
matches fragment = \case
  Left err -> fragment `T.isInfixOf` errorMessage err
  Right _ -> False

commandRequires :: Maybe (ErrorKind, Text)
commandRequires =
  Just
    ( ValueError
    , "command requires argv, a relative cwd, a positive finite timeout, and an output limit between 0 and 1000000 bytes"
    )

provenance :: ExecutionProvenance
provenance = rightOr (mkExecutionProvenance "operation" "provider" "lease")

reference :: PrivateFileRef
reference = rightOr (mkPrivateFileRef "file" "auth.json" "attachment" provenance)

spec :: Spec
spec = do
  describe "test_command_is_snapshotted_finite_and_uniformly_bounded" $ do
    it "keeps argv and normalizes cwd like pathlib" $ do
      let command = rightOr (mkCommand (commandSpec ["printf", "safe"]) {specCwd = "subdirectory"})
      commandArgv command `shouldBe` ["printf", "safe"]
      commandCwd command `shouldBe` "subdirectory"
      commandCwd (rightOr (mkCommand (commandSpec ["true"]) {specCwd = "./a//b/./"})) `shouldBe` "a/b"
      commandCwd (rightOr (mkCommand (commandSpec ["true"]) {specCwd = ""})) `shouldBe` "."
    it "rejects invalid capability keys" $ do
      leftMessage (mkEnvironmentSpec Nothing [Capability " x"])
        `shouldBe` Just (ValueError, "environment capability must be a non-empty trimmed string without control characters")
      leftMessage (mkEnvironmentSpec (Just "") [])
        `shouldBe` Just (ValueError, "environment image must be a non-empty trimmed string without control characters")
    it "rejects non-finite, non-positive timeouts and out-of-range output limits" $ do
      let bad s = leftMessage (mkCommand s) `shouldBe` commandRequires
      bad (commandSpec ["true"]) {specTimeout = Just (FractionalSeconds (1 / 0))}
      bad (commandSpec ["true"]) {specTimeout = Just (FractionalSeconds (0 / 0))}
      bad (commandSpec ["true"]) {specTimeout = Just 0}
      bad (commandSpec ["true"]) {specTimeout = Just (-1)}
      bad (commandSpec ["true"]) {specOutputLimit = maxCommandOutputBytes + 1}
      bad (commandSpec ["true"]) {specOutputLimit = -1}
      bad (commandSpec [])
      bad (commandSpec ["true"]) {specCwd = "/absolute"}
      mkCommand (commandSpec ["true"]) {specTimeout = Just 0.5, specOutputLimit = 0} `shouldSatisfy` not . isLeft

  describe "test_command_snapshots_and_validates_environment" $ do
    it "snapshots the environment with dict semantics" $ do
      let command = rightOr (mkCommand (commandSpec ["env"]) {specEnvironment = [("A", "1"), ("B", "2"), ("A", "3")]})
      commandEnvironment command `shouldBe` [("A", "3"), ("B", "2")]
    it "rejects NUL bytes and invalid names" $ do
      let bad s = leftMessage (mkCommand s) `shouldBe` Just (ValueError, "invalid command or environment value")
      bad (commandSpec ["true"]) {specEnvironment = [("BAD-NAME", "x")]}
      bad (commandSpec ["true"]) {specEnvironment = [("1A", "x")]}
      bad (commandSpec ["true"]) {specEnvironment = [("A", "x\NULy")]}
      bad (commandSpec ["tr\NULue"])

  describe "test_private_file_values_are_bounded_path_free_and_secret_safe" $ do
    let value = rightOr (mkPrivateFile "auth.json" "canary-private-content")
    it "binds private roots and hides secrets" $ do
      let command = rightOr (mkCommand (commandSpec ["codex", "status"]) {specPrivateRoots = [("CODEX_HOME", reference)]})
          cleaned = rightOr (mkPrivateFileCleanupResult "attachment" provenance Clean 1 "" False)
      commandPrivateRoots command `shouldBe` [("CODEX_HOME", reference)]
      privateCleanupVerified cleaned `shouldBe` True
      privateCleanupPhysicalErasureGuaranteed cleaned `shouldBe` False
      show value `shouldNotSatisfy` T.isInfixOf "canary-private-content" . T.pack
      show command `shouldNotSatisfy` T.isInfixOf "CODEX_HOME" . T.pack
    it "rejects unsafe private file names" $
      mapM_
        ( \name ->
            leftMessage (mkPrivateFile name "")
              `shouldBe` Just (ValueError, "private file name must be one bounded safe ASCII filename component")
        )
        ["", ".", "..", "../auth.json", "auth/json", "auth\\json", " auth", "\233", T.replicate 65 "a"]
    it "bounds private file content and accepts the maximum name" $ do
      leftMessage (mkPrivateFile "auth.json" (B.replicate (maxPrivateFileBytes + 1) 120))
        `shouldBe` Just (ValueError, "private file content exceeds the 1000000-byte bound")
      fmap privateFileContent (mkPrivateFile (T.replicate maxPrivateFileNameBytes "a") "") `shouldBe` Right ""
    it "rejects bad private root bindings" $ do
      let bad s = matches "private root" (mkCommand s) `shouldBe` True
      bad (commandSpec ["true"]) {specEnvironment = [("CODEX_HOME", "safe")], specPrivateRoots = [("CODEX_HOME", reference)]}
      bad (commandSpec ["true"]) {specPrivateRoots = [("BAD-NAME", reference)]}
      bad
        (commandSpec ["true"])
          { specPrivateRoots = [("ROOT_" <> T.pack (show i), reference) | i <- [0 .. maxPrivateFilesPerAttachment]]
          }
    it "rejects negative cleanup counts" $
      leftMessage (mkPrivateFileCleanupResult "attachment" provenance Clean (-1) "" False)
        `shouldBe` Just (ValueError, "private cleanup removed count must be a non-negative integer")
    it "keeps the total bound above the per-file bound" $
      maxPrivateFileTotalBytes `shouldSatisfy` (>= maxPrivateFileBytes)

  describe "value invariants" $ do
    it "validates identity text like _text" $ do
      leftMessage (mkLeaseIdentity "op" "provider" " lease")
        `shouldBe` Just (ValueError, "lease lease_id must be a non-empty trimmed string without control characters")
      leftMessage (mkLeaseIdentity "op\n" "provider" "lease")
        `shouldBe` Just (ValueError, "lease operation_id must be a non-empty trimmed string without control characters")
      leftMessage (mkExecutionAttachment "" (lease Ready) "digest" "/w")
        `shouldBe` Just (ValueError, "attachment_id must be a non-empty trimmed string without control characters")
    it "bounds command results" $
      leftMessage (mkCommandResult 0 (B.replicate 600000 1) (B.replicate 400001 1) False False False provenance)
        `shouldBe` Just (ValueError, "command result exceeds the supported output bound")
    it "makes reconciliation shapes explicit" $ do
      reconcileLease (terminalResult (lease Terminal) "") `shouldBe` Just (lease Terminal)
      reconcileLease (retryableResult "no lease") `shouldBe` Nothing
      reconcileClassification (uncertainResult Nothing "x") `shouldBe` ReconcileUncertain
    it "derives cleanup verification from the disposition" $ do
      let identity = leaseIdentity (lease Ready)
      map (cleanupVerified . (\d -> CleanupResult identity d "")) [Clean, NotCreated, Unverified]
        `shouldBe` [True, True, False]

  describe "provider helpers" $ do
    it "fingerprints specs like json.dumps(sort_keys=True, separators=(',', ':'))" $ do
      -- sha256(b'{"image":null}') and sha256(b'{"image":"caf\\u00e9"}')
      specFingerprint defaultSpec `shouldBe` "06c466547f7f493ff9a79fc9966f7615330430acd2b914bb80ad55e0c1aac8fd"
      specFingerprint (rightOr (mkEnvironmentSpec (Just "caf\233") []))
        `shouldBe` "2628d4659913b96b8578e5f5938414b2f3a2afe03326ad053e4b148048804c30"
    it "validates operation ids" $ do
      checkOperationId "a" `shouldReturn` ()
      checkOperationId (T.replicate 128 "a") `shouldReturn` ()
      mapM_
        (\bad -> checkOperationId bad `shouldThrow` (== valueError "operation id must be a safe non-empty provider label"))
        ["", "-a", T.replicate 129 "a", "a b", "a/b", "\233"]
    it "resolves guest cwd lexically and never above the workspace" $ do
      checkedGuestCwd "/workspace" "." `shouldReturn` "/workspace"
      checkedGuestCwd "/workspace" "a/../b" `shouldReturn` "/workspace/b"
      checkedGuestCwd "/workspace" "../workspace" `shouldThrow` (== valueError "command cwd escapes the workspace")
      checkedGuestCwd "/workspace" "a/../../x" `shouldThrow` (== valueError "command cwd escapes the workspace")
      checkedGuestCwd "relative" "." `shouldThrow` (== valueError "command cwd escapes the workspace")
  where
    lease state = rightOr (mkEnvironmentLease "op" "provider" "lease" (Set.fromList [capWorkspace]) state)
