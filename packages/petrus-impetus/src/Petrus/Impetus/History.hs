-- | Event history: the append-only record of how an instance evolves
-- (@petrus.impetus.history@): the record family, its validation, the
-- replay folds, and (in "Petrus.Impetus.History.Codec") the schema-5 codec.
module Petrus.Impetus.History
  ( module Petrus.Impetus.History.Records
  , module Petrus.Impetus.History.Replay
  ) where

import Petrus.Impetus.History.Records
import Petrus.Impetus.History.Replay
