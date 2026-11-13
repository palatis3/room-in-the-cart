import Foundation
import XCTest
@testable import HouseholdClient

final class SharedTrackingMealTests: XCTestCase {
    typealias M = TrackingMealFixture
    typealias F = TrackingWriteFixture
    func testEnabledCatalogKeepsDistinctFactAndContributionIdentitiesAndAllFourLocations() throws {
        let raw = try M.fixture(), page: SharedTrackingPage = try F.decode(raw["page"]!), catalog: SharedTrackingMealSources = try F.decode(raw["catalog"]!)
        try catalog.validate(page: page, action: catalog.normalizedAction.command)
        XCTAssertEqual(catalog.sources.map(\.location), [.tracked, .transferred, .unbound, .new])
        XCTAssertNotEqual(catalog.sources[0].factId, catalog.sources[0].proposed.id)
        XCTAssertNotEqual(catalog.sources[1].factId, catalog.sources[1].proposed.id)
        XCTAssertNil(catalog.sources[2].before); XCTAssertNil(catalog.sources[3].before)
        let review = try M.review(raw)
        XCTAssertEqual(review.candidate.after.unbound.map(\.factId.string), [F.id(24), F.id(25), F.id(26)])
        XCTAssertTrue(review.candidate.disclosure.pickup.coverage.allocatableUnboundFactIds.isEmpty)
        let wire = try JSONSerialization.jsonObject(with: encoded(review.intent)) as! [String: Any]
        XCTAssertNil(wire["mealSources"]); XCTAssertNil(wire["proposedCatalog"]); XCTAssertNil(wire["actionDigest"])
        XCTAssertNil(wire["transferredChanges"])
    }
    func testReviewedConversionAndRestrictionMappingRemainOnRowsWithoutChangingAuthoritativeFacts() throws {
        var raw: Any = try M.fixture()
        let conversion: [String: Any] = ["sourceUnit": "count", "targetUnit": "gram", "targetAmountPerSourceUnit": ["numerator": "100", "denominator": "1"], "sourceNote": "Measured one item", "confirmedAt": "2026-11-10T00:00:00Z"]
        for path in ["page.state.graph.contributions.1.quantity.confirmedConversion", "catalog.sources.0.before.quantity.confirmedConversion", "catalog.sources.0.proposed.quantity.confirmedConversion"] { raw = F.edit(raw, path, conversion) }
        let resolution: [String: Any] = ["kind": "mapped", "tags": ["dairy"], "confirmedAt": "2026-11-10T00:00:00Z"]
        for path in ["page.state.unbound.0.transferred.sourceExclusions.0.resolution", "catalog.sources.1.before.sourceExclusions.0.resolution", "catalog.sources.1.proposed.sourceExclusions.0.resolution"] { raw = F.edit(raw, path, resolution) }
        for path in ["page.state.unbound.0.transferred.exclusions", "catalog.sources.1.before.exclusions"] { raw = F.edit(raw, path, ["dairy"]) }
        let values = raw as! [String: Any], page: SharedTrackingPage = try F.decode(values["page"]!), catalog: SharedTrackingMealSources = try F.decode(values["catalog"]!)
        try catalog.validate(page: page, action: catalog.normalizedAction.command)
        XCTAssertNotNil(catalog.sources[0].proposed.quantity?.confirmedConversion)
        XCTAssertNil(catalog.proposedCatalog.first { $0.id.string == F.id(32) }?.quantity?.confirmedConversion)
        XCTAssertNotEqual(catalog.sources[1].proposed.sourceExclusions, catalog.proposedCatalog.first { $0.id.string == F.id(24) }?.sourceExclusions)
        let wrong: SharedTrackingMealSources = try F.decode(F.edit(values["catalog"]!, "sources.1.proposed.sourceExclusions.0.label", "Another author's restriction"))
        XCTAssertThrowsError(try wrong.validate(page: page, action: catalog.normalizedAction.command))
    }
    func testEnabledCatalogRejectsOmittedNullUnknownFieldsAndInventedLocation() throws {
        let raw = try M.fixture()["catalog"]!
        for path in ["mealChange.before", "mealChange.after.meal", "sources.2.before", "sources.1.proposed.quantity", "sources.1.proposed.originalQuantityText", "sources.2.proposed.requiredLineId"] {
            XCTAssertThrowsError(try F.decode(F.edit(raw, path, nil), as: SharedTrackingMealSources.self), path)
        }
        for (path, value): (String, Any) in [("sources.2.location", "freeSupply"), ("sources.0.before.quantity.extra", true),
            ("sources.0.proposed.quantity.extra", true), ("mealChange.before.meal.extra", true), ("sources.0.extra", true), ("base.extra", 1), ("mealChange.after.revision", 0)] {
            XCTAssertThrowsError(try F.decode(F.edit(raw, path, value), as: SharedTrackingMealSources.self), path)
        }
    }
    func testEnabledCatalogRejectsForeignMappingsMissingPartitionsStaleStateAndChangedUnrelatedFacts() throws {
        let raw = try M.fixture(), page: SharedTrackingPage = try F.decode(raw["page"]!), original: SharedTrackingMealSources = try F.decode(raw["catalog"]!)
        for (path, value): (String, Any) in [("sources.0.factId", F.id(30)), ("sources.1.location", "tracked"), ("sources.2.location", "new"),
            ("retainedContributionIds", []), ("beforeCoverage.allocatableUnboundFactIds", [F.id(24)]),
            ("base.stateDigest", String(repeating: "e", count: 64)), ("proposedCatalog.1.originalText", "Replaced protected wording") ] {
            XCTAssertThrowsError(try {
                let next: SharedTrackingMealSources = try F.decode(F.edit(raw["catalog"]!, path, value))
                try next.validate(page: page, action: original.normalizedAction.command)
            }(), path)
        }
        let legacy = try F.scenario("adopt"), legacyPage: SharedTrackingPage = try F.decode(legacy["page"]!)
        XCTAssertThrowsError(try SharedTrackingMealSourceRequest(page: legacyPage, action: original.normalizedAction.command))
    }
    func testExplicitDetachedQuantificationKeepsUsedIDAndRequiresSeparateIntent() throws {
        let raw = try M.fixture(quantify: true), review = try M.review(raw), intent = review.intent
        let input = try XCTUnwrap(intent.transferredChanges?.first), after = try XCTUnwrap(input.after)
        XCTAssertEqual(input.factId.string, F.id(24)); XCTAssertEqual(after.id.string, F.id(22))
        XCTAssertTrue(review.candidate.after.graph.usedIds.contains(after.id)); XCTAssertFalse(review.candidate.after.graph.contributions.contains { $0.id == after.id })
        let wire = try JSONSerialization.jsonObject(with: encoded(intent)) as! [String: Any]
        XCTAssertEqual((wire["transferredChanges"] as! [[String: Any]])[0]["factId"] as? String, F.id(24))
        guard case .change(let action, _, let packs, let unbound) = intent.kind else { return XCTFail() }
        XCTAssertThrowsError(try SharedTrackingIntent(page: review.page, context: F.context,
            kind: .change(action: action, change: .init(), packs: packs, unboundFactIds: unbound), mealSources: intent.mealSources, transferredChanges: intent.transferredChanges))
        var wrong = after; wrong.id = input.factId
        XCTAssertThrowsError(try SharedTrackingIntent(page: review.page, context: F.context, kind: intent.kind, mealSources: intent.mealSources,
            transferredChanges: [.init(factId: input.factId, after: wrong)]))
        XCTAssertThrowsError(try SharedTrackingIntent(page: review.page, context: F.context, kind: intent.kind, mealSources: intent.mealSources,
            transferredChanges: [.init(factId: input.factId, after: nil)]))
        let encodedNull = try JSONSerialization.jsonObject(with: encoded(SharedTrackingTransferredChange(factId: input.factId, after: nil))) as! [String: Any]
        XCTAssertTrue(encodedNull["after"] is NSNull)
    }
    func testFullMealDisclosureCannotDisappearOrDifferFromAcceptedCatalog() throws {
        let raw = try M.fixture(), review = try M.review(raw)
        guard case .mealActionChange(let change) = review.candidate.disclosure.changes else { return XCTFail() }
        XCTAssertEqual(change.mealChange.before?.meal?.title, "Original lunch")
        XCTAssertEqual(change.mealChange.after.meal?.title, "Changed lunch")
        for (path, value): (String, Any) in [("candidate.disclosure.changes", NSNull()), ("candidate.disclosure.changes.mealChange.before.meal.title", "Other history"),
            ("candidate.disclosure.changes.mealChange.after.meal.title", "Other result"), ("candidate.disclosure.changes.kind", "mealTransferChange")] {
            XCTAssertThrowsError(try M.review(F.edit(raw, path, value) as! [String: Any]), path)
        }
        _ = try SharedTrackingAcceptedReview(candidateReview: review, preview: F.decode(raw["preview"]!))
        XCTAssertThrowsError(try SharedTrackingAcceptedReview(candidateReview: review,
            preview: F.decode(F.edit(raw["preview"]!, "disclosure.changes.mealChange.before.meal.title", "Changed after acknowledgment"))))
    }
    func testInitialMealAdoptionAlsoRequiresFullServerMealDisclosure() throws {
        let raw = try F.scenario("adopt"), page: SharedTrackingPage = try F.decode(raw["page"]!)
        var candidate = raw["candidate"] as! [String: Any]
        let action = F.edit(candidate["action"]!, "body.mealEdit", ["occurrenceId": F.id(99), "baseMealRevision": NSNull(), "meal": M.meal("New lunch")])
        candidate["action"] = action
        let change: [String: Any] = ["kind": "mealActionChange", "mealChange": ["occurrenceId": F.id(99), "before": NSNull(), "after": ["revision": 9, "meal": M.meal("New lunch")]], "transferredChanges": []]
        candidate = F.edit(candidate, "disclosure.changes", change) as! [String: Any]
        let value: SharedTrackingCandidate = try F.decode(candidate)
        let catalog: SharedTrackingActionSources = try F.decode(["schemaVersion": 2, "shopId": F.id(2),
            "base": ["shopRevision": 8, "authorityEpoch": 3, "graphRevision": 0, "stateDigest": page.basisDigest.value],
            "normalizedAction": action, "actionDigest": String(repeating: "f", count: 64), "sources": []])
        let intent = try SharedTrackingIntent(page: page, context: F.context,
            kind: .adopt(action: value.action.command, change: .init(lines: value.after.graph.lines, contributions: value.after.graph.contributions), packs: value.after.packReviews), actionSources: catalog)
        _ = try SharedTrackingCandidateReview(page: page, intent: intent, candidate: value)
        XCTAssertThrowsError(try SharedTrackingCandidateReview(page: page, intent: intent, candidate: F.decode(F.edit(candidate, "disclosure.changes", NSNull()))))
        XCTAssertThrowsError(try F.decode(F.edit(candidate, "disclosure.changes.mealChange.before", nil), as: SharedTrackingCandidate.self))
    }
    func testWholeMealUndoRequiresExactTargetAndCompleteInverseDisclosure() throws {
        let raw = try M.inverse(), review = try M.inverseReview(raw)
        guard case .mealOperationUndo(let undo) = review.candidate.disclosure.changes else { return XCTFail() }
        XCTAssertEqual(undo.targetOperationId.string, F.id(90)); XCTAssertEqual(undo.mealUndo.restoredMeal?.title, "Before title")
        let wire = try JSONSerialization.jsonObject(with: encoded(review.intent)) as! [String: Any]
        XCTAssertEqual(Set(wire.keys), ["mode", "base", "targetOperationId", "packs"])
        XCTAssertEqual(wire["mode"] as? String, "mealOperationUndo")
        for (path, value): (String, Any) in [("candidate.disclosure.changes.targetOperationId", F.id(91)), ("candidate.disclosure.changes.graphRows", 1),
            ("candidate.disclosure.changes.mealUndo.current.meal.title", "Unrelated current meal"), ("candidate.action.body.mealEdit.occurrenceId", F.id(98))] {
            XCTAssertThrowsError(try M.inverseReview(F.edit(raw, path, value) as! [String: Any]), path)
        }
        for path in ["candidate.disclosure.changes.mealUndo", "candidate.disclosure.changes.transferredChanges", "candidate.disclosure.changes.quote.before"] {
            XCTAssertThrowsError(try M.inverseReview(F.edit(raw, path, nil) as! [String: Any]), path)
        }
    }
    func testMealHistoryRouteAndSavedUndoPreserveExactCommandBytes() throws {
        let raw = try M.inverse(), review = try M.inverseReview(raw), accepted = try SharedTrackingAcceptedReview(candidateReview: review, preview: F.decode(raw["preview"]!))
        let item: [String: Any] = ["operationId": F.id(90), "shopRevision": 7, "committedAt": "2026-11-10T00:00:00Z", "status": "current_preview_required", "reviewRoute": "trackingMeal"]
        let route: SharedTrackingHistoryItem = try F.decode(item); XCTAssertEqual(route.reviewRoute, .trackingMeal)
        XCTAssertThrowsError(try F.decode(F.edit(item, "reviewRoute", "mealMaybe"), as: SharedTrackingHistoryItem.self))
        let binding = SharedTrackingOperationBinding(kind: .apply, mode: "mealOperationUndo", context: F.context, shopID: review.page.shopId,
            base: .init(shopRevision: 8, authorityEpoch: 3), graphRevision: 4, privacyRevision: 5,
            stateDigest: accepted.preview.disclosure.pickup.stateDigest.value, previewID: accepted.preview.previewId,
            previewDigest: accepted.preview.previewDigest.value, action: accepted.preview.action, targetOperationID: route.operationId)
        let operation = try PendingOperation(envelope: .init(replayWindow: F.id(80), shopId: F.id(2), kind: "shop.patch", base: binding.base, body: binding.body()),
            householdID: F.context.householdID, memberID: F.context.memberID, deviceID: F.context.deviceID, sharedTrackingBinding: binding)
        let saved = try JSONDecoder().decode(PendingOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(saved.bytes, operation.bytes); XCTAssertEqual(saved.sharedTrackingBinding?.targetOperationID, route.operationId)
        _ = try binding.validate(saved)
        let body = try JSONDecoder().decode(CommandEnvelope.self, from: saved.bytes).body
        XCTAssertNil(body["mealSources"]); XCTAssertNil(body["mealUndo"]); XCTAssertNil(body["transferredChanges"])
    }
    func testStoreReviewRetainsExactExplicitBasisRevisionWithoutNewConsentDefaults() throws {
        let raw = try F.scenario(), page: SharedTrackingPage = try F.decode(raw["page"]!), candidate: SharedTrackingCandidate = try F.decode(raw["candidate"]!)
        guard case .patch(var patch) = candidate.action.command else { return XCTFail() }
        patch.reviewedStoreBasisRevision = 12
        let intent = try SharedTrackingIntent(page: page, context: F.context, kind: .review(action: .patch(patch), packs: candidate.after.packReviews))
        let wire = try JSONSerialization.jsonObject(with: encoded(intent)) as! [String: Any]
        XCTAssertEqual(((wire["action"] as! [String: Any])["body"] as! [String: Any])["reviewedStoreBasisRevision"] as? Int, 12)
        XCTAssertNil(wire["acceptUnknown"]); XCTAssertNil(wire["acceptOverage"])
        let budget: ShopperBudget = try F.decode(F.checkout)
        XCTAssertThrowsError(try SharedTrackingMoneyAcknowledgments(acceptOverage: false, acceptUnknown: false).validate(money: budget))
    }
}
