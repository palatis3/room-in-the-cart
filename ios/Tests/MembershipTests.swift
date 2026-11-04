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

    func testHTTPAdapterIncludesEnrolledDeviceAndDecodesServerDates() async throws {
        let householdID = "11111111-1111-4111-8111-111111111111"
        let actorID = "22222222-2222-4222-8222-222222222222"
        let accountToken = context.appAccountToken
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let expected = MembershipSnapshot(householdID: householdID, purchaserID: actorID, revision: 1,
            status: .active, expiresAt: now.addingTimeInterval(300), graceExpiresAt: nil,
            verifiedAt: now, validUntil: now.addingTimeInterval(300),
            seats: [.init(userID: actorID, displayName: "Mia", isAdult: true)])
        let data = try encoder.encode(expected)
        MembershipURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/households/\(householdID)/entitlements")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test.access.token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "test-device-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return (200, data)
        }
        defer { MembershipURLProtocol.handler = nil }
        let service = try httpService()
        let actual = try await service.fetch(context: .init(purchaserID: actorID, purchaserName: "Mia",
            householdID: householdID, householdName: "Home", appAccountToken: accountToken))
        XCTAssertEqual(actual, expected)
    }

    func testHTTPAdapterUsesSpecificServerFailureCodes() async throws {
        let service = try httpService()
        let cases: [(Int, String, MembershipFailure)] = [
            (409, "purchase_already_bound", .wrongHousehold), (409, "refresh_required", .refreshRequired),
            (409, "purchase_context_not_purchaser", .notPurchaser),
            (403, "access_ended", .signInRequired), (401, "session_needed", .signInRequired),
            (403, "membership_inactive", .membershipInactive),
            (422, "billing_verification_failed", .unverified), (503, "billing_unavailable", .deliveryPending),
            (503, "storage_unavailable", .deliveryPending), (429, "rate_limited", .deliveryPending)]
        defer { MembershipURLProtocol.handler = nil }
        for (status, code, expected) in cases {
            MembershipURLProtocol.handler = { _ in
                (status, Data("{\"error\":{\"code\":\"\(code)\"}}".utf8))
            }
            do {
                _ = try await service.purchaseContext(householdID: "11111111-1111-4111-8111-111111111111")
                XCTFail("Expected \(code)")
            } catch { XCTAssertEqual(error as? MembershipFailure, expected) }
        }
    }

    func testHTTPAdapterRequiresDeviceBeforeSendingPurchaseContext() async throws {
        MembershipURLProtocol.handler = { _ in XCTFail("Missing device must not reach the network"); return (500, Data()) }
        defer { MembershipURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let service = try HTTPMembershipEntitlementService(baseURL: URL(string: "https://service.example.test")!,
            session: URLSession(configuration: configuration), deviceToken: { "" }, token: { "test.access.token" })
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

    private func httpService() throws -> HTTPMembershipEntitlementService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        return try HTTPMembershipEntitlementService(baseURL: URL(string: "https://service.example.test")!,
            session: URLSession(configuration: configuration), deviceToken: { "test-device-token" }, token: { "test.access.token" })
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
    func replaceSeat(userID: String?, replacingUserID: String?, context: MembershipContext, revision: Int) async throws -> MembershipSnapshot { snapshot }
}

@MainActor private final class FakeMembershipStorefront: MembershipStorefront {
    var finished: [String] = []
    var current: [MembershipPurchaseOutcome] = []
    var unfinished: [MembershipPurchaseOutcome] = []
    var syncCount = 0
    var purchaseCount = 0
    var onFinish: (() -> Void)?
    var keepsUpdatesOpen = false
    var observerStarts = 0
    var activeObservers: Int { continuations.count }
    private var continuations: [UUID: AsyncStream<MembershipPurchaseOutcome>.Continuation] = [:]
    func emit(_ outcome: MembershipPurchaseOutcome) { for continuation in continuations.values { continuation.yield(outcome) } }
    func load(productID: String) async throws -> MembershipOffer {
        .init(productID: productID, displayName: "Test Household", displayPrice: "€51,99", periodValue: 1, periodUnit: .year)
    }
    func purchase(appAccountToken: UUID) async throws -> MembershipPurchaseOutcome {
        purchaseCount += 1
        return .pending
    }
    func currentTransactions() async -> [MembershipPurchaseOutcome] { current }
    func unfinishedTransactions() async -> [MembershipPurchaseOutcome] { unfinished }
    func updates() -> AsyncStream<MembershipPurchaseOutcome> {
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

private final class MembershipURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
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
