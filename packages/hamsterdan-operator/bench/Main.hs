-- | Wall-clock benchmark of the operator against the reference.
--
-- Two shapes, both timed by wall clock (monotonic), interleaved run by run
-- (the order flips every run):
--
-- * __CLI__: @python -I -B -m hamsterdan.operator@ against the
--   @hamsterdan-operator@ binary, each a fresh process with the same
--   arguments, in two identically laid out directories whose @PATH@ starts
--   with scripted fakes of @gh@ and @git@ (this benchmark binary in its
--   @--fake-provider@ mode, as in the test suite's differential).
--   Interpreter and runtime start-up and every fake process are included:
--   that is what an operator pays.
-- * __in process__: the operations called repeatedly inside one long-lived
--   interpreter (@bench/bench.py@) against the same operations called
--   repeatedly inside this process, both with a scripted runner answering
--   from the same table. Start-up excluded.
--
-- Before timing, each in-process workload runs once on each side and the
-- two results must be the same JSON (@json.dumps(result, sort_keys=True)@);
-- each CLI workload must exit with the same status and print the same
-- output on both sides.
--
-- Each cell is the median of the runs, with the minimum alongside: 21 runs
-- per CLI row and 210 per in-process row by default (@--runs N@: N and 10N).
module Main (main) where

import Control.Exception (bracket, evaluate)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fakes qualified
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Python.Object (PV (..), dumpsLine)
import Hamsterdan.Operator
import Petrus.Json (Json (..), compact, dumps)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.CPUTime (getCPUTime)
import System.Directory (canonicalizePath, createDirectoryIfMissing, findExecutable, removePathForcibly)
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv)
import System.Environment qualified as Environment
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), Handle, hClose, hGetLine, hPutStrLn, hSetBuffering)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdWrite)
import System.Process.Typed
import Text.Printf (printf)

main :: IO ()
main = do
  arguments <- getArgs
  handled <- Fakes.dispatch arguments
  unless handled $ case arguments of
    ["--runs", n] -> compareAll (read n)
    ["--repeat", name, n] -> repeatWorkload (T.pack name) (read n)
    _ -> compareAll 21

-- ---------------------------------------------------------------------------
-- Workloads

encode :: Json -> Text
encode value = either (error . show) TE.decodeUtf8 (dumps compact value)

repo :: Text -> Text
repo path = "gh api /repos/" <> repository <> path

sha :: Char -> Text
sha = T.replicate 40 . T.singleton

-- | @inspect --pr 7 --expect-hero-review@: 100 issue comments (dashboards,
-- rerun markers, readiness advisories, three-finding batches and plain
-- prose), 100 inline review comments, and 20 workflow runs of 30 jobs.
inspection :: [(Text, [Text])]
inspection =
  [ (repo "/pulls/7", [encode pull])
  , (repo "/issues/7/comments?per_page=100", [encode (Array (map issueComment [1 .. 100]))])
  , (repo "/pulls/7/comments?per_page=100", [encode (Array (map reviewComment [1 .. 100]))])
  , ( repo ("/commits/" <> hd)
    , [encode (Object [("commit", Object [("author", Object [("name", String "A")]), ("committer", Object [("name", String "C")])]), ("author", Object [("login", String "human")]), ("committer", Object [("login", String appBotLogin)])])]
    )
  , (repo ("/actions/runs?event=pull_request&head_sha=" <> hd <> "&per_page=100"), [encode (Object [("workflow_runs", Array (map run [1 .. 20]))])])
  ]
    <> [(repo ("/actions/runs/" <> tshow i <> "/attempts/1/jobs?per_page=100"), [encode (Object [("jobs", Array (map job [1 .. 30]))])]) | i <- [1 .. 20 :: Integer]]
  where
    hd = sha 'a'
    pull =
      Object
        [ ("html_url", String "https://github.test/pr/7")
        , ("state", String "open")
        , ("draft", Bool False)
        , ("head", Object [("sha", String hd), ("ref", String "hamsterdan/demo")])
        , ("base", Object [("ref", String "main"), ("repo", Object [("id", Int repositoryId)])])
        ]
    issueComment :: Integer -> Json
    issueComment i =
      Object
        [ ("id", Int i)
        , ("html_url", String ("https://github.test/comments/" <> tshow i))
        , ("user", Object [("login", String (if i `mod` 5 == 4 then "human" else appBotLogin))])
        , ("body", String (issueBody i))
        ]
    issueBody i = case i `mod` 5 of
      0 -> "dashboard prose\n<!-- hamsterdan:dashboard -->"
      1 -> "rerun prose\n<!-- hamsterdan-rerun run=" <> tshow i <> " head=" <> hd <> " operation=rerun:" <> tshow i <> " -->"
      2 -> "readiness prose\n<!-- hamsterdan:readiness operation=readiness:" <> tshow i <> " head=" <> hd <> " -->"
      3 -> batch i
      _ -> T.replicate 20 "private unrelated prose "
    batch i =
      T.concat
        [ "## Hamsterdan review findings\n\n"
        , "### `gate-1` \8212 Gate\n**blocking** \183 severity: **high**\n"
        , "Primary location: `scenario-fixtures/hero_review/gate.py:10`\n```suggestion\nfixed\n```\n"
        , "### `gate-2` \8212 Concept\nadvisory \183 severity: **low**\n"
        , "Primary location: `scenario-fixtures/hero_review/gate.py:16`\n"
        , "### `cache-1` \8212 Cache\nadvisory \183 severity: **medium**\n"
        , "Primary location: `scenario-fixtures/hero_review/cache.py:11`\n\nRelated locations:\n- `a.py:1`\n"
        , "<!-- hamsterdan:findings-digest " <> T.replicate 64 "0" <> " -->\n"
        , "<!-- hamsterdan:finding operation=review:" <> tshow i <> " head=" <> hd <> " -->"
        ]
    reviewComment :: Integer -> Json
    reviewComment i =
      Object
        [ ("id", Int (1000 + i))
        , ("html_url", String ("https://github.test/comments/" <> tshow (1000 + i)))
        , ("user", Object [("login", String appBotLogin)])
        , ("path", String "scenario-fixtures/hero_review/gate.py")
        , ("line", if even i then Int 16 else Null)
        , ("original_line", Int 10)
        , ("body", String ("inline prose\n<!-- hamsterdan:" <> (if i `mod` 3 == 0 then "reminder" else "finding") <> " operation=inline:" <> tshow i <> " head=" <> hd <> " -->"))
        ]
    run :: Integer -> Json
    run i =
      Object
        [ ("id", Int i)
        , ("name", String "ci")
        , ("run_attempt", Int 1)
        , ("head_sha", String hd)
        , ("status", String "completed")
        , ("conclusion", String "success")
        , ("html_url", String ("https://github.test/runs/" <> tshow i))
        ]
    job :: Integer -> Json
    job i = Object [("id", Int i), ("name", String ("job-" <> tshow i)), ("status", String "completed"), ("conclusion", String "success")]

-- | @inspect-authority --pr 9 --expect collaboration-clear@: 40 rules, 10
-- requested reviewers and 5 teams, 99 reviews and 100 review threads.
authorityAnswers :: [(Text, [Text])]
authorityAnswers =
  [ (repo "/pulls/9", [encode pull])
  , (repo "/git/ref/heads/authority-base", [encode (Object [("object", Object [("sha", String base)])])])
  , (repo ("/compare/" <> base <> "..." <> hd), [encode (Object [("behind_by", Int 0)])])
  , (repo "/rules/branches/authority-base?per_page=100", [encode (Array (map rule [1 .. 40]))])
  , ( repo "/pulls/9/requested_reviewers"
    , [encode (Object [("users", Array [Object [("login", String ("user-" <> tshow i))] | i <- [1 .. 10 :: Integer]]), ("teams", Array [Object [("slug", String ("team-" <> tshow i))] | i <- [1 .. 5 :: Integer]])])]
    )
  , (repo "/pulls/9/reviews?per_page=100", [encode (Array (map review [1 .. 99]))])
  , ( graphql
    , [ encode
          ( Object
              [ ( "data"
                , Object
                    [ ( "repository"
                      , Object
                          [ ( "pullRequest"
                            , Object
                                [ ("reviewDecision", String "APPROVED")
                                , ( "reviewThreads"
                                  , Object
                                      [ ("nodes", Array [Object [("id", String ("thread-" <> tshow i)), ("isResolved", Bool (even i))] | i <- [1 .. 100 :: Integer]])
                                      , ("pageInfo", Object [("hasNextPage", Bool False), ("endCursor", Null)])
                                      ]
                                  )
                                ]
                            )
                          ]
                      )
                    ]
                )
              ]
          )
      ]
    )
  ]
  where
    hd = sha 'a'
    base = sha 'b'
    graphql =
      T.unwords
        ["gh api graphql -f", "query=" <> authorityReviewFacts, "-F owner=HBNetwork -F repository=demo-pr-readiness -F number=9"]
    pull =
      Object
        [ ("html_url", String "https://github.test/pr/9")
        , ("draft", Bool False)
        , ("user", Object [("login", String "Author")])
        , ("head", Object [("sha", String hd)])
        , ("base", Object [("ref", String "authority-base")])
        , ("mergeable", Bool True)
        , ("mergeable_state", String "clean")
        ]
    rule :: Integer -> Json
    rule i
      | even i =
          Object
            [ ("type", String "required_status_checks")
            , ("parameters", Object [("strict_required_status_checks_policy", Bool (i `mod` 4 == 0)), ("required_status_checks", Array [Object [("context", String ("check-" <> tshow j))] | j <- [1 .. 5 :: Integer]])])
            ]
      | otherwise =
          Object
            [ ("type", String "pull_request")
            , ("parameters", Object [("required_approving_review_count", Int (i `mod` 3)), ("required_review_thread_resolution", Bool (i `mod` 5 == 0))])
            ]
    review :: Integer -> Json
    review i =
      Object
        [ ("id", Int i)
        , ("user", Object [("login", String ("Reviewer-" <> tshow (i `mod` 30)))])
        , ("state", String (["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED"] !! fromInteger (i `mod` 4)))
        , ("submitted_at", String ("2026-08-02T" <> T.justifyRight 2 '0' (tshow (i `mod` 24)) <> ":00:00Z"))
        ]

-- | A 2000-ref smart-HTTP projection.
refsProjection :: Text
refsProjection = T.concat [sha (hex i) <> "\trefs/heads/branch-" <> tshow i <> "\n" | i <- [1 .. 2000 :: Int]]
  where
    hex i = "0123456789abcdef" !! (i `mod` 16)

-- | The qualification setup's whole success path, given the resolved
-- @git@ and @gh@.
setupAnswers :: Text -> Text -> [(Text, [Text])]
setupAnswers git gh =
  [ (gitCommand ["init", "--quiet", "--initial-branch=main"], [""])
  , (gitCommand ["config", "user.name", "Hamsterdan", "Qualification"], [""])
  , (gitCommand ["config", "user.email", "qualification@invalid"], [""])
  , (gitCommand ["add", "qualification.txt"], [""])
  , (gitCommand ["commit", "--quiet", "-m", "base"], [""])
  , (gitCommand ["rev-parse", "HEAD"], [base <> "\n", hd <> "\n"])
  , (gitCommand ["add", "requested-change.txt"], [""])
  , (gitCommand ["commit", "--quiet", "-m", "change"], [""])
  , (gh <> " api /user", [encode (Object [("id", Int 41)])])
  , ( gh <> " api /repos/owner/target"
    , [ encode
          ( Object
              [ ("full_name", String "owner/target")
              , ("id", Int 42)
              , ("private", Bool False)
              , ("archived", Bool False)
              , ("disabled", Bool False)
              , ("size", Int 0)
              , ("default_branch", String "main")
              , ("permissions", Object [("push", Bool True)])
              ]
          )
      ]
    )
  , (gitCommand ["ls-remote", "--refs", remote], ["", exact, exact])
  , (gitCommand ["push", "--atomic", remote, base <> ":refs/heads/main", hd <> ":refs/heads/hamsterdan/ds11-live-v4"], [""])
  , (gitCommand ["ls-remote", "--refs", remote, "refs/pull/*/head"], [sha '9' <> "\trefs/pull/3/head\n"])
  , (gitCommand ["ls-remote", "--refs", remote, "refs/heads/hamsterdan/ds11-live-v4"], [hd <> "\trefs/heads/hamsterdan/ds11-live-v4\n"])
  ]
  where
    base = sha '1'
    hd = sha '2'
    remote = "https://github.com/owner/target.git"
    exact = base <> "\trefs/heads/main\n" <> hd <> "\trefs/heads/hamsterdan/ds11-live-v4\n"
    gitCommand arguments =
      T.unwords $
        [git, "-c", "credential.helper=", "-c", "credential.helper=!" <> gh <> " auth git-credential", "-c", "core.hooksPath=/dev/null", "-c", "http.followRedirects=false", "-c", "protocol.file.allow=never"]
          <> arguments

credential, target :: Text
credential = "ghs_benchmarkOnlyToken"
target = "{\"repository\": \"owner/target\", \"account_id\": 41, \"repository_id\": 42}"

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- The Haskell side, in process

-- | A workload's answer table, built and fully evaluated before timing:
-- @bench.py@ reads its tables from @workloads.json@ before timing too.
table :: [(Text, [Text])] -> IO (Map Text [Text])
table rows = do
  let answers = Map.fromList rows
  _ <- evaluate (sum [T.length value | values <- Map.elems answers, value <- values])
  pure answers

-- | @scripted(answers)@: a fresh call count per command over a prepared
-- table.
scripted :: Map Text [Text] -> IO (Text -> IO Text)
scripted answers = do
  counts <- newIORef (Map.empty :: Map Text Int)
  pure \key -> do
    index <- atomicModifyIORef' counts \m -> (Map.insertWith (+) key 1 m, Map.findWithDefault 0 key m)
    case Map.lookup key answers of
      Just values -> pure (values !! min index (length values - 1))
      Nothing -> fail ("unscripted command: " <> T.unpack key)

operatorFor :: Map Text [Text] -> IO Operator
operatorFor answers = do
  answer <- scripted answers
  let Operator {stamp, withTemporary, brokerDigest, validatorDigest, fixture} = defaultOperator
  pure
    Operator
      { runner = \command _ -> (\out -> Completed {returncode = 0, stdout = out, stderr = ""}) <$> answer (T.unwords command)
      , stamp
      , withTemporary
      , brokerDigest
      , validatorDigest
      , fixture
      }

data Sides = Sides {setupPrivate :: FilePath, git :: Text, gh :: Text}

-- | Fresh setup inputs, the system calls @bench.py@'s @prepare@ makes:
-- unlink the spent marker, then open each input @O_WRONLY | O_CREAT |
-- O_TRUNC@ @0600@, write it, close it, and chmod it.
prepareSetup :: FilePath -> IO ()
prepareSetup private = do
  removePathForcibly (private </> "push-spent")
  forM_ [("credential", credential), ("target.json", target)] \(name, content) -> do
    let path = private </> name
    bracket (openFd path WriteOnly defaultFileFlags {creat = Just 0o600, trunc = True, cloexec = True}) closeFd \fd ->
      void (fdWrite fd (TE.encodeUtf8 content))
    setFileMode path 0o600

haskellWorkload :: Sides -> Text -> IO (IO PV)
haskellWorkload sides name = case name of
  "inspect" -> do
    answers <- table inspection
    pure do
      op <- operatorFor answers
      inspect op 7 defaultInspectOptions {expectHeroReview = True}
  "authority" -> do
    answers <- table authorityAnswers
    pure do
      op <- operatorFor answers
      inspectAuthority op 9 "collaboration-clear"
  "refs" -> do
    raw <- evaluate (TE.encodeUtf8 refsProjection)
    pure do
      refs <- either (fail . show) pure (parseSetupRefs raw)
      pure (PDict [(reference, PStr hash) | (reference, hash) <- refs])
  "setup" -> do
    answers <- table (setupAnswers sides.git sides.gh)
    prepareSetup sides.setupPrivate
    pure do
      answer <- scripted answers
      let setupRunner command _ _ _ = (\out -> SetupCompleted {returncode = 0, stdout = TE.encodeUtf8 out, stderr = ""}) <$> answer (T.unwords command)
      qualificationSetup setupRunner (sides.setupPrivate </> "credential") (sides.setupPrivate </> "target.json") (sides.setupPrivate </> "push-spent")
  _ -> fail ("unknown workload " <> T.unpack name)

-- | Force a result completely (the Python side's result is a built dict;
-- encoding it is not part of either side's timed region).
forced :: PV -> Int
forced = \case
  PNone -> 0
  PBool b -> fromEnum b
  PInt n -> fromInteger (n `mod` 2)
  PFloat d -> if d > 0 then 1 else 0
  PStr t -> T.length t
  PBytes b -> BS.length b
  PList items -> foldl' (\acc item -> acc + forced item) 0 items
  PDict members -> foldl' (\acc (key, item) -> acc + T.length key + forced item) 0 members

-- ---------------------------------------------------------------------------
-- Running

data Server = Server {toServer :: Handle, fromServer :: Handle}

ask :: Server -> String -> IO String
ask server request = hPutStrLn server.toServer request >> hGetLine server.fromServer

-- | A temporary workspace: stub @git@ and @gh@ first on @PATH@ (the
-- qualification setup resolves them; the scripted runner never executes
-- them), one private directory per side, and the workloads' description
-- for @bench.py@.
data Workspace = Workspace {tmp :: FilePath, sides :: Sides, workloads :: Json}

withWorkspace :: (Workspace -> IO a) -> IO a
withWorkspace continue =
  withSystemTempDirectory "hamsterdan-operator-bench" \temporary -> do
    tmp <- canonicalizePath temporary
    let tools = tmp </> "tools"
    createDirectoryIfMissing True tools
    forM_ ["git", "gh"] \tool -> writeFile (tools </> tool) "#!/bin/sh\nexit 97\n" >> setFileMode (tools </> tool) 0o755
    inherited <- lookupEnv "PATH"
    Environment.setEnv "PATH" (tools <> maybe "" (":" <>) inherited)
    forM_ ["py", "hs"] \side -> createDirectoryIfMissing True (tmp </> side </> "private") >> setFileMode (tmp </> side </> "private") 0o700
    let gitPath = T.pack (tools </> "git")
        ghPath = T.pack (tools </> "gh")
        workloads =
          Object
            [ ("inspect", Object [("answers", answersJson inspection)])
            , ("authority", Object [("answers", answersJson authorityAnswers)])
            , ("refs", Object [("raw", String refsProjection)])
            , ( "setup"
              , Object
                  [ ("answers", answersJson (setupAnswers gitPath ghPath))
                  , ("private", String (T.pack (tmp </> "py" </> "private")))
                  , ("credential", String credential)
                  , ("target", String target)
                  ]
              )
            ]
    continue
      Workspace
        { tmp
        , sides = Sides {setupPrivate = tmp </> "hs" </> "private", git = gitPath, gh = ghPath}
        , workloads
        }
  where
    answersJson rows = Object [(k, Array (map String vs)) | (k, vs) <- rows]

-- | One timed run of an in-process workload on the Haskell side.
timedRun :: Sides -> Text -> IO Double
timedRun sides name = fst <$> measuredRun sides name

-- | One run's wall-clock and process CPU (user and system) seconds.
measuredRun :: Sides -> Text -> IO (Double, Double)
measuredRun sides name = do
  action <- haskellWorkload sides name
  cpuStart <- getCPUTime
  start <- getMonotonicTime
  result <- action
  _ <- evaluate (forced result)
  end <- getMonotonicTime
  cpuEnd <- getCPUTime
  pure (end - start, fromIntegral (cpuEnd - cpuStart) * 1.0e-12)

-- | @--repeat NAME N@: only the Haskell side of one in-process workload,
-- N times, for profiling (@+RTS -s@, or @-p@ with a profiling build): the
-- median and minimum wall clock, and the mean CPU time, per run.
repeatWorkload :: Text -> Int -> IO ()
repeatWorkload name runs = withWorkspace \workspace -> do
  measured <- forM [1 .. runs] \_ -> measuredRun workspace.sides name
  let (times, cpu) = unzip measured
  printf
    "%s: median %s, min %s, mean CPU %s over %d runs\n"
    name
    (duration (median times))
    (duration (minimum times))
    (duration (sum cpu / fromIntegral runs))
    runs

compareAll :: Int -> IO ()
compareAll runs = do
  root <- repoRoot
  python <- upstreamPythonExecutable "hamsterdan"
  port <- operatorBinary
  self <- getExecutablePath
  withWorkspace \workspace -> do
    let tmp = workspace.tmp
    inherited <- getEnvironment
    BS.writeFile (tmp </> "workloads.json") (either (error . show) id (dumps compact workspace.workloads))
    putStrLn "| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell | Haskell ahead |"
    putStrLn "| --- | --- | ---: | ---: | ---: | ---: |"
    forM_ cliWorkloads \(label, argv, answers) -> do
      (hs, py) <- cli tmp self python port runs argv answers
      row label "CLI (fresh process)" hs py
    let script = root </> "packages" </> "hamsterdan-operator" </> "bench" </> "bench.py"
        config = setEnv inherited $ setStdin createPipe $ setStdout createPipe $ proc python ["-I", "-B", script, tmp </> "workloads.json"]
    withProcessWait_ config \process -> do
      let server = Server (getStdin process) (getStdout process)
      hSetBuffering server.toServer LineBuffering
      ready <- hGetLine server.fromServer
      when (ready /= "ready") $ fail ("bench.py: " <> ready)
      forM_ inProcessWorkloads \(name, label) -> do
        mine <- haskellWorkload workspace.sides name >>= id >>= either (fail . show) pure . dumpsLine
        theirs <- ask server ("check " <> T.unpack name)
        unless (TE.decodeUtf8 mine == T.pack theirs) $
          fail ("the " <> T.unpack name <> " results differ:\n  haskell " <> show mine <> "\n  python  " <> theirs)
        pairs <- forM [1 .. 10 * runs] \index -> do
          let hsRun = timedRun workspace.sides name
              pyRun = read <$> ask server ("run " <> T.unpack name)
          if even index then (,) <$> hsRun <*> pyRun else (\py hs -> (hs, py)) <$> pyRun <*> hsRun
        let (hs, py) = unzip pairs
        row label "in process" hs py
      hClose server.toServer

inProcessWorkloads :: [(Text, String)]
inProcessWorkloads =
  [ ("inspect", "inspect, hero review (200 comments, 20 runs of 30 jobs)")
  , ("authority", "inspect-authority (40 rules, 99 reviews, 100 threads)")
  , ("refs", "Git ref projection parse (2000 refs)")
  , ("setup", "qualification-setup success path (scripted Git and gh)")
  ]

cliWorkloads :: [(String, [String], [(Text, [Json])])]
cliWorkloads =
  [ ("`--help`", ["--help"], [])
  , ("`preflight`", ["preflight"], preflightAnswers)
  , ("`inspect --pr 7 --expect-hero-review` (25 fake `gh` calls)", ["inspect", "--pr", "7", "--expect-hero-review"], [(k, map answer vs) | (k, vs) <- inspection])
  ]
  where
    answer out = Object [("stdout", String out), ("returncode", Int 0)]
    preflightAnswers =
      [ ("gh auth status", [answer ""])
      , ("gh api /orgs/HBNetwork", [answer (encode (Object [("id", Int orgId)]))])
      , (repo "", [answer (encode (Object [("id", Int repositoryId), ("private", Bool False), ("default_branch", String "main")]))])
      , (repo "/actions/workflows?per_page=100", [answer (encode (Object [("workflows", Array [Object [("name", String "ci")], Object [("name", String "rerun-broker")]])]))])
      , ( repo "/contents/.github/workflows/rerun-broker.yml?ref=main -H Accept: application/vnd.github.raw+json"
        , [ answer
              ( T.unlines
                  [ legacyBrokerAuthorization
                  , "startsWith(github.event.comment.body, '<!-- impetus-rerun ')"
                  , "marker = re.fullmatch(r\"<!-- impetus-rerun run=([1-9][0-9]*) head=x operation=x -->\", body)"
                  ]
              )
          ]
        )
      ]

-- | Both CLIs, interleaved run by run, each in its own directory with the
-- scripted fakes first on PATH.
cli :: FilePath -> FilePath -> FilePath -> FilePath -> Int -> [String] -> [(Text, [Json])] -> IO ([Double], [Double])
cli tmp self python port runs argv answers = do
  inherited <- getEnvironment
  let sideDir name = tmp </> ("cli-" <> name)
      prepare side = do
        removePathForcibly side
        createDirectoryIfMissing True (side </> "bin")
        createDirectoryIfMissing True (side </> "tmp")
        forM_ ["gh", "git", "curl", "python"] \tool -> do
          writeFile (side </> "bin" </> tool) (Fakes.wrapperScript self ["--fake-provider", side, tool])
          setFileMode (side </> "bin" </> tool) 0o755
        BS.writeFile (side </> "responses.json") (either (error . show) id (dumps compact (Object [(k, Array v) | (k, v) <- answers])))
      config side program arguments =
        setWorkingDir side $
          setEnv
            ( [("PATH", side </> "bin:/usr/bin:/bin"), ("TMPDIR", side </> "tmp"), ("COLUMNS", "80")]
                <> [(k, v) | (k, v) <- inherited, k `notElem` ["PATH", "TMPDIR", "COLUMNS"]]
            )
            (proc program arguments)
      timed side program arguments = do
        removePathForcibly (side </> "calls.log")
        start <- getMonotonicTime
        (status, out, _) <- readProcess (config side program arguments)
        end <- getMonotonicTime
        pure (end - start, status, out)
      pySide = sideDir "py"
      hsSide = sideDir "hs"
      pyRun = timed pySide python (["-I", "-B", "-m", "hamsterdan.operator"] <> argv)
      hsRun = timed hsSide port (argv <> ["+RTS", "-M2G", "-RTS"])
  prepare pySide
  prepare hsSide
  (_, pyStatus, pyOut) <- pyRun
  (_, hsStatus, hsOut) <- hsRun
  unless (pyStatus == hsStatus && BL.toStrict pyOut == BL.toStrict hsOut) $
    fail ("the CLI outputs differ for " <> unwords argv <> ": " <> show (pyStatus, pyOut) <> " against " <> show (hsStatus, hsOut))
  pairs <- forM [1 .. runs] \index -> do
    let first (t, _, _) = t
    if even index
      then (\hs py -> (first hs, first py)) <$> hsRun <*> pyRun
      else (\py hs -> (first hs, first py)) <$> pyRun <*> hsRun
  pure (unzip pairs)

row :: String -> String -> [Double] -> [Double] -> IO ()
row label shape hs py =
  printf
    "| %s | %s | %s (%s) | %s (%s) | %.2f× | %d of %d |\n"
    label
    shape
    (duration (median hs))
    (duration (minimum hs))
    (duration (median py))
    (duration (minimum py))
    (median py / median hs)
    -- the runs are paired (interleaved run by run): Haskell's wins
    (length (filter id (zipWith (<) hs py)))
    (length hs)

median :: [Double] -> Double
median xs = let sorted = sort xs in sorted !! (length sorted `div` 2)

duration :: Double -> String
duration seconds
  | seconds >= 1 = printf "%.2f s" seconds
  | seconds >= 1.0e-3 = printf "%.2f ms" (seconds * 1000)
  | otherwise = printf "%.1f µs" (seconds * 1.0e6)

operatorBinary :: IO FilePath
operatorBinary =
  lookupEnv "HAMSTERDAN_OPERATOR" >>= \case
    Just path -> pure path
    Nothing -> findExecutable "hamsterdan-operator" >>= maybe (fail "hamsterdan-operator is not on PATH") pure
