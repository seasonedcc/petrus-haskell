module Main (main) where

import ChainProducer (serveChain)
import CliSpec qualified
import CollabSpec qualified
import EndpointsSpec qualified
import HistorySpec qualified
import JsonSpec qualified
import McpSpec qualified
import ObservationSpec qualified
import ProxySpec qualified
import ProtocolSpec qualified
import RelaySpec qualified
import ServerSpec qualified
import Data.Text qualified as T
import System.Environment (getArgs)
import Test.Hspec
import UrlSpec qualified

main :: IO ()
main =
  getArgs >>= \case
    ["--chain-producer", instanceId] -> serveChain (T.pack instanceId)
    _ -> specs

specs :: IO ()
specs = hspec $ do
  describe "Json" JsonSpec.spec
  describe "Url" UrlSpec.spec
  describe "Protocol" ProtocolSpec.spec
  describe "Relay" RelaySpec.spec
  describe "Collab" CollabSpec.spec
  describe "Endpoints" EndpointsSpec.spec
  describe "Server" ServerSpec.spec
  describe "Observation" ObservationSpec.spec
  describe "Proxy" ProxySpec.spec
  describe "History" HistorySpec.spec
  describe "Cli" CliSpec.spec
  describe "Mcp" McpSpec.spec
