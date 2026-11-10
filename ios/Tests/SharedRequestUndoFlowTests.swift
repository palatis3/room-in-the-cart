import Foundation
import XCTest
import SwiftUI
@testable import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedRequestUndoFlowTests: XCTestCase {
    private typealias F = RequestUndoFlowFixture
    private final class Access: SharedRequestUndoFlowAccess {
        var trackingShop: ShopperShop?
        var trackingAllowed = true
        var trackingLease = UUID()
        var trackingPending = false
        var trackingSelectionID: UUID?
        let review: SharedRequestUndoReview
        let operation: PendingOperation
        var hold: String?
        var continuation: CheckedContinuation<Void, Never>?
        var arrived: (() -> Void)?
        var sends = 0
        init() throws {
            review = try F.review("partition"); trackingShop = review.shop
            let response = review.response
            let binding = SharedRequestUndoOperationBinding(context: review.context, shopID: review.candidate.shopId, targetOperationID: review.candidate.targetOperationId,
                reservedOperationID: response.operationId, previewID: response.previewId, previewDigest: response.previewDigest,
                base: .init(shopRevision: 8, authorityEpoch: 3, requestRevision: 4), action: response.candidate.action)
            operation = try .init(envelope: .init(replayWindow: F.id(80), shopId: F.id(2), kind: "request.undoAcceptance", base: binding.base, body: binding.body()),
                householdID: review.context.householdID, memberID: review.context.memberID, deviceID: review.context.deviceID, sharedRequestUndoBinding: binding)
        }
        func suspend(_ point: String) async {
            guard hold == point else { return }
            await withCheckedContinuation { continuation = $0; arrived?() }
        }
        func release() { continuation?.resume(); continuation = nil }
        func requestUndoHistory(shop: ShopperShop, beforeRevision: Int?) async throws -> SharedRequestUndoHistory {
            await suspend("history")
            return try F.decode(["schemaVersion": 1, "shopId": F.id(2), "shopRevision": 8, "authorityEpoch": 3, "items": [], "nextBeforeRevision": NSNull()])
        }
        func requestUndoCandidate(shop: ShopperShop, targetOperationID: SharedDemandID) async throws -> SharedRequestUndoCandidate { await suspend("candidate"); return review.candidate }
        func requestUndoPreview(shop: ShopperShop, candidate: SharedRequestUndoCandidate, packs: [SharedDemandPackReview], acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedRequestUndoReview { await suspend("preview"); return review }
        func requestUndoPrepare(_ review: SharedRequestUndoReview) async throws -> PendingOperation { await suspend("prepare"); return operation }
        func sendRequestUndo(_ operation: PendingOperation) async throws { XCTAssertEqual(operation, self.operation); sends += 1 }
        func readTracking(shopID: UUID) async throws -> SharedTrackingPage { throw ClientError.configuration }
        func trackingMealSources(page: SharedTrackingPage, action: SharedDemandAction) async throws -> SharedTrackingMealSources { throw ClientError.configuration }
        func trackingSources(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview?) async throws -> SharedTrackingActionSources { throw ClientError.configuration }
        func candidateTracking(page: SharedTrackingPage, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview?, actionSources: SharedTrackingActionSources?, mealSources: SharedTrackingMealSources?, transferredChanges: [SharedTrackingTransferredChange]?) async throws -> SharedTrackingCandidateReview { throw ClientError.configuration }
        func historyTracking(page: SharedTrackingPage) async throws -> SharedTrackingHistory { throw ClientError.configuration }
        func acceptTracking(_ candidate: SharedTrackingCandidateReview, acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedTrackingAcceptedReview { throw ClientError.configuration }
        func prepareTracking(_ accepted: SharedTrackingAcceptedReview) async throws -> PendingOperation { throw ClientError.configuration }
        func freezeTracking(page: SharedTrackingPage) async throws -> PendingOperation { throw ClientError.configuration }
        func sendTracking(_ operation: PendingOperation, selectionID: UUID?) async throws { throw ClientError.configuration }
    }
    func testHeldRequestUndoHistoryCannotPublishAfterLeaseChange() async throws {
        let access = try Access(), flow = SharedRequestUndoFlowModel(access: access)
        let arrived = expectation(description: "held request Undo history"); access.hold = "history"; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.load() }; await fulfillment(of: [arrived], timeout: 2)
        access.trackingLease = UUID(); access.release(); await task.value
        XCTAssertNil(flow.shop); XCTAssertTrue(flow.history.isEmpty); XCTAssertFalse(flow.busy)
    }
    func testHeldRequestUndoPreviewCannotRetainChangedPackOrMoneyChoices() async throws {
        let access = try Access(), flow = SharedRequestUndoFlowModel(access: access)
        await flow.load(target: access.review.candidate.targetOperationId)
        flow.gate.changes = true; flow.gate.pickup = true
        let arrived = expectation(description: "held request Undo preview"); access.hold = "preview"; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.preview() }; await fulfillment(of: [arrived], timeout: 2)
        flow.acceptOverage = true; access.release(); await task.value
        XCTAssertNil(flow.review); XCTAssertEqual(access.sends, 0)
    }
    func testHeldRequestUndoPreparationCannotSendAfterCancel() async throws {
        let access = try Access(), flow = SharedRequestUndoFlowModel(access: access)
        await flow.load(target: access.review.candidate.targetOperationId)
        flow.gate.changes = true; flow.gate.pickup = true; await flow.preview(); XCTAssertNotNil(flow.review)
        let arrived = expectation(description: "held request Undo Apply"); access.hold = "prepare"; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.apply() }; await fulfillment(of: [arrived], timeout: 2)
        flow.clear(); access.release(); await task.value
        XCTAssertEqual(access.sends, 0); XCTAssertNil(flow.review); XCTAssertNil(flow.candidate)
    }
    func testRequestUndoPackEditDropsExactAcceptedReviewAndBothAcknowledgments() async throws {
        let access = try Access(), flow = SharedRequestUndoFlowModel(access: access)
        await flow.load(target: access.review.candidate.targetOperationId)
        flow.gate.changes = true; flow.gate.pickup = true; await flow.preview(); XCTAssertNotNil(flow.review)
        flow.packs[0].usable.unknown = true
        XCTAssertNil(flow.review); XCTAssertFalse(flow.gate.canApply)
    }
}
