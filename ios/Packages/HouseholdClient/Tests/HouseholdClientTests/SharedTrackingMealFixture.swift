import Foundation
@testable import HouseholdClient

/// Structural wire fixtures, not a substitute for the server's authoritative
/// meal reducer. Fact IDs intentionally differ from retained contribution IDs.
enum TrackingMealFixture {
    typealias F = TrackingWriteFixture
    static func meal(_ title: String) -> [String: Any] { ["title": title, "day": NSNull(), "kind": "lunch", "portions": 2, "protected": false] }
    static func fact(_ id: Int, ingredient: Int, line: Int? = nil, quantity: Any = NSNull()) -> [String: Any] {
        ["id": F.id(id), "revision": 7, "source": ["kind": "meal", "occurrenceId": F.id(40), "ingredientId": F.id(ingredient), "groupId": NSNull(), "bindingId": NSNull()],
         "sourceLabel": "Lunch", "originalText": "Original ingredient \(ingredient)", "originalQuantityText": "Author quantity \(ingredient)",
         "quantity": quantity, "sourceExclusions": [], "requiredLineId": line.map { F.id($0) as Any } ?? NSNull()]
    }
    static func descriptor(_ fact: [String: Any], contribution: Int, productName: String) -> [String: Any] {
        var value = fact; value.removeValue(forKey: "revision"); value["id"] = F.id(contribution); value["productName"] = productName; return value
    }
    static func fixture(quantify: Bool = false) throws -> [String: Any] {
        var page = F.fixture(), state = page["state"] as! [String: Any], graph = state["graph"] as! [String: Any]
        let oldTransfer = (state["unbound"] as! [[String: Any]])[0]["transferred"] as! [String: Any]
        var protected = (state["catalog"] as! [[String: Any]])[0]; protected["id"] = F.id(24)
        let tracked = fact(32, ingredient: 44, line: 10, quantity: F.quantity(4)), plain = fact(25, ingredient: 45), added = fact(26, ingredient: 46)
        let row: [String: Any] = ["id": F.id(30), "lineId": F.id(10), "source": tracked["source"]!, "productKey": "apples", "productName": "Authored apples",
            "originalText": tracked["originalText"]!, "quantity": tracked["quantity"]!, "sourceExclusions": [], "exclusions": [], "contains": [], "removedAt": NSNull()]
        graph["contributions"] = (graph["contributions"] as! [Any]) + [row]; graph["usedIds"] = (graph["usedIds"] as! [String]) + [F.id(30)]
        state["graph"] = graph; state["catalog"] = [tracked, protected, plain]; state["bindings"] = [["factId": F.id(32), "contributionId": F.id(30)]]
        state["unbound"] = [["factId": F.id(24), "transferred": oldTransfer], ["factId": F.id(25), "transferred": NSNull()]]; page["state"] = state
        page = F.edit(page, "coverage.trackedSubtotals.0.activeContributionIds", [F.id(20), F.id(30)]) as! [String: Any]
        page = F.edit(page, "coverage.trackedSubtotals.0.quantity", ["numerator": "8", "denominator": "1"]) as! [String: Any]
        page = F.edit(page, "coverage.unboundFactIds", [F.id(24), F.id(25)]) as! [String: Any]
        page = F.edit(page, "coverage.protectedUnboundFactIds", [F.id(24)]) as! [String: Any]
        var nextProtected = protected, nextTransfer = oldTransfer, nextTracked = tracked, nextPlain = plain, nextAdded = added
        nextProtected["revision"] = 9; nextTracked["revision"] = 9; nextPlain["revision"] = 9; nextAdded["revision"] = 9
        if quantify { nextProtected["quantity"] = F.quantity(6); nextTransfer["quantity"] = F.quantity(6) }
        let catalogFacts = [nextTracked, nextProtected, nextPlain, nextAdded]
        let sources: [[String: Any]] = [
            ["before": row, "proposed": descriptor(nextTracked, contribution: 30, productName: "Authored apples"), "transition": "retain", "factId": F.id(32), "revision": 9, "location": "tracked"],
            ["before": oldTransfer, "proposed": descriptor(nextProtected, contribution: 22, productName: "Wraps"), "transition": quantify ? "quantifyReservation" : "retain", "factId": F.id(24), "revision": 9, "location": "transferred"],
            ["before": NSNull(), "proposed": descriptor(nextPlain, contribution: 25, productName: "Other ingredient"), "transition": "new", "factId": F.id(25), "revision": 9, "location": "unbound"],
            ["before": NSNull(), "proposed": descriptor(nextAdded, contribution: 26, productName: "New ingredient"), "transition": "new", "factId": F.id(26), "revision": 9, "location": "new"]]
        var action = F.action(state)
        action = F.edit(action, "body.mealEdit", ["occurrenceId": F.id(40), "baseMealRevision": 7, "meal": meal("Changed lunch")]) as! [String: Any]
        let change: [String: Any] = ["occurrenceId": F.id(40), "before": ["revision": 7, "meal": meal("Original lunch")], "after": ["revision": 9, "meal": meal("Changed lunch")]]
        let catalog: [String: Any] = ["schemaVersion": 2, "shopId": F.id(2), "base": ["shopRevision": 8, "authorityEpoch": 3, "graphRevision": 3, "stateDigest": String(repeating: "b", count: 64)],
            "normalizedAction": action, "actionDigest": String(repeating: "a", count: 64), "mealChange": change, "sources": sources, "retirementCandidates": [], "transferredRetirementCandidates": [],
            "retiredUnboundFactIds": [], "retainedContributionIds": [F.id(20)], "proposedCatalog": catalogFacts, "beforeCoverage": page["coverage"]!]
        var afterPage = page
        afterPage = F.edit(afterPage, "state.graph.revision", 4) as! [String: Any]
        afterPage = F.edit(afterPage, "state.catalog", catalogFacts) as! [String: Any]
        afterPage = F.edit(afterPage, "state.unbound", [["factId": F.id(24), "transferred": nextTransfer], ["factId": F.id(25), "transferred": NSNull()], ["factId": F.id(26), "transferred": NSNull()]]) as! [String: Any]
        afterPage = F.edit(afterPage, "coverage.unboundFactIds", [F.id(24), F.id(25), F.id(26)]) as! [String: Any]
        let transfers: [[String: Any]] = quantify ? [["factId": F.id(24), "before": oldTransfer, "after": nextTransfer]] : []
        let disclosure: [String: Any] = ["changes": ["kind": "mealActionChange", "mealChange": change, "transferredChanges": transfers], "pickup": F.pickup(afterPage), "money": ["before": F.checkout, "after": F.checkout]]
        let candidate: [String: Any] = ["schemaVersion": 2, "candidateId": F.id(61), "candidateDigest": String(repeating: "a", count: 64), "expiresAt": F.expiry, "action": action, "after": afterPage["state"]!, "disclosure": disclosure]
        let preview: [String: Any] = ["schemaVersion": 2, "previewId": F.id(61), "previewDigest": String(repeating: "c", count: 64), "trackingVersion": 2, "expiresAt": F.expiry,
            "action": action, "disclosure": disclosure, "moneyAcknowledgments": ["acceptOverage": false, "acceptUnknown": true]]
        return ["page": page, "catalog": catalog, "candidate": candidate, "preview": preview, "quantify": quantify]
    }
    static func intent(_ raw: [String: Any]) throws -> SharedTrackingIntent {
        let page: SharedTrackingPage = try F.decode(raw["page"]!), catalog: SharedTrackingMealSources = try F.decode(raw["catalog"]!), candidate: SharedTrackingCandidate = try F.decode(raw["candidate"]!)
        let quantify = raw["quantify"] as! Bool
        let transfer = candidate.after.unbound.first { $0.factId.string == F.id(24) }!.transferred!
        return try .init(page: page, context: F.context,
            kind: .change(action: candidate.action.command, change: .init(quantifyReservationIds: quantify ? [.init(UUID(uuidString: F.id(22))!)] : nil),
                          packs: candidate.after.packReviews, unboundFactIds: candidate.after.unbound.map(\.factId)),
            mealSources: catalog, transferredChanges: quantify ? [.init(factId: .init(UUID(uuidString: F.id(24))!), after: transfer)] : nil)
    }
    static func review(_ raw: [String: Any]) throws -> SharedTrackingCandidateReview {
        try .init(page: F.decode(raw["page"]!), intent: intent(raw), candidate: F.decode(raw["candidate"]!))
    }
    static func inverse() throws -> [String: Any] {
        var value = try F.scenario(), action = (value["candidate"] as! [String: Any])["action"] as! [String: Any]
        let old = meal("Before title"), current = meal("After title")
        action = F.edit(action, "body.mealEdit", ["occurrenceId": F.id(99), "baseMealRevision": 7, "meal": old]) as! [String: Any]
        let outcome: [String: Any] = ["occurrenceId": F.id(99), "targetBefore": ["revision": 6, "meal": old], "targetAfter": ["revision": 7, "meal": current],
            "current": ["revision": 7, "meal": current], "restoredMeal": old, "touchedFields": ["title"], "proposal": NSNull()]
        let changes: [String: Any] = ["kind": "mealOperationUndo", "targetOperationId": F.id(90), "mealUndo": outcome, "transferredChanges": [], "touchedBasket": [],
            "quote": ["before": F.quote(), "after": F.quote()], "graphRows": 0, "beforeCoverage": F.fixture()["coverage"]!, "afterCoverage": F.fixture()["coverage"]!]
        for key in ["candidate", "preview"] {
            value = F.edit(value, key + ".action", action) as! [String: Any]
            value = F.edit(value, key + ".disclosure.changes", changes) as! [String: Any]
        }
        return value
    }
    static func inverseReview(_ raw: [String: Any]) throws -> SharedTrackingCandidateReview {
        let page: SharedTrackingPage = try F.decode(raw["page"]!), candidate: SharedTrackingCandidate = try F.decode(raw["candidate"]!)
        let intent = try SharedTrackingIntent(page: page, context: F.context,
            kind: .mealOperationUndo(targetOperationId: .init(UUID(uuidString: F.id(90))!), packs: candidate.after.packReviews))
        return try .init(page: page, intent: intent, candidate: candidate)
    }
}
