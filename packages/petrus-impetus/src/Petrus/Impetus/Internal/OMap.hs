-- | An insertion-ordered finite map.
--
-- The reference keeps several of its states in Python dicts, whose iteration
-- order is insertion order, and some of those orders reach the wire: an
-- initial marking's places become @TokensInitialized@ records (and mint queue
-- identities) in the marking's order. An 'OMap' keeps that order exactly —
-- re-inserting an existing key keeps its position, deleting and re-inserting
-- moves it to the back, as a dict does — while lookups stay logarithmic.
-- Equality ignores order, like dict equality.
module Petrus.Impetus.Internal.OMap
  ( OMap
  , empty
  , singleton
  , fromList
  , toList
  , keys
  , elems
  , lookup
  , findWithDefault
  , member
  , insert
  , insertWith
  , adjust
  , alter
  , delete
  , size
  , null
  , toMap
  , mapValues
  ) where

import Control.DeepSeq (NFData (..))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Prelude hiding (lookup, null)

-- | Entries carry the stamp of their first insertion; 'toList' orders by it.
data OMap k v = OMap (Map k (Int, v)) Int

instance (Eq k, Eq v) => Eq (OMap k v) where
  OMap a _ == OMap b _ = Map.map snd a == Map.map snd b

instance (Show k, Show v) => Show (OMap k v) where
  show m = "fromList " ++ show (toList m)

instance (NFData k, NFData v) => NFData (OMap k v) where
  rnf (OMap m n) = rnf m `seq` rnf n

empty :: OMap k v
empty = OMap Map.empty 0

singleton :: k -> v -> OMap k v
singleton k v = OMap (Map.singleton k (0, v)) 1

-- | Build from pairs with dict-literal semantics: a repeated key keeps its
-- first position and its last value.
fromList :: Ord k => [(k, v)] -> OMap k v
fromList = foldl (\m (k, v) -> insert k v m) empty

toList :: OMap k v -> [(k, v)]
toList (OMap m _) = [(k, v) | (k, (_, v)) <- sortOn (fst . snd) (Map.toList m)]

keys :: OMap k v -> [k]
keys = map fst . toList

elems :: OMap k v -> [v]
elems = map snd . toList

lookup :: Ord k => k -> OMap k v -> Maybe v
lookup k (OMap m _) = snd <$> Map.lookup k m

findWithDefault :: Ord k => v -> k -> OMap k v -> v
findWithDefault d k m = maybe d id (lookup k m)

member :: Ord k => k -> OMap k v -> Bool
member k (OMap m _) = Map.member k m

-- | Insert or replace; a present key keeps its position.
insert :: Ord k => k -> v -> OMap k v -> OMap k v
insert k v (OMap m n) = case Map.lookup k m of
  Just (stamp, _) -> OMap (Map.insert k (stamp, v) m) n
  Nothing -> OMap (Map.insert k (n, v) m) (n + 1)

-- | Combine with the present value (@f new old@), or insert at the back.
insertWith :: Ord k => (v -> v -> v) -> k -> v -> OMap k v -> OMap k v
insertWith f k v (OMap m n) = case Map.lookup k m of
  Just (stamp, old) -> OMap (Map.insert k (stamp, f v old) m) n
  Nothing -> OMap (Map.insert k (n, v) m) (n + 1)

adjust :: Ord k => (v -> v) -> k -> OMap k v -> OMap k v
adjust f k (OMap m n) = OMap (Map.adjust (fmap f) k m) n

-- | Alter in place; a deleted key loses its position.
alter :: Ord k => (Maybe v -> Maybe v) -> k -> OMap k v -> OMap k v
alter f k om@(OMap m n) = case Map.lookup k m of
  Just (stamp, old) -> case f (Just old) of
    Just new -> OMap (Map.insert k (stamp, new) m) n
    Nothing -> OMap (Map.delete k m) n
  Nothing -> case f Nothing of
    Just new -> OMap (Map.insert k (n, new) m) (n + 1)
    Nothing -> om

delete :: Ord k => k -> OMap k v -> OMap k v
delete k (OMap m n) = OMap (Map.delete k m) n

size :: OMap k v -> Int
size (OMap m _) = Map.size m

null :: OMap k v -> Bool
null (OMap m _) = Map.null m

-- | The key-sorted view.
toMap :: OMap k v -> Map k v
toMap (OMap m _) = Map.map snd m

mapValues :: (v -> w) -> OMap k v -> OMap k w
mapValues f (OMap m n) = OMap (Map.map (fmap f) m) n
