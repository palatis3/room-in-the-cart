import Foundation
import XCTest
import HouseholdClient
@testable import RoomInTheCart

final class SharedTrackingFlowDraftTests: XCTestCase {
    private typealias F = TrackingFlowFixture
    private func decode<T: Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self, from: F.bytes(value)) }
    private func shop(_ value: Any = F.fixture()) throws -> ShopperShop {
        let page = try F.page(value), state = page.state
        let basket = state?.basket ?? page.projection!.state.basket
        return try decode(["shopId": page.shopId.string, "shopRevision": page.shopRevision, "authorityEpoch": page.authorityEpoch,
            "phase": "draft", "frozenRevision": NSNull(), "placedRevision": NSNull(), "meals": [],
            "lines": basket.map { ["lineId": $0.id.string, "originalItem": $0.name, "packs": $0.packs,
                "unitPriceMinor": $0.priceMinor.map { $0 as Any } ?? NSNull(), "feeEligible": $0.feeEligible] },
            "quote": ["currency": "USD", "scope": "wholeCheckout", "complete": false, "capMinor": 5000,
                "capScope": "wholeCheckout", "fee": ["kind": "fixed", "amountMinor": NSNull()], "taxesMinor": NSNull(),
                "depositsMinor": NSNull(), "discountsMinor": NSNull(), "observedAt": "2026-11-10T12:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"]])
    }
    private func legacy(emptyCatalog: Bool = false) throws -> SharedTrackingPage {
        var value: Any = F.fixture()
        value = F.edit(value, "status", "legacy")
        value = F.edit(value, "state.graph.revision", 0)
        for key in ["lines", "contributions", "edges", "usedIds"] { value = F.edit(value, "state.graph." + key, []) }
        value = F.edit(value, "state.packReviews", [])
        value = F.edit(value, "state.unbound.0.transferred", NSNull())
        value = F.edit(value, "state.legacyLineIds", [F.id(10), F.id(11)])
        value = F.edit(value, "coverage.trackedSubtotals", [])
        value = F.edit(value, "coverage.untrackedBasketIds", [F.id(10), F.id(11)])
        if emptyCatalog {
            value = F.edit(value, "state.catalog", []); value = F.edit(value, "state.unbound", [])
            value = F.edit(value, "coverage.unboundFactIds", []); value = F.edit(value, "coverage.protectedUnboundFactIds", [])
        }
        return try F.page(value)
    }
    private func authored(_ draft: inout TrackingFlowDraft, index: Int) {
        draft.manuals[index].enabled = true; draft.manuals[index].name = "Authored food \(index)"
        draft.manuals[index].original = "Independent wording \(index)"; draft.manuals[index].productConfirmed = true
        draft.packs[index].acceptUnresolved = true
    }
    private func validateAdoption(_ change: SharedDemandChange, packs: [SharedDemandPackReview], basket: [ShopperBasketLine], catalog: [[String: Any]]) throws -> SharedTrackingState {
        // Build only the proposed first-adoption shape in this test, then run
        // the real strict graph/partition decoder. This is not app reduction.
        let graph = SharedDemandGraph(householdId: .init(UUID(uuidString: F.id(1))!), shopId: .init(UUID(uuidString: F.id(2))!), revision: 1,
            lines: change.lines, contributions: change.contributions, edges: change.edges,
            usedIds: change.lines.map(\.id) + change.contributions.map(\.id) + change.edges.map(\.id))
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        return try decode(["schemaVersion": 2, "authorityEpoch": 3, "privacyRevision": 5, "quoteDigest": String(repeating: "a", count: 64),
            "graph": try object(graph), "basket": basket.map { ["id": $0.lineId, "name": $0.originalItem, "packs": $0.packs,
                "priceMinor": $0.unitPriceMinor.map { $0 as Any } ?? NSNull(), "feeEligible": $0.feeEligible] },
            "catalog": catalog, "bindings": catalog.map { ["factId": $0["id"]!, "contributionId": $0["id"]!] },
            "unbound": [], "legacyLineIds": [], "packReviews": try object(packs)])
    }
    func testPartialReviewKeepsUnboundAndDoesNotReviewLegacyBasketAsTracked() throws {
        let page = try F.page(F.fixture()), shop = try shop()
        let draft = try TrackingFlowDraft(page: page, shop: shop)
        guard case .review(let action, let packs) = try draft.intent(page: page, shop: shop), case .patch(let patch) = action else { return XCTFail() }
        XCTAssertEqual(packs.map(\.lineId.string), [F.id(10)])
        XCTAssertEqual(packs[0].usablePerPack, page.state?.packReviews.first?.usablePerPack)
        XCTAssertEqual(patch.lines, shop.lines)
        XCTAssertEqual(page.state?.unbound.count, 1)
        XCTAssertEqual(page.coverage?.completeFoodCoverage, false)
        XCTAssertEqual(page.coverage?.allocatableUnboundFactIds, [])
    }
    func testCatalogAdoptionRequiresEveryExplicitBindingAndPreservesProtectedUnknownFacts() throws {
        let page = try legacy(), shop = try shop()
        var draft = try TrackingFlowDraft(page: page, shop: shop)
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
        draft.facts[0].productConfirmed = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop)) // unrelated legacy row still needs an authored source
        authored(&draft, index: 0)
        guard case .adopt(_, let change, let packs) = try draft.intent(page: page, shop: shop) else { return XCTFail() }
        let source = try XCTUnwrap(change.contributions.first(where: { $0.source != .manual })), fact = try XCTUnwrap(page.state?.catalog.first)
        XCTAssertEqual(source.id, fact.id); XCTAssertEqual(source.source, fact.source)
        XCTAssertEqual(source.quantity, fact.quantity); XCTAssertNil(source.quantity)
        XCTAssertEqual(source.sourceExclusions, fact.sourceExclusions)
        XCTAssertEqual(source.originalText, fact.originalText)
        XCTAssertEqual(Set(packs.map(\.lineId)), Set(draft.packs.map(\.id)))
        let catalog = (F.fixture()["state"] as! [String: Any])["catalog"] as! [[String: Any]]
        let state = try validateAdoption(change, packs: packs, basket: shop.lines, catalog: catalog)
        XCTAssertTrue(state.legacyLineIds.isEmpty); XCTAssertTrue(state.unbound.isEmpty)
        draft.facts = []; XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
    }
    func testEveryLegacyBasketRowNeedsIndependentAuthoredSourceAndUnknownPackReview() throws {
        let page = try legacy(emptyCatalog: true), shop = try shop()
        var draft = try TrackingFlowDraft(page: page, shop: shop)
        XCTAssertEqual(draft.manuals.count, 2)
        XCTAssertTrue(draft.manuals.allSatisfy { !$0.enabled && $0.name.isEmpty && $0.original.isEmpty && $0.amount.unknown && !$0.productConfirmed })
        authored(&draft, index: 0)
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
        authored(&draft, index: 1)
        guard case .adopt(_, let change, let packs) = try draft.intent(page: page, shop: shop) else { return XCTFail() }
        XCTAssertEqual(Set(change.contributions.map(\.id)).count, 2)
        XCTAssertEqual(change.contributions.map(\.originalText), ["Independent wording 0", "Independent wording 1"])
        XCTAssertTrue(change.contributions.allSatisfy { $0.source == .manual && $0.quantity == nil })
        XCTAssertTrue(packs.allSatisfy { $0.usablePerPack == nil && $0.acceptUnresolved })
        let state = try validateAdoption(change, packs: packs, basket: shop.lines, catalog: [])
        XCTAssertEqual(Set(state.graph.lines.map(\.id)), Set(state.basket.map(\.id))); XCTAssertTrue(state.legacyLineIds.isEmpty)
        draft.manuals[1].lineID = draft.manuals[0].lineID
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
    }
    func testInitialRequestAddAndLinkKeepUnrelatedManualRowsReachable() throws {
        for adding in [false, true] {
            let page = try legacy(emptyCatalog: true), shop = try shop()
            let newLine: ShopperBasketLine = try decode(["lineId": F.id(12), "originalItem": "Requested cereal", "packs": 2, "unitPriceMinor": NSNull(), "feeEligible": true])
            let decision: ShopperDecision = adding ? .add(line: newLine, promote: false) : .link(lineID: shop.lines[1].lineId, promote: false)
            let request: OwnRequest = try decode(["requestId": F.id(70), "shopId": shop.shopId, "revision": 6, "originalItem": "Author cereal", "ownQuantity": "One family box",
                "authoredAt": "2026-11-10T00:00:00Z", "receivedAt": "2026-11-10T00:00:00Z", "route": "current", "status": "pending", "ownActionAllowed": true])
            let preview: ShopperPreview = try decode(["previewId": F.id(71), "expiresAt": "2099-01-01T00:00:00Z", "shopRevision": shop.shopRevision, "authorityEpoch": shop.authorityEpoch,
                "requestRevision": 6, "choice": decision.choice, "before": F.checkout, "after": F.checkout, "changeMinor": NSNull(), "requiresOverageAcceptance": false, "requiresUnknownAcceptance": true])
            let context = TrackingRequestContext(reviewed: .init(request: request, shop: shop, decision: decision, preview: preview), acceptOverage: false, acceptUnknown: true)
            let target = try XCTUnwrap(context.target)
            let source: [String: Any] = ["id": F.id(72), "revision": 6, "source": ["kind": "request", "requestId": F.id(70), "appliedRequestRevision": 6],
                "sourceLabel": "Request", "productName": "Author cereal", "originalText": "Author cereal", "originalQuantityText": "One family box",
                "quantity": NSNull(), "sourceExclusions": [], "requiredLineId": target.lineId]
            let catalog: SharedTrackingActionSources = try decode(["schemaVersion": 2, "shopId": shop.shopId,
                "base": ["shopRevision": shop.shopRevision, "authorityEpoch": shop.authorityEpoch, "graphRevision": 0, "stateDigest": page.basisDigest.value],
                "normalizedAction": try JSONSerialization.jsonObject(with: JSONEncoder().encode(context.action)), "actionDigest": String(repeating: "e", count: 64), "sources": [source]])
            try catalog.validate(page: page, action: context.action, requestPreview: preview)
            var draft = try TrackingFlowDraft(page: page, shop: shop, request: context, actionSources: catalog)
            draft.requestMatched = true
            XCTAssertThrowsError(try draft.intent(page: page, shop: shop, request: context, actionSources: catalog))
            for index in draft.manuals.indices where draft.manuals[index].lineID?.string != target.lineId { authored(&draft, index: index) }
            for index in draft.packs.indices { draft.packs[index].acceptUnresolved = true }
            guard case .adopt(_, let change, let packs) = try draft.intent(page: page, shop: shop, request: context, actionSources: catalog) else { return XCTFail() }
            var fact = source; fact.removeValue(forKey: "productName")
            let state = try validateAdoption(change, packs: packs, basket: context.basket, catalog: [fact])
            XCTAssertTrue(state.legacyLineIds.isEmpty); XCTAssertTrue(state.unbound.isEmpty)
            XCTAssertEqual(change.contributions.filter { $0.source == .manual }.count, adding ? 2 : 1)
            XCTAssertTrue(change.contributions.allSatisfy { $0.quantity == nil })
        }
    }
    func testRequiredBasketIdentityCannotBeReassignedByPicker() throws {
        let page = try legacy(), shop = try shop(); var draft = try TrackingFlowDraft(page: page, shop: shop)
        draft.facts[0].productConfirmed = true; draft.facts[0].lineID = SharedDemandID(UUID(uuidString: F.id(10))!)
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
    }
    func testManualAdoptionDoesNotCopyExistingBasketLabelOrInferQuantityFromPacks() throws {
        let page = try legacy(), shop = try shop(); var draft = try TrackingFlowDraft(page: page, shop: shop)
        XCTAssertEqual(draft.manual.name, ""); XCTAssertEqual(draft.manual.original, "")
        draft.facts[0].productConfirmed = true; draft.manual.enabled = true
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
        draft.manual.name = "Authored apples"; draft.manual.original = "Family's independent words"; draft.manual.productConfirmed = true
        guard case .adopt(_, let change, _) = try draft.intent(page: page, shop: shop), let manual = change.contributions.first(where: { $0.source == .manual }) else { return XCTFail() }
        XCTAssertEqual(manual.originalText, "Family's independent words"); XCTAssertNil(manual.quantity)
        XCTAssertEqual(manual.id, draft.manual.id)
    }
    func testRebindRequiresTransferProofAndPreservesExistingBasketAndHistoricalLine() throws {
        let page = try F.page(F.fixture()), shop = try shop(); var draft = try TrackingFlowDraft(page: page, shop: shop)
        draft.rebindFactID = .init(UUID(uuidString: F.id(22))!)
        XCTAssertThrowsError(try draft.rebind(page: page))
        draft.rebindConfirmed = true; draft.rebindName = "Unrelated renamed source"; draft.rebindPrice = "900"
        guard case .rebind(let bindings) = try draft.rebind(page: page) else { return XCTFail() }
        let binding = try XCTUnwrap(bindings.first)
        XCTAssertEqual(binding.line.name, "Wraps"); XCTAssertNil(binding.line.trashedAt)
        XCTAssertEqual(binding.basket, page.state?.basket.last)
        XCTAssertEqual(binding.factId.string, F.id(22))
        draft.rebindFactID = .init(UUID(uuidString: F.id(20))!); XCTAssertThrowsError(try draft.rebind(page: page))
    }
    func testPrivacyRecoveryHasFreshPacksAndCannotCarryManualDraft() throws {
        let page = try F.page(F.projectionFixture()), shop = try shop(F.projectionFixture())
        var draft = try TrackingFlowDraft(page: page, shop: shop)
        guard case .recover(let packs) = try draft.intent(page: page, shop: shop) else { return XCTFail() }
        XCTAssertEqual(packs.count, 1); XCTAssertNil(packs.first?.usablePerPack)
        XCTAssertFalse(packs[0].acceptUnresolved)
        draft.manual.enabled = true; XCTAssertThrowsError(try draft.intent(page: page, shop: shop))
    }
    func testChangedShopBasisFailsBeforeIntent() throws {
        let page = try F.page(F.fixture()), changed = try shop(F.edit(F.fixture(), "shopRevision", 9))
        XCTAssertThrowsError(try TrackingFlowDraft(page: page, shop: changed))
    }
    func testUnknownAmountDoesNotParseStaleTextAndKnownAmountNeedsPositiveExactRational() throws {
        var value = TrackingAmountEntry(); value.numerator = "bad"; XCTAssertNil(try value.value())
        value.unknown = false; XCTAssertThrowsError(try value.value())
        value.numerator = "3"; value.denominator = "2"; XCTAssertEqual(try value.value()?.amount, try .init(numerator: 3, denominator: 2))
        value.denominator = "0"; XCTAssertThrowsError(try value.value())
        value.denominator = "1"; value.numerator = "-1"; XCTAssertThrowsError(try value.value())
    }
    func testOrdinaryPackReviewPreservesExactLiteralAndConversionButRequiresFreshUnknownAck() throws {
        let original = try F.page(F.fixture()), shop = try shop()
        let draft = try TrackingFlowDraft(page: original, shop: shop)
        XCTAssertEqual(try draft.packs[0].review().usablePerPack, original.state?.packReviews.first?.usablePerPack)
        XCTAssertEqual(try draft.packs[0].review().usablePerPack?.originalLiteral, "4 wraps")
        XCTAssertFalse(draft.packs[0].acceptUnresolved)
        var quantity = try XCTUnwrap(original.state?.packReviews.first?.usablePerPack)
        quantity.confirmedConversion = .init(sourceUnit: .count, targetUnit: .gram,
            targetAmountPerSourceUnit: try .init(numerator: 40), sourceNote: "Weighed one apple", confirmedAt: "2026-11-10T12:00:00Z")
        let input = TrackingAmountEntry(quantity)
        XCTAssertEqual(try input.value(), quantity)
    }
    func testFixedConversionPreservesAuthoritativeCoreAndRejectsReplacementOrMissingEvidence() throws {
        let quantity = SharedDemandQuantity(amount: try .init(numerator: 1), unit: .cup, originalLiteral: "one original cup")
        var entry = TrackingFixedConversionEntry(); entry.enabled = true; entry.target = .gram; entry.numerator = "240"
        XCTAssertThrowsError(try entry.apply(to: quantity))
        entry.note = "Weighed this ingredient"
        let converted = try XCTUnwrap(entry.apply(to: quantity))
        XCTAssertEqual(converted.amount, quantity.amount); XCTAssertEqual(converted.unit, quantity.unit)
        XCTAssertEqual(converted.originalLiteral, quantity.originalLiteral)
        XCTAssertEqual(converted.confirmedConversion?.targetAmountPerSourceUnit.numerator, 240)
        XCTAssertThrowsError(try entry.apply(to: nil)); XCTAssertThrowsError(try entry.apply(to: converted))
    }

    func testReviewAcknowledgementsAreIndependentAndResetTogether() {
        var gate = TrackingReviewGate(); XCTAssertFalse(gate.canApply)
        gate.changes = true; XCTAssertFalse(gate.canApply)
        gate.pickup = true; XCTAssertTrue(gate.canApply)
        gate.reset(); XCTAssertFalse(gate.changes); XCTAssertFalse(gate.pickup)
    }
    func testInitialMealCatalogUsesAllServerFactsAndExplicitMappings() throws {
        let page = try legacy(), shop = try shop()
        let edit = SharedDemandMealEdit(occurrenceId: .init(UUID(uuidString: F.id(99))!), baseMealRevision: nil,
            meal: .init(title: "New dinner", day: nil, kind: "dinner", portions: 2, protected: false))
        let action = SharedDemandAction.patch(.init(quote: shop.quote, lines: shop.lines, mealEdit: edit))
        var protected = ((F.fixture()["state"] as! [String: Any])["catalog"] as! [[String: Any]])[0]
        protected["productName"] = "Wraps"
        let added: [String: Any] = ["id": F.id(55), "revision": 9,
            "source": ["kind": "meal", "occurrenceId": F.id(99), "ingredientId": F.id(56), "groupId": NSNull(), "bindingId": NSNull()],
            "sourceLabel": "New dinner", "productName": "Apples", "originalText": "One cup of apples", "originalQuantityText": NSNull(),
            "quantity": ["amount": ["numerator": "1", "denominator": "1"], "unit": "cup", "originalLiteral": "one original cup", "confirmedConversion": NSNull()],
            "sourceExclusions": [], "requiredLineId": NSNull()]
        let catalog: SharedTrackingActionSources = try decode(["schemaVersion": 2, "shopId": page.shopId.string,
            "base": ["shopRevision": page.shopRevision, "authorityEpoch": page.authorityEpoch, "graphRevision": 0, "stateDigest": page.basisDigest.value],
            "normalizedAction": try JSONSerialization.jsonObject(with: JSONEncoder().encode(action)), "actionDigest": String(repeating: "e", count: 64), "sources": [protected, added]])
        try catalog.validate(page: page, action: action)
        var draft = try TrackingFlowDraft(page: page, shop: shop, actionSources: catalog)
        XCTAssertEqual(draft.facts.map(\.fact), catalog.sources.map(\.fact))
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit, actionSources: catalog))
        draft.facts[0].productConfirmed = true; draft.facts[1].productConfirmed = true
        draft.facts[1].lineID = .init(UUID(uuidString: F.id(10))!); draft.packs[0].lineUnit = .cup
        guard case .adopt(let proposed, let change, let packs) = try draft.intent(page: page, shop: shop, mealEdit: edit, actionSources: catalog) else { return XCTFail() }
        XCTAssertEqual(proposed, catalog.normalizedAction.command)
        XCTAssertEqual(change.contributions.map(\.id), catalog.sources.map { $0.fact.id })
        XCTAssertNil(change.contributions[0].quantity)
        XCTAssertEqual(change.contributions[1].quantity?.originalLiteral, "one original cup")
        XCTAssertEqual(Set(packs.map(\.lineId)), Set(draft.packs.map(\.id)))
        draft.facts.removeLast()
        XCTAssertThrowsError(try draft.intent(page: page, shop: shop, mealEdit: edit, actionSources: catalog))
    }

}
