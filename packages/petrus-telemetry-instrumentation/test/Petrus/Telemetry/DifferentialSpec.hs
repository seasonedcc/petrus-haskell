{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The telemetry differential: every scenario of
-- @differential/telemetry_scenarios.py@ runs through the Haskell Instance,
-- Engine, and JSONL store under 'capture', and what was emitted must equal
-- the reference's recorded events exactly — event names, field names, field
-- order, and values (with Python's int/float/bool distinctions) — and render
-- to the same routed line bytes with @ts@ pinned.
--
-- Only wall-clock-dependent fields are normalised, by key and type, on both
-- sides: every @*_ms@ field must be an @int >= 0@ (then 0), @max_rss_mb@ a
-- positive float (then 0.0), @current_rss_mb@ a float or null (then null).
-- Nothing else is mapped: @error_type@ and @firing_failed.error@ are
-- compared raw.
module Petrus.Telemetry.DifferentialSpec (spec) where

import Control.Exception (ArithException (..), AsyncException (..), toException)
import Control.Monad (forM_, unless, zipWithM_)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Foreign.C.Error (Errno (..), errnoToIOError)
import Petrus.HistoryStore.Support (withReference, runPython, withScratch)
import Petrus.Json (Json (..), exactEq, lookupMember, parseJson, pythonLoads)
import Petrus.Telemetry
import Petrus.Impetus.Instance (exceptionFailureText)
import Petrus.Telemetry.Scenarios (scenarios)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

fixturePath :: FilePath
fixturePath = "differential/telemetry_scenarios.json"

generator :: FilePath
generator = "differential/telemetry_scenarios.py"

loadFixture :: FilePath -> IO Json
loadFixture path = BS.readFile path >>= either (fail . ("fixture: " <>)) pure . parseJson pythonLoads

member :: Text -> Json -> Json
member key value = maybe (error ("fixture: missing " <> T.unpack key)) id (lookupMember key value)

array :: Json -> [Json]
array = \case
  Array xs -> xs
  other -> error ("fixture: not an array: " <> show other)

text :: Json -> Text
text = \case
  String s -> s
  other -> error ("fixture: not a string: " <> show other)

object :: Json -> Payload
object = \case
  Object members -> members
  other -> error ("fixture: not an object: " <> show other)

-- | Check one wall-clock field's type, then replace it with the normal form.
normalise :: Payload -> Either String Payload
normalise = traverse $ \(key, value) -> fmap (key,) $
  if
    | "_ms" `T.isSuffixOf` key -> case value of
        Int n | n >= 0 -> Right (Int 0)
        _ -> Left (T.unpack key <> " is not an int >= 0: " <> show value)
    | key == "max_rss_mb" -> case value of
        Float d | d > 0 -> Right (Float 0)
        _ -> Left ("max_rss_mb is not a positive float: " <> show value)
    | key == "current_rss_mb" -> case value of
        Null -> Right Null
        Float _ -> Right Null
        _ -> Left ("current_rss_mb is not a float or null: " <> show value)
    | otherwise -> Right value

samePayload :: Payload -> Payload -> Bool
samePayload a b = exactEq (Object a) (Object b)

levelOf :: Text -> Level
levelOf spelling = either (error . T.unpack) id (parseLevel spelling)

spec :: Spec
spec = do
  describe "against the committed reference events" $ do
    fixture <- runIO (loadFixture fixturePath)
    let ts = case member "ts" fixture of
          Int n -> n
          other -> error ("fixture: ts " <> show other)
        cases = array (member "scenarios" fixture)

    it "covers every Haskell scenario, in the generator's order" $
      map (text . member "name") cases `shouldBe` map fst scenarios

    forM_ cases $ \scenario -> do
      let name = text (member "name" scenario)
          expected = map object (array (member "events" scenario))
          expectedLines = map (TE.encodeUtf8 . text) (array (member "lines" scenario))
      it (T.unpack name <> " emits the reference's events, fields, order, values and line bytes") $ do
        action <- maybe (fail ("no Haskell scenario " <> T.unpack name)) pure (lookup name scenarios)
        emitted <- capture Nothing (Just (levelOf (text (member "level" scenario)))) $ \recorder -> do
          action
          recorded recorder
        normalised <- either fail pure (traverse normalise emitted)
        let names = map (lookup "event")
        unless (map (lookup "event") normalised `sameNames` names expected) $
          expectationFailure
            ( "event sequence differs\n  haskell:   " <> show (map (lookup "event") normalised)
                <> "\n  reference: "
                <> show (names expected)
            )
        zipWithM_
          ( \(index :: Int) (ours, theirs) ->
              unless (samePayload ours theirs) $
                expectationFailure ("event " <> show index <> " differs\n  haskell:   " <> show ours <> "\n  reference: " <> show theirs)
          )
          [0 ..]
          (zip normalised expected)
        map (telemetryLine ts) normalised `shouldBe` map Right expectedLines

    it "routes fixed payloads to the reference JsonLogger's exact bytes with ts pinned" $ do
      forM_ (array (member "pinned" fixture)) $ \pinned -> do
        lines' <- newIORef []
        let sink' = jsonLoggerWith (pure ts) (\line -> modifyIORef' lines' (line :))
        info sink' (object (member "payload" pinned))
        readIORef lines' `shouldReturn` [TE.encodeUtf8 (text (member "line" pinned))]

  describe "the Python class vocabulary (error_type, FiringFailed.error)" $ do
    it "names every errno's OSError subclass and spells its failure text as the pinned reference does" $ withReference $ \python -> do
      reference <- runPython python "differential/error_types.py" [] >>= either fail pure . parseJson pythonLoads . TE.encodeUtf8 . T.pack
      let errnos = array (member "errnos" reference)
      length errnos `shouldSatisfy` (> 50)
      forM_ errnos $ \entry -> do
        number <- case member "errno" entry of
          Int n -> pure (fromInteger n)
          other -> fail ("errno: " <> show other)
        let raised = toException (errnoToIOError "op" (Errno number) Nothing Nothing)
        (number, pythonErrorType raised, exceptionFailureText raised)
          `shouldBe` (number, text (member "error_type" entry), text (member "text" entry))

    it "names the other mapped exceptions as the pinned reference does" $ withReference $ \python -> do
      reference <- runPython python "differential/error_types.py" [] >>= either fail pure . parseJson pythonLoads . TE.encodeUtf8 . T.pack
      let others = member "others" reference
          haskell =
            [ ("user_error", toException (userError "boom"))
            , ("keyboard_interrupt", toException UserInterrupt)
            , ("divide_by_zero", toException DivideByZero)
            , ("exit_failure", toException (ExitFailure 3))
            , ("exit_success", toException ExitSuccess)
            ]
      forM_ haskell $ \(name, raised) -> do
        let expected = member name others
        (name, pythonErrorType raised, exceptionFailureText raised)
          `shouldBe` (name, text (member "error_type" expected), text (member "text" expected))

  it "the committed reference events are what the pinned reference emits today" $ withReference $ \python -> withScratch $ \dir -> do
    let fresh = dir </> "telemetry_scenarios.json"
    _ <- runPython python generator [fresh]
    regenerated <- loadFixture fresh
    committed <- loadFixture fixturePath
    exactEq regenerated committed `shouldBe` True
  where
    sameNames :: [Maybe Json] -> [Maybe Json] -> Bool
    sameNames a b = length a == length b && and (zipWith sameName a b)
    sameName (Just a) (Just b) = exactEq a b
    sameName Nothing Nothing = True
    sameName _ _ = False
