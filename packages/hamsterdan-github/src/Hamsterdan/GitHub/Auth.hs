{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | App registration and installation authority (@github_app/auth.py@):
-- the clients of one host configuration and the startup check that the
-- App's identity, permissions and webhook events, and every configured
-- installation and repository, are exactly what GitHub reports.
module Hamsterdan.GitHub.Auth
  ( -- * Clients
    githubAppClients

    -- * Startup check
  , registrationInventory
  , appPermissions
  , appEvents
  , maxInventoryPages
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM, unless, when)
import Data.List (sort, sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Client
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), revealSecret)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.GitHub.Transport (request)
import Hamsterdan.PyLiteral (PyValue (..), repr)
import Petrus.Json (Json (..))

-- | @MAX_INVENTORY_PAGES@.
maxInventoryPages :: Int
maxInventoryPages = 20

-- | @APP_PERMISSIONS@, sorted by name.
appPermissions :: [(Text, Text)]
appPermissions =
  [ ("actions", "read")
  , ("administration", "read")
  , ("contents", "write")
  , ("issues", "write")
  , ("pull_requests", "write")
  ]

-- | @APP_EVENTS@, sorted.
appEvents :: [Text]
appEvents =
  [ "issue_comment"
  , "pull_request"
  , "pull_request_review"
  , "pull_request_review_comment"
  , "pull_request_review_thread"
  , "workflow_run"
  ]

-- | @GitHubAppClients(config)@ with the given effects.
githubAppClients :: HostConfig -> ClientOptions -> IO AppClients
githubAppClients config =
  newAppClients
    AppCredentials
      { appId = config.appId
      , clientId = config.clientId
      , privateKey = revealSecret config.privateKey
      }

refuse :: Text -> IO a
refuse = throwIO . ContractRefused

-- | @GitHubAppClients.registration_inventory@: validate the App
-- registration and every configured installation account.
registrationInventory :: AppClients -> HostConfig -> IO RegistrationInventory
registrationInventory clients config = do
  let app = appClient clients
  appResponse <- request app "GET" "/app" Nothing
  unless (appResponse.status == 200) (throwIO (boundary "GitHub App registration evidence is unavailable"))
  members <- case appResponse.body of
    Object members -> pure members
    _ -> refuse identityMismatch
  let field name = maybe Null id (lookup name members)
  case (field "id", field "client_id", field "slug") of
    (Int identifier, String clientId, String slug)
      | identifier == config.appId
      , clientId == config.clientId
      , Py.casefold slug == config.appSlug ->
          pure ()
    _ -> refuse identityMismatch
  validatePermissions (field "permissions") "GitHub App"
  events <- case field "events" of
    Array items -> pure items
    _ -> refuse "GitHub App events are malformed"
  let observedEvents = sort (map Py.str events)
  when (Set.fromList observedEvents /= Set.fromList appEvents || length observedEvents /= length appEvents) $
    refuse
      ( "GitHub App events do not match the required first-demo contract: expected="
          <> repr (PyList (map PyStr appEvents))
          <> " observed="
          <> repr (PyList (map PyStr observedEvents))
      )
  installations <- collect app (0 :: Int) (Just "/app/installations?per_page=100") []
  inventory <- forM config.accounts (accountInventory clients installations)
  when (Set.size (Set.fromList (map (.installationId) inventory)) /= length inventory) $
    refuse "configured installation identity is ambiguous"
  pure (RegistrationInventory inventory)
  where
    identityMismatch = "configured GitHub App identity does not match provider authority"
    collect app attempt current acc = case current of
      Nothing -> pure acc
      Just path
        | attempt >= maxInventoryPages -> refuse "GitHub installation inventory exceeds the bounded pagination limit"
        | otherwise -> do
            response <- request app "GET" path Nothing
            unless (response.status == 200) (throwIO (boundary "GitHub installation inventory is unavailable"))
            batch <- case response.body of
              Array items -> pure items
              _ -> refuse "GitHub installation inventory is malformed"
            let acc' = acc <> batch
            case response.nextPath of
              Nothing -> pure acc'
              next
                | attempt + 1 >= maxInventoryPages -> refuse "GitHub installation inventory exceeds the bounded pagination limit"
                | otherwise -> collect app (attempt + 1) next acc'

-- | @_account_inventory@.
accountInventory :: AppClients -> [Json] -> AccountConfig -> IO InstallationInventory
accountInventory clients installations account = do
  let matches = filter matching installations
  selected <- case matches of
    [Object members] -> pure members
    _ -> refuse "configured installation account is missing or ambiguous"
  suspended <- case lookup "suspended_at" selected of
    Nothing -> refuse "configured installation suspension evidence is malformed"
    Just value -> pure value
  unless (suspended == Null) (refuse "configured installation is suspended")
  validatePermissions (maybe Null id (lookup "permissions" selected)) "configured installation"
  installationId <- case lookup "id" selected of
    Just (Int identifier) | identifier > 0 -> pure identifier
    _ -> refuse "configured installation identity is malformed"
  client <- either (throwIO . InvalidRequest) pure (inventoryClient clients installationId)
  (repositories, total) <- collect client (0 :: Int) "/installation/repositories?per_page=100" [] Nothing
  when (length repositories /= total) (refuse "selected repository inventory is inconsistent")
  normalized <- forM repositories $ \case
    item@(Object fields)
      | validRepository item
      , Just (Int identifier) <- lookup "id" fields
      , Just (String fullName) <- lookup "full_name" fields ->
          pure (identifier, fullName)
    _ -> refuse "selected repository inventory is malformed"
  let count = length normalized
  when (Set.size (Set.fromList (map fst normalized)) /= count || Set.size (Set.fromList (map (Py.casefold . snd) normalized)) /= count) $
    refuse "selected repository inventory is inconsistent"
  let observed = Set.fromList [(identifier, Py.casefold fullName) | (identifier, fullName) <- normalized]
  unless (all (`Set.member` observed) account.repositories) $
    refuse "configured repositories are unavailable from the installation"
  pure InstallationInventory {installationId, accountId = account.accountId, repositories = normalized}
  where
    matching = \case
      Object members
        | Just (Object owner) <- lookup "account" members
        , Just (Int identifier) <- lookup "id" owner
        , identifier == account.accountId
        , Just (String login) <- lookup "login" owner ->
            Py.casefold login == Py.casefold account.accountLogin
      _ -> False
    collect client attempt path acc total
      | attempt >= maxInventoryPages = refuse "selected repository inventory exceeds the bounded pagination limit"
      | otherwise = do
          response <- request client "GET" path Nothing
          unless (response.status == 200) (throwIO (boundary "GitHub repository inventory is unavailable"))
          (batch, currentTotal) <- case response.body of
            Object payload
              | Just (Array items) <- lookup "repositories" payload
              , Just (Int n) <- lookup "total_count" payload
              , n >= 0 ->
                  pure (items, n)
            _ -> refuse "selected repository inventory is malformed"
          let expected = maybe currentTotal id total
          when (currentTotal /= expected) (refuse "selected repository inventory changed during pagination")
          let acc' = acc <> batch
              size = toInteger (length acc')
          when (size > expected || (size == expected && response.nextPath /= Nothing)) $
            refuse "selected repository inventory is inconsistent"
          case response.nextPath of
            Nothing -> pure (acc', fromInteger expected)
            Just next
              | attempt + 1 >= maxInventoryPages -> refuse "selected repository inventory exceeds the bounded pagination limit"
              | otherwise -> collect client (attempt + 1) next acc' (Just expected)

-- | @_validate_permissions@.
validatePermissions :: Json -> Text -> IO ()
validatePermissions value owner = case value of
  Object members -> do
    let observed = sortOn fst [(key, Py.str permission) | (key, permission) <- members, key /= "metadata"]
        metadataOk = maybe True (== String "read") (lookup "metadata" members)
    unless (observed == appPermissions && metadataOk) $
      refuse
        ( owner
            <> " permissions do not match the required first-demo contract: expected="
            <> pairs appPermissions
            <> " observed="
            <> pairs observed
        )
  _ -> refuse (owner <> " permissions are malformed")
  where
    pairs items = repr (PyList [PyTuple [PyStr k, PyStr v] | (k, v) <- items])

-- | @_valid_repository@.
validRepository :: Json -> Bool
validRepository = \case
  Object fields
    | Just (Int identifier) <- lookup "id" fields
    , identifier > 0
    , Just (String fullName) <- lookup "full_name" fields ->
        T.length fullName >= 1
          && T.length fullName <= 201
          && Py.isAscii fullName
          && Py.isPrintable fullName
          && T.count "/" fullName == 1
          && all (\part -> not (T.null part) && Py.strip part == part) (T.splitOn "/" fullName)
  _ -> False
