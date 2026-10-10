-- | Parity: @tests/petrus/impetus/instance/test_handlers.py@ — handler
-- declaration binding, handler-supplied tokens, per-arc output contracts,
-- typed passthrough routing, and the zero-consume handled emitter.
--
-- The reference asserts binding by identity (@bound_handler(t) is f@).
-- Haskell functions have no identity, so the two implementations here
-- answer distinguishable results and the spec compares what the bound
-- handler answers.
module Petrus.Impetus.HandlersSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.Binding
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)

-- | @first_handler@ / @second_handler@, made distinguishable by what they
-- answer.
firstHandler, secondHandler :: Handler
firstHandler _ _ = Right (handlerTokens [(np "first", [])])
secondHandler _ _ = Right (handlerTokens [(np "second", [])])

-- | What a bound pure handler answers for an empty binding.
answers :: HasCallStack => BoundHandler -> IO (Either Text HandlerResult)
answers = \case
  PureHandler h -> pure (h (selectionBinding (np "left") [] []) [])
  ActivityBound _ -> expectationFailure "expected a pure handler" >> error "unreachable"

exactHandlers :: [(NetUri, Handler)] -> Map.Map ImplementationRef BoundHandler
exactHandlers xs = Map.fromList [(Exact u, PureHandler h) | (u, h) <- xs]

handlerUriOf :: HasCallStack => Net -> NetPath -> NetUri
handlerUriOf net p = maybe (error "transition has no handler declaration") id (handlerUri net p)

withHandler :: NetPath -> HandlerDeclaration -> Transition
withHandler p declaration = (transition p) {handler = Just declaration}

-- | @price_order@: the receipt total is quantity times unit price.
priceOrder :: Handler
priceOrder binding _ = case bindingTokens binding of
  [order] -> do
    qty <- numberField "qty" order
    unitPrice <- numberField "unit_price" order
    Right (handlerTokens [(np "receipt_out", [tokD "Receipt" (obj [("total", Int (qty * unitPrice)), ("currency", String "USD")])])])
  _ -> Left "ValueError('too many values to unpack (expected 1)')"

spec :: Spec
spec = describe "Instance handlers" $ do
  describe "handler declaration bindings" $ do
    let left = np "left"
        right = np "right"
        net declaration = netOf [] [withHandler left declaration, withHandler right declaration] []
        shared = net (HandlerSymbol "shared")
    -- TestHandlerDeclarationBindings.test_exact_declaration_uris_bind_same_named_handlers_independently
    it "binds same-named handlers independently by exact declaration URI" $ do
      inst <-
        seededWith
          shared
          defaultInstanceConfig
            { handlerImplementations =
                exactHandlers [(handlerUriOf shared left, firstHandler), (handlerUriOf shared right, secondHandler)]
            }
      answers (boundHandler inst left) `shouldReturn` firstHandler (selectionBinding left [] []) []
      answers (boundHandler inst right) `shouldReturn` secondHandler (selectionBinding left [] []) []
    -- TestHandlerDeclarationBindings.test_local_symbol_deliberately_shares_one_handler
    it "shares one handler through the local symbol" $ do
      inst <- seededWith shared defaultInstanceConfig {handlerImplementations = symbolHandlers [("shared", firstHandler)]}
      answers (boundHandler inst left) `shouldReturn` firstHandler (selectionBinding left [] []) []
      answers (boundHandler inst right) `shouldReturn` firstHandler (selectionBinding left [] []) []
    -- TestHandlerDeclarationBindings.test_exact_and_local_binding_for_one_handler_is_ambiguous
    it "refuses an exact and a local binding for one handler as ambiguous" $ do
      result <-
        newInstance
          shared
          defaultInstanceConfig
            { handlerImplementations =
                Map.fromList [(Symbol "shared", PureHandler firstHandler), (Exact (handlerUriOf shared left), PureHandler secondHandler)]
            }
      result `shouldRefuse` "handler declaration transition:/left#handler has both an exact implementation and local symbol 'shared'"
    -- TestHandlerDeclarationBindings.test_anonymous_handler_requires_its_exact_declaration_uri
    it "requires the exact declaration URI for an anonymous handler" $ do
      let anonymousNet = net (HandlerAnonymous anonymous)
      result <- newInstance anonymousNet defaultInstanceConfig
      result `shouldRefuse` "handler declaration(s) with no implementation: ['transition:/left#handler', 'transition:/right#handler']"
      inst <-
        seededWith
          anonymousNet
          defaultInstanceConfig
            { handlerImplementations =
                exactHandlers [(handlerUriOf anonymousNet left, firstHandler), (handlerUriOf anonymousNet right, secondHandler)]
            }
      answers (boundHandler inst left) `shouldReturn` firstHandler (selectionBinding left [] []) []

  describe "handler tokens" $ do
    let orderIn = np "order_in"
        price = np "price"
        receiptOut = np "receipt_out"
        order = tokD "Order" (obj [("sku", String "widget"), ("qty", Int 3), ("unit_price", Int 25)])
        receipt = tokD "Receipt" (obj [("total", Int 75), ("currency", String "USD")])
        net = netOf [place orderIn, place receiptOut] [withHandler price (HandlerSymbol "price_order")] [arc orderIn price, arc price receiptOut]
        fresh =
          seededWith
            net
            defaultInstanceConfig
              { initialMarking = markingFromList [(orderIn, [order])]
              , handlerImplementations = symbolHandlers [("price_order", priceOrder)]
              }
    -- TestHandlerTokens.test_handler_supplied_token_is_deposited_not_the_consumed_one
    it "deposits the handler-supplied token, not the consumed one" $ do
      inst <- fresh
      _ <- run inst >>= expectRight
      marking inst `shouldReturn` markingFromList [(receiptOut, [receipt])]
    -- TestHandlerTokens.test_firing_reports_consumed_input_and_handler_output
    it "reports the consumed input and the handler output" $ do
      [firing] <- fresh >>= run >>= expectRight
      firing.consumed `shouldBe` [order]
      firing.produced `shouldBe` [(receiptOut, receipt)]
    -- TestHandlerTokens.test_handler_firing_records_movements_in_lifecycle_order
    it "records the handler firing's movements in lifecycle order" $ do
      [firing] <- fresh >>= run >>= expectRight
      firing.records
        `shouldBe` [ RFiringBegun (FiringBegun price 1 Nothing 0)
                   , RTokensConsumed (TokensConsumed orderIn [order] 1 [] Nothing 0)
                   , RTokensProduced (TokensProduced receiptOut [receipt] 1 [] Nothing 0)
                   , RFiringCompleted (FiringCompleted price 1 0)
                   ]
    -- TestHandlerTokens.test_history_replays_handler_supplied_tokens
    it "replays the handler-supplied tokens from History" $ do
      inst <- fresh
      _ <- run inst >>= expectRight
      records <- historyOf inst
      live <- marking inst
      replayMarking records `shouldBe` Right live
    -- TestHandlerTokens.test_missing_handler_implementation_fails_at_construction
    it "fails at construction on a missing handler implementation" $ do
      result <- newInstance net defaultInstanceConfig
      result `shouldRefuse` "handler declaration(s) with no implementation: ['price_order']"

  describe "a handler sees the full binding" $ do
    let config = np "config"
        pending = np "pending"
        charge = np "charge"
        out = np "out"
        -- @apply_fee@: the read config's fee added to the consumed payment.
        applyFee :: Handler
        applyFee binding _ = case (binding.read, bindingTokens binding) of
          ([(_, [cfg])], [payment]) -> do
            amount <- numberField "amount" payment
            fee <- numberField "fee" cfg
            Right (handlerTokens [(out, [tokD "Charged" (obj [("amount", Int (amount + fee))])])])
          _ -> Left "ValueError('not enough values to unpack')"
    -- TestHandlerSeesTheFullBinding.test_handler_correlates_consumed_and_read_tokens
    it "correlates consumed and read tokens" $ do
      let net =
            netOf
              [place config, place pending, place out]
              [withHandler charge (HandlerSymbol "apply_fee")]
              [(arc config charge) {mode = Read}, arc pending charge, arc charge out]
      inst <-
        seededWith
          net
          defaultInstanceConfig
            { initialMarking =
                markingFromList
                  [(config, [tokD "Config" (obj [("fee", Int 5)])]), (pending, [tokD "Payment" (obj [("amount", Int 100)])])]
            , handlerImplementations = symbolHandlers [("apply_fee", applyFee)]
            }
      _ <- run inst >>= expectRight
      current <- marking inst
      toList (placeTokens out current) `shouldBe` [tokD "Charged" (obj [("amount", Int 105)])]
      toList (placeTokens config current) `shouldBe` [tokD "Config" (obj [("fee", Int 5)])]

  describe "per-arc output contracts" $ do
    let pending = np "pending"
        settle = np "settle"
        approved = np "approved"
        ledger = np "ledger"
        notice = tokD "ApprovalNotice" (obj [("ok", Bool True)])
        entry = tokD "LedgerEntry" (obj [("amount", Int 150)])
        net =
          netOf
            [place pending, place approved, place ledger]
            [withHandler settle (HandlerSymbol "settle")]
            [arc pending settle, withArcColor (Just "ApprovalNotice") (arc settle approved), withArcColor (Just "LedgerEntry") (arc settle ledger)]
        fired handler = do
          inst <-
            seededWith
              net
              defaultInstanceConfig
                { initialMarking = markingFromList [(pending, [tokD "Payment" (obj [("amount", Int 150)])])]
                , handlerImplementations = symbolHandlers [("settle", handler)]
                }
          [firing] <- run inst >>= expectRight
          pure (inst, firing)
    -- TestPerArcOutputContracts.test_heterogeneous_fanout_deposits_different_payloads_per_branch
    it "deposits different payloads per branch of a heterogeneous fan-out" $ do
      (inst, firing) <- fired (\_ _ -> Right (handlerTokens [(approved, [notice]), (ledger, [entry])]))
      marking inst `shouldReturn` markingFromList [(approved, [notice]), (ledger, [entry])]
      firing.produced `shouldBe` [(approved, notice), (ledger, entry)]
    -- TestPerArcOutputContracts.test_token_whose_color_matches_no_arc_at_its_destination_is_dropped
    it "drops a token whose color matches no arc at its destination" $ do
      (inst, firing) <- fired (\_ _ -> Right (handlerTokens [(approved, [entry]), (ledger, [entry])]))
      marking inst `shouldReturn` markingFromList [(ledger, [entry])]
      firing.produced `shouldBe` [(ledger, entry)]
    -- TestPerArcOutputContracts.test_token_keyed_to_a_place_with_no_output_arc_is_dropped
    it "drops a token keyed to a place with no output arc" $ do
      (inst, firing) <- fired (\_ _ -> Right (handlerTokens [(pending, [notice]), (ledger, [entry])]))
      marking inst `shouldReturn` markingFromList [(ledger, [entry])]
      firing.produced `shouldBe` [(ledger, entry)]
    -- TestPerArcOutputContracts.test_a_handler_may_consult_the_output_arcs_to_route
    it "lets a handler consult the output arcs to route" $ do
      (inst, firing) <- fired (\_ outputArcs -> Right (handlerTokens [(o.target, [notice]) | o <- outputArcs, arcAdmits o notice.color]))
      firing.produced `shouldBe` [(approved, notice)]
      marking inst `shouldReturn` markingFromList [(approved, [notice])]

  describe "typed passthrough routing" $ do
    let input = np "in"
        routeT = np "route"
        xs = np "xs"
        anything = np "anything"
        ys = np "ys"
    -- TestTypedPassthroughRouting.test_forwards_through_admitting_arcs_only
    it "forwards through admitting arcs only" $ do
      let net =
            netOf
              [place input, place xs, place anything, place ys]
              [transition routeT]
              [arc input routeT, withArcColor (Just "X") (arc routeT xs), arc routeT anything, withArcColor (Just "Y") (arc routeT ys)]
      inst <- seeded net (markingFromList [(input, [tok "X"])])
      _ <- run inst >>= expectRight
      marking inst `shouldReturn` markingFromList [(xs, [tok "X"]), (anything, [tok "X"])]
    -- TestTypedPassthroughRouting.test_consumed_token_admitted_by_no_arc_is_simply_consumed
    it "simply consumes a token no arc admits" $ do
      let net = netOf [place input, place ys] [transition routeT] [arc input routeT, withArcColor (Just "Y") (arc routeT ys)]
      inst <- seeded net (markingFromList [(input, [tok "X"])])
      _ <- run inst >>= expectRight
      marking inst `shouldReturn` emptyMarking
      isQuiescent inst `shouldReturn` True

  describe "zero-consume handled emitter" $ do
    let signal = np "signal"
        emit = np "emit"
        out = np "out"
        done = np "done"
    -- TestZeroConsumeHandledEmitter.test_self_inhibiting_emitter_fires_once_then_quiesces
    it "fires a self-inhibiting emitter once, then quiesces" $ do
      let net =
            netOf
              [place signal, place out, place done]
              [withHandler emit (HandlerSymbol "emit_once")]
              [(arc signal emit) {mode = Read}, (arc done emit) {mode = Inhibit}, arc emit out, arc emit done]
          emitOnce _ _ = Right (handlerTokens [(out, [tok "Emitted"]), (done, [black])])
      inst <-
        seededWith
          net
          defaultInstanceConfig
            { initialMarking = markingFromList [(signal, [black])]
            , handlerImplementations = symbolHandlers [("emit_once", emitOnce)]
            }
      firings <- run inst >>= expectRight
      length firings `shouldBe` 1
      map (.produced) firings `shouldBe` [[(out, tok "Emitted"), (done, black)]]
      current <- marking inst
      toList (placeTokens out current) `shouldBe` [tok "Emitted"]
      isQuiescent inst `shouldReturn` True
