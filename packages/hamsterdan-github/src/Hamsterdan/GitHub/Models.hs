{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Provider snapshots, results, failures and the transport capabilities
-- (@github_app/models.py@).
module Hamsterdan.GitHub.Models
  ( -- * Failures
    FailureClass (..)
  , failureClassName
  , GitHubBoundaryError (..)
  , BoundaryKind (..)
  , boundary
  , boundaryWith
  , RerunRefused (..)
  , ContractRefused (..)
  , InvalidRequest (..)
  , PublicationCollision (..)
  , PublicationRejected (..)

    -- * Inventory
  , InstallationInventory (..)
  , RegistrationInventory (..)

    -- * Transport capabilities (the effect seam)
  , WireResponse (..)
  , Transport (..)
  , BinaryTransport (..)
  , GraphQLTransport (..)
  , maxLogBytes

    -- * Snapshots
  , PullRequestSnapshot (..)
  , RepositoryPolicy (..)
  , ActionsJobSnapshot (..)
  , ActionsRunSnapshot (..)
  , ActionsConclusion (..)
  , ActionsEvidence (..)
  , HumanReviewSnapshot (..)
  , CommentReference (..)
  , PublicationResult (..)
  , PublicationStatus (..)
  , publicationStatusText
  , publication
  , FindingPublication (..)
  , finding
  , RerunIssue (..)
  ) where

import Control.Exception (Exception (..))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json)

-- | @ProviderFailureClass@.
data FailureClass
  = TransportAmbiguity
  | TransientHttpRejection
  | CapabilityDenial
  | PayloadRejection
  | ProviderRejection
  deriving stock (Eq, Ord, Show, Enum, Bounded)

failureClassName :: FailureClass -> Text
failureClassName = \case
  TransportAmbiguity -> "transport_ambiguity"
  TransientHttpRejection -> "transient_http_rejection"
  CapabilityDenial -> "capability_denial"
  PayloadRejection -> "payload_rejection"
  ProviderRejection -> "provider_rejection"

-- | Which @GitHubBoundaryError@ class was raised.
data BoundaryKind
  = -- | @GitHubBoundaryError@ itself.
    Boundary
  | -- | @GitHubObjectWriteError@: GitHub did not prove creation of an exact
    -- Git object.
    ObjectWrite
  deriving stock (Eq, Show)

-- | @GitHubBoundaryError@: a secret-safe provider boundary failure with
-- bounded diagnostics.
data GitHubBoundaryError = GitHubBoundaryError
  { kind :: BoundaryKind
  , message :: Text
  , failureClass :: FailureClass
  , providerStatus :: Maybe Int
  , providerDetail :: Text
  }
  deriving stock (Eq, Show)

instance Exception GitHubBoundaryError where
  displayException e = T.unpack e.message

-- | A transport-ambiguity failure with no diagnostics.
boundary :: Text -> GitHubBoundaryError
boundary text = GitHubBoundaryError Boundary text TransportAmbiguity Nothing "none"

-- | A transport-ambiguity failure with a bounded diagnostic atom.
boundaryWith :: Text -> Text -> GitHubBoundaryError
boundaryWith text detail = (boundary text) {providerDetail = detail}

-- | @RerunRefusedError@: proven pre-effect movement. The broker verified
-- currency and refused before any effect, so nothing landed.
newtype RerunRefused = RerunRefused Text
  deriving stock (Eq, Show)

instance Exception RerunRefused

-- | A provider contract the reference enforces with @RuntimeError@
-- (registration identity, permissions, inventory consistency).
newtype ContractRefused = ContractRefused Text
  deriving stock (Eq, Show)

instance Exception ContractRefused

-- | An argument the reference refuses with @ValueError@ before any request.
newtype InvalidRequest = InvalidRequest Text
  deriving stock (Eq, Show)

instance Exception InvalidRequest

-- | @ValueError("stable publication operation collided with a different
-- payload")@: an operation identity already holds different content.
data PublicationCollision = PublicationCollision
  deriving stock (Eq, Show)

instance Exception PublicationCollision

-- | @ValueError("GitHub rejected {operation}")@: a definitive, non-retryable
-- provider rejection of a comment publication.
newtype PublicationRejected = PublicationRejected Text
  deriving stock (Eq, Show)

instance Exception PublicationRejected

data InstallationInventory = InstallationInventory
  { installationId :: Integer
  , accountId :: Integer
  , repositories :: [(Integer, Text)]
  }
  deriving stock (Eq, Show)

newtype RegistrationInventory = RegistrationInventory
  { installations :: [InstallationInventory]
  }
  deriving stock (Eq, Show)

-- | One decoded provider response.
data WireResponse = WireResponse
  { status :: Int
  , body :: Json
  -- ^ The decoded JSON body; 'Petrus.Json.Null' for an empty body.
  , nextPath :: Maybe Text
  -- ^ The admitted @Link: rel="next"@ path and query, if any.
  }
  deriving stock (Show)

-- | The REST capability every read and effect goes through.
--
-- This record is the GitHub effect seam: 'Hamsterdan.GitHub.Transport'
-- builds the bounded production value over an authenticated client, and
-- tests pass scripted records.
data Transport = Transport
  { request :: Text -> Text -> Maybe [(Text, Json)] -> IO WireResponse
  -- ^ Method, path (with query) relative to the API origin, JSON object body.
  , pages :: Text -> IO [[(Text, Json)]]
  -- ^ Every object of a paginated list, following @Link: rel="next"@.
  }

-- | Bounded binary downloads.
newtype BinaryTransport = BinaryTransport
  { download :: Text -> Int -> IO ByteString
  }

-- | The GraphQL capability.
data GraphQLTransport = GraphQLTransport
  { reviewThreads :: Text -> Text -> Integer -> IO [Json]
  -- ^ Owner, repository name, pull request number.
  , resolveReviewThread :: Text -> IO ()
  , compareAndSwapRef :: Text -> Text -> Text -> Text -> IO ()
  -- ^ Repository, ref, expected head, new commit.
  }

-- | @MAX_LOG_BYTES@.
maxLogBytes :: Int
maxLogBytes = 2097152

data PullRequestSnapshot = PullRequestSnapshot
  { repository :: Text
  , number :: Integer
  , state :: Text
  , draft :: Bool
  , head :: Text
  , base :: Text
  , headRef :: Text
  , baseRef :: Text
  , mergeable :: Json
  -- ^ The provider's @mergeable@ value as given (@bool | None@ upstream).
  , merged :: Bool
  , closed :: Bool
  , author :: Text
  , mergeableState :: Text
  , url :: Text
  , headRepository :: Text
  }
  deriving stock (Eq, Show)

data RepositoryPolicy = RepositoryPolicy
  { strict :: Bool
  , updateRequired :: Bool
  , requiredChecks :: [Text]
  , requiredApprovals :: Integer
  , conversationResolution :: Bool
  , source :: Text
  , digest :: Text
  }
  deriving stock (Eq, Show)

data ActionsJobSnapshot = ActionsJobSnapshot
  { id :: Integer
  , name :: Text
  , status :: Text
  , conclusion :: Maybe Text
  , required :: Bool
  }
  deriving stock (Eq, Show)

data ActionsRunSnapshot = ActionsRunSnapshot
  { id :: Integer
  , head :: Text
  , workflow :: Text
  , attempt :: Integer
  , status :: Text
  , conclusion :: Maybe Text
  , jobs :: [ActionsJobSnapshot]
  }
  deriving stock (Eq, Show)

data ActionsConclusion = Queued | InProgress | Success | Failure
  deriving stock (Eq, Show)

data ActionsEvidence = ActionsEvidence
  { run :: ActionsRunSnapshot
  , conclusion :: ActionsConclusion
  , failedRequiredJobs :: [(Text, Maybe Text)]
  }
  deriving stock (Eq, Show)

data HumanReviewSnapshot = HumanReviewSnapshot
  { requestedReviewers :: [Text]
  , latestReviews :: [(Text, Text)]
  , approvals :: [Text]
  , changesRequested :: [Text]
  , unresolvedThreads :: Maybe Int
  , threadsCapability :: Text
  }
  deriving stock (Eq, Show)

data CommentReference = CommentReference
  { id :: Integer
  , url :: Text
  }
  deriving stock (Eq, Show)

data PublicationResult = PublicationResult
  { status :: PublicationStatus
  , reference :: Maybe CommentReference
  , capabilityAvailable :: Bool
  , inline :: Bool
  }
  deriving stock (Eq, Show)

-- | @PublicationResult.status@. Hamsterdan's publisher answers one of the
-- six named statuses. The reference's field is a @str@, and its gate tests
-- substitute publishers that answer something else (@"banana"@), which the
-- gates refuse: 'PublicationUnclassified' carries such a status to them.
data PublicationStatus
  = PublicationCreated
  | PublicationExisting
  | PublicationUpdated
  | PublicationRequested
  | PublicationCapabilityUnavailable
  | PublicationInlineUnavailable
  | PublicationUnclassified Text
  deriving stock (Eq, Show)

-- | The status's spelling in the reference.
publicationStatusText :: PublicationStatus -> Text
publicationStatusText = \case
  PublicationCreated -> "created"
  PublicationExisting -> "existing"
  PublicationUpdated -> "updated"
  PublicationRequested -> "requested"
  PublicationCapabilityUnavailable -> "capability_unavailable"
  PublicationInlineUnavailable -> "inline_unavailable"
  PublicationUnclassified other -> other

-- | @PublicationResult(status, reference)@ with the dataclass defaults.
publication :: PublicationStatus -> Maybe CommentReference -> PublicationResult
publication status reference = PublicationResult status reference True False

data FindingPublication = FindingPublication
  { operation :: Text
  , text :: Text
  , path :: Text
  , line :: Integer
  , relatedLocations :: [(Text, Integer)]
  , suggestion :: Text
  , link :: Text
  }
  deriving stock (Eq, Show)

-- | @FindingPublication(operation, text, path, line)@ with the dataclass
-- defaults.
finding :: Text -> Text -> Text -> Integer -> FindingPublication
finding operation text path line = FindingPublication operation text path line [] "" ""

-- | One rerun issuance plus the pre-request evidence cut: the newest
-- @(run_id, attempt)@ the provider reported for the head in the final read
-- immediately before the request.
data RerunIssue = RerunIssue
  { result :: PublicationResult
  , cutRunId :: Integer
  , cutAttempt :: Integer
  }
  deriving stock (Eq, Show)
