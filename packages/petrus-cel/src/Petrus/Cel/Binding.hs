-- | Petrus's CEL adapter (@petrus.impetus.binding.cel@), over plain JSON.
--
-- The three Petrus environments, exactly as the reference builds them:
--
-- * a /filter/ sees the token's data fields as bare variables; data that is
--   not a JSON object raises @TypeError@;
-- * a /guard/ sees each of its transition's consume/read input places as a
--   variable bound to the binding's selected tokens from that place
--   (consumed selections first, read after), each token a
--   @{color, data}@ map;
-- * a /completion/ condition sees every place of the net bound to its queue
--   of @{color, data}@ maps (an empty place binds to the empty list).
--
-- Compilation refuses, with the reference's @ValueError@ texts, an
-- expression that does not parse and an expression with a free variable
-- outside its scope (a guard's input places, a completion's places). A
-- compiled predicate's @Left@ is the exception the reference lets propagate
-- (a CEL evaluation error or a Python exception); its @Right@ is
-- @bool(result)@.
--
-- "Petrus.Cel.Impetus" adapts these to the Impetus kernel's types.
module Petrus.Cel.Binding
  ( -- * Tokens
    TokenJson (..)
    -- * Compilers
  , compileFilter
  , compileGuard
  , compileCompletion
  , macros
    -- * Diagnostics
  , diagnostic
  ) where

import Data.List (nub, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Petrus.Cel
import Petrus.Cel.Python (strRepr)
import Petrus.Cel.Value (pyExc)
import Petrus.Json (Json (..))

-- | A token as the expressions see it: its color (@null@ for a black
-- token) and its data.
data TokenJson = TokenJson
  { tokenColor :: Maybe Text
  , tokenData :: Json
  }

-- | @_parsed@: the program, or the declared-mismatch @ValueError@ text
-- naming the slot kind and carrying cel-python's parse-error context.
parsed :: Text -> Text -> Either Text Program
parsed kind expression = case compile expression of
  Right program -> Right program
  Left err -> Left ("invalid CEL " <> kind <> " " <> strRepr expression <> ": " <> parseErrorMessage err)

-- | Python's @repr()@ of a sorted list of names.
namesRepr :: [Text] -> Text
namesRepr names = "[" <> T.intercalate ", " (map strRepr (sort names)) <> "]"

-- | @_structs@: tokens as @[{"color": ..., "data": ...}]@.
structs :: [TokenJson] -> Json
structs tokens = Array [Object [("color", maybe Null String (tokenColor t)), ("data", tokenData t)] | t <- tokens]

-- | @compile_filter@: a predicate over a token's data.
compileFilter :: Text -> Either Text (Json -> Either Exc Bool)
compileFilter expression = do
  program <- parsed "filter" expression
  Right $ \case
    Object members -> truthy <$> evaluateJson program members
    other ->
      Left
        ( pyExc
            TypeError
            ("CEL filters read data fields; token data is " <> pythonTypeName other <> ", not a mapping")
        )
  where
    pythonTypeName = \case
      Null -> "NoneType"
      Bool _ -> "bool"
      Int _ -> "int"
      Float _ -> "float"
      String _ -> "str"
      Array _ -> "list"
      Object _ -> "dict"

-- | @compile_guard@: the expression, its transition (for the refusal
-- message), and the transition's consume/read input places. The predicate
-- takes the binding's selections, consumed then read, as (place, tokens).
compileGuard :: Text -> Text -> [Text] -> Either Text ([(Text, [TokenJson])] -> Either Exc Bool)
compileGuard expression transition places = do
  program <- parsed "guard" expression
  let unknown = Set.toList (freeVariables program `Set.difference` Set.fromList places)
  if not (null unknown)
    then
      Left
        ( "CEL guard " <> strRepr expression <> " on transition " <> transition
            <> " references name(s) outside its consume/read input places "
            <> namesRepr places
            <> ": "
            <> namesRepr unknown
        )
    else Right $ \selections ->
      let names = nub (map fst selections)
          grouped = [(name, structs (concat [ts | (p, ts) <- selections, p == name])) | name <- names]
       in truthy <$> evaluateJson program grouped

-- | @compile_completion@: the expression and the net's places. The
-- predicate takes each place's queue.
compileCompletion :: Text -> [Text] -> Either Text ((Text -> [TokenJson]) -> Either Exc Bool)
compileCompletion expression places = do
  program <- parsed "completion" expression
  let queues = nub places
      unknown = Set.toList (freeVariables program `Set.difference` Set.fromList queues)
  if not (null unknown)
    then Left ("CEL completion " <> strRepr expression <> " references unknown place(s): " <> namesRepr unknown)
    else Right $ \queue -> truthy <$> evaluateJson program [(name, structs (queue name)) | name <- queues]

-- | The diagnostic text of a predicate's error: Python's @repr()@ of the
-- exception (a @CELEvalError@'s activation dump is abbreviated).
diagnostic :: Exc -> Text
diagnostic = excRepr
