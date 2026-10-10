-- | The Haskell twin of conformance_driver.py's lifecycle-demo operations,
-- answered with "Petrus.Processes.Demo".
module Petrus.Processes.Conformance.Lifecycle (lifecycleOps) where

import Control.Exception (SomeException, bracket, try)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text.Encoding qualified as TE
import Petrus.Engine qualified as Engine
import Petrus.Fabric (orThrow)
import Petrus.Fabric.Conformance.Haskell (errorOut)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Postgres (exposeSource, grant, issueCredential, pending, postgresFabric, submit)
import Petrus.Impetus.Instance (statusText)
import Petrus.Json (Json (..))
import Petrus.Postgres qualified as Pg
import Petrus.Processes
import Petrus.Processes.Demo

lifecycleOps :: Handles -> Ops
lifecycleOps _ =
  Map.fromList
    [ ( "lifecycle_unarmed_reply"
      , \args -> do
          dsnText <- argText args "dsn"
          suffix <- argText args "suffix"
          let dsn = TE.encodeUtf8 dsnText
              parent = "unarmed-parent-" <> suffix
              child = "unarmed-child-" <> suffix
          parentCredential <- issueCredential
          childCredential <- issueCredential
          bootstrap dsn [(parent, parentCredential), (child, childCredential)]
          let e = callEnvelope parent child
          Pg.withConnection dsn True $ \c -> do
            parentFabric <- postgresFabric c parent parentCredential
            childFabric <- postgresFabric c child childCredential
            exposeSource parentFabric "reply"
            grant parentFabric child "reply"
            exposeSource childFabric "request"
            grant childFabric parent "request"
            value <- orThrow (callResult callId (Object [("answer", Int 42)]))
            reply <- orThrow (resultEnvelope value e child Nothing)
            () <$ submit childFabric reply
          placeholder <- orThrow (spawnSpec parent "unused" "call-only" "request" (Object []) (Object []) Nothing)
          let openLive create = do
                send <- newSendActivity dsn parent parentCredential
                dispatcher <- newDemoDispatch (Map.fromList [("fabric.send", runSend send)]) Set.empty
                openParent dsn parent parentCredential placeholder e dispatcher send create False
              attempt live = do
                result <- try (drainAuthority live)
                pure $ case result of
                  Right _ -> Null
                  Left (err :: SomeException) -> errorOut err
          -- A refused door poisons its Engine (records and status then
          -- throw), so the second attempt runs on a fresh load, and the
          -- durable outcome is read through a third one.
          (before, first) <- bracket (openLive True) closeAuthority $ \live ->
            (,) <$> (length <$> Engine.records live.engine) <*> attempt live
          second <- bracket (openLive False) closeAuthority attempt
          waiting <- Pg.withConnection dsn True $ \c -> do
            f <- postgresFabric c parent parentCredential
            length <$> pending f 100
          bracket (openLive False) closeAuthority $ \live -> do
            later <- length <$> Engine.records live.engine
            status <- Engine.status live.engine
            pure
              ( Object
                  [ ("attempts", Array [first, second])
                  , ("pending", Int (toInteger waiting))
                  , ("appended", Int (toInteger (later - before)))
                  , ("status", String (statusText status))
                  ]
              )
      )
    ]
