-- | DSL benchmarks, the twins of @bench/python_bench.py@: the same
-- @chain@ and @stamped@ workloads as @differential/dsl_corpus.py@ (whose
-- outputs the differential corpus checks byte for byte at sizes 50 and 30).
--
-- * @build@: author the specification and build the canonical 'Net' (the
--   kernel constructor validates every place, transition, and arc before it
--   returns, so a 'Right' is a fully checked Net); the result is the arc
--   count.
-- * @build+v3@: the same, then project and serialize the Net definition v3;
--   the result is the byte count, which @python_bench.py@ prints too.
module Main (main) where

import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Dsl
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.Petrinet.Schema (netArcs)
import Test.Tasty.Bench

-- | A flat chain of @size@ places and @size@ transitions.
chain :: Int -> Either DslError NetSpec
chain size = netSpec (named ("chain-" <> showT size)) $ forM_ [0 .. size - 1] $ \i ->
  void $
    (p ("p" <> showT i) >>= color "Item")
      ~> (t ("t" <> showT i) >>= configure [handler "step"])
      ~> (p ("p" <> showT (i + 1)) >>= color "Item")

-- | A 10-node child stamped at @scopes@ scopes nested three deep.
stamped :: Int -> Either DslError NetSpec
stamped scopes = do
  unit <- netSpec (named "unit") $ forM_ [0 .. 4 :: Int] $ \i ->
    void $
      (p ("in" <> showT i) >>= color "Item")
        ~> (t ("step" <> showT i) >>= configure [handler "step"])
        ~> (p "out" >>= color "Item")
  netSpec (named ("stamped-" <> showT scopes)) $ forM_ [0 .. scopes - 1] $ \i ->
    scope ("a" <> showT (i `mod` 10)) $
      scope ("b" <> showT (i `div` 10 `mod` 10)) $
        scope ("c" <> showT (i `div` 100)) (stamp unit)

showT :: Int -> Text
showT = T.pack . show

builtArcs :: (Int -> Either DslError NetSpec) -> Int -> Int
builtArcs make size = case make size >>= build of
  Right b -> length (netArcs b.net)
  Left err -> error (show err)

serializedBytes :: (Int -> Either DslError NetSpec) -> Int -> Int
serializedBytes make size = case make size >>= build of
  Right b -> either (error . T.unpack) BS.length (projectNetDefinition b.net >>= serializeNetDefinition)
  Left err -> error (show err)

workload :: String -> (Int -> Either DslError NetSpec) -> Int -> Benchmark
workload name make size =
  bgroup
    (name <> "-" <> show size)
    [ bench "build" (nf (builtArcs make) size)
    , bench "build+v3" (nf (serializedBytes make) size)
    ]

main :: IO ()
main = do
  forM_ [("chain", chain, [1000, 10000]), ("stamped", stamped, [10, 100, 1000])] $ \(name, make, sizes) ->
    forM_ sizes $ \size ->
      putStrLn (name <> "-" <> show size <> ": " <> show (builtArcs make size) <> " arcs, " <> show (serializedBytes make size) <> " bytes")
  defaultMain
    [ bgroup "chain" [workload "chain" chain size | size <- [1000, 10000]]
    , bgroup "stamped" [workload "stamped" stamped size | size <- [10, 100, 1000]]
    ]
