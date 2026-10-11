-- | Tier C's deterministic agent (docs/hamsterdan.md §5.2, tier C step 2):
-- the agent results one real run recorded, answered to a host acting on
-- another repository. The twin of @python/host_seams.CarriedRunner@ and
-- @tape.operation_shape@ / @tape.carry_result@; both hosts of a tier C run
-- take the same recorded tape, so they must answer alike.
module Hamsterdan.E2E.Agents
  ( operationShape
  , carryResult
  , replaceStrings
  , CarriedRunner (..)
  , carriedRunner
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM)
import Data.Char (isDigit)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Contract, renderDecodeError, validate)
import Hamsterdan.Contracts.Codec qualified as Codec
import Hamsterdan.E2E.Replay (raiseRecorded)
import Hamsterdan.E2E.Tape
import Petrus.Json (Json (..))

-- | @tape.operation_shape@: the operation split on @:@, a segment holding
-- @/@ as @<repository>@, 40 lowercase hexadecimal digits as @<sha>@, 64 as
-- @<digest>@, a UUID as @<uuid>@ and ASCII decimal digits as @<n>@.
operationShape :: Text -> Text
operationShape = T.intercalate ":" . map shape . T.splitOn ":"
  where
    shape segment
      | "/" `T.isInfixOf` segment = "<repository>"
      | hex 40 segment = "<sha>"
      | hex 64 segment = "<digest>"
      | uuid segment = "<uuid>"
      | not (T.null segment) && T.all isDigit segment = "<n>"
      | otherwise = segment
    hex n segment = T.length segment == n && T.all (`elem` ("0123456789abcdef" :: String)) segment
    uuid segment =
      let parts = T.splitOn "-" segment
       in map T.length parts == [8, 4, 4, 4, 12] && all (\part -> hex (T.length part) part) parts

-- | @tape.carry_result@: every string the recorded request's @repository@,
-- @head@, @base@ and @ref@ held, replaced in the result by the new
-- request's (longest first), and the result's correlation members set to
-- the new request's.
carryResult :: Json -> Json -> Json -> Json
carryResult recorded request result = case replaceStrings replacements result of
  Object members -> Object [(name, correlated name value) | (name, value) <- members]
  other -> other
  where
    pairs =
      Map.fromList
        [ (old, new)
        | name <- ["repository", "head", "base", "ref"]
        , String old <- [member name recorded]
        , String new <- [member name request]
        , not (T.null old)
        , old /= new
        ]
    replacements = sortOn (\(old, _) -> (Down (T.length old), old)) (Map.toList pairs)
    correlated name value
      | name `elem` correlation, Object fields <- request, Just new <- lookup name fields = new
      | otherwise = value
    correlation = ["kind", "repository", "pull_request", "epoch", "head", "base", "ref"]

-- | Every string in a value with each @(old, new)@ replaced, in order.
replaceStrings :: [(Text, Text)] -> Json -> Json
replaceStrings replacements = go
  where
    go = \case
      String value -> String (foldl (\acc (old, new) -> T.replace old new acc) value replacements)
      Array items -> Array (map go items)
      Object members -> Object [(name, go value) | (name, value) <- members]
      other -> other

type Key = (Text, Text, Integer)

-- | The carried runner and what it saw (@CarriedRunner.log@ and
-- @unknown@).
data CarriedRunner = CarriedRunner
  { runner :: AgentRunner
  , answer :: Text -> Text -> Integer -> Json -> IO Json
  -- ^ @CarriedRunner.answer(kind, operation, attempt, request)@.
  , report :: IO Json
  }

-- | @CarriedRunner(tape)@ over a tape's @agents.jsonl@.
carriedRunner :: Tape -> IO CarriedRunner
carriedRunner tape = do
  keyed <- forM tape.agents $ \record -> (,[record]) <$> keyOf record
  calls <- newIORef (Map.fromListWith (flip (<>)) keyed :: Map Key [Json])
  logged <- newIORef []
  unknown <- newIORef []
  let answer kind operation attempt request = do
        let key = (kind, operationShape operation, attempt)
        recorded <- atomicModifyIORef' calls $ \known -> case Map.lookup key known of
          Just (record : rest) -> (Map.insert key rest known, Just record)
          _ -> (known, Nothing)
        case recorded of
          Nothing -> do
            modifyIORef' unknown (<> [identity kind operation attempt])
            pure $
              Object
                [ ( "error"
                  , Object
                      [ ("class", String "AgentProtocolError")
                      , ("reason", String ("carried: no recorded " <> kind <> " call for " <> operationShape operation <> " attempt " <> T.pack (show attempt)))
                      , ("canceled", Bool False)
                      , ("timed_out", Bool False)
                      , ("result_category", Null)
                      , ("cleanup_category", Null)
                      ]
                  )
                ]
          Just record -> do
            sequence' <- field "seq" record
            modifyIORef' logged (<> [Object (fields (identity kind operation attempt) <> [("seq", sequence')])])
            optionalField "error" record >>= \case
              Just failure -> pure (Object [("error", failure)])
              Nothing -> do
                recordedRequest <- field "request" record
                result <- field "result" record
                pure (Object [("result", carryResult recordedRequest request result)])
      call :: (Contract request, Contract result) => Text -> Text -> request -> Invocation -> IO result
      call kind _ request invocation = do
        answered <- answer kind invocation.operation invocation.attempt (Codec.dump request)
        optionalField "error" answered >>= \case
          Nothing -> field "result" answered >>= either (throwIO . protocolError . ("carried: recorded result refused: " <>) . renderDecodeError) pure . validate
          Just failure -> raiseRecorded failure
      report = do
        known <- readIORef logged
        missing <- readIORef unknown
        pure (Object [("calls", Array known), ("unknown", Array missing)])
  pure
    CarriedRunner
      { runner = AgentRunner {review = call "review", converse = call "converse", code = call "code"}
      , answer
      , report
      }
  where
    keyOf record = (,,) <$> field "kind" record <*> (operationShape <$> field "operation" record) <*> field "attempt" record
    identity kind operation attempt = Object [("kind", String kind), ("operation", String operation), ("attempt", Int attempt)]
    fields = \case
      Object members -> members
      _ -> []
