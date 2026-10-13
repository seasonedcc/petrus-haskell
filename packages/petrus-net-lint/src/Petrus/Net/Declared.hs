-- | What a net's author declares beside its definition, for the lint and the
-- behavioral checks, and the lint's waivers (@README.md@).
--
-- A net's definition shows its places, transitions and arcs, but not what a
-- handler does with them: whether a transition with two output places fills
-- both, or one of them. So the author declares each transition's outcomes,
-- in @NET.declared.json@:
--
-- > { "v": 1,
-- >   "initial": {"key-ring": 1},
-- >   "outcomes": {
-- >     "revoke": [
-- >       {"name": "recorded", "when": "success", "puts": {"destroying": 1}},
-- >       {"name": "refused", "when": "success", "puts": {"key-ring": 1}},
-- >       {"name": "failed", "when": "failure", "puts": {"key-ring": 1}}]},
-- >   "ingress": [],
-- >   "final_places": [],
-- >   "final_markings": [{"key-ring": 1}],
-- >   "laws": [{"name": "the key ring", "weights": {"key-ring": 1, "destroying": 1, "@revoke": 1}, "total": 1}],
-- >   "scenarios": [{"name": "two requests", "deliver": {"request": 2}}] }
--
-- A transition with a @failure@ outcome runs an Activity, and a law may
-- count its firings in flight as @\@name@. A scenario says how many times a
-- caller delivers to each source transition or ingress place, for the
-- behavioral checks. A transition with no declared
-- outcomes fills every output place once per firing, by its arcs' weights.
-- Every member but @v@ may be left out.
--
-- A waiver, in @NET.waivers.json@, accepts one finding: its rule, where,
-- why in a sentence, and the decision or review that accepted it.
module Petrus.Net.Declared
  ( Declared (..)
  , Outcome (..)
  , When (..)
  , Law (..)
  , Scenario (..)
  , noDeclarations
  , parseDeclared
  , Waiver (..)
  , parseWaivers
  ) where

import Control.Monad (forM, unless)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Json qualified as J

-- | Whether an outcome follows the Activity's success or its failure. A
-- pure handler's outcomes are all successes.
data When = OnSuccess | OnFailure
  deriving stock (Eq, Ord, Show)

-- | One way a transition's firing can end: what it puts in each place.
data Outcome = Outcome
  { name :: Text
  , when :: When
  , puts :: Map Text Int
  }
  deriving stock (Eq, Show)

-- | A weighted sum of tokens that every reachable marking keeps.
data Law = Law
  { name :: Text
  , weights :: Map Text Int
  , total :: Int
  }
  deriving stock (Eq, Show)

-- | A small run for the behavioral checks: how many times a caller
-- delivers to each source transition or ingress place.
data Scenario = Scenario
  { name :: Text
  , deliver :: Map Text Int
  }
  deriving stock (Eq, Show)

data Declared = Declared
  { initial :: Map Text Int
  -- ^ How many tokens each place starts with.
  , outcomes :: Map Text [Outcome]
  , ingress :: [Text]
  -- ^ Places a caller fills from outside the net.
  , finalPlaces :: [Text]
  -- ^ Places a token may rest in for good.
  , finalMarkings :: [Map Text Int]
  -- ^ The markings the net may stop in, with every other place empty.
  , laws :: [Law]
  , scenarios :: [Scenario]
  }
  deriving stock (Eq, Show)

-- | A net that declares nothing.
noDeclarations :: Declared
noDeclarations = Declared {initial = Map.empty, outcomes = Map.empty, ingress = [], finalPlaces = [], finalMarkings = [], laws = [], scenarios = []}

data Waiver = Waiver
  { rule :: Text
  , at :: Text
  , reason :: Text
  , acceptedBy :: Text
  }
  deriving stock (Eq, Show)

-- | Read @NET.declared.json@.
parseDeclared :: ByteString -> Either Text Declared
parseDeclared bytes = do
  members <- document "a net's declarations" ["v", "initial", "outcomes", "ingress", "final_places", "final_markings", "laws", "scenarios"] bytes
  initial <- maybe (Right Map.empty) (counts "initial") (lookup "initial" members)
  outcomes <- maybe (Right Map.empty) outcomesOf (lookup "outcomes" members)
  ingress <- maybe (Right []) (texts "ingress") (lookup "ingress" members)
  finalPlaces <- maybe (Right []) (texts "final_places") (lookup "final_places" members)
  finalMarkings <- maybe (Right []) (list "final_markings" (counts "a final marking")) (lookup "final_markings" members)
  laws <- maybe (Right []) (list "laws" lawOf) (lookup "laws" members)
  scenarios <- maybe (Right []) (list "scenarios" scenarioOf) (lookup "scenarios" members)
  pure Declared {initial, outcomes, ingress, finalPlaces, finalMarkings, laws, scenarios}
  where
    outcomesOf = \case
      Object byTransition -> Map.fromList <$> forM byTransition (\(transition, value) -> (transition,) <$> list ("the outcomes of " <> transition) (outcomeOf transition) value)
      _ -> Left "\"outcomes\" maps each transition to its outcomes"
    outcomeOf transition value = do
      members <- object ("an outcome of " <> transition) ["name", "when", "puts"] value
      name <- text "name" members
      when <-
        text "when" members >>= \case
          "success" -> Right OnSuccess
          "failure" -> Right OnFailure
          other -> Left ("an outcome's \"when\" is \"success\" or \"failure\", not \"" <> other <> "\"")
      puts <- maybe (Right Map.empty) (counts ("what " <> transition <> "'s outcome " <> name <> " puts")) (lookup "puts" members)
      pure Outcome {name, when, puts}
    lawOf value = do
      members <- object "a law" ["name", "weights", "total"] value
      name <- text "name" members
      weights <- maybe (Left ("the law " <> name <> " has no weights")) (counts ("the weights of " <> name)) (lookup "weights" members)
      total <- case lookup "total" members of
        Just (Int n) -> Right (fromInteger n)
        _ -> Left ("the law " <> name <> " has no whole \"total\"")
      pure Law {name, weights, total}
    scenarioOf value = do
      members <- object "a scenario" ["name", "deliver"] value
      name <- text "name" members
      deliver <- maybe (Right Map.empty) (counts ("what " <> name <> " delivers")) (lookup "deliver" members)
      pure Scenario {name, deliver}

-- | Read @NET.waivers.json@.
parseWaivers :: ByteString -> Either Text [Waiver]
parseWaivers bytes = do
  members <- document "a net's waivers" ["v", "waivers"] bytes
  maybe (Right []) (list "waivers" waiverOf) (lookup "waivers" members)
  where
    waiverOf value = do
      members <- object "a waiver" ["rule", "at", "reason", "accepted_by"] value
      waiver <- Waiver <$> text "rule" members <*> text "at" members <*> text "reason" members <*> text "accepted_by" members
      unless (all (not . T.null . T.strip) [waiver.rule, waiver.at, waiver.reason, waiver.acceptedBy]) $
        Left "a waiver names its rule, where, why, and who accepted it"
      pure waiver

-- A version-1 document's members.
document :: Text -> [Text] -> ByteString -> Either Text [(Text, Json)]
document what allowed bytes = do
  value <- either (Left . ((what <> " isn't JSON: ") <>) . T.pack) Right (J.parseJson J.strictLoads bytes)
  members <- object what allowed value
  case lookup "v" members of
    Just (Int 1) -> Right members
    _ -> Left (what <> " needs \"v\": 1")

-- An object with no member outside @allowed@, so a misspelled one isn't
-- quietly ignored.
object :: Text -> [Text] -> Json -> Either Text [(Text, Json)]
object what allowed = \case
  Object members -> case [key | (key, _) <- members, key `notElem` allowed] of
    [] -> Right members
    unknown -> Left (what <> " has members it doesn't know: " <> T.intercalate ", " unknown)
  _ -> Left (what <> " is an object")

list :: Text -> (Json -> Either Text a) -> Json -> Either Text [a]
list what each = \case
  Array values -> mapM each values
  _ -> Left ("\"" <> what <> "\" is a list")

text :: Text -> [(Text, Json)] -> Either Text Text
text key members = case lookup key members of
  Just (String value) -> Right value
  _ -> Left ("\"" <> key <> "\" is text")

texts :: Text -> Json -> Either Text [Text]
texts what = list what $ \case
  String value -> Right value
  _ -> Left ("\"" <> what <> "\" holds names")

counts :: Text -> Json -> Either Text (Map Text Int)
counts what = \case
  Object members -> Map.fromList <$> forM members (\(key, value) -> case value of
    Int n | n >= 0 -> Right (key, fromInteger n)
    _ -> Left (what <> ": " <> key <> " needs a whole number, at least 0"))
  _ -> Left (what <> " maps places to counts")
