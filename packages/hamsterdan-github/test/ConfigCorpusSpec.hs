{-# LANGUAGE OverloadedRecordDot #-}

-- | Replays @test/corpus/config.jsonl@ (scripts/gen_config_corpus.py):
-- installations files through 'installationAccounts' and whole host
-- environments through 'fromEnvironment'.
module ConfigCorpusSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Corpus
import Hamsterdan.GitHub.Config
import Petrus.Json (Json (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "configuration corpus" $ do
  rows <- runIO (readCorpus "config.jsonl")
  let byKind kind = filter (\row -> field "kind" row == String kind) rows
  it ("installations files reproduce every snapshot and message (" <> show (length (byKind "installations")) <> " cases)") $ do
    mismatches <- newIORef []
    forM_ (zip [0 :: Int ..] (byKind "installations")) $ \(index, row) -> do
      actual <- withSystemTempDirectory "installations" $ \directory -> do
        let path = directory </> "installations.toml"
        BS.writeFile path (decode64 (field "raw" row))
        setFileMode path 0o600
        outcome <- try (installationAccounts path)
        pure $ case outcome of
          Left (ConfigurationError message) -> Object [("error", String message)]
          Right accounts -> Object [("accounts", accountsJson accounts)]
      checkJson mismatches ("installations #" <> show index <> " " <> show (decode64 (field "raw" row))) (expected row) actual
    readIORef mismatches >>= expectNone
  it ("host environments reproduce every configuration and message (" <> show (length (byKind "environment")) <> " cases)") $ do
    mismatches <- newIORef []
    forM_ (zip [0 :: Int ..] (byKind "environment")) $ \(index, row) -> do
      actual <- withSystemTempDirectory "environment" $ \directory -> do
        let path = directory </> "installations.toml"
            wide = directory </> "wide.toml"
            link = directory </> "link.toml"
        BS.writeFile path (decode64 (field "installations" row))
        setFileMode path 0o600
        BS.writeFile wide "[[accounts]]\nid = 23\nlogin = \"Owner\"\nrepositories = [\"31:Owner/One\", \"32:Owner/Two\"]\n"
        setFileMode wide 0o664
        createSymbolicLink path link
        let substitute =
              T.replace "{installations}" (T.pack path)
                . T.replace "{directory}" (T.pack directory)
                . T.replace "{wide}" (T.pack wide)
                . T.replace "{symlink}" (T.pack link)
                . expand
            environment = case field "environment" row of
              Object members -> Map.fromList [(T.unpack name, T.unpack (substitute (textOf value))) | (name, value) <- members]
              other -> error ("corpus: environment " <> show other)
        outcome <- try (fromEnvironment environment)
        pure $ case outcome of
          Left (ConfigurationError message) -> Object [("error", String message)]
          Right config ->
            Object
              [ ( "config"
                , Object
                    [ ("app_id", Int config.appId)
                    , ("app_slug", String config.appSlug)
                    , ("bot_login", String (botLogin config))
                    , ("client_id", String config.clientId)
                    , ("accounts", accountsJson config.accounts)
                    , ("state_path", String (T.pack config.statePath))
                    , ("watched_authors", Array (map String (Set.toAscList config.watchedAuthors)))
                    , ("private_key_matches", Bool (Just (T.unpack (revealSecret config.privateKey)) == Map.lookup "HAMSTERDAN_GITHUB_PRIVATE_KEY" environment))
                    , ("webhook_secret_matches", Bool (Just (T.unpack (revealSecret config.webhookSecret)) == Map.lookup "HAMSTERDAN_GITHUB_WEBHOOK_SECRET" environment))
                    ]
                )
              ]
      checkJson mismatches ("environment #" <> show index <> " " <> T.unpack (canonical (field "environment" row))) (expected row) actual
    readIORef mismatches >>= expectNone

expected :: Json -> Json
expected row = Object [(key, value) | key <- ["accounts", "config", "error"], Just value <- [member key row]]

decode64 :: Json -> BS.ByteString
decode64 = either error id . B64.decode . TE.encodeUtf8 . textOf

-- | @{repeat:c:n}@ spells @c * n@.
expand :: Text -> Text
expand value = case T.stripPrefix "{repeat:" value >>= T.stripSuffix "}" of
  Just inner | Just (c, rest) <- T.uncons inner, Just count <- T.stripPrefix ":" rest -> T.replicate (read (T.unpack count)) (T.singleton c)
  _ -> value

accountsJson :: [AccountConfig] -> Json
accountsJson accounts =
  Array
    [ Array [Int a.accountId, String a.accountLogin, Array [Array [Int i, String n] | (i, n) <- a.repositories]]
    | a <- accounts
    ]
