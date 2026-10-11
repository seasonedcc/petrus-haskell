-- | Shared JSON builders and expectations for the agent specs.
module PiDoubles
  ( obj
  , str
  , int
  , arr
  , strs
  , refusedMatching
  , refusalOf
  , headSha
  , baseSha
  , firstOf
  , membersOf
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol (AgentProtocolError (..))
import Hamsterdan.Agents.Validate (Failure (..))
import Petrus.Json (Json (..))
import Test.Hspec

obj :: [(Text, Json)] -> Json
obj = Object

str :: Text -> Json
str = String

int :: Integer -> Json
int = Int

arr :: [Json] -> Json
arr = Array

strs :: [Text] -> Json
strs = Array . map String

headSha, baseSha :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"

-- | @pytest.raises(AgentProtocolError, match=pattern)@ for a literal
-- pattern.
refusedMatching :: (Show a) => Text -> Either Failure a -> Expectation
refusedMatching pattern = \case
  Left (Refused failure) | pattern `T.isInfixOf` failure.reason -> pure ()
  other -> expectationFailure ("expected a refusal matching " <> show pattern <> ", got " <> show other)

refusalOf :: (Show a) => Either Failure a -> IO AgentProtocolError
refusalOf = \case
  Left (Refused failure) -> pure failure
  other -> fail ("expected a refusal, got " <> show other)

firstOf :: [a] -> a
firstOf = \case
  first : _ -> first
  [] -> error "empty list"

membersOf :: Json -> [(Text, Json)]
membersOf = \case
  Object members -> members
  _ -> []
