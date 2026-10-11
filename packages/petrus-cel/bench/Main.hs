{-# LANGUAGE OverloadedRecordDot #-}

-- | Compile and evaluate typical Petrus CEL expressions through the kernel
-- seam ("Petrus.Cel.Impetus"), the way the Impetus kernel uses them: arc
-- filters over token data, guards over a binding, completion conditions over
-- a marking. @bench/time_cel.py@ times the same cases on the reference
-- (cel-python 0.5.0 behind @petrus.impetus.binding.cel@); see
-- @bench/RESULTS.md@.
--
-- Three measurements per case:
--
-- * @parse@: source text to a fully built syntax tree ('compile');
-- * @evaluate@: one call of the precompiled predicate (this includes
--   building the activation from the token JSON, as the reference does on
--   every call);
-- * @compile+evaluate@: the kernel compiler (parse, free-variable check,
--   closure) followed by one evaluation.
module Main (main) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (localOption)
import Test.Tasty.Bench

import Petrus.Cel (compile, programExpr)
import Petrus.Cel.Impetus (celCompilers)
import Petrus.Impetus.Binding (CelCompilers (..))
import Petrus.Impetus.Petrinet hiding (outputs, token)
import Petrus.Json (Json (..))

np :: Text -> NetPath
np = either (error . T.unpack) id . netPath

payment :: Integer -> Token
payment amount = Token (Just "Payment") (Object [("amount", Int amount), ("currency", String "USD"), ("status", String "paid")])

-- | A case: its name, source, kernel compiler, input, and expected result.
data Case = forall a. Case String Text (Text -> Either Text (a -> Either Text Bool)) a Bool

filterCase :: String -> Text -> Token -> Bool -> Case
filterCase name source = Case name source (celCompilers.compileFilter . unsafeCel)

guardCase :: String -> Text -> Binding -> Bool -> Case
guardCase name source b =
  Case name source (\s -> celCompilers.compileGuard (unsafeCel s) b.transition scope) b
  where
    scope = Set.fromList (map fst (b.consumed ++ b.read))

completionCase :: String -> Text -> [NetPath] -> Marking -> Bool -> Case
completionCase name source places = Case name source (\s -> celCompilers.compileCompletion (unsafeCel s) places)

cases :: [Case]
cases =
  [ filterCase "filter/field" "amount >= 100" (payment 150) True
  , filterCase
      "filter/conjunction"
      "amount >= 100 && currency == \"USD\" && !(status in [\"void\", \"refunded\"])"
      (payment 150)
      True
  , filterCase
      "filter/regex"
      "email.matches(r'^[a-z.]+@example\\.com$')"
      (Token (Just "Customer") (Object [("email", String "jane.doe@example.com")]))
      True
  , guardCase
      "guard/correlate"
      "pending[0].data.amount <= config[0].data.limit"
      (Binding (np "approve") [(np "pending", [payment 150])] [(np "config", [config])] [])
      True
  , guardCase
      "guard/macros"
      "pending.all(t, t.data.amount < 500) && size(pending.filter(t, t.data.amount > 100)) >= 1"
      (Binding (np "approve") [(np "pending", map payment ([10, 20 .. 100] ++ [150]))] [] [])
      True
  , completionCase
      "completion/all"
      "size(pending) == 0 && accepted.all(t, t.data.amount >= 100)"
      [np "pending", np "accepted", np "rejected"]
      ( markingFromList
          [ (np "accepted", map payment [100, 110 .. 290])
          , (np "rejected", map payment [1 .. 5])
          ]
      )
      True
  , completionCase
      "completion/exists"
      "done.exists(t, t.color == \"Result\" && t.data.state == \"ok\") && size(failed) == 0"
      [np "done", np "failed"]
      (markingFromList [(np "done", [result "pending", result "running", result "ok"])])
      True
  ]
  where
    config = Token (Just "Config") (Object [("limit", Int 200)])
    result state = Token (Just "Result") (Object [("state", String state)])

benchmarks :: Case -> Benchmark
benchmarks (Case name source compiler input _) =
  bgroup
    name
    [ bench "parse" (whnf parsedTo source)
    , bench "evaluate" (whnf (holds . predicate) input)
    , bench "compile+evaluate" (whnf (\s -> holds (compiler s >>= ($ input))) source)
    ]
  where
    tree = either (error . show) programExpr (compile source)
    parsedTo s = either (const False) ((== tree) . programExpr) (compile s)
    predicate = either (error . T.unpack) id (compiler source)
    holds = either (const False) id

-- | Every case must hold before it is timed.
check :: Case -> IO ()
check (Case name source compiler input expected) =
  case compiler source >>= ($ input) of
    Right got | got == expected -> pure ()
    other -> fail (name <> ": " <> show other <> ", expected " <> show expected)

main :: IO ()
main = do
  mapM_ check cases
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain (map (localOption WallTime . benchmarks) cases)
