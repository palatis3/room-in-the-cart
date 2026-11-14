import XCTest
import Combine
@testable import RoomInTheCart

@MainActor final class MembershipTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let context = MembershipContext(purchaserID: "adult-one", purchaserName: "Mia", householdID: "household-one", householdName: "Home", appAccountToken: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)

    func snapshot(status: MembershipStatus = .active, revision: Int = 1, household: String = "household-one", seats: [MembershipSeat]? = nil) -> MembershipSnapshot {
        MembershipSnapshot(householdID: household, purchaserID: context.purchaserID, revision: revision, status: status,
            expiresAt: status == .grace ? now.addingTimeInterval(-60) : now.addingTimeInterval(3600),
            graceExpiresAt: status == .grace ? now.addingTimeInterval(600) : nil,
            verifiedAt: now.addingTimeInterval(-10), validUntil: now.addingTimeInterval(900),
            seats: seats ?? [MembershipSeat(userID: "adult-one", displayName: "Mia", isAdult: true)])
    }

    func transaction(id: String = "1001", token: UUID? = nil) -> SignedMembershipTransaction {
        .init(transactionID: id, originalTransactionID: "1000", productID: "test.household.annual", signedTransactionInfo: "test-only-jws", appAccountToken: token)
    }

    private func makeModel(_ service: FakeMembershipService, _ store: FakeMembershipStorefront) -> MembershipModel {
        MembershipModel(configuration: .init(productID: "test.household.annual", privacyURL: URL(string: "https://example.test/privacy"), termsURL: URL(string: "https://example.test/terms")),
            context: context, service: service, storefront: store, clock: { self.now })
    }

    func testOffDeviceTransactionArrivingDuringOfferLoadAttemptsDelivery() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        service.submissionError = .deliveryPending
        let store = FakeMembershipStorefront()
        store.keepsUpdatesOpen = true
        let purchase = transaction(token: context.appAccountToken)
        store.onLoad = { [weak store] in store?.emit(.verified(purchase)) }
        let model = makeModel(service, store)
        defer { model.stop() }

        await model.start()
        await settle { model.deliveryOutcomes[purchase.transactionID] == .failed(.deliveryPending) }
        XCTAssertEqual(service.submissions, 1)
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertFalse(model.hasPaidAccess)
    }

    func testLatePendingAndVerifiedDeliveryFailureRemainSimultaneouslyVisible() async {
        for issue: MembershipFailure in [.notConfigured, .deliveryPending] {
            let service = FakeMembershipService(snapshot: snapshot(status: .free)); service.error = issue
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
            let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.start()
            let purchase = await pausedPurchase(model, store)
            store.emit(.verified(transaction(id: "approved-B", token: context.appAccountToken)))
            await settle { model.deliveryOutcomes["approved-B"] == .failed(issue) }
            store.resolvePurchase(.pending); await purchase.value
            XCTAssertEqual(model.purchaseReport, .pending)
            XCTAssertEqual(model.deliveryOutcomes["approved-B"], .failed(issue))
            XCTAssertTrue(model.statusMessages.contains(.pendingReport))
            XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(issue)))
            XCTAssertFalse(model.hasPaidAccess); XCTAssertFalse(model.isBusy)
            XCTAssertEqual(service.submissions, 1); XCTAssertTrue(store.finished.isEmpty)
            XCTAssertEqual(model.canPurchase, issue != .deliveryPending,
                           "Structured deliveryPending blocks Subscribe even after notice becomes pending")
            assertNeutralProjection(model)
        }
    }

    func testLatePendingDoesNotDenyAccessEstablishedByDurableVerifiedDelivery() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.start()
        let purchase = await pausedPurchase(model, store)
        service.snapshot = snapshot(revision: 2)
        store.onFinish = { XCTAssertTrue(service.didCommit) }
        store.emit(.verified(transaction(id: "verified-A", token: context.appAccountToken)))
        await settle { model.deliveryOutcomes["verified-A"] == .delivered }
        store.resolvePurchase(.pending); await purchase.value
        XCTAssertEqual(model.purchaseReport, .pending)
        XCTAssertEqual(model.deliveryOutcomes["verified-A"], .delivered)
        XCTAssertTrue(model.hasPaidAccess)
        XCTAssertTrue(model.statusMessages.contains(.pendingReport)); XCTAssertTrue(model.statusMessages.contains(.deliverySaved))
        XCTAssertEqual(service.submissions, 1); XCTAssertEqual(store.finished, ["verified-A"])
        assertNeutralProjection(model)
    }

    func testOlderSameAccountTransactionDoesNotResolveDifferentPendingRequest() async {
        let cases: [MembershipModel.DeliveryOutcome] = [.failed(.deliveryPending), .delivered, .inFlight]
        for expected in cases {
            let service = FakeMembershipService(snapshot: snapshot(status: .free))
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
            let model = makeModel(service, store)
            defer {
                store.resolvePurchase(.cancelled)
                service.continuation?.resume(); service.continuation = nil
                model.stop()
            }
            await model.start()
            let purchaseB = await pausedPurchase(model, store)
            switch expected {
            case .failed(let issue): service.submissionError = issue
            case .inFlight: service.pauseSubmission = true
            case .delivered: break
            }
            // A is not B: neither the pending return nor product/account equality
            // supplies an identity link to this older transaction update.
            store.emit(.verified(transaction(id: "older-A", token: context.appAccountToken)))
            await settle { model.deliveryOutcomes["older-A"] == expected }
            store.resolvePurchase(.pending); await purchaseB.value
            XCTAssertEqual(model.purchaseReport, .pending)
            XCTAssertEqual(model.deliveryOutcomes["older-A"], expected)
            XCTAssertTrue(model.statusMessages.contains(.pendingReport))
            switch expected {
            case .failed(let issue):
                XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(issue)))
                XCTAssertFalse(model.canPurchase)
            case .delivered: XCTAssertTrue(model.statusMessages.contains(.deliverySaved))
            case .inFlight:
                XCTAssertTrue(model.statusMessages.contains(.deliveryInFlight))
                XCTAssertFalse(model.canPurchase)
                let continuation = service.continuation; service.continuation = nil; continuation?.resume()
                await settle { model.deliveryOutcomes["older-A"] == .delivered }
            }
            XCTAssertEqual(model.purchaseReport, .pending, "Delivery of A cannot resolve B's unidentified report")
            XCTAssertFalse(model.hasPaidAccess)
            XCTAssertEqual(service.submissions, 1)
            if case .failed = expected { XCTAssertTrue(store.finished.isEmpty) }
            else { XCTAssertEqual(store.finished, ["older-A"]) }
            assertNeutralProjection(model)
        }
    }

    func testPriorDeliveryFailureSurvivesNewPendingAttemptWithoutBecomingItsOutcome() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free)); service.submissionError = .notConfigured
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.start()
        store.emit(.verified(transaction(id: "prior-A", token: context.appAccountToken)))
        await settle { model.deliveryOutcomes["prior-A"] == .failed(.notConfigured) }
        let purchaseB = await pausedPurchase(model, store)
        XCTAssertEqual(model.purchaseReport, .awaitingResult)
        XCTAssertEqual(model.deliveryOutcomes["prior-A"], .failed(.notConfigured))
        store.resolvePurchase(.pending); await purchaseB.value
        XCTAssertEqual(model.purchaseReport, .pending)
        XCTAssertTrue(model.statusMessages.contains(.pendingReport))
        XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.notConfigured)))
        XCTAssertEqual(service.submissions, 1); XCTAssertTrue(store.finished.isEmpty)
    }

    func testPendingFirstThenVerifiedFailureKeepsBothObservations() async {
        for issue: MembershipFailure in [.notConfigured, .deliveryPending] {
            let service = FakeMembershipService(snapshot: snapshot(status: .free)); service.submissionError = issue
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
            let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.start()
            let purchase = await pausedPurchase(model, store)
            store.resolvePurchase(.pending); await purchase.value
            XCTAssertEqual(model.purchaseReport, .pending); XCTAssertTrue(model.deliveryOutcomes.isEmpty)
            store.emit(.verified(transaction(id: "approved-B", token: context.appAccountToken)))
            await settle { model.deliveryOutcomes["approved-B"] == .failed(issue) }
            XCTAssertEqual(model.purchaseReport, .pending)
            XCTAssertTrue(model.statusMessages.contains(.pendingReport))
            XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(issue)))
            XCTAssertEqual(model.canPurchase, issue != .deliveryPending)
            XCTAssertFalse(model.hasPaidAccess); XCTAssertTrue(store.finished.isEmpty)
        }
    }

    func testUnrelatedRejectedAndUnverifiedCallbacksCannotClearPurchaseOrAdmittedDeliveryEvidence() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.start()
        let purchase = await pausedPurchase(model, store)
        service.snapshot = snapshot(revision: 2)
        store.emit(.verified(transaction(id: "verified-A", token: context.appAccountToken)))
        await settle { model.deliveryOutcomes["verified-A"] == .delivered }
        store.resolvePurchase(.pending); await purchase.value
        let outcomes = model.deliveryOutcomes
        let wrongProduct = SignedMembershipTransaction(transactionID: "wrong-product", originalTransactionID: "0",
            productID: "other.product", signedTransactionInfo: "test-only-jws", appAccountToken: context.appAccountToken)
        let rejected: [MembershipPurchaseOutcome] = [.verified(wrongProduct), .verified(transaction(id: "wrong-account", token: UUID())), .unverified]
        for outcome in rejected {
            await model.receive(outcome)
            XCTAssertEqual(model.purchaseReport, .pending)
            XCTAssertEqual(model.deliveryOutcomes, outcomes)
            XCTAssertTrue(model.hasPaidAccess)
            XCTAssertTrue(model.statusMessages.contains(.pendingReport)); XCTAssertTrue(model.statusMessages.contains(.deliverySaved))
            XCTAssertEqual(service.submissions, 1); XCTAssertEqual(store.finished, ["verified-A"])
            assertNeutralProjection(model)
        }
    }

    func testPerTransactionRetryUpdatesOnlyThatTransactionAndPreservesOtherFailures() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        defer { service.continuation?.resume(); service.continuation = nil; model.stop() }
        await model.loadOffer(); await model.purchase()
        service.submissionError = .notConfigured
        await model.receive(.verified(transaction(id: "retry-A", token: context.appAccountToken)))
        service.submissionError = .deliveryPending
        await model.receive(.verified(transaction(id: "waiting-B", token: context.appAccountToken)))
        service.submissionError = nil; service.pauseSubmission = true
        let retry = Task { await model.receive(.verified(transaction(id: "retry-A", token: context.appAccountToken))) }
        await settle { service.continuation != nil }
        XCTAssertEqual(model.deliveryOutcomes["retry-A"], .inFlight)
        XCTAssertEqual(model.deliveryOutcomes["waiting-B"], .failed(.deliveryPending))
        XCTAssertEqual(model.purchaseReport, .pending)
        let continuation = service.continuation; service.continuation = nil; continuation?.resume()
        _ = await retry.value
        XCTAssertEqual(model.deliveryOutcomes["retry-A"], .delivered)
        XCTAssertEqual(model.deliveryOutcomes["waiting-B"], .failed(.deliveryPending))
        XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.deliveryPending)))
        XCTAssertEqual(service.submissions, 3); XCTAssertEqual(store.finished, ["retry-A"])
        XCTAssertEqual(model.notice, .delivered)
        XCTAssertFalse(model.canPurchase, "Another transaction's success cannot unlock unresolved waiting-B")
        // Preserve the existing purchase policy: an unfinished transaction is
        // retried before asking Apple for a new purchase, independent of notice.
        store.unfinished = [.verified(transaction(id: "waiting-B", token: context.appAccountToken))]
        service.pauseSubmission = false; service.submissionError = .deliveryPending
        await model.purchase()
        XCTAssertEqual(store.purchaseCount, 1); XCTAssertEqual(service.submissions, 4)
        XCTAssertEqual(store.finished, ["retry-A"])
    }

    func testPurchaseReportResetsOnlyAtNewActualAttemptOrStopNotRefreshOrRestore() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.loadOffer(); await model.purchase()
        XCTAssertEqual(model.purchaseReport, .pending)
        await model.refresh(); XCTAssertEqual(model.purchaseReport, .pending)
        await model.restore(); XCTAssertEqual(model.purchaseReport, .pending)
        let next = await pausedPurchase(model, store)
        XCTAssertEqual(model.purchaseReport, .awaitingResult)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.statusMessages.contains(.pendingReport))
        XCTAssertFalse(model.statusMessages.contains(.otherNotice(.pending)))
        store.resolvePurchase(.cancelled); await next.value
        XCTAssertEqual(model.purchaseReport, .cancelled)
        XCTAssertTrue(model.statusMessages.contains(.cancelledReport))
        model.stop()
        XCTAssertNil(model.purchaseReport); XCTAssertTrue(model.deliveryOutcomes.isEmpty); XCTAssertTrue(model.callbackRejections.isEmpty); XCTAssertTrue(model.statusMessages.isEmpty)
    }

    func testAllUnresolvedDeliveryPendingTransactionsGateSubscribeUntilExactRecovery() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free)); service.submissionError = .deliveryPending
        let store = FakeMembershipStorefront(); let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.loadOffer()
        let a = transaction(id: "unresolved-A", token: context.appAccountToken)
        let b = transaction(id: "unresolved-B", token: context.appAccountToken)
        await model.receive(.verified(a)); await model.receive(.verified(b))
        XCTAssertFalse(model.canPurchase)
        XCTAssertEqual(service.submissions, 2); XCTAssertTrue(store.finished.isEmpty)
        service.submissionError = nil
        store.onFinish = { XCTAssertTrue(service.didCommit) }
        store.unfinished = [.verified(a)]
        await model.purchase() // Retry unfinished A even though Subscribe is gated.
        XCTAssertEqual(model.deliveryOutcomes["unresolved-A"], .delivered)
        XCTAssertEqual(model.deliveryOutcomes["unresolved-B"], .failed(.deliveryPending))
        XCTAssertEqual(model.notice, .delivered)
        XCTAssertFalse(model.canPurchase, "Recovering A must not clear B's unresolved delivery")
        XCTAssertEqual(store.purchaseCount, 0); XCTAssertEqual(store.finished, ["unresolved-A"])
        store.unfinished = [.verified(b)]
        await model.purchase() // Exact B recovery removes the final independent gate.
        XCTAssertEqual(model.deliveryOutcomes["unresolved-B"], .delivered)
        XCTAssertTrue(model.canPurchase)
        XCTAssertEqual(service.submissions, 4); XCTAssertEqual(store.purchaseCount, 0)
        XCTAssertEqual(store.finished, ["unresolved-A", "unresolved-B"])
        store.unfinished = [] // Model the completed StoreKit unfinished queue.
        let fresh = await pausedPurchase(model, store)
        XCTAssertEqual(store.purchaseCount, 1)
        XCTAssertEqual(model.purchaseReport, .awaitingResult)
        store.resolvePurchase(.pending); await fresh.value
        XCTAssertTrue(model.canPurchase, "An ordinary pending report does not invent a delivery failure")
    }

    func testNewActualAttemptClearsOldOperationCopyButRetainsStructuredDeliveryErrors() async {
        let cases: [(MembershipPurchaseOutcome, MembershipFailure?)] = [
            (.pending, nil), (.cancelled, nil), (.pending, .unavailable),
        ]
        for (oldOutcome, oldError) in cases {
            let service = FakeMembershipService(snapshot: snapshot(status: .free)); service.submissionError = .notConfigured
            let store = FakeMembershipStorefront(); let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.loadOffer()
            await model.receive(.verified(transaction(id: "prior-failed-A", token: context.appAccountToken)))
            store.purchaseError = oldError
            let prior = await pausedPurchase(model, store)
            store.resolvePurchase(oldOutcome); await prior.value
            if let oldError { XCTAssertEqual(model.notice, .failed(oldError)) }
            else if case .pending = oldOutcome { XCTAssertEqual(model.notice, .pending) }
            else { XCTAssertEqual(model.notice, .cancelled) }
            store.purchaseError = nil
            let fresh = await pausedPurchase(model, store)
            XCTAssertEqual(model.purchaseReport, .awaitingResult); XCTAssertNil(model.notice)
            XCTAssertEqual(model.deliveryOutcomes["prior-failed-A"], .failed(.notConfigured))
            XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.notConfigured)))
            let rendered = model.statusMessages.map(membershipStatusMessageText).joined(separator: "\n")
            XCTAssertFalse(rendered.contains(membershipStatusMessageText(.pendingReport)))
            XCTAssertFalse(rendered.contains(membershipStatusMessageText(.cancelledReport)))
            XCTAssertFalse(rendered.contains(membershipNoticeText(.failed(.unavailable))))
            XCTAssertTrue(rendered.contains(membershipStatusMessageText(.deliveryFailure(.notConfigured))))
            store.resolvePurchase(.cancelled); await fresh.value
        }
    }

    func testDeliveryHistoryAndUnresolvedFailureSurviveGenericRefreshRestoreAndRevocation() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront(); let model = makeModel(service, store)
        defer { model.stop() }
        await model.loadOffer(); await model.purchase()
        await model.receive(.verified(transaction(id: "current-ack-A", token: context.appAccountToken)))
        XCTAssertTrue(model.hasPaidAccess)
        service.submissionError = .deliveryPending
        await model.receive(.verified(transaction(id: "unresolved-B", token: context.appAccountToken)))
        let history = model.deliveryOutcomes
        XCTAssertEqual(history["current-ack-A"], .delivered)
        XCTAssertEqual(history["unresolved-B"], .failed(.deliveryPending))
        XCTAssertTrue(model.hasPaidAccess, "A delivery failure does not invent revocation of an authoritative active lease")
        service.submissionError = nil
        store.current = []; store.unfinished = [] // These refreshes perform no same-transaction retry.
        service.snapshot = snapshot(status: .expired, revision: 2)
        await model.refresh()
        XCTAssertFalse(model.hasPaidAccess); XCTAssertEqual(model.deliveryOutcomes, history)
        XCTAssertFalse(model.canPurchase, "An expired projection cannot erase unresolved B")
        await model.restore()
        XCTAssertFalse(model.hasPaidAccess); XCTAssertEqual(model.deliveryOutcomes, history)
        XCTAssertEqual(model.purchaseReport, .pending); XCTAssertEqual(store.syncCount, 1)
        service.snapshot = snapshot(status: .revoked, revision: 3)
        await model.refresh()
        XCTAssertFalse(model.hasPaidAccess); XCTAssertEqual(model.deliveryOutcomes, history)
        service.snapshot = snapshot(revision: 4)
        await model.refresh()
        XCTAssertTrue(model.hasPaidAccess); XCTAssertEqual(model.deliveryOutcomes, history)
        XCTAssertTrue(model.statusMessages.contains(.deliverySaved))
        XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.deliveryPending)))
        XCTAssertEqual(membershipStatusMessageText(.deliverySaved),
            mtr("An App Store transaction was saved by your household service. Current membership access is shown above."))
        XCTAssertFalse(membershipStatusMessageText(.deliverySaved).contains(mtr("Household access is active")))
        XCTAssertEqual(service.submissions, 2); XCTAssertEqual(store.finished, ["current-ack-A"])
    }

    func testHistoricalDeliveryAcknowledgementDoesNotExtendActualSubscriptionExpiry() async {
        var time = now
        let current = snapshot()
        let shortTerm = MembershipSnapshot(householdID: current.householdID, purchaserID: current.purchaserID,
            revision: current.revision, status: .active, expiresAt: now.addingTimeInterval(60), graceExpiresAt: nil,
            verifiedAt: current.verifiedAt, validUntil: current.validUntil, seats: current.seats)
        let service = FakeMembershipService(snapshot: shortTerm), store = FakeMembershipStorefront()
        let model = MembershipModel(configuration: .init(productID: "test.household.annual",
            privacyURL: URL(string: "https://example.test/privacy"), termsURL: URL(string: "https://example.test/terms")),
            context: context, service: service, storefront: store, clock: { time })
        defer { model.stop() }
        await model.receive(.verified(transaction(id: "historic-ack", token: context.appAccountToken)))
        XCTAssertTrue(model.hasPaidAccess)
        time = now.addingTimeInterval(61)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.deliveryOutcomes["historic-ack"], .delivered)
        XCTAssertTrue(model.statusMessages.contains(.deliverySaved))
        XCTAssertEqual(membershipStatusMessageText(.deliverySaved),
            mtr("An App Store transaction was saved by your household service. Current membership access is shown above."))
        XCTAssertEqual(service.submissions, 1); XCTAssertEqual(store.finished, ["historic-ack"])
    }

    func testEquivalentDeliveryFailuresRenderOnceWithoutErasingTransactionEvidence() async {
        let pairs: [(MembershipFailure, MembershipFailure)] = [
            (.invalidReceipt, .serverRejected), (.unverified, .invalidSnapshot),
            (.wrongHousehold, .accountMismatch),
        ]
        for (first, second) in pairs {
            for issues in [[first, second], [second, first]] {
                let service = FakeMembershipService(snapshot: snapshot(status: .free))
                let store = FakeMembershipStorefront(); let model = makeModel(service, store)
                defer { model.stop() }
                await model.loadOffer(); await model.purchase()
                for (index, issue) in issues.enumerated() {
                    service.submissionError = issue
                    await model.receive(.verified(transaction(id: "delivery-\(index)", token: context.appAccountToken)))
                }
                let expectedText = membershipStatusMessageText(.deliveryFailure(first))
                XCTAssertEqual(expectedText, membershipStatusMessageText(.deliveryFailure(second)))
                XCTAssertEqual(model.statusMessages.map(membershipStatusMessageText).filter { $0 == expectedText }.count, 1)
                XCTAssertEqual(model.deliveryOutcomes, ["delivery-0": .failed(issues[0]), "delivery-1": .failed(issues[1])])
                XCTAssertTrue(store.finished.isEmpty)
                XCTAssertTrue(model.statusMessages.contains(.pendingReport))
                let stableID = MembershipModel.StatusMessage.deliveryFailure(first).id
                XCTAssertEqual(model.statusMessages.filter { $0.id == stableID }.count, 1)

                // An unrelated delivery gate and rejected callback remain
                // distinct from the coalesced delivery instruction.
                service.submissionError = .deliveryPending
                await model.receive(.verified(transaction(id: "pending-delivery", token: context.appAccountToken)))
                await model.receive(.unverified)
                XCTAssertFalse(model.canPurchase)
                XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.deliveryPending)))
                XCTAssertTrue(model.statusMessages.contains(.callbackRejection(.unverified)))
                XCTAssertTrue(model.statusMessages.contains(.pendingReport))

                // Recovering one transaction must leave the other's instruction
                // in place with the same identity and must not clear the gate.
                service.submissionError = nil
                await model.receive(.verified(transaction(id: "delivery-0", token: context.appAccountToken)))
                XCTAssertEqual(model.deliveryOutcomes["delivery-0"], .delivered)
                XCTAssertEqual(model.deliveryOutcomes["delivery-1"], .failed(issues[1]))
                XCTAssertEqual(model.deliveryOutcomes["pending-delivery"], .failed(.deliveryPending))
                XCTAssertEqual(model.statusMessages.filter { $0.id == stableID }.count, 1)
                XCTAssertEqual(model.statusMessages.map(membershipStatusMessageText).filter { $0 == expectedText }.count, 1)
                XCTAssertEqual(store.finished, ["delivery-0"])
                XCTAssertFalse(model.canPurchase)
                XCTAssertFalse(model.hasPaidAccess)
            }
        }
    }

    func testStatusMessagesHaveUniqueStableSemanticIdentityWithoutTransactionIdentity() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); let model = makeModel(service, store)
        defer { service.continuation?.resume(); service.continuation = nil; model.stop() }
        await model.loadOffer(); await model.purchase()
        service.submissionError = .notConfigured
        await model.receive(.verified(transaction(id: "private-transaction-A", token: context.appAccountToken)))
        service.submissionError = nil; service.pauseSubmission = true
        let deliveryB = Task { await model.receive(.verified(transaction(id: "private-transaction-B", token: context.appAccountToken))) }
        await settle { service.continuation != nil }
        service.pauseSubmission = false
        await model.receive(.verified(transaction(id: "private-transaction-C", token: context.appAccountToken)))
        let ids = model.statusMessages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("membership.status.purchase.pending"))
        XCTAssertTrue(ids.contains("membership.status.delivery.failure.not-configured"))
        XCTAssertTrue(ids.contains("membership.status.delivery.in-flight"))
        XCTAssertTrue(ids.contains("membership.status.delivery.saved"))
        let unrelated = SignedMembershipTransaction(transactionID: "private-rejected-ID", originalTransactionID: "0",
            productID: "unrelated.product", signedTransactionInfo: "private-signed-payload", appAccountToken: context.appAccountToken)
        await model.receive(.verified(unrelated))
        let changedIDs = model.statusMessages.map(\.id)
        XCTAssertTrue(Set(ids).isSubset(of: Set(changedIDs)))
        XCTAssertEqual(Set(changedIDs).count, changedIDs.count)
        let rendered = model.statusMessages.map(membershipStatusMessageText).joined(separator: "\n")
        for value in ["private-transaction-A", "private-transaction-B", "private-transaction-C", "private-rejected-ID", "private-signed-payload"] {
            XCTAssertFalse(rendered.contains(value)); XCTAssertFalse(changedIDs.contains { $0.contains(value) })
        }
        let continuation = service.continuation; service.continuation = nil; continuation?.resume()
        _ = await deliveryB.value
        XCTAssertFalse(model.statusMessages.map(\.id).contains("membership.status.delivery.in-flight"))
        XCTAssertTrue(model.statusMessages.map(\.id).contains("membership.status.delivery.saved"))
        XCTAssertTrue(model.statusMessages.map(\.id).contains("membership.status.delivery.failure.not-configured"))
        XCTAssertEqual(service.submissions, 3); XCTAssertEqual(store.finished, ["private-transaction-C", "private-transaction-B"])
    }

    func testRejectedCallbackHistorySurvivesActualPendingAndCancelledPurchases() async {
        let wrongProduct = SignedMembershipTransaction(transactionID: "rejected-callback-A", originalTransactionID: "0",
            productID: "unrelated.product", signedTransactionInfo: "private-callback-jws", appAccountToken: context.appAccountToken)
        let rejected: [(MembershipPurchaseOutcome, MembershipFailure)] = [
            (.verified(wrongProduct), .unverified),
            (.verified(transaction(id: "rejected-callback-A", token: UUID())), .accountMismatch),
            (.unverified, .unverified),
        ]
        let returned: [MembershipPurchaseOutcome] = [.pending, .cancelled]
        for (callbackA, issue) in rejected {
            for outcomeB in returned {
                let service = FakeMembershipService(snapshot: snapshot(status: .free))
                let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
                let model = makeModel(service, store)
                defer { store.resolvePurchase(.cancelled); model.stop() }
                await model.start()
                store.emit(callbackA)
                await settle { model.callbackRejections.contains(issue) }
                XCTAssertNil(model.purchaseReport); XCTAssertTrue(model.deliveryOutcomes.isEmpty)
                let purchaseB = await pausedPurchase(model, store)
                XCTAssertNil(model.notice); XCTAssertEqual(model.purchaseReport, .awaitingResult)
                XCTAssertEqual(model.statusMessages, [.callbackRejection(issue)])
                XCTAssertFalse(model.statusMessages.contains(.deliveryFailure(issue)))
                store.resolvePurchase(outcomeB); await purchaseB.value
                switch outcomeB {
                case .pending:
                    XCTAssertEqual(model.purchaseReport, .pending); XCTAssertTrue(model.statusMessages.contains(.pendingReport))
                case .cancelled:
                    XCTAssertEqual(model.purchaseReport, .cancelled); XCTAssertTrue(model.statusMessages.contains(.cancelledReport))
                default: XCTFail("Unexpected test outcome")
                }
                XCTAssertEqual(model.callbackRejections, [issue])
                XCTAssertTrue(model.statusMessages.contains(.callbackRejection(issue)))
                XCTAssertFalse(model.statusMessages.contains(.purchaseFailure(issue)))
                XCTAssertTrue(model.deliveryOutcomes.isEmpty)
                XCTAssertTrue(model.canPurchase, "A rejected callback is not an admitted deliveryPending gate")
                XCTAssertFalse(model.hasPaidAccess); XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty)
                let historyText = membershipStatusMessageText(.callbackRejection(issue))
                let expectedHistory = issue == .accountMismatch
                    ? mtr("An earlier App Store update did not match this account or household. Use its purchasing account to restore it. Current membership access is shown above.")
                    : mtr("An earlier App Store update could not be verified. Use Restore Purchases or contact support. Current membership access is shown above.")
                XCTAssertEqual(historyText, expectedHistory)
                let rendered = model.statusMessages.map(membershipStatusMessageText).joined(separator: "\n")
                XCTAssertTrue(rendered.contains(historyText))
                let ids = model.statusMessages.map(\.id)
                XCTAssertEqual(ids.count, Set(ids).count)
                for privateValue in ["rejected-callback-A", "private-callback-jws", context.appAccountToken!.uuidString] {
                    XCTAssertFalse(rendered.contains(privateValue)); XCTAssertFalse(ids.contains { $0.contains(privateValue) })
                }
                await model.refresh(); await model.restore()
                XCTAssertEqual(model.callbackRejections, [issue])
                await model.receive(callbackA) // Repeat observations coalesce; they are not new purchase outcomes.
                XCTAssertEqual(model.callbackRejections, [issue])
                model.stop()
                await model.receive(callbackA)
                XCTAssertTrue(model.callbackRejections.isEmpty); XCTAssertTrue(model.statusMessages.isEmpty)
            }
        }
    }

    func testActualNewAttemptClearsOnlyPurchaseOwnedVerificationAndErrorEvidence() async {
        let wrongProduct = SignedMembershipTransaction(transactionID: "purchase-owned-B", originalTransactionID: "0",
            productID: "unrelated.product", signedTransactionInfo: "private-purchase-jws", appAccountToken: context.appAccountToken)
        let cases: [(MembershipPurchaseOutcome, MembershipFailure?)] = [
            (.unverified, nil), (.verified(wrongProduct), nil), (.pending, .unavailable),
        ]
        for (ownOutcome, purchaseError) in cases {
            let service = FakeMembershipService(snapshot: snapshot(status: .free))
            let store = FakeMembershipStorefront(); let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.loadOffer()
            await model.receive(.verified(transaction(id: "independent-A", token: UUID())))
            XCTAssertEqual(model.callbackRejections, [.accountMismatch])
            store.purchaseError = purchaseError
            let ownedB = await pausedPurchase(model, store)
            store.resolvePurchase(ownOutcome); await ownedB.value
            XCTAssertEqual(model.callbackRejections, [.accountMismatch], "Purchase-owned failures cannot duplicate independent callback history")
            XCTAssertTrue(model.deliveryOutcomes.isEmpty)
            if let purchaseError { XCTAssertTrue(model.statusMessages.contains(.purchaseFailure(purchaseError))) }
            else if case .unverified = ownOutcome {
                XCTAssertTrue(model.statusMessages.contains(.unverifiedReport))
                XCTAssertFalse(model.statusMessages.contains(.purchaseFailure(.unverified)), "Do not duplicate purchase-owned unverified evidence")
            } else { XCTAssertTrue(model.statusMessages.contains(.purchaseFailure(.unverified))) }
            store.purchaseError = nil
            let freshC = await pausedPurchase(model, store)
            XCTAssertNil(model.notice); XCTAssertEqual(model.purchaseReport, .awaitingResult)
            XCTAssertEqual(model.statusMessages, [.callbackRejection(.accountMismatch)])
            let rendered = model.statusMessages.map(membershipStatusMessageText).joined(separator: "\n")
            XCTAssertFalse(rendered.contains(membershipNoticeText(.failed(.unverified))))
            XCTAssertFalse(rendered.contains(membershipNoticeText(.failed(.unavailable))))
            XCTAssertTrue(rendered.contains(membershipStatusMessageText(.callbackRejection(.accountMismatch))))
            store.resolvePurchase(.pending); await freshC.value
            XCTAssertEqual(model.purchaseReport, .pending)
            XCTAssertEqual(model.callbackRejections, [.accountMismatch])
            XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty)
        }
    }

    func testSameReasonHistoricalCallbackAndOwnedRejectionRemainDistinctWithoutDuplication() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.loadOffer()
        await model.receive(.verified(transaction(id: "callback-A", token: UUID())))
        let purchaseB = await pausedPurchase(model, store)
        store.resolvePurchase(.verified(transaction(id: "purchase-owned-B", token: UUID())))
        await purchaseB.value
        XCTAssertEqual(model.callbackRejections, [.accountMismatch])
        XCTAssertEqual(model.purchaseReport, .verified(transactionID: "purchase-owned-B"))
        XCTAssertTrue(model.statusMessages.contains(.purchaseFailure(.accountMismatch)))
        XCTAssertTrue(model.statusMessages.contains(.callbackRejection(.accountMismatch)))
        let ids = model.statusMessages.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains("membership.status.purchase.failure.account-mismatch"))
        XCTAssertTrue(ids.contains("membership.status.callback.rejection.account-mismatch"))
        XCTAssertTrue(model.deliveryOutcomes.isEmpty)
        let freshC = await pausedPurchase(model, store)
        XCTAssertEqual(model.statusMessages, [.callbackRejection(.accountMismatch)])
        store.resolvePurchase(.pending); await freshC.value
        XCTAssertTrue(model.statusMessages.contains(.pendingReport))
        XCTAssertFalse(model.statusMessages.contains(.purchaseFailure(.accountMismatch)))
        XCTAssertEqual(model.callbackRejections, [.accountMismatch])
        XCTAssertFalse(model.hasPaidAccess); XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty)
    }

    func testOrdinaryPendingCancellationAndPurchaseExceptionKeepExistingPolicies() async {
        let cases: [MembershipPurchaseOutcome] = [.pending, .cancelled]
        for outcome in cases {
            let service = FakeMembershipService(snapshot: snapshot(status: .free))
            let store = FakeMembershipStorefront(); let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.loadOffer()
            let purchase = await pausedPurchase(model, store)
            store.resolvePurchase(outcome); await purchase.value
            switch outcome {
            case .pending: XCTAssertEqual(model.notice, .pending); XCTAssertEqual(model.purchaseReport, .pending)
            case .cancelled: XCTAssertEqual(model.notice, .cancelled); XCTAssertEqual(model.purchaseReport, .cancelled)
            default: XCTFail("Unexpected test outcome")
            }
            XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty); XCTAssertFalse(model.hasPaidAccess)
        }
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.purchaseError = .unavailable
        let model = makeModel(service, store); defer { model.stop() }
        await model.loadOffer(); await model.purchase()
        XCTAssertEqual(model.notice, .failed(.unavailable)); XCTAssertEqual(model.purchaseReport, .failed(.unavailable))
        XCTAssertTrue(model.deliveryOutcomes.isEmpty); XCTAssertFalse(model.hasPaidAccess)
    }

    func testStopDiscardsObservationsAndIgnoresLatePurchaseAndServiceCallbacks() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer {
            store.resolvePurchase(.cancelled)
            service.continuation?.resume(); service.continuation = nil
            model.stop()
        }
        await model.start()
        let purchase = await pausedPurchase(model, store)
        service.pauseSubmission = true
        let delivery = Task { await model.receive(.verified(transaction(id: "in-flight-A", token: context.appAccountToken))) }
        await settle { service.continuation != nil }
        XCTAssertEqual(model.deliveryOutcomes["in-flight-A"], .inFlight)
        model.stop()
        store.resolvePurchase(.pending); await purchase.value
        let continuation = service.continuation; service.continuation = nil; continuation?.resume()
        _ = await delivery.value
        XCTAssertNil(model.purchaseReport); XCTAssertTrue(model.deliveryOutcomes.isEmpty); XCTAssertTrue(model.callbackRejections.isEmpty); XCTAssertNil(model.notice)
        XCTAssertTrue(model.statusMessages.isEmpty); XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(service.submissions, 1); XCTAssertTrue(store.finished.isEmpty)
    }

    private func pausedPurchase(_ model: MembershipModel, _ store: FakeMembershipStorefront) async -> Task<Void, Never> {
        store.pausePurchase = true
        let task = Task { await model.purchase() }
        await settle { store.purchaseContinuation != nil }
        return task
    }
    private func assertNeutralProjection(_ model: MembershipModel, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = model.statusMessages.map(membershipStatusMessageText).joined(separator: "\n")
        XCTAssertTrue(rendered.contains(mtr("Apple reported a pending purchase status. Use Restore Purchases to check current membership access.")), file: file, line: line)
        XCTAssertFalse(rendered.contains(mtr("Purchase pending Apple approval. Paid access has not been added.")), file: file, line: line)
        XCTAssertFalse(rendered.contains(mtr("The purchase could not be verified. Paid access has not been added. Try Restore Purchases or contact support.")), file: file, line: line)
        for privateValue in ["test-only-jws", "approved-B", "verified-A", "older-A", "wrong-product", "wrong-account", context.purchaserID, context.householdID, context.appAccountToken!.uuidString] {
            XCTAssertFalse(rendered.contains(privateValue), "No raw identity or signed payload in status copy", file: file, line: line)
        }
    }

    func testPendingCompletionReconcilesAvailableApprovalWithoutAnUpdateEvent() async {
        for failsDelivery in [true, false] {
            let service = FakeMembershipService(snapshot: snapshot(status: .free))
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
            let model = makeModel(service, store)
            defer { store.resolvePurchase(.cancelled); model.stop() }
            await model.start()
            let purchase = await pausedPurchase(model, store)
            let readsBeforeCompletion = store.unfinishedReads
            XCTAssertEqual(store.activeObservers, 1)
            XCTAssertTrue(model.deliveryOutcomes.isEmpty)
            XCTAssertFalse(model.hasPaidAccess)
            // Approval is available while purchase is suspended, but no update is emitted.
            store.unfinished = [.verified(transaction(id: "approved-B", token: context.appAccountToken))]
            service.snapshot = snapshot(revision: 2)
            service.submissionError = failsDelivery ? .notConfigured : nil
            store.onFinish = { XCTAssertTrue(service.didCommit, "Only durable service acknowledgement permits finish") }
            store.resolvePurchase(.pending); await purchase.value
            XCTAssertEqual(store.unfinishedReads, readsBeforeCompletion + 1, "One reconciliation; no polling")
            XCTAssertEqual(store.purchaseCount, 1); XCTAssertEqual(service.submissions, 1)
            XCTAssertEqual(store.syncCount, 0); XCTAssertEqual(store.observerStarts, 1)
            XCTAssertEqual(model.purchaseReport, .pending, "No transaction is inferred to resolve the pending request")
            XCTAssertTrue(model.statusMessages.contains(.pendingReport))
            if failsDelivery {
                XCTAssertEqual(model.deliveryOutcomes["approved-B"], .failed(.notConfigured))
                XCTAssertTrue(model.statusMessages.contains(.deliveryFailure(.notConfigured)))
                XCTAssertTrue(store.finished.isEmpty); XCTAssertFalse(model.hasPaidAccess)
            } else {
                XCTAssertEqual(model.deliveryOutcomes["approved-B"], .delivered)
                XCTAssertEqual(store.finished, ["approved-B"]); XCTAssertTrue(model.hasPaidAccess)
            }
        }
    }

    func testPendingCompletionReconciliationRejectsAnotherAccount() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer { store.resolvePurchase(.cancelled); model.stop() }
        await model.start()
        let purchase = await pausedPurchase(model, store)
        store.unfinished = [.verified(transaction(id: "wrong-account", token: UUID()))]
        store.resolvePurchase(.pending); await purchase.value
        XCTAssertEqual(model.purchaseReport, .pending)
        XCTAssertEqual(model.callbackRejections, [.accountMismatch])
        XCTAssertTrue(model.deliveryOutcomes.isEmpty)
        XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty)
        XCTAssertFalse(model.hasPaidAccess)
    }

    func testStopDuringPendingReconciliationDiscardsItsLateSnapshot() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let model = makeModel(service, store)
        defer {
            store.resolvePurchase(.cancelled)
            store.unfinishedContinuation?.resume(); store.unfinishedContinuation = nil
            model.stop()
        }
        await model.start()
        let purchase = await pausedPurchase(model, store)
        store.unfinished = [.verified(transaction(id: "approved-B", token: context.appAccountToken))]
        store.pauseUnfinishedRead = true
        store.resolvePurchase(.pending)
        await settle { store.unfinishedContinuation != nil }
        model.stop()
        let continuation = store.unfinishedContinuation; store.unfinishedContinuation = nil
        continuation?.resume(); await purchase.value
        XCTAssertTrue(model.isStopped); XCTAssertNil(model.purchaseReport)
        XCTAssertTrue(model.deliveryOutcomes.isEmpty); XCTAssertTrue(model.callbackRejections.isEmpty)
        XCTAssertEqual(service.submissions, 0); XCTAssertTrue(store.finished.isEmpty)
        XCTAssertFalse(model.hasPaidAccess)
    }

    func testPendingCancellationAndUnverifiedNeverGrantSeatsOrFinish() async {
        for outcome: MembershipPurchaseOutcome in [.pending, .cancelled, .unverified] {
            let service = FakeMembershipService(snapshot: snapshot())
            let store = FakeMembershipStorefront()
            let model = makeModel(service, store)
            await model.receive(outcome)
            XCTAssertFalse(model.hasPaidAccess)
            XCTAssertNil(model.state.snapshot)
            XCTAssertEqual(service.submissions, 0)
            XCTAssertTrue(store.finished.isEmpty)
        }
    }

    func testDurableServiceDeliveryPrecedesFinish() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        store.onFinish = { XCTAssertTrue(service.didCommit) }
        let model = makeModel(service, store)
        await model.receive(.verified(transaction()))
        XCTAssertTrue(model.hasPaidAccess)
        XCTAssertEqual(store.finished, ["1001"])
    }

    func testInterruptedDeliveryRemainsUnfinishedAndRetries() async {
        let service = FakeMembershipService(snapshot: snapshot())
        service.error = .deliveryPending
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        await model.receive(.verified(transaction()))
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertTrue(store.finished.isEmpty)
        service.error = nil
        await model.receive(.verified(transaction()))
        XCTAssertEqual(store.finished, ["1001"])
        XCTAssertTrue(model.hasPaidAccess)
    }

    func testSubscribeRecoversAnUnfinishedPurchaseBeforeAskingAppleForAnother() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        store.unfinished = [.verified(transaction(token: context.appAccountToken))]
        let model = makeModel(service, store)
        await model.loadOffer()

        await model.purchase()

        XCTAssertEqual(store.purchaseCount, 0)
        XCTAssertEqual(service.submissions, 1)
        XCTAssertEqual(store.finished, ["1001"])
        XCTAssertTrue(model.hasPaidAccess)
        XCTAssertFalse(model.canPurchase)
    }

    func testPendingDeliveryKeepsSubscribeClosedUntilRestoreReconciles() async {
        let service = FakeMembershipService(snapshot: snapshot())
        service.error = .deliveryPending
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        let outcome = MembershipPurchaseOutcome.verified(transaction(token: context.appAccountToken))
        await model.loadOffer()
        await model.receive(outcome)

        XCTAssertFalse(model.canPurchase)
        await model.purchase()
        XCTAssertEqual(store.purchaseCount, 0)
        XCTAssertTrue(store.finished.isEmpty)

        service.error = nil
        store.unfinished = [outcome]
        await model.restore()
        XCTAssertEqual(service.submissions, 2)
        XCTAssertEqual(store.finished, ["1001"])
        XCTAssertEqual(model.notice, .restored)
        XCTAssertTrue(model.hasPaidAccess)
    }

    func testNonDurableAndMismatchedAcknowledgmentsNeverFinish() async {
        for badReceipt in [MembershipDeliveryReceipt(acceptedTransactionID: "1001", durable: false, snapshot: snapshot()),
                           MembershipDeliveryReceipt(acceptedTransactionID: "9999", durable: true, snapshot: snapshot())] {
            let service = FakeMembershipService(snapshot: snapshot())
            service.receiptOverride = badReceipt
            let store = FakeMembershipStorefront()
            let model = makeModel(service, store)
            await model.receive(.verified(transaction()))
            XCTAssertFalse(model.hasPaidAccess)
            XCTAssertTrue(store.finished.isEmpty)
        }
    }

    func testWrongHouseholdRestoreCannotGrantOrFinish() async {
        let service = FakeMembershipService(snapshot: snapshot(household: "another-household"))
        let store = FakeMembershipStorefront()
        store.current = [.verified(transaction())]
        let model = makeModel(service, store)
        await model.restore()
        XCTAssertEqual(store.syncCount, 1)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.state.issue, .wrongHousehold)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testMismatchedAccountTokenNeverReachesService() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        await model.receive(.verified(transaction(token: UUID())))
        XCTAssertEqual(service.submissions, 0)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testConcurrentDoubleCallbackCommitsOnlyOnce() async {
        let service = FakeMembershipService(snapshot: snapshot())
        service.pauseSubmission = true
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        let first = Task { await model.receive(.verified(transaction())) }
        await Task.yield()
        while service.continuation == nil { await Task.yield() }
        await model.receive(.verified(transaction()))
        XCTAssertEqual(service.submissions, 1)
        service.continuation?.resume()
        _ = await first.value
        XCTAssertEqual(store.finished, ["1001"])
    }

    func testRefundWinsOverOlderActiveReceiptAndPreservesFreeRights() throws {
        var state = MembershipState()
        try state.accept(snapshot(), context: context, now: now)
        try state.accept(snapshot(status: .revoked, revision: 2), context: context, now: now)
        try state.accept(snapshot(revision: 1), context: context, now: now)
        XCTAssertFalse(state.hasPaidAccess(context: context, now: now))
        XCTAssertEqual(state.snapshot?.status, .revoked)
        XCTAssertTrue(state.freeRecordsAndExportAvailable)
        XCTAssertTrue(state.freeManualPlanningAvailable)
        XCTAssertEqual(state.freeReusableDinnerCount, 1)
    }

    func testVerifiedGraceEndsAtKnownDeadlineAndNoInfiniteOfflineAccess() {
        let grace = snapshot(status: .grace)
        XCTAssertTrue(grace.hasPaidAccess(for: "adult-one", now: now))
        XCTAssertFalse(grace.hasPaidAccess(for: "adult-one", now: now.addingTimeInterval(600)))
        XCTAssertFalse(snapshot().hasPaidAccess(for: "adult-one", now: now.addingTimeInterval(900)))
        XCTAssertFalse(snapshot().hasPaidAccess(for: "adult-one", now: now.addingTimeInterval(-100)))
        for status: MembershipStatus in [.expired, .billingRetry, .revoked, .free] {
            XCTAssertFalse(snapshot(status: status).hasPaidAccess(for: "adult-one", now: now))
        }
    }

    func testNamedAdultSeatsDoNotGrantShopBudgetOrPlanningAuthority() throws {
        var state = MembershipState()
        try state.accept(snapshot(seats: [MembershipSeat(userID: "adult-one", displayName: "Mia", isAdult: true),
            MembershipSeat(userID: "adult-two", displayName: "Sam", isAdult: true)]), context: context, now: now)
        XCTAssertTrue(state.snapshot!.hasPaidAccess(for: "adult-two", now: now))
        XCTAssertFalse(state.snapshot!.hasPaidAccess(for: "unseated", now: now))
        XCTAssertFalse(state.grantsShopperAuthority)
        XCTAssertFalse(state.grantsBudgetAccess)
        XCTAssertFalse(state.grantsHouseholdPlanningPermission)
    }

    func testThirdSeatChildAndDuplicateSeatAreRejected() {
        let adult = MembershipSeat(userID: "adult-one", displayName: "Mia", isAdult: true)
        for seats in [[adult, adult], [MembershipSeat(userID: "child", displayName: "Child", isAdult: false)],
                      [adult, .init(userID: "two", displayName: "Sam", isAdult: true), .init(userID: "three", displayName: "Lee", isAdult: true)]] {
            var state = MembershipState()
            XCTAssertThrowsError(try state.accept(snapshot(seats: seats), context: context, now: now))
            XCTAssertNil(state.snapshot)
        }
    }

    func testEqualRevisionCannotReplaceRefundWithActiveSnapshot() throws {
        var state = MembershipState()
        try state.accept(snapshot(status: .revoked, revision: 2), context: context, now: now)
        XCTAssertThrowsError(try state.accept(snapshot(revision: 2), context: context, now: now))
        XCTAssertFalse(state.hasPaidAccess(context: context, now: now))
    }

    func testStopDuringDeliveryDiscardsLateResultWithoutFinishing() async {
        let service = FakeMembershipService(snapshot: snapshot())
        service.pauseSubmission = true
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        let task = Task { await model.receive(.verified(transaction())) }
        while service.continuation == nil { await Task.yield() }
        model.stop()
        service.continuation?.resume()
        _ = await task.value
        XCTAssertNil(model.state.snapshot)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testStoppedScopeCannotBeReactivatedByQueuedCallback() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        model.stop()
        await model.receive(.verified(transaction()))
        await model.start()
        await model.purchase()
        XCTAssertFalse(model.canPurchase)
        XCTAssertNil(model.state.snapshot)
        XCTAssertEqual(service.submissions, 0)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testRefreshDoesNotPromptAppleSyncAndRestoreDoes() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        await model.refresh()
        XCTAssertEqual(store.syncCount, 0)
        await model.restore()
        XCTAssertEqual(store.syncCount, 1)
        XCTAssertTrue(model.hasPaidAccess)
    }

    func testOfferRetryCoalescesLoadsAndPreservesAnIndependentRestoreFailure() async {
        let store = FakeMembershipStorefront()
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let model = makeModel(service, store)
        await model.restore()
        XCTAssertEqual(model.notice, .failed(.unavailable))
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0
        store.waitDuringLoad = {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { resume = $0 }
                throw MembershipFailure.unavailable
            }
        }

        let initial = Task { await model.loadOffer() }
        await settle { resume != nil }
        XCTAssertTrue(model.isLoadingOffer)
        await model.loadOffer()
        XCTAssertEqual(calls, 1)
        resume?.resume()
        await initial.value
        XCTAssertFalse(model.isLoadingOffer)
        XCTAssertNil(model.offer)

        await model.loadOffer()
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(model.offer)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.statusMessages, [.otherNotice(.failed(.unavailable))])
    }

    func testStorefrontMetadataIsUsedWithoutReplacingLocalizedPrice() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let model = makeModel(service, FakeMembershipStorefront())
        await model.loadOffer()
        XCTAssertEqual(model.offer?.displayPrice, "€51,99")
        XCTAssertEqual(model.offer?.periodValue, 1)
        XCTAssertEqual(model.offer?.periodUnit, .year)
        XCTAssertTrue(model.canPurchase)
    }

    func testSameRevisionMayRefreshVerifiedLeaseButCannotChangeSeats() throws {
        var state = MembershipState()
        let initial = snapshot()
        try state.accept(initial, context: context, now: now)
        let renewed = MembershipSnapshot(householdID: initial.householdID, purchaserID: initial.purchaserID,
            revision: initial.revision, status: initial.status, expiresAt: initial.expiresAt, graceExpiresAt: nil,
            verifiedAt: now, validUntil: now.addingTimeInterval(1200), seats: initial.seats)
        try state.accept(renewed, context: context, now: now)
        XCTAssertEqual(state.snapshot?.validUntil, renewed.validUntil)
        XCTAssertThrowsError(try state.accept(snapshot(seats: []), context: context, now: now))
        XCTAssertEqual(state.snapshot?.seats, initial.seats)
    }

    func testExpiryBoundaryDoesNotWaitForCachedLeaseDeadline() {
        let value = MembershipSnapshot(householdID: context.householdID, purchaserID: context.purchaserID,
            revision: 1, status: .active, expiresAt: now, graceExpiresAt: nil,
            verifiedAt: now.addingTimeInterval(-30), validUntil: now.addingTimeInterval(900),
            seats: [MembershipSeat(userID: context.purchaserID, displayName: "Mia", isAdult: true)])
        XCTAssertFalse(value.hasPaidAccess(for: context.purchaserID, now: now))
    }

    func testSecondNamedAdultRecoversSeatWithoutPurchaserTokenOrAppleSubmission() async {
        let second = MembershipContext(purchaserID: "adult-two", purchaserName: "Sam", householdID: context.householdID,
            householdName: "Home", appAccountToken: nil)
        let seats = [MembershipSeat(userID: context.purchaserID, displayName: "Mia", isAdult: true),
                     MembershipSeat(userID: second.purchaserID, displayName: "Sam", isAdult: true)]
        let service = FakeMembershipService(snapshot: snapshot(seats: seats))
        let store = FakeMembershipStorefront()
        store.current = [.verified(transaction(token: context.appAccountToken))]
        let model = MembershipModel(configuration: .init(productID: "test.household.annual",
            privacyURL: URL(string: "https://example.test/privacy"), termsURL: URL(string: "https://example.test/terms")),
            context: second, service: service, storefront: store, clock: { self.now })
        await model.start()
        await model.restore()
        XCTAssertTrue(model.hasPaidAccess)
        XCTAssertEqual(model.notice, .restored)
        XCTAssertFalse(model.canPurchase)
        XCTAssertFalse(model.canManageSeats)
        XCTAssertEqual(store.syncCount, 0)
        XCTAssertEqual(service.submissions, 0)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testRemovedSeatDropsRosterRejectsDelayedResponsesAndAcceptsLaterReassignment() throws {
        let adult = MembershipSeat(userID: "adult-two", displayName: "Sam", isAdult: true)
        let member = MembershipContext(purchaserID: adult.userID, purchaserName: adult.displayName,
            householdID: context.householdID, householdName: context.householdName, appAccountToken: nil)
        func privateFree(at date: Date) -> MembershipSnapshot {
            .init(householdID: member.householdID, purchaserID: member.purchaserID, revision: 0, status: .free,
                expiresAt: nil, graceExpiresAt: nil, verifiedAt: date, validUntil: date, seats: [])
        }
        let paid = snapshot(revision: 4, seats: [adult])
        let removed = privateFree(at: now.addingTimeInterval(-5))
        var state = MembershipState()
        try state.accept(paid, context: member, now: now)
        try state.accept(removed, context: member, now: now)
        XCTAssertEqual(state.snapshot, removed)
        XCTAssertFalse(state.hasPaidAccess(context: member, now: now))
        try state.accept(paid, context: member, now: now)
        // Even a previously unseen revision can have been read before the removal.
        try state.accept(snapshot(revision: 5, seats: [adult]), context: member, now: now)
        XCTAssertEqual(state.snapshot, removed)
        XCTAssertTrue(state.freeRecordsAndExportAvailable)

        let reassigned = MembershipSnapshot(householdID: paid.householdID, purchaserID: paid.purchaserID,
            revision: 6, status: .active, expiresAt: paid.expiresAt, graceExpiresAt: nil,
            verifiedAt: now, validUntil: paid.validUntil, seats: [adult])
        try state.accept(reassigned, context: member, now: now)
        try state.accept(removed, context: member, now: now)
        XCTAssertEqual(state.snapshot, reassigned)
        XCTAssertTrue(state.hasPaidAccess(context: member, now: now))
    }

    func testUnseatedAdultNeverGetsPaidAccessFromSharedSnapshot() async {
        let second = MembershipContext(purchaserID: "unseated-adult", purchaserName: "Sam", householdID: context.householdID,
            householdName: "Home", appAccountToken: nil)
        let service = FakeMembershipService(snapshot: snapshot())
        let model = MembershipModel(context: second, service: service, storefront: FakeMembershipStorefront(), clock: { self.now })
        await model.restore()
        XCTAssertFalse(model.hasPaidAccess)
        await model.receive(.verified(transaction()))
        XCTAssertEqual(service.submissions, 0)
        XCTAssertEqual(model.notice, .failed(.notPurchaser))
    }

    func testRejectedRestoreSurvivesSuccessfulFreeProjection() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        service.submissionError = .wrongHousehold
        let store = FakeMembershipStorefront()
        store.current = [.verified(transaction())]
        let model = makeModel(service, store)
        await model.restore()
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.notice, .failed(.wrongHousehold))
        XCTAssertEqual(model.state.issue, .wrongHousehold)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testMismatchedAccountRestoreSurvivesSuccessfulFreeProjection() async {
        let service = FakeMembershipService(snapshot: snapshot(status: .free))
        let store = FakeMembershipStorefront()
        store.current = [.verified(transaction(token: UUID()))]
        let model = makeModel(service, store)
        await model.restore()
        XCTAssertEqual(model.notice, .failed(.accountMismatch))
        XCTAssertEqual(service.submissions, 0)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testSeatConflictLoadsCurrentRosterWithoutReplayingRemoval() async {
        let second = MembershipSeat(userID: "adult-two", displayName: "Sam", isAdult: true)
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront()
        let model = makeModel(service, store)
        await model.refresh()
        service.snapshot = snapshot(revision: 2, seats: [second])
        let reads = store.unfinishedReads

        await model.replaceSeat(userID: nil, replacingUserID: context.purchaserID, reviewedRevision: 1)
        XCTAssertEqual(model.state.snapshot?.revision, 2)
        XCTAssertEqual(model.state.snapshot?.seats, [second])
        XCTAssertEqual(model.eligibleAdults, [second])
        XCTAssertEqual(service.requestedSeatRevisions, [1])
        XCTAssertEqual(store.unfinishedReads, reads)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertTrue(model.canManageSeats)
        XCTAssertEqual(model.notice, .failed(.refreshRequired))

        // A menu tap captured before the roster changed cannot use its newer revision.
        await model.replaceSeat(userID: nil, replacingUserID: context.purchaserID, reviewedRevision: 1)
        XCTAssertEqual(service.requestedSeatRevisions, [1])
        service.seatUpdateResponse = snapshot(revision: 3, seats: [])
        await model.replaceSeat(userID: nil, replacingUserID: second.userID, reviewedRevision: 2)
        XCTAssertEqual(service.requestedSeatRevisions, [1, 2])
        XCTAssertEqual(model.state.snapshot?.seats, [])
        XCTAssertNil(model.notice)
    }

    func testSeatConflictFollowedByAccessLossClearsRosterAndStopsChanges() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let model = makeModel(service, FakeMembershipStorefront())
        await model.refresh()
        service.snapshot = snapshot(revision: 2)
        service.error = .signInRequired

        await model.replaceSeat(userID: nil, replacingUserID: context.purchaserID, reviewedRevision: 1)
        XCTAssertNil(model.state.snapshot)
        XCTAssertTrue(model.eligibleAdults.isEmpty)
        XCTAssertFalse(model.canManageSeats)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.notice, .failed(.signInRequired))
        await model.replaceSeat(userID: nil, replacingUserID: context.purchaserID, reviewedRevision: 1)
        XCTAssertEqual(service.requestedSeatRevisions, [1])
    }

    func testSessionRejectionImmediatelyClearsPaidProjection() async {
        let service = FakeMembershipService(snapshot: snapshot())
        let model = makeModel(service, FakeMembershipStorefront())
        await model.refresh()
        XCTAssertTrue(model.hasPaidAccess)
        service.error = .signInRequired
        await model.refresh()
        XCTAssertNil(model.state.snapshot)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertFalse(model.canManageSeats)
        XCTAssertTrue(model.eligibleAdults.isEmpty)
        XCTAssertTrue(model.state.freeManualPlanningAvailable)
        var state = MembershipState()
        try? state.accept(snapshot(), context: context, now: now)
        state.fail(.membershipInactive)
        XCTAssertFalse(state.hasPaidAccess(context: context, now: now))
        XCTAssertTrue(state.freeRecordsAndExportAvailable)
    }

    func testHTTPAdaptersKeepTheirOwnResponsesAfterAnotherSessionIsCreated() async throws {
        let firstFixture = httpFixture()
        firstFixture.handler = { _ in
            (409, Data("{\"error\":{\"code\":\"refresh_required\"}}".utf8))
        }
        let first = try httpService(firstFixture)
        let secondFixture = httpFixture()
        secondFixture.handler = { _ in
            (409, Data("{\"error\":{\"code\":\"purchase_already_bound\"}}".utf8))
        }
        let second = try httpService(secondFixture)
        defer { firstFixture.handler = nil; secondFixture.handler = nil }
        let householdID = "11111111-1111-4111-8111-111111111111"
        for (service, expected) in [(first, MembershipFailure.refreshRequired), (second, .wrongHousehold)] {
            do {
                _ = try await service.purchaseContext(householdID: householdID)
                XCTFail("Expected the response belonging to this service's fixture")
            } catch { XCTAssertEqual(error as? MembershipFailure, expected) }
        }
    }

    func testHTTPAdapterIncludesEnrolledDeviceAndDecodesServerDates() async throws {
        let fixture = httpFixture()
        let householdID = "11111111-1111-4111-8111-111111111111"
        let actorID = "22222222-2222-4222-8222-222222222222"
        let accountToken = context.appAccountToken
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let expected = MembershipSnapshot(householdID: householdID, purchaserID: actorID, revision: 1,
            status: .active, expiresAt: now.addingTimeInterval(300), graceExpiresAt: nil,
            verifiedAt: now, validUntil: now.addingTimeInterval(300),
            seats: [.init(userID: actorID, displayName: "Mia", isAdult: true)])
        let data = try encoder.encode(expected)
        fixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/households/\(householdID)/entitlements")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test.access.token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "test-device-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return (200, data)
        }
        defer { fixture.handler = nil }
        let service = try httpService(fixture)
        let actual = try await service.fetch(context: .init(purchaserID: actorID, purchaserName: "Mia",
            householdID: householdID, householdName: "Home", appAccountToken: accountToken))
        XCTAssertEqual(actual, expected)
    }

    func testHTTPAdapterUsesSpecificServerFailureCodes() async throws {
        let fixture = httpFixture()
        let service = try httpService(fixture)
        let cases: [(Int, String, MembershipFailure)] = [
            (409, "purchase_already_bound", .wrongHousehold), (409, "refresh_required", .refreshRequired),
            (409, "purchase_context_not_purchaser", .notPurchaser),
            (403, "access_ended", .signInRequired), (401, "session_needed", .signInRequired),
            (403, "membership_inactive", .membershipInactive),
            (422, "billing_verification_failed", .unverified), (503, "billing_unavailable", .deliveryPending),
            (503, "storage_unavailable", .deliveryPending), (429, "rate_limited", .deliveryPending)]
        defer { fixture.handler = nil }
        for (status, code, expected) in cases {
            fixture.handler = { _ in
                (status, Data("{\"error\":{\"code\":\"\(code)\"}}".utf8))
            }
            do {
                _ = try await service.purchaseContext(householdID: "11111111-1111-4111-8111-111111111111")
                XCTFail("Expected \(code)")
            } catch { XCTAssertEqual(error as? MembershipFailure, expected) }
        }
    }

    func testHTTPAdapterRequiresDeviceBeforeSendingPurchaseContext() async throws {
        let fixture = httpFixture()
        fixture.handler = { _ in XCTFail("Missing device must not reach the network"); return (500, Data()) }
        defer { fixture.handler = nil }
        let service = try HTTPMembershipEntitlementService(baseURL: fixture.baseURL,
            session: fixture.session, deviceToken: { "" }, token: { "test.access.token" })
        do {
            _ = try await service.purchaseContext(householdID: "11111111-1111-4111-8111-111111111111")
            XCTFail("Expected missing-device rejection")
        } catch { XCTAssertEqual(error as? MembershipFailure, .signInRequired) }
    }

    func testHTTPAdapterRejectsUntrustedBaseURLs() {
        for value in ["http://service.example.test", "https://user:password@service.example.test", "https://service.example.test?q=1", "https://service.example.test#fragment"] {
            XCTAssertThrowsError(try HTTPMembershipEntitlementService(baseURL: URL(string: value)!, deviceToken: { "device" }, token: { "token" }))
        }
    }

    private func httpFixture() -> MembershipHTTPFixture {
        let fixture = MembershipHTTPFixture()
        addTeardownBlock { @MainActor in fixture.close() }
        return fixture
    }

    private func httpService(_ fixture: MembershipHTTPFixture) throws -> HTTPMembershipEntitlementService {
        try HTTPMembershipEntitlementService(baseURL: fixture.baseURL,
            session: fixture.session, deviceToken: { "test-device-token" }, token: { "test.access.token" })
    }

    private func session(household: String = "household-one", subject: String = "subject-one") -> MembershipSession {
        .init(subjectID: subject, memberID: context.purchaserID, accountName: "Mia", householdID: household,
            householdName: "Home", serviceURL: URL(string: "https://service.example.test")!)
    }

    private func coordinatorModel(_ session: MembershipSession, _ service: FakeMembershipService, _ store: FakeMembershipStorefront) -> MembershipModel {
        MembershipModel(configuration: .init(productID: "test.household.annual", privacyURL: URL(string: "https://example.test/privacy"), termsURL: URL(string: "https://example.test/terms")),
            context: .init(purchaserID: session.memberID, purchaserName: session.accountName, householdID: session.householdID,
                householdName: session.householdName, appAccountToken: context.appAccountToken),
            service: service, storefront: store, clock: { self.now })
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Lifecycle condition did not settle", file: file, line: line)
    }

    func testCoordinatorStartsWithoutScreenAndForegroundReusesOneObserver() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let coordinator = MembershipCoordinator { session, _ in self.coordinatorModel(session, service, store) }
        coordinator.bind(to: source)
        await settle { coordinator.model != nil && !coordinator.isLoading }
        XCTAssertEqual(store.observerStarts, 1)
        XCTAssertEqual(store.activeObservers, 1)
        let retained = coordinator.model
        let before = service.fetches
        coordinator.bind(to: source)
        coordinator.foreground(); coordinator.foreground()
        await settle { service.fetches > before }
        XCTAssertTrue(coordinator.model === retained)
        XCTAssertEqual(store.observerStarts, 1)
        XCTAssertEqual(store.syncCount, 0)
        coordinator.stop()
        await settle { store.activeObservers == 0 }
    }

    func testCoordinatorLockSynchronouslyClearsModelAndCancelsObservation() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let coordinator = MembershipCoordinator { session, _ in self.coordinatorModel(session, service, store) }
        coordinator.bind(to: source)
        await settle { coordinator.model != nil && !coordinator.isLoading }
        let retained = coordinator.model
        source.invalidate()
        XCTAssertNil(coordinator.model)
        XCTAssertNil(retained?.state.snapshot)
        coordinator.foreground()
        store.emit(.verified(transaction()))
        await settle { store.activeObservers == 0 }
        XCTAssertNil(coordinator.model)
        XCTAssertEqual(service.submissions, 0)
    }

    func testCoordinatorDiscardsModelConstructedAfterSignOut() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let fresh = coordinatorModel(session(), service, store)
        var continuation: CheckedContinuation<MembershipModel, Never>?
        let coordinator = MembershipCoordinator { _, _ in await withCheckedContinuation { continuation = $0 } }
        coordinator.bind(to: source)
        await settle { continuation != nil }
        source.invalidate()
        continuation?.resume(returning: fresh)
        // Cancellation is cooperative: wait for the factory result to be discarded,
        // rather than assuming a fixed number of task yields runs its continuation.
        await settle { fresh.isStopped }
        XCTAssertNil(coordinator.model)
        await fresh.start()
        XCTAssertEqual(store.observerStarts, 0)
        XCTAssertNil(fresh.state.snapshot)
    }

    func testCoordinatorHouseholdSwitchRejectsOldInFlightDelivery() async {
        let source = FakeMembershipSessionSource(session: session())
        let oldService = FakeMembershipService(snapshot: snapshot())
        let newService = FakeMembershipService(snapshot: snapshot(household: "household-two"))
        let oldStore = FakeMembershipStorefront(); oldStore.keepsUpdatesOpen = true
        let newStore = FakeMembershipStorefront(); newStore.keepsUpdatesOpen = true
        let coordinator = MembershipCoordinator { session, _ in
            self.coordinatorModel(session, session.householdID == "household-one" ? oldService : newService,
                session.householdID == "household-one" ? oldStore : newStore)
        }
        coordinator.bind(to: source)
        await settle { coordinator.model != nil && !coordinator.isLoading }
        oldService.pauseSubmission = true
        oldStore.emit(.verified(transaction()))
        await settle { oldService.continuation != nil }
        source.replace(with: session(household: "household-two"))
        await settle { coordinator.model?.context?.householdID == "household-two" && !coordinator.isLoading }
        oldService.continuation?.resume()
        await settle { oldService.didCommit && oldStore.activeObservers == 0 }
        XCTAssertTrue(oldStore.finished.isEmpty)
        XCTAssertEqual(newStore.activeObservers, 1)
        XCTAssertEqual(coordinator.model?.state.snapshot?.householdID, "household-two")
        XCTAssertEqual(newService.submissions, 0)
        coordinator.stop()
        await settle { newStore.activeObservers == 0 }
    }

    func testCoordinatorReenrollmentInSameHouseholdReplacesObserver() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        var stores: [FakeMembershipStorefront] = []
        let coordinator = MembershipCoordinator { session, _ in
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true; stores.append(store)
            return self.coordinatorModel(session, service, store)
        }
        coordinator.bind(to: source)
        await settle { stores.count == 1 && !coordinator.isLoading }
        source.replace(with: session())
        await settle { stores.count == 2 && !coordinator.isLoading && stores[0].activeObservers == 0 }
        XCTAssertEqual(stores[1].activeObservers, 1)
        XCTAssertEqual(stores.reduce(0) { $0 + $1.activeObservers }, 1)
        coordinator.stop()
        await settle { stores[1].activeObservers == 0 }
    }

    func testCoordinatorIdentityChangeWaitsForNewAuthorizedProjection() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        var stores: [FakeMembershipStorefront] = []
        let coordinator = MembershipCoordinator { session, _ in
            let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true; stores.append(store)
            return self.coordinatorModel(session, service, store)
        }
        coordinator.bind(to: source)
        await settle { stores.count == 1 && !coordinator.isLoading }
        source.membershipSession = session(subject: "new-subject-with-old-projection")
        source.events.send(.identity)
        await settle { coordinator.model == nil && stores[0].activeObservers == 0 }
        coordinator.foreground(); coordinator.retry()
        await Task.yield()
        XCTAssertEqual(stores.count, 1)
        source.events.send(.projection)
        await settle { stores.count == 2 && !coordinator.isLoading }
        coordinator.stop()
        await settle { stores[1].activeObservers == 0 }
    }

    func testCoordinatorCredentialsCannotFollowAnotherAuthenticatedSubject() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        var credentials: [MembershipCredentials] = []
        let coordinator = MembershipCoordinator { session, supplied in
            credentials.append(supplied)
            return self.coordinatorModel(session, service, FakeMembershipStorefront())
        }
        coordinator.bind(to: source)
        await settle { credentials.count == 1 && !coordinator.isLoading }
        source.replace(with: session(subject: "subject-two"))
        await settle { credentials.count == 2 && !coordinator.isLoading }
        do { _ = try await credentials[0].accessToken(); XCTFail("Old identity used a new credential") }
        catch { XCTAssertEqual(error as? MembershipFailure, .signInRequired) }
        do { _ = try await credentials[0].deviceToken(); XCTFail("Old identity used a new device") }
        catch { XCTAssertEqual(error as? MembershipFailure, .signInRequired) }
        XCTAssertEqual(source.credentialReads, 0)
        coordinator.stop()
    }

    func testCoordinatorAuthorizationRejectionStopsObserverUntilNewProjection() async {
        let source = FakeMembershipSessionSource(session: session())
        let service = FakeMembershipService(snapshot: snapshot())
        let store = FakeMembershipStorefront(); store.keepsUpdatesOpen = true
        let coordinator = MembershipCoordinator { session, credentials in
            service.fetchCredential = credentials.accessToken
            return self.coordinatorModel(session, service, store)
        }
        coordinator.bind(to: source)
        await settle { coordinator.model != nil && !coordinator.isLoading }
        source.credentialError = .signInRequired
        coordinator.foreground()
        await settle { coordinator.model == nil && coordinator.failure && store.activeObservers == 0 }
        coordinator.foreground(); coordinator.retry()
        await Task.yield()
        XCTAssertNil(coordinator.model)
        XCTAssertEqual(store.observerStarts, 1)
    }

    func testMissingDeploymentConfigurationKeepsPurchaseDisabled() async {
        let model = MembershipModel(configuration: .init(productID: nil, privacyURL: nil, termsURL: nil))
        await model.purchase()
        XCTAssertFalse(model.canPurchase)
        XCTAssertFalse(model.hasPaidAccess)
        XCTAssertEqual(model.notice, .failed(.notConfigured))
    }
}

@MainActor private final class FakeMembershipService: MembershipEntitlementService {
    var snapshot: MembershipSnapshot
    var error: MembershipFailure?
    var submissionError: MembershipFailure?
    var receiptOverride: MembershipDeliveryReceipt?
    var submissions = 0
    var fetches = 0
    var fetchCredential: (() async throws -> String)?
    var didCommit = false
    var pauseSubmission = false
    var continuation: CheckedContinuation<Void, Never>?
    init(snapshot: MembershipSnapshot) { self.snapshot = snapshot }
    func submit(_ transaction: SignedMembershipTransaction, context: MembershipContext) async throws -> MembershipDeliveryReceipt {
        submissions += 1
        if pauseSubmission { await withCheckedContinuation { continuation = $0 } }
        if let submissionError { throw submissionError }
        if let error { throw error }
        didCommit = true
        return receiptOverride ?? .init(acceptedTransactionID: transaction.transactionID, durable: true, snapshot: snapshot)
    }
    func fetch(context: MembershipContext) async throws -> MembershipSnapshot {
        fetches += 1
        _ = try await fetchCredential?()
        if let error { throw error }; return snapshot
    }
    func seatCandidates(context: MembershipContext) async throws -> [MembershipSeat] { snapshot.seats }
    var requestedSeatRevisions: [Int] = []
    var seatUpdateResponse: MembershipSnapshot?
    func replaceSeat(userID: String?, replacingUserID: String?, context: MembershipContext, revision: Int) async throws -> MembershipSnapshot {
        requestedSeatRevisions.append(revision)
        guard revision == snapshot.revision else { throw MembershipFailure.refreshRequired }
        if let seatUpdateResponse { snapshot = seatUpdateResponse }
        return snapshot
    }
}

@MainActor private final class FakeMembershipStorefront: MembershipStorefront {
    var finished: [String] = []
    var current: [MembershipPurchaseOutcome] = []
    var unfinished: [MembershipPurchaseOutcome] = []
    var unfinishedReads = 0
    var pauseUnfinishedRead = false
    var unfinishedContinuation: CheckedContinuation<Void, Never>?
    var syncCount = 0
    var purchaseCount = 0
    var pausePurchase = false
    var purchaseError: MembershipFailure?
    var purchaseContinuation: CheckedContinuation<MembershipPurchaseOutcome, Never>?
    func resolvePurchase(_ outcome: MembershipPurchaseOutcome) {
        let continuation = purchaseContinuation; purchaseContinuation = nil
        continuation?.resume(returning: outcome)
    }
    var onFinish: (() -> Void)?
    var keepsUpdatesOpen = false
    var onLoad: (() -> Void)?
    var waitDuringLoad: (() async throws -> Void)?
    var observerStarts = 0
    var activeObservers: Int { continuations.count }
    private var continuations: [UUID: AsyncStream<MembershipPurchaseOutcome>.Continuation] = [:]
    func emit(_ outcome: MembershipPurchaseOutcome) { for continuation in continuations.values { continuation.yield(outcome) } }
    func load(productID: String) async throws -> MembershipOffer {
        onLoad?()
        try await waitDuringLoad?()
        return .init(productID: productID, displayName: "Test Household", displayPrice: "€51,99", periodValue: 1, periodUnit: .year)
    }
    func purchase(appAccountToken: UUID) async throws -> MembershipPurchaseOutcome {
        purchaseCount += 1
        let outcome: MembershipPurchaseOutcome
        if pausePurchase { outcome = await withCheckedContinuation { purchaseContinuation = $0 } }
        else { outcome = .pending }
        if let purchaseError { throw purchaseError }
        return outcome
    }
    func currentTransactions() async -> [MembershipPurchaseOutcome] { current }
    func unfinishedTransactions() async -> [MembershipPurchaseOutcome] {
        unfinishedReads += 1
        let snapshot = unfinished
        if pauseUnfinishedRead { await withCheckedContinuation { unfinishedContinuation = $0 } }
        return snapshot
    }
    func updates(for productID: String) -> AsyncStream<MembershipPurchaseOutcome> {
        observerStarts += 1
        guard keepsUpdatesOpen else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations.removeValue(forKey: id) }
            }
        }
    }
    func finish(transactionID: String) async { onFinish?(); finished.append(transactionID) }
    func sync() async throws { syncCount += 1 }
}

// The test owns the fixture until teardown; the registry owns only a weak route.
@MainActor private final class MembershipHTTPFixture {
    private let responses = MembershipFixtureResponses()
    let session: URLSession
    var baseURL: URL { URL(string: "https://" + responses.host)! }
    var handler: MembershipFixtureResponses.Handler? {
        get { responses.handler }
        set { responses.handler = newValue }
    }
    init() {
        MembershipURLProtocol.register(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    func close() {
        responses.close()
        MembershipURLProtocol.remove(host: responses.host)
        session.invalidateAndCancel()
    }
}

private final class MembershipFixtureResponses {
    typealias Handler = (URLRequest) -> (Int, Data)
    let host = "membership-" + UUID().uuidString.lowercased() + ".invalid"
    private let lock = NSLock()
    private var closed = false
    private var storedHandler: Handler?
    var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; if !closed { storedHandler = newValue } }
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        guard !closed, request.url?.host == host, let handler = storedHandler else {
            lock.unlock(); throw URLError(.unsupportedURL)
        }
        lock.unlock()
        // The request retains this handler snapshot; callbacks never run under a registry/state lock.
        return handler(request)
    }
    func close() { lock.lock(); closed = true; storedHandler = nil; lock.unlock() }
    deinit { MembershipURLProtocol.remove(host: host) }
}

private final class WeakMembershipResponses {
    weak var value: MembershipFixtureResponses?
    init(_ value: MembershipFixtureResponses) { self.value = value }
}

private final class MembershipURLProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var routes: [String: WeakMembershipResponses] = [:]
    static func register(_ responses: MembershipFixtureResponses) {
        registryLock.lock(); defer { registryLock.unlock() }
        routes[responses.host] = WeakMembershipResponses(responses)
    }
    static func remove(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; routes.removeValue(forKey: host)
    }
    private static func responses(for request: URLRequest) -> MembershipFixtureResponses? {
        registryLock.lock(); defer { registryLock.unlock() }
        guard request.url?.scheme == "https", let host = request.url?.host else { return nil }
        return routes[host]?.value
    }
    // Always intercept, including unknown destinations: never fall through to networking.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let responses = Self.responses(for: request), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let (status, data) = try responses.respond(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class FakeMembershipSessionSource: MembershipSessionSource {
    var membershipSession: MembershipSession?
    let events = PassthroughSubject<MembershipSessionEvent, Never>()
    var membershipSessionChanges: AnyPublisher<MembershipSessionEvent, Never> { events.eraseToAnyPublisher() }
    var onScopeChange: (() -> Void)?
    var credentialReads = 0
    var credentialError: MembershipFailure?
    init(session: MembershipSession) { membershipSession = session }
    func membershipAccessToken() async throws -> String {
        credentialReads += 1; if let credentialError { throw credentialError }; return "test.access.token"
    }
    func membershipDeviceToken() async throws -> String {
        credentialReads += 1; if let credentialError { throw credentialError }; return "test-device-token"
    }
    func invalidate() { onScopeChange?(); membershipSession = nil; events.send(.lock) }
    func replace(with session: MembershipSession) { onScopeChange?(); membershipSession = session; events.send(.projection) }
}
