import XCTest
import StoreKit
import StoreKitTest
@testable import RoomInTheCart

/// Opt-in, serial integration suite. Never pointed at a service or an App Store Connect product.
@MainActor final class StoreKitScenarioTests: XCTestCase {
    private let productID = "local.testing.household.annual"
    private let accountToken = UUID()
    private var session: SKTestSession!
    private var cancellationTraceStart: ContinuousClock.Instant?
    private var cancellationTraceCount = 0

    // Temporary diagnostic: fixed stage labels only, persisted before the next await.
    // No identities, tokens, receipts, error descriptions, or transaction payloads.
    private func traceCancellation(_ stage: StaticString) {
        guard let start = cancellationTraceStart, cancellationTraceCount < 96 else { return }
        cancellationTraceCount += 1
        let line = "StoreKitCancellationTrace seq=\(cancellationTraceCount) elapsed=\(start.duration(to: .now)) stage=\(stage)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let attachment = XCTAttachment(string: line)
        attachment.name = "StoreKitCancellation-stage-\(cancellationTraceCount)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    override func setUp() async throws {
        if name.contains("testSimulatedPurchaseCancellationGrantsNothing") {
            cancellationTraceStart = .now
            cancellationTraceCount = 0
        }
        traceCancellation("setup.super.begin")
        try await super.setUp()
        traceCancellation("setup.super.end")
        guard ProcessInfo.processInfo.environment["RITC_LOCAL_STOREKIT_TESTS"] == "1" else {
            throw XCTSkip("Run the serial LocalStoreKit test plan to enable the isolated StoreKit environment.")
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HouseholdLocalTesting", withExtension: "storekit"),
                                "Add HouseholdLocalTesting.storekit to the test target's resources only.")
        traceCancellation("setup.session-and-configuration.begin")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        session.storefront = "USA"
        let requestedLocale = ProcessInfo.processInfo.environment["RITC_STOREKIT_LOCALE"] ?? "en_US"
        session.locale = Locale(identifier: requestedLocale)
        traceCancellation("setup.session-and-configuration.end")
        traceCancellation("setup.sync.begin")
        try await AppStore.sync()
        traceCancellation("setup.sync.end")
        XCTAssertEqual(session.locale.identifier.replacingOccurrences(of: "-", with: "_"), requestedLocale,
                       "Use the explicit supported product-metadata locale from the plan; never silently change it.")
    }

    override func tearDown() async throws {
        traceCancellation("teardown.begin")
        if let session {
            traceCancellation("teardown.reset.begin")
            session.resetToDefaultState()
            session.disableDialogs = true
            traceCancellation("teardown.reset.end")
            traceCancellation("teardown.unfinished.begin")
            for await result in StoreKit.Transaction.unfinished {
                if case .verified(let transaction) = result,
                   transaction.environment == .xcode && transaction.productID == productID {
                    traceCancellation("teardown.finish.begin")
                    await transaction.finish()
                    traceCancellation("teardown.finish.end")
                }
            }
            traceCancellation("teardown.unfinished.end")
            traceCancellation("teardown.clear.begin")
            session.clearTransactions()
            traceCancellation("teardown.clear.end")
            traceCancellation("teardown.sync.begin")
            try await AppStore.sync()
            traceCancellation("teardown.sync.end")
            traceCancellation("teardown.final-reset.begin")
            session.resetToDefaultState()
            traceCancellation("teardown.final-reset.end")
        }
        session = nil
        traceCancellation("teardown.super.begin")
        try await super.tearDown()
        traceCancellation("teardown.super.end")
        traceCancellation("teardown.end")
    }

    func testLocalAnnualOfferUsesStoreKitPriceAndLocale() async throws {
        let storefront = StoreKitMembershipStorefront()
        let offer = try await storefront.load(productID: productID)
        XCTAssertEqual(offer.productID, productID)
        XCTAssertEqual(offer.periodValue, 1)
        XCTAssertEqual(offer.periodUnit, .year)
        let expected = session.locale.language.languageCode?.identifier == "es" ? "Household (prueba local)" : "Household (local test)"
        XCTAssertEqual(offer.displayName, expected)
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(offer.displayPrice, product.displayPrice)
        XCTAssertEqual(product.price, Decimal(string: "49.99")) // Fixture hypothesis, never a production-price assertion.
        XCTAssertFalse(product.isFamilyShareable)
        XCTAssertEqual(product.priceFormatStyle.currencyCode, "USD")
        let storefrontCountry = await Storefront.current?.countryCode
        XCTAssertEqual(storefrontCountry, "USA")
        XCTAssertEqual(Locale.current.region?.identifier, "US")
        let appLanguage = ProcessInfo.processInfo.environment["RITC_APP_LANGUAGE"] ?? "en-US"
        XCTAssertEqual(Locale.current.language.languageCode?.identifier, String(appLanguage.prefix(2)))
    }

    func testPurchaseDoesNotFinishOrGrantAccessWithoutDurableServiceDelivery() async throws {
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        // A fresh purchase requires the session reset to have reached StoreKit, too.
        // An unfinished purchase would exercise account reconciliation instead.
        try await eventually("The reset customer has no StoreKit history, entitlement or unfinished purchase") {
            guard self.session.allTransactions().isEmpty else { return false }
            guard await storefront.currentTransactions().isEmpty else { return false }
            return await storefront.unfinishedTransactions().isEmpty
        }
        await model.purchase()
        XCTAssertEqual(model.notice, .failed(.notConfigured))
        let purchases = await storefront.currentTransactions()
        let transaction = try verified(try XCTUnwrap(purchases.first))
        XCTAssertEqual(model.purchaseReport, .verified(transactionID: transaction.transactionID))
        XCTAssertTrue(transaction.appAccountToken == accountToken, "The purchase must belong to this fixture account")
        XCTAssertEqual(transaction.productID, productID)
        XCTAssertFalse(transaction.signedTransactionInfo.isEmpty)
        assertFree(model)
        let pending = await storefront.unfinishedTransactions()
        XCTAssertTrue(pending.contains { id($0) == transaction.transactionID })
        let purchaseIDs = session.allTransactions().map(\.identifier)
        await model.purchase()
        XCTAssertEqual(session.allTransactions().map(\.identifier), purchaseIDs)
        XCTAssertEqual(model.notice, .failed(.notConfigured))
        let stillUnfinished = await storefront.unfinishedTransactions()
        XCTAssertTrue(stillUnfinished.contains { id($0) == transaction.transactionID })
        assertFree(model)
    }

    func testRealTransactionObserverAttemptsDeliveryWithoutUnlock() async throws {
        let storefront = StoreKitMembershipStorefront()
        let model = makeModel(storefront: storefront)
        defer { model.stop() }
        await model.start()
        let purchased = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        do {
            try await eventually("The app-scoped StoreKit observer attempts delivery") {
                model.notice == .failed(.notConfigured)
            }
        } catch {
            // Capture the failed boundary before another await. Keep the original
            // failure; these fixed flags contain no identities or transaction data.
            let delivery = model.deliveryOutcomes[String(purchased.id)]
            let rejections = model.callbackRejections
            let state = XCTAttachment(string: """
            phase=after-delivery-predicate-failure-before-raw-read
            offerLoaded=\(model.offer != nil) stopped=\(model.isStopped) busy=\(model.isBusy)
            noticePresent=\(model.notice != nil) noticeNotConfigured=\(model.notice == .failed(.notConfigured))
            issuePresent=\(model.state.issue != nil) issueNotConfigured=\(model.state.issue == .notConfigured)
            deliveryCount=\(model.deliveryOutcomes.count) purchasedDeliveryAbsent=\(delivery == nil)
            purchasedDeliveryInFlight=\(delivery == .inFlight) purchasedDeliverySaved=\(delivery == .delivered)
            purchasedDeliveryNotConfigured=\(delivery == .failed(.notConfigured))
            callbackCount=\(rejections.count) callbackUnverified=\(rejections.contains(.unverified))
            callbackAccountMismatch=\(rejections.contains(.accountMismatch)) callbackNotPurchaser=\(rejections.contains(.notPurchaser))
            callbackSignInRequired=\(rejections.contains(.signInRequired)) paidAccess=\(model.hasPaidAccess)
            """)
            state.name = "Observer-failure-model-before-raw-read"
            state.lifetime = .keepAlways; add(state)

            // One sample-limited read after failure, without adapter conversion, refresh,
            // sync or finish. It cannot turn the failed predicate into a pass.
            var sampled = 0, verified = 0, unverified = 0
            var purchasedVerified = 0, purchasedUnverified = 0
            var purchasedProductMatches = 0, purchasedTokenMatches = 0, purchasedTokenNil = 0
            var truncated = false
            for await result in StoreKit.Transaction.unfinished {
                guard sampled < 8 else { truncated = true; break }
                sampled += 1
                let transaction: StoreKit.Transaction
                switch result {
                case .verified(let value):
                    transaction = value; verified += 1
                    if value.id == purchased.id { purchasedVerified += 1 }
                case .unverified(let value, _):
                    transaction = value; unverified += 1
                    if value.id == purchased.id { purchasedUnverified += 1 }
                }
                if transaction.id == purchased.id {
                    if transaction.productID == productID { purchasedProductMatches += 1 }
                    if transaction.appAccountToken == accountToken { purchasedTokenMatches += 1 }
                    if transaction.appAccountToken == nil { purchasedTokenNil += 1 }
                }
            }
            let raw = XCTAttachment(string: """
            phase=raw-unfinished-snapshot-after-failed-predicate sampleLimit=8
            sampled=\(sampled) truncated=\(truncated) verified=\(verified) unverified=\(unverified)
            purchasedVerified=\(purchasedVerified) purchasedUnverified=\(purchasedUnverified)
            purchasedProductMatches=\(purchasedProductMatches) purchasedTokenMatches=\(purchasedTokenMatches) purchasedTokenNil=\(purchasedTokenNil)
            """)
            raw.name = "Observer-failure-raw-unfinished-after-predicate"
            raw.lifetime = .keepAlways; add(raw)
            throw error
        }
        assertFree(model)
        try await eventually("The observed transaction remains unfinished") {
            await storefront.unfinishedTransactions().contains { self.id($0) == String(purchased.id) }
        }
    }

    func testRelaunchAndExplicitRestoreReplayUnfinishedWithoutUnlock() async throws {
        let transaction = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        try await eventually("The local purchase becomes unfinished before restore") {
            await storefront.unfinishedTransactions().contains { self.id($0) == String(transaction.id) }
        }
        await model.restore()
        XCTAssertEqual(model.notice, .failed(.notConfigured))
        assertFree(model)
        try await eventually("The same undelivered purchase stays unfinished after restore") {
            await storefront.unfinishedTransactions().contains { self.id($0) == String(transaction.id) }
        }
        // A new adapter/model represents relaunch; no entitlement snapshot is restored from local defaults.
        let (_, relaunched) = try await loadedModel()
        defer { relaunched.stop() }
        await relaunched.refresh()
        assertFree(relaunched)
    }

    func testAskToBuyApprovalRemainsUndelivered() async throws {
        session.askToBuyEnabled = true
        let (storefront, model) = try await loadedModel()
        let purchase = beginPurchase(model)
        defer { purchase.task?.cancel(); model.stop() }
        do {
            // A fresh hosted StoreKit session took 15s to return its pending result.
            // Keep the complete pending boundary while allowing that first response.
            try await eventually("A real Ask to Buy request reaches pending approval", timeout: .seconds(30)) {
                purchase.finished && model.purchaseReport == .pending
                    && self.session.allTransactions().contains { $0.pendingAskToBuyConfirmation }
            }
        } catch {
            // Observe only after the original predicate fails, before teardown.
            // Retain fixed state labels/counts, never purchase identities or payloads.
            let report: String
            switch model.purchaseReport {
            case .some(.awaitingResult): report = "awaiting-result"
            case .some(.pending): report = "pending"
            case .some(.cancelled): report = "cancelled"
            case .some(.unverified): report = "unverified"
            case .some(.verified): report = "verified"
            case .some(.failed): report = "failed"
            case .none: report = "none"
            }
            let state = "finished=\(purchase.finished) busy=\(model.isBusy) stopped=\(model.isStopped) report=\(report)"
            let transactions = session.allTransactions()
            let sample = transactions.prefix(8)
            let attachment = XCTAttachment(string: "phase=initial-pending-predicate-failed \(state) sessionTotal=\(transactions.count) sampleLimit=8 sampleCount=\(sample.count) pendingInSample=\(sample.filter { $0.pendingAskToBuyConfirmation }.count) truncated=\(transactions.count > 8)")
            attachment.name = "AskToBuy-initial-pending-failure"
            attachment.lifetime = .keepAlways; add(attachment)
            throw error
        }
        let request = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        // Follow the documented pending-result then approval sequence. The test
        // session can expose its pending request before the purchase call returns.
        XCTAssertEqual(model.notice, .pending)
        XCTAssertFalse(model.isBusy)
        assertFree(model)
        XCTAssertEqual(session.allTransactions().count, 1, "The fresh approval fixture contains only its pending request")
        // Bounded structural diagnostics only. No transaction identity, token,
        // signature, payload, or arbitrary error description enters this log.
        // Observation work can affect scheduling; this is an instrumented run.
        let observationStart = ContinuousClock.now
        let sampleLimit = 128
        let collectionLimit = 8
        var observations: [String] = []
        var droppedSamples = 0
        func failureLabel(_ issue: MembershipFailure) -> String {
            switch issue {
            case .notConfigured: return "not-configured"
            case .signInRequired: return "sign-in-required"
            case .unavailable: return "unavailable"
            case .unverified: return "unverified"
            case .wrongHousehold: return "wrong-household"
            case .invalidSnapshot: return "invalid-snapshot"
            case .invalidReceipt: return "invalid-receipt"
            case .deliveryPending: return "delivery-pending"
            case .serverRejected: return "server-rejected"
            case .accountMismatch: return "account-mismatch"
            case .refreshRequired: return "refresh-required"
            case .notPurchaser: return "not-purchaser"
            case .membershipInactive: return "membership-inactive"
            }
        }
        func deliveryLabel(_ outcome: MembershipModel.DeliveryOutcome) -> String {
            switch outcome {
            case .inFlight: return "in-flight"
            case .delivered: return "delivered"
            case .failed(let issue): return "failed." + failureLabel(issue)
            }
        }
        func observe(_ stage: String, current: [MembershipPurchaseOutcome]? = nil,
                     approved: [SignedMembershipTransaction]? = nil) {
            guard observations.count < sampleLimit else { droppedSamples += 1; return }
            let report: String
            switch model.purchaseReport {
            case .some(.awaitingResult): report = "awaiting-result"
            case .some(.pending): report = "pending"
            case .some(.cancelled): report = "cancelled"
            case .some(.unverified): report = "unverified"
            case .some(.verified): report = "verified"
            case .some(.failed(let issue)): report = "failed." + failureLabel(issue)
            case .none: report = "none"
            }
            let currentEvidence: String
            if let current, let approved {
                let sample = current.prefix(collectionLimit)
                let verified = sample.compactMap { outcome -> SignedMembershipTransaction? in
                    if case .verified(let value) = outcome { return value }; return nil
                }
                let matchingOutcome = approved.count == 1
                    ? model.deliveryOutcomes[approved[0].transactionID].map(deliveryLabel) ?? "absent"
                    : "non-unique"
                let unverifiedCount = sample.filter { if case .unverified = $0 { return true }; return false }.count
                currentEvidence = "currentRead=true currentTotal=\(current.count) sampleCount=\(sample.count) sampleTruncated=\(current.count > collectionLimit) sampleVerified=\(verified.count) sampleProductMatches=\(verified.filter { $0.productID == self.productID }.count) sampleTokenMatches=\(verified.filter { $0.appAccountToken == self.accountToken }.count) sampleNilTokens=\(verified.filter { $0.appAccountToken == nil }.count) sampleUnverified=\(unverifiedCount) approvedCount=\(approved.count) matchingOutcome=\(matchingOutcome)"
            } else {
                currentEvidence = "currentRead=false currentCounts=not-read approvedCount=not-read matchingOutcome=not-read"
            }
            let delivery = model.deliveryOutcomes.values.prefix(collectionLimit).map(deliveryLabel).sorted().joined(separator: ",")
            let callbacks = model.callbackRejections.prefix(collectionLimit).map(failureLabel).sorted().joined(separator: ",")
            observations.append("\(observationStart.duration(to: .now)) stage=\(stage) finished=\(purchase.finished) busy=\(model.isBusy) report=\(report) deliveryTotal=\(model.deliveryOutcomes.count) deliverySample=[\(delivery)] deliveryTruncated=\(model.deliveryOutcomes.count > collectionLimit) callbackTotal=\(model.callbackRejections.count) callbackSample=[\(callbacks)] callbacksTruncated=\(model.callbackRejections.count > collectionLimit) \(currentEvidence)")
        }
        defer {
            observe("test-exit")
            let header = "sampleLimit=\(sampleLimit) collectionLimit=\(collectionLimit) droppedSamples=\(droppedSamples)"
            let attachment = XCTAttachment(string: ([header] + observations).joined(separator: "\n"))
            attachment.name = "AskToBuy-predicate-observations"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        observe("before-approval")
        try session.approveAskToBuyTransaction(identifier: request.identifier)
        observe("after-approval")
        try await eventually("Approval completes the purchase flow and attempts durable delivery") {
            guard purchase.finished else { observe("purchase-open"); return false }
            // Read the identity from StoreKit 2 itself; do not assume that an
            // SKTestTransaction.identifier equals a StoreKit.Transaction.id.
            let current = await storefront.currentTransactions()
            let approved = current.compactMap { outcome -> SignedMembershipTransaction? in
                guard case .verified(let transaction) = outcome,
                      transaction.productID == self.productID,
                      transaction.appAccountToken == self.accountToken else { return nil }
                return transaction
            }
            observe("current-read", current: current, approved: approved)
            guard approved.count == 1, let transaction = approved.first else { return false }
            return model.deliveryOutcomes[transaction.transactionID] == .failed(.notConfigured)
        }
        XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.notConfigured)),
                      "The exact verified transaction's service-delivery failure remains visible")
        try await eventually("Approved transaction appears in current entitlements") {
            await storefront.currentTransactions().contains { self.id($0) != nil }
        }
        assertFree(model)
        try await eventually("The approved purchase remains unfinished") {
            await storefront.unfinishedTransactions().contains {
                if case .verified(let transaction) = $0 { return transaction.appAccountToken == self.accountToken }
                return false
            }
        }
    }

    func testAskToBuyDeclineGrantsNothing() async throws {
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        let before = await storefront.currentTransactions()
        XCTAssertTrue(before.isEmpty, "The fresh customer has no prior entitlement")
        try await declineNewPurchase(storefront: storefront, model: model)
    }

    func testRestoredSubscriptionThenCancelledAndDeclinedRepurchasesStayFree() async throws {
        let original = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        // Seed a previously completed local purchase. An unfinished purchase would
        // be replayed by StoreKit when this customer later attempts to repurchase.
        await original.finish()
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        await model.restore()
        try await eventually("Restore sees the same previously completed subscription") {
            await storefront.currentTransactions().contains { self.id($0) == String(original.id) }
        }
        XCTAssertEqual(model.notice, .failed(.notConfigured))
        assertFree(model)

        // End the original term, then attempt two new purchases with this same
        // model, account and annual SKU.
        try session.expireSubscription(productIdentifier: productID)
        try await AppStore.sync()
        try await eventually("The restored subscription expires before repurchase") {
            await storefront.currentTransactions().isEmpty
        }
        let latest = await StoreKit.Transaction.latest(for: productID)
        guard case .verified(let ended) = try XCTUnwrap(latest) else { return XCTFail("Unverified fixture expiry") }
        XCTAssertEqual(ended.id, original.id)
        XCTAssertLessThanOrEqual(try XCTUnwrap(ended.expirationDate), Date())
        // SKTestSession emits the forced expiry as an unfinished update for the same
        // transaction. Complete that fixture update before testing a new purchase.
        await ended.finish()
        try await eventually("The expired fixture update is complete before repurchase") {
            await storefront.unfinishedTransactions().isEmpty
        }
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await model.purchase()
        XCTAssertTrue(model.notice == .cancelled || model.notice == .failed(.unavailable))
        let afterCancel = await storefront.currentTransactions()
        XCTAssertTrue(afterCancel.isEmpty)
        assertFree(model)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        // StoreKit can queue the new payment behind the cancelled repurchase before marking it pending.
        try await declineNewPurchase(storefront: storefront, model: model, pendingTimeout: .seconds(30))
    }

    private func declineNewPurchase(storefront: StoreKitMembershipStorefront, model: MembershipModel,
                                    pendingTimeout: Duration = .seconds(10)) async throws {
        session.askToBuyEnabled = true
        let purchase = beginPurchase(model)
        defer { purchase.task?.cancel() }
        try await eventually("A real Ask to Buy request reaches pending approval", timeout: pendingTimeout) {
            self.session.allTransactions().contains { $0.pendingAskToBuyConfirmation }
        }
        let request = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        let pendingEntitlements = await storefront.currentTransactions()
        XCTAssertTrue(pendingEntitlements.isEmpty, "The pending request has no current entitlement")
        if purchase.finished { XCTAssertEqual(model.notice, .pending) }
        else { XCTAssertTrue(model.isBusy) }
        assertFree(model)
        try session.declineAskToBuyTransaction(identifier: request.identifier)
        try await AppStore.sync()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var pendingCount = 0, purchasedCount = 0, failedCount = 0, deferredCount = 0
        var currentCount = 0, verifiedCount = 0, unverifiedCount = 0
        repeat {
            let transactions = session.allTransactions().filter { $0.identifier == request.identifier }
            pendingCount = transactions.filter { $0.pendingAskToBuyConfirmation }.count
            purchasedCount = transactions.filter { $0.state == .purchased }.count
            failedCount = transactions.filter { $0.state == .failed }.count
            deferredCount = transactions.filter { $0.state == .deferred }.count
            let current = await storefront.currentTransactions()
            currentCount = current.count
            verifiedCount = current.filter { if case .verified = $0 { return true }; return false }.count
            unverifiedCount = current.filter { if case .unverified = $0 { return true }; return false }.count
            if purchase.finished && pendingCount == 0 && currentCount == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        var returnedDeclinedRequest = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.id == UInt64(request.identifier),
               transaction.productID == productID, transaction.appAccountToken == accountToken,
               transaction.environment == .xcode, transaction.revocationDate == nil,
               let expiration = transaction.expirationDate, expiration > Date() {
                returnedDeclinedRequest = true
            }
        }
        let diagnostic = "purchaseFinished=\(purchase.finished); modelBusy=\(model.isBusy); pendingFlags=\(pendingCount); purchased=\(purchasedCount); failed=\(failedCount); deferred=\(deferredCount); currentWhilePending=\(pendingEntitlements.count); current=\(currentCount); verified=\(verifiedCount); unverified=\(unverifiedCount); verifiedUnexpiredDeclinedRequest=\(returnedDeclinedRequest); notice=\(String(describing: model.notice))"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "Ask to Buy decline — structural state only"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(purchase.finished, "Purchase call did not finish after decline. " + diagnostic)
        XCTAssertEqual(pendingCount, 0, "Declined request still carries a pending flag. " + diagnostic)
        XCTAssertEqual(currentCount, 0, "Declined request must not be a current entitlement. " + diagnostic)
        XCTAssertFalse(returnedDeclinedRequest, diagnostic)
        XCTAssertTrue(model.notice == .pending || model.notice == .cancelled || model.notice == .failed(.unavailable))
        assertFree(model)
    }

    func testSimulatedPurchaseCancellationGrantsNothing() async throws {
        traceCancellation("body.begin")
        let storefront = CancellationTracingStorefront(trace: traceCancellation)
        let model = makeModel(storefront: storefront)
        traceCancellation("model.start.begin")
        await model.start()
        traceCancellation("model.start.end")
        traceCancellation("observer-yield.begin")
        await Task.yield()
        traceCancellation("observer-yield.end")
        _ = try XCTUnwrap(model.offer, "The local fixture must load before checking transaction state")
        defer {
            traceCancellation("model.stop.begin")
            model.stop()
            traceCancellation("model.stop.end")
        }
        traceCancellation("simulated-error.begin")
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        traceCancellation("simulated-error.end")
        traceCancellation("model.purchase.begin")
        await model.purchase()
        traceCancellation("model.purchase.end")
        // StoreKit may deliver a cancellation result or throw its simulated cancellation error.
        XCTAssertTrue(model.notice == .cancelled || model.notice == .failed(.unavailable))
        // Some StoreKitTest runtimes retain a failed transaction for the cancelled attempt.
        traceCancellation("history.begin")
        let history = session.allTransactions()
        traceCancellation("history.end")
        XCTAssertTrue(history.allSatisfy { $0.state == .failed && !$0.pendingAskToBuyConfirmation },
                      "Unexpected cancellation history states: \(history.map { $0.state.rawValue })")
        let current = await storefront.currentTransactions()
        let unfinished = await storefront.unfinishedTransactions()
        XCTAssertTrue(current.isEmpty, "Cancellation must not create an entitlement")
        XCTAssertTrue(unfinished.isEmpty, "Cancellation must not create an unfinished purchase")
        let summary = XCTAttachment(string: "historyStates=\(history.map { $0.state.rawValue }); current=\(current.count); unfinished=\(unfinished.count)")
        summary.name = "Cancelled purchase — structural state only"
        summary.lifetime = .keepAlways
        add(summary)
        assertFree(model)
        traceCancellation("body.end")
    }

    func testUnverifiedLocalTransactionGrantsNothing() async throws {
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let outcome = try await storefront.purchase(appAccountToken: accountToken)
        guard case .unverified = outcome else { return XCTFail("Simulated signature failure must remain unverified") }
        let failure = await model.receive(outcome)
        XCTAssertEqual(failure, .unverified)
        XCTAssertEqual(model.notice, .failed(.unverified))
        assertFree(model)
    }

    func testUnavailableProductKeepsFreeRoute() async throws {
        let model = makeModel(storefront: StoreKitMembershipStorefront())
        defer { model.stop() }
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await model.loadOffer()
        XCTAssertNil(model.offer)
        XCTAssertFalse(model.canPurchase)
        XCTAssertEqual(model.notice, .failed(.unavailable))
        assertFree(model)
    }

    func testRenewalKeepsOriginalPurchaseAndNoLocalUnlock() async throws {
        let original = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        try session.forceRenewalOfSubscription(productIdentifier: productID)
        try await eventually("Renewal creates another transaction") {
            self.session.allTransactions().contains { $0.identifier != UInt(original.id) }
        }
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        try await eventually("The renewed transaction retains the original purchase identity") {
            await storefront.currentTransactions().contains {
                guard case .verified(let transaction) = $0 else { return false }
                return transaction.originalTransactionID == String(original.originalID)
                    && transaction.transactionID != String(original.id)
            }
        }
        await model.refresh()
        assertFree(model)
    }

    func testExpirationRemovesCurrentEntitlementAndPreservesFree() async throws {
        _ = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        try session.expireSubscription(productIdentifier: productID)
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        try await eventually("Expired product has no current entitlement") { await storefront.currentTransactions().isEmpty }
        await model.refresh()
        assertFree(model)
    }

    func testRefundRevokesTransactionAndPreservesFree() async throws {
        let purchased = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        try session.refundTransaction(identifier: UInt(purchased.id))
        try await eventually("Refund records the revocation") {
            guard let result = await StoreKit.Transaction.latest(for: self.productID), case .verified(let transaction) = result else { return false }
            return transaction.revocationDate != nil
        }
        let (storefront, model) = try await loadedModel()
        defer { model.stop() }
        let current = await storefront.currentTransactions()
        XCTAssertTrue(current.isEmpty)
        await model.refresh()
        assertFree(model)
    }

    func testBillingRetryWithoutGraceDoesNotGrantPaidAccess() async throws {
        try await checkBillingFailure(graceEnabled: false, expected: .inBillingRetryPeriod)
    }

    func testBillingGraceStillRequiresServiceVerification() async throws {
        try await checkBillingFailure(graceEnabled: true, expected: .inGracePeriod)
    }

    private func checkBillingFailure(graceEnabled: Bool, expected: Product.SubscriptionInfo.RenewalState) async throws {
        session.billingGracePeriodIsEnabled = graceEnabled
        _ = try await session.buyProduct(identifier: productID, options: [.appAccountToken(accountToken)])
        session.shouldEnterBillingRetryOnRenewal = true
        try session.forceRenewalOfSubscription(productIdentifier: productID)
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        try await eventually("Configured billing failure reaches the expected StoreKit state") {
            try await subscription.status.contains { $0.state == expected }
        }
        let (_, model) = try await loadedModel()
        defer { model.stop() }
        await model.refresh()
        assertFree(model)
    }

    private func loadedModel() async throws -> (StoreKitMembershipStorefront, MembershipModel) {
        let storefront = StoreKitMembershipStorefront()
        let model = makeModel(storefront: storefront)
        await model.start() // Production coordinator starts observation before the user can purchase.
        await Task.yield() // Let the observer enter Transaction.updates before initiating a purchase.
        _ = try XCTUnwrap(model.offer, "The local fixture must load before checking transaction state")
        return (storefront, model)
    }

    // One forwarding call in the original task for each StoreKit operation.
    // Returning the original update stream avoids adding a consumer/task/retry.
    @MainActor private final class CancellationTracingStorefront: MembershipStorefront {
        private let base = StoreKitMembershipStorefront()
        private let trace: (StaticString) -> Void
        init(trace: @escaping (StaticString) -> Void) { self.trace = trace }

        func load(productID: String) async throws -> MembershipOffer {
            trace("storefront.load.begin")
            defer { trace("storefront.load.end") }
            return try await base.load(productID: productID)
        }
        func purchase(appAccountToken: UUID) async throws -> MembershipPurchaseOutcome {
            trace("storefront.purchase.begin")
            defer { trace("storefront.purchase.end") }
            return try await base.purchase(appAccountToken: appAccountToken)
        }
        func currentTransactions() async -> [MembershipPurchaseOutcome] {
            trace("storefront.current.begin")
            defer { trace("storefront.current.end") }
            return await base.currentTransactions()
        }
        func unfinishedTransactions() async -> [MembershipPurchaseOutcome] {
            trace("storefront.unfinished.begin")
            defer { trace("storefront.unfinished.end") }
            return await base.unfinishedTransactions()
        }
        func updates() -> AsyncStream<MembershipPurchaseOutcome> {
            trace("storefront.updates.begin")
            defer { trace("storefront.updates.end") }
            return base.updates()
        }
        func finish(transactionID: String) async {
            trace("storefront.finish.begin")
            defer { trace("storefront.finish.end") }
            await base.finish(transactionID: transactionID)
        }
        func sync() async throws {
            trace("storefront.sync.begin")
            defer { trace("storefront.sync.end") }
            try await base.sync()
        }
    }

    private final class PurchaseProbe {
        var finished = false
        var task: Task<Void, Never>?
    }
    private func beginPurchase(_ model: MembershipModel) -> PurchaseProbe {
        let probe = PurchaseProbe()
        probe.task = Task { @MainActor [weak probe] in
            await model.purchase()
            probe?.finished = true
        }
        return probe
    }

    private func makeModel(storefront: any MembershipStorefront) -> MembershipModel {
        MembershipModel(configuration: MembershipConfiguration(productID: productID,
            privacyURL: URL(string: "https://example.invalid/privacy"), termsURL: URL(string: "https://example.invalid/terms")),
            context: MembershipContext(purchaserID: "local-test-adult", purchaserName: "Local test adult",
                householdID: "local-test-household", householdName: "Local test household", appAccountToken: accountToken),
            service: UnavailableMembershipService(), storefront: storefront)
    }

    private func assertFree(_ model: MembershipModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.hasPaidAccess, file: file, line: line)
        XCTAssertNil(model.state.snapshot, file: file, line: line)
        XCTAssertTrue(model.state.freeRecordsAndExportAvailable, file: file, line: line)
        XCTAssertTrue(model.state.freeManualPlanningAvailable, file: file, line: line)
        XCTAssertFalse(model.state.grantsShopperAuthority, file: file, line: line)
        XCTAssertFalse(model.canManageSeats, file: file, line: line)
    }

    private func verified(_ outcome: MembershipPurchaseOutcome) throws -> SignedMembershipTransaction {
        if case .verified(let transaction) = outcome { return transaction }
        XCTFail("Expected a verified local StoreKit transaction")
        throw ScenarioFailure.unexpectedPurchase
    }
    private func id(_ outcome: MembershipPurchaseOutcome) -> String? {
        if case .verified(let transaction) = outcome { return transaction.transactionID }; return nil
    }
    private func eventually(_ description: String, timeout: Duration = .seconds(10), condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTFail(description)
        throw ScenarioFailure.timeout
    }
    private enum ScenarioFailure: Error { case unexpectedPurchase, timeout }
}
