{-# LANGUAGE MultiWayIf #-}

-- | @tests/integration/host/test_git_publish.py@: the privileged Git
-- publication boundary; all remotes are local.
module GitPublishSpec
  ( spec
  , gitIn
  , Repository (..)
  , withRepository
  , LocalAuthority (..)
  , newLocalAuthority
  , localAuthority
  , diffFor
  ) where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol (CodingResult (..))
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models
  ( BoundaryKind (..)
  , GitHubBoundaryError (..)
  , GraphQLTransport (..)
  , PullRequestSnapshot (..)
  , Transport (..)
  , WireResponse (..)
  , boundary
  )
import Hamsterdan.Host.GitPublish
import Petrus.Json (Json (..))
import System.Directory (doesFileExist, removeFile)
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), proc, readCreateProcess)
import Test.Hspec
import TestSupport (withTempRoot)

-- ---------------------------------------------------------------------------
-- Local Git fixtures

-- | @git(root, *arguments, input_text=)@: stripped standard output.
gitIn :: FilePath -> [String] -> Maybe String -> IO Text
gitIn root arguments input = T.strip . T.pack <$> readCreateProcess (proc "git" ("-C" : root : arguments)) (maybe "" id input)

gitEnv :: FilePath -> [(String, String)] -> [String] -> Maybe ByteString -> IO Text
gitEnv root extra arguments input = do
  ambient <- getEnvironment
  let environment = [(k, v) | (k, v) <- ambient, k `notElem` map fst extra] ++ extra
  T.strip . T.pack
    <$> readCreateProcess ((proc "git" ("-C" : root : arguments)) {env = Just environment}) (maybe "" (T.unpack . TE.decodeLatin1) input)

data Repository = Repository {root :: FilePath, remote :: FilePath, first :: Text, second :: Text, tmp :: FilePath}

withRepository :: (Repository -> IO a) -> IO a
withRepository action = withTempRoot $ \tmp -> do
  let remote = tmp </> "remote.git"
      root = tmp </> "work"
  _ <- readCreateProcess (proc "git" ["init", "--bare", "-q", remote]) ""
  _ <- readCreateProcess (proc "git" ["clone", "-q", remote, root]) ""
  _ <- gitIn root ["config", "user.name", "Test"] Nothing
  _ <- gitIn root ["config", "user.email", "test@example.invalid"] Nothing
  _ <- gitIn root ["config", "commit.gpgsign", "false"] Nothing
  writeFile (root </> "file.txt") "one\n"
  _ <- gitIn root ["add", "file.txt"] Nothing
  _ <- gitIn root ["commit", "-qm", "one"] Nothing
  first <- gitIn root ["rev-parse", "HEAD"] Nothing
  _ <- gitIn root ["push", "-q", "origin", "HEAD:refs/heads/topic"] Nothing
  writeFile (root </> "file.txt") "two\n"
  _ <- gitIn root ["commit", "-qam", "two"] Nothing
  second <- gitIn root ["rev-parse", "HEAD"] Nothing
  action Repository {root, remote, first, second, tmp}

-- ---------------------------------------------------------------------------
-- Scripted authority

data Scripted = Scripted
  { calls :: IORef [(Text, Text, Maybe [(Text, Json)])]
  , responses :: IORef [WireResponse]
  , casCalls :: IORef [(Text, Text, Text, Text)]
  , casFail :: IORef Bool
  }

newScripted :: IO Scripted
newScripted = Scripted <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef False

scriptedTransport :: Scripted -> Transport
scriptedTransport s =
  Transport
    { request = \method path body -> do
        modifyIORef' s.calls (++ [(method, path, body)])
        readIORef s.responses >>= \case
          r : rest -> writeIORef s.responses rest >> pure r
          [] -> fail "no scripted response"
    , pages = \_ -> fail "unexpected pages"
    }

scriptedAuthority :: Scripted -> IO PublicationAuthority
scriptedAuthority s = do
  authority <-
    either (fail . show) pure $
      Gateway.githubAuthority
        (scriptedTransport s)
        "owner/repo"
        7
        ( Just
            GraphQLTransport
              { reviewThreads = \_ _ _ -> pure []
              , resolveReviewThread = \_ -> pure ()
              , compareAndSwapRef = \repository ref expected commit -> do
                  modifyIORef' s.casCalls (++ [(repository, ref, expected, commit)])
                  failing <- readIORef s.casFail
                  if failing then throwIO (boundary "stale") else pure ()
              }
        )
  let base = publicationAuthority authority
  pure
    PublicationAuthority
      { repository = base.repository
      , pullRequest = fail "unexpected pull request read"
      , createTree = base.createTree
      , createCommit = base.createCommit
      , compareAndSwapRef = base.compareAndSwapRef
      }

scriptedPublisher :: Scripted -> FilePath -> IO HostGitPublisher
scriptedPublisher s remote = do
  authority <- scriptedAuthority s
  hostGitPublisher authority (T.pack remote)

created :: Text -> WireResponse
created sha = WireResponse 201 (Object [("sha", String sha)]) Nothing

-- ---------------------------------------------------------------------------
-- Local publication authority

data LocalAuthority = LocalAuthority
  { headRef :: IORef Text
  , baseRef :: Text
  , createdShas :: IORef (Set.Set Text)
  , casCount :: IORef Int
  , lagProjection :: IORef Bool
  , work :: FilePath
  , remotePath :: FilePath
  }

newLocalAuthority :: FilePath -> FilePath -> Text -> IO LocalAuthority
newLocalAuthority work remotePath head' = do
  headRef <- newIORef head'
  createdShas <- newIORef Set.empty
  casCount <- newIORef 0
  lagProjection <- newIORef False
  pure LocalAuthority {headRef, baseRef = head', createdShas, casCount, lagProjection, work, remotePath}

snapshot :: LocalAuthority -> IO PullRequestSnapshot
snapshot a = do
  h <- readIORef a.headRef
  pure
    PullRequestSnapshot
      { repository = "owner/repo"
      , number = 7
      , state = "open"
      , draft = False
      , head = h
      , base = a.baseRef
      , headRef = "topic"
      , baseRef = "main"
      , mergeable = Bool True
      , merged = False
      , closed = False
      , author = "qualifier"
      , mergeableState = "clean"
      , url = "https://example.invalid/pull/7"
      , headRepository = "owner/repo"
      }

localObjectTransport :: LocalAuthority -> Transport
localObjectTransport a =
  Transport
    { request = \method path body -> do
        method `shouldBe` "POST"
        members <- maybe (fail "missing body") pure body
        let field k = maybe Null id (lookup k members)
            text k = case field k of String t -> t; _ -> ""
        sha <-
          if
            | "/git/blobs" `T.isSuffixOf` path -> do
                content <- either fail pure (Base64.decode (TE.encodeUtf8 (text "content")))
                gitEnv a.work [] ["hash-object", "-w", "--stdin"] (Just content)
            | "/git/trees" `T.isSuffixOf` path -> do
                let index = a.work </> ".git" </> "publication-index"
                present <- doesFileExist index
                if present then removeFile index else pure ()
                let environment = [("GIT_INDEX_FILE", index)]
                _ <- gitEnv a.work environment ["read-tree", T.unpack (text "base_tree")] Nothing
                entries <- case field "tree" of
                  Array xs -> pure xs
                  _ -> fail "tree entries"
                forM_ entries $ \case
                  Object entry -> do
                    let get k = maybe Null id (lookup k entry)
                        str k = case get k of String t -> T.unpack t; _ -> ""
                    case get "sha" of
                      Null -> gitEnv a.work environment ["update-index", "--force-remove", "--", str "path"] Nothing
                      _ -> gitEnv a.work environment ["update-index", "--add", "--cacheinfo", str "mode" <> "," <> str "sha" <> "," <> str "path"] Nothing
                  _ -> fail "tree entry"
                sha <- gitEnv a.work environment ["write-tree"] Nothing
                removeFile index
                pure sha
            | "/git/commits" `T.isSuffixOf` path -> do
                let person k sub = case field k of
                      Object p -> case lookup sub p of Just (String t) -> T.unpack t; _ -> ""
                      _ -> ""
                    environment =
                      [ ("GIT_AUTHOR_NAME", person "author" "name")
                      , ("GIT_AUTHOR_EMAIL", person "author" "email")
                      , ("GIT_COMMITTER_NAME", person "committer" "name")
                      , ("GIT_COMMITTER_EMAIL", person "committer" "email")
                      , ("GIT_AUTHOR_DATE", "2001-01-01T00:00:00Z")
                      , ("GIT_COMMITTER_DATE", "2001-01-01T00:00:00Z")
                      ]
                    parents = case field "parents" of
                      Array ps -> concat [["-p", T.unpack p] | String p <- ps]
                      _ -> []
                gitEnv a.work environment (["commit-tree", T.unpack (text "tree")] ++ parents) (Just (TE.encodeUtf8 (text "message")))
            | otherwise -> fail "unexpected local authority request"
        modifyIORef' a.createdShas (Set.insert sha)
        pure (created sha)
    , pages = \_ -> fail "unexpected pages"
    }

localAuthority :: LocalAuthority -> IO PublicationAuthority
localAuthority a = do
  github <- either (fail . show) pure (Gateway.githubAuthority (localObjectTransport a) "owner/repo" 7 Nothing)
  pure
    PublicationAuthority
      { repository = "owner/repo"
      , pullRequest = snapshot a
      , createTree = Gateway.createTree github
      , createCommit = Gateway.createCommit github
      , compareAndSwapRef = Just $ \repository ref expected commit -> do
          repository `shouldBe` "owner/repo"
          ref `shouldBe` "refs/heads/topic"
          current <- readIORef a.headRef
          expected `shouldBe` current
          known <- readIORef a.createdShas
          commit `shouldSatisfy` (`Set.member` known)
          _ <- gitIn a.work ["push", "--quiet", a.remotePath, T.unpack commit <> ":" <> T.unpack ref] Nothing
          lag <- readIORef a.lagProjection
          writeIORef a.headRef (if lag then expected else commit)
          modifyIORef' a.casCount (+ 1)
      }

-- | The host-captured binary diff of writing @bounded.txt@ on @head@
-- (the reference derives it through its Pi workspace provider).
diffFor :: Repository -> Text -> IO (Text, [Text])
diffFor repo head' = do
  let scratch = repo.tmp </> "settled"
  _ <- readCreateProcess (proc "git" ["clone", "-q", repo.remote, scratch]) ""
  _ <- gitIn scratch ["checkout", "-q", "--detach", T.unpack head'] Nothing
  writeFile (scratch </> "bounded.txt") "qualified\n"
  _ <- gitIn scratch ["add", "-A"] Nothing
  diff <- T.pack <$> readCreateProcess (proc "git" ["-C", scratch, "diff", "--cached", "--binary", "--full-index", T.unpack head']) ""
  pure (diff, ["bounded.txt"])

codingResult :: Text -> Text -> Text -> [Text] -> CodingResult
codingResult head' ref diff changed =
  CodingResult
    { kind = "change"
    , repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = head'
    , base = head'
    , ref
    , status = "changed"
    , reproductionStatus = "not_attempted"
    , diff
    , changedFiles = changed
    , validationEvidence = [[("command", String "credential-free"), ("status", String "passed")]]
    , proposedCommitMessage = "Apply bounded diagnostic change"
    }

category :: PublicationCategory -> Selector GitPublishError
category c e = e.category == c

matching :: Text -> Selector GitPublishError
matching fragment e = fragment `T.isInfixOf` e.reason

withEnv :: [(String, String)] -> IO a -> IO a
withEnv settings action = bracket save restore (const action)
  where
    save = do
      previous <- mapM (\(k, _) -> (k,) <$> lookupEnv k) settings
      mapM_ (uncurry setEnv) settings
      pure previous
    restore = mapM_ (\(k, v) -> maybe (unsetEnv k) (setEnv k) v)

spec :: Spec
spec = describe "test_git_publish" $ do
  it "test_ref_advance_uses_github_exact_compare_and_swap" $ withTempRoot $ \tmp -> do
    s <- newScripted
    subject <- scriptedPublisher s tmp
    let expected = T.replicate 40 "c"
        commit = T.replicate 40 "d"
    advanceRef subject "topic/branch" expected commit
    readIORef s.casCalls >>= (`shouldBe` [("owner/repo", "refs/heads/topic/branch", expected, commit)])
    writeIORef s.casFail True
    advanceRef subject "topic/branch" expected commit `shouldThrow` matching "exact ref compare-and-swap"

  it "test_local_publication_io_failure_has_closed_sanitized_category" $ withTempRoot $ \tmp ->
    withEnv [("TMPDIR", tmp </> "missing")] $ do
      reached <- newIORef False
      withPublicationDirectory (\_ -> writeIORef reached True)
        `shouldThrow` (\e -> category GitOperation e && matching "Git operation failed" e)
      readIORef reached >>= (`shouldBe` False)

  it "test_git_publication_never_consults_ambient_credential_helpers" $ withTempRoot $ \tmp -> do
    let marker = tmp </> "ambient-helper-called"
        helper = tmp </> "credential-helper"
        config = tmp </> "ambient-git-config"
    writeFile helper ("#!/bin/sh\nprintf 'username=ambient\\npassword=human-authority\\n'\ntouch " <> marker <> "\n")
    setFileMode helper 0o755
    writeFile config ("[credential]\n\thelper = !" <> helper <> "\n")
    withEnv
      [ ("GIT_CONFIG_GLOBAL", config)
      , ("GIT_ASKPASS", helper)
      , ("SSH_ASKPASS", helper)
      , ("SSH_AUTH_SOCK", tmp </> "ambient-agent")
      ]
      $ runGit ["credential", "fill"] (Just "protocol=https\nhost=github.com\n\n") `shouldThrow` category GitOperation
    doesFileExist marker >>= (`shouldBe` False)

  it "test_same_repository_identity_is_case_insensitive_but_still_rejects_forks" $ do
    sameRepository "HBNetwork/demo-pr-readiness" "hbnetwork/demo-pr-readiness" `shouldBe` True
    sameRepository "fork/demo-pr-readiness" "hbnetwork/demo-pr-readiness" `shouldBe` False

  forM_ ["../x", "/x", "x\\y", "-x", ".GIT/config", "a/.GitModules", "a//b"] $ \path ->
    it ("test_declared_paths_reject_privileged_and_unsafe_names[" <> T.unpack path <> "]") $
      validateDeclaredPaths [path] `shouldThrow` matching "paths are unsafe"

  forM_ ["Proposal\n\nHamsterdan-Operation: forged", "Proposal\nHAMSTERDAN-PAYLOAD-DIGEST: forged"] $ \message ->
    it ("test_commit_message_rejects_reserved_idempotency_trailers[" <> show message <> "]") $
      validateCommitMessage message `shouldThrow` matching "reserved publication trailer"

  it "test_staged_regular_and_executable_modes_are_safe" $ withRepository $ \repo -> do
    writeFile (repo.root </> "file.txt") "safe\n"
    writeFile (repo.root </> "tool") "#!/bin/sh\n"
    setFileMode (repo.root </> "tool") 0o755
    _ <- gitIn repo.root ["add", "file.txt", "tool"] Nothing
    validateStagedTree repo.root >>= (`shouldBe` ["file.txt", "tool"])

  it "test_commit_upload_preserves_staged_modes_parents_and_binary_content" $ withRepository $ \repo -> do
    BS.writeFile (repo.root </> "file.txt") (BC.pack "binary\0value")
    _ <- gitIn repo.root ["add", "file.txt"] Nothing
    tree <- gitIn repo.root ["rev-parse", T.unpack repo.first <> "^{tree}"] Nothing
    s <- newScripted
    writeIORef s.responses [created (T.replicate 40 "a"), created (T.replicate 40 "b"), created (T.replicate 40 "c")]
    subject <- scriptedPublisher s repo.remote
    commit <- createCommit subject repo.root tree (T.replicate 40 "b") ["file.txt"] [repo.first] "message"
    commit `shouldBe` T.replicate 40 "c"
    calls <- readIORef s.calls
    case calls of
      [blob, createdTree, createdCommit] -> do
        blob
          `shouldBe` ( "POST"
                     , "/repos/owner/repo/git/blobs"
                     , Just [("content", String "YmluYXJ5AHZhbHVl"), ("encoding", String "base64")]
                     )
        createdTree
          `shouldBe` ( "POST"
                     , "/repos/owner/repo/git/trees"
                     , Just
                        [ ("base_tree", String tree)
                        , ( "tree"
                          , Array
                              [ Object
                                  [ ("path", String "file.txt")
                                  , ("mode", String "100644")
                                  , ("type", String "blob")
                                  , ("sha", String (T.replicate 40 "a"))
                                  ]
                              ]
                          )
                        ]
                     )
        let person = Object [("name", String "Hamsterdan"), ("email", String "hamster-dan[bot]@users.noreply.github.com")]
        createdCommit
          `shouldBe` ( "POST"
                     , "/repos/owner/repo/git/commits"
                     , Just
                        [ ("message", String "message")
                        , ("tree", String (T.replicate 40 "b"))
                        , ("parents", Array [String repo.first])
                        , ("author", person)
                        , ("committer", person)
                        ]
                     )
      other -> expectationFailure (show (length other))

  forM_ [("blob", 0 :: Int), ("tree", 1), ("commit", 2)] $ \(failure, position) ->
    it ("test_provider_object_creation_requires_exact_proof_before_continuing[" <> T.unpack failure <> "]") $ do
      s <- newScripted
      let valid = [created (T.replicate 40 "a"), created (T.replicate 40 "b"), created (T.replicate 40 "c")]
          bad = WireResponse 200 (Object [("sha", String (T.replicate 40 "f"))]) Nothing
      writeIORef s.responses [if i == position then bad else r | (i, r) <- zip [0 ..] valid]
      authority <- scriptedAuthority s
      let attempt = do
            tree <- authority.createTree (T.replicate 40 "d") [("file.txt", "100644", Just "content")]
            authority.createCommit tree [T.replicate 40 "e"] "message" "Hamsterdan" "hamster-dan[bot]@users.noreply.github.com"
      attempt `shouldThrow` \(e :: GitHubBoundaryError) -> e.kind == ObjectWrite && (failure <> " creation") `T.isInfixOf` e.message
      length <$> readIORef s.calls >>= (`shouldBe` position + 1)

  it "test_host_refuses_unexpected_created_tree_before_commit_or_ref_update" $ withRepository $ \repo -> do
    writeFile (repo.root </> "file.txt") "changed\n"
    _ <- gitIn repo.root ["add", "file.txt"] Nothing
    baseTree <- gitIn repo.root ["rev-parse", T.unpack repo.first <> "^{tree}"] Nothing
    expectedTree <- gitIn repo.root ["write-tree"] Nothing
    s <- newScripted
    writeIORef s.responses [created (T.replicate 40 "a"), created (T.replicate 40 "b")]
    subject <- scriptedPublisher s repo.remote
    createCommit subject repo.root baseTree expectedTree ["file.txt"] [repo.first] "message" `shouldThrow` category ObjectWriteFailure
    map (\(_, p, _) -> p) <$> readIORef s.calls >>= (`shouldBe` ["/repos/owner/repo/git/blobs", "/repos/owner/repo/git/trees"])
    readIORef s.casCalls >>= (`shouldBe` [])

  forM_ [("120000", Just "file.txt"), ("160000", Nothing)] $ \(mode, content) ->
    it ("test_staged_symlink_and_gitlink_are_rejected[" <> mode <> "]") $ withRepository $ \repo -> do
      blob <- case content of
        Nothing -> pure repo.second
        Just c -> gitIn repo.root ["hash-object", "-w", "--stdin"] (Just c)
      _ <- gitIn repo.root ["update-index", "--add", "--cacheinfo", mode <> "," <> T.unpack blob <> ",unsafe"] Nothing
      s <- newScripted
      _ <- scriptedPublisher s repo.remote
      validateStagedTree repo.root `shouldThrow` matching "unsafe mode"

  it "test_unmerged_index_is_rejected" $ withRepository $ \repo -> do
    firstBlob <- gitIn repo.root ["rev-parse", T.unpack repo.first <> ":file.txt"] Nothing
    secondBlob <- gitIn repo.root ["rev-parse", T.unpack repo.second <> ":file.txt"] Nothing
    _ <- gitIn repo.root ["rm", "--cached", "file.txt"] Nothing
    _ <-
      gitIn
        repo.root
        ["update-index", "--index-info"]
        (Just ("100644 " <> T.unpack firstBlob <> " 1\tfile.txt\n100644 " <> T.unpack secondBlob <> " 2\tfile.txt\n"))
    validateStagedTree repo.root `shouldThrow` matching "unsafe mode"

  it "test_reconciliation_finds_an_operation_beneath_a_later_fast_forward" $ withRepository $ \repo -> do
    tree <- gitIn repo.root ["rev-parse", T.unpack repo.first <> "^{tree}"] Nothing
    operation <-
      gitIn
        repo.root
        ["commit-tree", T.unpack tree, "-p", T.unpack repo.first]
        (Just "proposal\n\nHamsterdan-Operation: push:one\nHamsterdan-Payload-Digest: digest\n")
    later <- gitIn repo.root ["commit-tree", T.unpack tree, "-p", T.unpack operation] (Just "later\n")
    _ <- gitIn repo.root ["push", "-q", "--force", "origin", T.unpack later <> ":refs/heads/topic"] Nothing
    a <- newLocalAuthority repo.root repo.remote repo.first
    writeIORef a.headRef later
    subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
    result <- reconcile subject "push:one" "digest" repo.first repo.first False
    result `shouldBe` GitReconciliation "existing" later operation [repo.first]

  it "test_merge_base_reconciliation_requires_the_exact_ordered_parents" $ withRepository $ \repo -> do
    tree <- gitIn repo.root ["rev-parse", T.unpack repo.second <> "^{tree}"] Nothing
    operation <-
      gitIn
        repo.root
        ["commit-tree", T.unpack tree, "-p", T.unpack repo.first, "-p", T.unpack repo.second]
        (Just "proposal\n\nHamsterdan-Operation: push:merge\nHamsterdan-Payload-Digest: digest\n")
    _ <- gitIn repo.root ["push", "-q", "--force", "origin", T.unpack operation <> ":refs/heads/topic"] Nothing
    a <- newLocalAuthority repo.root repo.remote repo.first
    writeIORef a.headRef operation
    subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
    result <- reconcile subject "push:merge" "digest" repo.first repo.second True
    result `shouldBe` GitReconciliation "existing" operation operation [repo.first, repo.second]

  it "test_reconciliation_proves_coherent_absence" $ withRepository $ \repo -> do
    a <- newLocalAuthority repo.root repo.remote repo.first
    subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
    result <- reconcile subject "push:absent" "digest" repo.first repo.first False
    result `shouldBe` GitReconciliation "absent" repo.first "" []

  forM_ ["digest", "parents", "duplicate"] $ \collision ->
    it ("test_reconciliation_rejects_operation_identity_collisions[" <> collision <> "]") $ withRepository $ \repo -> do
      tree <- gitIn repo.root ["rev-parse", T.unpack repo.first <> "^{tree}"] Nothing
      let digest = if collision == "digest" then "different" else "digest"
          parents = if collision == "parents" then [repo.first, repo.second] else [repo.first]
      operation <-
        gitIn
          repo.root
          (["commit-tree", T.unpack tree] ++ concat [["-p", T.unpack p] | p <- parents])
          (Just ("proposal\n\nHamsterdan-Operation: push:one\nHamsterdan-Payload-Digest: " <> digest <> "\n"))
      head' <-
        if collision == "duplicate"
          then
            gitIn
              repo.root
              ["commit-tree", T.unpack tree, "-p", T.unpack operation]
              (Just "again\n\nHamsterdan-Operation: push:one\nHamsterdan-Payload-Digest: digest\n")
          else pure operation
      _ <- gitIn repo.root ["push", "-q", "--force", "origin", T.unpack head' <> ":refs/heads/topic"] Nothing
      a <- newLocalAuthority repo.root repo.remote repo.first
      writeIORef a.headRef head'
      subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
      reconcile subject "push:one" "digest" repo.first repo.first False `shouldThrow` category Idempotency

  it "test_host_derived_patch_publishes_and_replays_through_complete_local_authority" $ withRepository $ \repo -> do
    (diff, changed) <- diffFor repo repo.first
    let result = codingResult repo.first "hamsterdan/change/diagnostic" diff changed
    a <- newLocalAuthority repo.root repo.remote repo.first
    subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
    published <- publish subject result "change:diagnostic" (T.replicate 64 "d") repo.first repo.first False
    published.recovered `shouldBe` False
    content <- gitIn repo.root ["show", T.unpack published.head <> ":bounded.txt"] Nothing
    content `shouldBe` "qualified"
    replayed <- publish subject result "change:diagnostic" (T.replicate 64 "d") repo.first repo.first False
    replayed.recovered `shouldBe` True
    current <- readIORef a.headRef
    published.head `shouldBe` current
    replayed.head `shouldBe` published.head
    readIORef a.casCount >>= (`shouldBe` 1)

  it "test_publish_settle_tolerates_only_its_own_lagging_pr_projection" $ withRepository $ \repo -> do
    (diff, changed) <- diffFor repo repo.first
    let result = codingResult repo.first "hamsterdan/change/lag" diff changed
    a <- newLocalAuthority repo.root repo.remote repo.first
    writeIORef a.lagProjection True
    subject <- localAuthority a >>= (`hostGitPublisher` T.pack repo.remote)
    published <- publish subject result "change:lag" (T.replicate 64 "e") repo.first repo.first False
    readIORef a.casCount >>= (`shouldBe` 1)
    published.head `shouldNotBe` repo.first
    reconcile subject "change:lag" (T.replicate 64 "e") repo.first repo.first False
      `shouldThrow` matching "differs from the current PR projection"
