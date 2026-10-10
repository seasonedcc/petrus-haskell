module Main (main) where

import CliSpec qualified
import CollabSpec qualified
import EndpointsSpec qualified
import JsonSpec qualified
import McpSpec qualified
import ObservationSpec qualified
import ProtocolSpec qualified
import RelaySpec qualified
import ServerSpec qualified
import Test.Hspec
import UrlSpec qualified

main :: IO ()
main = hspec $ do
  describe "Json" JsonSpec.spec
  describe "Url" UrlSpec.spec
  describe "Protocol" ProtocolSpec.spec
  describe "Relay" RelaySpec.spec
  describe "Collab" CollabSpec.spec
  describe "Endpoints" EndpointsSpec.spec
  describe "Server" ServerSpec.spec
  describe "Observation" ObservationSpec.spec
  describe "Cli" CliSpec.spec
  describe "Mcp" McpSpec.spec
