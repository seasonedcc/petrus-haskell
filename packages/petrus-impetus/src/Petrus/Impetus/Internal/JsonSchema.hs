-- | The JSON Schema (draft 2020-12) Pydantic v2 generates for the reference's
-- wire models (@BaseModel.model_json_schema()@), from a description of each
-- model's fields.
--
-- The rules reproduced are the ones the Net definition and Net document
-- models exercise:
--
-- * a model is @{"additionalProperties": false, "description"?,
--   "properties", "required", "title", "type": "object"}@ (every model is
--   @extra="forbid"@; the description is the class docstring);
-- * a field's schema is its type's schema plus a @title@ (the field name,
--   underscores as spaces, title-cased), except that a field whose type is a
--   model reference (or an optional one) carries no title; a field with a
--   default carries it (@"default": null@) and is not @required@;
-- * @Optional[T]@ is @anyOf [T, {"type": "null"}]@; a tagged union is
--   @{"discriminator": {"mapping", "propertyName"}, "oneOf"}@ with the
--   mapping sorted by tag and @oneOf@ in declaration order;
-- * every referenced model is a @$defs@ entry, sorted by name;
-- * object keys are sorted, except the members of @properties@, which keep
--   declaration order (Pydantic's @GenerateJsonSchema@ sorting).
module Petrus.Impetus.Internal.JsonSchema
  ( Ty (..)
  , FieldSpec (..)
  , ModelSpec (..)
  , field
  , defaultedNull
  , modelJsonSchema
  ) where

import Data.Char (isAlpha, toLower, toUpper)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))

-- | A field type, as Pydantic sees the annotation.
data Ty
  = -- | @str@
    Str
  | -- | @Literal["…"]@
    ConstStr Text
  | -- | @Literal[n]@
    ConstInt Integer
  | -- | @Literal["a", "b", …]@
    Enum [Text]
  | -- | @Annotated[int, Field(ge=…, le=…)]@ (strict)
    IntIn Integer Integer
  | -- | @int | float@
    IntOrFloat
  | -- | @Any@ (JSON data)
    AnyValue
  | -- | @dict[str, Any]@
    Dict
  | -- | @T | None@
    Nullable Ty
  | -- | @tuple[T, ...]@
    ListOf Ty
  | -- | Another model, by class name.
    Ref Text
  | -- | A union discriminated by @kind@: each tag with its model's name, in
    -- declaration order.
    Tagged [(Text, Text)]

-- | One declared field.
data FieldSpec = FieldSpec
  { fieldName :: Text
  , fieldType :: Ty
  , defaultsToNull :: Bool
  }

-- | A required field.
field :: Text -> Ty -> FieldSpec
field name ty = FieldSpec name ty False

-- | A field whose default is @None@.
defaultedNull :: Text -> Ty -> FieldSpec
defaultedNull name ty = FieldSpec name ty True

-- | One model: its class name, docstring and fields in declaration order.
data ModelSpec = ModelSpec
  { modelName :: Text
  , modelDescription :: Maybe Text
  , modelFields :: [FieldSpec]
  }

-- | @model_json_schema()@ of the first model, resolving references among
-- the given ones.
modelJsonSchema :: [ModelSpec] -> Json
modelJsonSchema [] = Object []
modelJsonSchema models@(root : _) =
  sortKeys (Object (("$defs", Object [(name, modelSchema (spec name)) | name <- Set.toAscList defs]) : members (modelSchema root)))
  where
    table = Map.fromList [(m.modelName, m) | m <- models]
    spec name = Map.findWithDefault (error ("JsonSchema: no model " <> T.unpack name)) name table
    defs = reachable Set.empty (refsOf root)
    reachable seen [] = seen
    reachable seen (name : rest)
      | name `Set.member` seen = reachable seen rest
      | otherwise = reachable (Set.insert name seen) (refsOf (spec name) ++ rest)
    refsOf m = concatMap (tyRefs . (.fieldType)) m.modelFields
    members = \case
      Object kvs -> kvs
      _ -> []

tyRefs :: Ty -> [Text]
tyRefs = \case
  Nullable t -> tyRefs t
  ListOf t -> tyRefs t
  Ref name -> [name]
  Tagged variants -> map snd variants
  _ -> []

modelSchema :: ModelSpec -> Json
modelSchema m =
  Object $
    [("additionalProperties", Bool False)]
      ++ maybe [] (\d -> [("description", String d)]) m.modelDescription
      ++ [ ("properties", Object [(f.fieldName, fieldSchema f) | f <- m.modelFields])
         , ("required", Array [String f.fieldName | f <- m.modelFields, not f.defaultsToNull])
         , ("title", String m.modelName)
         , ("type", String "object")
         ]

fieldSchema :: FieldSpec -> Json
fieldSchema f =
  let base = case tySchema f.fieldType of
        Object kvs -> kvs
        _ -> []
      titled = if isReference f.fieldType then [] else [("title", String (titleOf f.fieldName))]
      defaulted = [("default", Null) | f.defaultsToNull]
   in Object (base ++ defaulted ++ titled)
  where
    isReference = \case
      Ref _ -> True
      Nullable (Ref _) -> True
      _ -> False

tySchema :: Ty -> Json
tySchema = \case
  Str -> Object [("type", String "string")]
  ConstStr t -> Object [("const", String t), ("type", String "string")]
  ConstInt n -> Object [("const", Int n), ("type", String "integer")]
  Enum tags -> Object [("enum", Array (map String tags)), ("type", String "string")]
  IntIn lo hi -> Object [("maximum", Int hi), ("minimum", Int lo), ("type", String "integer")]
  IntOrFloat -> Object [("anyOf", Array [Object [("type", String "integer")], Object [("type", String "number")]])]
  AnyValue -> Object []
  Dict -> Object [("additionalProperties", Bool True), ("type", String "object")]
  Nullable t -> Object [("anyOf", Array [tySchema t, Object [("type", String "null")]])]
  ListOf t -> Object [("items", tySchema t), ("type", String "array")]
  Ref name -> Object [("$ref", String (reference name))]
  Tagged variants ->
    Object
      [ ( "discriminator"
        , Object
            [ ("mapping", Object [(tag, String (reference name)) | (tag, name) <- sortOn fst variants])
            , ("propertyName", String "kind")
            ]
        )
      , ("oneOf", Array [Object [("$ref", String (reference name))] | (_, name) <- variants])
      ]
  where
    reference name = "#/$defs/" <> name

-- | Pydantic's default field title: @name.replace("_", " ").title()@.
titleOf :: Text -> Text
titleOf = T.pack . go True . T.unpack . T.replace "_" " "
  where
    go _ [] = []
    go start (c : cs)
      | isAlpha c = (if start then toUpper c else toLower c) : go False cs
      | otherwise = c : go True cs

-- | Sort every object's keys, except the members of a @properties@ object
-- (declaration order), recursively.
sortKeys :: Json -> Json
sortKeys = \case
  Object kvs -> Object [(k, if k == "properties" then inOrder v else sortKeys v) | (k, v) <- sortOn fst kvs]
  Array items -> Array (map sortKeys items)
  other -> other
  where
    inOrder = \case
      Object kvs -> Object [(k, sortKeys v) | (k, v) <- kvs]
      other -> sortKeys other
