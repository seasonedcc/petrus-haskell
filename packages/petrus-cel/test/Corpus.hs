-- | The differential corpus: every case recorded from cel-python by
-- @test/gen-cel-corpus.py@ is replayed here — parse trees and parse-error
-- positions, evaluation outcomes (value @repr@ and truthiness, CEL error
-- text, Python exception class and message), Petrus free variables, the
-- operator cross product, and the Petrus adapter cases.
module Corpus
  ( Corpus (..)
  , load
  , spec
  , decodeCorpusJson
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Petrus.Cel
import Petrus.Cel.Binding
import Petrus.Cel.Syntax (larkText, toLark)
import Petrus.Json

data Corpus = Corpus
  { corpusMain :: Json
  , corpusOperators :: Json
  }

load :: IO Corpus
load = Corpus <$> readCorpus "test/corpus/cel-corpus.json" <*> readCorpus "test/corpus/cel-operators.json"
  where
    readCorpus path = either (fail . ((path <> ": ") <>)) pure . parseJson surrogateRefusingLoads =<< BS.readFile path

field :: Text -> Json -> Maybe Json
field = lookupMember

textField :: Text -> Json -> Text
textField name j = case field name j of
  Just (String t) -> t
  _ -> ""

arrayField :: Text -> Json -> [Json]
arrayField name j = case field name j of
  Just (Array xs) -> xs
  _ -> []

-- | The generator's encoding of Python data: @{"$object": [[k, v], ...]}@
-- for a dict (keeping keys JSON cannot express unambiguously) and
-- @{"$float": "nan"}@ for non-finite floats.
decodeCorpusJson :: Json -> Json
decodeCorpusJson = \case
  Object [("$object", Array pairs)] -> Object [(k, decodeCorpusJson v) | Array [String k, v] <- pairs]
  Object [("$float", String s)] -> Float $ case s of
    "nan" -> 0 / 0
    "inf" -> 1 / 0
    _ -> -1 / 0
  Array xs -> Array (map decodeCorpusJson xs)
  Object members -> Object [(k, decodeCorpusJson v) | (k, v) <- members]
  j -> j

-- | Check every case of a group, reporting up to ten mismatches at once.
checkAll :: [(Text, Maybe String)] -> Expectation
checkAll results = case [T.unpack label <> "\n    " <> problem | (label, Just problem) <- results] of
  [] -> pure ()
  problems ->
    expectationFailure
      (show (length problems) <> " mismatching case(s):\n  " <> concatMap (<> "\n  ") (take 10 problems))

spec :: Corpus -> Spec
spec corpus = describe "differential corpus (cel-python 0.5.0)" $ do
  let main' = corpusMain corpus
      cases = arrayField "cases" main'
      groups = nub (map (textField "group") cases)
      environments = case field "environments" main' of
        Just (Object envs) -> [(name, [(k, decodeCorpusJson v) | Array [String k, v] <- xs]) | (name, Array xs) <- envs]
        _ -> []
  describe "expression cases" $
    forM_ groups $ \group ->
      it (T.unpack group) $
        checkAll
          [ (label c, checkCase environments c)
          | c <- cases
          , textField "group" c == group
          ]
  it "free variables (Petrus free_variables)" $
    checkAll [(label c, checkFree c) | c <- arrayField "free_variables" main']
  it "operator cross product" $
    checkAll [(label c, checkOutcome [] c) | c <- arrayField "cases" (corpusOperators corpus)]
  describe "Petrus adapter" $
    forM_ (zip [0 :: Int ..] (arrayField "petrus" main')) $ \(i, c) ->
      it (show i <> " " <> T.unpack (textField "kind" c) <> " " <> show (textField "expr" c)) $
        checkAll (checkPetrus c)
  where
    label c = T.pack (show (textField "expr" c))

-- | Parse result and, when the expression parses, its evaluation outcome.
checkCase :: [(Text, [(Text, Json)])] -> Json -> Maybe String
checkCase environments c =
  let source = textField "expr" c
   in case (parseCel' source, field "parse_error" c) of
        (Left err, Just expected) ->
          let want = (intField "line" expected, intField "column" expected)
              got = (parseErrorLine err, parseErrorColumn err)
           in if want == got then Nothing else Just ("parse error at " <> show got <> ", expected " <> show want)
        (Left err, Nothing) -> Just ("unexpected parse error: " <> show err)
        (Right _, Just expected) -> Just ("parsed, expected parse error " <> show expected)
        (Right program, Nothing) ->
          let tree = larkText (toLark (programExpr program))
              environment = fromMaybe [] (lookup (textField "env" c) environments)
           in case field "tree" c of
                Just (String want) | tree /= want -> Just ("tree " <> T.unpack tree <> "\n    expected " <> T.unpack want)
                _ -> case checkFreeList program c of
                  Just problem -> Just problem
                  Nothing -> checkOutcome environment c
  where
    parseCel' = compile
    intField name j = case field name j of
      Just (Int n) -> Just (fromInteger n)
      _ -> Nothing

checkFreeList :: Program -> Json -> Maybe String
checkFreeList program c = case field "free" c of
  Just (Array names) ->
    let want = [n | String n <- names]
        got = Set.toAscList (freeVariables program)
     in if want == got then Nothing else Just ("free variables " <> show got <> ", expected " <> show want)
  _ -> Nothing

checkFree :: Json -> Maybe String
checkFree c = case compile (textField "expr" c) of
  Left err -> Just ("parse error " <> show err)
  Right program -> checkFreeList program c

-- | Compare an evaluation with the recorded outcome.
checkOutcome :: [(Text, Json)] -> Json -> Maybe String
checkOutcome environment c = case compile (textField "expr" c) of
  Left err -> case field "parse_error" c of
    Just _ -> Nothing
    Nothing -> Just ("unexpected parse error: " <> show err)
  Right program -> compareResult (evaluateJson program environment) c

compareResult :: Either Exc Value -> Json -> Maybe String
compareResult result c = case (result, field "value" c, field "cel_error" c, field "py_error" c) of
  (Right v, Just (String want), _, _) ->
    let wantTruthy = field "truthy" c
        gotTruthy = Bool (truthy v)
     in if valueRepr v /= want
          then Just ("value " <> T.unpack (valueRepr v) <> "\n    expected " <> T.unpack want)
          else case wantTruthy of
            Just (Bool b) | Bool b /= gotTruthy -> Just ("truthiness " <> show (truthy v) <> ", expected " <> show b)
            _ -> Nothing
  (Left ex, Nothing, _, _) | matchesError ex c -> Nothing
  _ -> Just ("got " <> describeResult result <> "\n    expected " <> T.unpack (expectedText c))

-- | Does a raised exception match the recorded one, rendering and all?
--
-- * @cel_error@: the whole @repr()@ of the @CELEvalError@;
-- * @cel_error_args@ with @repr_raises@: the @repr()@ itself raised (celpy's
--   @tree_dump@), so the arguments and the raised error are compared;
-- * @py_error@: the class name, @str()@ and @repr()@.
matchesError :: Exc -> Json -> Bool
matchesError ex c = case (ex, field "cel_error" c, field "cel_error_args" c, field "py_error" c) of
  (CelExc _, Just (String want), _, _) -> either (const False) (== want) (excReprStrict ex)
  (CelExc e, _, Just (String args), _) ->
    let raised = either (\r -> excClassName' r <> ": " <> excStr r) (const "") (excReprStrict ex)
     in excArgsText e == args && raised == textField "repr_raises" c
  (PyExc cls message _, _, _, Just (String want)) ->
    excClassName cls == want && message == textField "message" c && either (const False) (== textField "repr" c) (excReprStrict ex)
  _ -> False
  where
    excClassName' = \case
      PyExc cls _ _ -> excClassName cls
      CelExc _ -> "CELEvalError"
    excArgsText e = excStr (CelExc e)

describeResult :: Either Exc Value -> String
describeResult = \case
  Right v -> "value " <> T.unpack (valueRepr v)
  Left ex -> "error " <> either (\r -> "(repr raises " <> T.unpack (excRepr r) <> ") " <> T.unpack (excStr ex)) T.unpack (excReprStrict ex)

expectedText :: Json -> Text
expectedText c = case (field "value" c, field "cel_error" c, field "cel_error_args" c, field "py_error" c) of
  (Just (String v), _, _, _) -> "value " <> v
  (_, Just (String e), _, _) -> "error " <> e
  (_, _, Just (String args), _) -> "error (repr raises " <> textField "repr_raises" c <> ") " <> args
  (_, _, _, Just (String _)) -> "error " <> textField "repr" c
  _ -> "?"

-- | A Petrus adapter case: compile once, then evaluate each input.
checkPetrus :: Json -> [(Text, Maybe String)]
checkPetrus c =
  let kind = textField "kind" c
      expression = textField "expr" c
      places = [p | String p <- arrayField "places" c]
      inputs = map decodeCorpusJson (arrayField "inputs" c)
      compiled :: Either Text (Json -> Either Exc Bool)
      compiled = case kind of
        "filter" -> (\f input -> f (tokenData (token input))) <$> compileFilter expression
        "guard" -> (\g input -> g (guardSelections input)) <$> compileGuard expression "approve" places
        _ -> (\f input -> f (queueOf input)) <$> compileCompletion expression places
   in case (compiled, field "compile_error" c) of
        (Left err, Just (String want)) -> [("compile", if cut err == want then Nothing else Just ("compile error " <> show err <> "\n    expected " <> show want))]
        (Left err, _) -> [("compile", Just ("unexpected compile error " <> show err))]
        (Right _, Just want) -> [("compile", Just ("compiled, expected " <> show want))]
        (Right run, Nothing) ->
          [ (T.pack (show i), comparePetrus (run input) expected)
          | (i, input, expected) <- zip3 [0 :: Int ..] inputs (arrayField "results" c)
          ]
  where
    cut text = case T.breakOn "': (" text of
      (prefix, rest) | "invalid CEL" `T.isPrefixOf` text, not (T.null rest) -> prefix <> "': "
      _ -> text
    token = \case
      Array [color, payload] -> TokenJson (case color of String t -> Just t; _ -> Nothing) payload
      other -> TokenJson Nothing other
    tokens = \case
      Array ts -> map token ts
      _ -> []
    selections = \case
      Array groups -> [(p, tokens ts) | Array [String p, ts] <- groups]
      _ -> []
    guardSelections = \case
      Array [consumed, readSelections] -> selections consumed ++ selections readSelections
      _ -> []
    queueOf input name = concat [ts | (p, ts) <- selections input, p == name]

comparePetrus :: Either Exc Bool -> Json -> Maybe String
comparePetrus result expected = case (result, field "value" expected, field "cel_error" expected, field "py_error" expected) of
  (Right b, Just (Bool want), _, _) | b == want -> Nothing
  (Left ex, Nothing, _, _) | matchesError ex expected -> Nothing
  _ ->
    Just
      ( "got " <> either (describeResult . Left) (\b -> "value " <> show b) result <> "\n    expected "
          <> show expected
      )
