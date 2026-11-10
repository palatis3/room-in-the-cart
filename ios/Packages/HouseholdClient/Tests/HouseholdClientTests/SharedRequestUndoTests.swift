import Foundation
import XCTest
@testable import HouseholdClient

final class SharedRequestUndoTests: XCTestCase {
    private typealias F = RequestUndoFixture
    func testLegacyUndoKeepsDistinctRequestOutcomeAndBothCheckouts() throws {
        let review = try F.review()
        XCTAssertFalse(review.candidate.scope.quoteChanged)
        XCTAssertEqual(review.candidate.beforeCheckout.totalMinor, 400)
        XCTAssertEqual(review.candidate.afterCheckout.totalMinor, 100)
        XCTAssertEqual(review.candidate.requestUndo.restored.status, .pending)
        XCTAssertNil(review.candidate.requestUndo.afterLink)
        try review.validate()
    }
    func testTrackedPreviewNormalizesOnlyNewRetirementTimestampsAndChecksWholeReceipt() throws {
        let review = try F.review("tracked"); try review.validate()
        let original = F.candidate("tracked"), candidate: SharedRequestUndoCandidate = try F.decode(original)
        let input = try SharedRequestUndoPreviewInput(candidate: candidate, packs: F.packs(), acceptOverage: false, acceptUnknown: false)
        let preview = try F.preview(original)
        for (path, value): (String, Any) in [("candidate.foodAfter.graph.contributions.0.quantity.originalLiteral", "Changed unrelated food"),
                                           ("candidate.requestUndo.restored.route", "next"),
                                           ("foodReceipt.receipt.operationId", F.id(97)),
                                           ("candidate.action.body.lines.0.packs", 2)] {
            XCTAssertThrowsError(try SharedRequestUndoReview(context: TrackingWriteFixture.context, shop: F.shop(), candidate: candidate, input: input,
                response: F.decode(TrackingWriteFixture.edit(preview, path, value))))
        }
    }
    func testRequiredNullsAndUnknownFieldsCannotDisappearOrNormalizeAway() throws {
        let candidate = F.candidate()
        for path in ["requestUndo.afterLink", "requestUndo.originalQuantityText", "storeBasis", "beforeCheckout.totalMinor", "action.body.lines.0.unitPriceMinor"] {
            XCTAssertThrowsError(try SharedRequestUndoWire.candidate(from: F.bytes(TrackingWriteFixture.edit(candidate, path, nil))))
        }
        for (path, value): (String, Any) in [("foodAfter.kind", "futurePartition"), ("scope.firstAdoptionReversed", false),
                                           ("requestUndo.afterLink", candidate["requestUndo"]!), ("extra", true), ("base.food.extra", true)] {
            XCTAssertThrowsError(try SharedRequestUndoWire.candidate(from: F.bytes(TrackingWriteFixture.edit(candidate, path, value))))
        }
        let preview = try F.preview(candidate)
        XCTAssertThrowsError(try SharedRequestUndoWire.preview(from: F.bytes(TrackingWriteFixture.edit(preview, "foodReceipt.receipt", nil))))
    }
    func testPacksAndIndependentBudgetAcceptancesCoverWholeResult() throws {
        let candidate: SharedRequestUndoCandidate = try F.decode(F.candidate())
        XCTAssertThrowsError(try SharedRequestUndoPreviewInput(candidate: candidate, packs: [], acceptOverage: false, acceptUnknown: false))
        let line = SharedDemandID(UUID(uuidString: F.id(10))!)
        XCTAssertThrowsError(try SharedRequestUndoPreviewInput(candidate: candidate, packs: [.init(lineId: line, usablePerPack: nil, acceptUnresolved: false)], acceptOverage: false, acceptUnknown: false))
        var raw: Any = F.candidate(); raw = TrackingWriteFixture.edit(raw, "afterCheckout.status", "unresolved")
        raw = TrackingWriteFixture.edit(raw, "afterCheckout.wholeCheckoutWithinCap", false)
        let unknown: SharedRequestUndoCandidate = try F.decode(raw)
        XCTAssertThrowsError(try SharedRequestUndoPreviewInput(candidate: unknown, packs: F.packs(), acceptOverage: true, acceptUnknown: false))
        _ = try SharedRequestUndoPreviewInput(candidate: unknown, packs: F.packs(), acceptOverage: false, acceptUnknown: true)
    }
    func testTargetLinkAndMutableRequestRevisionCannotBeSubstituted() throws {
        for (path, value): (String, Any) in [("requestUndo.beforeLink.operationId", F.id(91)), ("action.body.baseRequestRevision", 3),
                                           ("requestUndo.restored.revision", 4), ("requestUndo.targetAfter.status", "pending")] {
            XCTAssertThrowsError(try SharedRequestUndoWire.candidate(from: F.bytes(TrackingWriteFixture.edit(F.candidate(), path, value))))
        }
    }
    func testLegacyOutboxWithoutNewBindingStillDecodesAndNewOperationBindsReservedReceipt() throws {
        let review = try F.review(), response = review.response
        let binding = SharedRequestUndoOperationBinding(context: review.context, shopID: review.candidate.shopId, targetOperationID: review.candidate.targetOperationId,
            reservedOperationID: response.operationId, previewID: response.previewId, previewDigest: response.previewDigest,
            base: .init(shopRevision: 8, authorityEpoch: 3, requestRevision: 4), action: response.candidate.action)
        let operation = try PendingOperation(envelope: .init(replayWindow: F.id(97), shopId: F.id(2), kind: "request.undoAcceptance", base: binding.base, body: binding.body()),
            householdID: review.context.householdID, memberID: review.context.memberID, deviceID: review.context.deviceID, sharedRequestUndoBinding: binding)
        try binding.validate(operation)
        let receipt: ShopperReceipt = try F.decode(["operationId": F.id(95), "kind": "request.undoAcceptance", "shopId": F.id(2), "shopRevision": 9,
            "authorityEpoch": 3, "disposition": "acceptanceUndone", "requestId": F.id(20), "requestRevision": 5])
        try binding.validateReceipt(receipt)
        let wrong: ShopperReceipt = try F.decode(["operationId": F.id(94), "kind": "request.undoAcceptance", "shopId": F.id(2), "shopRevision": 9,
            "authorityEpoch": 3, "disposition": "acceptanceUndone", "requestId": F.id(20), "requestRevision": 5])
        XCTAssertThrowsError(try binding.validateReceipt(wrong))
        var old = try JSONSerialization.jsonObject(with: encoded(operation)) as! [String: Any]
        old.removeValue(forKey: "sharedRequestUndoBinding")
        let legacy: PendingOperation = try F.decode(old); XCTAssertNil(legacy.sharedRequestUndoBinding)
        XCTAssertEqual(legacy.bytes, operation.bytes)
    }
}
