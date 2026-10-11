-- | Petrus conversion for strict readiness workflow models
-- (@readiness/payloads.py@).
--
-- The reference's @PydanticPayloadConverter@ round-trips strict pydantic
-- dataclasses through canonical JSON values, choosing the model from the
-- parameter's annotation. A Haskell 'PayloadConverter' is untyped (JSON to
-- JSON), so the typed directions are 'decodeModel' and 'encodeModel', and
-- 'pydanticPayloadConverter' is the converter for one known model.
module Hamsterdan.Readiness.Payloads
  ( decodeModel
  , encodeModel
  , pydanticPayloadConverter
  , decodeWith
  ) where

import Data.Bifunctor (first)
import Hamsterdan.Contracts.Codec (Codec (..), Contract (..), Model (..), dump, validate)
import Hamsterdan.Readiness.NetV5.Folding (PythonException, pyError, typeError)
import Petrus.Impetus.Instance.FailureText (pythonFailureText)
import Petrus.Activity (PayloadConverter (..), jsonPayloadConverter)
import Petrus.Json (Json (..))

-- | @decode(value, T)@: a mapping, validated strictly as JSON (extra
-- members and coercions are a @ValidationError@).
decodeModel :: forall a. (Contract a) => Json -> Either PythonException a
decodeModel value = case value of
  Object _ -> either (const (Left (pyError "ValidationError" []))) Right (validate @a value)
  _ -> Left (typeError ("Pydantic payload for " <> (contract @a).codecName <> " must be a mapping"))

-- | @encode(value, T)@: the value's JSON dump. (The reference refuses a
-- value whose type is not exactly @T@; here the type is checked statically.)
encodeModel :: (Contract a) => a -> Json
encodeModel = dump

-- | 'decodeModel' for a type-erased model: the validated value, dumped.
decodeWith :: Model -> Json -> Either PythonException Json
decodeWith model value = case value of
  Object _ -> either (const (Left (pyError "ValidationError" []))) Right (model.modelRoundTrip value)
  _ -> Left (typeError ("Pydantic payload for " <> model.modelName <> " must be a mapping"))

-- | The converter of an Activity whose parameter and result are one strict
-- model: decode validates, encode revalidates (the reference's exact-type
-- check), both answering the canonical dump. Anything else falls back to
-- the JSON-faithful converter's checks.
pydanticPayloadConverter :: Model -> PayloadConverter
pydanticPayloadConverter model =
  PayloadConverter
    { decodePayload = \v -> first pythonFailureText (decodeWith model v) >>= jsonPayloadConverter.decodePayload
    , encodePayload = \v -> case model.modelRoundTrip v of
        Right dumped -> jsonPayloadConverter.encodePayload dumped
        Left _ -> Left (pythonFailureText (typeError ("Pydantic result must be " <> model.modelName)))
    }
