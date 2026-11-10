import Foundation
import XCTest
import SwiftUI
@testable import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedTrackingFlowLeaseTests: XCTestCase {
    private final class Access: SharedTrackingFlowAccess {
        var trackingShop: ShopperShop?
        var trackingAllowed = true
        var trackingLease = UUID()
        var trackingPending = false
        var trackingSelectionID: UUID?
        let review: SharedTrackingCandidateReview
        let accepted: SharedTrackingAcceptedReview
        let operation: PendingOperation
        var hold: String?
        var continuation: CheckedContinuation<Void, Never>?
        var arrived: (() -> Void)?
        var prepares = 0, sends = 0
        var pageOverride: SharedTrackingPage?
        var mealCatalog: SharedTrackingMealSources?
        var savedHistory: SharedTrackingHistory?
        var capturedKind: SharedTrackingIntentKind?
        init(selectionID: UUID? = nil) throws {
            typealias F = TrackingFlowReviewFixture
            let fixture = try F.scenario()
            review = try F.candidateReview(fixture); accepted = try F.accepted(fixture)
            let state = review.page.state!, action = try F.action((fixture["page"] as! [String: Any])["state"] as! [String: Any])
            let body = action["body"] as! [String: Any]
            trackingShop = try F.decode(["shopId": state.graph.shopId.string, "shopRevision": 8, "authorityEpoch": 3, "phase": "draft",
                "lines": body["lines"]!, "quote": body["quote"]!, "meals": [], "frozenRevision": NSNull(), "placedRevision": NSNull()])
            let binding = SharedTrackingOperationBinding(kind: .apply, mode: "review", context: F.context, shopID: review.page.shopId,
                base: .init(shopRevision: 8, authorityEpoch: 3), graphRevision: 4, privacyRevision: 5,
                stateDigest: String(repeating: "b", count: 64), previewID: accepted.preview.previewId,
                previewDigest: accepted.preview.previewDigest.value, action: accepted.preview.action, targetOperationID: nil)
            operation = try .init(envelope: .init(replayWindow: F.id(98), shopId: F.id(2), kind: "shop.patch", base: binding.base,
                body: binding.body()), householdID: F.context.householdID, memberID: F.context.memberID,
                deviceID: F.context.deviceID, sharedTrackingBinding: binding)
            trackingSelectionID = selectionID
        }
        func suspend(_ point: String) async {
            guard hold == point else { return }
            await withCheckedContinuation { continuation = $0; arrived?() }
        }
        func release() { continuation?.resume(); continuation = nil }
        func readTracking(shopID: UUID) async throws -> SharedTrackingPage { await suspend("read"); return pageOverride ?? review.page }
        func candidateTracking(page: SharedTrackingPage, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview?, actionSources: SharedTrackingActionSources?, mealSources: SharedTrackingMealSources?, transferredChanges: [SharedTrackingTransferredChange]?) async throws -> SharedTrackingCandidateReview { capturedKind = kind; await suspend("candidate"); return review }
        func trackingMealSources(page: SharedTrackingPage, action: SharedDemandAction) async throws -> SharedTrackingMealSources {
            await suspend("mealSources"); return try XCTUnwrap(mealCatalog)
        }
        func trackingSources(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview?) async throws -> SharedTrackingActionSources { throw ClientError.configuration }
        func historyTracking(page: SharedTrackingPage) async throws -> SharedTrackingHistory { try XCTUnwrap(savedHistory) }
        func acceptTracking(_ candidate: SharedTrackingCandidateReview, acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedTrackingAcceptedReview { await suspend("accept"); return accepted }
        func prepareTracking(_ accepted: SharedTrackingAcceptedReview) async throws -> PendingOperation { prepares += 1; await suspend("prepare"); return operation }
        func freezeTracking(page: SharedTrackingPage) async throws -> PendingOperation { throw ClientError.configuration }
        func sendTracking(_ operation: PendingOperation, selectionID: UUID?) async throws {
            guard trackingSelectionID == selectionID else { throw ClientError.cancelled }; sends += 1
        }
    }
    func testMealHistorySelectsWholeMealUndoAndNeverRoutesRequestHistoryAsFoodUndo() async throws {
        typealias F = TrackingFlowReviewFixture
        let access = try Access(), flow = SharedTrackingFlowModel(access: access)
        await flow.load()
        let item: [String: Any] = ["operationId": F.id(90), "shopRevision": 7, "committedAt": "2026-11-10T12:00:00Z", "status": "current_preview_required", "reviewRoute": "trackingMeal"]
        access.savedHistory = try F.decode(["schemaVersion": 2, "shopId": F.id(2), "shopRevision": 8, "items": [item]])
        await flow.loadHistory(); await flow.undo(try XCTUnwrap(flow.history?.items.first))
        guard case .mealOperationUndo(let target, let packs) = access.capturedKind else { return XCTFail("Wrong operation family") }
        XCTAssertEqual(target.string, F.id(90)); XCTAssertFalse(packs.isEmpty); XCTAssertEqual(access.sends, 0)
        access.capturedKind = nil
        let other = F.edit(item, "reviewRoute", "requestAcceptance")
        access.savedHistory = try F.decode(["schemaVersion": 2, "shopId": F.id(2), "shopRevision": 8, "items": [other]])
        await flow.loadHistory(); await flow.undo(try XCTUnwrap(flow.history?.items.first))
        XCTAssertNil(access.capturedKind); XCTAssertEqual(access.sends, 0)
        access.savedHistory = try F.decode(["schemaVersion": 2, "shopId": F.id(2), "shopRevision": 8, "items": [F.edit(item, "status", "unavailable")]])
        await flow.loadHistory(); await flow.undo(try XCTUnwrap(flow.history?.items.first))
        XCTAssertNil(access.capturedKind); XCTAssertEqual(access.sends, 0)
    }
    func testHeldMealCatalogCannotPublishAfterCancelOrShopperLeaseChange() async throws {
        for cancel in [false, true] {
            let (page, shop, catalog, edit, _) = try TrackingPartialMealFixture.setup(TrackingPartialMealFixture.fixture())
            let access = try Access(); access.pageOverride = page; access.trackingShop = shop; access.mealCatalog = catalog
            let flow = SharedTrackingFlowModel(access: access, mealEdit: edit)
            let arrived = expectation(description: "held meal catalog")
            access.hold = "mealSources"; access.arrived = { arrived.fulfill() }
            let task = Task { await flow.load() }; await fulfillment(of: [arrived], timeout: 2)
            if cancel { flow.clear() } else { access.trackingLease = UUID() }
            access.release(); await task.value
            XCTAssertNil(flow.page); XCTAssertNil(flow.mealSources); XCTAssertNil(flow.draft.mealChanges)
            XCTAssertNil(flow.candidate); XCTAssertEqual(access.sends, 0)
        }
    }
    func testMealBindingChangeRequiresNewMatchAndRetainedControlsCannotSurviveCancel() async throws {
        let (page, shop, catalog, edit, _) = try TrackingPartialMealFixture.setup(TrackingPartialMealFixture.fixture())
        let access = try Access(); access.pageOverride = page; access.trackingShop = shop; access.mealCatalog = catalog
        let flow = SharedTrackingFlowModel(access: access, mealEdit: edit)
        await flow.load(); XCTAssertNotNil(flow.draft.mealChanges)
        let id = try XCTUnwrap(flow.draft.mealChanges?.rows.first { $0.canBind }?.id)
        let line = flow.mealLineEntry(id: id), confirmed = flow.mealRowEntry(\.rows, id: id, path: \.productConfirmed, empty: false)
        let reviewed = flow.mealEntry(\.reviewed, empty: false)
        line.wrappedValue = page.state?.basket.first?.id; confirmed.wrappedValue = true; reviewed.wrappedValue = true
        XCTAssertTrue(confirmed.wrappedValue); XCTAssertTrue(reviewed.wrappedValue)
        line.wrappedValue = nil
        XCTAssertFalse(confirmed.wrappedValue); XCTAssertFalse(reviewed.wrappedValue)
        line.wrappedValue = page.state?.basket.first?.id; confirmed.wrappedValue = true; reviewed.wrappedValue = true
        flow.clear()
        XCTAssertNil(line.wrappedValue); XCTAssertFalse(confirmed.wrappedValue); XCTAssertFalse(reviewed.wrappedValue)
        line.wrappedValue = page.state?.basket.first?.id; confirmed.wrappedValue = true; reviewed.wrappedValue = true
        XCTAssertNil(flow.draft.mealChanges); XCTAssertNil(flow.candidate); XCTAssertEqual(access.sends, 0)
    }
    func testHeldLoadCannotPublishAfterEditorSelectionWasInvalidated() async throws {
        let selection = UUID(), access = try Access(selectionID: selection)
        let flow = SharedTrackingFlowModel(access: access, selectionID: selection)
        let arrived = expectation(description: "held read"); access.hold = "read"; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.load() }; await fulfillment(of: [arrived], timeout: 2)
        access.trackingSelectionID = nil; access.release(); await task.value
        XCTAssertNil(flow.page); XCTAssertNil(flow.shop); XCTAssertEqual(access.sends, 0)
    }
    func testHeldCandidateCannotSurviveDraftCancellationOrSameShopReselection() async throws {
        let access = try Access(), flow = SharedTrackingFlowModel(access: access)
        await flow.load()
        let arrived = expectation(description: "held candidate"); access.hold = "candidate"; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.preview() }; await fulfillment(of: [arrived], timeout: 2)
        flow.clear(); access.trackingLease = UUID(); access.release(); await task.value
        XCTAssertNil(flow.candidate); XCTAssertFalse(flow.gate.canApply); XCTAssertEqual(access.sends, 0)
    }
    func testHeldAcceptCannotPrepareAfterRequestAckOrEditorChoiceInvalidation() async throws { try await invalidation(point: "accept") }
    func testHeldPrepareCannotDispatchAfterRequestAckOrEditorChoiceInvalidation() async throws { try await invalidation(point: "prepare") }
    private func invalidation(point: String) async throws {
        let selection = UUID(), access = try Access(selectionID: selection)
        let flow = SharedTrackingFlowModel(access: access, selectionID: selection)
        await flow.load(); await flow.preview(); XCTAssertNotNil(flow.candidate)
        flow.gate.changes = true; flow.gate.pickup = true; flow.acceptUnknown = true
        let arrived = expectation(description: "held " + point); access.hold = point; access.arrived = { arrived.fulfill() }
        let task = Task { await flow.apply() }; await fulfillment(of: [arrived], timeout: 2)
        // This is the synchronous invalidation performed by both parent owners.
        // No SwiftUI onChange callback is invoked before releasing the response.
        access.trackingSelectionID = nil; access.release(); await task.value
        XCTAssertFalse(flow.permitted); XCTAssertEqual(access.sends, 0)
        XCTAssertEqual(access.prepares, point == "accept" ? 0 : 1)
    }
    func testEditedDraftDropsBothAcknowledgementsAndExactCandidate() async throws {
        let access = try Access(), flow = SharedTrackingFlowModel(access: access)
        await flow.load(); await flow.preview(); XCTAssertNotNil(flow.candidate)
        flow.gate.changes = true; flow.gate.pickup = true; flow.acceptUnknown = true
        flow.draft.manual.enabled = true
        XCTAssertNil(flow.candidate); XCTAssertFalse(flow.gate.canApply)
    }
    func testRetainedManualBindingRedactsAfterCancelOrLeaseLossAndCannotWriteNewDraft() async throws {
        for cancel in [false, true] {
            let access = try Access(), flow = SharedTrackingFlowModel(access: access)
            await flow.load()
            flow.draft.manual.enabled = true; flow.draft.manual.name = "Private food name"
            flow.draft.manual.original = "Private author wording"; flow.draft.manual.contains = "private-tag"
            flow.draft.manual.exclusions = "private-exclusion"; flow.draft.manual.productConfirmed = true
            flow.draft.manual.amount.unknown = false; flow.draft.manual.amount.numerator = "7"
            let id = flow.draft.manual.id
            let binding = flow.row(\.manuals, id: id, empty: TrackingManualEntry(id: id))
            XCTAssertEqual(binding.wrappedValue.original, "Private author wording")
            if cancel { flow.clear() } else { access.trackingLease = UUID() }
            let redacted = binding.wrappedValue
            XCTAssertEqual(redacted.id, id); XCTAssertEqual(binding.wrappedValue.id, id)
            XCTAssertTrue(redacted.name.isEmpty); XCTAssertTrue(redacted.original.isEmpty)
            XCTAssertTrue(redacted.contains.isEmpty); XCTAssertTrue(redacted.exclusions.isEmpty)
            XCTAssertTrue(redacted.amount.unknown); XCTAssertTrue(redacted.amount.numerator.isEmpty)
            XCTAssertFalse(redacted.enabled); XCTAssertFalse(redacted.productConfirmed); XCTAssertNil(redacted.lineID)
            let unchanged = flow.draft
            var replacement = redacted; replacement.name = "Stale write"; replacement.enabled = true
            binding.wrappedValue = replacement
            XCTAssertEqual(flow.draft, unchanged); XCTAssertEqual(access.sends, 0)
        }
    }
    func testCancelDropsEveryAuthoredManualRowAndReviewWithoutSending() async throws {
        let access = try Access(), flow = SharedTrackingFlowModel(access: access)
        await flow.load()
        flow.draft.manuals = (0..<3).map { index in
            var row = TrackingManualEntry(); row.enabled = true; row.name = "Authored \(index)"; row.original = "Private words \(index)"; return row
        }
        flow.gate.changes = true; flow.gate.pickup = true
        flow.clear()
        XCTAssertEqual(flow.draft.manuals.count, 1); XCTAssertTrue(flow.draft.manual.name.isEmpty)
        XCTAssertTrue(flow.draft.manual.original.isEmpty); XCTAssertFalse(flow.draft.manual.enabled)
        XCTAssertNil(flow.page); XCTAssertNil(flow.candidate); XCTAssertFalse(flow.gate.canApply)
        XCTAssertEqual(access.sends, 0); XCTAssertEqual(access.prepares, 0)
    }
    func testHeldMoneyAcceptanceCannotDispatchAfterIndependentChoiceChanges() async throws {
        for point in ["accept", "prepare"] {
            let access = try Access(), flow = SharedTrackingFlowModel(access: access)
            await flow.load(); await flow.preview()
            flow.gate.changes = true; flow.gate.pickup = true; flow.acceptUnknown = true
            let arrived = expectation(description: "held money " + point); access.hold = point; access.arrived = { arrived.fulfill() }
            let task = Task { await flow.apply() }; await fulfillment(of: [arrived], timeout: 2)
            // The resulting budget remains permitted, but this is a different
            // explicit choice than the one awaiting its server response.
            flow.acceptOverage = true; access.release(); await task.value
            XCTAssertEqual(access.sends, 0); XCTAssertEqual(access.prepares, point == "accept" ? 0 : 1)
        }
    }
    func testFullPickupAcknowledgementAloneDoesNotAcceptUnknownMoney() async throws {
        let access = try Access(), flow = SharedTrackingFlowModel(access: access)
        await flow.load(); await flow.preview(); flow.gate.changes = true; flow.gate.pickup = true
        XCTAssertFalse(flow.moneyAccepted); await flow.apply(); XCTAssertEqual(access.sends, 0); XCTAssertEqual(access.prepares, 0)
        flow.acceptUnknown = true; XCTAssertTrue(flow.moneyAccepted)
    }

}
