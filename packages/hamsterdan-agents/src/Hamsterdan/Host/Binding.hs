-- | Topology-labeled ownership for one durable PR Instance root
-- (@host/binding.py@).
--
-- @binding.json@ is written byte for byte as the reference writes it
-- (@json.dumps(payload, sort_keys=True, separators=(",", ":"))@, mode
-- @0600@, a @.binding.*.tmp@ temporary renamed into place, the directory
-- fsynced), so either host can own the other's state root.
module Hamsterdan.Host.Binding
  ( Topology (..)
  , InstanceBinding (..)
  , topologyText
  , bindingPayload
  , encodeBinding
  , parseInstanceBinding
  , readInstanceBinding
  , ensureInstanceBinding
  , preflightV5State
  ) where

import Control.Exception (Exception, IOException, catch, evaluate, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Exception (raisingDumps)
import Hamsterdan.Python.Text (isAscii, isPrintable, pyIntBase, utf8Length)
import Petrus.Json (Json (..), dumps, parseJson, pythonLoads)
import Petrus.Json qualified as Json
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import Petrus.Posix.File (AtomicWrite (..), atomicWriteFile, prefixNaming)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as Posix

data Topology = Production | V5
  deriving stock (Eq, Show)

data InstanceBinding = InstanceBinding
  { topology :: Topology
  , instanceId :: Text
  , repository :: Text
  , pullRequest :: Integer
  , legacy :: Bool
  }
  deriving stock (Eq, Show)

topologyText :: Topology -> Text
topologyText = \case
  Production -> "production"
  V5 -> "v5"

-- | @InstanceBinding.payload()@.
bindingPayload :: InstanceBinding -> Json
bindingPayload b =
  Object
    [ ("instance_id", String b.instanceId)
    , ("pull_request", Int b.pullRequest)
    , ("repository", String b.repository)
    , ("topology", String (topologyText b.topology))
    ]

-- | The bytes of @binding.json@.
encodeBinding :: InstanceBinding -> BS.ByteString
encodeBinding b =
  raisingDumps $
    dumps Json.defaultDumps {Json.itemSeparator = Just ",", Json.keySeparator = ":", Json.sortKeys = True} (bindingPayload b)

malformed :: ValueError
malformed = ValueError "Instance state binding is malformed"

legacyFields, allFields :: [Text]
legacyFields = ["instance_id", "pull_request", "repository"]
allFields = ["instance_id", "pull_request", "repository", "topology"]

repositoryShape :: Text -> Bool
repositoryShape value = case T.splitOn "/" value of
  [owner, name] -> part owner && part name
  _ -> False
  where
    part p = not (T.null p) && T.all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("_.-" :: String)) p

-- | @parse_instance_binding(value)@; 'Left' is the @ValueError@.
parseInstanceBinding :: Json -> Either ValueError InstanceBinding
parseInstanceBinding = \case
  Object members
    | keys <- sort (map fst members)
    , keys == legacyFields || keys == allFields -> do
        let legacy = keys == legacyFields
            field k = lookup k members
        topology <-
          if legacy
            then Right Production
            else case field "topology" of
              Just (String "production") -> Right Production
              Just (String "v5") -> Right V5
              _ -> Left malformed
        instanceId <- case field "instance_id" of
          Just (String t)
            | utf8Length t > 0
            , utf8Length t <= 1024
            , isAscii t
            , isPrintable t ->
                Right t
          _ -> Left malformed
        repository <- case field "repository" of
          Just (String t) | repositoryShape t -> Right t
          _ -> Left malformed
        pullRequest <- case field "pull_request" of
          Just (Int n) | n > 0 -> Right n
          _ -> Left malformed
        Right InstanceBinding {topology, instanceId, repository, pullRequest, legacy}
  _ -> Left malformed

unreadable :: RuntimeError
unreadable = RuntimeError "Instance state binding is unreadable or malformed"

-- | @read_instance_binding(path)@.
readInstanceBinding :: FilePath -> IO InstanceBinding
readInstanceBinding path = do
  outcome <- try @IOException $ do
    info <- Posix.getSymbolicLinkStatus path
    if Posix.isSymbolicLink info || not (Posix.isRegularFile info) || Posix.fileSize info <= 0 || Posix.fileSize info > 4096
      then pure Nothing
      else Just <$> BS.readFile path
  case outcome of
    Right (Just bytes)
      | Right _ <- TE.decodeUtf8' bytes
      , Right value <- parseJson pythonLoads bytes
      , Right binding <- parseInstanceBinding value ->
          pure binding
    _ -> throwIO unreadable

lstatMaybe :: FilePath -> IO (Maybe Posix.FileStatus)
lstatMaybe path =
  (Just <$> Posix.getSymbolicLinkStatus path) `catch` \(e :: IOException) ->
    if isDoesNotExistError e then pure Nothing else throwIO e

ancestry :: FilePath -> [FilePath]
ancestry path = go path
  where
    go p =
      let parent = takeDirectory p
       in if parent == p then [p] else p : go parent

requireRealDirectoryAncestry :: FilePath -> IO ()
requireRealDirectoryAncestry path =
  forM_ (ancestry path) $ \component -> do
    info <- try @IOException (lstatMaybe component)
    case info of
      Left _ -> throwIO (RuntimeError "state root is malformed")
      Right Nothing -> pure ()
      Right (Just st) ->
        when (Posix.isSymbolicLink st || not (Posix.isDirectory st)) $
          throwIO (RuntimeError "state root is malformed")

requireRegularHistory :: FilePath -> IO ()
requireRegularHistory path = do
  info <- try @IOException (lstatMaybe path)
  case info of
    Left _ -> throwIO (RuntimeError "History is unreadable or malformed")
    Right Nothing -> pure ()
    Right (Just st) ->
      when (Posix.isSymbolicLink st || not (Posix.isRegularFile st)) $
        throwIO (RuntimeError "History is unreadable or malformed")

-- | @path.exists() or path.is_symlink()@.
present :: FilePath -> IO Bool
present path = do
  st <- try @IOException (Posix.getSymbolicLinkStatus path)
  pure (either (const False) (const True) st)

writeBinding :: FilePath -> InstanceBinding -> IO ()
writeBinding path binding =
  atomicWriteFile
    AtomicWrite {tempNaming = prefixNaming (const ".binding."), tempMode = 0o600, syncDirectory = True}
    path
    (encodeBinding binding)

-- | @ensure_instance_binding(root, instance_id, repository, pull_request)@.
ensureInstanceBinding :: FilePath -> Text -> Text -> Integer -> IO InstanceBinding
ensureInstanceBinding root instanceId repository pullRequest = do
  expected <-
    either throwIO pure . parseInstanceBinding $
      Object
        [ ("instance_id", String instanceId)
        , ("pull_request", Int pullRequest)
        , ("repository", String repository)
        , ("topology", String "v5")
        ]
  requireRealDirectoryAncestry root
  let bindingPath = root </> "binding.json"
      historyPath = root </> "history.jsonl"
  bound <- present bindingPath
  if bound
    then do
      observed <- readInstanceBinding bindingPath
      unless
        ( observed.topology == V5
            && observed.instanceId == instanceId
            && observed.repository == repository
            && observed.pullRequest == pullRequest
        )
        $ throwIO (RuntimeError "state root belongs to a different PR Instance or topology")
      requireRegularHistory historyPath
      pure expected
    else do
      history <- present historyPath
      when history $ throwIO (RuntimeError "History has no subject binding")
      makeRoot root
      writeBinding bindingPath expected
      pure expected

-- | @root.mkdir(mode=0o700, parents=True, exist_ok=True)@: only the leaf
-- gets @0700@; created parents get the default mode, as @pathlib@ does.
makeRoot :: FilePath -> IO ()
makeRoot root = do
  exists <- present root
  unless exists $ do
    createDirectoryIfMissing True (takeDirectory root)
    PosixDir.createDirectory root 0o700 `catch` \(e :: IOException) -> do
      again <- present root
      unless again (throwIO e)

-- | @preflight_v5_state(state_path)@.
preflightV5State :: FilePath -> IO ()
preflightV5State statePath = do
  let applications = statePath </> "applications"
  exists <- present applications
  when exists $ do
    info <- try @IOException (Posix.getFileStatus applications)
    isLink <- either (const False) Posix.isSymbolicLink <$> try @IOException (Posix.getSymbolicLinkStatus applications)
    case info of
      Right st | not isLink, Posix.isDirectory st -> pure ()
      _ -> throwIO (RuntimeError "application state root is malformed")
    result <- try @MalformedRoot (walk applications `catch` \(_ :: IOException) -> throwIO MalformedRoot)
    case result of
      Left MalformedRoot -> throwIO (RuntimeError "application state root is malformed")
      Right () -> pure ()
  where
    number name = maybe (throwIO MalformedRoot) pure (pyIntBase 10 (T.pack name))
    sortedEntries dir = sort <$> listDirectory dir
    walk applications = do
      installations <- sortedEntries applications
      forM_ installations $ \installationName -> do
        let installationPath = applications </> installationName
        requireRealDirectoryAncestry installationPath
        installation <- number installationName
        repositories <- sortedEntries installationPath
        forM_ repositories $ \repositoryName -> do
          let repositoryPath = installationPath </> repositoryName
          requireRealDirectoryAncestry repositoryPath
          repositoryId <- number repositoryName
          roots <- sortedEntries repositoryPath
          forM_ roots $ \rootName -> do
            let root = repositoryPath </> rootName
            requireRealDirectoryAncestry root
            pullRequest <- number rootName
            when (minimum [installation, repositoryId, pullRequest] <= 0) $ throwIO MalformedRoot
            let bindingPath = root </> "binding.json"
                historyPath = root </> "history.jsonl"
            hasBinding <- present bindingPath
            hasHistory <- present historyPath
            when (hasBinding || hasHistory) $ do
              requireRegularHistory historyPath
              binding <- readInstanceBinding bindingPath
              _ <- evaluate binding
              when (binding.instanceId /= T.pack ("github:" <> show installation <> ":" <> show repositoryId <> ":pr:" <> show pullRequest)) $
                throwIO MalformedRoot
              when (binding.topology /= V5 || binding.legacy) $
                throwIO (RuntimeError "application state is not compatible with the V5 readiness topology")

-- | The reference's internal @ValueError@ inside the preflight walk.
data MalformedRoot = MalformedRoot
  deriving stock (Show)

instance Exception MalformedRoot
