-- | Tool input schemas: the zod shapes declared in @server/mcp.mjs@, as data.
--
-- One description yields both the JSON Schema advertised by @tools/list@
-- (what @zod-to-json-schema@ emits through the MCP SDK) and the validator
-- applied to @tools/call@ arguments (zod v4 @safeParse@ semantics: unknown
-- keys are stripped, output keys follow the shape order, passthrough
-- objects keep extras, and every issue is reported with zod's exact JSON).
module Petrus.Viewer.Mcp.Schema
  ( Schema (..)
  , Field (..)
  , required
  , optional
  , described
  , toJsonSchema
  , toolInputSchema
  , validate
  , issuesText
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Viewer.Json

data Schema
  = SString
  | SNumber
  | SBoolean
  | SArray Schema
  | -- | @z.record(z.string(), value)@
    SRecord Schema
  | -- | @z.object(shape)@, optionally @.passthrough()@
    SObject [(Text, Field)] Bool
  deriving stock (Eq, Show)

data Field = Field
  { fieldSchema :: Schema
  , fieldOptional :: Bool
  , fieldDescription :: Maybe Text
  }
  deriving stock (Eq, Show)

required :: Schema -> Field
required s = Field s False Nothing

optional :: Schema -> Field
optional s = Field s True Nothing

described :: Text -> Field -> Field
described d f = f {fieldDescription = Just d}

-- | The JSON Schema (draft 7) for a schema.
toJsonSchema :: Schema -> JsValue
toJsonSchema = go Nothing
  where
    go desc s = obj (body s ++ maybe [] (\d -> [("description", str d)]) desc)
    body = \case
      SString -> [("type", str "string")]
      SNumber -> [("type", str "number")]
      SBoolean -> [("type", str "boolean")]
      SArray item -> [("type", str "array"), ("items", toJsonSchema item)]
      SRecord value ->
        [ ("type", str "object")
        , ("propertyNames", obj [("type", str "string")])
        , ("additionalProperties", toJsonSchema value)
        ]
      SObject shape passthrough ->
        [("type", str "object"), ("properties", obj [(k, go (fieldDescription f) (fieldSchema f)) | (k, f) <- shape])]
          ++ (case [k | (k, f) <- shape, not (fieldOptional f)] of [] -> []; ks -> [("required", arr (map str ks))])
          ++ [("additionalProperties", obj []) | passthrough]

-- | A tool's @inputSchema@: the object schema plus the draft-07 marker.
toolInputSchema :: [(Text, Field)] -> JsValue
toolInputSchema shape = case toJsonSchema (SObject shape False) of
  JsObj o -> JsObj (objectFromList ((jsString "$schema", str "http://json-schema.org/draft-07/schema#") : objectToList o))
  other -> other

type Path = [JsValue]

-- | Validate (and strip) a value; 'Nothing' stands for @undefined@.
validate :: Schema -> Maybe JsValue -> Either [JsValue] JsValue
validate = go []
  where
    go :: Path -> Schema -> Maybe JsValue -> Either [JsValue] JsValue
    go path schema mv = case (schema, mv) of
      (SString, Just v@(JsStr _)) -> Right v
      (SNumber, Just v@(JsNum n)) | finite n -> Right v
      (SBoolean, Just v@(JsBool _)) -> Right v
      (SArray item, Just (JsArr xs)) ->
        let results = [go (path ++ [int i]) item (Just x) | (i, x) <- zip [0 ..] xs]
         in collect JsArr results
      (SRecord value, Just (JsObj o)) ->
        let results = [fmap (k,) (go (path ++ [JsStr k]) value (Just v)) | (k, v) <- objectToList o]
         in collect (JsObj . objectFromList) results
      (SObject shape passthrough, Just (JsObj o)) ->
        let known =
              [ fmap (fmap (jsString k,)) r
              | (k, f) <- shape
              , let present = lookupKey k o
              , let r = case present of
                      Nothing | fieldOptional f -> Right Nothing
                      _ -> Just <$> go (path ++ [str k]) (fieldSchema f) present
              ]
            extras =
              if passthrough
                then [kv | kv@(k, _) <- objectToList o, jsStringText k `notElem` map fst shape]
                else []
         in case collect id known of
              Left issues -> Left issues
              Right kvs -> Right (JsObj (objectFromList (mapMaybe id kvs ++ extras)))
      _ -> Left [issue path (expected schema) mv]
    finite n = let d = jsNumberValue n in not (isNaN d || isInfinite d)
    collect :: ([a] -> b) -> [Either [JsValue] a] -> Either [JsValue] b
    collect f rs = case concat [is | Left is <- rs] of
      [] -> Right (f [x | Right x <- rs])
      issues -> Left issues
    expected = \case
      SString -> "string"
      SNumber -> "number"
      SBoolean -> "boolean"
      SArray _ -> "array"
      SRecord _ -> "record"
      SObject _ _ -> "object"
    issue path ex mv =
      let received = maybe "undefined" jsTypeName mv
       in obj
            [ ("expected", str ex)
            , ("code", str "invalid_type")
            , ("path", arr path)
            , ("message", str ("Invalid input: expected " <> ex <> ", received " <> received))
            ]

-- | zod's @error.message@: the issues, pretty-printed.
issuesText :: [JsValue] -> Text
issuesText = TE.decodeUtf8 . encodePretty . arr
