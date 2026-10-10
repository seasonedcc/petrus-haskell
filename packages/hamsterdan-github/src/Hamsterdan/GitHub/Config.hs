{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}

-- | Strict, single-registration GitHub App host configuration
-- (@github_app/config.py@).
--
-- Every failure is a 'ConfigurationError' whose message never includes a
-- secret or any part of the installations file.
module Hamsterdan.GitHub.Config
  ( ConfigurationError (..)
  , AccountConfig (..)
  , HostConfig (..)
  , Secret
  , revealSecret
  , secret
  , botLogin
  , fromEnvironment
  , installationAccounts
  , parseInstallations
  , readBoundedFile
  , maxSecretBytes
  , normalizeStatePath
  ) where

import Control.Exception (Exception, IOException, bracket, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Python (casefold, isAscii, isAsciiDecimal, isPrintable, strip)
import System.Posix.Files qualified as Posix
import System.Posix.IO qualified as PosixIO
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types (FileMode)
import Toml qualified
import Toml.Semantics qualified as TomlS

-- | A configuration failure that never includes a secret value.
newtype ConfigurationError = ConfigurationError Text
  deriving stock (Eq, Show)

instance Exception ConfigurationError

-- | A credential whose 'Show' instance is always redacted.
newtype Secret = Secret Text
  deriving stock (Eq)

instance Show Secret where
  show _ = "<redacted>"

revealSecret :: Secret -> Text
revealSecret (Secret value) = value

-- | Wrap a credential (for tests and tools; the host reads them with
-- 'fromEnvironment').
secret :: Text -> Secret
secret = Secret

-- | @MAX_SECRET_BYTES@.
maxSecretBytes :: Int
maxSecretBytes = 64 * 1024

data AccountConfig = AccountConfig
  { accountId :: Integer
  , accountLogin :: Text
  , repositories :: [(Integer, Text)]
  -- ^ Sorted @(id, casefolded full name)@ pairs.
  }
  deriving stock (Eq, Show)

-- | Immutable host-owned configuration; its credentials 'Show' redacted.
data HostConfig = HostConfig
  { appId :: Integer
  , appSlug :: Text
  -- ^ Casefolded.
  , clientId :: Text
  , accounts :: [AccountConfig]
  , statePath :: FilePath
  , watchedAuthors :: Set Text
  , privateKey :: Secret
  , webhookSecret :: Secret
  }
  deriving stock (Eq, Show)

-- | @HostConfig.bot_login@.
botLogin :: HostConfig -> Text
botLogin config = config.appSlug <> "[bot]"

failWith :: Text -> Either ConfigurationError a
failWith = Left . ConfigurationError

positiveDecimal :: Maybe Text -> Text -> Either ConfigurationError Integer
positiveDecimal value label = case value of
  Just text
    | isAsciiDecimal text
    , not (T.isPrefixOf "0" text)
    , n <- read (T.unpack text)
    , n > 0 ->
        Right n
  _ -> failWith (label <> " is missing or malformed")

identifier :: Maybe Text -> Text -> Either ConfigurationError Text
identifier value label = case value of
  Just text | T.length text >= 1, T.length text <= 128, isAscii text, isPrintable text -> Right text
  _ -> failWith (label <> " is missing or malformed")

slug :: Maybe Text -> Either ConfigurationError Text
slug value =
  let folded = maybe "" casefold value
   in if T.length folded < 1
        || T.length folded > 100
        || not (isAscii folded)
        || T.any (\c -> not (isAsciiAlnum c || c == '-')) folded
        || T.isPrefixOf "-" folded
        || T.isSuffixOf "-" folded
        then failWith "App slug is missing or malformed"
        else Right folded

isAsciiAlnum :: Char -> Bool
isAsciiAlnum c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

-- | @[A-Za-z0-9-]{1,39}@.
accountLoginShape :: Text -> Bool
accountLoginShape text = T.length text >= 1 && T.length text <= 39 && T.all (\c -> isAsciiAlnum c || c == '-') text

watchedAuthorsOf :: Maybe Text -> Either ConfigurationError (Set Text)
watchedAuthorsOf = \case
  Nothing -> Right Set.empty
  Just value
    | T.null (strip value) -> Right Set.empty
    | otherwise ->
        let logins = Set.fromList (map (casefold . strip) (T.splitOn "," value))
         in if all accountLoginShape (Set.toList logins)
              then Right logins
              else failWith "watched authors are malformed"

-- | A credential from the environment. Environment strings may carry lone
-- surrogates (undecodable bytes); CPython reports them as invalid text.
credential :: Maybe String -> Text -> Either ConfigurationError Secret
credential value label = case value of
  Nothing -> malformed
  Just raw
    | null raw -> malformed
    | all isSpaceChar raw -> malformed
    | '\0' `elem` raw -> malformed
    | any isSurrogate raw -> failWith (label <> " is not valid text")
    | BS.length (TE.encodeUtf8 (T.pack raw)) > maxSecretBytes -> failWith (label <> " size is not admitted")
    | otherwise -> Right (Secret (T.pack raw))
  where
    malformed = failWith (label <> " is missing or malformed")
    isSurrogate c = c >= '\xD800' && c <= '\xDFFF'
    isSpaceChar c = T.null (strip (T.singleton c))

-- | Read a small credential-grade file safely: refuse symlinks, non-regular
-- files, group- or world-writable modes ('FileMode' bits in the forbidden
-- mask), empty or oversized files, and a file replaced while opening.
readBoundedFile :: FilePath -> Text -> FileMode -> IO ByteString
readBoundedFile path label forbidden = do
  when (null path) $ throwIO (ConfigurationError (label <> " file is missing"))
  let refuse :: Text -> IO a
      refuse = throwIO . ConfigurationError . ((label <> " ") <>)
  outcome <- try $ do
    info <- Posix.getSymbolicLinkStatus path
    when (Posix.isSymbolicLink info || not (Posix.isRegularFile info)) $ refuse "file is not a regular file"
    when (Posix.fileMode info .&. forbidden /= 0) $ refuse "file permissions are too broad"
    let size = fromIntegral (Posix.fileSize info) :: Integer
    unless (size > 0 && size <= toInteger maxSecretBytes) $ refuse "file size is not admitted"
    bracket
      (PosixIO.openFd path PosixIO.ReadOnly PosixIO.defaultFileFlags {PosixIO.nofollow = True})
      PosixIO.closeFd
      $ \descriptor -> do
        current <- Posix.getFdStatus descriptor
        when
          ( (Posix.deviceID current, Posix.fileID current) /= (Posix.deviceID info, Posix.fileID info)
              || not (Posix.isRegularFile current)
          )
          $ refuse "file changed while opening"
        PosixBS.fdRead descriptor (fromIntegral (maxSecretBytes + 1))
  raw <- case outcome of
    Left (_ :: IOException) -> refuse "file cannot be read safely"
    Right bytes -> pure bytes
  when (BS.null raw || BS.length raw > maxSecretBytes) $ refuse "file size is not admitted"
  pure raw

-- | @installation_accounts(path)@: read one strict, complete installation
-- configuration snapshot.
installationAccounts :: FilePath -> IO [AccountConfig]
installationAccounts path = do
  raw <- readBoundedFile path "GitHub installations" 0o022
  either throwIO pure (parseInstallations raw)

-- | The document checks of @installation_accounts@ over the file's bytes.
parseInstallations :: ByteString -> Either ConfigurationError [AccountConfig]
parseInstallations raw = do
  text <- either (const malformed) Right (TE.decodeUtf8' raw)
  table <- either (const malformed) Right (Toml.parse text)
  let document = members table
  accountValues <- case Map.toList document of
    [("accounts", TomlS.List' _ values@(_ : _))] -> Right values
    _ -> malformed
  accounts <- collect Set.empty Set.empty Set.empty Set.empty [] accountValues
  Right (sortOn (.accountId) accounts)
  where
    malformed = failWith "GitHub installations file is malformed"
    members (TomlS.MkTable entries) = fmap snd entries
    collect _ _ _ _ acc [] = Right (reverse acc)
    collect accountIds accountLogins repositoryIds repositoryNames acc (value : rest) = do
      fields <- case value of
        TomlS.Table' _ table -> Right (members table)
        _ -> malformed
      unless (Map.keysSet fields == Set.fromList ["id", "login", "repositories"]) malformed
      account <- case Map.lookup "id" fields of
        Just (TomlS.Integer' _ n) | n > 0 -> Right n
        _ -> malformed
      login <- case Map.lookup "login" fields of
        Just (TomlS.Text' _ s) | accountLoginShape s -> Right s
        _ -> malformed
      rawRepositories <- case Map.lookup "repositories" fields of
        Just (TomlS.List' _ items@(_ : _)) -> Right items
        _ -> malformed
      let canonical = casefold login
      when (Set.member account accountIds || Set.member canonical accountLogins) $
        failWith "GitHub installation accounts are duplicated"
      repositories <- sortOn id <$> traverse (repository login) rawRepositories
      let currentIds = Set.fromList (map fst repositories)
          currentNames = Set.fromList (map snd repositories)
      when
        ( Set.size currentIds /= length repositories
            || Set.size currentNames /= length repositories
            || not (Set.disjoint currentIds repositoryIds)
            || not (Set.disjoint currentNames repositoryNames)
        )
        $ failWith "GitHub installation repositories are duplicated"
      collect
        (Set.insert account accountIds)
        (Set.insert canonical accountLogins)
        (Set.union currentIds repositoryIds)
        (Set.union currentNames repositoryNames)
        (AccountConfig account login repositories : acc)
        rest
    repository login = \case
      TomlS.Text' _ value -> case T.breakOn ":" value of
        (_, "") -> repositoryMalformed
        (identifierText, rest) -> do
          repositoryId <- positiveDecimal (Just identifierText) "repository id"
          let fullName = T.drop 1 rest
          unless (repositoryNameShape fullName && casefold (fst (T.breakOn "/" fullName)) == casefold login) repositoryMalformed
          Right (repositoryId, casefold fullName)
      _ -> repositoryMalformed
    repositoryMalformed = failWith "installation repositories are malformed"

-- | @[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@.
repositoryNameShape :: Text -> Bool
repositoryNameShape name = case T.splitOn "/" name of
  [owner, repo] -> part owner && part repo
  _ -> False
  where
    part segment = not (T.null segment) && T.all (\c -> isAsciiAlnum c || c == '_' || c == '.' || c == '-') segment

retiredInstallationEnvironment :: [String]
retiredInstallationEnvironment =
  [ "HAMSTERDAN_ALLOWED_REPOSITORIES"
  , "HAMSTERDAN_GITHUB_ACCOUNT_ID"
  , "HAMSTERDAN_GITHUB_ACCOUNT_LOGIN"
  ]

-- | @pathlib.Path(value)@'s spelling: repeated slashes and @.@ components
-- collapse, a trailing slash drops, and an empty path is @.@.
normalizeStatePath :: String -> FilePath
normalizeStatePath value =
  let root
        | take 2 value == "//" && take 3 value /= "///" = "//"
        | take 1 value == "/" = "/"
        | otherwise = ""
      parts = filter (\part -> part /= "" && part /= ".") (splitSlash value)
      joined = foldr1' (\a b -> a <> "/" <> b) parts
   in case (root, joined) of
        ("", "") -> "."
        (_, "") -> root
        _ -> root <> joined
  where
    splitSlash s = case break (== '/') s of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitSlash rest
    foldr1' f = \case
      [] -> ""
      xs -> foldr1 f xs

-- | @HostConfig.from_environment(environment)@.
fromEnvironment :: Map String String -> IO HostConfig
fromEnvironment environment = do
  when (any (`Map.member` environment) retiredInstallationEnvironment) $
    throwIO (ConfigurationError "retired single-account configuration is present")
  when (any (`Map.member` environment) ["HAMSTERDAN_GITHUB_PRIVATE_KEY_FILE", "HAMSTERDAN_GITHUB_WEBHOOK_SECRET_FILE"]) $
    throwIO (ConfigurationError "retired GitHub credential-file configuration is present")
  let statePath = normalizeStatePath (Map.findWithDefault "" "HAMSTERDAN_STATE_PATH" environment)
      text name = T.pack <$> Map.lookup name environment
      orThrow = either throwIO pure
  when (statePath == ".") $ throwIO (ConfigurationError "state path is missing")
  appId <- orThrow (positiveDecimal (text "HAMSTERDAN_GITHUB_APP_ID") "App id")
  appSlug <- orThrow (slug (text "HAMSTERDAN_GITHUB_APP_SLUG"))
  clientId <- orThrow (identifier (text "HAMSTERDAN_GITHUB_CLIENT_ID") "client id")
  accounts <- installationAccounts (Map.findWithDefault "" "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE" environment)
  privateKey <- orThrow (credential (Map.lookup "HAMSTERDAN_GITHUB_PRIVATE_KEY" environment) "private key")
  webhookSecret <- orThrow (credential (Map.lookup "HAMSTERDAN_GITHUB_WEBHOOK_SECRET" environment) "webhook secret")
  watchedAuthors <- orThrow (watchedAuthorsOf (text "HAMSTERDAN_WATCH_AUTHORS"))
  pure HostConfig {..}
