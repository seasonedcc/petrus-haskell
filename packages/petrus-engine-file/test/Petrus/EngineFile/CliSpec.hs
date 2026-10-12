-- | @petrus-format-json@ against @python -m petrus.cli.format_json@ (in
-- @upstream/petrus-engine/.venv@, provisioned on first use): the same arguments,
-- stdin and files give the same exit status, stdout, files afterwards, and
-- error (the traceback's exception line, or argparse's @error:@ line).
module Petrus.EngineFile.CliSpec (spec) where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (sort)
import Petrus.EngineFile.LiveSpec (referencePython)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, listDirectory, doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import Test.Hspec

data Scenario = Scenario
  { title :: String
  , files :: [(FilePath, ByteString)]
  , args :: [String]
  , input :: ByteString
  }

-- | What one run did.
data Run = Run
  { code :: ExitCode
  , out :: ByteString
  , err :: ByteString
  , after :: [(FilePath, ByteString)]
  }
  deriving stock (Eq, Show)

canonical, messy, crlf :: ByteString
canonical = "{\n  \"fileVersion\": \"2\",\n  \"net\": \"m\",\n  \"places\": {\"p\": {\"initial\": 1}}\n}\n"
messy = "{\"places\": {\"p\": {\"initial\": 1.0}}, \"net\": \"m\"}"
crlf = BC.intercalate "\r\n" (BC.lines canonical) <> "\r\n"

scenarios :: [Scenario]
scenarios =
  [ Scenario "in place: unchanged file" [("a.json", canonical)] ["a.json"] ""
  , Scenario "in place: reformatted file" [("a.json", messy)] ["a.json"] ""
  , Scenario "in place: CRLF spelling of the canonical text" [("a.json", crlf)] ["a.json"] ""
  , Scenario "in place: several files, labels normalized" [("a.json", messy), ("sub/b.json", messy), ("c.json", canonical)] ["./a.json", "sub//b.json", "c.json"] ""
  , Scenario "in place: --fail-on-change with a change" [("a.json", messy)] ["--fail-on-change", "a.json"] ""
  , Scenario "in place: --fail-on-change without a change" [("a.json", canonical)] ["--fail-on-change", "a.json"] ""
  , Scenario "in place: indent and max-inline" [("a.json", messy)] ["--indent", "4", "--max-inline=10", "a.json"] ""
  , Scenario "in place: negative indent" [("a.json", messy)] ["--indent", "-1", "--max-inline", "0", "a.json"] ""
  , Scenario "in place: second file invalid after the first changed" [("a.json", messy), ("b.json", "{\"net\": 5}")] ["a.json", "b.json"] ""
  , Scenario "in place: invalid JSON" [("a.json", "{\"net\": }")] ["a.json"] ""
  , Scenario "in place: missing file" [] ["missing.json"] ""
  , Scenario "in place: a directory" [("d/x.json", canonical)] ["d"] ""
  , Scenario "in place: not UTF-8" [("a.json", "{\"net\": \"\xff\"}")] ["a.json"] ""
  , Scenario "in place: delay overflow" [("a.json", "{\"net\": \"m\", \"transitions\": {\"t\": {\"delay\": 1e18}}}")] ["a.json"] ""
  , Scenario "in place: unserializable path segment" [("a.json", "{\"net\": \"m\", \"arcs\": [{\"source\": [[\"x\"]], \"target\": \"y\"}]}")] ["a.json"] ""
  , Scenario "stream: stdin to stdout, changed" [] [] messy
  , Scenario "stream: stdin unchanged writes nothing" [] [] "{\"fileVersion\": \"2\", \"net\": \"m\"}\n"
  , Scenario "stream: stdin CRLF is not translated" [] [] "{\"net\": \"m\"}\r\n"
  , Scenario "stream: stdin invalid JSON" [] [] "{"
  , Scenario "stream: stdin validation error" [] [] "{\"net\": [1]}"
  , Scenario "stream: --fail-on-change" [] ["--fail-on-change"] messy
  , Scenario "stream: --infile and --outfile" [("in.json", messy)] ["--infile", "in.json", "--outfile", "out.json"] ""
  , Scenario "stream: --outfile is truncated even when unchanged" [("in.json", "{\"fileVersion\": \"2\", \"net\": \"m\"}\n"), ("out.json", "old")] ["--infile", "in.json", "--outfile", "out.json"] ""
  , Scenario "stream: --infile with CRLF is translated" [("in.json", "{\"fileVersion\": \"2\", \"net\": \"m\"}\r\n")] ["--infile", "in.json"] ""
  , Scenario "stream: --infile not UTF-8" [("in.json", "\xc3\x28")] ["--infile", "in.json"] ""
  , Scenario "stream: --infile - reads stdin" [] ["--infile", "-"] messy
  , Scenario "stream: --infile ignored when paths are given" [("a.json", messy), ("in.json", "junk")] ["--infile", "in.json", "a.json"] ""
  , Scenario "usage: missing --infile" [] ["--infile", "nope.json"] ""
  , Scenario "usage: invalid --indent" [] ["--indent", "x"] ""
  , Scenario "usage: --indent with spaces and underscores" [("a.json", messy)] ["--indent", " 1_0 ", "a.json"] ""
  , Scenario "usage: ambiguous abbreviation" [] ["--in", "x"] ""
  , Scenario "usage: abbreviation" [("a.json", messy)] ["--max", "30", "--fail", "a.json"] ""
  , Scenario "usage: unknown option" [] ["--frobnicate"] ""
  , Scenario "usage: missing value" [] ["--indent"] ""
  , Scenario "usage: -- ends options" [("-x.json", messy)] ["--", "-x.json"] ""
  , Scenario "lone surrogate: in the net name, from stdin" [] [] "{\"fileVersion\": \"2\", \"net\": \"n\\ud800\",  \"places\": {}}"
  , Scenario "lone surrogate: in names, keys and metadata, in place" [("a.json", surrogates)] ["a.json"] ""
  , Scenario "lone surrogate: through --infile and --outfile" [("in.json", surrogates)] ["--infile", "in.json", "--outfile", "out.json"] ""
  , Scenario "lone surrogate: in an arc endpoint" [] [] "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\\ud800\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\\ud800\"}, {\"source\": [\"t\\udfff\", 1], \"target\": \"p\"}]}"
  , Scenario "lone surrogate: unpaired around a valid pair" [] [] "{\"net\": \"\\ud800\\u0041\\udc00\\ud83d\\ude00\\ud800\", \"description\": \"\\udbff\"}"
  , Scenario "lone surrogate: quoted by a validation error" [] [] "{\"net\": \"m\", \"places\": {\"p\": {\"initial\": \"\\ud800\"}}}"
  , Scenario "lone surrogate: where a number, enum, literal or duration is parsed" [] [] "{\"net\": \"m\", \"places\": {\"p\": {\"initial\": \"1\\ud800\", \"interface\": \"\\udc00\"}}, \"transitions\": {\"t\": {\"delay\": \"1s\\ud800\"}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\", \"weight\": \"\\ud800\", \"kind\": \"read\\udfff\"}], \"viewState\": {\"zoom\": \"\\ud800\", \"pan\": [\"\\ud800\", 1], \"layout\": {\"p\": [\"\\udc00\", 0]}}}"
  , Scenario "lone surrogate: in a key the error location names" [] [] "{\"net\": \"m\", \"places\": {\"p\\ud800q\": {\"initial\": \"x\"}, \"a.\\udc00\": {\"initial\": []}}, \"viewState\": {\"arcWaypoints\": {\"a\\udfff\": [[\"\\ud800\", 1]]}}}"
  , Scenario "lone surrogate: in keys the model ignores" [] [] "{\"net\": \"m\", \"\\ud800\": 1, \"places\": {\"p\": {\"\\udc00\": 2}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\", \"\\ud800\": 3}], \"refs\": {\"r\\ud800\": {\"ref\": \"x\\udc00.json\", \"\\ud800\": 1}}, \"viewState\": {\"\\ud800\": 4, \"selected\": [\"p\\ud800\"]}}"
  , Scenario "lone surrogate: in the file version" [] [] "{\"fileVersion\": \"\\ud800\", \"net\": \"m\"}"
  , Scenario "lone surrogate: as the net itself" [] [] "{\"net\": {\"\\ud800\": 1}}"
  , Scenario "lone surrogate: overwritten by a repeated key" [] [] "{\"net\": \"\\ud800\", \"net\": \"m\"}"
  , Scenario "recursion: lists nested 990 deep" [] [] (deepLists 986)
  , Scenario "recursion: lists nested 991 deep" [] [] (deepLists 987)
  , Scenario "recursion: objects nested 990 deep" [] [] (deepObjects 985)
  , Scenario "recursion: objects nested 991 deep" [("a.json", deepObjects 986)] ["a.json"] ""
  , Scenario "recursion: arc metadata nested 991 deep" [] [] ("{\"net\": \"m\", \"arcs\": [{\"source\": \"a\", \"target\": \"b\", \"metadata\": {\"x\": " <> BC.replicate 987 '[' <> BC.replicate 987 ']' <> "}}]}")
  ]

-- | Lone surrogates (escaped, as JSON text can only spell them) in place
-- and transition names, metadata keys and values, and the view state.
surrogates :: ByteString
surrogates =
  "{\"net\": \"m\\udc00\", \"places\": {\"p\\udc00\": {\"initial\": 1, \"metadata\": {\"k\\ud83d\": \"\\udfff x\", \"\\ud800\": [\"\\udbff\"]}}}, \
  \\"transitions\": {\"t\": {\"metadata\": {\"\\ud801\": null}}}, \"viewState\": {\"note\": \"\\udc80\"}}"

-- | Place metadata holding @n@ nested lists (the document nests @n + 4@
-- containers deep).
deepLists :: Int -> ByteString
deepLists n = "{\"net\": \"m\", \"places\": {\"p\": {\"metadata\": {\"x\": " <> BC.replicate n '[' <> BC.replicate n ']' <> "}}}}"

-- | Place metadata holding @n@ nested objects around an empty one.
deepObjects :: Int -> ByteString
deepObjects n = "{\"net\": \"m\", \"places\": {\"p\": {\"metadata\": {\"x\": " <> mconcat (replicate n "{\"a\": ") <> "{}" <> BC.replicate n '}' <> "}}}}"

spec :: Spec
spec = describe "petrus-format-json against python -m petrus.cli.format_json" $ do
  ours <- runIO findOurs
  forM_ scenarios $ \s -> it s.title $ do
    (python, _) <- referencePython
    -- cabal test puts petrus-format-json on PATH (build-tool-depends).
    case ours of
      Nothing -> expectationFailure "petrus-format-json is not on PATH (set PETRUS_FORMAT_JSON)"
      Just exe -> do
        want <- runIn s python ["-m", "petrus.cli.format_json"]
        got <- runIn s exe []
        got.code `shouldBe` want.code
        got.out `shouldBe` want.out
        got.after `shouldBe` want.after
        lastError got.err `shouldBe` lastError want.err
  where
    findOurs = do
      env <- lookupEnv "PETRUS_FORMAT_JSON"
      maybe (findExecutable "petrus-format-json") (pure . Just) env

-- | Run one scenario in a fresh directory.
runIn :: Scenario -> FilePath -> [String] -> IO Run
runIn s exe prefix = withSystemTempDirectory "petrus-format-json" $ \dir -> do
  forM_ s.files $ \(path, bytes) -> do
    createDirectoryIfMissing True (dir </> parent path)
    BS.writeFile (dir </> path) bytes
  let process = (proc exe (prefix ++ s.args)) {cwd = Just dir, std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  (code, out, err) <- withCreateProcess process $ \mi mo me handle -> case (mi, mo, me) of
    (Just i, Just o, Just e) -> do
      BS.hPut i s.input
      hClose i
      out <- BS.hGetContents o
      err <- BS.hGetContents e
      code <- waitForProcess handle
      pure (code, out, err)
    _ -> fail "no pipes"
  files <- snapshot dir ""
  pure Run {code, out, err, after = files}
  where
    parent path = reverse (dropWhile (/= '/') (reverse path))

snapshot :: FilePath -> FilePath -> IO [(FilePath, ByteString)]
snapshot root rel = do
  names <- sort <$> listDirectory (root </> rel)
  concat <$> forM names (\n -> do
    let path = if null rel then n else rel </> n
    isFile <- doesFileExist (root </> path)
    isDir <- doesDirectoryExist (root </> path)
    if isFile
      then (\b -> [(path, b)]) <$> BS.readFile (root </> path)
      else if isDir then snapshot root path else pure [])

-- | The part of stderr both programs share: the exception text after the
-- last traceback's frames, or argparse's @error:@ message.
lastError :: ByteString -> ByteString
lastError err = case filter (": error: " `BS.isInfixOf`) ls of
  l : _ | "usage:" `BS.isPrefixOf` err -> snd (BS.breakSubstring ": error: " l)
  _ -> BC.unlines (dropWhile (" " `BS.isPrefixOf`) (afterLastTraceback ls))
  where
    ls = BC.lines err
    afterLastTraceback xs = case break ("Traceback (most recent call last):" ==) xs of
      (whole, []) -> whole
      (_, _ : rest) -> afterLastTraceback rest
