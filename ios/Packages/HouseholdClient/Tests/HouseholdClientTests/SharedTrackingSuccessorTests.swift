import Foundation
import XCTest
@testable import HouseholdClient

final class SharedTrackingSuccessorTests: XCTestCase {
    private typealias F = TrackingWriteFixture
    func testMoneyRequiredNullsAndScopeCannotDisappear() throws {
        for path in ["checkout", "checkout.totalMinor", "checkout.upperBoundMinor", "checkout.overCapMinor", "checkout.headroomMinor"] {
            XCTAssertThrowsError(try F.page(F.edit(F.fixture(), path, nil)))
        }
        let fixture = try F.scenario()
        for path in ["candidate.disclosure.money", "candidate.disclosure.money.before.totalMinor", "candidate.disclosure.money.after.headroomMinor"] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(fixture, path, nil) as! [String: Any]))
        }
        for (path, value): (String, Any) in [("candidate.disclosure.money.after.extra", true), ("candidate.disclosure.money.after.status", "probablyWithinCap"),
                                           ("candidate.disclosure.money.after.missing", ["estimated"]), ("candidate.disclosure.money.after.wholeCheckoutWithinCap", true)] {
            XCTAssertThrowsError(try F.candidateReview(F.edit(fixture, path, value) as! [String: Any]))
        }
    }
    func testMoneyBeforeUsesExactReadAndAcceptedAfterCannotChange() throws {
        let fixture = try F.scenario()
        XCTAssertThrowsError(try F.candidateReview(F.edit(fixture, "candidate.disclosure.money.before.lowerBoundMinor", 1) as! [String: Any]))
        XCTAssertThrowsError(try F.accepted(F.edit(fixture, "preview.disclosure.money.after.lowerBoundMinor", 1) as! [String: Any]))
        let value = try F.accepted(fixture)
        XCTAssertNil(value.preview.disclosure.money.after.totalMinor)
        XCTAssertFalse(value.preview.disclosure.money.after.wholeCheckoutWithinCap)
        XCTAssertFalse(value.preview.disclosure.pickup.coverage.completeFoodCoverage)
    }
    func testExplicitMoneyAcknowledgmentsDoNotSubstituteForEachOther() throws {
        let unknown: ShopperBudget = try F.decode(F.checkout)
        XCTAssertThrowsError(try SharedTrackingMoneyAcknowledgments(acceptOverage: true, acceptUnknown: false).validate(money: unknown))
        try SharedTrackingMoneyAcknowledgments(acceptOverage: false, acceptUnknown: true).validate(money: unknown)
        var over: Any = RequestUndoFixture.budget(1200)
        over = F.edit(over, "status", "overCap"); over = F.edit(over, "overCapMinor", 200); over = F.edit(over, "wholeCheckoutWithinCap", false)
        let overBudget: ShopperBudget = try F.decode(over)
        XCTAssertThrowsError(try SharedTrackingMoneyAcknowledgments(acceptOverage: false, acceptUnknown: true).validate(money: overBudget))
        try SharedTrackingMoneyAcknowledgments(acceptOverage: true, acceptUnknown: false).validate(money: overBudget)
        let within: ShopperBudget = try F.decode(RequestUndoFixture.budget(100))
        try SharedTrackingMoneyAcknowledgments(acceptOverage: false, acceptUnknown: false).validate(money: within)
        let fixture = try F.scenario()
        for path in ["preview.moneyAcknowledgments", "preview.moneyAcknowledgments.acceptUnknown", "preview.moneyAcknowledgments.acceptOverage"] {
            XCTAssertThrowsError(try F.accepted(F.edit(fixture, path, nil) as! [String: Any]))
        }
        XCTAssertThrowsError(try F.accepted(F.edit(fixture, "preview.moneyAcknowledgments.acceptUnknown", false) as! [String: Any]))
    }
    private func requestCatalog() throws -> (SharedTrackingPage, SharedDemandAction, ShopperPreview, [String: Any]) {
        let legacy = try F.scenario("adopt"), request = try F.scenario("request")
        let page: SharedTrackingPage = try F.decode(legacy["page"]!), candidate: SharedTrackingCandidate = try F.decode(request["candidate"]!)
        let preview: ShopperPreview = try F.decode(request["requestPreview"]!)
        let state = (request["candidate"] as! [String: Any])["after"] as! [String: Any]
        let facts = state["catalog"] as! [[String: Any]]
        let sources = facts.map { fact -> [String: Any] in var value = fact; value["productName"] = fact["originalText"]; return value }
        let value: [String: Any] = ["schemaVersion": 2, "shopId": page.shopId.string,
            "base": ["shopRevision": page.shopRevision, "authorityEpoch": page.authorityEpoch, "graphRevision": 0, "stateDigest": page.basisDigest.value],
            "normalizedAction": (request["candidate"] as! [String: Any])["action"]!, "actionDigest": String(repeating: "d", count: 64), "sources": sources]
        return (page, candidate.action.command, preview, value)
    }
    func testLegacyActionCatalogRequiresExplicitMutableRequestRevisionAndExactBasis() throws {
        let (page, action, preview, raw) = try requestCatalog(), catalog: SharedTrackingActionSources = try F.decode(raw)
        try catalog.validate(page: page, action: action, requestPreview: preview)
        XCTAssertThrowsError(try catalog.validate(page: page, action: action))
        let next: ShopperPreview = try F.decode(F.edit(try JSONSerialization.jsonObject(with: encoded(preview)), "requestRevision", preview.requestRevision + 1))
        XCTAssertThrowsError(try catalog.validate(page: page, action: action, requestPreview: next))
        XCTAssertThrowsError(try SharedTrackingActionSourceBase(page: F.page(F.fixture())))
        let changed: SharedTrackingActionSources = try F.decode(F.edit(raw, "base.stateDigest", String(repeating: "e", count: 64)))
        XCTAssertThrowsError(try changed.validate(page: page, action: action, requestPreview: preview))
    }
    func testActionCatalogStrictDescriptorsAndNoApplyGrant() throws {
        let (page, action, preview, raw) = try requestCatalog()
        for path in ["sources.0.revision", "sources.0.quantity", "sources.0.originalQuantityText", "sources.0.requiredLineId"] {
            XCTAssertThrowsError(try F.decode(F.edit(raw, path, nil), as: SharedTrackingActionSources.self))
        }
        for (path, value): (String, Any) in [("sources.0.extra", true), ("base.graphRevision", 1), ("sources.0.source.extra", true), ("normalizedAction.body.extra", true)] {
            XCTAssertThrowsError(try F.decode(F.edit(raw, path, value), as: SharedTrackingActionSources.self))
        }
        let catalog: SharedTrackingActionSources = try F.decode(raw)
        let kind = SharedTrackingIntentKind.adopt(action: action, change: .init(), packs: [])
        XCTAssertThrowsError(try SharedTrackingIntent(page: page, context: F.context, kind: kind, requestPreview: preview))
        _ = try SharedTrackingIntent(page: page, context: F.context, kind: kind, requestPreview: preview, actionSources: catalog)
        // Informational catalog is absent from the command candidate wire; the
        // service revalidates authoritative sources against the explicit action.
        let intent = try SharedTrackingIntent(page: page, context: F.context, kind: kind, requestPreview: preview, actionSources: catalog)
        let wire = try JSONSerialization.jsonObject(with: encoded(intent)) as! [String: Any]
        XCTAssertNil(wire["actionSources"]); XCTAssertNil(wire["actionDigest"])
    }
    func testRequestUndoPartitionKeepsProtectedIdentityAndFreshPacks() throws {
        let review = try RequestUndoFixture.review("partition")
        try review.validate()
        guard case .partition(let before) = review.candidate.foodBefore, case .partition(let after) = review.response.candidate.foodAfter else { return XCTFail("Partition disappeared") }
        XCTAssertTrue(Set(before.graph.usedIds).isSubset(of: Set(after.graph.usedIds)))
        XCTAssertEqual(after.packReviews, review.input.packs)
        XCTAssertEqual(review.candidate.requestUndo.originalQuantityText, "one large box")
        let raw = RequestUndoFixture.candidate("partition")
        for (path, value): (String, Any) in [("foodAfter.state.graph.usedIds", [F.id(10)]), ("foodAfter.state.privacyRevision", 6),
                                           ("foodBefore.state.catalog.0.source.appliedRequestRevision", 4), ("requestUndo.originalQuantityText", "")] {
            XCTAssertThrowsError(try F.decode(F.edit(raw, path, value), as: SharedRequestUndoCandidate.self))
        }
        let nullable: SharedRequestUndoCandidate = try F.decode(F.edit(raw, "requestUndo.originalQuantityText", NSNull()))
        XCTAssertNil(nullable.requestUndo.originalQuantityText)
    }
}

extension SharedTrackingSuccessorTests {
    func testCompoundUndoDisclosureSeparatesMealAndDedicatedRequestRouting() throws {
        typealias F = TrackingWriteFixture
        let original = try F.scenario("firstAdoptionUndo"), old = ((original["candidate"] as! [String: Any])["disclosure"] as! [String: Any])["changes"] as! [String: Any]
        let changes: [String: Any] = ["component": ["kind": "none"], "reversedAssertions": old["reversedAssertions"]!, "touchedBasket": [],
            "quote": ["before": F.quote(), "after": F.quote()], "beforeCoverage": old["beforeCoverage"]!, "afterCoverage": old["afterCoverage"]!, "mealUndo": NSNull()]
        let compound = F.edit(original, "candidate.disclosure.changes", changes) as! [String: Any]
        let review = try F.candidateReview(compound)
        guard case .compoundAdoptionUndo = review.candidate.disclosure.changes else { return XCTFail("Wrong Undo family") }
        XCTAssertThrowsError(try F.candidateReview(F.edit(compound, "candidate.disclosure.changes.mealUndo", nil) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(compound, "candidate.disclosure.changes.component", ["kind": "requestAcceptance", "requestId": F.id(90), "componentDigest": String(repeating: "a", count: 64)]) as! [String: Any]))
        XCTAssertThrowsError(try F.candidateReview(F.edit(compound, "candidate.disclosure.changes.reversedAssertions.contributions.0.originalText", "different assertion") as! [String: Any]))
        let meal: [String: Any] = ["title": "Simple dinner", "day": NSNull(), "kind": "dinner", "portions": 2, "protected": false]
        let fact: [String: Any] = ["revision": 7, "meal": meal]
        let mealUndo: [String: Any] = ["occurrenceId": F.id(99), "targetBefore": ["revision": NSNull(), "meal": NSNull()], "targetAfter": fact,
            "current": fact, "restoredMeal": NSNull(), "touchedFields": ["membership"], "proposal": NSNull()]
        var withMeal: Any = F.edit(compound, "candidate.disclosure.changes.component", ["kind": "meal", "occurrenceId": F.id(99), "componentDigest": String(repeating: "a", count: 64)])
        withMeal = F.edit(withMeal, "candidate.disclosure.changes.mealUndo", mealUndo)
        withMeal = F.edit(withMeal, "candidate.action.body.mealEdit", ["occurrenceId": F.id(99), "baseMealRevision": 7, "meal": NSNull()])
        _ = try F.candidateReview(withMeal as! [String: Any])
        XCTAssertThrowsError(try F.candidateReview(F.edit(withMeal, "candidate.action.body.mealEdit.occurrenceId", F.id(98)) as! [String: Any]))
    }
    func testMealActionCanonicalIDsPreserveHistoricalPendingWireAndRequiredNulls() throws {
        typealias F = TrackingWriteFixture
        let group = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        var raw: Any = F.action(F.fixture()["state"] as! [String: Any])
        raw = F.edit(raw, "body.mealEdit", ["occurrenceId": F.id(99), "baseMealRevision": NSNull(), "meal": ["title": "Dinner", "day": NSNull(), "kind": "dinner", "portions": 2, "protected": false,
            "planning": ["groups": [["id": group, "name": "Family", "servings": ["numerator": 2, "denominator": 1], "protected": false]], "ingredients": []]]])
        let decoded: SharedTrackingAction = try F.decode(raw)
        let authored = try SharedTrackingAction(decoded.command)
        XCTAssertEqual(authored, decoded)
        let upper = F.edit(raw, "body.mealEdit.meal.planning.groups.0.id", group.uppercased())
        let oldPending: SharedTrackingAction = try F.decode(upper)
        XCTAssertEqual(oldPending.command, decoded.command)
        XCTAssertEqual(oldPending.wire, try F.decode(upper, as: JSONValue.self))
        let oldBinding = try XCTUnwrap(F.pending().sharedTrackingBinding)
        let binding = SharedTrackingOperationBinding(kind: .apply, mode: "change", context: F.context, shopID: oldBinding.shopID, base: oldBinding.base,
            graphRevision: oldBinding.graphRevision, privacyRevision: oldBinding.privacyRevision, stateDigest: oldBinding.stateDigest,
            previewID: oldBinding.previewID, previewDigest: oldBinding.previewDigest, action: oldPending, targetOperationID: nil)
        var historicalBody = try oldPending.command.bodyValues() // r2's original encoding, including uppercase meal UUID.
        historicalBody["demandReview"] = .object(["previewId": .string(binding.previewID.string), "previewDigest": .string(binding.previewDigest), "trackingVersion": .integer(2)])
        let saved = try PendingOperation(envelope: .init(replayWindow: F.id(80), shopId: binding.shopID.string, kind: "shop.patch", base: binding.base, body: historicalBody),
            householdID: F.context.householdID, memberID: F.context.memberID, deviceID: F.context.deviceID, sharedTrackingBinding: binding)
        try binding.validate(saved)
        XCTAssertEqual(try binding.body(), historicalBody)
        let restored = try JSONDecoder().decode(PendingOperation.self, from: encoded(saved))
        try XCTUnwrap(restored.sharedTrackingBinding).validate(restored)
        XCTAssertEqual(restored.bytes, saved.bytes)

        XCTAssertThrowsError(try F.decode(F.edit(raw, "body.mealEdit.meal.day", nil), as: SharedTrackingAction.self))
        XCTAssertThrowsError(try F.decode(F.edit(raw, "body.mealEdit.meal.planning.groups.0.extra", true), as: SharedTrackingAction.self))
    }
}
