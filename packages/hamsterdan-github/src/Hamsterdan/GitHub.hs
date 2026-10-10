{-# LANGUAGE DuplicateRecordFields #-}

-- | The GitHub boundary of Hamsterdan: one import for a host process.
--
-- This module re-exports what wiring a process needs — configuration, the
-- App clients and their startup check, the production 'Transport' (the
-- GitHub effect seam), the gateway and publisher constructors, webhook
-- custody and routing. The operations themselves keep names that clash
-- across modules (@request@, @pages@, @status@, @comments@, …), so import
-- "Hamsterdan.GitHub.Gateway", "Hamsterdan.GitHub.Effects",
-- "Hamsterdan.GitHub.Webhooks" or "Hamsterdan.GitHub.Routing" qualified
-- for those.
module Hamsterdan.GitHub
  ( -- * Configuration
    HostConfig (..)
  , AccountConfig (..)
  , ConfigurationError (..)
  , Secret
  , secret
  , revealSecret
  , fromEnvironment
  , botLogin

    -- * Clients
  , ClientOptions (..)
  , defaultClientOptions
  , RequestMetadata (..)
  , AppClients
  , GitHubClient
  , githubAppClients
  , appClient
  , installationClient
  , inventoryClient
  , registrationInventory

    -- * The effect seam
  , Transport (..)
  , BinaryTransport (..)
  , GraphQLTransport (..)
  , WireResponse (..)
  , githubTransport
  , githubDownloads
  , githubGraphQL
  , Exchange (..)
  , newRealExchange

    -- * Gateway, publisher and broker
  , GitHubAuthority
  , githubAuthority
  , CommentPublisher
  , commentPublisher
  , Fence
  , EffectFault
  , CommentRerunBroker (..)

    -- * Webhooks and routing
  , WebhookCustody
  , CustodyOptions (..)
  , defaultCustodyOptions
  , openCustody
  , closeCustody
  , Observation (..)
  , InstallationRegistry
  , openRegistry
  , closeRegistry
  , Route (..)

    -- * Models
  , module Hamsterdan.GitHub.Models
  ) where

import Hamsterdan.GitHub.Auth (githubAppClients, registrationInventory)
import Hamsterdan.GitHub.Client
  ( AppClients
  , ClientOptions (..)
  , GitHubClient
  , RequestMetadata (..)
  , appClient
  , defaultClientOptions
  , installationClient
  , inventoryClient
  )
import Hamsterdan.GitHub.Config
  ( AccountConfig (..)
  , ConfigurationError (..)
  , HostConfig (..)
  , Secret
  , botLogin
  , fromEnvironment
  , revealSecret
  , secret
  )
import Hamsterdan.GitHub.Effects (CommentPublisher, CommentRerunBroker (..), EffectFault, Fence, commentPublisher)
import Hamsterdan.GitHub.Gateway (GitHubAuthority, githubAuthority)
import Hamsterdan.GitHub.Http (Exchange (..), newRealExchange)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Routing (InstallationRegistry, Route (..), closeRegistry, openRegistry)
import Hamsterdan.GitHub.Transport (githubDownloads, githubGraphQL, githubTransport)
import Hamsterdan.GitHub.Webhooks
  ( CustodyOptions (..)
  , Observation (..)
  , WebhookCustody
  , closeCustody
  , defaultCustodyOptions
  , openCustody
  )
