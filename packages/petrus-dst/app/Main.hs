{-# LANGUAGE OverloadedRecordDot #-}

-- | @petrus-dst-world@: the DST tooling routes, the Haskell twins of the
-- reference's @python -m tests.dst.{replay_world,replay,failure,campaign,
-- boundaries}@ commands.
--
-- > petrus-dst-world replay ARTIFACT
-- > petrus-dst-world legacy-replay SCENARIO
-- > petrus-dst-world failure demonstrate --output BUNDLE
-- > petrus-dst-world failure replay BUNDLE
-- > petrus-dst-world campaign [--tier ordinary|scheduled] --campaign-id ID [--profile NAME]... --report PATH
-- > petrus-dst-world campaign-profile NAME
-- > petrus-dst-world boundaries [--profile NAME]... --report PATH
--
-- Results print as compact sorted JSON on standard output; a refusal
-- prints on standard error and exits 1, as the reference's uncaught
-- exception does; a usage error exits 2, as argparse does.
module Main (main) where

import Control.Exception (SomeException, displayException, fromException, handle)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst (failureClass, failureMessage)
import Petrus.Testing.Dst.Boundaries qualified as Boundaries
import Petrus.Testing.Dst.Campaign qualified as Campaign
import Petrus.Testing.Dst.Campaign.Machines (checkCampaignProfile)
import Petrus.Testing.Dst.Campaign.Support (ToolError (..), canonicalDumps, member, orRefuse)
import Petrus.Testing.Dst.Engine.ReplayWorld (replayPath, replayResultBytes)
import Petrus.Testing.Dst.Failure qualified as Failure
import Petrus.Testing.Dst.LegacyReplay qualified as Legacy
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  arguments <- getArgs
  code <- handle refusal (route arguments)
  exitWith (if code == 0 then ExitSuccess else ExitFailure code)

refusal :: SomeException -> IO Int
refusal e = do
  hPutStrLn stderr $ case fromException e of
    Just (ToolError message) -> "ValueError: " <> T.unpack message
    Nothing -> case fromException e of
      Just (Legacy.ValidationError message) -> T.unpack message
      Nothing -> displayException e
  pure 1

usage :: String -> IO Int
usage message = do
  hPutStrLn stderr ("usage: petrus-dst-world {replay,legacy-replay,failure,campaign,campaign-profile,boundaries} ...\npetrus-dst-world: error: " <> message)
  pure 2

printJson :: Json -> IO Int
printJson value = do
  bytes <- orRefuse (canonicalDumps value)
  BC.putStrLn bytes
  pure 0

route :: [String] -> IO Int
route = \case
  ["replay", artifact] ->
    replayPath artifact >>= \case
      Right result -> BC.putStrLn (replayResultBytes result) >> pure 0
      Left failure -> do
        hPutStrLn stderr (T.unpack (failureClass failure <> ": " <> failureMessage failure))
        pure 1
  ["legacy-replay", scenario] -> do
    report <- Legacy.loadScenario scenario >>= Legacy.replayScenario
    printJson (Legacy.reportJson report)
  ["failure", "demonstrate", "--output", output] -> do
    manifest <- Failure.demonstrateFailureBundle output
    printJson $
      Object
        [ ("bundle", String (T.pack output))
        , ("failure_artifact_digest", member "digest" (member "artifact" manifest))
        , ("outcome", String "pass")
        , ("promoted_scenario_id", member "scenario_id" (member "promotion" manifest))
        , ("replay_command", Array (map String ["petrus-dst-world", "failure", "replay", T.pack output]))
        ]
  ["failure", "replay", bundle] -> Failure.replayFailureBundle bundle >>= printJson
  "campaign" : rest -> campaign rest
  ["campaign-profile", name] -> do
    passed <- checkCampaignProfile (T.pack name)
    pure (if passed then 0 else 1)
  "boundaries" : rest -> boundaries rest
  _ -> usage "unrecognized arguments"

-- | @--flag VALUE@ options, in order.
options :: [String] -> Either String [(String, String)]
options = \case
  [] -> Right []
  flag : value : rest | take 2 flag == "--" -> ((flag, value) :) <$> options rest
  other : _ -> Left ("unrecognized arguments: " <> other)

values :: String -> [(String, String)] -> [Text]
values flag pairs = [T.pack v | (f, v) <- pairs, f == flag]

single :: String -> [(String, String)] -> Maybe Text
single flag pairs = case values flag pairs of
  [] -> Nothing
  vs -> Just (last vs)

campaign :: [String] -> IO Int
campaign rest = case options rest of
  Left message -> usage message
  Right pairs
    | any ((`notElem` ["--tier", "--campaign-id", "--profile", "--report"]) . fst) pairs -> usage "unrecognized arguments"
    | otherwise -> case (single "--campaign-id" pairs, single "--report" pairs) of
        (Just campaignId, Just report) -> do
          tier <- orRefuse (Campaign.parseTier (maybe "scheduled" id (single "--tier" pairs)))
          let selected = case values "--profile" pairs of
                [] -> [p.name | p <- Campaign.campaignProfiles]
                names -> names
          runner <- getExecutablePath >>= Campaign.processRunner
          Campaign.runCampaign runner tier campaignId selected (T.unpack report)
        _ -> usage "the following arguments are required: --campaign-id, --report"

boundaries :: [String] -> IO Int
boundaries rest = case options rest of
  Left message -> usage message
  Right pairs
    | any ((`notElem` ["--profile", "--report"]) . fst) pairs -> usage "unrecognized arguments"
    | otherwise -> case single "--report" pairs of
        Just report -> do
          let selected = case values "--profile" pairs of
                [] -> [p.name | p <- Boundaries.boundaryProfiles]
                names -> names
          Boundaries.runBoundaryQualification selected (T.unpack report)
        Nothing -> usage "the following arguments are required: --report"
