-- | V5 actor-loop executable topology for one PR-readiness Instance
-- (@net_v5/topology.py@).
--
-- One concern = one loop = one memory baton plus mailbox places;
-- cross-loop influence is mailed facts only. Each loop module owns
-- @declare@ (its places), @wire@ (its transitions), and @seed@ (its
-- baton's contribution to the newborn marking). The composer declares
-- all places first, then wires all loops, so any loop may mail into any
-- sibling mailbox.
module Hamsterdan.Readiness.NetV5.Topology
  ( netV5Spec
  , buildNetV5
  , gates
  , derived
  , seedMarking
  , seedMarkingWith
  , defaultReminderDelayS
  , subjectMalformed
  ) where

import Control.Monad (foldM)
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Readiness.NetV5.Folding (PythonException, valueError)
import Hamsterdan.Readiness.NetV5.Ci qualified as Ci
import Hamsterdan.Readiness.NetV5.Conversation qualified as Conversation
import Hamsterdan.Readiness.NetV5.Dashboard qualified as Dashboard
import Hamsterdan.Readiness.NetV5.Esc qualified as Esc
import Hamsterdan.Readiness.NetV5.Life qualified as Life
import Hamsterdan.Readiness.NetV5.Mutation qualified as Mutation
import Hamsterdan.Readiness.NetV5.Readiness qualified as Readiness
import Hamsterdan.Readiness.NetV5.Reminders qualified as Reminders
import Hamsterdan.Readiness.NetV5.Review qualified as Review
import Hamsterdan.Readiness.NetV5.Startup qualified as Startup
import Petrus.Impetus.Dsl (Author, BuiltNet, DslError, NetSpec, build, named, netSpec)
import Petrus.Impetus.Petrinet (Marking, NetPath, Token, markingFromList, netPathText)

-- | Transition path → (activity name, declared variant colors), for every
-- gate in the composed topology, in loop order (@GATES@).
gates :: [(Text, (Text, [Text]))]
gates =
  Esc.gates
    ++ Review.gates
    ++ Mutation.gates
    ++ Conversation.gates
    ++ Dashboard.gates
    ++ Reminders.gates
    ++ Readiness.gates

-- | Transition path → activity name, for single-output (derived) gates.
-- V5 declares none (@DERIVED@).
derived :: [(Text, Text)]
derived = []

declares :: [Author s ()]
declares =
  [ Life.declare
  , Ci.declare
  , Esc.declare
  , Review.declare
  , Mutation.declare
  , Conversation.declare
  , Dashboard.declare
  , Reminders.declare
  , Readiness.declare
  ]

wires :: [Author s ()]
wires =
  [ Life.wire
  , Ci.wire
  , Esc.wire
  , Review.wire
  , Mutation.wire
  , Conversation.wire
  , Dashboard.wire
  , Reminders.wire
  , Readiness.wire
  ]

-- | The authored specification (@NetSpec("pr_v5")@ after every loop).
netV5Spec :: Either DslError NetSpec
netV5Spec = netSpec (named "pr_v5") $ do
  Startup.declare
  sequence_ declares
  sequence_ wires
  Startup.wire gates

-- | @build_net_v5()@.
buildNetV5 :: Either DslError BuiltNet
buildNetV5 = netV5Spec >>= build

-- | Three days, the reference's default reminder delay.
defaultReminderDelayS :: Integer
defaultReminderDelayS = 3 * 24 * 60 * 60

-- | The refusal text for a malformed subject.
subjectMalformed :: Text
subjectMalformed = "V5 workflow subject is malformed"

-- | @seed_marking(subject)@.
seedMarking :: Text -> Either PythonException Marking
seedMarking = seedMarkingWith defaultReminderDelayS

-- | @seed_marking(subject, reminder_delay_s=...)@: the newborn Instance,
-- bound to one globally unique host subject. Refuses a subject that is
-- empty, over 900 UTF-8 bytes, non-ASCII, or not printable; the refusal
-- is the reference's @ValueError@ message.
seedMarkingWith :: Integer -> Text -> Either PythonException Marking
seedMarkingWith reminderDelayS subject
  | T.null subject || T.length subject > 900 || not (T.all printableAscii subject) = Left (valueError subjectMalformed)
  | otherwise = markingFromList . reverse <$> foldM add [] contributions
  where
    printableAscii c = ord c >= 0x20 && ord c <= 0x7e
    contributions =
      Startup.seed
        ++ Life.seed reminderDelayS
        ++ Ci.seed
        ++ Esc.seed
        ++ Review.seed subject
        ++ Mutation.seed
        ++ Conversation.seed
        ++ Dashboard.seed
        ++ Reminders.seed subject
        ++ Readiness.seed
    add :: [(NetPath, [Token])] -> (NetPath, [Token]) -> Either PythonException [(NetPath, [Token])]
    add acc (path, tokens)
      | any ((== path) . fst) acc = Left (valueError ("duplicate seed contribution for " <> netPathText path))
      | otherwise = Right ((path, tokens) : acc)
