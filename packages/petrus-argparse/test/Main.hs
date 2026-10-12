-- | petrus-argparse against the pinned interpreter's @argparse@: the same
-- parsers built on both sides (@test/argparse_reference.py@), and every
-- case's exit status, stdout, stderr and namespace compared. The cases
-- cover parsing, the error messages, help and usage at several widths, and
-- the colors @_colorize@ chooses from the environment and the terminal.
-- The typed declarations ("Petrus.Argparse") are checked to read back
-- what the namespace holds.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Argparse
import Petrus.Argparse.Parser (Action (..), Behavior (..), Namespace, Parser (..), Value (..), ValueType (..), parseArgs, plainTheme)
import Petrus.Json (Json (..), compact, dumps, parseJson, surrogateRefusingLoads)
import Petrus.Json.Python (pythonDoubleRepr, pythonStrRepr)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Exit (ExitCode (..))
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- The parsers

data Provider = Local | Absurd | ZeroMQ
  deriving stock (Eq, Show)

data Worker = Worker
  { provider :: Provider
  , registry :: Text
  , queue :: [Text]
  , workerId :: Maybe Text
  , mode :: Text
  , concurrency :: Integer
  , pollInterval :: Double
  , verbose :: Bool
  , out :: Maybe Text
  , limit :: Maybe Integer
  , ratio :: Maybe Double
  }
  deriving stock (Eq, Show)

-- | Options only, as the Worker entry point declares them, with a short
-- flag, a short option and a path.
worker :: ArgumentParser Worker
worker =
  ArgumentParser "python -m petrus.motus.worker" (Just "Provider and transport selection for the Worker process entry point, with a description long enough to wrap at the narrower widths.") $
    Worker
      <$> required (choice [("local", Local), ("absurd", Absurd), ("zeromq", ZeroMQ)]) ["--provider"] []
      <*> required str ["--registry"] [help "module:attribute of the Activity registry"]
      <*> appended str ["--queue"] [help "subscribed queue (repeatable)"]
      <*> option str ["--worker-id"] [help "optional operational Worker label"]
      <*> defaulted (oneOf ["sync", "async"]) ["--execution-mode"] "sync" []
      <*> defaulted int ["--concurrency"] 1 [help "positive AsyncWorker Activity-slot concurrency"]
      <*> defaulted float ["--poll-interval"] 0.25 []
      <*> flag ["-v", "--verbose"] [help "say more about what happens, over several words so that the help wraps"]
      <*> option path ["-o", "--out"] [help "where to write"]
      <*> option int ["--limit"] [metavar "N"]
      <*> option float ["--ratio-of-something-quite-long"] [dest "ratio"]

data Command = Serve | Inspect
  deriving stock (Eq, Show)

data Host = Host
  { command :: Command
  , delivery :: Maybe Text
  , pr :: Maybe Integer
  , host :: Text
  , port :: Integer
  , identities :: [Text]
  }
  deriving stock (Eq, Show)

-- | A positional choice before options, as @python -m hamsterdan.host@
-- declares it.
hostParser :: ArgumentParser Host
hostParser =
  ArgumentParser "python -m hamsterdan.host" (Just "Run or validate the Hamsterdan GitHub App host. Credentials are supplied by the selected Environment.") $
    Host
      <$> positional (choice [("serve", Serve), ("inspect-instance", Inspect)]) "command" []
      <*> option str ["--delivery"] [help "canonical failed GitHub delivery UUID to requeue"]
      <*> option int ["--pr"] []
      <*> defaulted str ["--host"] "127.0.0.1" []
      <*> defaulted int ["--port"] 8000 []
      <*> appended path ["--identity"] [help "extra run-identity file to copy into identity/ (repeatable)"]

data Operation
  = Preflight (Maybe Text)
  | Create Text
  | PrepareBroker
  | Check Integer Text Bool Bool
  | Setup Text Text
  deriving stock (Eq, Show)

-- | Required subcommands, as @python -m hamsterdan.operator@ declares them.
operator :: ArgumentParser (Text, Operation)
operator =
  ArgumentParser "python -m hamsterdan.operator" Nothing $
    subcommands
      "command"
      [ ("preflight", (,) "preflight" . Preflight <$> option str ["--health-url"] [])
      , ("create", (,) "create" . Create <$> required (oneOf ["hero-review", "flake"]) ["--scenario"] [])
      , ("prepare-broker", pure ("prepare-broker", PrepareBroker))
      ,
        ( "inspect"
        , (,) "inspect"
            <$> ( Check
                    <$> required int ["--pr"] []
                    <*> defaulted str ["--bot-login"] "hamsterdan[bot]" []
                    <*> flag ["--expect-hero-review"] []
                    <*> defaulted (choice [("present", True), ("absent", False)]) ["--expect-readiness"] True []
                )
        )
      , ("qualification-setup", (,) "qualification-setup" <$> (Setup <$> required path ["--credential-file"] [] <*> required path ["--target-file"] []))
      ]

-- ---------------------------------------------------------------------------
-- The cases

data Case = Case
  { parserIndex :: Int
  , argv :: [Text]
  , env :: Map String String
  , tty :: Bool
  }

columns :: String -> Map String String
columns width = Map.fromList [("COLUMNS", width)]

with :: [(String, String)] -> Map String String
with = Map.union (columns "80") . Map.fromList

cases :: [Case]
cases =
  -- Help and usage errors at several widths, plain.
  [ Case index argv' (columns width) False
  | index <- [0, 1, 2]
  , width <- ["20", "40", "60", "80", "120", "200"]
  , argv' <- [["-h"], ["--bogus"]]
  ]
    -- Colors: the environment's say, then the terminal's.
    <> [ Case index argv' (with environment) terminal
       | index <- [0, 1, 2]
       , argv' <- [["-h"], [], ["--bogus"]]
       , (environment, terminal) <-
           [ ([("FORCE_COLOR", "1")], False)
           , ([("FORCE_COLOR", "")], False)
           , ([("FORCE_COLOR", "1"), ("NO_COLOR", "1")], False)
           , ([("FORCE_COLOR", "1"), ("TERM", "dumb")], False)
           , ([("PYTHON_COLORS", "1")], False)
           , ([("PYTHON_COLORS", "0"), ("FORCE_COLOR", "1")], False)
           , ([("PYTHON_COLORS", "1"), ("NO_COLOR", "1")], False)
           , ([("PYTHON_COLORS", "2"), ("NO_COLOR", "1"), ("FORCE_COLOR", "1")], False)
           , ([], True)
           , ([("TERM", "dumb")], True)
           , ([("NO_COLOR", "1")], True)
           , ([("NO_COLOR", "")], True)
           , ([("TERM", "xterm")], True)
           ]
       ]
    <> [Case index argv' (Map.insert "FORCE_COLOR" "1" (columns width)) False | index <- [0, 1, 2], width <- ["20", "50"], argv' <- [["-h"], ["--bogus"]]]
    <> [Case 2 [sub, "-h"] (with environment) False | sub <- ["inspect", "create", "prepare-broker"], environment <- [[], [("FORCE_COLOR", "1")]]]
    -- Parsing the worker's options.
    <> [ Case 0 argv' (columns "80") False
       | argv' <-
           [ ["--provider", "local", "--registry", "a:b"]
           , ["--provider=zeromq", "--reg", "a:b", "--queue", "one", "--queue=two", "--queue", "one", "--worker-id", "w1"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", " 7 ", "--poll-interval", "1e3"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", "1_000", "--poll-interval", "-inf"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", "-5", "--poll-interval", "-.5"]
           , ["--provider", "local", "--registry", "a:b", "--poll-interval", "nan", "--limit", "+3"]
           , ["--provider", "local", "--registry", "a:b", "-v", "-o", "/tmp//x/./y/", "--ratio", "0.5"]
           , ["--provider", "local", "--registry", "a:b", "-vo", "out"]
           , ["--provider", "local", "--registry", "a:b", "-oout", "--out=", "--execution-mode", "async"]
           , ["--provider", "local", "--registry", "a:b", "--verb"]
           , ["--provider", "local", "--registry", "--", "a:b"]
           , []
           , ["--provider"]
           , ["--provider", "x"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", "x"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", "1.5"]
           , ["--provider", "local", "--registry", "a:b", "--concurrency", "1__0"]
           , ["--provider", "local", "--registry", "a:b", "--poll-interval", "fast"]
           , ["--provider", "local", "--registry", "a:b", "--poll-interval", "1e"]
           , ["--provider", "local", "--registry", "a:b", "--c", "3"]
           , ["--provider", "local", "--registry", "a:b", "--verbose=yes"]
           , ["--provider", "local", "--registry", "a:b", "-vx"]
           , ["--provider", "local", "--registry", "a:b", "stray", "--bar"]
           , ["--provider", "local", "--registry", "a:b", "--execution-mode", "Sync"]
           , ["--provider", "local", "--registry", "a:b", "--limit", "-1", "-x"]
           , ["--provider", "local", "--registry", "a:b", "--limit", T.replicate 4301 "9"]
           ]
       ]
    -- Parsing the host's positional and options.
    <> [ Case 1 argv' (columns "80") False
       | argv' <-
           [ ["serve"]
           , ["serve", "--host", "0.0.0.0", "--port", "9000"]
           , ["--pr", "7", "inspect-instance", "--identity", "a//b", "--identity", "."]
           , ["inspect-instance", "--pr", "-7"]
           , ["--", "serve"]
           , ["serve", "extra"]
           , ["bogus"]
           , []
           , ["serve", "--port"]
           , ["serve", "--delivery", "-x"]
           ]
       ]
    -- Parsing the operator's subcommands.
    <> [ Case 2 argv' (columns "80") False
       | argv' <-
           [ ["preflight"]
           , ["preflight", "--health-url", "http://x"]
           , ["create", "--scenario", "flake"]
           , ["create", "--scenario", "nope"]
           , ["create"]
           , ["prepare-broker", "--x"]
           , ["inspect", "--pr", "59", "--expect-hero-review", "--expect-readiness", "absent"]
           , ["inspect", "--pr", "59", "--bot", "me"]
           , ["qualification-setup", "--credential-file", "c", "--target-file", "t//"]
           , ["insp", "--pr", "1"]
           , []
           , ["--bogus", "preflight"]
           ]
       ]

-- ---------------------------------------------------------------------------
-- The comparison

parsers :: [Parser]
parsers = [parser worker, parser hostParser, parser operator]

-- | The case's formatting as a process computes it ('formattingFor')
-- from its environment and terminal.
formatting :: Case -> Formatting
formatting theCase = formattingOf theCase.env (fromMaybe 80 (environmentColumns theCase.env)) theCase.tty

actionJson :: Action -> Json
actionJson action = case action.behavior of
  Subcommands subparsers ->
    Object [("action", String "subparsers"), ("dest", String action.dest), ("parsers", Array [Array [String name, Array (map actionJson (drop 1 sub.actions))] | (name, sub) <- subparsers])]
  behavior ->
    Object $
      [ ("strings", Array (map String action.optionStrings))
      , ("dest", String action.dest)
      , ( "action"
        , String $ case behavior of
            Append -> "append"
            StoreTrue -> "store_true"
            _ -> "store"
        )
      , ( "type"
        , String $ case action.valueType of
            AsStr -> "str"
            AsInt -> "int"
            AsFloat -> "float"
            AsPath -> "path"
        )
      , ("choices", maybe Null (Array . map String) action.choices)
      , ("help", maybe Null String action.help)
      , ("metavar", maybe Null String action.metavar)
      , ("required", Bool action.required)
      ]
        <> [("default", valueJson value) | Just value <- [action.defaultValue], value /= None]

valueJson :: Value -> Json
valueJson = \case
  None -> Null
  Str text -> String text
  IntValue value -> Int value
  FloatValue value -> Float value
  BoolValue value -> Bool value
  List values -> Array (map valueJson values)

valueRepr :: Value -> Text
valueRepr = \case
  None -> "None"
  Str text -> pythonStrRepr text
  IntValue value -> T.pack (show value)
  FloatValue value -> pythonDoubleRepr value
  BoolValue value -> if value then "True" else "False"
  List values -> "[" <> T.intercalate ", " (map valueRepr values) <> "]"

namespaceJson :: Namespace -> Json
namespaceJson namespace = Array [Array [String key, String (valueRepr value)] | (key, value) <- sortOn fst (Map.toList namespace)]

portOutcome :: Parser -> Case -> Json
portOutcome declared theCase = case parseArgs (formatting theCase) declared theCase.argv of
  Parsed namespace -> Object [("code", Int 0), ("stdout", String ""), ("stderr", String ""), ("namespace", namespaceJson namespace)]
  Exited status printed problems -> Object [("code", Int (toInteger status)), ("stdout", String printed), ("stderr", String problems), ("namespace", Null)]

main :: IO ()
main = hspec $ do
  describe "argparse against the pinned CPython (argparse_reference.py)" $
    it "parses, refuses, formats and colors every case as CPython 3.14 does" $ do
      executable <- upstreamPythonExecutable "petrus"
      root <- repoRoot
      let script = root <> "/packages/petrus-argparse/test/argparse_reference.py"
          query =
            Object
              [ ("parsers", Array [Object [("prog", String p.prog), ("description", maybe Null String p.description), ("actions", Array (map actionJson (drop 1 p.actions)))] | p <- parsers])
              , ("cases", Array [Object [("parser", Int (toInteger c.parserIndex)), ("argv", Array (map String c.argv)), ("env", Object [(T.pack k, String (T.pack v)) | (k, v) <- Map.toList c.env]), ("tty", Bool c.tty)] | c <- cases])
              ]
          payload = either (error . show) id (dumps compact query)
      (exit, output, problems) <- readProcess (setStdin (byteStringInput (BL.fromStrict payload)) (proc executable ["-B", "-P", script]))
      unless (exit == ExitSuccess) $ expectationFailure ("the oracle failed: " <> BC.unpack (BL.toStrict problems))
      results <- case parseJson surrogateRefusingLoads (BL.toStrict output) of
        Right (Array items) -> pure items
        other -> expectationFailure ("unreadable oracle output: " <> show other) >> pure []
      length results `shouldBe` length cases
      -- Not vacuous: some cases parse, some print colored help or usage.
      let member key = \case
            Object members -> lookup key members
            _ -> Nothing
          colored key = length [() | r <- results, Just (String text) <- [member key r], "\ESC[" `T.isInfixOf` text]
      length [() | r <- results, Just (Array _) <- [member "namespace" r]] `shouldSatisfy` (> 15)
      colored "stdout" `shouldSatisfy` (> 20)
      colored "stderr" `shouldSatisfy` (> 20)
      forM_ (zip cases results) $ \(theCase, reference) -> do
        let ours = maybe Null (`portOutcome` theCase) (lookup theCase.parserIndex (zip [0 ..] parsers))
        unless (ours == reference) $
          expectationFailure
            ( "parser " <> show theCase.parserIndex <> " " <> show theCase.argv <> " " <> show (Map.toList theCase.env) <> " tty=" <> show theCase.tty
                <> "\n  reference: " <> show reference
                <> "\n  port:      " <> show ours
            )

  describe "typed declarations (Petrus.Argparse)" $ do
    let plain = Formatting {width = 78, theme = plainTheme}
        decoded :: ArgumentParser a -> [Text] -> Outcome a
        decoded = parse plain
    it "read back each option at its type, under its own destination" $ do
      decoded worker ["--provider", "zeromq", "--registry", "a:b", "--queue", "q", "--queue", "r", "-vo", "x//y", "--ratio", "2", "--limit", "+3"]
        `shouldBe` Parsed
          Worker
            { provider = ZeroMQ
            , registry = "a:b"
            , queue = ["q", "r"]
            , workerId = Nothing
            , mode = "sync"
            , concurrency = 1
            , pollInterval = 0.25
            , verbose = True
            , out = Just "x/y"
            , limit = Just 3
            , ratio = Just 2
            }
      decoded hostParser ["inspect-instance", "--pr", "7", "--port", "1"]
        `shouldBe` Parsed Host {command = Inspect, delivery = Nothing, pr = Just 7, host = "127.0.0.1", port = 1, identities = []}
    it "decode the chosen subcommand by its own arguments" $ do
      decoded operator ["inspect", "--pr", "59", "--expect-readiness", "absent"] `shouldBe` Parsed ("inspect", Check 59 "hamsterdan[bot]" False False)
      decoded operator ["prepare-broker"] `shouldBe` Parsed ("prepare-broker", PrepareBroker)
      decoded operator ["qualification-setup", "--credential-file", "c", "--target-file", "./t/"] `shouldBe` Parsed ("qualification-setup", Setup "c" "t")
    it "exit as the parser does on help and on errors" $ do
      case decoded worker ["-h"] of
        Exited 0 printed "" -> printed `shouldSatisfy` T.isPrefixOf "usage: python -m petrus.motus.worker"
        other -> expectationFailure (show (() <$ other))
      (() <$ decoded worker []) `shouldBe` Exited 2 "" (errorText plain worker "the following arguments are required: --provider, --registry")
