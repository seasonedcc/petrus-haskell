-- | The differential corpus: every net @differential/dsl_corpus.py@ authors
-- with the reference DSL, authored again with the Haskell DSL
-- ("Petrus.Impetus.Dsl.Corpus"), must produce the same canonical
-- Net-definition v3 bytes, the same authored node and arc order, the same
-- implementation URIs and display names — or the same refusal text.
module Petrus.Impetus.DslCorpusSpec (spec, locate) where

import Control.Monad (filterM, forM_)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.Dsl
import Petrus.Impetus.Dsl.Corpus (corpus)
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.Petrinet.Schema
  ( AnonymousDeclaration (..)
  , Arc (..)
  , GuardDeclaration (..)
  , HandlerDeclaration (..)
  , Transition (..)
  , lookupTransition
  , netArcs
  , netPathText
  , netPlaceOrder
  , netTransitionOrder
  , netUriText
  )
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import System.Directory (doesFileExist)
import Test.Hspec

-- | Find a repository file from the package or the repository root.
locate :: FilePath -> IO FilePath
locate relativePath = do
  let candidates = [relativePath, "packages/petrus-dsl/" <> relativePath]
  found <- filterM doesFileExist candidates
  case found of
    path : _ -> pure path
    [] -> fail ("cannot find " <> relativePath)

verdict :: Either DslError BuiltNet -> Json
verdict = \case
  Left err -> Object [("error", String err.message)]
  Right built ->
    let net = built.net
        definition = case projectNetDefinition net >>= serializeNetDefinition of
          Right bytes -> TE.decodeUtf8 bytes
          Left err -> "<cannot serialize: " <> err <> ">"
        display =
          catMaybes
            [ case lookupTransition at net of
                Just tr ->
                  let names =
                        [ Array [String "handler", maybe Null String name]
                        | Just (HandlerAnonymous (AnonymousDeclaration name)) <- [tr.handler]
                        ]
                          ++ [ Array [String ("guard:" <> T.pack (show i)), maybe Null String name]
                             | (i, GuardAnonymous (AnonymousDeclaration name)) <- zip [0 :: Int ..] tr.guards
                             ]
                   in if null names then Nothing else Just (netPathText at, Array names)
                Nothing -> Nothing
            | at <- netTransitionOrder net
            ]
     in Object
          [ ("definition", String definition)
          , ("places", Array [String (netPathText at) | at <- netPlaceOrder net])
          , ("transitions", Array [String (netPathText at) | at <- netTransitionOrder net])
          , ("arcs", Array [Array [String (netPathText a.source), String (netPathText a.target)] | a <- netArcs net])
          , ("handlers", Array (map String (sort (map netUriText (Map.keys built.handlers)))))
          , ("guards", Array (map String (sort (map netUriText (Map.keys built.guards)))))
          , ("display", Object display)
          ]

spec :: Spec
spec = describe "differential corpus (dsl_corpus.json, from the reference DSL)" $ do
  expected <- runIO $ do
    path <- locate "differential/dsl_corpus.json"
    bytes <- BS.readFile path
    either fail pure (parseJson pythonLoads bytes)
  let cases = case expected of
        Object members -> members
        _ -> []
  it "covers exactly the reference corpus" $
    sort (map fst corpus) `shouldBe` sort (map fst cases)
  forM_ corpus $ \(name, outcome) ->
    it (T.unpack name) $ do
      let reference = lookupMember name expected
          produced = verdict outcome
      case reference of
        Nothing -> expectationFailure "case missing from the corpus"
        Just wanted -> forM_ (keys wanted) $ \key ->
          (key, lookupMember key produced) `shouldBe` (key, lookupMember key wanted)
  where
    keys :: Json -> [Text]
    keys = \case
      Object members -> map fst members
      _ -> []
