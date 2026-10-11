-- | Round-trip properties of the Net-definition and Net-document wire
-- formats over generated nets: every valid net projects to a canonical
-- definition that is a fixed point of serialize/parse and of compile/project,
-- and a document's identity never depends on its view.
module Petrus.Impetus.NetDefinitionPropertiesSpec (spec, nets, nodePaths, coordinate) where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.NetDocument
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (np)
import Test.Hspec
import Test.QuickCheck

-- | Segments that exercise code-point (not UTF-16) ordering.
segments :: [Text]
segments = ["a", "b", "z1", "é", "\xe000", "😀", "work"]

pathsUnder :: Text -> Gen [NetPath]
pathsUnder root = do
  n <- chooseInt (1, 4)
  names <- vectorOf n (do k <- chooseInt (1, 2); vectorOf k (elements segments))
  pure (map (np . T.intercalate "." . (root :)) (nub names))

expression :: Gen Text
expression = elements ["true", "size(p.a) > 0", "token.n >= 1", "\"é\" == \"é\""]

symbol :: Gen Text
symbol = elements ["ready", "visible", "worker", "done_when"]

genNet :: Gen (Maybe Net)
genNet = do
  placePaths <- pathsUnder "p"
  transitionPaths <- pathsUnder "t"
  places' <- mapM (\p -> oneof [pure (place p), coloredPlace p <$> elements ["Work", "Done"]]) placePaths
  inputArcs <- fmap concat . mapM (\t -> listOf1' 2 (inputArc placePaths t)) =<< sublistOf transitionPaths
  outputArcs <- fmap concat . mapM (\t -> listOf1' 2 (outputArc placePaths t)) =<< sublistOf transitionPaths
  let fed t = any (\a -> a.target == t) inputArcs
  transitions' <- mapM (\t -> genTransition (fed t) t) transitionPaths
  arcs' <- shuffle (inputArcs <> outputArcs)
  completion' <- oneof [pure Nothing, Just . CompletionSymbol <$> symbol, Just . CompletionCel . unsafeCel <$> expression]
  name' <- oneof [pure Nothing, Just <$> elements ["generated", "réseau", "😀-net"]]
  pure $ either (const Nothing) Just $ mkNet NetSpec {places = places', transitions = transitions', arcs = arcs', completion = completion', name = name'}
  where
    listOf1' k g = do n <- chooseInt (1, k); vectorOf n g
    inputArc placePaths t = do
      p <- elements placePaths
      mode' <- elements [Consume, Read, Inhibit]
      weight' <- chooseInt (1, 3)
      filter' <- oneof [pure Nothing, Just . FilterSymbol <$> symbol, Just . FilterCel . unsafeCel <$> expression]
      pure Arc {source = p, target = t, mode = mode', weight = weight', color = Nothing, filter = if mode' == Inhibit then Nothing else filter'}
    outputArc placePaths t = do
      p <- elements placePaths
      weight' <- chooseInt (1, 2)
      pure Arc {source = t, target = p, mode = Consume, weight = weight', color = Nothing, filter = Nothing}
    genTransition fed t = do
      handler' <- oneof [pure Nothing, Just . HandlerSymbol <$> symbol, pure (Just (HandlerAnonymous anonymous))]
      guards' <-
        if fed
          then listOf (oneof [GuardSymbol <$> symbol, GuardCel . unsafeCel <$> expression, pure (GuardAnonymous anonymous)]) >>= pure . take 3
          else pure []
      timers' <-
        if fed
          then fmap (take 2) (listOf (oneof [Delay . IntNumber <$> chooseInteger (-5, 50), Until . IntNumber <$> chooseInteger (-5, 50)]))
          else pure []
      pure Transition {path = t, handler = handler', guards = guards', timers = timers'}

nets :: Gen Net
nets = genNet `suchThatMap` id

-- | Node paths of a net, for views.
nodePaths :: Net -> [Text]
nodePaths net = map netPathText (netPlaceOrder net <> netTransitionOrder net)

coordinate :: Gen Number
coordinate = oneof [IntNumber <$> chooseInteger (-1000, 1000), FloatNumber . (/ 4) . fromInteger <$> chooseInteger (-4000, 4000)]

spec :: Spec
spec = describe "Net definition and document round-trip properties" $ do
  it "generates mostly valid nets" $
    property $ forAll (vectorOf 50 genNet) $ \generated ->
      length (filter (/= Nothing) (map (fmap (const ())) generated)) >= 10

  it "projects to a definition that is a fixed point of serialize and parse" $
    property $ forAll nets $ \net -> either (\e -> counterexample (T.unpack e) False) id $ do
      document <- projectNetDefinition net
      bytes <- serializeNetDefinition document
      parsed <- parseNetDefinition bytes
      viaText <- parseNetDefinitionText (TE.decodeUtf8 bytes)
      reserialized <- serializeNetDefinition parsed
      pure (parsed === document .&&. viaText === document .&&. reserialized === bytes)

  it "compiles and projects back to the same definition" $
    property $ forAll nets $ \net -> either (\e -> counterexample (T.unpack e) False) id $ do
      document <- projectNetDefinition net
      compiled <- compileNetDefinition document
      projected <- projectNetDefinition compiled
      fromJson <- netDefinitionFromJson (netDefinitionToJson document)
      pure (projected === document .&&. fromJson === document .&&. arcUris compiled === arcUris net)

  it "round-trips documents and never lets the view change the identity" $
    property $ forAll nets $ \net -> forAll (sublistOf (nodePaths net)) $ \nodes ->
      forAll (vectorOf (length nodes) ((,) <$> coordinate <*> coordinate)) $ \xys ->
        either (\e -> counterexample (T.unpack e) False) id $ do
          plain <- projectNetDocument net Nothing Nothing
          arranged <- projectNetDocument net (Just (zip nodes xys)) Nothing
          bytes <- serializeNetDocument arranged
          parsed <- parseNetDocument bytes
          reserialized <- serializeNetDocument parsed
          plainIdentity <- definitionIdentity plain
          arrangedIdentity <- definitionIdentity arranged
          pure (parsed === arranged .&&. reserialized === bytes .&&. plainIdentity === arrangedIdentity)
