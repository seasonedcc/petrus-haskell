-- | Helpers shared by the ported specs: Python-object literals, the
-- reference tests' @FakeRunner@ and @completed()@, and assertions on
-- Python values.
module Support
  ( -- * Python objects
    obj
  , str
  , int
  , bool
  , none
  , list
  , at
  , atPath
  , merge
  , setPath
  , shouldEqualPy
  , encoded

    -- * The fake runner
  , Response (..)
  , Fake (..)
  , newFake
  , fakeRunner
  , fakeCalls
  , setResponse
  , getResponse
  , completed
  , operatorWith
  , fixedTemporary
  , throwsOperatorError
  ) where

import Control.Exception (Exception, throwIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Export.Python (PV (..), pyEq)
import Hamsterdan.Operator
import Hamsterdan.Operator.Python (dumpsPlain)
import Test.Hspec

obj :: [(Text, PV)] -> PV
obj = PDict

str :: Text -> PV
str = PStr

int :: Integer -> PV
int = PInt

bool :: Bool -> PV
bool = PBool

none :: PV
none = PNone

list :: [PV] -> PV
list = PList

-- | @value[key]@ for a test value known to be a dict.
at :: Text -> PV -> PV
at key = \case
  PDict members -> maybe (error ("missing key " <> T.unpack key)) id (lookup key members)
  other -> error ("not a dict: " <> show other)

atPath :: [Text] -> PV -> PV
atPath keys value = foldl (flip at) value keys

-- | @left | right@ for dicts.
merge :: PV -> [(Text, PV)] -> PV
merge (PDict members) extra =
  PDict ([(k, maybe v id (lookup k extra)) | (k, v) <- members] <> [(k, v) | (k, v) <- extra, k `notElem` map fst members])
merge other _ = error ("not a dict: " <> show other)

-- | @value[k1][k2]...[kn] = new@.
setPath :: [Text] -> PV -> PV -> PV
setPath [] new _ = new
setPath (key : rest) new value = merge value [(key, setPath rest new (at key value))]

-- | Python @==@.
shouldEqualPy :: PV -> PV -> Expectation
shouldEqualPy actual expected =
  if pyEq actual expected then pure () else expectationFailure ("expected " <> show expected <> "\n but got " <> show actual)

-- | @json.dumps(value)@.
encoded :: PV -> Text
encoded value = either (error . show) id (dumpsPlain value)

-- | A response of the fake runner: a value @completed()@ wraps, or a whole
-- completed process.
data Response = Value PV | Done Completed

-- | @FakeRunner(responses)@.
data Fake = Fake
  { responses :: IORef (Map Text Response)
  , calls :: IORef [([Text], Maybe FilePath)]
  }

newtype UnexpectedCommand = UnexpectedCommand [Text]
  deriving stock (Show)

instance Exception UnexpectedCommand

newFake :: [(Text, Response)] -> IO Fake
newFake initial = Fake <$> newIORef (Map.fromList initial) <*> newIORef []

setResponse :: Fake -> Text -> Response -> IO ()
setResponse fake key value = modifyIORef' fake.responses (Map.insert key value)

getResponse :: Fake -> Text -> IO PV
getResponse fake key =
  Map.lookup key <$> readIORef fake.responses >>= \case
    Just (Value v) -> pure v
    _ -> error ("no value response for " <> T.unpack key)

-- | @FakeRunner.__call__@: record the call and answer by the API path (for
-- @gh api@) or the whole command line.
fakeRunner :: Fake -> Runner
fakeRunner fake command cwd = do
  modifyIORef' fake.calls (<> [(command, cwd)])
  let key = case command of
        "gh" : "api" : path : _ -> path
        _ -> T.unwords command
  Map.lookup key <$> readIORef fake.responses >>= \case
    Just (Done result) -> pure result
    Just (Value value) -> pure (completed value 0)
    Nothing -> throwIO (UnexpectedCommand command)

fakeCalls :: Fake -> IO [([Text], Maybe FilePath)]
fakeCalls fake = readIORef fake.calls

-- | @completed(value, returncode)@.
completed :: PV -> Int -> Completed
completed value code =
  Completed
    { returncode = code
    , stdout = case value of
        PStr s -> s
        other -> encoded other
    , stderr = "sensitive stderr must never be emitted"
    }

-- | The operator with the fake runner and the given delegated digests.
operatorWith :: Runner -> (Text, Text) -> Operator
operatorWith runner (brokerDigest, validatorDigest) =
  Operator
    { runner
    , stamp = defaultStamp
    , withTemporary = defaultWithTemporary
    , brokerDigest
    , validatorDigest
    }
  where
    Operator {stamp = defaultStamp, withTemporary = defaultWithTemporary} = defaultOperator

-- | @TemporaryDirectory = lambda **kwargs: nullcontext(path)@.
fixedTemporary :: FilePath -> WithTemporary
fixedTemporary path = WithTemporary \_ action -> action path

-- | @pytest.raises(OperatorError, match=needle)@.
throwsOperatorError :: Text -> OperatorError -> Bool
throwsOperatorError needle (OperatorError message) = needle `T.isInfixOf` message
