-- | The CPython semantics the Hamsterdan ports share, built on petrus-json's
-- CPython-compatibility layer ("Petrus.Json.Python"):
--
-- * "Hamsterdan.Python.Text": @str@ predicates and methods, @repr@ of a
--   @str@, @int()@, @uuid.UUID@, strict UTF-8 decoding and encoding;
-- * "Hamsterdan.Python.Value": truthiness, @dict.get@, @str()@, @int()@,
--   subscripts and iteration over what @json.loads@ returns;
-- * "Hamsterdan.Python.Json": @json.loads@ of a @str@ or @bytes@;
-- * "Hamsterdan.Python.Exception": the one Python exception value;
-- * "Hamsterdan.Python.Hashlib": @hashlib.sha256@;
-- * "Hamsterdan.Python.Url" (imported on its own, its field names being
--   generic): @urllib.parse@.
--
-- Upstream these are the standard library, which every subsystem may use;
-- here they live in hamsterdan-contracts, which every subsystem may import
-- (@scripts/lint-hamsterdan-architecture@).
module Hamsterdan.Python
  ( module Hamsterdan.Python.Exception
  , module Hamsterdan.Python.Hashlib
  , module Hamsterdan.Python.Json
  , module Hamsterdan.Python.Text
  , module Hamsterdan.Python.Value
  ) where

import Hamsterdan.Python.Exception
import Hamsterdan.Python.Hashlib
import Hamsterdan.Python.Json
import Hamsterdan.Python.Text
import Hamsterdan.Python.Value
