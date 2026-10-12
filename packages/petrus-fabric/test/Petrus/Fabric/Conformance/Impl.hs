{-# OPTIONS_GHC -Wno-orphans #-}

-- | The language-neutral conformance harness: one request/answer protocol
-- (JSON objects, see test/interop/conformance_driver.py) spoken by two
-- implementations — the pinned Python reference through that driver, and
-- this repository's Haskell port through an in-process twin. Every
-- conformance check is written once against 'Impl'.
module Petrus.Fabric.Conformance.Impl
  ( -- * Implementations
    Impl (..)
  , Answer (..)
  , withPythonImpl
  , driverPath
    -- * The Haskell twin's building blocks
  , Ops
  , Handles
  , newHandles
  , store
  , fetch
  , haskellImpl
  , arg
  , argText
  , argInt
  , argBool
  , argMaybe
  , argObject
  , typeEnforced
  , stampText
  , parseStamp
    -- * Asserting
  , ok
  , refused
  , refusedWith
  , answerOf
  , obj
  , str
  , int
  , arr
  , member
  , memberText
  , showJson
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (SomeAsyncException, SomeException, bracket, fromException, throwIO, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Dynamic (Dynamic, Typeable, fromDynamic, toDyn)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.String (IsString (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Petrus.Fabric.Error
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps, parseJson, surrogateRefusingLoads)
import Petrus.Postgres (PostgresError)
import Petrus.TestSupport (pythonExecutable, upstreamPetrus)
import System.Directory (makeAbsolute)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , cleanupProcess
  , createProcess
  , proc
  )
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)

-- | One answer: a value, a categorized refusal, or an operation this
-- implementation does not offer.
data Answer
  = Ok Json
  | Err Category Text Text
  | -- | A failure outside fabric.md §12's categories (a door that raised).
    Failed Text Text
  | -- | The operation is not expressible in this implementation's API.
    Unsupported
  deriving stock (Show)

-- | An implementation under test.
data Impl = Impl
  { name :: String
  , isHaskell :: Bool
  , call :: Text -> [(Text, Json)] -> IO Answer
  }

-- | String literals as JSON strings, for writing requests (test code only).
instance IsString Json where
  fromString = String . T.pack

-- ---------------------------------------------------------------------------
-- Python

-- | The driver script, relative to the package directory a suite runs in.
driverPath :: FilePath
driverPath = "../petrus-fabric/test/interop/conformance_driver.py"

-- | Run the reference driver for the duration of an action.
withPythonImpl :: (Impl -> IO a) -> IO a
withPythonImpl action = do
  exe <- pythonExecutable
  root <- upstreamPetrus
  script <- makeAbsolute driverPath
  let process = (proc exe ["-I", script]) {cwd = Just root, std_in = CreatePipe, std_out = CreatePipe}
  bracket (createProcess process) cleanupProcess $ \case
    (Just input, Just output, _, _) -> do
      hSetBuffering input LineBuffering
      hSetBinaryMode output True
      lock <- newMVar ()
      action Impl {name = "Python reference", isHaskell = False, call = pythonCall lock input output}
    _ -> error "createProcess did not return pipes"

pythonCall :: MVar () -> Handle -> Handle -> Text -> [(Text, Json)] -> IO Answer
pythonCall lock input output op args = modifyMVar lock $ \() -> do
  BS.hPut input (encodeLine (Object (("op", String op) : args)) <> "\n")
  hFlush input
  line <-
    timeout 60000000 (BC.hGetLine output) >>= \case
      Just l -> pure l
      Nothing -> hClose input >> error ("the conformance driver did not answer " <> T.unpack op)
  answer <- case parseJson surrogateRefusingLoads line of
    Left problem -> error ("the conformance driver answered invalid JSON: " <> problem <> ": " <> show line)
    Right value -> pure (decodeAnswer value)
  pure ((), answer)

encodeLine :: Json -> BS.ByteString
encodeLine value = either (error . show) id (dumps compact {allowNan = True} value)

decodeAnswer :: Json -> Answer
decodeAnswer = \case
  Object [("ok", value)] -> Ok value
  Object [("unsupported", _)] -> Unsupported
  Object [("error", Object fields)] ->
    let text key = case lookup key fields of
          Just (String s) -> s
          _ -> ""
     in if text "category" == "other"
          then Failed (text "type") (text "message")
          else Err (categoryOf (text "category")) (text "type") (text "message")
  other -> error ("unexpected driver answer " <> show other)
  where
    categoryOf c = case [x | x <- [minBound .. maxBound], categoryText x == c] of
      [x] -> x
      _ -> error ("unknown category " <> T.unpack c)

-- ---------------------------------------------------------------------------
-- The Haskell twin

-- | Live objects the requests refer to by number.
newtype Handles = Handles (IORef (Int, Map Int Dynamic))

newHandles :: IO Handles
newHandles = Handles <$> newIORef (0, Map.empty)

store :: Typeable a => Handles -> a -> IO Json
store (Handles ref) value =
  atomicModifyIORef' ref (\(n, m) -> ((n + 1, Map.insert (n + 1) (toDyn value) m), Int (fromIntegral (n + 1))))

fetch :: Typeable a => Handles -> Map Text Json -> Text -> IO a
fetch (Handles ref) args key = do
  (_, m) <- readIORef ref
  case Map.lookup key args of
    Just (Int n) | Just d <- Map.lookup (fromIntegral n) m, Just value <- fromDynamic d -> pure value
    _ -> error ("no live " <> T.unpack key <> " handle in the request")

-- | An operation table: each entry answers a request's arguments.
type Ops = Map Text (Map Text Json -> IO Json)

-- | The Haskell implementation over the given operation tables.
haskellImpl :: [Ops] -> Impl
haskellImpl tables =
  Impl
    { name = "Haskell port"
    , isHaskell = True
    , call = \op args -> case Map.lookup op table of
        Nothing -> pure Unsupported
        Just run ->
          try (run (Map.fromList args) >>= \value -> length (show value) `seq` pure value) >>= \case
            Right value -> pure (Ok value)
            Left err -> classify err
    }
  where
    table = Map.unions tables
    classify :: SomeException -> IO Answer
    classify err
      | Just fabric <- fromException err = pure (Err (errorCategory fabric) (pythonExceptionName fabric) (errorMessage fabric))
      | Just (pg :: PostgresError) <- fromException err = pure (Err Storage "PostgresError" (T.pack (show pg)))
      | Just (_ :: SomeAsyncException) <- fromException err = throwIO err
      | otherwise = pure (Failed "SomeException" (T.pack (show err)))

-- | The refusal for an argument the Haskell API's types cannot even
-- express (a boolean where an Int is required, a naive datetime, …).
typeEnforced :: Text -> IO a
typeEnforced what = throwIO (InvalidType ("type-enforced: " <> what))

arg :: Map Text Json -> Text -> Json
arg args key = Map.findWithDefault Null key args

argText :: Map Text Json -> Text -> IO Text
argText args key = case arg args key of
  String s -> pure s
  _ -> throwIO (InvalidValue (key <> " must be a non-empty string of at most 1024 UTF-8 bytes"))

argInt :: Map Text Json -> Text -> IO Int
argInt args key = case arg args key of
  Int n -> pure (fromIntegral n)
  _ -> typeEnforced (key <> " is an Int")

argBool :: Map Text Json -> Text -> IO Bool
argBool args key = case arg args key of
  Bool b -> pure b
  _ -> typeEnforced (key <> " is a Bool")

argMaybe :: Map Text Json -> Text -> Maybe Json
argMaybe args key = case Map.lookup key args of
  Just Null -> Nothing
  other -> other

argObject :: Map Text Json -> Text -> Map Text Json
argObject args key = case arg args key of
  Object members -> Map.fromList members
  _ -> Map.empty

-- | A receipt time as the driver spells it.
stampText :: UTCTime -> Text
stampText t =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S." t <> take 6 (formatTime defaultTimeLocale "%q" t) <> "+00:00")

-- | An ISO-8601 time that must carry an offset.
parseStamp :: Text -> Maybe UTCTime
parseStamp text =
  let s = T.unpack text
   in case parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Ez" s of
        Just t -> Just t
        Nothing -> parseTimeM False defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q%Ez" s

-- ---------------------------------------------------------------------------
-- Asserting

answerOf :: Impl -> Text -> [(Text, Json)] -> IO Answer
answerOf impl = impl.call

-- | The value, or a failed expectation.
ok :: Impl -> Text -> [(Text, Json)] -> IO Json
ok impl op args =
  impl.call op args >>= \case
    Ok value -> pure value
    other -> expectationFailure (impl.name <> ": " <> T.unpack op <> " " <> showJson (Object args) <> " answered " <> show other) >> pure Null

-- | A refusal of the category; answers its message.
refused :: Category -> Impl -> Text -> [(Text, Json)] -> IO Text
refused category impl op args =
  impl.call op args >>= \case
    Err c _ message
      | c == category -> pure message
    other ->
      expectationFailure
        ( impl.name
            <> ": "
            <> T.unpack op
            <> " "
            <> showJson (Object args)
            <> " should be refused as "
            <> T.unpack (categoryText category)
            <> ", answered "
            <> show other
        )
        >> pure ""

-- | 'refused', and the message contains the fragment.
refusedWith :: Category -> Text -> Impl -> Text -> [(Text, Json)] -> IO ()
refusedWith category fragment impl op args = do
  message <- refused category impl op args
  if fragment `T.isInfixOf` message || T.null message
    then pure ()
    else expectationFailure (impl.name <> ": message " <> show message <> " lacks " <> show fragment)

obj :: [(Text, Json)] -> Json
obj = Object

str :: Text -> Json
str = String

int :: Integer -> Json
int = Int

arr :: [Json] -> Json
arr = Array

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

memberText :: Text -> Json -> Text
memberText key value = case member key value of
  String s -> s
  other -> T.pack (show other)

showJson :: Json -> String
showJson value = either show (T.unpack . TE.decodeUtf8) (dumps compact {allowNan = True} value)
