-- | Shared result shape for compatibility checks
-- (@petrus.agenticus.catalog.result@).
module Petrus.Agenticus.Catalog.Result
  ( CompatibilityIssue (code, subject)
  , mkCompatibilityIssue
  , compatibilityIssue
  , issueToData
  , issueFromData
  , CompatibilityResult (candidate, issues)
  , mkCompatibilityResult
  , compatible
  , resultToData
  , resultFromData
  ) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- | One machine-readable incompatibility with an opaque safe subject.  The
-- code is open text: decoders accept codes outside Catalog's own vocabulary.
-- Ordered by @(code, subject)@.
data CompatibilityIssue = CompatibilityIssue
  { code :: Text
  , subject :: Text
  }
  deriving stock (Eq, Ord, Show)

issueText :: Text -> Text -> Either AgenticusError Text
issueText label = boundedText (label <> " must be a non-empty, trimmed string of at most 256 UTF-8 bytes")

mkCompatibilityIssue :: Text -> Text -> Either AgenticusError CompatibilityIssue
mkCompatibilityIssue c s =
  CompatibilityIssue <$> issueText "compatibility issue code" c <*> issueText "compatibility issue subject" s

-- | 'mkCompatibilityIssue' for values known to be valid.
compatibilityIssue :: Text -> Text -> CompatibilityIssue
compatibilityIssue c s = either (error . T.unpack . errorMessage) id (mkCompatibilityIssue c s)

issueToData :: CompatibilityIssue -> Json
issueToData i = Object [("code", String i.code), ("subject", String i.subject)]

issueFromData :: Json -> Either AgenticusError CompatibilityIssue
issueFromData raw = do
  fields <- exactObject ["code", "subject"] (valueError "compatibility issue requires exact code and subject fields") raw
  c <- textOf "compatibility issue code" (member "code" fields)
  s <- textOf "compatibility issue subject" (member "subject" fields)
  pure (CompatibilityIssue c s)
  where
    textOf label = \case
      String t -> issueText label t
      _ -> issueText label ""

-- | A candidate-local compatibility result; success is structurally derived.
-- Issues are unique and sorted.
data CompatibilityResult = CompatibilityResult
  { candidate :: Maybe DescriptorIdentity
  , issues :: [CompatibilityIssue]
  }
  deriving stock (Eq, Show)

mkCompatibilityResult :: Maybe DescriptorIdentity -> [CompatibilityIssue] -> Either AgenticusError CompatibilityResult
mkCompatibilityResult c is
  | hasDuplicates is = Left (valueError "compatibility issues must not contain duplicates")
  | c == Nothing && null is = Left (valueError "a compatible result requires a candidate")
  | otherwise = Right (CompatibilityResult c (sort is))

compatible :: CompatibilityResult -> Bool
compatible r = r.candidate /= Nothing && null r.issues

resultToData :: CompatibilityResult -> Json
resultToData r =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("candidate", maybe Null identityToData r.candidate)
    , ("issues", Array (map issueToData r.issues))
    ]

resultFromData :: Json -> Either AgenticusError CompatibilityResult
resultFromData raw = do
  fields <-
    exactObject
      ["schema_version", "candidate", "issues"]
      (valueError "compatibility result requires exact schema_version, candidate, and issues fields")
      raw
  case member "schema_version" fields of
    Int v | v == schemaVersion -> Right ()
    _ -> Left (valueError "compatibility result schema_version must be integer 1")
  items <- case member "issues" fields of
    Array xs -> Right xs
    _ -> Left (typeError "compatibility result issues must be a JSON array")
  c <- case member "candidate" fields of
    Null -> Right Nothing
    other -> Just <$> identityFromData other
  is <- traverse issueFromData items
  mkCompatibilityResult c is
