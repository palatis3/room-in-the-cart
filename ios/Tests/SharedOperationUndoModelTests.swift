import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedOperationUndoModelTests: XCTestCase {
    @MainActor private final class Access: SharedOperationUndoAccess {
        var foodShop: ShopperShop?
        var canReadFood = true
        var hasAuthority = true
        var foodPending = false
        var operationUndoIdentity: SharedOperationUndoAccessIdentity? {
            hasAuthority ? .init(householdID: fixture.context.householdID, memberID: fixture.context.memberID, shopID: fixture.page.shopId.string) : nil
        }
        var onLoadPublication: (() -> Void)?
        var historyValue: SharedOperationUndoHistory?
        var staleCandidate = false
        let fixture: SharedOperationUndoReview
        var previewCalls = 0, applies = 0, retries = 0, candidates = 0
        var retained: SharedOperationUndoReview?
        var appliedReview: SharedOperationUndoReview?
        var holdPreview = false, holdCandidate = false
        var continuation: CheckedContinuation<Void, Never>?
        init(_ facts: [String: Any]? = nil) throws {
            fixture = try OperationUndoFixture.review(facts); foodShop = fixture.shop
            if let facts { historyValue = try OperationUndoFixture.decode(facts["history"]!) }
        }
        func load() async { foodShop = fixture.shop; canReadFood = hasAuthority; onLoadPublication?() }
        func retry() async { retries += 1 }
        func readFood() async throws -> SharedDemandPage { fixture.page }
        func previewFood(_ request: SharedDemandPreviewRequest) async throws -> SharedDemandReview { throw ClientError.configuration }
        func applyFood(_ review: SharedDemandReview) async throws { throw ClientError.configuration }
        func operationHistory(page: SharedDemandPage, beforeRevision: Int?) async throws -> SharedOperationUndoHistory { try historyValue ?? OperationUndoFixture.value("history") }
        func operationUndoCandidate(page: SharedDemandPage, target: SharedOperationUndoHistoryItem) async throws -> SharedOperationUndoCandidate {
            candidates += 1
            if staleCandidate { throw ClientError.service(status: 409, code: "stale_demand", correlationID: nil, retryAfter: nil) }
            if holdCandidate { await withCheckedContinuation { continuation = $0 } }
            return fixture.candidate
        }
        func previewOperationUndo(page: SharedDemandPage, target: SharedOperationUndoHistoryItem, candidate: SharedOperationUndoCandidate, packs: [SharedDemandPackReview]) async throws -> SharedOperationUndoReview {
            previewCalls += 1
            if holdPreview { await withCheckedContinuation { continuation = $0 } }
            retained = fixture; return fixture
        }
        func applyOperationUndo(_ review: SharedOperationUndoReview) async throws { applies += 1; appliedReview = review; foodPending = true; retained = nil }
        func cancelOperationUndoReview() { retained = nil }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func selected(_ access: Access) async -> SharedOperationUndoModel {
        let model = SharedOperationUndoModel(access: access); await model.load(); await model.select(access.fixture.target); return model
    }
    private func held(_ access: Access) async throws {
        for _ in 0..<200 { if access.continuation != nil { return }; await Task.yield() }
        XCTFail("Expected held fixture response"); throw ClientError.configuration
    }
    func testUnavailableHistoryCannotStartCandidateReview() async throws {
        let access = try Access()
        var history = try OperationUndoFixture.object()["history"] as! [String: Any]
        var item = (history["items"] as! [[String: Any]])[0]
        item["eligibility"] = ["status": "unavailable", "reason": "food_undo_meal_action_unsupported"]; history["items"] = [item]
        access.historyValue = try OperationUndoFixture.decode(history)
        let model = SharedOperationUndoModel(access: access); await model.load()
        await model.select(try XCTUnwrap(model.history.first))
        XCTAssertEqual(access.candidates, 0); XCTAssertNil(model.candidate)
        XCTAssertFalse(SharedOperationUndoCopy.unavailable(.food_undo_meal_action_unsupported).isEmpty)
    }
    func testStaleCandidateClearsLoadedHistoryAndPrivateFacts() async throws {
        let access = try Access(), model = SharedOperationUndoModel(access: access)
        await model.load(); access.staleCandidate = true; await model.select(access.fixture.target)
        XCTAssertTrue(model.failed); XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.candidate); XCTAssertNil(model.currentShop)
        XCTAssertEqual(access.applies, 0)
    }
    func testChangedAlreadyBoundShopImmediatelyInvalidatesReview() async throws {
        let access = try Access(), model = await selected(access)
        var shop = try OperationUndoFixture.object()["shop"] as! [String: Any]; shop["shopRevision"] = 8
        access.foodShop = try OperationUndoFixture.decode(shop); model.accessChanged()
        XCTAssertNil(model.candidate); XCTAssertNil(model.currentShop); XCTAssertTrue(model.history.isEmpty)
    }
    func testInitialParentShopPublicationDoesNotCancelHistoryLoad() async throws {
        let access = try Access(); access.foodShop = nil; access.canReadFood = false
        let model = SharedOperationUndoModel(access: access)
        access.onLoadPublication = { model.accessChanged() }
        await model.load()
        XCTAssertEqual(model.history, [access.fixture.target]); XCTAssertFalse(model.busy)
    }
    func testAuthorityLostDuringInitialPublicationCancelsHistoryLoad() async throws {
        let access = try Access(); access.foodShop = nil; access.canReadFood = false
        let model = SharedOperationUndoModel(access: access)
        access.onLoadPublication = { access.hasAuthority = false; model.accessChanged() }
        await model.load()
        XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.currentShop); XCTAssertFalse(model.busy)
    }
    func testPendingPublicationClearsReviewButKeepsParentRetryState() async throws {
        let access = try Access(), model = await selected(access)
        try model.acknowledgePack(access.fixture.request.packs[0]); await model.preview()
        access.foodPending = true; model.accessChanged()
        XCTAssertTrue(model.pending); XCTAssertNil(model.review); XCTAssertNil(model.candidate)
        await model.retry(); XCTAssertEqual(access.retries, 1)
    }
    func testHistoryAndCandidateCancelAreReadOnlyAndClearCopiedSources() async throws {
        let access = try Access(), model = await selected(access)
        XCTAssertNotNil(model.candidate); XCTAssertEqual(access.candidates, 1)
        model.cancel()
        XCTAssertNil(model.candidate); XCTAssertNil(model.review); XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.packs.isEmpty); XCTAssertEqual(access.previewCalls, 0); XCTAssertEqual(access.applies, 0); XCTAssertNil(access.retained)
    }
    func testExplicitPacksAndSeparateMonetaryAcknowledgmentPrecedeApply() async throws {
        let access = try Access(), model = await selected(access)
        XCTAssertTrue(model.packs.isEmpty)
        try model.acknowledgePack(access.fixture.request.packs[0]); await model.preview()
        XCTAssertNotNil(model.review); await model.apply(); XCTAssertEqual(access.applies, 0)
        model.monetaryAcknowledged = true; await model.apply()
        XCTAssertEqual(access.applies, 1); XCTAssertTrue(model.pending); XCTAssertNil(model.review); XCTAssertNil(model.candidate)
    }
    func testMissingPackAcknowledgmentNeverRequestsPreview() async throws {
        let access = try Access(), model = await selected(access)
        await model.preview()
        XCTAssertEqual(access.previewCalls, 0); XCTAssertTrue(model.failed); XCTAssertNil(model.candidate)
    }
    func testCancelHeldPreviewCannotRestoreReviewOrApply() async throws {
        let access = try Access(), model = await selected(access)
        try model.acknowledgePack(access.fixture.request.packs[0]); access.holdPreview = true
        let task = Task { await model.preview() }; try await held(access)
        model.cancel(); access.release(); await task.value
        XCTAssertNil(model.review); XCTAssertNil(model.candidate); XCTAssertEqual(access.applies, 0)
    }
    func testPackEditDuringHeldPreviewInvalidatesOldReviewAndMoneyAcknowledgment() async throws {
        let access = try Access(), model = await selected(access)
        try model.acknowledgePack(access.fixture.request.packs[0]); access.holdPreview = true
        let task = Task { await model.preview() }; try await held(access)
        try model.acknowledgePack(.init(lineId: access.fixture.candidate.packReviewLineIds[0], usablePerPack: nil, acceptUnresolved: true))
        access.release(); await task.value
        XCTAssertNil(model.review); XCTAssertFalse(model.monetaryAcknowledged); XCTAssertEqual(access.applies, 0)
    }
    func testRevocationDuringHeldCandidateClearsPrivateState() async throws {
        let access = try Access(), model = SharedOperationUndoModel(access: access)
        await model.load(); access.holdCandidate = true
        let task = Task { await model.select(access.fixture.target) }; try await held(access)
        access.canReadFood = false; model.accessChanged(); access.release(); await task.value
        XCTAssertNil(model.candidate); XCTAssertTrue(model.history.isEmpty); XCTAssertEqual(access.applies, 0)
    }
    func testRelaunchWithExistingPendingUsesParentRetryWithoutCandidateOrPreview() async throws {
        let access = try Access(); access.foodPending = true
        let model = SharedOperationUndoModel(access: access); await model.load(); await model.retry()
        XCTAssertTrue(model.pending); XCTAssertEqual(access.retries, 1)
        XCTAssertEqual(access.candidates, 0); XCTAssertEqual(access.previewCalls, 0); XCTAssertTrue(model.history.isEmpty)
    }
    func testSkippedMealCancelClearsHistoricalMealAndPreservesReadOnlyCounters() async throws {
        let access = try Access(OperationUndoFixture.mealObject()), model = await selected(access)
        XCTAssertNil(model.candidate?.mealUndo?.current.meal)
        XCTAssertEqual(model.candidate?.mealUndo?.restoredMeal.title, "Original taco dinner")
        model.cancel()
        XCTAssertNil(model.candidate); XCTAssertNil(model.review); XCTAssertNil(model.currentShop)
        XCTAssertTrue(model.history.isEmpty); XCTAssertTrue(model.packs.isEmpty)
        XCTAssertEqual(access.applies, 0); XCTAssertEqual(access.previewCalls, 0)
    }
    func testSkippedMealApplyRequiresAllPacksAndPreservesCompleteRestorationAction() async throws {
        let access = try Access(OperationUndoFixture.mealObject()), model = await selected(access)
        for pack in access.fixture.request.packs { try model.acknowledgePack(pack) }
        await model.preview(); XCTAssertNotNil(model.review); await model.apply(); XCTAssertEqual(access.applies, 0)
        model.monetaryAcknowledged = true; await model.apply()
        XCTAssertEqual(access.applies, 1)
        XCTAssertEqual(access.appliedReview?.response.action.body.mealEdit, access.fixture.candidate.action.body.mealEdit)
        XCTAssertEqual(access.appliedReview?.response.preview.after.contributions.last, access.fixture.page.graph?.contributions.last)
        XCTAssertTrue(model.pending); XCTAssertNil(model.candidate); XCTAssertNil(model.review)
    }
    func testRevokedHeldMealCandidateCannotPublishHistoricalMealOrReservations() async throws {
        let access = try Access(OperationUndoFixture.mealObject()), model = SharedOperationUndoModel(access: access)
        await model.load(); access.holdCandidate = true
        let task = Task { await model.select(access.fixture.target) }; try await held(access)
        access.hasAuthority = false; access.canReadFood = false; model.accessChanged(); access.release(); await task.value
        XCTAssertNil(model.candidate); XCTAssertNil(model.review); XCTAssertNil(model.currentShop)
        XCTAssertTrue(model.history.isEmpty); XCTAssertTrue(model.packs.isEmpty); XCTAssertEqual(access.applies, 0)
    }
    func testRedactedHeldMealPreviewClearsEveryPrivateFactAndCannotApply() async throws {
        let access = try Access(OperationUndoFixture.mealObject()), model = await selected(access)
        for pack in access.fixture.request.packs { try model.acknowledgePack(pack) }
        access.holdPreview = true; let task = Task { await model.preview() }; try await held(access)
        access.foodShop = nil; access.canReadFood = false; model.accessChanged(); access.release(); await task.value
        model.monetaryAcknowledged = true; await model.apply()
        XCTAssertNil(model.candidate); XCTAssertNil(model.review); XCTAssertNil(model.currentShop)
        XCTAssertTrue(model.history.isEmpty); XCTAssertTrue(model.packs.isEmpty); XCTAssertEqual(access.applies, 0)
    }
    func testPendingMealRestorationRelaunchUsesOnlyExistingParentRetry() async throws {
        let access = try Access(OperationUndoFixture.mealObject()); access.foodPending = true
        let model = SharedOperationUndoModel(access: access); await model.load(); await model.retry()
        XCTAssertEqual(access.retries, 1); XCTAssertEqual(access.candidates, 0); XCTAssertEqual(access.previewCalls, 0)
        XCTAssertNil(model.candidate); XCTAssertNil(model.review); XCTAssertTrue(model.history.isEmpty)
    }
}
