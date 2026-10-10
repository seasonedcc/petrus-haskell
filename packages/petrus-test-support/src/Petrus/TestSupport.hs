-- | Internal test infrastructure for the Petrus port: the pinned upstream
-- checkout and its fixtures ("Petrus.TestSupport.Repo"), Python reference
-- snippets for differential tests ("Petrus.TestSupport.Python"), and a
-- scratch PostgreSQL database per run ("Petrus.TestSupport.Postgres").
module Petrus.TestSupport
  ( module Petrus.TestSupport.Postgres
  , module Petrus.TestSupport.Python
  , module Petrus.TestSupport.Repo
  ) where

import Petrus.TestSupport.Postgres
import Petrus.TestSupport.Python
import Petrus.TestSupport.Repo
