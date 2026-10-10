-- | Fake adapters, fences and request builders shared by the Hands specs
-- (the @Adapter@, @Fence@ and @request@ helpers of the upstream tests).
module Petrus.Agenticus.Hands.Fixtures
  ( Fake (..)
  , newFake
  , fakeAdapter
  , callsOf
  , targetOf
  , Fence
  , newFence
  , setFence
  , modifyFence
  , fenceSource
  , requestWith
  , request
  , orFail
  , digestOf
  ) where

import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Hands.Gateway
import Petrus.Agenticus.Support (setMember)
import Petrus.Json (Json (..))

-- | The upstream @Adapter@ test double: it records every crossing and keeps
-- an in-memory target.  Stages live under @"stage"@ (or
-- @"stage:<call_id>"@ when 'keyedStages' is set, as the conformance test's
-- adapter does), and 'closeOnStage' closes a fence after staging.
data Fake = Fake
  { callLog :: IORef [Text]
  , targetMap :: IORef (Map Text Text)
  , keyedStages :: Bool
  , closeOnStage :: IORef (Maybe Fence)
  , readText :: Text
  , searchMatch :: Text
  }

newFake :: Bool -> Text -> Text -> IO Fake
newFake keyed readValue match = do
  c <- newIORef []
  t <- newIORef Map.empty
  close <- newIORef Nothing
  pure (Fake c t keyed close readValue match)

note :: Fake -> Text -> IO ()
note fake name = modifyIORef' fake.callLog (<> [name])

callsOf :: Fake -> IO [Text]
callsOf fake = readIORef fake.callLog

targetOf :: Fake -> IO (Map Text Text)
targetOf fake = readIORef fake.targetMap

stageKey :: Fake -> Text -> Text
stageKey fake call = if fake.keyedStages then "stage:" <> call else "stage"

orFail :: Either a b -> b
orFail = either (const (error "invalid fixture value")) id

digestOf :: Char -> Text
digestOf c = T.replicate 64 (T.singleton c)

fakeAdapter :: Fake -> HandsAdapter
fakeAdapter fake =
  HandsAdapter
    { read = \_ -> note fake "read" >> pure fake.readText
    , search = \_ _ -> note fake "search" >> pure [fake.searchMatch]
    , shell = \_ _ -> note fake "shell" >> pure (orFail (mkShellOutcome 0 fake.readText "" False))
    , stageWrite = \call path content -> do
        note fake "stage"
        modifyIORef' fake.targetMap (Map.insert (stageKey fake call) content)
        readIORef fake.closeOnStage >>= \case
          Just fence -> modifyFence fence (\f -> callFence False f.aborted f.deadline)
          Nothing -> pure ()
        pure (orFail (mkStagedWrite call path (digestOf 'd')))
    , commitWrite = \staged -> do
        note fake "commit"
        modifyIORef' fake.targetMap $ \t ->
          let key = stageKey fake staged.callId
           in Map.insert staged.path (Map.findWithDefault "" key t) (Map.delete key t)
        pure staged.digest
    , discardWrite = \staged -> do
        note fake "discard"
        modifyIORef' fake.targetMap (Map.delete (stageKey fake staged.callId))
    , runTest = note fake "test" >> pure (orFail (mkTestOutcome True (digestOf 'e')))
    , discardAllStages = do
        t <- readIORef fake.targetMap
        let stages = [k | k <- Map.keys t, k == "stage" || "stage:" `T.isPrefixOf` k]
        writeIORef fake.targetMap (foldr Map.delete t stages)
        pure (length stages)
    }

-- | A mutable @Fence@ whose snapshot is its current value.
newtype Fence = Fence (IORef CallFence)

newFence :: IO Fence
newFence = Fence <$> newIORef (callFence True False 100)

setFence :: Fence -> CallFence -> IO ()
setFence (Fence ref) = writeIORef ref

modifyFence :: Fence -> (CallFence -> CallFence) -> IO ()
modifyFence (Fence ref) = modifyIORef' ref

fenceSource :: Fence -> CallFenceSource
fenceSource (Fence ref) = CallFenceSource (readIORef ref)

-- | The upstream @request(method, params, **changes)@.
requestWith :: Text -> [(Text, Json)] -> [(Text, Json)] -> Json
requestWith method params changes =
  foldl
    (\acc (k, v) -> setMember k v acc)
    ( Object
        [ ("version", Int 1)
        , ("call_id", String "call-1")
        , ("episode_id", String "episode-1")
        , ("attachment_id", String "attachment-1")
        , ("attachment_epoch", Int 1)
        , ("grant_epoch", Int 1)
        , ("method", String method)
        , ("params", Object params)
        ]
    )
    changes

request :: Text -> [(Text, Json)] -> Json
request method params = requestWith method params []
