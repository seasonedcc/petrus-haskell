-- | An 'ExecutionError' is recorded as the Python exception it stands for:
-- the class, @repr@ and @str@ a Worker records for the reference's
-- exception, checked against the pinned interpreter.
module ErrorSpec (spec) where

import Control.Exception (toException)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Json.Python.Exception (PythonException (..), asPythonException, pythonExceptionRepr, pythonExceptionStr)
import Petrus.Motus.Execution.Error (ErrorKind (..), ExecutionError (..), pythonErrnoMessage)
import Petrus.TestSupport (pythonJson)
import Test.Hspec

-- | Each error with the Python expression that builds the reference's.
cases :: [(ExecutionError, Text)]
cases =
  [ (ExecutionError OSError (T.pack (pythonErrnoMessage 2 (Just "/tmp/missing"))), "FileNotFoundError(2, os.strerror(2), '/tmp/missing')")
  , (ExecutionError OSError (T.pack (pythonErrnoMessage 13 Nothing)), "PermissionError(13, os.strerror(13))")
  , (ExecutionError OSError (T.pack (pythonErrnoMessage 21 (Just "it's \"here\"\n"))), "IsADirectoryError(21, os.strerror(21), 'it\\'s \"here\"\\n')")
  , (ExecutionError OSError "workspace is not writable", "OSError('workspace is not writable')")
  , (ExecutionError KeyError "'missing'", "KeyError('missing')")
  , (ExecutionError KeyError "3", "KeyError(3)")
  , (ExecutionError (TarError "ReadError") "unexpected end of data", "tarfile.ReadError('unexpected end of data')")
  , (ExecutionError (TarError "OutsideDestinationError") "'../x' would be extracted to '/x', which is outside the destination", "tarfile.OutsideDestinationError(tarfile.TarInfo('../x'), '/x')")
  , (ExecutionError ValueError "", "ValueError()")
  , (ExecutionError TimeoutError "deadline exceeded", "TimeoutError('deadline exceeded')")
  ]

recorded :: ExecutionError -> Json
recorded err = case asPythonException (toException err) of
  Just python@(PythonException name _) -> Array [String name, String (pythonExceptionRepr python), String (pythonExceptionStr python)]
  Nothing -> Null

spec :: Spec
spec =
  describe "ExecutionError as a Python exception" $
    it "records the class, repr and str of the reference's exception" $ do
      reference <-
        pythonJson
          "import json, os, sys, tarfile\nerrors = [eval(e) for e in json.loads(sys.argv[1])]\nprint(json.dumps([[type(e).__name__, repr(e), str(e)] for e in errors]))"
          [T.unpack (jsonList (map snd cases))]
      Array (map (recorded . fst) cases) `shouldBe` reference
  where
    jsonList items = "[" <> T.intercalate "," (map quote items) <> "]"
    quote item = "\"" <> T.concatMap escape item <> "\""
    escape = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      c -> T.singleton c
