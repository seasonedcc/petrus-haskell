-- | Tokens, token queues, and markings (@petrus.impetus.petrinet.marking@).
--
-- * 'Token' — a colored token: at most one color plus its structured data.
-- * 'TokenQueue' — the tokens at one place, FIFO order, each paired with its
--   recorded entry instant, durable queue identity, and lifecycle scope. The
--   one home of queue semantics: front-most-equal-occurrence removal, and
--   positions that index tokens and entry instants alike.
-- * 'Marking' — the immutable distribution of tokens across places.
--
-- Everything here is a value: firing is a function from marking to marking,
-- and replaying recorded movements over empty queues rebuilds state.
module Petrus.Impetus.Petrinet.Marking
  ( -- * Tokens
    Token (..)
  , black
  , token
  , isBlack
  , reprToken
  , reprTokens
    -- * Token queues
  , TokenQueue
  , QueueEntry (..)
  , emptyQueue
  , queueFromEntries
  , queueFromPairs
  , timeBlind
  , queueEntries
  , queueTokens
  , queueInstants
  , queueIdentities
  , queueScopes
  , queueLength
  , queueNull
  , queueIndex
  , queueSlice
  , depositEntry
  , depositToken
  , selectedOccurrences
  , removeTokens
  , removeExact
  , discardIdentities
  , admittedBy
  , reprQueue
    -- * Markings
  , Marking
  , emptyMarking
  , markingFromList
  , markingToList
  , fromCounts
  , placeTokens
  , consume
  , deposit
  , counts
  , markingNull
  , markingPlaces
  ) where

import Control.DeepSeq (NFData (..))
import Data.Foldable (toList)
import Data.Maybe (isNothing)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Internal.OMap (OMap)
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Internal.Repr
import Petrus.Impetus.Petrinet.Schema (Color, Instant, NetPath, netPathText)
import Petrus.Impetus.Scope (LifecycleScope)
import Petrus.Json (Json (..))

-- ---------------------------------------------------------------------------
-- Tokens

-- | A colored token: one color and its data. Color 'Nothing' is the black
-- token. The reference admits any Python object as data; every durable
-- spelling of a token is JSON, so the Haskell token carries a 'Json' value
-- (compared with Python's equality, so @1 == 1.0@ as in the reference).
data Token = Token
  { color :: Maybe Color
  , payload :: Json
  }
  deriving stock (Eq)

instance Show Token where
  show = T.unpack . reprToken

instance NFData Token where
  rnf (Token c d) = rnf c `seq` rnf d

-- | The black token — control flow with no data.
black :: Token
black = Token Nothing Null

-- | A token of the given color carrying data.
token :: Color -> Json -> Token
token c = Token (Just c)

isBlack :: Token -> Bool
isBlack t = isNothing t.color

-- | The reference's @repr(token)@, which its diagnostics embed.
reprToken :: Token -> Text
reprToken t = case t.color of
  Nothing -> "Token.black()"
  Just c -> "Token(" <> pyStr c <> ", " <> pyJson t.payload <> ")"

-- | @repr@ of a tuple of tokens.
reprTokens :: [Token] -> Text
reprTokens = pyTuple . map reprToken

-- ---------------------------------------------------------------------------
-- Token queues

-- | One queue position: the token, its recorded entry instant ('Nothing'
-- for a time-blind queue), its durable occurrence identity, and its
-- lifecycle provenance.
data QueueEntry = QueueEntry
  { token :: Token
  , instant :: Maybe Instant
  , identity :: Maybe Int
  , scope :: Maybe LifecycleScope
  }
  deriving stock (Show)

instance NFData QueueEntry where
  rnf (QueueEntry t i n s) = rnf t `seq` rnf i `seq` rnf n `seq` s `seq` ()

-- | The tokens at one place, FIFO order, each paired with its entry instant,
-- identity, and scope. Not a set: duplicates are legal and order is
-- significant. Equality compares the token and instant halves only, as the
-- reference's does; identities and scopes are inspected explicitly.
newtype TokenQueue = TokenQueue (Seq QueueEntry)

instance Eq TokenQueue where
  a == b = queueTokens a == queueTokens b && queueInstants a == queueInstants b

instance Show TokenQueue where
  show = T.unpack . reprQueue

instance NFData TokenQueue where
  rnf (TokenQueue s) = rnf s

-- | The reference's @repr(queue)@: token and instant halves only.
reprQueue :: TokenQueue -> Text
reprQueue q =
  "TokenQueue(["
    <> T.intercalate ", " ["(" <> reprToken e.token <> ", " <> maybe "None" pyInt e.instant <> ")" | e <- toList (queueEntries q)]
    <> "])"

emptyQueue :: TokenQueue
emptyQueue = TokenQueue Seq.empty

queueFromEntries :: [QueueEntry] -> TokenQueue
queueFromEntries = TokenQueue . Seq.fromList

-- | A queue of @(token, instant)@ pairs without identities or scopes.
queueFromPairs :: [(Token, Instant)] -> TokenQueue
queueFromPairs pairs = queueFromEntries [QueueEntry t (Just i) Nothing Nothing | (t, i) <- pairs]

-- | A queue over the token half alone — every entry instant unrecorded
-- (never the epoch): the spelling for time-free queue work.
timeBlind :: Foldable f => f Token -> TokenQueue
timeBlind tokens = TokenQueue (Seq.fromList [QueueEntry t Nothing Nothing Nothing | t <- toList tokens])

queueEntries :: TokenQueue -> Seq QueueEntry
queueEntries (TokenQueue s) = s

-- | The token half, front to back.
queueTokens :: TokenQueue -> Seq Token
queueTokens (TokenQueue s) = fmap (.token) s

-- | The entry-instant half, position-aligned with the tokens.
queueInstants :: TokenQueue -> Seq (Maybe Instant)
queueInstants (TokenQueue s) = fmap (.instant) s

queueIdentities :: TokenQueue -> Seq (Maybe Int)
queueIdentities (TokenQueue s) = fmap (.identity) s

queueScopes :: TokenQueue -> Seq (Maybe LifecycleScope)
queueScopes (TokenQueue s) = fmap (.scope) s

queueLength :: TokenQueue -> Int
queueLength (TokenQueue s) = Seq.length s

queueNull :: TokenQueue -> Bool
queueNull (TokenQueue s) = Seq.null s

queueIndex :: TokenQueue -> Int -> Maybe Token
queueIndex (TokenQueue s) position = (.token) <$> Seq.lookup position s

-- | @queue[start:stop]@ for non-negative bounds.
queueSlice :: Int -> Int -> TokenQueue -> TokenQueue
queueSlice start stop (TokenQueue s) = TokenQueue (Seq.take (stop - start) (Seq.drop start s))

-- | A new queue with the entry appended to the back.
depositEntry :: QueueEntry -> TokenQueue -> TokenQueue
depositEntry e (TokenQueue s) = TokenQueue (s |> e)

-- | A new queue with a token entered at an instant, without identity/scope.
depositToken :: Token -> Instant -> TokenQueue -> TokenQueue
depositToken t i = depositEntry (QueueEntry t (Just i) Nothing Nothing)

-- | Identify the front-most equal occurrences selected by a token-value
-- binding; 'Left' carries the first token the queue does not hold.
selectedOccurrences :: [Token] -> TokenQueue -> Either Token [(Maybe Int, Maybe LifecycleScope)]
selectedOccurrences tokens (TokenQueue s) = go s tokens
  where
    go _ [] = Right []
    go remaining (t : rest) = case Seq.findIndexL (\e -> e.token == t) remaining of
      Nothing -> Left t
      Just position -> do
        let e = Seq.index remaining position
        others <- go (Seq.deleteAt position remaining) rest
        Right ((e.identity, e.scope) : others)

-- | Remove each token's front-most equal occurrence, in request order, so the
-- rest keeps its queue order. 'Left' carries the first token not present
-- (the reference's @TokenNotPresent@); no partial removal is observable.
removeTokens :: [Token] -> TokenQueue -> Either Token TokenQueue
removeTokens tokens (TokenQueue s) = TokenQueue <$> go s tokens
  where
    go remaining [] = Right remaining
    go remaining (t : rest) = case Seq.findIndexL (\e -> e.token == t) remaining of
      Nothing -> Left t
      Just position -> go (Seq.deleteAt position remaining) rest

-- | Remove exact occurrences: each token must match an entry with the paired
-- identity. 'Left' carries the reference's message.
removeExact :: [(Token, Int)] -> TokenQueue -> Either Text TokenQueue
removeExact pairs (TokenQueue s) = TokenQueue <$> go s pairs
  where
    go remaining [] = Right remaining
    go remaining ((t, i) : rest) = case Seq.findIndexL (\e -> e.token == t && e.identity == Just i) remaining of
      Nothing -> Left ("cannot remove " <> reprToken t <> ": token not present")
      Just position -> go (Seq.deleteAt position remaining) rest

-- | Remove the exact durable occurrences, failing if any is absent.
discardIdentities :: [Int] -> TokenQueue -> Either Text TokenQueue
discardIdentities identities (TokenQueue s) = TokenQueue <$> go s identities
  where
    go remaining [] = Right remaining
    go remaining (i : rest) = case Seq.findIndexL (\e -> e.identity == Just i) remaining of
      Nothing -> Left ("cannot discard queue entry " <> pyInt i <> ": identity not present")
      Just position -> go (Seq.deleteAt position remaining) rest

-- | The queue positions of the tokens the judgment accepts, front-to-back:
-- all of them, or the first @limit@. Positions rather than tokens, because a
-- selection's positions also index the entry instants. The judgment may fail
-- per token; 'admittedBy' threads it through a monad so diagnostics can be
-- collected. A non-positive limit is refused, as in the reference.
admittedBy :: Monad m => (Token -> m Bool) -> Maybe Int -> TokenQueue -> m (Either Text [Int])
admittedBy admits limit (TokenQueue s) = case limit of
  Just n | n < 1 -> pure (Left ("admitted_by requires a positive limit (or None for all), got " <> pyInt n))
  _ -> Right . reverse <$> scan 0 0 [] (toList s)
  where
    scan _ _ acc [] = pure acc
    scan position found acc (e : rest) = do
      ok <- admits e.token
      if ok
        then
          let found' = found + 1
              acc' = position : acc
           in if Just found' == limit then pure acc' else scan (position + 1) found' acc' rest
        else scan (position + 1) found acc rest

-- ---------------------------------------------------------------------------
-- Markings

-- | Immutable distribution of tokens across places. Sparse (empty places
-- are absent); places iterate in first-deposit order, as the reference's
-- dict does, because that order reaches History through the initial
-- marking. Equality ignores order.
newtype Marking = Marking (OMap NetPath (Seq Token))
  deriving stock (Eq)

instance Show Marking where
  show (Marking m) =
    T.unpack ("Marking({" <> T.intercalate ", " [netPathText p <> ": " <> pyInt (Seq.length q) | (p, q) <- OMap.toList m] <> "})")

instance NFData Marking where
  rnf (Marking m) = rnf m

emptyMarking :: Marking
emptyMarking = Marking OMap.empty

-- | @Marking({place: tokens, ...})@: empty queues are dropped; a repeated
-- place keeps its first position and its last tokens (dict-literal rules).
markingFromList :: [(NetPath, [Token])] -> Marking
markingFromList pairs =
  Marking (OMap.fromList [(p, Seq.fromList ts) | (p, ts) <- dedupeLast pairs, not (null ts)])
  where
    -- A later empty value for a repeated key removes it, as a dict
    -- comprehension filtered on the final value does.
    dedupeLast xs =
      let final = OMap.fromList xs
       in [(p, OMap.findWithDefault [] p final) | p <- OMap.keys final]

-- | @(place, tokens)@ for each non-empty place, in marking order.
markingToList :: Marking -> [(NetPath, [Token])]
markingToList (Marking m) = [(p, toList q) | (p, q) <- OMap.toList m]

-- | The non-empty places, in marking order.
markingPlaces :: Marking -> [NetPath]
markingPlaces (Marking m) = OMap.keys m

-- | A marking of black tokens from @{place: count}@.
fromCounts :: [(NetPath, Int)] -> Marking
fromCounts pairs = markingFromList [(p, replicate n black) | (p, n) <- pairs]

-- | The FIFO queue at a place (empty if absent).
placeTokens :: NetPath -> Marking -> Seq Token
placeTokens p (Marking m) = OMap.findWithDefault Seq.empty p m

-- | Remove exactly the selected tokens from a place's queue, each its
-- front-most equal occurrence. A consume that silently under-delivers would
-- be a footgun, so an absent token is an error.
consume :: NetPath -> [Token] -> Marking -> Either Text Marking
consume p tokens (Marking m) =
  case removeTokens tokens (timeBlind (OMap.findWithDefault Seq.empty p m)) of
    Left missing -> Left ("cannot consume " <> reprToken missing <> " from " <> netPathText p <> ": token not present")
    Right remaining
      | queueNull remaining -> Right (Marking (OMap.delete p m))
      | otherwise -> Right (Marking (OMap.insert p (queueTokens remaining) m))

-- | Append a token to a place's queue.
deposit :: NetPath -> Token -> Marking -> Marking
deposit p t (Marking m) = Marking (OMap.alter (Just . maybe (Seq.singleton t) (|> t)) p m)

-- | Token count per non-empty place, in marking order.
counts :: Marking -> [(NetPath, Int)]
counts (Marking m) = [(p, Seq.length q) | (p, q) <- OMap.toList m]

-- | Whether no place holds a token (@not marking@).
markingNull :: Marking -> Bool
markingNull (Marking m) = OMap.null m
