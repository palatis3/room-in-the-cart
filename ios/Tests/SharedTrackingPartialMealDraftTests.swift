import Foundation
import XCTest
import HouseholdClient
@testable import RoomInTheCart

enum TrackingPartialMealFixture {
    typealias F = TrackingFlowFixture
    static func decode<T: Decodable>(_ raw: Any) throws -> T { try JSONDecoder().decode(T.self, from: F.bytes(raw)) }
    static func action(_ state: [String: Any]) -> [String: Any] {
        let basket = state["basket"] as! [[String: Any]]
        return ["kind": "shop.patch", "body": ["lines": basket.map { row in
            ["lineId": row["id"]!, "originalItem": row["name"]!, "packs": row["packs"]!, "unitPriceMinor": row["priceMinor"]!, "feeEligible": row["feeEligible"]!]
        }, "quote": ["currency": "USD", "scope": "wholeCheckout", "complete": false, "capMinor": 5000,
            "capScope": "wholeCheckout", "fee": ["kind": "fixed", "amountMinor": NSNull()], "taxesMinor": NSNull(),
            "depositsMinor": NSNull(), "discountsMinor": NSNull(), "observedAt": "2026-11-10T12:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"]]]
    }
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
        var nextProtected = protected, nextTracked = tracked, nextPlain = plain, nextAdded = added
        nextProtected["revision"] = 9; nextTracked["revision"] = 9; nextPlain["revision"] = 9; nextAdded["revision"] = 9
        if quantify { nextProtected["quantity"] = F.quantity(6) }
        let catalogFacts = [nextTracked, nextProtected, nextPlain, nextAdded]
        let sources: [[String: Any]] = [
            ["before": row, "proposed": descriptor(nextTracked, contribution: 30, productName: "Authored apples"), "transition": "retain", "factId": F.id(32), "revision": 9, "location": "tracked"],
            ["before": oldTransfer, "proposed": descriptor(nextProtected, contribution: 22, productName: "Wraps"), "transition": quantify ? "quantifyReservation" : "retain", "factId": F.id(24), "revision": 9, "location": "transferred"],
            ["before": NSNull(), "proposed": descriptor(nextPlain, contribution: 25, productName: "Other ingredient"), "transition": "new", "factId": F.id(25), "revision": 9, "location": "unbound"],
            ["before": NSNull(), "proposed": descriptor(nextAdded, contribution: 26, productName: "New ingredient"), "transition": "new", "factId": F.id(26), "revision": 9, "location": "new"]]
        var action = Self.action(state)
        action = F.edit(action, "body.mealEdit", ["occurrenceId": F.id(40), "baseMealRevision": 7, "meal": meal("Changed lunch")]) as! [String: Any]
        let change: [String: Any] = ["occurrenceId": F.id(40), "before": ["revision": 7, "meal": meal("Original lunch")], "after": ["revision": 9, "meal": meal("Changed lunch")]]
        let catalog: [String: Any] = ["schemaVersion": 2, "shopId": F.id(2), "base": ["shopRevision": 8, "authorityEpoch": 3, "graphRevision": 3, "stateDigest": String(repeating: "b", count: 64)],
            "normalizedAction": action, "actionDigest": String(repeating: "a", count: 64), "mealChange": change, "sources": sources, "retirementCandidates": [], "transferredRetirementCandidates": [],
            "retiredUnboundFactIds": [], "retainedContributionIds": [F.id(20)], "proposedCatalog": catalogFacts, "beforeCoverage": page["coverage"]!]
        return ["page": page, "catalog": catalog]
    }

    static func setup(_ raw: [String: Any]) throws -> (SharedTrackingPage, ShopperShop, SharedTrackingMealSources, SharedDemandMealEdit, TrackingFlowDraft) {
        let page = try F.page(raw["page"]!), catalog: SharedTrackingMealSources = try decode(raw["catalog"]!)
        guard case .patch(let patch) = catalog.normalizedAction.command, let edit = patch.mealEdit else { throw ClientError.configuration }
        let action = (raw["catalog"] as! [String: Any])["normalizedAction"] as! [String: Any], body = action["body"] as! [String: Any]
        let shop: ShopperShop = try decode(["shopId": page.shopId.string, "shopRevision": page.shopRevision, "authorityEpoch": page.authorityEpoch,
            "phase": "draft", "frozenRevision": NSNull(), "placedRevision": NSNull(), "meals": [], "lines": body["lines"]!, "quote": body["quote"]!])
        return (page, shop, catalog, edit, try TrackingFlowDraft(page: page, shop: shop, mealSources: catalog))
    }
    static func change(_ raw: [String: Any], tracked: Bool = true) -> [String: Any] {
        var value: Any = raw
        let index = tracked ? 0 : 1
        value = F.edit(value, "catalog.sources.\(index).transition", tracked ? "update" : "quantifyReservation")
        value = F.edit(value, "catalog.sources.\(index).proposed.quantity", F.quantity(6))
        value = F.edit(value, "catalog.proposedCatalog.\(index).quantity", F.quantity(6))
        return value as! [String: Any]
    }
}

final class SharedTrackingPartialMealDraftTests: XCTestCase {
    private typealias M = TrackingPartialMealFixture
    private typealias F = TrackingFlowFixture
    private func id(_ n: Int) -> SharedDemandID { .init(UUID(uuidString: F.id(n))!) }
    private func acknowledge(_ draft: inout TrackingFlowDraft) {
        draft.mealChanges!.reviewed = true
        for i in draft.mealChanges!.rows.indices {
            draft.mealChanges!.rows[i].confirmed = true
            draft.mealChanges!.rows[i].quantificationConfirmed = true
        }
        for i in draft.mealChanges!.retirements.indices { draft.mealChanges!.retirements[i].confirmed = true }
        for i in draft.mealChanges!.edgeRemovals.indices where draft.mealChanges!.edgeRemovals[i].required { draft.mealChanges!.edgeRemovals[i].confirmed = true }
    }
    func testDefaultsRequireReviewAndNeverBindNewOrPlainUnboundSources() throws {
        let (page, shop, _, edit, original) = try M.setup(M.fixture())
        var draft = original
        XCTAssertFalse(draft.mealChanges!.reviewed)
        XCTAssertTrue(draft.mealChanges!.rows.allSatisfy { !$0.confirmed && !$0.quantificationConfirmed && $0.lineID == nil && !$0.productConfirmed })
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.reviewed = true
        guard case .change(_, let change, let packs, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(unbound, [id(24), id(25), id(26)])
        XCTAssertEqual(packs.map(\.lineId), [id(10)])
        XCTAssertNil(try draft.mealChanges!.transferredChanges(page: page))
        XCTAssertEqual(original.mealChanges!.reviewed, false) // value-copy cancellation
        XCTAssertEqual(page.coverage?.allocatableUnboundFactIds, [])
    }
    func testTrackedUpdatePreservesContributionIdentityAndRequiresAcknowledgment() throws {
        let (page, shop, catalog, edit, original) = try M.setup(M.change(M.fixture()))
        var draft = original; draft.mealChanges!.reviewed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.rows[0].confirmed = true
        guard case .change(let action, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertEqual(action, catalog.normalizedAction.command)
        let row = try XCTUnwrap(change.contributions.first)
        XCTAssertEqual(row.id, id(30)); XCTAssertNotEqual(row.id, catalog.sources[0].factId)
        XCTAssertEqual(row.quantity, catalog.sources[0].proposed.quantity)
        XCTAssertEqual(row.originalText, catalog.sources[0].before?.originalText)
        XCTAssertEqual(row.productKey, catalog.sources[0].before?.productKey)
        XCTAssertEqual(change.contributions.count, 1)
        XCTAssertFalse(change.removeSourceIds.contains(id(20)))
        XCTAssertEqual(unbound, [id(24), id(25), id(26)])
    }
    func testTransferredProtectedQuantificationIsExplicitAndStaysOutsideGraph() throws {
        let (page, shop, catalog, edit, original) = try M.setup(M.fixture(quantify: true))
        var draft = original; draft.mealChanges!.reviewed = true; draft.mealChanges!.rows[1].confirmed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        XCTAssertThrowsError(try draft.mealChanges!.transferredChanges(page: page))
        draft.mealChanges!.rows[1].quantificationConfirmed = true
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.contributions.isEmpty); XCTAssertTrue(change.edges.isEmpty)
        XCTAssertEqual(change.quantifyReservationIds, [id(22)])
        let transferred = try XCTUnwrap(draft.mealChanges!.transferredChanges(page: page)?.first)
        XCTAssertEqual(transferred.factId, id(24)); XCTAssertEqual(transferred.after?.id, id(22))
        XCTAssertEqual(transferred.after?.quantity, catalog.sources[1].proposed.quantity)
        XCTAssertEqual(transferred.after?.sourceExclusions, catalog.sources[1].before?.sourceExclusions)
        XCTAssertNil(transferred.after?.productKey); XCTAssertTrue(unbound.contains(id(24)))
    }
    func testTrackedProtectedUnknownCannotBeQuantifiedWithoutSeparateConfirmation() throws {
        var raw = try M.fixture(quantify: true)
        let state = ((raw["page"] as! [String: Any])["state"] as! [String: Any])
        let transfer = (state["unbound"] as! [[String: Any]])[0]["transferred"]!
        raw = F.edit(raw, "page.state.graph.lines.1.trashedAt", NSNull()) as! [String: Any]
        raw = F.edit(raw, "page.state.graph.contributions", ((state["graph"] as! [String: Any])["contributions"] as! [Any]) + [transfer]) as! [String: Any]
        raw = F.edit(raw, "page.state.bindings", (state["bindings"] as! [Any]) + [["factId": F.id(24), "contributionId": F.id(22)]]) as! [String: Any]
        raw = F.edit(raw, "page.state.unbound", [["factId": F.id(25), "transferred": NSNull()]]) as! [String: Any]
        raw = F.edit(raw, "page.state.legacyLineIds", []) as! [String: Any]
        raw = F.edit(raw, "page.state.packReviews", (state["packReviews"] as! [Any]) + [["lineId": F.id(11), "usablePerPack": NSNull(), "acceptUnresolved": false]]) as! [String: Any]
        let coverage = (raw["page"] as! [String: Any])["coverage"] as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals", (coverage["trackedSubtotals"] as! [Any]) + [["lineId": F.id(11), "unit": "count", "quantity": NSNull(), "activeContributionIds": [F.id(22)]]]) as! [String: Any]
        raw = F.edit(raw, "page.coverage.unboundFactIds", [F.id(25)]) as! [String: Any]
        for key in ["untrackedBasketIds", "protectedUnboundFactIds"] { raw = F.edit(raw, "page.coverage." + key, []) as! [String: Any] }
        raw = F.edit(raw, "catalog.beforeCoverage", (raw["page"] as! [String: Any])["coverage"]!) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1.location", "tracked") as! [String: Any]
        let (page, shop, _, edit, original) = try M.setup(raw)
        var draft = original; draft.mealChanges!.reviewed = true; draft.mealChanges!.rows[1].confirmed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.rows[1].quantificationConfirmed = true
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertEqual(change.contributions.map(\.id), [id(22)]); XCTAssertEqual(change.quantifyReservationIds, [id(22)])
        XCTAssertEqual(unbound, [id(25), id(26)]); XCTAssertNil(try draft.mealChanges!.transferredChanges(page: page))
    }
    func testNewAndPlainUnboundBindingRequiresExplicitLineAndProductReview() throws {
        let (page, shop, _, edit, original) = try M.setup(M.fixture())
        for rowIndex in [2, 3] {
            var draft = original; draft.mealChanges!.reviewed = true
            draft.mealChanges!.rows[rowIndex].lineID = id(10)
            XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
            draft.mealChanges!.rows[rowIndex].productConfirmed = true
            XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
            draft.packs[0].confirmExistingSources = true
            guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
            let factID = draft.mealChanges!.rows[rowIndex].id
            XCTAssertFalse(unbound.contains(factID))
            XCTAssertEqual(change.contributions.first { $0.id == factID }?.lineId, id(10))
            XCTAssertNil(change.contributions.first { $0.id == factID }?.quantity)
            XCTAssertFalse(change.contributions.contains { $0.id == id(22) })
            XCTAssertTrue(change.edges.isEmpty)
        }
    }
    func testDetachedSourceCannotBeBoundThroughMealChangeFields() throws {
        let (page, shop, _, edit, original) = try M.setup(M.fixture())
        var draft = original; acknowledge(&draft)
        draft.mealChanges!.rows[1].lineID = id(10)
        draft.mealChanges!.rows[1].productConfirmed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
    }
    func testManualAdditionSurvivesAlongsideTrackedChange() throws {
        let (page, shop, _, edit, original) = try M.setup(M.change(M.fixture()))
        var draft = original; acknowledge(&draft)
        draft.manuals[0].enabled = true; draft.manuals[0].name = "Independent apples"
        draft.manuals[0].original = "Keep this staple"; draft.manuals[0].productConfirmed = true
        draft.packs[0].confirmExistingSources = true
        guard case .change(_, let change, _, _) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.contributions.contains { $0.id == draft.manuals[0].id && $0.source == .manual && $0.originalText == "Keep this staple" })
        XCTAssertTrue(change.contributions.contains { $0.id == id(30) && $0.quantity?.amount.numerator == 6 })
        XCTAssertTrue(change.removeSourceIds.isEmpty)
    }
    func testFreshCatalogAndOriginalActionInvalidateOldAcknowledgments() throws {
        let (page, shop, catalog, edit, original) = try M.setup(M.fixture(quantify: true))
        var draft = original; acknowledge(&draft)
        var changedEdit = edit; changedEdit.meal?.title = "Different meal"
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: changedEdit))
        let fresh = try TrackingFlowDraft(page: page, shop: shop, mealSources: catalog)
        XCTAssertFalse(fresh.mealChanges!.reviewed)
        XCTAssertThrowsError(try fresh.intent(page: page, shop: shop, mealEdit: edit))
        var removed = draft; removed.mealChanges!.rows.removeLast()
        XCTAssertThrowsError(try removed.intent(page: page, shop: shop, mealEdit: edit))
    }
    func testTrackedRetirementRequiresSourceAndIncidentEdgeRemovalAcknowledgments() throws {
        var raw = try M.fixture()
        let edge: [String: Any] = ["id": F.id(70), "kind": "withinExisting", "demandId": F.id(30), "supplyId": F.id(20),
            "quantity": F.quantity(1), "confirmation": ["productMatchConfirmed": true, "confirmedAt": "2026-11-10T12:00:00Z", "evidence": "Reviewed apples"]]
        raw = F.edit(raw, "page.state.graph.edges", [edge]) as! [String: Any]
        let graph = ((raw["page"] as! [String: Any])["state"] as! [String: Any])["graph"] as! [String: Any]
        raw = F.edit(raw, "page.state.graph.usedIds", (graph["usedIds"] as! [String]) + [F.id(70)]) as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals.0.quantity", ["numerator": "7", "denominator": "1"]) as! [String: Any]
        raw = F.edit(raw, "catalog.beforeCoverage", (raw["page"] as! [String: Any])["coverage"]!) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.0", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.proposedCatalog.0", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.retirementCandidates", [F.id(30)]) as! [String: Any]
        let (page, shop, _, edit, original) = try M.setup(raw)
        var draft = original; draft.mealChanges!.reviewed = true
        XCTAssertEqual(draft.mealChanges!.retirements.map(\.id), [id(30)])
        XCTAssertTrue(draft.mealChanges!.edgeRemovals[0].required)
        XCTAssertTrue(draft.mealChanges!.edgeRemovals[0].remove)
        XCTAssertFalse(draft.mealChanges!.edgeRemovals[0].confirmed)
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.retirements[0].confirmed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.edgeRemovals[0].confirmed = true
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertEqual(change.removeSourceIds, [id(30)]); XCTAssertEqual(change.removeEdgeIds, [id(70)])
        XCTAssertTrue(change.contributions.isEmpty); XCTAssertTrue(unbound.contains(id(24)))
        draft.mealChanges!.edgeRemovals[0].remove = false
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
    }
    func testTransferredMealRetirementCannotDisappearWithoutExplicitTransferIntent() throws {
        var raw = try M.fixture()
        var fact = M.fact(24, ingredient: 43, line: 11)
        fact["originalText"] = "Keep lunch wraps"
        raw = F.edit(raw, "page.state.catalog.1", fact) as! [String: Any]
        raw = F.edit(raw, "page.state.unbound.0.transferred.source", fact["source"]!) as! [String: Any]
        raw = F.edit(raw, "page.state.unbound.0.transferred.sourceExclusions", []) as! [String: Any]
        raw = F.edit(raw, "page.coverage.protectedUnboundFactIds", []) as! [String: Any]
        raw = F.edit(raw, "catalog.beforeCoverage", (raw["page"] as! [String: Any])["coverage"]!) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.proposedCatalog.1", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.transferredRetirementCandidates", [["factId": F.id(24), "contributionId": F.id(22)]]) as! [String: Any]
        let (page, shop, _, edit, original) = try M.setup(raw)
        var draft = original; draft.mealChanges!.reviewed = true
        XCTAssertThrowsError(try draft.mealChanges!.transferredChanges(page: page))
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.retirements[0].confirmed = true
        let transfer = try XCTUnwrap(draft.mealChanges!.transferredChanges(page: page)?.first)
        XCTAssertEqual(transfer.factId, id(24)); XCTAssertNil(transfer.after)
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.removeSourceIds.isEmpty); XCTAssertTrue(change.contributions.isEmpty)
        XCTAssertFalse(unbound.contains(id(24))); XCTAssertTrue(unbound.contains(id(25)))
    }
    func testReviewedConversionAndRestrictionMappingSurviveTrackedUpdate() throws {
        var raw = try M.fixture()
        let conversion: [String: Any] = ["sourceUnit": "count", "targetUnit": "gram", "targetAmountPerSourceUnit": ["numerator": "40", "denominator": "1"], "sourceNote": "Weighed one apple", "confirmedAt": "2026-11-10T12:00:00Z"]
        let restriction: [String: Any] = ["occurrenceId": F.id(40), "ingredientId": F.id(44), "label": "Family wording", "resolution": ["kind": "mapped", "tags": ["family.reviewed"], "confirmedAt": "2026-11-10T12:00:00Z"]]
        for path in ["page.state.graph.contributions.1", "catalog.sources.0.before", "catalog.sources.0.proposed"] {
            raw = F.edit(raw, path + ".quantity.confirmedConversion", conversion) as! [String: Any]
            raw = F.edit(raw, path + ".sourceExclusions", [restriction]) as! [String: Any]
        }
        for path in ["page.state.graph.contributions.1", "catalog.sources.0.before"] {
            raw = F.edit(raw, path + ".exclusions", ["family.reviewed", "extra.reviewed"]) as! [String: Any]
            raw = F.edit(raw, path + ".contains", ["fruit"]) as! [String: Any]
        }
        // Authoritative facts carry restriction origins; the reviewed descriptor
        // independently retains the prior mapping and conversion evidence.
        let unresolved = F.edit(restriction, "resolution", ["kind": "unresolved"])
        for path in ["page.state.catalog.0", "catalog.proposedCatalog.0"] { raw = F.edit(raw, path + ".sourceExclusions", [unresolved]) as! [String: Any] }
        raw = F.edit(raw, "catalog.sources.0.transition", "update") as! [String: Any]
        let (page, shop, catalog, edit, original) = try M.setup(raw)
        var draft = original; acknowledge(&draft)
        guard case .change(_, let change, _, _) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        let row = try XCTUnwrap(change.contributions.first)
        XCTAssertEqual(row.quantity, catalog.sources[0].before?.quantity)
        XCTAssertEqual(row.sourceExclusions, catalog.sources[0].before?.sourceExclusions)
        XCTAssertEqual(Set(row.exclusions), Set(["family.reviewed", "extra.reviewed"]))
        XCTAssertEqual(row.contains, ["fruit"])
    }

    func testRetiringLastSourceReturnsBasketToUntrackedWithoutReviewingItsPack() throws {
        var raw = try M.fixture()
        raw = F.edit(raw, "page.state.graph.contributions.0", nil) as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals.0.activeContributionIds", [F.id(30)]) as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals.0.quantity", ["numerator": "4", "denominator": "1"]) as! [String: Any]
        raw = F.edit(raw, "catalog.beforeCoverage", (raw["page"] as! [String: Any])["coverage"]!) as! [String: Any]
        raw = F.edit(raw, "catalog.retainedContributionIds", []) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.0", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.proposedCatalog.0", nil) as! [String: Any]
        raw = F.edit(raw, "catalog.retirementCandidates", [F.id(30)]) as! [String: Any]
        let (page, shop, _, edit, original) = try M.setup(raw)
        var draft = original; acknowledge(&draft)
        guard case .change(let action, let change, let packs, _) = try draft.intent(page: page, shop: shop, mealEdit: edit), case .patch(let patch) = action else { return XCTFail() }
        XCTAssertEqual(change.removeSourceIds, [id(30)]); XCTAssertTrue(packs.isEmpty)
        XCTAssertEqual(patch.lines, shop.lines); XCTAssertEqual(patch.quote, shop.quote)
        XCTAssertTrue(change.contributions.isEmpty)
    }
    func testExplicitPlainBindingRestoresHistoricalLineWithoutRestoringTransferredSupply() throws {
        let (page, shop, _, edit, original) = try M.setup(M.fixture())
        var draft = original; acknowledge(&draft)
        draft.mealChanges!.rows[2].lineID = id(11); draft.mealChanges!.rows[2].productConfirmed = true
        guard case .change(_, let change, let packs, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertEqual(change.lines.map(\.id), [id(11)]); XCTAssertNil(change.lines[0].trashedAt)
        XCTAssertEqual(change.contributions.map(\.id), [id(25)])
        XCTAssertEqual(Set(packs.map(\.lineId)), Set([id(10), id(11)]))
        XCTAssertEqual(unbound, [id(24), id(26)])
        XCTAssertNil(try draft.mealChanges!.transferredChanges(page: page)); XCTAssertTrue(change.edges.isEmpty)
    }
    func testPlainUnboundProtectedQuantificationRequiresConsentWithoutCreatingContribution() throws {
        var raw = try M.fixture(quantify: true)
        raw = F.edit(raw, "page.state.unbound.0.transferred", NSNull()) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1.before", NSNull()) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1.proposed.id", F.id(24)) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1.location", "unbound") as! [String: Any]
        raw = F.edit(raw, "catalog.sources.1.transition", "new") as! [String: Any]
        let (page, shop, _, edit, original) = try M.setup(raw)
        var draft = original; draft.mealChanges!.reviewed = true
        XCTAssertTrue(draft.mealChanges!.rows[1].needsQuantificationConfirmation)
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        draft.mealChanges!.rows[1].quantificationConfirmed = true
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.isEmpty); XCTAssertTrue(unbound.contains(id(24)))
        XCTAssertNil(try draft.mealChanges!.transferredChanges(page: page))
    }

    private func undoPackDraft(_ raw: Any) throws -> (SharedTrackingPage, ShopperShop, TrackingFlowDraft) {
        let page = try F.page(raw)
        let stateObject = (raw as! [String: Any])["state"] as! [String: Any]
        let body = M.action(stateObject)["body"] as! [String: Any]
        let shop: ShopperShop = try M.decode(["shopId": page.shopId.string, "shopRevision": page.shopRevision,
            "authorityEpoch": page.authorityEpoch, "phase": "draft", "frozenRevision": NSNull(), "placedRevision": NSNull(),
            "meals": [], "lines": body["lines"]!, "quote": body["quote"]!])
        return (page, shop, try TrackingFlowDraft(page: page, shop: shop))
    }
    private func pageWithMissingHistoricalBasket() -> Any {
        var raw: Any = F.fixture()
        raw = F.edit(raw, "state.basket.1", nil)
        raw = F.edit(raw, "state.legacyLineIds", [])
        raw = F.edit(raw, "state.catalog.0.requiredLineId", NSNull())
        raw = F.edit(raw, "coverage.untrackedBasketIds", [])
        return raw
    }
    func testHistoricalUndoPackAbsentFromBasketStartsUnselectedUnknownAndUnaccepted() throws {
        let (_, _, draft) = try undoPackDraft(pageWithMissingHistoricalBasket())
        XCTAssertEqual(draft.packs.map(\.id), [id(10)])
        XCTAssertEqual(draft.historicalUndoPacks.map(\.id), [id(11)])
        let historical = try XCTUnwrap(draft.historicalUndoPacks.first)
        XCTAssertEqual(historical.name, "Wraps"); XCTAssertEqual(historical.lineUnit, .count)
        XCTAssertFalse(historical.includeForUndo); XCTAssertTrue(historical.usable.unknown)
        XCTAssertFalse(historical.acceptUnresolved); XCTAssertNil(try historical.review().usablePerPack)
        XCTAssertEqual(try draft.undoPackReviews().map(\.lineId), [id(10)])
        XCTAssertEqual(draft.manuals.map(\.lineID), [id(10)])
    }
    func testHistoricalUndoPackRequiresExplicitUnknownAcceptanceAndDoesNotBecomeOrdinaryFood() throws {
        let (page, shop, original) = try undoPackDraft(pageWithMissingHistoricalBasket())
        var draft = original; draft.historicalUndoPacks[0].includeForUndo = true
        XCTAssertThrowsError(try draft.undoPackReviews())
        draft.historicalUndoPacks[0].acceptUnresolved = true
        let inverse = try draft.undoPackReviews()
        XCTAssertEqual(inverse.map(\.lineId), [id(10), id(11)])
        XCTAssertNil(inverse[1].usablePerPack); XCTAssertTrue(inverse[1].acceptUnresolved)
        guard case .review(let action, let currentPacks) = try draft.intent(page: page, shop: shop), case .patch(let patch) = action else { return XCTFail() }
        XCTAssertEqual(currentPacks.map(\.lineId), [id(10)])
        XCTAssertEqual(try draft.packReviews().map(\.lineId), [id(10)])
        XCTAssertEqual(draft.reviewLineIDs(page: page, request: nil), Set([id(10)]))
        XCTAssertEqual(patch.lines, shop.lines); XCTAssertEqual(patch.lines.count, 1)
        XCTAssertEqual(draft.manuals.count, 1)
        draft.rebindFactID = id(22); draft.rebindConfirmed = true
        guard case .rebind(let bindings) = try draft.rebind(page: page) else { return XCTFail() }
        XCTAssertNil(bindings[0].packReview.usablePerPack)
        XCTAssertFalse(bindings[0].packReview.acceptUnresolved) // Undo acceptance never authorizes a rebind.
    }
    func testLastSourceRetirementUndoCanReviewCurrentUntrackedBasketPack() throws {
        var raw: Any = F.fixture()
        raw = F.edit(raw, "state.graph.contributions.0.removedAt", "2026-11-10T12:00:00Z")
        raw = F.edit(raw, "state.graph.lines.0.trashedAt", "2026-11-10T12:00:00Z")
        raw = F.edit(raw, "state.packReviews", [])
        raw = F.edit(raw, "state.legacyLineIds", [F.id(10), F.id(11)])
        raw = F.edit(raw, "coverage.trackedSubtotals", [])
        raw = F.edit(raw, "coverage.untrackedBasketIds", [F.id(10), F.id(11)])
        let (page, shop, original) = try undoPackDraft(raw)
        var draft = original
        XCTAssertTrue(draft.historicalUndoPacks.isEmpty)
        XCTAssertTrue(draft.packs.allSatisfy { !$0.includeForUndo && $0.usable.unknown && !$0.acceptUnresolved })
        draft.packs[0].includeForUndo = true
        XCTAssertThrowsError(try draft.undoPackReviews())
        draft.packs[0].acceptUnresolved = true
        XCTAssertEqual(try draft.undoPackReviews().map(\.lineId), [id(10)])
        guard case .review(_, let ordinaryPacks) = try draft.intent(page: page, shop: shop) else { return XCTFail() }
        XCTAssertTrue(ordinaryPacks.isEmpty)
    }
    func testHistoricalUndoKnownEvidenceAndRefreshHaveIndependentAcknowledgments() throws {
        let (page, shop, original) = try undoPackDraft(pageWithMissingHistoricalBasket())
        var draft = original
        draft.historicalUndoPacks[0].includeForUndo = true
        draft.historicalUndoPacks[0].usable.unknown = false
        draft.historicalUndoPacks[0].usable.numerator = "8"
        let reviews = try draft.undoPackReviews()
        XCTAssertEqual(reviews[1].usablePerPack?.amount.numerator, 8)
        XCTAssertFalse(reviews[1].acceptUnresolved)
        let refreshed = try TrackingFlowDraft(page: page, shop: shop)
        XCTAssertFalse(refreshed.historicalUndoPacks[0].includeForUndo)
        XCTAssertTrue(refreshed.historicalUndoPacks[0].usable.unknown)
        XCTAssertFalse(refreshed.historicalUndoPacks[0].acceptUnresolved)
        XCTAssertEqual(refreshed.packs[0].usable, original.packs[0].usable)
        XCTAssertFalse(refreshed.packs[0].acceptUnresolved)
    }

    private func trackedFreshConversionFixture(retain: Bool = false) throws -> [String: Any] {
        var raw = try M.fixture()
        let basis: [String: Any] = ["sourceUnit": "cup", "targetUnit": "gram", "targetAmountPerSourceUnit": ["numerator": "120", "denominator": "1"], "sourceNote": "Old reviewed density", "confirmedAt": "2026-11-10T12:00:00Z"]
        func cups(_ count: Int, conversion: Any) -> [String: Any] {
            ["amount": ["numerator": String(count), "denominator": "1"], "unit": "cup", "originalLiteral": "\(count) measured cups", "confirmedConversion": conversion]
        }
        let old = cups(1, conversion: basis), proposed = retain ? old : cups(2, conversion: NSNull())
        var manualQuantity = F.quantity(240); manualQuantity["unit"] = "gram"; manualQuantity["originalLiteral"] = "240 grams"
        raw = F.edit(raw, "page.state.graph.lines.0.unit", "gram") as! [String: Any]
        raw = F.edit(raw, "page.state.graph.contributions.0.quantity", manualQuantity) as! [String: Any]
        raw = F.edit(raw, "page.state.packReviews.0.usablePerPack", manualQuantity) as! [String: Any]
        raw = F.edit(raw, "page.state.graph.contributions.0.productKey", "apples") as! [String: Any]
        raw = F.edit(raw, "page.state.graph.contributions.1.quantity", old) as! [String: Any]
        raw = F.edit(raw, "page.state.catalog.0.quantity", cups(1, conversion: NSNull())) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.0.before.quantity", old) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.0.proposed.quantity", proposed) as! [String: Any]
        raw = F.edit(raw, "catalog.sources.0.transition", retain ? "retain" : "update") as! [String: Any]
        raw = F.edit(raw, "catalog.proposedCatalog.0.quantity", cups(retain ? 1 : 2, conversion: NSNull())) as! [String: Any]
        var edgeQuantity = manualQuantity; edgeQuantity["amount"] = ["numerator": "120", "denominator": "1"]
        edgeQuantity["originalLiteral"] = "120 grams already included"; edgeQuantity["confirmedConversion"] = basis
        let edge: [String: Any] = ["id": F.id(70), "kind": "withinExisting", "demandId": F.id(30), "supplyId": F.id(20), "quantity": edgeQuantity,
            "confirmation": ["productMatchConfirmed": true, "confirmedAt": "2026-11-10T12:00:00Z", "evidence": "Reviewed same ingredient"]]
        raw = F.edit(raw, "page.state.graph.edges", [edge]) as! [String: Any]
        let graph = ((raw["page"] as! [String: Any])["state"] as! [String: Any])["graph"] as! [String: Any]
        raw = F.edit(raw, "page.state.graph.usedIds", (graph["usedIds"] as! [String]) + [F.id(70)]) as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals.0.unit", "gram") as! [String: Any]
        raw = F.edit(raw, "page.coverage.trackedSubtotals.0.quantity", ["numerator": "240", "denominator": "1"]) as! [String: Any]
        raw = F.edit(raw, "catalog.beforeCoverage", (raw["page"] as! [String: Any])["coverage"]!) as! [String: Any]
        return raw
    }
    private func freshConversion(target: SharedDemandUnit = .gram, numerator: String = "120", denominator: String = "1", note: String = "Fresh measurement for this ingredient") -> TrackingFixedConversionEntry {
        var entry = TrackingFixedConversionEntry(); entry.enabled = true; entry.target = target
        entry.numerator = numerator; entry.denominator = denominator; entry.note = note; return entry
    }
    func testChangedTrackedQuantityAcceptsFreshConversionAndKeepsReviewedEdge() throws {
        let (page, shop, catalog, edit, original) = try M.setup(trackedFreshConversionFixture())
        var draft = original; acknowledge(&draft)
        XCTAssertTrue(draft.mealChanges!.rows[0].canReviewFreshConversion)
        XCTAssertNil(catalog.sources[0].proposed.quantity?.confirmedConversion)
        draft.mealChanges!.rows[0].conversion = freshConversion()
        guard case .change(_, let change, _, _) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        let after = try XCTUnwrap(change.contributions.first), amount = try XCTUnwrap(after.quantity)
        XCTAssertEqual(after.id, id(30)); XCTAssertEqual(after.source, catalog.sources[0].before?.source)
        XCTAssertEqual(amount.amount, catalog.sources[0].proposed.quantity?.amount)
        XCTAssertEqual(amount.unit, .cup); XCTAssertEqual(amount.originalLiteral, "2 measured cups")
        XCTAssertEqual(amount.confirmedConversion?.targetUnit, .gram)
        XCTAssertEqual(amount.confirmedConversion?.targetAmountPerSourceUnit, try .init(numerator: 120))
        XCTAssertEqual(amount.confirmedConversion?.sourceNote, "Fresh measurement for this ingredient")
        XCTAssertTrue(change.edges.isEmpty); XCTAssertTrue(change.removeEdgeIds.isEmpty)
        XCTAssertEqual(draft.mealChanges!.edgeRemovals[0].edge, page.state?.graph.edges[0])
        XCTAssertFalse(draft.mealChanges!.edgeRemovals[0].remove)
        XCTAssertEqual(catalog.sources[0].before?.quantity?.confirmedConversion?.sourceNote, "Old reviewed density")
    }
    func testTransferredProtectedUnitChangeAcceptsFreshEquivalentBasisWithoutAllocation() throws {
        var raw = try M.fixture()
        let old = F.quantity(2)
        var proposed = F.quantity(60); proposed["unit"] = "gram"; proposed["originalLiteral"] = "60 measured grams"
        for path in ["page.state.catalog.1.quantity", "page.state.unbound.0.transferred.quantity", "catalog.sources.1.before.quantity"] { raw = F.edit(raw, path, old) as! [String: Any] }
        for path in ["catalog.sources.1.proposed.quantity", "catalog.proposedCatalog.1.quantity"] { raw = F.edit(raw, path, proposed) as! [String: Any] }
        raw = F.edit(raw, "catalog.sources.1.transition", "update") as! [String: Any]
        let (page, shop, catalog, edit, original) = try M.setup(raw)
        var draft = original; acknowledge(&draft)
        XCTAssertTrue(draft.mealChanges!.rows[1].canReviewFreshConversion)
        draft.mealChanges!.rows[1].conversion = freshConversion(target: .count, numerator: "1", denominator: "30", note: "One reserved wrap weighs 30 grams")
        guard case .change(_, let change, _, let unbound) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        let transfer = try XCTUnwrap(draft.mealChanges!.transferredChanges(page: page)?.first), after = try XCTUnwrap(transfer.after)
        XCTAssertEqual(transfer.factId, id(24)); XCTAssertEqual(after.id, id(22))
        XCTAssertEqual(after.quantity?.amount.numerator, 60); XCTAssertEqual(after.quantity?.unit, .gram)
        XCTAssertEqual(after.quantity?.originalLiteral, "60 measured grams")
        XCTAssertEqual(after.quantity?.confirmedConversion?.targetAmountPerSourceUnit, try .init(numerator: 1, denominator: 30))
        XCTAssertEqual(after.source, catalog.sources[1].before?.source)
        XCTAssertEqual(after.sourceExclusions, catalog.sources[1].before?.sourceExclusions)
        XCTAssertEqual(after.productKey, catalog.sources[1].before?.productKey)
        XCTAssertTrue(change.contributions.isEmpty); XCTAssertTrue(change.edges.isEmpty)
        XCTAssertNil(change.quantifyReservationIds); XCTAssertTrue(unbound.contains(id(24)))
        // The server remains responsible for testing the exact equivalent
        // quantity against protected conservation; this draft sends evidence.
    }
    func testFreshConversionNeedsRelevantDimensionPositiveRatioAndEvidence() throws {
        let (page, shop, _, edit, original) = try M.setup(trackedFreshConversionFixture())
        for conversion in [freshConversion(target: .cup), freshConversion(target: .count),
                           freshConversion(numerator: "0"), freshConversion(denominator: "0"), freshConversion(note: " ")] {
            var draft = original; acknowledge(&draft); draft.mealChanges!.rows[0].conversion = conversion
            XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        }
        var withoutBasis = original; acknowledge(&withoutBasis)
        guard case .change(_, let change, _, _) = try withoutBasis.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertNil(change.contributions[0].quantity?.confirmedConversion)
        // Leaving evidence absent never copies the old basis. The service
        // rejects incompatible kept edges or leaves an unallocated total unknown.
        var missingAmount = original; acknowledge(&missingAmount)
        missingAmount.mealChanges!.rows[0].conversion = freshConversion(numerator: "")
        XCTAssertThrowsError(try missingAmount.intent(page: page, shop: shop, mealEdit: edit))
    }
    func testRetainedConversionAndRetainedSourcesCannotBeReplacedByFreshEntry() throws {
        let (page, shop, catalog, edit, original) = try M.setup(trackedFreshConversionFixture(retain: true))
        var draft = original; acknowledge(&draft)
        XCTAssertFalse(draft.mealChanges!.rows[0].canReviewFreshConversion)
        guard case .change(_, let change, _, _) = try draft.intent(page: page, shop: shop, mealEdit: edit) else { return XCTFail() }
        XCTAssertTrue(change.contributions.isEmpty); XCTAssertTrue(change.removeEdgeIds.isEmpty)
        XCTAssertEqual(catalog.sources[0].proposed.quantity, catalog.sources[0].before?.quantity)
        draft.mealChanges!.rows[0].conversion = freshConversion(numerator: "130")
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit))
        let changedWithExistingBasis = F.edit(try trackedFreshConversionFixture(retain: true), "catalog.sources.0.transition", "update") as! [String: Any]
        let (changedPage, changedShop, _, changedEdit, changedOriginal) = try M.setup(changedWithExistingBasis)
        var replacement = changedOriginal; acknowledge(&replacement)
        XCTAssertTrue(replacement.mealChanges!.rows[0].needsConfirmation)
        XCTAssertFalse(replacement.mealChanges!.rows[0].canReviewFreshConversion)
        replacement.mealChanges!.rows[0].conversion = freshConversion(numerator: "130")
        XCTAssertThrowsError(try replacement.intent(page: changedPage, shop: changedShop, mealEdit: changedEdit))
        let (otherPage, otherShop, _, otherEdit, otherOriginal) = try M.setup(M.fixture())
        var retainedWithoutBasis = otherOriginal; acknowledge(&retainedWithoutBasis)
        retainedWithoutBasis.mealChanges!.rows[0].conversion = freshConversion()
        XCTAssertFalse(retainedWithoutBasis.mealChanges!.rows[0].canReviewFreshConversion)
        XCTAssertThrowsError(try retainedWithoutBasis.intent(page: otherPage, shop: otherShop, mealEdit: otherEdit))
    }

}
