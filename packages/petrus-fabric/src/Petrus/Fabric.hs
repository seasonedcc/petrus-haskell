-- | Transport-neutral Fabric values and the kernel ingress bridge (a port of
-- @petrus.fabric@). The PostgreSQL store is the @petrus-fabric:postgres@
-- sublibrary ("Petrus.Fabric.Postgres"); the Engine door is
-- @petrus-fabric:engine@ ("Petrus.Fabric.Engine").
module Petrus.Fabric
  ( module Petrus.Fabric.Error
  , module Petrus.Fabric.Model
  , module Petrus.Fabric.Ingress
  ) where

import Petrus.Fabric.Error
import Petrus.Fabric.Ingress
import Petrus.Fabric.Model
