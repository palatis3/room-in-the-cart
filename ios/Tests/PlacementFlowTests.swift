import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class PlacementFlowTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for url in directories { try? FileManager.default.removeItem(at: url) }; directories = []; super.tearDown() }
    private func setup() async throws -> (PlacementFeatureModel, PlacementFixtureService, PlacementFaultStore, PlacementScopeBox) {
        let service = try PlacementFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = PlacementFaultStore(inner: PlacementPendingStore(url: directory.appendingPathComponent("placement.json")))
        let box = PlacementScopeBox(scope: .init(generation: UUID(), subject: "adult", householdID: service.household, memberID: service.member,
                                                   currentShopID: service.shopID, authorityStamp: "shopper", canManage: true), now: service.now)
        let model = PlacementFeatureModel(service: service, store: store, runtime: { box.scope }, clock: { box.now })
        await model.load(); return (model, service, store, box)
    }
    private func capture(_ model: PlacementFeatureModel) async throws {
        await model.refreshCurrent(); model.reviewCapture(); model.approved = true; await model.applyReviewed()
        XCTAssertNotNil(model.selected); XCTAssertNil(model.selected?.report)
    }
    private func reviewReport(_ model: PlacementFeatureModel, at date: Date) {
        model.occurredAt = date; model.reviewReport(); model.approved = true
    }
    func testLocalLoadNeverFetchesCurrentShopperDataOrSends() async throws {
        let (model, service, _, _) = try await setup()
        XCTAssertTrue(model.authorized); XCTAssertTrue(model.canManage); XCTAssertEqual(service.shopReads, 0)
        XCTAssertEqual(service.reportSends.count, 0); XCTAssertTrue(model.saved.isEmpty)
    }
    func testCaptureNeedsExplicitApprovalAndPersistsOriginalSnapshotBeforeExternalAction() async throws {
        let (model, service, store, _) = try await setup()
        await model.refreshCurrent(); model.reviewCapture(); await model.applyReviewed()
        XCTAssertTrue(model.saved.isEmpty); XCTAssertEqual(service.prepareCaptures, 0)
        model.approved = true; await model.applyReviewed()
        let state = try await store.read(); let saved = try XCTUnwrap(state.captures.first)
        XCTAssertEqual(saved.capture.snapshot, service.shop); XCTAssertEqual(saved.capture.snapshot.shopRevision, 4)
        XCTAssertEqual(saved.capture.snapshot.authorityEpoch, 2); XCTAssertNil(saved.report)
        XCTAssertEqual(service.prepareCaptures, 1); XCTAssertTrue(service.reportSends.isEmpty)
    }
    func testOfflineReportSealsExactTimeIdentityAndBytesBeforeFirstSend() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        let original = try XCTUnwrap(model.selected?.capture)
        reviewReport(model, at: box.now.addingTimeInterval(-3)); service.reportError = ClientError.invalidResponse
        service.beforeReportSend = { intent in
            let state = try await store.read(); XCTAssertEqual(state.captures.first?.report, intent)
        }
        await model.applyReviewed()
        let intent = try XCTUnwrap(model.selected?.report)
        XCTAssertEqual(intent.prepared, original); XCTAssertEqual(intent.id, original.id)
        XCTAssertEqual(intent.occurredAt, PlacementDate.string(box.now.addingTimeInterval(-3)))
        XCTAssertNil(model.selected?.receipt); XCTAssertEqual(service.prepareCaptures, 1)
        let state = try await store.read(); XCTAssertEqual(state.captures.first?.report?.bytes, intent.bytes)
    }
    func testFormerShopperRetriesOriginalReportWithoutFetchingNewShopperFacts() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        reviewReport(model, at: box.now); service.reportError = ClientError.invalidResponse; await model.applyReviewed()
        let original = try XCTUnwrap(model.selected?.report); let reads = service.shopReads
        let old = try XCTUnwrap(box.scope)
        box.scope = .init(generation: old.generation, subject: old.subject, householdID: old.householdID, memberID: old.memberID,
                          currentShopID: old.currentShopID, authorityStamp: "contributor", canManage: false)
        model.enforceRuntime(); XCTAssertNil(model.currentShop); XCTAssertTrue(model.saved.isEmpty)
        let restored = PlacementFeatureModel(service: service, store: store, runtime: { box.scope }, clock: { box.now })
        await restored.load(); XCTAssertFalse(restored.canManage); XCTAssertEqual(restored.selected?.report, original)
        service.reportError = nil; service.reportDisposition = "pending_reconciliation"; await restored.retryReport()
        XCTAssertEqual(service.shopReads, reads); XCTAssertEqual(service.prepareCaptures, 1)
        XCTAssertEqual(service.reportSends.count, 2); XCTAssertEqual(service.reportSends[0].bytes, service.reportSends[1].bytes)
        XCTAssertEqual(restored.selected?.receipt?.disposition, "pending_reconciliation")
    }
    func testSealFailureNeverSendsAndTimeEditInvalidatesApproval() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        reviewReport(model, at: box.now); model.occurredAt = box.now.addingTimeInterval(-1)
        XCTAssertNil(model.reviewed); XCTAssertFalse(model.approved)
        model.reviewReport(); model.approved = true; await store.setSealFailure(true); await model.applyReviewed()
        XCTAssertTrue(service.reportSends.isEmpty); XCTAssertNil(model.selected?.report)
    }
    func testPersistingConfirmedReportReceiptCanRetryWithoutResending() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        reviewReport(model, at: box.now); await store.setReceiptFailure(true); await model.applyReviewed()
        XCTAssertEqual(service.reportSends.count, 1); XCTAssertNil(model.selected?.receipt)
        box.now = box.now.addingTimeInterval(7200); XCTAssertTrue(model.reportWindowExpired); XCTAssertTrue(model.canRetryReport)
        await store.setReceiptFailure(false); await model.retryReport()
        XCTAssertEqual(service.reportSends.count, 1); XCTAssertNotNil(model.selected?.receipt)
    }
    func testExpiredReportNeverMintsAnotherWindowAndRecoversMinimalStatus() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        reviewReport(model, at: box.now); service.reportError = ClientError.invalidResponse; await model.applyReviewed()
        let intent = try XCTUnwrap(model.selected?.report); box.now = box.now.addingTimeInterval(7200)
        let restored = PlacementFeatureModel(service: service, store: store, runtime: { box.scope }, clock: { box.now }); await restored.load()
        XCTAssertTrue(restored.reportWindowExpired); await restored.retryReport()
        XCTAssertEqual(service.reportSends.count, 1); XCTAssertEqual(service.prepareCaptures, 1)
        service.reportedStatus = service.status(intent: intent, state: "pending_reconciliation")
        await restored.refreshReporterStatus()
        XCTAssertEqual(restored.selected?.status?.state, "pending_reconciliation"); XCTAssertEqual(restored.selected?.report?.bytes, intent.bytes)
        await restored.retryReport(); XCTAssertEqual(service.reportSends.count, 1)
    }
    func testAbsentExpiredStatusPreservesOriginalEvidenceWithoutAssumingSuccess() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        box.now = box.now.addingTimeInterval(7200); reviewReport(model, at: box.now); await model.applyReviewed()
        XCTAssertTrue(service.reportSends.isEmpty); XCTAssertNotNil(model.selected?.report)
        await model.refreshReporterStatus(); XCTAssertNil(model.selected?.receipt); XCTAssertNil(model.selected?.status)
        XCTAssertTrue(model.notice?.contains("No recorded result") == true)
        let state = try await store.read(); XCTAssertEqual(state.captures.count, 1); XCTAssertNotNil(state.captures[0].report)
    }
    func testAuthorityScopeChangeDuringCaptureCannotPersistLateSnapshot() async throws {
        let (model, service, store, box) = try await setup(); await model.refreshCurrent(); model.reviewCapture(); model.approved = true
        service.beforePrepareCapture = { box.scope = nil; model.enforceRuntime() }
        await model.applyReviewed(); let state = try await store.read()
        XCTAssertTrue(state.captures.isEmpty); XCTAssertFalse(model.authorized); XCTAssertNil(model.currentShop)
    }
    func testDeletionEpochRejectsLateCaptureAndLateReportSeal() async throws {
        let (model, service, store, box) = try await setup(); await model.refreshCurrent(); model.reviewCapture(); model.approved = true
        service.beforePrepareCapture = { try await store.purge() }; await model.applyReviewed()
        let emptyState = try await store.read(); XCTAssertTrue(emptyState.captures.isEmpty)
        service.beforePrepareCapture = nil; await model.load(); try await capture(model)
        reviewReport(model, at: box.now); try await store.purge(); await model.applyReviewed()
        XCTAssertTrue(service.reportSends.isEmpty); let erasedState = try await store.read(); XCTAssertTrue(erasedState.captures.isEmpty)
    }
    func testNewAccountCannotReadOldActorsCapture() async throws {
        let (model, _, store, box) = try await setup(); try await capture(model)
        let old = try XCTUnwrap(box.scope)
        box.scope = .init(generation: UUID(), subject: "different-adult", householdID: old.householdID, memberID: old.memberID,
                          currentShopID: nil, authorityStamp: "local_reporter_evidence", canManage: false)
        model.enforceRuntime(); await model.load(); XCTAssertTrue(model.saved.isEmpty); XCTAssertNil(model.selected)
        let retained = try await store.read(); XCTAssertEqual(retained.captures.count, 1)
    }
    func testReviewerTransferClearsLiveDataButKeepsOriginalReporterEvidence() async throws {
        let (model, service, store, _) = try await setup(); try await capture(model)
        service.shopError = ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)
        await model.refreshCurrent(); XCTAssertNil(model.currentShop); XCTAssertNil(model.reportPage)
        XCTAssertEqual(model.saved.count, 1); XCTAssertNotNil(model.selected); XCTAssertTrue(model.authorized)
        let retained = try await store.read(); XCTAssertEqual(retained.captures.count, 1)
    }
    func testReconciliationRequiresCurrentFrozenMatchAndExplicitReview() async throws {
        let (model, service, _, _) = try await setup(); await model.refreshCurrent()
        model.reviewReconciliation(service.pending, choice: .apply); XCTAssertNotNil(model.reviewed)
        await model.applyReviewed(); XCTAssertTrue(service.reviewSends.isEmpty)
        model.approved = true; await model.applyReviewed(); XCTAssertEqual(service.reviewSends.count, 1)
        XCTAssertEqual(service.reviewSends[0].base.shopRevision, 4); XCTAssertEqual(service.reviewSends[0].report.reportedRevision, 4)
        XCTAssertNil(model.currentShop); XCTAssertNil(model.pendingReview)
    }
    func testMismatchedFrozenReportCannotApplyButCanExplicitlyReject() async throws {
        let (model, service, _, _) = try await setup()
        service.pending = service.makePending(revision: 3); await model.refreshCurrent()
        model.reviewReconciliation(service.pending, choice: .apply); XCTAssertNil(model.reviewed)
        model.reviewReconciliation(service.pending, choice: .reject); XCTAssertNotNil(model.reviewed)
        model.approved = true; await model.applyReviewed(); XCTAssertEqual(service.reviewSends.first?.choice, .reject)
    }
    func testReconciliationLostResponsePreservesExactBaseAndRetry() async throws {
        let (model, service, store, box) = try await setup(); await model.refreshCurrent()
        model.reviewReconciliation(service.pending, choice: .apply); model.approved = true
        service.reviewError = ClientError.invalidResponse; await model.applyReviewed()
        let original = try XCTUnwrap(model.pendingReview)
        let restored = PlacementFeatureModel(service: service, store: store, runtime: { box.scope }, clock: { box.now })
        await restored.load(); XCTAssertNil(restored.pendingReview); await restored.refreshCurrent()
        XCTAssertEqual(restored.pendingReview, original); XCTAssertEqual(service.reviewSends.count, 1)
        service.reviewError = nil; await restored.retryReconciliation()
        XCTAssertEqual(service.reviewSends.count, 2); XCTAssertEqual(service.reviewSends[0].bytes, service.reviewSends[1].bytes)
    }
    func testKnownHandledReconciliationStatusPreventsResendAndExplicitRetirementKeepsEvidence() async throws {
        let (model, service, store, _) = try await setup(); await model.refreshCurrent()
        model.reviewReconciliation(service.pending, choice: .reject); model.approved = true; service.reviewError = ClientError.invalidResponse
        await model.applyReviewed(); let intent = try XCTUnwrap(model.pendingReview?.intent)
        service.detailReport = service.makePending(state: "rejected", resolutionKey: intent.id)
        await model.refreshReconciliationStatus(); XCTAssertEqual(model.pendingReview?.status?.report.resolutionClientKey, intent.id)
        await model.retryReconciliation(); XCTAssertEqual(service.reviewSends.count, 1)
        await model.retireReconciliationAfterStatusReview(); XCTAssertNil(model.pendingReview)
        let state = try await store.read(); XCTAssertTrue(state.reviews.first?.retired == true); XCTAssertEqual(state.reviews.first?.intent, intent)
    }
    func testStatusFailureCannotRetirePendingReconciliation() async throws {
        let (model, service, store, _) = try await setup(); await model.refreshCurrent()
        model.reviewReconciliation(service.pending, choice: .reject); model.approved = true; service.reviewError = ClientError.invalidResponse
        await model.applyReviewed(); service.detailError = ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)
        await model.retireReconciliationAfterStatusReview(); XCTAssertNil(model.pendingReview)
        let state = try await store.read(); XCTAssertFalse(try XCTUnwrap(state.reviews.first).retired)
    }
    func testOnlyExplicitUnreportedDiscardAllowsFreshCaptureOfSameSnapshot() async throws {
        let (model, service, store, box) = try await setup(); try await capture(model)
        let original = try XCTUnwrap(model.selected?.capture)
        await model.refreshCurrent(); model.reviewCapture(); model.approved = true; await model.applyReviewed()
        XCTAssertEqual(model.saved.count, 1)
        await model.discardUnreportedCapture(); XCTAssertTrue(model.saved.isEmpty)
        try await capture(model); let fresh = try XCTUnwrap(model.selected?.capture)
        XCTAssertNotEqual(original.id, fresh.id); XCTAssertEqual(original.snapshot, fresh.snapshot)
        reviewReport(model, at: box.now); service.reportError = ClientError.invalidResponse; await model.applyReviewed()
        await model.discardUnreportedCapture(); XCTAssertEqual(model.saved.count, 1); XCTAssertNotNil(model.selected?.report)
        let epoch = await store.epoch()
        do { try await store.discardUnreportedCapture(id: fresh.id, expectedEpoch: epoch); XCTFail("Sealed report erased") } catch {}
        let retained = try await store.read(); XCTAssertEqual(retained.captures.count, 1)
    }
    func testSealedTimeCannotBeRewrittenAndScopedPurgePreservesOtherActors() async throws {
        let (_, service, store, _) = try await setup()
        let epoch = await store.epoch(); let capture = try service.prepared()
        try await store.saveCapture(capture, expectedEpoch: epoch)
        let original = try capture.report(occurredAt: PlacementDate.string(service.now))
        try await store.sealReport(original, expectedEpoch: epoch)
        let changed = try capture.report(occurredAt: PlacementDate.string(service.now.addingTimeInterval(1)))
        do { try await store.sealReport(changed, expectedEpoch: epoch); XCTFail("Sealed time changed") } catch {}
        let other = try service.prepared(subject: "other-adult", member: "10000000-0000-4000-8000-000000000008")
        try await store.saveCapture(other, expectedEpoch: epoch)
        try await store.purge(householdID: service.household, subject: "adult")
        let state = try await store.read(); XCTAssertEqual(state.captures.map { $0.capture.subject }, ["other-adult"])
        do { try await store.saveCapture(capture, expectedEpoch: epoch); XCTFail("Late purged capture restored") } catch {}
    }
}

@MainActor private final class PlacementScopeBox {
    var scope: PlacementRuntimeScope?; var now: Date
    init(scope: PlacementRuntimeScope, now: Date) { self.scope = scope; self.now = now }
}
@MainActor private final class PlacementFixtureService: PlacementServing {
    let household = "10000000-0000-4000-8000-000000000001", member = "10000000-0000-4000-8000-000000000002", shopID = "10000000-0000-4000-8000-000000000003"
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let shop: ShopperShop; let budget: ShopperBudget
    var pending: PlacementPendingReport!
    var detailReport: PlacementPendingReport?
    var shopError: Error?, reportError: Error?, reviewError: Error?, detailError: Error?
    var beforePrepareCapture: (() async throws -> Void)?
    var beforeReportSend: ((PlacementReportIntent) async throws -> Void)?
    var reportDisposition = "placed"
    var reportedStatus: PlacementReporterStatus?
    var shopReads = 0, prepareCaptures = 0, statusReads = 0
    var reportSends: [PlacementReportIntent] = [], reviewSends: [PlacementReviewIntent] = []
    init() throws {
        struct Shop: Encodable { let shopId: String; let shopRevision: Int; let authorityEpoch: Int; let phase: String; let quote: ShopperQuote; let lines: [ShopperBasketLine]; let frozenRevision: Int; let placedRevision: Int? }
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 5000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: now.addingTimeInterval(-300), expiresAt: now.addingTimeInterval(3600))
        let encoded = try JSONEncoder().encode(Shop(shopId: shopID, shopRevision: 4, authorityEpoch: 2, phase: "frozen", quote: quote, lines: [.init(originalItem: "Original oats", packs: 1, unitPriceMinor: 349, feeEligible: true)], frozenRevision: 4, placedRevision: nil))
        shop = try JSONDecoder().decode(ShopperShop.self, from: encoded)
        budget = try JSONDecoder().decode(ShopperBudget.self, from: Data("{\"currency\":\"USD\",\"totalMinor\":349,\"overCapMinor\":0,\"headroomMinor\":4651,\"status\":\"within\",\"scope\":\"wholeCheckout\",\"missing\":[],\"lowerBoundMinor\":349,\"upperBoundMinor\":349,\"wholeCheckoutWithinCap\":true}".utf8))
        pending = makePending()
    }
    func window() throws -> ReplayWindow { try JSONDecoder().decode(ReplayWindow.self, from: JSONEncoder().encode(["id": UUID().uuidString.lowercased(), "expiresAt": PlacementDate.string(now.addingTimeInterval(3600))])) }
    func prepared(subject: String = "adult", member: String? = nil) throws -> PlacementPreparedSnapshot {
        try .init(subject: subject, householdID: household, memberID: member ?? self.member, deviceID: "device", snapshot: shop, replayWindow: window(), capturedAt: PlacementDate.string(now.addingTimeInterval(-10)))
    }
    func makePending(revision: Int = 4, state: String = "pending_reconciliation", resolutionKey: String? = nil) -> PlacementPendingReport {
        .init(reportId: "10000000-0000-4000-8000-000000000004", shopId: shopID, reportedRevision: revision, reportedAuthorityEpoch: 1,
              occurredAt: PlacementDate.string(now.addingTimeInterval(-60)), receivedAt: PlacementDate.string(now), state: state,
              snapshot: .init(shopId: shopID, revision: revision, phase: "frozen", quote: shop.quote, lines: shop.lines, budget: budget),
              snapshotCreatedAt: PlacementDate.string(now.addingTimeInterval(-120)), snapshotDigest: String(repeating: "a", count: 64),
              resolutionOperationId: state == "pending_reconciliation" ? nil : "10000000-0000-4000-8000-000000000006", resolutionClientKey: resolutionKey)
    }
    func status(intent: PlacementReportIntent, state: String) -> PlacementReporterStatus {
        .init(clientKey: intent.id, operationId: "10000000-0000-4000-8000-000000000005", reportId: "10000000-0000-4000-8000-000000000004", shopId: shopID, reportedRevision: intent.prepared.snapshot.shopRevision, reportedAuthorityEpoch: intent.prepared.snapshot.authorityEpoch, occurredAt: intent.occurredAt, receivedAt: PlacementDate.string(now), state: state)
    }
    func placementShop(shopID: String) async throws -> ShopperShop { shopReads += 1; if let shopError { throw shopError }; return shop }
    func preparePlacementSnapshot(reviewed: ShopperShop) async throws -> PlacementPreparedSnapshot { prepareCaptures += 1; try await beforePrepareCapture?(); guard reviewed == shop else { throw ClientError.configuration }; return try prepared() }
    func executePlacementReport(_ intent: PlacementReportIntent) async throws -> PlacementReporterReceipt { try await beforeReportSend?(intent); reportSends.append(intent); if let reportError { throw reportError }; return .init(operationId: "10000000-0000-4000-8000-000000000005", reportId: "10000000-0000-4000-8000-000000000004", disposition: reportDisposition) }
    func placementReportStatus(_ intent: PlacementReportIntent) async throws -> PlacementReporterStatus? { statusReads += 1; return reportedStatus }
    func pendingPlacementReports(shopID: String, cursor: String?) async throws -> PlacementReportPage {
        .init(shopId: shopID, shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, phase: shop.phase, frozenRevision: shop.frozenRevision, reports: [pending], nextCursor: nil)
    }
    func placementReport(shopID: String, reportID: String) async throws -> PlacementReportDetail { if let detailError { throw detailError }; return .init(shopId: shopID, shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, phase: shop.phase, frozenRevision: shop.frozenRevision, report: detailReport ?? pending) }
    func preparePlacementReview(page: PlacementReportPage, report: PlacementPendingReport, choice: PlacementReviewChoice) async throws -> PlacementReviewIntent {
        try .init(subject: "adult", householdID: household, memberID: member, deviceID: "device", page: page, report: report, choice: choice, replayWindow: window())
    }
    func executePlacementReview(_ intent: PlacementReviewIntent) async throws -> PlacementReviewReceipt { reviewSends.append(intent); if let reviewError { throw reviewError }; return .init(operationId: "10000000-0000-4000-8000-000000000006", shopId: shopID, shopRevision: intent.base.shopRevision + (intent.choice == .apply ? 1 : 0), authorityEpoch: intent.base.authorityEpoch, disposition: intent.choice == .apply ? "placed" : "report_rejected", reportId: intent.report.reportId) }
}
private actor PlacementFaultStore: PlacementPersisting {
    let inner: PlacementPendingStore
    var sealFailure = false, receiptFailure = false
    init(inner: PlacementPendingStore) { self.inner = inner }
    func setSealFailure(_ value: Bool) { sealFailure = value }
    func setReceiptFailure(_ value: Bool) { receiptFailure = value }
    func epoch() async -> UUID { await inner.epoch() }
    func read() async throws -> PlacementStoredState { try await inner.read() }
    func purge() async throws { try await inner.purge() }
    func purge(householdID: String, subject: String) async throws { try await inner.purge(householdID: householdID, subject: subject) }
    func saveCapture(_ capture: PlacementPreparedSnapshot, expectedEpoch: UUID) async throws { try await inner.saveCapture(capture, expectedEpoch: expectedEpoch) }
    func discardUnreportedCapture(id: String, expectedEpoch: UUID) async throws { try await inner.discardUnreportedCapture(id: id, expectedEpoch: expectedEpoch) }
    func sealReport(_ intent: PlacementReportIntent, expectedEpoch: UUID) async throws { if sealFailure { throw ClientError.configuration }; try await inner.sealReport(intent, expectedEpoch: expectedEpoch) }
    func recordReportReceipt(id: String, receipt: PlacementReporterReceipt, expectedEpoch: UUID) async throws { if receiptFailure { throw ClientError.configuration }; try await inner.recordReportReceipt(id: id, receipt: receipt, expectedEpoch: expectedEpoch) }
    func recordReportStatus(id: String, status: PlacementReporterStatus, expectedEpoch: UUID) async throws { try await inner.recordReportStatus(id: id, status: status, expectedEpoch: expectedEpoch) }
    func saveReview(_ review: PlacementLocalReview, expectedEpoch: UUID) async throws { try await inner.saveReview(review, expectedEpoch: expectedEpoch) }
    func recordReviewReceipt(id: String, receipt: PlacementReviewReceipt, expectedEpoch: UUID) async throws { try await inner.recordReviewReceipt(id: id, receipt: receipt, expectedEpoch: expectedEpoch) }
    func recordReviewStatus(id: String, status: PlacementReportDetail, retire: Bool, expectedEpoch: UUID) async throws { try await inner.recordReviewStatus(id: id, status: status, retire: retire, expectedEpoch: expectedEpoch) }
}
