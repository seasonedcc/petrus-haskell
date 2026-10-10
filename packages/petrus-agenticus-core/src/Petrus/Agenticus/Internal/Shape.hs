-- | Small decoding helpers shared by the Thread, Program and Runtime value
-- modules: Python @StrEnum@ spellings, kind-checked descriptor identities,
-- versioned envelopes and the lifecycle integer checks.
module Petrus.Agenticus.Internal.Shape
  ( -- * @StrEnum@
    StrEnum (..)
  , parseStrEnum
  , strEnumJson
  , strEnumData
    -- * Descriptor identities of one kind (@_identity_of_kind@)
  , identityOfKind
    -- * Versioned envelopes
  , requireSchemaVersion
    -- * Lifecycle integers
  , positiveInteger
  , nonnegativeInteger
  , positiveIntegerJson
  , nonnegativeIntegerJson
    -- * Machine tokens (@[a-z][a-z0-9.-]{0,127}@)
  , isMachineToken
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- | A Python @StrEnum@: every constructor has one wire spelling.
class (Bounded a, Enum a) => StrEnum a where
  enumText :: a -> Text

-- | @Cls(value)@ for a string value.
parseStrEnum :: (StrEnum a) => Text -> Maybe a
parseStrEnum t = lookup t [(enumText x, x) | x <- [minBound .. maxBound]]

-- | @Cls(value)@ for any decoded JSON value (non-strings never match).
strEnumJson :: (StrEnum a) => Json -> Maybe a
strEnumJson = \case
  String t -> parseStrEnum t
  _ -> Nothing

strEnumData :: (StrEnum a) => a -> Json
strEnumData = String . enumText

-- | @_identity_of_kind@: a @TypeError@ naming the expected kind.
identityOfKind :: DescriptorKind -> Text -> DescriptorIdentity -> Either AgenticusError DescriptorIdentity
identityOfKind k label value
  | value.kind == k = Right value
  | otherwise = Left (typeError (label <> " must be a " <> kindText k <> " DescriptorIdentity"))

-- | @type(v) is not int or v != 1@, failing with
-- @"{label} schema_version must be integer 1"@.
requireSchemaVersion :: Text -> Fields -> Either AgenticusError ()
requireSchemaVersion label fields = case member "schema_version" fields of
  Int 1 -> Right ()
  _ -> Left (valueError (label <> " schema_version must be integer 1"))

positiveInteger :: Text -> Integer -> Either AgenticusError Integer
positiveInteger label v
  | v > 0 = Right v
  | otherwise = Left (valueError (label <> " must be a positive integer"))

nonnegativeInteger :: Text -> Integer -> Either AgenticusError Integer
nonnegativeInteger label v
  | v >= 0 = Right v
  | otherwise = Left (valueError (label <> " must be a nonnegative integer"))

positiveIntegerJson :: Text -> Json -> Either AgenticusError Integer
positiveIntegerJson label = \case
  Int v -> positiveInteger label v
  _ -> positiveInteger label 0

nonnegativeIntegerJson :: Text -> Json -> Either AgenticusError Integer
nonnegativeIntegerJson label = \case
  Int v -> nonnegativeInteger label v
  _ -> nonnegativeInteger label (-1)

-- | @re.fullmatch(r"[a-z][a-z0-9.-]{0,127}", value)@.
isMachineToken :: Text -> Bool
isMachineToken value = case T.uncons value of
  Just (first, rest) ->
    lower first && T.length rest <= 127 && T.all (\c -> lower c || (c >= '0' && c <= '9') || c == '.' || c == '-') rest
  Nothing -> False
  where
    lower c = c >= 'a' && c <= 'z'
