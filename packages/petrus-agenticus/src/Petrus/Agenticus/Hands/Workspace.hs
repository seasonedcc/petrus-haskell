-- | The concrete Hands workspace adapter over the public Motus execution
-- contract (@petrus.agenticus.hands.workspace@).
--
-- The adapter is the only place a version-1 Hands call crosses into a
-- territory. It works as follows:
--
-- * It uses only the supported 'EnvironmentProvider' and
--   'ExecutionAttachment' surface.
-- * It fences every command result to the exact lease provenance it was
--   created for.
-- * It stages writes outside every final target.
-- * It returns only bounded digests and truncated text: never raw provider
--   state, sessions, credentials or unbounded output.
module Petrus.Agenticus.Hands.Workspace
  ( -- * Bounds
    stageDirectory
  , maxReadBytes
  , maxSearchMatches
  , maxSearchMatchChars
  , maxStreamBytes
  , commandOutputLimit
  , defaultCommandTimeout
    -- * The adapter
  , MotusWorkspaceAdapter
  , newMotusWorkspaceAdapter
  , workspaceHandsAdapter
  , workspaceRead
  , workspaceSearch
  , workspaceShell
  , workspaceStageWrite
  , workspaceCommitWrite
  , workspaceDiscardWrite
  , workspaceRunTest
  , workspaceDiscardAllStages
  , outstandingStages
    -- * Pure projections (exposed for the differential corpus)
  , boundedText
  , searchLines
  , stageName
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Gateway (HandsAdapter (..), ShellOutcome, StagedWrite (..), TestOutcome, mkShellOutcome, mkStagedWrite, mkTestOutcome)
import Petrus.Agenticus.Internal.PyText (boundedText, splitLines)
import Petrus.Motus.Execution
  ( CommandResult
  , CommandSpec (..)
  , EnvironmentProvider (..)
  , ExecutionAttachment
  , LeaseIdentity
  , Seconds (..)
  , attachmentLease
  , commandSpec
  , leaseIdentity
  , mkCommand
  , provenanceIdentity
  , resultOutputTruncated
  , resultProvenance
  , resultReturncode
  , resultStderr
  , resultStdout
  , resultSuperseded
  , resultTimedOut
  )

-- | Writes stage here, outside every final target.
stageDirectory :: Text
stageDirectory = ".petrus-hands-stage"

maxReadBytes, maxSearchMatches, maxSearchMatchChars, maxStreamBytes, commandOutputLimit :: Int
maxReadBytes = 4096
maxSearchMatches = 16
maxSearchMatchChars = 256
maxStreamBytes = 2048
commandOutputLimit = 65536

-- | The reference's @command_timeout=60.0@ default.
defaultCommandTimeout :: Double
defaultCommandTimeout = 60

-- | The gateway's Hands adapter for one exact Motus execution attachment.
--
-- The adapter keeps the authoritative registry of outstanding stage tokens,
-- so settlement can prove that every stage was removed. Commands run with
-- the empty default environment, so no credential-shaped value ever enters
-- the territory.
data MotusWorkspaceAdapter = MotusWorkspaceAdapter
  { provider :: EnvironmentProvider
  , attachment :: ExecutionAttachment
  , lease :: LeaseIdentity
  , testCommand :: [Text]
  , timeout :: Double
  , stages :: IORef (Map Text Text)
  -- ^ stage name -> target path
  }

-- | @MotusWorkspaceAdapter(provider, attachment, test_command=...,
-- command_timeout=...)@.
newMotusWorkspaceAdapter :: EnvironmentProvider -> ExecutionAttachment -> [Text] -> Double -> IO MotusWorkspaceAdapter
newMotusWorkspaceAdapter provider attachment command timeout' = do
  if null command || any T.null command
    then throwAgenticus ValueError "workspace adapter test_command must be a non-empty tuple of non-empty strings"
    else pure ()
  if isNaN timeout' || isInfinite timeout' || timeout' <= 0
    then throwAgenticus ValueError "workspace adapter command_timeout must be a positive finite number"
    else pure ()
  MotusWorkspaceAdapter provider attachment (leaseIdentity (attachmentLease attachment)) command timeout'
    <$> newIORef Map.empty

-- | The adapter as the gateway's 'HandsAdapter'.
workspaceHandsAdapter :: MotusWorkspaceAdapter -> HandsAdapter
workspaceHandsAdapter a =
  HandsAdapter
    { read = workspaceRead a
    , search = workspaceSearch a
    , shell = workspaceShell a
    , stageWrite = workspaceStageWrite a
    , commitWrite = workspaceCommitWrite a
    , discardWrite = workspaceDiscardWrite a
    , runTest = workspaceRunTest a
    , discardAllStages = workspaceDiscardAllStages a
    }

failWith :: Text -> IO a
failWith = throwAgenticus WorkspaceAdapterError

sh :: Text -> [Text] -> [Text]
sh script args = "/bin/sh" : "-c" : script : args

workspaceRead :: MotusWorkspaceAdapter -> Text -> IO Text
workspaceRead a path = do
  result <- run a (sh "cat -- \"$0\"" [path]) "."
  if resultReturncode result /= 0
    then failWith "workspace read failed"
    else pure (fst (boundedText (resultStdout result) maxReadBytes))

workspaceSearch :: MotusWorkspaceAdapter -> Text -> Text -> IO [Text]
workspaceSearch a query path = do
  result <- run a (sh "grep -r -n -e \"$0\" -- \"$1\"" [query, path]) "."
  case resultReturncode result of
    1 -> pure []
    0 -> pure (searchLines (resultStdout result))
    _ -> failWith "workspace search failed"

-- | The @search@ projection of raw grep output: the output is bounded to
-- the command output limit, split as by @str.splitlines@ with empty lines
-- dropped, and each line is cut to 256 code points. At most 16 lines are
-- kept.
searchLines :: ByteString -> [Text]
searchLines out =
  take maxSearchMatches
    [T.take maxSearchMatchChars line | line <- splitLines (fst (boundedText out commandOutputLimit)), not (T.null line)]

workspaceShell :: MotusWorkspaceAdapter -> [Text] -> Text -> IO ShellOutcome
workspaceShell a argv cwd = do
  result <- run a argv cwd
  let (out, outCut) = boundedText (resultStdout result) maxStreamBytes
      (err, errCut) = boundedText (resultStderr result) maxStreamBytes
  either throwIO pure $
    mkShellOutcome (toInteger (resultReturncode result)) out err (resultOutputTruncated result || outCut || errCut)

-- | The stage file name for a call id: the first 32 hex digits of its
-- SHA-256.
stageName :: Text -> Text
stageName callId = T.take 32 (hexDigest (TE.encodeUtf8 callId))

hexDigest :: ByteString -> Text
hexDigest bytes = T.pack (show (hash bytes :: Digest SHA256))

workspaceStageWrite :: MotusWorkspaceAdapter -> Text -> Text -> Text -> IO StagedWrite
workspaceStageWrite a callId path content = do
  let name = stageName callId
  result <- run a (sh "mkdir -p -- \"$0\" && printf %s \"$2\" > \"$0/$1\"" [stageDirectory, name, content]) "."
  if resultReturncode result /= 0 then failWith "workspace stage failed" else pure ()
  staged <- either throwIO pure (mkStagedWrite callId path (hexDigest (TE.encodeUtf8 content)))
  atomicModifyIORef' a.stages (\m -> (Map.insert name staged.path m, ()))
  pure staged

workspaceCommitWrite :: MotusWorkspaceAdapter -> StagedWrite -> IO Text
workspaceCommitWrite a staged = do
  name <- registeredStage a staged
  result <-
    run
      a
      (sh "parent=$(dirname -- \"$2\") && mkdir -p -- \"$parent\" && mv -f -- \"$0/$1\" \"$2\"" [stageDirectory, name, staged.path])
      "."
  if resultReturncode result /= 0 then failWith "workspace commit failed" else pure ()
  atomicModifyIORef' a.stages (\m -> (Map.delete name m, ()))
  pure staged.digest

workspaceDiscardWrite :: MotusWorkspaceAdapter -> StagedWrite -> IO ()
workspaceDiscardWrite a staged = do
  name <- registeredStage a staged
  result <- run a (sh "rm -f -- \"$0/$1\"" [stageDirectory, name]) "."
  atomicModifyIORef' a.stages (\m -> (Map.delete name m, ()))
  if resultReturncode result /= 0 then failWith "workspace stage discard failed" else pure ()

workspaceRunTest :: MotusWorkspaceAdapter -> IO TestOutcome
workspaceRunTest a = do
  result <- run a a.testCommand "."
  either throwIO pure $
    mkTestOutcome (resultReturncode result == 0) (hexDigest (resultStdout result <> resultStderr result))

workspaceDiscardAllStages :: MotusWorkspaceAdapter -> IO Int
workspaceDiscardAllStages a = do
  result <- run a (sh "rm -rf -- \"$0\"" [stageDirectory]) "."
  if resultReturncode result /= 0 then failWith "workspace stage cleanup failed" else pure ()
  atomicModifyIORef' a.stages (\m -> (Map.empty, Map.size m))

-- | The authoritative count of stage tokens not yet committed or discarded.
outstandingStages :: MotusWorkspaceAdapter -> IO Int
outstandingStages a = Map.size <$> readIORef a.stages

registeredStage :: MotusWorkspaceAdapter -> StagedWrite -> IO Text
registeredStage a staged = do
  let name = stageName staged.callId
  registered <- Map.lookup name <$> readIORef a.stages
  if registered /= Just staged.path
    then failWith "stage token is not registered with this adapter"
    else pure name

-- | One fenced territory command. A synchronous failure to build or run the
-- command is @territory command failed@; asynchronous exceptions propagate.
run :: MotusWorkspaceAdapter -> [Text] -> Text -> IO CommandResult
run a argv cwd = do
  outcome <- try $ do
    command <-
      either throwIO pure $
        mkCommand
          (commandSpec argv)
            { specCwd = T.unpack cwd
            , specTimeout = Just (FractionalSeconds a.timeout)
            , specOutputLimit = commandOutputLimit
            }
    a.provider.providerExecute a.attachment command
  result <- case outcome of
    Right result -> pure result
    Left (e :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | Just (ae :: AgenticusError) <- fromException e, ae.errorClass == WorkspaceAdapterError -> throwIO ae
      | otherwise -> failWith "territory command failed"
  if provenanceIdentity (resultProvenance result) /= a.lease
    then failWith "command result provenance does not match the bound lease"
    else pure ()
  if resultTimedOut result || resultSuperseded result
    then failWith "territory command did not complete currently"
    else pure ()
  pure result
