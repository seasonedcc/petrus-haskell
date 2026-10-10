-- | Authoring shorthands shared by the loop modules: each mirrors one
-- reference idiom, and each lays its arcs down in the reference's order.
module Hamsterdan.Readiness.NetV5.Wiring
  ( place
  , fold
  , gate
  , door
  , inhibit
  , filtered
  , inhibitFiltered
  , seedToken
  , celFilter
  ) where

import Control.Monad (void)
import Data.Text (Text)
import Hamsterdan.Contracts.Codec (Contract, colorOf, dump)
import Hamsterdan.Readiness.NetV5.Folding (Fold)
import Petrus.Impetus.Dsl hiding (colorOf)
import Petrus.Impetus.Petrinet (Token (..))

-- | @s.loop.p.name(Color)@.
place :: Text -> Color -> Author s ()
place path c = void (p path >>= color c)

-- | @(inputs) >> loop.t.name(handler=petri_handler(fn)) >> (outputs)@.
fold :: Text -> Text -> Fold -> [Text] -> [Text] -> Author s ()
fold path name implementation ins outs = do
  sources <- mapM p ins
  node <- t path >>= configure [handler (petriHandler name implementation)]
  targets <- mapM p outs
  void (sources ~> node ~> targets)

-- | @(inputs) >> loop.t.name(handler="symbol") >> (outputs)@.
gate :: Text -> Text -> [Text] -> [Text] -> Author s ()
gate path symbol ins outs = do
  sources <- mapM p ins
  node <- t path >>= configure [handler (handlerSymbol symbol)]
  targets <- mapM p outs
  void (sources ~> node ~> targets)

-- | @net.t.door >> place@: an ingress door.
door :: Text -> Text -> Author s ()
door name target = void (t name ~> p target)

-- | @place >> arc.inhibit() >> transition@.
inhibit :: Text -> Text -> Author s ()
inhibit source target = void (p source ~> inhibitArc ~> t target)

-- | @place >> arc(filter=Cel(...)) >> transition@ (the arc only).
filtered :: Text -> Text -> Text -> Author s ()
filtered source expression target = void (p source ~> arc {arcFilter = Just (celFilter expression)} ~> t target)

-- | @place >> arc.inhibit(filter=Cel(...)) >> transition@.
inhibitFiltered :: Text -> Text -> Text -> Author s ()
inhibitFiltered source expression target =
  void (p source ~> inhibitArc {arcFilter = Just (celFilter expression)} ~> t target)

celFilter :: Text -> FilterDeclaration
celFilter = FilterCel . unsafeCel

-- | @Token(Color, value.dump())@.
seedToken :: forall a. (Contract a) => a -> Token
seedToken value = Token (Just (colorOf value)) (dump value)
