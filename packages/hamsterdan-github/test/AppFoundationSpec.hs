{-# LANGUAGE OverloadedRecordDot #-}

-- | The port of @tests/unit/github_app/test_app_foundation.py@'s
-- configuration, routing, admission and webhook tests. (The auth and
-- transport tests of that file live in "GitHubSpec".)
module AppFoundationSpec (spec, environment, installationConfig) where

import Control.Exception (try)
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Codec (dump)
import Hamsterdan.GitHub.Config
import Hamsterdan.GitHub.Models (InstallationInventory (..))
import Hamsterdan.GitHub.Routing (InventoryMismatch (..))
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Sqlite qualified as Db
import Hamsterdan.GitHub.Webhooks
import Petrus.Json (Json (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, removeLink, setFileMode)
import Test.Hspec hiding (pending)

-- | A throwaway, multi-line credential shaped like a PEM key; configuration
-- never parses it (the auth tests use a real throwaway key).
testKey :: String
testKey = "-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END PRIVATE KEY-----\n"

installationConfig :: FilePath -> Bool -> IO FilePath
installationConfig path secondAccount = do
  let first = "\n[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\n  \"31:Owner/One\",\n  \"32:Owner/Two\",\n]\n"
      second = "\n\n[[accounts]]\nid = 24\nlogin = \"Other-Owner\"\nrepositories = [\n  \"33:Other-Owner/Three\",\n]\n"
  writeFile path (first <> (if secondAccount then second else ""))
  setFileMode path 0o600
  pure path

environment :: FilePath -> String -> IO (Map String String)
environment directory key = do
  installations <- installationConfig (directory </> "installations.toml") False
  pure $
    Map.fromList
      [ ("HAMSTERDAN_GITHUB_APP_ID", "17")
      , ("HAMSTERDAN_GITHUB_APP_SLUG", "hamsterdan-test")
      , ("HAMSTERDAN_GITHUB_CLIENT_ID", "Iv1.explicit")
      , ("HAMSTERDAN_GITHUB_INSTALLATIONS_FILE", installations)
      , ("HAMSTERDAN_STATE_PATH", directory </> "state.db")
      , ("HAMSTERDAN_GITHUB_PRIVATE_KEY", key)
      , ("HAMSTERDAN_GITHUB_WEBHOOK_SECRET", "hook-secret")
      ]

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "foundation"

configurationFailure :: Map String String -> IO Text
configurationFailure env =
  try (fromEnvironment env) >>= \case
    Left (ConfigurationError message) -> pure message
    Right _ -> expectationFailure "expected a ConfigurationError" >> pure ""

conversation :: [(Text, Json)] -> Observation
conversation changes =
  fromJust . observationFromJson 0 . Object . Map.toList $
    Map.fromList changes
      `Map.union` Map.fromList
        [ ("delivery_id", String "delivery")
        , ("event", String "issue_comment")
        , ("action", String "created")
        , ("installation_id", Int 44)
        , ("account_id", Int 23)
        , ("repository_id", Int 31)
        , ("repository_full_name", String "owner/one")
        , ("pull_request_number", Int 7)
        , ("comment_id", Int 9)
        , ("comment_body", String "  @HaMsTeR-DaN   explain the blockers  ")
        , ("actor_id", Int 5)
        , ("actor_login", String "human")
        , ("actor_type", String "User")
        , ("author_association", String "MEMBER")
        ]

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

admit :: Observation -> Maybe Json
admit = fmap dump . admitConversation "hamster-dan" "hamster-dan[bot]"

signedHeaders :: ByteString -> Text -> Text -> [(Text, Text)]
signedHeaders body event delivery =
  [ ("content-length", T.pack (show (BS.length body)))
  , ("content-type", "application/json")
  , ("x-hub-signature-256", sign "hook-secret" body)
  , ("x-github-delivery", delivery)
  , ("x-github-event", event)
  ]

deliveries :: [Text]
deliveries = ["3f0c1a52-4b7e-4c71-9a10-0000000000" <> T.pack (pad (show n)) | n <- [1 :: Int ..]]
  where
    pad s = replicate (2 - length s) '0' <> s

custodyAt :: FilePath -> IO WebhookCustody
custodyAt path = openCustody path "hook-secret" (defaultCustodyOptions (pure 100))

rejection :: IO a -> IO Text
rejection action =
  try action >>= \case
    Left (WebhookRejected reason) -> pure reason
    Right _ -> expectationFailure "expected a WebhookRejected" >> pure ""

utf8 :: Text -> ByteString
utf8 = TE.encodeUtf8

spec :: Spec
spec = describe "app foundation (test_app_foundation.py)" $ do
  describe "conversation admission" $ do
    it "returns only stripped neutral values" $
      admit (conversation [])
        `shouldBe` Just
          ( Object
              [ ("delivery_id", String "delivery")
              , ("comment_id", Int 9)
              , ("actor_id", Int 5)
              , ("actor_login", String "human")
              , ("association", String "MEMBER")
              , ("text", String "explain the blockers")
              ]
          )
    it "accepts a bare mention as empty text" $
      (admit (conversation [("comment_body", String "@hamster-dan")]) >>= member "text")
        `shouldBe` Just (String "")
    forM_
      [ ("event", String "pull_request")
      , ("action", String "edited")
      , ("actor_login", String "HAMSTER-DAN[BOT]")
      , ("actor_type", String "Bot")
      , ("author_association", String "CONTRIBUTOR")
      , ("comment_id", String "9")
      , ("actor_id", String "5")
      , ("actor_login", Int 5)
      , ("comment_body", String "@hamster-dan-other explain")
      , ("comment_body", String "@hamster-dan\texplain")
      , ("comment_body", String "hello @hamster-dan")
      ]
      $ \change ->
        it ("rejects provider policy failure " <> show change) $
          admit (conversation [change]) `shouldBe` Nothing

  describe "configuration" $ do
    it "preserves multiline credentials and redacts them" $ withTemp $ \directory -> do
      env <- environment directory testKey
      config <- fromEnvironment env
      config.appId `shouldBe` 17
      botLogin config `shouldBe` "hamsterdan-test[bot]"
      [(account.accountId, account.accountLogin) | account <- config.accounts] `shouldBe` [(23, "Owner")]
      (config.accounts !! 0).repositories `shouldBe` [(31, "owner/one"), (32, "owner/two")]
      show config `shouldNotSatisfy` ("hook-secret" `isInfixOf`)
      show config `shouldNotSatisfy` ("PRIVATE KEY" `isInfixOf`)
      (revealSecret config.privateKey, revealSecret config.webhookSecret) `shouldBe` (T.pack testKey, "hook-secret")
      again <- fromEnvironment (Map.insert "GITHUB_APP_ID" "999" env)
      again.appId `shouldBe` 17

    it "accepts multiple installation accounts as one snapshot" $ withTemp $ \directory -> do
      env <- environment directory testKey
      multiple <- installationConfig (directory </> "multiple-installations.toml") True
      config <- fromEnvironment (Map.insert "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE" multiple env)
      map (.accountId) config.accounts `shouldBe` [23, 24]
      (config.accounts !! 1).repositories `shouldBe` [(33, "other-owner/three")]

    forM_
      [ "accounts = ["
      , "unknown = true"
      , "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = []\n"
      , "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\"31:Other/repo\"]\n"
      , "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\"31:Owner/one\"]\n[[accounts]]\nid = 23\nlogin = \"Other\"\nrepositories = [\"32:Other/two\"]\n"
      ]
      $ \content ->
        it ("rejects malformed installation snapshot " <> show content <> " without disclosure") $ withTemp $ \directory -> do
          env <- environment directory testKey
          let path = directory </> "invalid-installations.toml"
          writeFile path (content <> "\n# configuration-leak-canary")
          setFileMode path 0o600
          message <- configurationFailure (Map.insert "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE" path env)
          T.unpack message `shouldNotSatisfy` ("configuration-leak-canary" `isInfixOf`)

    forM_ ["symlink", "writable" :: String] $ \failure ->
      it ("rejects unsafe installation file custody: " <> failure) $ withTemp $ \directory -> do
        env <- environment directory testKey
        let path = env Map.! "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE"
        if failure == "symlink"
          then do
            target <- installationConfig (directory </> "installation-target.toml") False
            removeLink path
            createSymbolicLink target path
          else setFileMode path 0o622
        message <- configurationFailure env
        T.unpack message `shouldSatisfy` ("GitHub installations file" `isInfixOf`)

    forM_ [Nothing, Just "", Just " \n", Just (replicate 65537 'x'), Just "do-not-disclose\x00", Just "do-not-disclose\xdcff"] $ \value ->
      it ("rejects invalid webhook secret " <> take 24 (show value) <> " without disclosure") $ withTemp $ \directory -> do
        env <- environment directory testKey
        let changed = maybe (Map.delete "HAMSTERDAN_GITHUB_WEBHOOK_SECRET") (Map.insert "HAMSTERDAN_GITHUB_WEBHOOK_SECRET") value env
        message <- configurationFailure changed
        T.unpack message `shouldNotSatisfy` ("do-not-disclose" `isInfixOf`)

    forM_ ["HAMSTERDAN_GITHUB_PRIVATE_KEY_FILE", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET_FILE"] $ \name ->
      it ("refuses competing credential file " <> name) $ withTemp $ \directory -> do
        env <- environment directory testKey
        message <- configurationFailure (Map.insert name "/stale/credential" env)
        T.unpack message `shouldSatisfy` ("retired GitHub credential-file" `isInfixOf`)

    it "watches every author by default and narrows casefolded" $ withTemp $ \directory -> do
      env <- environment directory testKey
      config <- fromEnvironment env
      config.watchedAuthors `shouldBe` Set.empty
      narrowed <- fromEnvironment (Map.insert "HAMSTERDAN_WATCH_AUTHORS" " Alice , bob-Dev " env)
      narrowed.watchedAuthors `shouldBe` Set.fromList ["alice", "bob-dev"]

    forM_ ["alice,", "not a login", "@alice", ","] $ \value ->
      it ("rejects malformed watched authors " <> show value) $ withTemp $ \directory -> do
        env <- environment directory testKey
        message <- configurationFailure (Map.insert "HAMSTERDAN_WATCH_AUTHORS" value env)
        T.unpack message `shouldSatisfy` ("watched authors" `isInfixOf`)

  describe "routing" $ do
    it "covers the lifecycle and keeps malformed or unknown events inert" $ withTemp $ \directory -> do
      routes <- Routing.openRegistry (directory </> "routing.db") [AccountConfig 23 "Owner" [(31, "owner/one"), (32, "owner/two")]]
      let installation action i a = Routing.installation routes (String action) (Int i) (Int a)
          repositories action i a items = Routing.repositories routes (String action) (Int i) (Int a) [(Int r, String n) | (r, n) <- items]
          route i r = Routing.route routes i r
      installation "created" 44 23 `shouldReturn` True
      repositories "added" 44 23 [(31, "Owner/One"), (32, "owner/two")] `shouldReturn` True
      (route 44 31 >>= (`shouldSatisfy` isJust)) >> (route 44 32 >>= (`shouldSatisfy` isJust))
      repositories "removed" 44 23 [(31, "owner/one")] `shouldReturn` True
      route 44 31 >>= (`shouldSatisfy` isNothing)
      installation "suspend" 44 23 `shouldReturn` True
      route 44 32 >>= (`shouldSatisfy` isNothing)
      installation "unsuspend" 44 23 `shouldReturn` True
      route 44 32 >>= (`shouldSatisfy` isJust)
      installation "new_permissions_accepted" 44 23 `shouldReturn` True
      installation "created" 0 23 `shouldReturn` False
      installation "created" 45 999 `shouldReturn` False
      repositories "added" 999 23 [(31, "owner/one")] `shouldReturn` False
      repositories "added" 44 23 [(-1, "bad")] `shouldReturn` False
      installation "deleted" 44 23 `shouldReturn` True
      route 44 32 >>= (`shouldSatisfy` isNothing)
      Routing.closeRegistry routes

    it "reconciles multiple installations atomically and fences removed routes" $ withTemp $ \directory -> do
      let path = directory </> "multiple-routing.db"
          firstInventory = InstallationInventory 44 23 [(31, "owner/one")]
          inventory = [firstInventory, InstallationInventory 45 24 [(33, "other-owner/three")]]
      routes <- Routing.openRegistry path [AccountConfig 23 "Owner" [(31, "owner/one")], AccountConfig 24 "Other-Owner" [(33, "other-owner/three")]]
      Routing.reconcile routes inventory `shouldReturn` 2
      Routing.route routes 44 31 >>= (`shouldSatisfy` isJust)
      Routing.route routes 45 33 >>= (`shouldSatisfy` isJust)
      Routing.installation routes (String "deleted") (Int 45) (Int 23) `shouldReturn` False
      Routing.installation routes (String "created") (Int 45) (Int 23) `shouldReturn` False
      Routing.route routes 45 33 >>= (`shouldSatisfy` isJust)
      outcome <- try (Routing.reconcile routes [firstInventory, InstallationInventory 45 24 []])
      case outcome of
        Left (InventoryMismatch message) -> T.unpack message `shouldSatisfy` ("every configured repository" `isInfixOf`)
        Right _ -> expectationFailure "expected a ValueError"
      Routing.route routes 44 31 >>= (`shouldSatisfy` isJust)
      Routing.route routes 45 33 >>= (`shouldSatisfy` isJust)
      Routing.closeRegistry routes
      reduced <- Routing.openRegistry path [AccountConfig 23 "Owner" [(31, "owner/one")]]
      Routing.reconcile reduced [firstInventory] `shouldReturn` 1
      Routing.route reduced 44 31 >>= (`shouldSatisfy` isJust)
      Routing.route reduced 45 33 >>= (`shouldSatisfy` isNothing)
      Routing.closeRegistry reduced

  describe "webhooks" $ do
    it "verifies before parse or persistence and records no rejection" $ withTemp $ \directory -> do
      custody <- custodyAt (directory </> "webhooks.db")
      let body = "not json"
          forged = [if name == "x-hub-signature-256" then (name, "sha256=" <> T.replicate 64 "0") else (name, value) | (name, value) <- signedHeaders body "ping" (deliveries !! 0)]
      rejection (receive custody forged body) >>= (`shouldSatisfy` T.isInfixOf "verification")
      status custody (deliveries !! 0) `shouldReturn` Nothing
      rejection (receive custody (signedHeaders body "ping" (deliveries !! 1)) body) >>= (`shouldSatisfy` T.isInfixOf "envelope")
      status custody (deliveries !! 1) `shouldReturn` Nothing
      closeCustody custody

    forM_ ["content-type", "length", "sha1", "duplicate", "oversized" :: String] $ \mutation ->
      it ("enforces the exact transport envelope: " <> mutation) $ withTemp $ \directory -> do
        custody <- openCustody (directory </> "w.db") "hook-secret" (defaultCustodyOptions (pure 100)) {maximumBodyBytes = 20}
        let body = if mutation == "oversized" then "{" <> BS.replicate 20 32 <> "}" else "{}"
            headers = signedHeaders "{}" "ping" (deliveries !! 0)
            replace name value = map (\(n, v) -> if n == name then (n, value) else (n, v))
            mutated = case mutation of
              "content-type" -> replace "content-type" "application/json; charset=utf-8" headers
              "length" -> replace "content-length" "3" headers
              "sha1" -> replace "x-hub-signature-256" ("sha1=" <> T.replicate 40 "0") headers
              "duplicate" -> headers <> [("Content-Length", "2")]
              _ -> signedHeaders body "ping" (deliveries !! 0)
        _ <- rejection (receive custody mutated body)
        closeCustody custody

    it "dedupes, observes issue_comment and never stores the payload" $ withTemp $ \directory -> do
      custody <- custodyAt (directory </> "w.db")
      let body =
            utf8
              "{\"action\": \"created\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \
              \\"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"issue\": {\"number\": 7, \"pull_request\": {}}, \
              \\"comment\": {\"id\": 8, \"body\": \"secret payload text\", \"author_association\": \"MEMBER\", \
              \\"user\": {\"id\": 9, \"login\": \"alice\", \"type\": \"User\"}}}"
          headers = signedHeaders body "issue_comment" (deliveries !! 2)
      receipt <- receive custody headers body
      duplicate <- receive custody headers body
      let item = fromJust receipt.observation
      (item.pullRequestNumber, item.commentId, item.actorLogin) `shouldBe` (Int 7, Int 8, String "alice")
      duplicate.disposition `shouldBe` Duplicate
      closeCustody custody
      db <- Db.open (T.pack (directory </> "w.db"))
      rows <- Db.query db "select observation from inbox" []
      Db.close db
      show rows `shouldSatisfy` ("secret payload text" `isInfixOf`)
      show rows `shouldNotSatisfy` ("x-hub-signature" `isInfixOf`)

    it "delays retries and eventually parks the delivery" $ withTemp $ \directory -> do
      now <- newIORef (100 :: Double)
      custody <- openCustody (directory </> "w.db") "hook-secret" (defaultCustodyOptions (readIORef now))
      let delivery = deliveries !! 3
      _ <- receive custody (signedHeaders "{}" "ping" delivery) "{}"
      forM_ [1 .. maxDeliveryAttempts] $ \attempt -> do
        items <- pending custody 100 Nothing
        map (.attempts) items `shouldBe` [attempt - 1]
        retry custody delivery (ErrorClass "RuntimeError")
        pending custody 100 Nothing `shouldReturn` []
        when (attempt < maxDeliveryAttempts) $
          modifyIORef' now (+ fromIntegral (min (2 ^ (attempt - 1) :: Int) 300))
      status custody delivery `shouldReturn` Just "failed"
      counts custody `shouldReturn` Map.fromList [("failed", 1)]
      parked <- failures custody 100
      [(f.deliveryId, f.event, f.attempts, f.errorClass, f.reason) | f <- parked]
        `shouldBe` [(delivery, "ping", maxDeliveryAttempts, Just "RuntimeError", Just "attempts exhausted")]
      requeue custody "not-a-uuid" `shouldReturn` False
      requeue custody delivery `shouldReturn` True
      requeue custody delivery `shouldReturn` False
      map (.attempts) <$> pending custody 100 Nothing `shouldReturn` [0]
      closeCustody custody

    it "migrates an existing inbox for the retry schedule" $ withTemp $ \directory -> do
      let path = directory </> "legacy.db"
      legacy <- Db.open (T.pack path)
      Db.script
        legacy
        "CREATE TABLE inbox (delivery_id TEXT PRIMARY KEY,event TEXT NOT NULL,observation TEXT NOT NULL,\
        \status TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,reason TEXT,error_class TEXT)"
      Db.close legacy
      custody <- custodyAt path
      closeCustody custody
      migrated <- Db.open (T.pack path)
      columns <- Db.query migrated "PRAGMA table_info(inbox)" []
      Db.close migrated
      [name | (_ : Db.SQLText name : _) <- columns] `shouldContain` ["next_attempt_at"]

    it "admits an installation's initial repositories into the routing portfolio" $ withTemp $ \directory -> do
      routes <- Routing.openRegistry (directory </> "routing.db") [AccountConfig 23 "Owner" [(31, "owner/one"), (32, "owner/two")]]
      custody <- openCustody (directory </> "w.db") "hook-secret" (defaultCustodyOptions (pure 100)) {registry = Just routes}
      let body =
            utf8
              "{\"action\": \"created\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \
              \\"repositories\": [{\"id\": 31, \"full_name\": \"owner/one\"}, {\"id\": 99, \"full_name\": \"owner/no\"}]}"
      _ <- receive custody (signedHeaders body "installation" (deliveries !! 4)) body
      Routing.route routes 44 31 >>= (`shouldSatisfy` isJust)
      Routing.route routes 44 99 >>= (`shouldSatisfy` isNothing)
      Set.fromList ["pull_request_review_comment", "pull_request_review_thread", "check_run", "check_suite"]
        `shouldSatisfy` (`Set.isSubsetOf` supportedEvents)
      closeCustody custody
      Routing.closeRegistry routes

    forM_
      [ ("pull_request", "pull_request")
      , ("pull_request_review", "pull_request")
      , ("pull_request_review_comment", "pull_request")
      , ("pull_request_review_thread", "pull_request")
      , ("workflow_run", "workflow_run")
      , ("check_run", "check_run")
      , ("check_suite", "check_suite")
      ]
      $ \(event, container) ->
        it ("extracts the exact pull number from " <> T.unpack event) $ withTemp $ \directory -> do
          custody <- custodyAt (directory </> T.unpack event <> ".db")
          let inner = if container == "pull_request" then "{\"number\": 7}" else "{\"pull_requests\": [{\"number\": 7}]}"
              body =
                utf8 $
                  "{\"action\": \"completed\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \
                  \\"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \""
                    <> container
                    <> "\": "
                    <> inner
                    <> "}"
          receipt <- receive custody (signedHeaders body event (deliveries !! 5)) body
          ((.pullRequestNumber) <$> receipt.observation) `shouldBe` Just (Int 7)
          closeCustody custody
