-- | The CPython-compatibility layer: every observable CPython behaviour the
-- Petrus and Hamsterdan ports reproduce outside the JSON codec itself, in
-- one place.
--
-- * "Petrus.Json.PythonText": @str.isprintable@, @str.isspace@, the line
--   boundaries, @unicodedata.decimal@ (one table generated from CPython
--   3.14 / Unicode 16.0), @strip@, @split@, @splitlines@, @repr(str)@, and
--   @int()@ / @float()@ of a @str@;
-- * "Petrus.Json.PythonCase": @str.lower@, @upper@, @casefold@, @title@
--   and friends;
-- * "Petrus.Json.Repr": @repr@ of strings, bytes, ints and floats;
-- * "Petrus.Json.Python.Object": a Python object as a value, with its
--   @repr()@, @str()@ and type name (what @json.loads@ returns, exception
--   arguments, pydantic inputs);
-- * "Petrus.Json.Python.Decode": strict UTF-8 decoding with CPython's
--   'UnicodeDecodeError' text, @errors="replace"@ decoding, and
--   @json.loads(bytes)@'s @detect_encoding@ decoding;
-- * "Petrus.Json.Python.Fs": @os.fsencode@ / @os.fsdecode@
--   (@surrogateescape@);
-- * "Petrus.Json.Python.Scanner" (imported on its own, its names being
--   generic): @json.loads@'s scanner with its hooks and 'JSONDecodeError'
--   texts;
-- * "Petrus.Json.Python.Exception": an exception as a value (class and
--   @args@), with its @repr()@ and @str()@;
-- * "Petrus.Json.Python.OsError": the @OSError@ subclass of an @errno@, and
--   the exception CPython raises for a failed system call on a path;
-- * "Petrus.Json.Python.Loads": @json.loads@ of a @str@ or @bytes@, as the
--   value or the exception CPython raises;
-- * "Petrus.Json.Python.Pydantic" (imported on its own): the text of a
--   pydantic @ValidationError@;
-- * "Petrus.Json.Python.Uuid": @uuid.uuid4()@, @uuid.uuid7()@ and
--   @os.urandom@;
-- * 'jsonTypeName': @type(value).__name__@ of a decoded value.
--
-- Each is checked against the pinned interpreter on generated inputs
-- (@test/Petrus/Json/PythonCompatSpec.hs@).
module Petrus.Json.Python
  ( module Petrus.Json.PythonText
  , module Petrus.Json.PythonCase
  , module Petrus.Json.Repr
  , module Petrus.Json.Python.Decode
  , module Petrus.Json.Python.Exception
  , module Petrus.Json.Python.Fs
  , module Petrus.Json.Python.Loads
  , module Petrus.Json.Python.Object
  , module Petrus.Json.Python.OsError
  , module Petrus.Json.Python.Uuid
  , jsonTypeName
  ) where

import Petrus.Json.Python.Decode
import Petrus.Json.Python.Exception
import Petrus.Json.Python.Fs
import Petrus.Json.Python.Loads
import Petrus.Json.Python.Object
import Petrus.Json.Python.OsError
import Petrus.Json.Python.Uuid
import Petrus.Json.PythonCase
import Petrus.Json.PythonText
import Petrus.Json.Repr
import Petrus.Json.Value (jsonTypeName)
