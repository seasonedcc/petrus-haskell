-- | Shared fixtures for the History store specs.
module Petrus.HistoryStore.Support
  ( withScratch
  , jsonlReopen
  , place'
  , transition'
  , token'
  , storeErrorContaining
  , runPython
  , withReference
  , surrogateRecords
  , surrogatePayment
  ) where

import Control.Exception (bracket)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.History
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json (Json (..), fromCodePoints)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | A fresh scratch directory, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-history-store"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- | The reference's @reopen@ fixture for JSONL: each call loads a fresh
-- store over the same file.
jsonlReopen :: FilePath -> IO HistoryStore
jsonlReopen directory = openJsonlHistoryStore (directory </> "history.jsonl")

-- | @PLACE, TRANSITION = NetPath("p"), NetPath("t")@.
place', transition' :: NetPath
place' = np "p"
transition' = np "t"

-- | @TOKEN = Token("issue", {"id": "goose", "passed": True})@.
token' :: Token
token' = tokD "issue" (Object [("id", String "goose"), ("passed", Bool True)])

-- | A store refusal whose message contains the fragment.
storeErrorContaining :: Text -> Selector HistoryStoreError
storeErrorContaining fragment (HistoryStoreError message) = fragment `T.isInfixOf` message

-- | Run a script under the reference (cwd = the upstream root); fail the
-- example on a non-zero exit and return its stdout.
runPython :: (FilePath, FilePath) -> FilePath -> [String] -> IO String
runPython (python, root) script arguments = do
  scriptPath <- makeAbsolute script
  (code, out, err) <- readCreateProcessWithExitCode (proc python (scriptPath : arguments)) {cwd = Just root} ""
  case code of
    ExitSuccess -> pure out
    ExitFailure n -> do
      expectationFailure ("python " <> script <> " exited " <> show n <> ":\n" <> out <> err)
      pure out

-- | Run the example against the pinned reference: its interpreter
-- (provisioned by @scripts/upstream-python@ on first use) and the upstream
-- root. Fails loudly, never skips, when the reference cannot be provisioned.
withReference :: ((FilePath, FilePath) -> IO a) -> IO a
withReference body = do
  python <- pythonExecutable
  root <- upstreamPetrus
  body (python, root)

-- | The drivers' @surrogate_records()@: lone surrogates (WTF-8 'Text', the
-- reference's @str@) in token data, a member name, a delivery identity, an
-- Activity result and a failure text.
surrogateRecords :: [Record]
surrogateRecords =
  [ RExternalEventDelivered (ExternalEventDelivered (np "intake") tokens (fromCodePoints "evt-\xDFFF") 1 Nothing 1)
  , RTokensProduced (TokensProduced (np "queue") tokens 1 [] Nothing 1)
  , RActivityCompleted
      (ActivityCompleted (np "work") (Object [("note", String (fromCodePoints "\xDBFF!")), (fromCodePoints "\xD800", Null)]) 2 3)
  , RFiringFailed (FiringFailed (np "work") (fromCodePoints "boom \xD800") 2 4)
  ]
  where
    tokens =
      [ tokD "Payment" (String (fromCodePoints "\xD800"))
      , tokD "Payment" (Object [(fromCodePoints "\xDC00x", Array [String (fromCodePoints "a\xD83D"), Int 1, String (fromCodePoints "\xDFFF\xD800")])])
      ]

-- | The drivers' @surrogate_payment()@: a payment whose memo holds lone
-- surrogates.
surrogatePayment :: Token
surrogatePayment = tokD "Payment" (Object [("amount", Int 100), ("memo", String (fromCodePoints "\xD800 \xDC00"))])
