-- | The tier C fixture file (@python/fixture.py@ documents it): the
-- repository, organization and App one host's operator acts on, as the
-- Haskell operator's configuration ('Fixture' and the delegated broker
-- digests of 'Operator').
module Hamsterdan.E2E.Fixture
  ( readFixture
  , parseFixture
  , fixtureOperator
  ) where

import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Operator (Fixture (..), Operator (..), defaultOperator)
import Petrus.Json (Json (..), parseJson, pythonJsonLoads)

-- | The operator over a fixture: 'defaultOperator' with its fixture and
-- delegated broker digests.
fixtureOperator :: (Fixture, (Text, Text)) -> Operator
fixtureOperator (fixture, (brokerDigest, validatorDigest)) =
  defaultOperator {fixture, brokerDigest, validatorDigest}

readFixture :: FilePath -> IO (Fixture, (Text, Text))
readFixture path = do
  bytes <- BS.readFile path
  either (ioError . userError . ((path <> ": ") <>)) pure (parseJson pythonJsonLoads bytes >>= parseFixture)

-- | @fixture.parse@: exactly the eight members, positive ids, non-empty
-- strings, and a repository inside the organization.
parseFixture :: Json -> Either String (Fixture, (Text, Text))
parseFixture = \case
  Object members
    | sort (map fst members) == sort fields -> do
        let string name = case lookup name members of
              Just (String value) | not (T.null value) -> Right value
              _ -> Left ("fixture " <> T.unpack name <> " must be a non-empty string")
            positive name = case lookup name members of
              Just (Int value) | value > 0 -> Right value
              _ -> Left ("fixture " <> T.unpack name <> " must be a positive integer")
        repository <- string "repository"
        organization <- string "organization"
        orgId <- positive "org_id"
        repositoryId <- positive "repository_id"
        appSlug <- string "app_slug"
        heroReviewer <- string "hero_reviewer"
        brokerDigest <- string "broker_digest"
        validatorDigest <- string "validator_digest"
        let (owner, name) = T.breakOn "/" repository
        if T.length name < 2 || owner /= organization
          then Left "fixture repository must be <organization>/<name>"
          else Right (Fixture {repository, organization, orgId, repositoryId, appSlug, heroReviewer}, (brokerDigest, validatorDigest))
  _ -> Left ("a fixture has exactly the members " <> T.unpack (T.intercalate ", " fields))
  where
    fields = ["repository", "organization", "org_id", "repository_id", "app_slug", "hero_reviewer", "broker_digest", "validator_digest"]
