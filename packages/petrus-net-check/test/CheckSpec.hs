-- | The checks on small nets: a mutex that holds, two locks taken in
-- opposite orders, a lock lost on failure, a loop that never rests, and a
-- net that grows without bound.
module CheckSpec (spec) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, takeMVar, threadDelay, tryPutMVar)
import Control.Exception (evaluate)
import Control.Monad (void)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Petrinet.Schema
import Petrus.Net.Check
import Petrus.Net.Declared
import Test.Hspec

-- | A net from its places, and its transitions, each with its input arcs
-- (place, mode) and its output places.
netOf :: [Text] -> [(Text, [(Text, ArcMode)], [Text])] -> Net
netOf places steps =
  either (error . show) id $
    mkNet
      NetSpec
        { places = map (place . path) places
        , transitions = [(transition (path t)) {handler = Just (HandlerSymbol t)} | (t, _, _) <- steps]
        , arcs =
            concat
              [ [(arc (path from) (path t)) {mode} | (from, mode) <- ins] <> [arc (path t) (path to) | to <- outs]
              | (t, ins, outs) <- steps
              ]
        , completion = Nothing
        , name = Nothing
        }
  where
    path = either (error . show) id . netPath

outcome :: Text -> When -> [(Text, Int)] -> Outcome
outcome name when puts = Outcome {name, when, puts = Map.fromList puts}

problemsOf :: Checked -> [(Text, Text, [Text])]
problemsOf checked = [(r.scenario, p.rule, p.trace) | r <- checked.reports, p <- r.problems]

-- | What came of waiting for a value: it came in time, or the wait ran out.
data Waited a
  = Came a
  | RanOut
  deriving stock (Eq, Show)

-- | Show a value in full, if that takes no more than so many seconds.
waitFor :: (Show a) => Int -> a -> IO (Waited a)
waitFor seconds value = do
  answer <- newEmptyMVar
  worker <- forkIO (evaluate (length (show value)) >> void (tryPutMVar answer (Came value)))
  timer <- forkIO (threadDelay (seconds * 1000000) >> void (tryPutMVar answer RanOut))
  waited <- takeMVar answer
  mapM_ killThread [worker, timer]
  pure waited

-- | A net with 4097 minimal P-invariants: 2^12 from twelve stages, and one
-- from a chain of 200 steps after them. The stages pass a token on through
-- one of two places each, and the last puts it back where the first takes
-- it from, so `start`, with any one place from each stage, is an invariant.
-- The chain's 201 places together are the one more. Farkas'
-- algorithm carries the stages' 4096, with the chain's rows, under its cap
-- of 5000, through every column of the chain, and compares each with each
-- at every one. No place holds a token, so the checks reach one marking.
branching :: Net
branching =
  netOf
    (["start"] <> concat [[at "left" i, at "right" i] | i <- stages] <> [at "chain" i | i <- [0 .. 200]])
    ( [(at "stage" 0, [("start", Consume)], [at "left" 0, at "right" 0])]
        <> [(at "stage" i, [(at "left" (i - 1), Consume), (at "right" (i - 1), Consume)], [at "left" i, at "right" i]) | i <- drop 1 stages]
        <> [(at "stage" 12, [(at "left" 11, Consume), (at "right" 11, Consume)], ["start"])]
        <> [(at "step" i, [(at "chain" i, Consume)], [at "chain" (i + 1)]) | i <- [0 .. 199]]
    )
  where
    stages = [0 .. 11]
    at :: Text -> Int -> Text
    at name i = name <> "-" <> T.justifyRight 3 '0' (T.pack (show i))

mutex :: Net
mutex =
  netOf
    ["waiting", "lock", "working", "done"]
    [ ("arrive", [], ["waiting"])
    , ("acquire", [("waiting", Consume), ("lock", Consume)], ["working"])
    , ("release", [("working", Consume)], ["done", "lock"])
    ]

mutexDeclared :: Declared
mutexDeclared =
  noDeclarations
    { initial = Map.fromList [("lock", 1)]
    , finalPlaces = ["done"]
    , finalMarkings = [Map.fromList [("lock", 1)]]
    , laws = [Law {name = "the lock", weights = Map.fromList [("lock", 1), ("working", 1)], total = 1}]
    , scenarios = [Scenario {name = "three arrivals", deliver = Map.fromList [("arrive", 3)]}]
    }

spec :: Spec
spec = describe "the net checks" $ do
  it "explore a mutex in full, and find every check holds" $ do
    let checked = check defaultLimits mutex mutexDeclared
    problemsOf checked `shouldBe` []
    map (.reached) checked.reports `shouldBe` [16]
    -- Deliveries are left out, so every arrival stays somewhere too.
    checked.invariants `shouldBe` Right [Map.fromList [("lock", 1), ("working", 1)], Map.fromList [("done", 1), ("waiting", 1), ("working", 1)]]

  it "report on every scenario without listing the P-invariants, which only the render reads" $ do
    -- The checks reach one marking here in well under 0.2 s, so 2 s is
    -- ten times that. Listing the 4097 invariants compares up to 4297 rows
    -- with each other at each of some 200 columns.
    let checked = check defaultLimits branching noDeclarations
    waited <- waitFor 2 [(r.scenario, r.reached, map (.rule) r.problems) | r <- checked.reports]
    waited `shouldBe` Came [("the initial marking", 1, [])]

  it "find two locks taken in opposite orders, and the firings into it" $ do
    let crossed =
          netOf
            ["a", "b", "p", "p-has-a", "q", "q-has-b", "done"]
            [ ("p-takes-a", [("p", Consume), ("a", Consume)], ["p-has-a"])
            , ("p-takes-b", [("p-has-a", Consume), ("b", Consume)], ["done", "a", "b"])
            , ("q-takes-b", [("q", Consume), ("b", Consume)], ["q-has-b"])
            , ("q-takes-a", [("q-has-b", Consume), ("a", Consume)], ["done", "a", "b"])
            ]
        declared =
          noDeclarations
            { initial = Map.fromList [("a", 1), ("b", 1), ("p", 1), ("q", 1)]
            , finalMarkings = [Map.fromList [("a", 1), ("b", 1), ("done", 2)]]
            }
    problemsOf (check defaultLimits crossed declared)
      `shouldBe` [ ("the initial marking", "deadlock", ["q-takes-b", "p-takes-a"])
                 , ("the initial marking", "never-rests", ["q-takes-b", "p-takes-a"])
                 ]

  it "find a lock an Activity loses when it fails, between its start and its end" $ do
    let losing =
          netOf
            ["jobs", "lock", "done"]
            [ ("arrive", [], ["jobs"])
            , ("work", [("jobs", Consume), ("lock", Consume)], ["done", "lock"])
            ]
        declared =
          noDeclarations
            { initial = Map.fromList [("lock", 1)]
            , finalPlaces = ["done"]
            , finalMarkings = [Map.fromList [("lock", 1)]]
            , outcomes = Map.fromList [("work", [outcome "worked" OnSuccess [("done", 1), ("lock", 1)], outcome "failed" OnFailure []])]
            , laws = [Law {name = "the lock", weights = Map.fromList [("lock", 1), ("@work", 1)], total = 1}]
            , scenarios = [Scenario {name = "one job", deliver = Map.fromList [("arrive", 1)]}]
            }
        checked = check defaultLimits losing declared
    problemsOf checked
      `shouldBe` [ ("one job", "law", ["deliver to arrive", "start work", "work ends: failed"])
                 , ("one job", "deadlock", ["deliver to arrive", "start work", "work ends: failed"])
                 , ("one job", "never-rests", ["deliver to arrive", "start work", "work ends: failed"])
                 ]
    -- A failure that drops the lock leaves nothing the net conserves.
    checked.invariants `shouldBe` Right []

  it "find a loop that never comes to rest" $ do
    let loop = netOf ["ping", "pong"] [("hit", [("ping", Consume)], ["pong"]), ("back", [("pong", Consume)], ["ping"])]
    problemsOf (check defaultLimits loop noDeclarations {initial = Map.fromList [("ping", 1)]})
      `shouldBe` [("the initial marking", "never-rests", [])]

  it "let a caller fill ingress, and let a reader hold its place" $ do
    let reading =
          netOf
            ["inbox", "config", "done"]
            [("read", [("inbox", Consume), ("config", Read)], ["done"])]
        declared =
          noDeclarations
            { ingress = ["inbox", "config"]
            , finalPlaces = ["done", "config"]
            , scenarios =
                [ Scenario {name = "configured", deliver = Map.fromList [("inbox", 2), ("config", 1)]}
                , Scenario {name = "unconfigured", deliver = Map.fromList [("inbox", 1)]}
                ]
            }
    problemsOf (check defaultLimits reading declared)
      `shouldBe` [("unconfigured", "deadlock", ["deliver to inbox"]), ("unconfigured", "never-rests", [])]

  it "stop a net that grows without bound" $ do
    let growing = netOf ["seed", "pile"] [("grow", [("seed", Consume)], ["seed", "pile"])]
    problemsOf (check defaultLimits {tokens = 3} growing noDeclarations {initial = Map.fromList [("seed", 1)]})
      `shouldBe` [("the initial marking", "unbounded", ["grow", "grow", "grow", "grow"])]

  it "check nothing while the declarations name what the net doesn't have" $
    problemsOf (check defaultLimits mutex mutexDeclared {finalPlaces = ["gone"]})
      `shouldBe` [("the declarations", "declaration", [])]
