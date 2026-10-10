-- | Minimal program-owned steering and evaluation seams
-- (@petrus.agenticus.program.seam@).
--
-- The directive, trace and evaluation types stay program-native type
-- parameters, exactly as upstream's generic Protocols; Agenticus never
-- defines their schema.
module Petrus.Agenticus.Program.Seam
  ( ProgramSteering
  , ProgramEvaluator
  , ProgramSeams (descriptor, steering, evaluator)
  , mkProgramSeams
  ) where

import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate (require)
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Thread.Identity

-- | Apply one program-native steering directive to an Episode.
type ProgramSteering directive = EpisodeId -> directive -> IO ()

-- | Evaluate one program-native trace without defining a trace schema.
type ProgramEvaluator trace evaluation = EpisodeId -> trace -> IO evaluation

-- | Concrete optional seams whose ownership is declared by the program: a
-- seam is present exactly when the descriptor owns it.
data ProgramSeams directive trace evaluation = ProgramSeams
  { descriptor :: AgentProgramDescriptor
  , steering :: Maybe (ProgramSteering directive)
  , evaluator :: Maybe (ProgramEvaluator trace evaluation)
  }

mkProgramSeams
  :: AgentProgramDescriptor
  -> Maybe (ProgramSteering directive)
  -> Maybe (ProgramEvaluator trace evaluation)
  -> Either AgenticusError (ProgramSeams directive trace evaluation)
mkProgramSeams d s e = do
  let present = maybe False (const True)
  require (not (d.ownsSteering && not (present s))) (valueError "Agent Program requires a steering seam")
  require (not (not d.ownsSteering && present s)) (valueError "Agent Program does not own steering")
  require (not (d.ownsEvaluation && not (present e))) (valueError "Agent Program requires an evaluator seam")
  require (not (not d.ownsEvaluation && present e)) (valueError "Agent Program does not own evaluation")
  pure (ProgramSeams d s e)
