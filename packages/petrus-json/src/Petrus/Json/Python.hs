-- | The CPython-compatibility layer: every observable CPython behaviour the
-- Petrus and Hamsterdan ports reproduce outside the JSON codec itself, in
-- one place.
--
-- * "Petrus.Json.PythonText": @str.isprintable@, @str.isspace@, the line
--   boundaries, @unicodedata.decimal@ (one table generated from CPython
--   3.14 / Unicode 16.0), @strip@, @split@, @splitlines@ and @repr(str)@;
-- * "Petrus.Json.Repr": @repr@ and @str@ of what @json.loads@ returns,
--   @repr(bytes)@ and @repr(float)@;
-- * "Petrus.Json.Python.Decode": strict UTF-8 decoding with CPython's
--   'UnicodeDecodeError' text, @errors="replace"@ decoding, and
--   @json.loads(bytes)@'s @detect_encoding@ decoding;
-- * "Petrus.Json.Python.Scanner" (imported on its own, its names being
--   generic): @json.loads@'s scanner with its hooks and 'JSONDecodeError'
--   texts;
-- * "Petrus.Json.Python.Uuid": @uuid.uuid4()@;
-- * 'jsonTypeName': @type(value).__name__@ of a decoded value.
--
-- Each is checked against the pinned interpreter on generated inputs
-- (@test/Petrus/Json/PythonCompatSpec.hs@).
module Petrus.Json.Python
  ( module Petrus.Json.PythonText
  , module Petrus.Json.Repr
  , module Petrus.Json.Python.Decode
  , module Petrus.Json.Python.Uuid
  , jsonTypeName
  ) where

import Petrus.Json.Python.Decode
import Petrus.Json.Python.Uuid
import Petrus.Json.PythonText
import Petrus.Json.Repr
import Petrus.Json.Value (jsonTypeName)
