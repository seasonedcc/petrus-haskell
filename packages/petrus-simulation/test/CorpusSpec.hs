-- | Differential corpus: @test/corpus_simulation.py@ generates random
-- implementation-free scenarios (a Net definition v3 document, a marking in
-- the protocol-v1 shape, and @max_actions@) and records what the pinned
-- upstream @simulate@ did with each. Every scenario is replayed here from
-- the same document: a result must be the same bytes, a profile refusal the
-- same message, and an unexpected failure an unexpected failure.
module CorpusSpec (spec) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.NetDefinition (compileNetDefinition, parseNetDefinition)
import Petrus.Json
import Petrus.Simulation (SimulationError (..), simulate)
import Petrus.Simulation.Http (decodeMarking)
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import System.Exit (ExitCode (..))
import Test.Hspec

data Outcome = Ok ByteString | Refused Text | Failed
  deriving stock (Eq, Show)

cases :: Int
cases = 300

spec :: Spec
spec = describe "differential corpus against the upstream runner" $
  forM_ [1 :: Int, 2] $ \seed ->
    it ("seed " <> show seed <> ": " <> show cases <> " generated scenarios") $ do
      root <- repoRoot
      script <- T.pack <$> readFile (root <> "/packages/petrus-simulation/test/corpus_simulation.py")
      result <- runPython script [show seed, show cases] ""
      unless (resultExit result == ExitSuccess) $ expectationFailure (BC.unpack (resultStderr result))
      tally <- newIORef (Map.empty :: Map.Map String Int)
      let lines' = filter (not . BS.null) (BC.lines (resultStdout result))
      length lines' `shouldBe` cases
      forM_ lines' $ \line -> do
        record <- either (fail . ("corpus line: " <>)) pure (parseJson strictLoads line)
        let field name = maybe Null id (lookupMember name record)
        definition <- case field "definition" of
          String text -> pure (TE.encodeUtf8 text)
          other -> fail ("definition: " <> show other)
        maxActions <- case field "max_actions" of
          Int n -> pure (fromInteger n)
          other -> fail ("max_actions: " <> show other)
        expected <- case field "outcome" of
          Object [("ok", String text)] -> pure (Ok (TE.encodeUtf8 text))
          Object [("profile_error", String message)] -> pure (Refused message)
          Object [("error", String _)] -> pure Failed
          other -> fail ("outcome: " <> show other)
        net <- either (fail . T.unpack) pure (parseNetDefinition definition >>= compileNetDefinition)
        marking <- either (fail . T.unpack) pure (decodeMarking (field "marking"))
        attempt <- try (simulate (builtOf net) marking maxActions >>= evaluate)
        let actual = case attempt of
              Right (Right payload) -> Ok payload
              Right (Left (ProfileError message)) -> Refused message
              Right (Left (UnexpectedError _)) -> Failed
              Left (_ :: SomeException) -> Failed
        modifyIORef' tally (Map.insertWith (+) (category actual) 1)
        unless (actual == expected) $
          expectationFailure
            ( "scenario differs\n  definition: "
                <> BC.unpack definition
                <> "\n  marking: "
                <> show (field "marking")
                <> "\n  max_actions: "
                <> show maxActions
                <> "\n  upstream: "
                <> take 600 (show expected)
                <> "\n  here: "
                <> take 600 (show actual)
            )
      counts <- readIORef tally
      -- the corpus exercises results and refusals, not only one of them
      Map.findWithDefault 0 "ok" counts `shouldSatisfy` (>= 100)
      Map.findWithDefault 0 "refused" counts `shouldSatisfy` (>= 30)
  where
    category = \case
      Ok _ -> "ok"
      Refused _ -> "refused"
      Failed -> "failed"
