import XCTest
@testable import HouseholdClient

final class SharedOperationUndoTests: XCTestCase {
    func testCandidateCannotSupplyApplyAndPreviewBodyContainsOnlyExplicitAcknowledgments() throws {
        let review = try OperationUndoFixture.review()
        XCTAssertEqual(review.response.action.body.lines.first?.packs, 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(review.request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["targetOperationId", "effectDigest", "base", "packs"])
        XCTAssertThrowsError(try SharedOperationUndoPreviewRequest(candidate: review.candidate, packs: []))
        XCTAssertThrowsError(try SharedOperationUndoPreviewRequest(candidate: review.candidate, packs: [.init(lineId: review.candidate.packReviewLineIds[0], usablePerPack: nil, acceptUnresolved: false)]))
        XCTAssertNoThrow(try SharedOperationUndoPreviewRequest(candidate: review.candidate, packs: [.init(lineId: review.candidate.packReviewLineIds[0], usablePerPack: nil, acceptUnresolved: true)]))
    }
    func testHistoryRejectsUnknownReasonsAndMismatchedEligibility() throws {
        let page: SharedDemandPage = try OperationUndoFixture.value("page")
        let good: SharedOperationUndoHistory = try OperationUndoFixture.value("history")
        try good.validate(page: page, beforeRevision: nil)
        var history = try XCTUnwrap(OperationUndoFixture.object()["history"] as? [String: Any])
        var item = try XCTUnwrap((history["items"] as? [[String: Any]])?.first)
        item["eligibility"] = ["status": "unavailable", "reason": "future_silent_partial_undo"]
        history["items"] = [item]
        XCTAssertThrowsError(try OperationUndoFixture.decode(history, as: SharedOperationUndoHistory.self))
        item["eligibility"] = ["status": "unavailable", "reason": "explicit_current_preview_required"]; history["items"] = [item]
        XCTAssertThrowsError(try OperationUndoFixture.decode(history, as: SharedOperationUndoHistory.self).validate(page: page, beforeRevision: nil))
        XCTAssertThrowsError(try good.validate(page: page, beforeRevision: 5))
    }
    func testCandidateRejectsExtraActionAndUnsupportedOrHiddenScope() throws {
        let good = try OperationUndoFixture.review()
        var c = try XCTUnwrap(OperationUndoFixture.object()["candidate"] as? [String: Any])
        var action = try XCTUnwrap(c["action"] as? [String: Any]), body = try XCTUnwrap(action["body"] as? [String: Any])
        body["mealEdit"] = NSNull(); action["body"] = body; c["action"] = action
        XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self))
        c = try XCTUnwrap(OperationUndoFixture.object()["candidate"] as? [String: Any])
        var scope = try XCTUnwrap(c["scope"] as? [String: Any]); scope["mealsChanged"] = true; c["scope"] = scope
        XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self).validate(page: good.page, shop: good.shop, target: good.target))
        scope["mealsChanged"] = false; scope["touchedLines"] = []; c["scope"] = scope
        XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self).validate(page: good.page, shop: good.shop, target: good.target))
    }
    func testPreviewBindsExactEffectActionCheckoutReceiptAndCurrentGraph() throws {
        for key in ["effect", "action", "checkout", "receipt", "source"] {
            var f = try OperationUndoFixture.object(), response = try XCTUnwrap(f["response"] as? [String: Any])
            switch key {
            case "effect": var metadata = response["operationUndo"] as! [String: Any]; metadata["effectDigest"] = String(repeating: "d", count: 64); response["operationUndo"] = metadata
            case "action": var action = response["action"] as! [String: Any], body = action["body"] as! [String: Any], lines = body["lines"] as! [[String: Any]]; lines[0]["packs"] = 4; body["lines"] = lines; action["body"] = body; response["action"] = action
            case "checkout": var money = response["afterCheckout"] as! [String: Any]; money["totalMinor"] = 1; response["afterCheckout"] = money
            case "receipt": var receipt = response["receipt"] as! [String: Any]; receipt["resultRevision"] = 99; response["receipt"] = receipt
            default: var after = response["after"] as! [String: Any], sources = after["contributions"] as! [[String: Any]]; sources[0]["originalText"] = "Rewritten source"; after["contributions"] = sources; response["after"] = after
            }
            f["response"] = response; XCTAssertThrowsError(try OperationUndoFixture.review(f), key)
        }
    }
    func testCandidateRejectsStaleGraphDigestAndWrongTargetRevision() throws {
        let good = try OperationUndoFixture.review()
        let f = try OperationUndoFixture.object()
        var c = f["candidate"] as! [String: Any], base = c["base"] as! [String: Any]
        base["graphDigest"] = String(repeating: "d", count: 64); c["base"] = base
        XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self).validate(page: good.page, shop: good.shop, target: good.target))
        c = f["candidate"] as! [String: Any]; var scope = c["scope"] as! [String: Any]; scope["resultShopRevision"] = 6; c["scope"] = scope
        XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self).validate(page: good.page, shop: good.shop, target: good.target))
    }
    func testOnlyNewTombstoneTimestampsMayDifferBetweenCandidateAndFinalPreview() throws {
        var f = try OperationUndoFixture.object(), c = f["candidate"] as! [String: Any], response = f["response"] as! [String: Any]
        let before = c["before"] as! [String: Any]
        var after = c["after"] as! [String: Any], lines = after["lines"] as! [[String: Any]], sources = after["contributions"] as! [[String: Any]]
        lines[0]["trashedAt"] = "2026-11-09T12:10:00Z"; sources[0]["removedAt"] = "2026-11-09T12:10:00Z"
        after["lines"] = lines; after["contributions"] = sources
        var action = c["action"] as! [String: Any], body = action["body"] as! [String: Any], scope = c["scope"] as! [String: Any]
        body["lines"] = []; action["body"] = body
        scope["graphRows"] = 2; scope["touchedLines"] = [["lineId": lines[0]["id"]!, "fields": ["membership"]]]
        c["action"] = action; c["scope"] = scope; c["after"] = after; c["afterTotals"] = []; c["packReviewLineIds"] = []
        var money = c["afterCheckout"] as! [String: Any]
        for key in ["totalMinor", "lowerBoundMinor", "upperBoundMinor"] { money[key] = 0 }; money["headroomMinor"] = 1000
        c["afterCheckout"] = money; f["candidate"] = c; f["packs"] = []
        lines[0]["trashedAt"] = "2026-11-09T12:11:00Z"; sources[0]["removedAt"] = "2026-11-09T12:11:00Z"
        after["lines"] = lines; after["contributions"] = sources
        response["after"] = after; response["afterTotals"] = []; response["packs"] = []; response["action"] = action; response["afterCheckout"] = money
        var metadata = response["operationUndo"] as! [String: Any]; metadata["scope"] = scope; response["operationUndo"] = metadata
        var receipt = response["receipt"] as! [String: Any]
        receipt["lines"] = [["id": lines[0]["id"]!, "before": (before["lines"] as! [[String: Any]])[0], "after": lines[0]]]
        receipt["contributions"] = [["id": sources[0]["id"]!, "before": (before["contributions"] as! [[String: Any]])[0], "after": sources[0]]]
        response["receipt"] = receipt; f["response"] = response
        XCTAssertNoThrow(try OperationUndoFixture.review(f))
        sources[0]["originalText"] = "A changed fact cannot hide behind a timestamp"
        after["contributions"] = sources; response["after"] = after; f["response"] = response
        XCTAssertThrowsError(try OperationUndoFixture.review(f))
    }
    func testProtectedKnownQuantityCannotBecomeUnknownUnderUndo() throws {
        let f = try OperationUndoFixture.object()
        var c = f["candidate"] as! [String: Any], page = f["page"] as! [String: Any]
        var before = c["before"] as! [String: Any], old = (before["contributions"] as! [[String: Any]])[0]
        old["source"] = ["kind": "reservation", "reservationId": "00000000-0000-4000-8000-000000000020", "purpose": "Protected lunch", "originOccurrenceId": NSNull(), "ingredientId": "00000000-0000-4000-8000-000000000021", "groupId": NSNull(), "bindingId": NSNull()] as [String: Any]
        before["contributions"] = [old]; c["before"] = before; page["graph"] = before
        var after = c["after"] as! [String: Any]; old["quantity"] = NSNull(); after["contributions"] = [old]; c["after"] = after
        let candidate: SharedOperationUndoCandidate = try OperationUndoFixture.decode(c)
        XCTAssertThrowsError(try candidate.validate(page: OperationUndoFixture.decode(page), shop: OperationUndoFixture.decode(f["shop"]!), target: OperationUndoFixture.decode(f["target"]!)))
    }
    func testExistingOutboxRoundtripPreservesServerActionReservedReceiptAndExactBytes() async throws {
        let r = try OperationUndoFixture.review(), p = r.response.preview
        let binding = SharedDemandOperationBinding(context: r.context, shopID: r.page.shopId, reservedOperationID: p.receipt.operationId, previewID: p.previewId, previewDigest: p.previewDigest,
            action: r.response.action.commandAction, base: .init(shopRevision: p.shopRevision, authorityEpoch: p.authorityEpoch), graphRevision: p.after.revision)
        var body = try binding.action.bodyValues(); body["demandReview"] = .object(["previewId": .string(p.previewId.string), "previewDigest": .string(p.previewDigest)])
        let envelope = CommandEnvelope(replayWindow: UUID().uuidString.lowercased(), shopId: r.page.shopId.string, kind: "shop.patch", base: binding.base, body: body)
        let pending = try PendingOperation(envelope: envelope, householdID: r.context.householdID, memberID: r.context.memberID, deviceID: r.context.deviceID, sharedDemandBinding: binding)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json"), outbox = OperationOutbox(url: directory.appendingPathComponent("outbox.json"))
        try await outbox.append(pending); try await outbox.append(pending)
        let restored = try await OperationOutbox(url: url).operations()
        XCTAssertEqual(restored, [pending]); XCTAssertEqual(restored.first?.bytes, pending.bytes)
        XCTAssertEqual(try binding.validate(try XCTUnwrap(restored.first)), envelope)
        XCTAssertEqual(binding.reservedOperationID, p.receipt.operationId)
    }
}
