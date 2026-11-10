import XCTest
import SwiftUI
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedMealFoodFlowTests: XCTestCase {
    private let household = SharedDemandID(), shopID = SharedDemandID(), lineID = SharedDemandID(), occurrence = SharedDemandID(), ingredient = SharedDemandID()
    private let at = "2026-11-09T12:00:00Z", digest = String(repeating: "a", count: 64)
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func decode<T: Decodable>(_ value: Any, as: T.Type = T.self) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func quantity(_ n: Int64) throws -> SharedDemandQuantity { .init(amount: try .init(numerator: n), unit: .count, originalLiteral: "\(n)") }
    private func fixture(protected: Bool = false, unknown: Bool = false, retirement: Bool = false, relationship: Bool = false) throws -> (SharedDemandPage, ShopperShop, SharedMealFoodContext, SharedFoodDraft) {
        let mealSource: SharedDemandSource = protected ? .reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: occurrence, ingredientId: ingredient, groupId: .init(), bindingId: nil) : .meal(occurrenceId: occurrence, ingredientId: ingredient, groupId: nil, bindingId: nil)
        let source = SharedDemandContribution(lineId: lineID, source: mealSource, productKey: "wraps", productName: "Wraps", originalText: "Original source wording", quantity: unknown ? nil : try quantity(protected ? 2 : 6))
        let manual = SharedDemandContribution(lineId: lineID, source: .manual, productKey: "wraps", productName: "Wraps", originalText: "Manual twelve", quantity: try quantity(12))
        let lunch = SharedDemandContribution(lineId: lineID, source: .reservation(reservationId: .init(), purpose: "Other lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil), productKey: "wraps", productName: "Wraps", originalText: "Other protected lunch", quantity: try quantity(2))
        let edge = SharedDemandEdge(kind: .withinExisting, demandId: source.id, supplyId: manual.id, quantity: try quantity(6), confirmation: .init(confirmedAt: at, evidence: "Six from twelve"))
        let graph = SharedDemandGraph(householdId: household, shopId: shopID, revision: 3, lines: [.init(id: lineID, name: "Wraps", unit: .count, originalOrder: 0)], contributions: [manual, source, lunch], edges: relationship ? [edge] : [], usedIds: [lineID, manual.id, source.id, lunch.id] + (relationship ? [edge.id] : []))
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 4000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let basket = [ShopperBasketLine(lineId: lineID.uuid, originalItem: "Wraps", packs: 3, unitPriceMinor: 250, feeEligible: true)]
        let shop: ShopperShop = try decode(["shopId": shopID.string, "shopRevision": 4, "authorityEpoch": 2, "phase": "draft", "meals": [], "quote": object(quote), "lines": object(basket), "frozenRevision": NSNull(), "placedRevision": NSNull()])
        let page: SharedDemandPage = try decode(["schemaVersion": 1, "shopId": shopID.string, "shopRevision": 4, "authorityEpoch": 2, "status": "enabled", "graphDigest": digest, "graph": object(graph), "totals": [["lineId": lineID.string, "unit": "count", "quantity": NSNull(), "activeContributionIds": graph.contributions.map { $0.id.string }]]])
        let edit = SharedDemandMealEdit(occurrenceId: occurrence, baseMealRevision: 2, meal: retirement ? nil : .init(title: "Updated dinner", day: nil, kind: "dinner", portions: 3, protected: false), changeProposalId: .init())
        let request = try SharedDemandActionSourceRequest(page: page, patch: .init(quote: quote, lines: basket, mealEdit: edit))
        func row(_ before: SharedDemandContribution, next: SharedDemandQuantity?, transition: String) throws -> [String: Any] {
            ["before": try object(before), "transition": transition, "proposed": ["id": before.id.string, "source": try object(before.source), "sourceLabel": "Updated dinner", "productName": before.productName, "originalText": before.originalText, "originalQuantityText": next?.originalLiteral as Any? ?? NSNull(), "quantity": try next.map(object) ?? NSNull(), "sourceExclusions": [], "requiredLineId": before.lineId.string]]
        }
        let rows = try (retirement ? [] : [row(source, next: quantity(protected ? 3 : 8), transition: protected && unknown ? "quantifyReservation" : "update")]) + [row(lunch, next: lunch.quantity, transition: "retain")]
        let catalog: SharedDemandActionSources = try decode(["schemaVersion": 1, "shopId": shopID.string, "base": object(request.base), "graphDigest": digest, "actionDigest": String(repeating: "b", count: 64), "normalizedAction": object(request.action), "sources": rows, "retirementCandidates": retirement ? [source.id.string] : [], "retainedContributionIds": [manual.id.string]])
        let context = try SharedMealFoodContext(page: page, request: request, catalog: catalog)
        var draft = try SharedFoodDraft(page: page, shop: shop, candidate: .init(quote: quote, lines: basket))
        try context.prepare(&draft, page: page)
        draft.lines[0].acceptUnresolved = true
        return (page, shop, context, draft)
    }
    private func confirm(_ draft: inout SharedFoodDraft) {
        draft.mealSourcesReviewed = true
        for i in draft.sources.indices { draft.sources[i].productConfirmed = true }
        for i in draft.mealRetirements.indices { draft.mealRetirements[i].confirmed = true }
        for i in draft.mealRelationships.indices { draft.mealRelationships[i].decision = .keep }
    }
    func testMealActionTrimsOnlyServerContractEdgesAndPreservesExactIdentityAndQuantityFacts() throws {
        let (page, _, context, _) = try fixture()
        guard case .patch(var patch) = context.request.action else { return XCTFail() }
        let group = UUID(), ingredient = UUID(), binding = UUID(), origin = UUID()
        let quantity = SharedMealQuantity(amount: .init(numerator: 2, denominator: 4), unit: "cup", originalLiteral: "\t 2/4  cups \u{00A0}")
        let meal = SharedMeal(title: "\u{FEFF}\u{00A0}Tacos  night\u{3000}", day: nil, kind: "dinner", portions: 3, protected: false,
            planning: .init(groups: [.init(id: group, name: "\u{2003}Lunch  group\u{2029}", servings: .init(numerator: 2, denominator: 4), protected: true)],
                ingredients: [.init(id: ingredient, name: "\u{202F}Flour  blend\u{205F}", quantity: quantity, groupIds: [group], exclusions: ["\u{1680}No  sesame\u{200A}"]),
                    .init(name: " Unknown  spice ", quantity: nil, groupIds: [], exclusions: [])], sourceOccurrenceId: origin,
                bindings: [.init(id: binding, groupId: group, ingredientId: ingredient, quantity: quantity)], exclusions: ["\rNo  peanuts\n"], leadTimeMinutes: 25, completedSteps: ["\u{2000}Soak  slowly\u{2001}"]))
        patch.mealEdit?.meal = meal
        let original = patch, request = try SharedDemandActionSourceRequest(page: page, patch: patch)
        guard case .patch(let canonical) = request.action, let actual = canonical.mealEdit?.meal else { return XCTFail() }
        var expected = meal; expected.title = "Tacos  night"
        expected.planning?.groups[0].name = "Lunch  group"
        expected.planning?.ingredients[0].name = "Flour  blend"; expected.planning?.ingredients[0].quantity?.originalLiteral = "2/4  cups"
        expected.planning?.ingredients[0].exclusions = ["No  sesame"]; expected.planning?.ingredients[1].name = "Unknown  spice"
        expected.planning?.bindings?[0].quantity.originalLiteral = "2/4  cups"
        expected.planning?.exclusions = ["No  peanuts"]; expected.planning?.completedSteps = ["Soak  slowly"]
        XCTAssertEqual(actual, expected); XCTAssertEqual(patch, original)
        var expectedPatch = original; expectedPatch.mealEdit?.meal = expected
        XCTAssertEqual(canonical, expectedPatch)
        XCTAssertEqual(actual.planning?.ingredients[0].quantity?.amount, .init(numerator: 2, denominator: 4))
        XCTAssertEqual(actual.planning?.bindings?[0].id, binding); XCTAssertEqual(actual.planning?.sourceOccurrenceId, origin)
        XCTAssertNil(actual.planning?.ingredients[1].quantity)
        patch.mealEdit?.meal?.title = "\u{0085}\u{200B}Keep these edges\u{200B}\u{0085}"
        guard case .patch(let unchanged) = try SharedDemandActionSourceRequest(page: page, patch: patch).action else { return XCTFail() }
        XCTAssertEqual(unchanged.mealEdit?.meal?.title, patch.mealEdit?.meal?.title)
    }
    private func conversionFixture() throws -> (SharedDemandPage, ShopperShop, SharedMealFoodContext, SharedFoodDraft) {
        var (page, shop, context, _) = try fixture(relationship: true)
        var graph = try XCTUnwrap(page.graph)
        let basis = SharedDemandConversion(sourceUnit: .cup, targetUnit: .gram, targetAmountPerSourceUnit: try .init(numerator: 120), sourceNote: "Old reviewed density", confirmedAt: at)
        graph.lines[0].unit = .gram
        graph.contributions[0].quantity = .init(amount: try .init(numerator: 240), unit: .gram, originalLiteral: "240 grams")
        graph.contributions[1].quantity = .init(amount: try .init(numerator: 1), unit: .cup, originalLiteral: "1 cup", confirmedConversion: basis)
        graph.contributions[2].quantity = .init(amount: try .init(numerator: 2), unit: .gram, originalLiteral: "2 grams")
        graph.edges[0].quantity = .init(amount: try .init(numerator: 120), unit: .gram, originalLiteral: "120 grams already included", confirmedConversion: basis)
        page.graph = graph
        var pageObject = try XCTUnwrap(self.object(page) as? [String: Any])
        pageObject["totals"] = [["lineId": lineID.string, "unit": "gram", "quantity": ["numerator": "242", "denominator": "1"], "activeContributionIds": graph.contributions.map { $0.id.string }]]
        page = try decode(pageObject)
        let fresh = SharedDemandQuantity(amount: try .init(numerator: 2), unit: .cup, originalLiteral: "2  cups, measured")
        var object = try XCTUnwrap(self.object(context.catalog) as? [String: Any])
        var rows = try XCTUnwrap(object["sources"] as? [[String: Any]])
        for (rowIndex, graphIndex, quantity) in [(0, 1, fresh), (1, 2, try XCTUnwrap(graph.contributions[2].quantity))] {
            rows[rowIndex]["before"] = try self.object(graph.contributions[graphIndex])
            var proposed = try XCTUnwrap(rows[rowIndex]["proposed"] as? [String: Any])
            proposed["quantity"] = try self.object(quantity); proposed["originalQuantityText"] = quantity.originalLiteral
            rows[rowIndex]["proposed"] = proposed
        }
        object["sources"] = rows
        context = try .init(page: page, request: context.request, catalog: decode(object))
        var draft = try SharedFoodDraft(page: page, shop: shop, candidate: .init(quote: shop.quote, lines: shop.lines))
        try context.prepare(&draft, page: page); confirm(&draft); draft.lines[0].acceptUnresolved = true
        return (page, shop, context, draft)
    }
    func testChangedFixedMealQuantityNeedsExplicitFreshBasisAndPreservesKeptRelationship() throws {
        var (page, shop, context, draft) = try conversionFixture()
        let authoritative = draft.sources[0].fixedQuantity
        XCTAssertNil(authoritative?.confirmedConversion)
        let unresolved = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertNil(unresolved.change.contributions[0].quantity?.confirmedConversion)
        draft.sources[0].fixedConversion = .init(enabled: true, targetUnit: .gram, rate: "120", note: "New measurement: one cup is 120 grams")
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        let actual = try XCTUnwrap(request.change.contributions[0].quantity)
        XCTAssertEqual(actual.amount, authoritative?.amount); XCTAssertEqual(actual.unit, authoritative?.unit)
        XCTAssertEqual(actual.originalLiteral, "2  cups, measured"); XCTAssertEqual(draft.sources[0].fixedQuantity, authoritative)
        XCTAssertEqual(actual.confirmedConversion?.sourceUnit, .cup); XCTAssertEqual(actual.confirmedConversion?.targetUnit, .gram)
        XCTAssertEqual(actual.confirmedConversion?.targetAmountPerSourceUnit, try .init(numerator: 120))
        XCTAssertEqual(actual.confirmedConversion?.sourceNote, "New measurement: one cup is 120 grams")
        XCTAssertTrue(request.change.edges.isEmpty); XCTAssertTrue(request.change.removeEdgeIds.isEmpty)
        XCTAssertEqual(draft.mealRelationships[0].edge, page.graph?.edges[0]); XCTAssertEqual(draft.mealRelationships[0].decision, .keep)
    }
    func testFixedConversionRejectsInvalidBasisAndNeverUnlocksOtherFixedFacts() throws {
        let (page, shop, context, original) = try conversionFixture()
        for (target, rate, note) in [(SharedDemandUnit.cup, "120", "Wrong dimension"), (.count, "120", "Wrong target"), (.gram, "0", "Zero"), (.gram, "-2", "Negative"), (.gram, "120", "   ")] {
            var draft = original; draft.sources[0].fixedConversion = .init(enabled: true, targetUnit: target, rate: rate, note: note)
            XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        }
        var draft = original; draft.sources[0].fixedConversion = .init(enabled: true, targetUnit: .gram, rate: "120", note: "Reviewed")
        let source = draft.sources[0], line = draft.lines[0]
        XCTAssertThrowsError(try source.contribution(line: line, productKey: "wraps", at: at), "A fixed request/legacy source cannot enable the meal-only conversion path")
        draft.sources[0].fixedQuantity?.originalLiteral = "Rewritten authoritative fact"
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        var known = try XCTUnwrap(original.sources[0].fixedQuantity)
        known.confirmedConversion = .init(sourceUnit: .cup, targetUnit: .gram, targetAmountPerSourceUnit: try .init(numerator: 120), sourceNote: "Existing evidence", confirmedAt: at)
        XCTAssertThrowsError(try source.fixedConversion.apply(to: known, lineUnit: .gram, permitted: true, at: at))
        XCTAssertThrowsError(try source.fixedConversion.apply(to: nil, lineUnit: .gram, permitted: true, at: at))
        XCTAssertThrowsError(try source.fixedConversion.apply(to: original.sources[0].fixedQuantity, lineUnit: .cup, permitted: true, at: at))
    }
    private func convertedReview(_ request: SharedDemandPreviewRequest, page: SharedDemandPage) throws -> SharedDemandReview {
        let before = try XCTUnwrap(page.graph); var after = before; after.revision += 1
        let changed = try XCTUnwrap(request.change.contributions.first)
        after.contributions[1] = changed
        let total: [[String: Any]] = [["lineId": lineID.string, "unit": "gram", "quantity": ["numerator": "362", "denominator": "1"], "activeContributionIds": after.contributions.map { $0.id.string }]]
        let preview: [String: Any] = ["previewId": SharedDemandID().string, "previewDigest": digest, "expiresAt": "2099-01-01T00:00:00Z", "before": try object(before), "after": try object(after), "beforeTotals": try object(page.totals), "afterTotals": total,
            "packs": try object(request.packs), "shopRevision": page.shopRevision, "authorityEpoch": page.authorityEpoch,
            "receipt": ["schemaVersion": 1, "operationId": SharedDemandID().string, "householdId": household.string, "shopId": shopID.string, "baseRevision": before.revision, "resultRevision": after.revision, "lines": [], "edges": [], "contributions": [["id": changed.id.string, "before": try object(before.contributions[1]), "after": try object(changed)]]]]
        let review: SharedDemandReview = try decode(["context": ["subject": "fixture", "householdID": household.string, "memberID": "fixture", "deviceID": "fixture"], "shopID": shopID.uuid.uuidString, "request": object(request), "preview": preview])
        try review.validate(); return review
    }
    func testChangedConversionEvidenceInvalidatesCompletedAndHeldPreview() async throws {
        let (page, shop, context, draft) = try conversionFixture()
        let editor = try SharedFoodEditorContext(shop: shop, page: page, candidate: .init(quote: shop.quote, lines: shop.lines), meal: context)
        let access = MealDraftAccess(page: page, shop: shop); access.foodEditorID = editor.id
        access.reviewBuilder = { try self.convertedReview($0, page: page) }
        let flow = SharedDemandFlowModel(access: access, editor: editor); await flow.load(); flow.draft = draft
        flow.draft.sources[0].fixedConversion = .init(enabled: true, targetUnit: .gram, rate: "120", note: "Reviewed density")
        await flow.preview(); XCTAssertNotNil(flow.review); flow.acknowledged = true
        flow.draft.sources[0].fixedConversion.note = "Rechecked density"
        XCTAssertNil(flow.review); XCTAssertFalse(flow.acknowledged)
        access.holdPreview = true
        let task = Task { await flow.preview() }
        for _ in 0..<1000 { if access.previewContinuation != nil { break }; await Task.yield() }
        let continuation = try XCTUnwrap(access.previewContinuation), held = try XCTUnwrap(access.heldReview)
        flow.draft.sources[0].fixedConversion.rate = "121"
        continuation.resume(returning: held); await task.value
        XCTAssertNil(flow.review); XCTAssertFalse(flow.acknowledged)
        await flow.apply(); XCTAssertEqual(access.applies, 0)
    }
    func testChangedMealNeedsExplicitReviewPreservesProposalQuoteBasketAndUntouchedSources() throws {
        var (page, shop, context, draft) = try fixture()
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        confirm(&draft)
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertEqual(request.action, context.request.action)
        XCTAssertEqual(request.change.contributions.count, 1)
        XCTAssertEqual(request.change.contributions[0].id, context.catalog.sources[0].before?.id)
        XCTAssertEqual(request.change.contributions[0].originalText, "Original source wording")
        XCTAssertEqual(request.change.contributions[0].quantity?.amount.numerator, 8)
        XCTAssertFalse(request.change.contributions.contains { $0.originalText == "Manual twelve" || $0.originalText == "Other protected lunch" })
        XCTAssertTrue(request.change.removeSourceIds.isEmpty); XCTAssertNil(request.change.quantifyReservationIds)
    }
    func testRemovalOnlyTargetsExactRetirementAndKeepsManualAndOtherLunch() throws {
        var (page, shop, context, draft) = try fixture(retirement: true)
        draft.mealSourcesReviewed = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        confirm(&draft)
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertEqual(request.change.removeSourceIds, context.catalog.retirementCandidates)
        XCTAssertEqual(request.change.removeSourceIds.count, 1); XCTAssertTrue(request.change.contributions.isEmpty)
        XCTAssertTrue(request.change.edges.isEmpty)
    }
    func testProtectedUnknownSameBindingRequiresExplicitQuantificationAndStableIdentity() throws {
        var (page, shop, context, draft) = try fixture(protected: true, unknown: true)
        confirm(&draft)
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.sources[0].quantificationConfirmed = true
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertEqual(request.change.quantifyReservationIds, [draft.sources[0].id])
        XCTAssertEqual(request.change.contributions[0].source, context.catalog.sources[0].before?.source)
        XCTAssertEqual(request.change.contributions[0].productKey, "wraps")
        XCTAssertEqual(request.change.contributions[0].quantity?.amount.numerator, 3)
    }
    func testRelationshipDecisionIsRequiredAndExplicitRemoveKeepsOriginalEdgeID() throws {
        var (page, shop, context, draft) = try fixture(relationship: true)
        confirm(&draft); draft.mealRelationships[0].decision = .unreviewed
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.mealRelationships[0].decision = .remove
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertEqual(request.change.removeEdgeIds, page.graph?.edges.map(\.id)); XCTAssertTrue(request.change.edges.isEmpty)
    }
    func testRemovedSourceCannotKeepItsOldRelationship() throws {
        var (page, shop, context, draft) = try fixture(retirement: true, relationship: true)
        confirm(&draft)
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.mealRelationships[0].decision = .remove
        XCTAssertEqual(try draft.request(page: page, shop: shop, at: at, mealContext: context).change.removeEdgeIds.count, 1)
    }
    func testAuthoritativeQuantityOriginalTextAndProposalCannotBeChangedInFoodForm() throws {
        let (page, shop, context, original) = try fixture()
        for mutation in 0..<4 {
            var draft = original; confirm(&draft)
            if mutation == 0 { draft.sources[0].fixedQuantity = try quantity(99) }
            if mutation == 1 { draft.sources[0].originalText = "Rewritten" }
            if mutation == 2 { draft.sources[0].source = .manual }
            if mutation == 3 { draft.sources.removeAll() }
            XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        }
    }
    func testCatalogRejectsWrongDigestActionPartitionAndProtectedRetirement() throws {
        let (page, _, context, _) = try fixture()
        let original = try XCTUnwrap(object(context.catalog) as? [String: Any])
        for mutation in 0..<5 {
            var value = original
            if mutation == 0 { value["graphDigest"] = String(repeating: "c", count: 64) }
            if mutation == 1 { value["retainedContributionIds"] = [] }
            if mutation == 2 { value["retirementCandidates"] = [context.catalog.sources[1].proposed.id.string] }
            if mutation == 3 { var action = try XCTUnwrap(value["normalizedAction"] as? [String: Any]); var body = try XCTUnwrap(action["body"] as? [String: Any]); body["mealEdit"] = NSNull(); action["body"] = body; value["normalizedAction"] = action }
            if mutation == 4 { value["shopId"] = SharedDemandID().string }
            XCTAssertThrowsError(try decode(value, as: SharedDemandActionSources.self).validate(page: page, request: context.request))
        }
    }
    func testNewAuthoritativeUnknownSourceRequiresExplicitLineAndProductMatch() throws {
        let (page, shop, original, _) = try fixture()
        var value = try XCTUnwrap(object(original.catalog) as? [String: Any])
        var rows = try XCTUnwrap(value["sources"] as? [[String: Any]])
        var proposed = try XCTUnwrap(rows[0]["proposed"] as? [String: Any])
        let freshID = SharedDemandID()
        proposed["id"] = freshID.string; proposed["requiredLineId"] = NSNull(); proposed["quantity"] = NSNull()
        proposed["source"] = try object(SharedDemandSource.meal(occurrenceId: occurrence, ingredientId: .init(), groupId: nil, bindingId: nil))
        rows.append(["before": NSNull(), "proposed": proposed, "transition": "new"]); value["sources"] = rows
        let catalog = try decode(value, as: SharedDemandActionSources.self)
        let context = try SharedMealFoodContext(page: page, request: original.request, catalog: catalog)
        var draft = try SharedFoodDraft(page: page, shop: shop, candidate: .init(quote: shop.quote, lines: shop.lines))
        try context.prepare(&draft, page: page); confirm(&draft); draft.lines[0].acceptUnresolved = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.sources[1].lineID = lineID; draft.sources[1].productConfirmed = false
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.sources[1].productConfirmed = true
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        let new = try XCTUnwrap(request.change.contributions.first { $0.id == freshID })
        XCTAssertNil(new.quantity); XCTAssertEqual(new.productKey, "wraps")
        XCTAssertEqual(new.originalText, proposed["originalText"] as? String); XCTAssertTrue(request.change.edges.isEmpty)
    }
    func testRemovingBasketLineCannotDiscardOtherProtectedOrManualNeeds() throws {
        var (page, shop, context, draft) = try fixture(retirement: true)
        confirm(&draft)
        let line = draft.lines.removeFirst()
        draft.removedLines = [.init(line: line, sources: try XCTUnwrap(page.graph).contributions, mealRetirementIDs: Set(context.catalog.retirementCandidates), confirmed: true)]
        XCTAssertTrue(draft.removedLines[0].mustKeep)
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at, mealContext: context))
        draft.restoreRemovedLine(line.id)
        let request = try draft.request(page: page, shop: shop, at: at, mealContext: context)
        XCTAssertEqual(request.change.removeSourceIds, context.catalog.retirementCandidates)
        XCTAssertEqual(draft.lines[0].id, line.id)
    }
    func testRetirementBindingAfterCancelIsRedactedAndCannotReinsertSource() async throws {
        let (page, shop, _, draft) = try fixture(retirement: true)
        let access = MealDraftAccess(page: page, shop: shop)
        let model = SharedDemandFlowModel(access: access)
        await model.load(); model.draft = draft
        let id = try XCTUnwrap(draft.mealRetirements.first).id
        let binding = model.mealRetirementBinding(id); var edited = binding.wrappedValue
        XCTAssertEqual(edited.source.originalText, "Original source wording")
        model.cancel()
        XCTAssertEqual(binding.wrappedValue.source.originalText, "")
        edited.confirmed = true; binding.wrappedValue = edited
        XCTAssertTrue(model.draft.mealRetirements.isEmpty); XCTAssertNil(model.page)
    }
    func testRelationshipBindingAfterReloadCannotEditSameIDInNewGeneration() async throws {
        let (page, shop, _, draft) = try fixture(relationship: true)
        let access = MealDraftAccess(page: page, shop: shop)
        let model = SharedDemandFlowModel(access: access)
        await model.load(); model.draft = draft
        let id = try XCTUnwrap(draft.mealRelationships.first).id
        let old = model.mealRelationshipBinding(id); var edited = old.wrappedValue
        model.cancel(); await model.load(); model.draft = draft
        edited.decision = .remove; old.wrappedValue = edited
        XCTAssertEqual(model.draft.mealRelationships[0].decision, .unreviewed)
        XCTAssertEqual(old.wrappedValue.edge.confirmation.evidence, "")
        let fresh = model.mealRelationshipBinding(id); fresh.wrappedValue = edited
        XCTAssertEqual(model.draft.mealRelationships[0].decision, .remove)
    }
    func testCatalogRequiresExplicitNullAndNeverTreatsMissingDigestAsLegacy() throws {
        let (page, _, context, _) = try fixture()
        var value = try XCTUnwrap(object(context.catalog) as? [String: Any])
        var rows = try XCTUnwrap(value["sources"] as? [[String: Any]])
        rows[0].removeValue(forKey: "before"); value["sources"] = rows
        XCTAssertThrowsError(try decode(value, as: SharedDemandActionSources.self))
        var oldPage = page; oldPage.graphDigest = nil
        guard case .patch(let patch) = context.request.action else { return XCTFail() }
        XCTAssertThrowsError(try SharedDemandActionSourceRequest(page: oldPage, patch: patch))
    }
}

/// Real parent, service transport and durable outbox. The fixture has a meal with
/// no ingredient facts; moving it leaves the independently seeded manual graph exact.
@MainActor final class SharedMealFoodLookupTests: XCTestCase {
    private struct Context {
        let fixture: MealFoodHTTPFixture
        let service: HouseholdService
        let scope: HouseholdBootstrap
        let parent: HouseholdShopModel
        let outbox: OperationOutbox
        let directory: URL
        var outboxURL: URL { directory.appendingPathComponent("shared-shop.json") }
        func close() { fixture.releaseDemandReads(); MealFoodHTTPProtocol.registry.remove(fixture.host); try? FileManager.default.removeItem(at: directory) }
    }
    private func setup(enabled: Bool = true, expiredQuote: Bool = false) async throws -> Context {
        let fixture = MealFoodHTTPFixture(enabled: enabled, expiredQuote: expiredQuote); MealFoodHTTPProtocol.registry.add(fixture)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MealFoodHTTPProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: configuration))
        let url = URL(string: "https://\(fixture.host)")!
        let auth = AdultAuth(configuration: try .init(projectURL: url, publishableKey: "sb_publishable_test"), vault: MealFoodHTTPVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: url), auth: auth, deviceVault: MealFoodHTTPVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "fixture@example.test", code: "123456")
        _ = try await service.enroll(householdID: fixture.household.string)
        let scope = try await service.bootstrap()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = OperationOutbox(url: directory.appendingPathComponent("shared-shop.json"))
        let parent = HouseholdShopModel(scope: scope, service: service, outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        await parent.load(); parent.beginEditing()
        parent.draft.mealEdit = SharedMealEdit(occurrenceID: fixture.occurrence.uuid, meal: .init(title: "Moved tacos", day: "2026-11-12", kind: "dinner", portions: 2, protected: false), proposalID: fixture.proposal.uuid)
        parent.draft.mealEdit?.baseMealRevision = 1
        return .init(fixture: fixture, service: service, scope: scope, parent: parent, outbox: outbox, directory: directory)
    }
    private func awaitHeld(_ fixture: MealFoodHTTPFixture) async throws {
        for _ in 0..<200 {
            if fixture.heldCount == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fixture.releaseDemandReads()
        XCTFail("The exact demand read did not reach the held transport")
        throw ClientError.configuration
    }
    private func changedScope(_ original: HouseholdBootstrap, key: String, value: Any) throws -> HouseholdBootstrap {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object[key] = value
        return try JSONDecoder().decode(HouseholdBootstrap.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testCatalogIsReadOnlyAndPreservesExactEnteredMealProposalQuoteAndBasket() async throws {
        let c = try await setup(); defer { c.close() }
        c.parent.draft.cap = "31.00"; c.parent.draft.lines[0].price = "2.15"
        let candidate = try c.parent.draft.candidate(), edit = c.parent.draft.mealEdit
        await c.parent.reviewEditor()
        let editor = try XCTUnwrap(c.parent.foodEditor)
        XCTAssertEqual(editor.candidate, candidate); XCTAssertEqual(c.parent.draft.mealEdit, edit)
        XCTAssertNil(c.parent.review); XCTAssertFalse(c.parent.acknowledged)
        XCTAssertEqual(c.fixture.catalogRequests.count, 1)
        guard case .patch(let action) = try XCTUnwrap(c.fixture.catalogRequests.first).action else { return XCTFail() }
        XCTAssertEqual(action.quote, candidate.quote); XCTAssertEqual(action.lines, candidate.lines)
        XCTAssertEqual(action.mealEdit?.proposalId, c.fixture.proposal); XCTAssertEqual(action.mealEdit?.occurrenceId, c.fixture.occurrence)
        XCTAssertEqual(action.mealEdit?.baseMealRevision, 1)
        let pending = try await c.outbox.operations(); XCTAssertTrue(pending.isEmpty); XCTAssertTrue(c.fixture.commandBytes.isEmpty)
    }
    func testRealisticallyNormalizedCatalogKeepsDisplayedAndPreviewedMealActionIdentical() async throws {
        let c = try await setup(); defer { c.close() }
        let meal = SharedMeal(title: "\u{FEFF}  Tacos  supper \u{00A0}", day: nil, kind: "dinner", portions: 2, protected: false,
            planning: .init(groups: [], ingredients: [], exclusions: [" No  peanuts "], completedSteps: ["\tCook  gently\n"]))
        var edit = SharedMealEdit(occurrenceID: c.fixture.occurrence.uuid, meal: meal); edit.baseMealRevision = 1
        c.parent.draft.mealEdit = edit
        await c.parent.reviewEditor(); let editor = try XCTUnwrap(c.parent.foodEditor), context = try XCTUnwrap(editor.meal)
        XCTAssertEqual(c.parent.draft.mealEdit, edit, "Review must not rewrite the user's outer draft")
        XCTAssertEqual(context.mealEdit?.meal?.title, "Tacos  supper")
        XCTAssertEqual(context.mealEdit?.meal?.planning?.exclusions, ["No  peanuts"])
        XCTAssertEqual(context.mealEdit?.meal?.planning?.completedSteps, ["Cook  gently"])
        XCTAssertEqual(context.request.action, context.catalog.normalizedAction)
        XCTAssertEqual(c.fixture.catalogRequests.first?.action, context.request.action)
        let flow = SharedDemandFlowModel(access: c.parent, editor: editor); await flow.load()
        flow.draft.mealSourcesReviewed = true; flow.draft.lines[0].acceptUnresolved = true
        await flow.preview(); XCTAssertEqual(flow.review?.request.action, context.request.action)
        XCTAssertEqual(flow.mealContext?.mealEdit, context.mealEdit)
        flow.cancel(); c.parent.cancelFoodEditor(); XCTAssertTrue(c.fixture.commandBytes.isEmpty)
        let saved = try await c.outbox.operations(); XCTAssertTrue(saved.isEmpty)
    }
    func testMissingDeniedOrStaleCatalogNeverFallsBackOrQueuesAnOperation() async throws {
        for status in [404, 403, 409, 500] {
            let c = try await setup(); defer { c.close() }
            let edit = c.parent.draft.mealEdit; c.fixture.catalogStatus = status
            await c.parent.reviewEditor()
            XCTAssertNil(c.parent.foodEditor); XCTAssertNil(c.parent.review); XCTAssertFalse(c.parent.acknowledged)
            XCTAssertTrue(c.fixture.commandBytes.isEmpty)
            let pending = try await c.outbox.operations(); XCTAssertTrue(pending.isEmpty)
            if status == 409 || status == 500 { XCTAssertEqual(c.parent.draft.mealEdit, edit) }
        }
    }
    func testDirectAndApprovedChangeProposalKeepTheirOwnImmutableIdentities() async throws {
        for proposed in [false, true] {
            let c = try await setup(); defer { c.close() }
            var edit = SharedMealEdit(occurrenceID: c.fixture.occurrence.uuid, meal: .init(title: "Revised tacos", day: nil, kind: "dinner", portions: 3, protected: false), changeProposalID: proposed ? c.fixture.proposal.uuid : nil)
            edit.baseMealRevision = 1; c.parent.draft.mealEdit = edit
            await c.parent.reviewEditor()
            let meal = try XCTUnwrap(c.parent.foodEditor?.meal?.mealEdit)
            XCTAssertEqual(meal.occurrenceId, c.fixture.occurrence); XCTAssertEqual(meal.meal, edit.meal)
            XCTAssertNil(meal.proposalId); XCTAssertEqual(meal.changeProposalId?.uuid, edit.changeProposalID)
            XCTAssertEqual(meal.baseMealRevision, 1); XCTAssertTrue(c.fixture.commandBytes.isEmpty)
        }
    }
    func testHeldCatalogCannotReplaceChangedCandidateOrDismissedEditor() async throws {
        for clear in [false, true] {
            let c = try await setup(); defer { c.close() }
            c.fixture.holdDemandReads = true
            let task = Task { await c.parent.reviewEditor() }; try await awaitHeld(c.fixture)
            if clear { c.parent.cancelFoodEditor() } else { c.parent.draft.cap = "33.00" }
            c.fixture.releaseDemandReads(); await task.value
            XCTAssertNil(c.parent.foodEditor); XCTAssertNil(c.parent.review); XCTAssertFalse(c.parent.acknowledged)
            XCTAssertTrue(c.fixture.commandBytes.isEmpty)
        }
    }
    func testHeldCatalogCannotOpenAfterRoleShopOrAuthorityAccessChanges() async throws {
        for key in ["shopId", "role", "clear"] {
            let c = try await setup(); defer { c.close() }
            c.fixture.holdDemandReads = true
            let task = Task { await c.parent.reviewEditor() }; try await awaitHeld(c.fixture)
            if key == "clear" { c.parent.clear() }
            else { c.parent.updateScope(try changedScope(c.scope, key: key, value: key == "shopId" ? UUID().uuidString.lowercased() : "contributor")) }
            c.fixture.releaseDemandReads(); await task.value
            XCTAssertNil(c.parent.foodEditor); XCTAssertNil(c.parent.review); XCTAssertTrue(c.fixture.commandBytes.isEmpty)
        }
    }
    func testLegacyMealUsesTrackingAdoptionAndPrivacyRecoveryDoesNotFetchCatalog() async throws {
        let legacy = try await setup(enabled: false); defer { legacy.close() }
        await legacy.parent.reviewEditor()
        XCTAssertNil(legacy.parent.review)
        XCTAssertEqual(legacy.parent.trackingEditor?.mealEdit?.occurrenceId.uuid, legacy.parent.draft.mealEdit?.occurrenceID)
        XCTAssertEqual(legacy.parent.trackingEditor?.mealEdit?.meal, legacy.parent.draft.mealEdit?.meal)
        XCTAssertNil(legacy.parent.foodEditor); XCTAssertTrue(legacy.fixture.catalogRequests.isEmpty)
        let recovery = try await setup(); defer { recovery.close() }
        recovery.fixture.recoveryRequired = true; await recovery.parent.reviewEditor()
        XCTAssertNil(recovery.parent.review); XCTAssertNil(recovery.parent.foodEditor)
        XCTAssertTrue(recovery.fixture.catalogRequests.isEmpty); XCTAssertTrue(recovery.fixture.commandBytes.isEmpty)
    }
    func testMealCancelWritesNothingThenLostApplyAndRelaunchRetryExactProposalOperation() async throws {
        let c = try await setup(); defer { c.close() }
        c.parent.draft.cap = "31.00"; let entered = try c.parent.draft.candidate()
        await c.parent.reviewEditor()
        var editor = try XCTUnwrap(c.parent.foodEditor)
        let cancelled = SharedDemandFlowModel(access: c.parent, editor: editor); await cancelled.load()
        cancelled.draft.mealSourcesReviewed = true; cancelled.draft.lines[0].acceptUnresolved = true
        await cancelled.preview(); XCTAssertNotNil(cancelled.review)
        cancelled.cancel(); c.parent.cancelFoodEditor()
        let empty = try await c.outbox.operations(); XCTAssertTrue(empty.isEmpty); XCTAssertTrue(c.fixture.commandBytes.isEmpty)
        await c.parent.reviewEditor(); editor = try XCTUnwrap(c.parent.foodEditor)
        let flow = SharedDemandFlowModel(access: c.parent, editor: editor); await flow.load()
        flow.draft.mealSourcesReviewed = true; flow.draft.lines[0].acceptUnresolved = true
        await flow.preview(); let review = try XCTUnwrap(flow.review)
        guard case .patch(let patch) = review.request.action else { return XCTFail() }
        XCTAssertEqual(patch.quote, entered.quote); XCTAssertEqual(patch.lines, entered.lines)
        XCTAssertEqual(patch.mealEdit?.proposalId, c.fixture.proposal)
        XCTAssertEqual(review.request.mode, .review); XCTAssertTrue(review.request.change.isEmpty)
        flow.acknowledged = true; await flow.apply()
        let pending = try XCTUnwrap(c.parent.pending)
        XCTAssertEqual(pending.sharedDemandBinding?.reservedOperationID, review.preview.receipt.operationId)
        let disk = try await c.outbox.operations(); XCTAssertEqual(disk, [pending])
        let restarted = HouseholdShopModel(scope: c.scope, service: c.service, outbox: OperationOutbox(url: c.outboxURL), onConfirmed: {}, onAccessEnded: {})
        await restarted.load(); XCTAssertEqual(restarted.pending, pending); await restarted.retry()
        XCTAssertNil(restarted.pending); XCTAssertEqual(c.fixture.commandBytes, [pending.bytes, pending.bytes])
        let final = try await c.outbox.operations(); XCTAssertTrue(final.isEmpty)
        guard case .confirmed(let receipt) = restarted.delivery else { return XCTFail() }
        XCTAssertEqual(receipt.operationId, review.preview.receipt.operationId.string)
    }
}
private final class MealFoodHTTPVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private final class MealFoodHTTPFixture: @unchecked Sendable {
    let host = "food-\(UUID().uuidString.lowercased()).test"
    let household = SharedDemandID(), member = SharedDemandID(), shop = SharedDemandID(), line = SharedDemandID()
    private let lock = NSLock()
    private var commands: [Data] = [], preview: [String: Any]?, after: SharedDemandGraph?
    private var operation = SharedDemandID()
    private let initiallyEnabled: Bool, expiredQuote: Bool
    private let manualID = SharedDemandID()
    let occurrence = SharedDemandID(), proposal = SharedDemandID()
    private var catalogs: [SharedDemandActionSourceRequest] = []
    var catalogRequests: [SharedDemandActionSourceRequest] { lock.lock(); defer { lock.unlock() }; return catalogs }
    private var committedPatch: SharedDemandShopPatch?
    private var holding = false, held: [MealFoodHTTPProtocol] = []
    private var readStatus = 200, pageDelta = 0
    private var catalogCode = 200
    var catalogStatus: Int { get { lock.lock(); defer { lock.unlock() }; return catalogCode } set { lock.lock(); defer { lock.unlock() }; catalogCode = newValue } }
    private var recovery = false
    var recoveryRequired: Bool { get { lock.lock(); defer { lock.unlock() }; return recovery } set { lock.lock(); defer { lock.unlock() }; recovery = newValue } }
    init(enabled: Bool = false, expiredQuote: Bool = false) { initiallyEnabled = enabled; self.expiredQuote = expiredQuote }
    var holdDemandReads: Bool { get { lock.lock(); defer { lock.unlock() }; return holding } set { lock.lock(); defer { lock.unlock() }; holding = newValue } }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var demandStatus: Int { get { lock.lock(); defer { lock.unlock() }; return readStatus } set { lock.lock(); defer { lock.unlock() }; readStatus = newValue } }
    var demandRevisionDelta: Int { get { lock.lock(); defer { lock.unlock() }; return pageDelta } set { lock.lock(); defer { lock.unlock() }; pageDelta = newValue } }
    func holdIfRequested(_ loader: MealFoodHTTPProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard holding, loader.request.url?.path.hasSuffix("/demand/action-sources") == true else { return false }
        held.append(loader); return true
    }
    func releaseDemandReads() {
        lock.lock(); let snapshot = held; held = []; holding = false; lock.unlock()
        for loader in snapshot { loader.complete(using: self) }
    }
    func cancel(_ loader: MealFoodHTTPProtocol) { lock.lock(); defer { lock.unlock() }; held.removeAll { $0 === loader } }
    private func initialGraph() throws -> SharedDemandGraph {
        let row = SharedDemandLine(id: line, name: "Wraps", unit: .count, originalOrder: 0)
        let source = SharedDemandContribution(id: manualID, lineId: line, source: .manual, productKey: "wraps", productName: "Wraps", originalText: "Twelve wraps", quantity: .init(amount: try .init(numerator: 12), unit: .count, originalLiteral: "12"))
        return .init(householdId: household, shopId: shop, revision: 1, lines: [row], contributions: [source], edges: [], usedIds: [line, manualID])
    }
    var commandBytes: [Data] { lock.lock(); defer { lock.unlock() }; return commands }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) throws -> Data {
        if let value = request.httpBody { return value }
        guard let stream = request.httpBodyStream else { return Data("{}".utf8) }
        stream.open(); defer { stream.close() }; var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count); guard count >= 0 else { throw ClientError.invalidResponse }
            if count == 0 { break }; result.append(bytes, count: count)
            guard result.count <= 1_800_000 else { throw ClientError.invalidResponse }
        }
        return result
    }
    private func normalizedAction(_ action: SharedDemandAction) throws -> Any {
        guard var result = try object(action) as? [String: Any], var body = result["body"] as? [String: Any],
              var edit = body["mealEdit"] as? [String: Any], var meal = edit["meal"] as? [String: Any] else { return try object(action) }
        let trimSet = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        func trim(_ value: Any?) -> Any? { if let text = value as? String { return text.trimmingCharacters(in: trimSet) }; return value }
        func labels(_ value: Any?) -> Any? { if let items = value as? [String] { return items.map { $0.trimmingCharacters(in: trimSet) } }; return value }
        func quantity(_ value: Any?) -> Any? { guard var row = value as? [String: Any] else { return value }; row["originalLiteral"] = trim(row["originalLiteral"]); return row }
        meal["title"] = trim(meal["title"])
        if var planning = meal["planning"] as? [String: Any] {
            planning["groups"] = (planning["groups"] as? [[String: Any]])?.map { var row = $0; row["name"] = trim(row["name"]); return row }
            planning["ingredients"] = (planning["ingredients"] as? [[String: Any]])?.map { var row = $0; row["name"] = trim(row["name"]); row["quantity"] = quantity(row["quantity"]); row["exclusions"] = labels(row["exclusions"]); return row }
            if let bindings = planning["bindings"] as? [[String: Any]] { planning["bindings"] = bindings.map { var row = $0; row["quantity"] = quantity(row["quantity"]); return row } }
            planning["exclusions"] = labels(planning["exclusions"]); planning["completedSteps"] = labels(planning["completedSteps"])
            meal["planning"] = planning
        }
        edit["meal"] = meal; body["mealEdit"] = edit; result["body"] = body; return result
    }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/demand"), readStatus != 200 { return try data(["error": ["code": "access_ended"]]) }
        if path.hasSuffix("/auth/v1/verify") { return try data(["access_token": "adult", "refresh_token": "refresh", "expires_in": 3600, "user": ["id": "adult", "email_confirmed_at": "date"]]) }
        if path.hasSuffix("/auth/v1/user") { return try data(["id": "adult", "email_confirmed_at": "date"]) }
        if path.hasSuffix("/devices") { return try data(["deviceId": "device", "deviceToken": "token"]) }
        if path.hasSuffix("/bootstrap") { return try data(["household": ["id": household.string, "label": "Home"], "memberId": member.string,
            "role": "shopper", "shopId": shop.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]]) }
        if path.hasSuffix("/replay-windows") { return try data(["id": UUID().uuidString.lowercased(), "expiresAt": "2099-01-01T00:00:00Z"]) }
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 2000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: Date(timeIntervalSince1970: expiredQuote ? 2_000_000 : 4_000_000_000))
        let basket = ShopperBasketLine(lineId: line.uuid, originalItem: "Wraps", packs: 2, unitPriceMinor: 100, feeEligible: true)
        if path.hasSuffix("/demand/action-sources") {
            if catalogCode != 200 { return try data(["error": ["code": "stale_demand"]]) }
            let input = try JSONDecoder().decode(SharedDemandActionSourceRequest.self, from: body(request)); catalogs.append(input)
            return try data(["schemaVersion": 1, "shopId": shop.string, "base": object(input.base), "graphDigest": String(repeating: "a", count: 64),
                "actionDigest": String(repeating: "b", count: 64), "normalizedAction": normalizedAction(input.action), "sources": [], "retirementCandidates": [], "retainedContributionIds": [manualID.string]])
        }
        if path.hasSuffix("/demand/tracking") {
            if readStatus != 200 { return try data(["error": ["code": "access_ended"]]) }
            let graph = commands.isEmpty ? (initiallyEnabled ? try initialGraph() : nil) : after
            let totals: [[String: Any]] = graph.map { value in [["lineId": line.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": value.contributions.map { $0.id.string }]] } ?? []
            let basketRows = try object(committedPatch?.lines ?? [basket]) as! [[String: Any]]
            let total = basketRows.contains { $0["unitPriceMinor"] is NSNull } ? nil : basketRows.reduce(0) { $0 + ($1["unitPriceMinor"] as? Int ?? 0) * ($1["packs"] as? Int ?? 1) }
            return try data(ModelTrackingReadFixture.page(household: household.string, shop: shop.string,
                revision: commands.isEmpty ? 1 + pageDelta : 2, basket: basketRows, graph: graph, totals: totals,
                checkout: ModelTrackingReadFixture.budget(total, cap: committedPatch?.quote.capMinor ?? 2000), recovery: recovery))
        }
        if path.hasSuffix("/demand/previews") {
            let input = try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: body(request))
            let twelve = try SharedDemandAmount(numerator: 12)
            let before: SharedDemandGraph, result: SharedDemandGraph
            if initiallyEnabled {
                guard input.mode == .review, input.change.isEmpty else { throw ClientError.invalidResponse }
                before = try initialGraph(); var reviewed = before; reviewed.revision += 1; result = reviewed
            } else {
                guard input.mode == .adopt, input.change.contributions.count == 1, input.change.edges.isEmpty,
                      input.change.contributions[0].quantity?.amount == twelve else { throw ClientError.invalidResponse }
                before = SharedDemandGraph(householdId: household, shopId: shop, revision: 0, lines: [], contributions: [], edges: [], usedIds: [])
                result = SharedDemandGraph(householdId: household, shopId: shop, revision: 1, lines: input.change.lines, contributions: input.change.contributions, edges: [], usedIds: input.change.lines.map(\.id) + input.change.contributions.map(\.id))
            }
            after = result; operation = .init()
            let receipt: [String: Any] = ["schemaVersion": 1, "operationId": operation.string, "householdId": household.string, "shopId": shop.string, "baseRevision": before.revision, "resultRevision": result.revision,
                "lines": try input.change.lines.map { ["id": $0.id.string, "before": NSNull(), "after": try object($0)] },
                "contributions": try input.change.contributions.map { ["id": $0.id.string, "before": NSNull(), "after": try object($0)] }, "edges": []]
            let resultJSON: [String: Any] = ["previewId": SharedDemandID().string, "previewDigest": String(repeating: "a", count: 64), "expiresAt": "2099-01-01T00:00:00Z",
                "before": try object(before), "after": try object(result), "receipt": receipt, "packs": try object(input.packs), "beforeTotals": initiallyEnabled ? [["lineId": line.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": [manualID.string]]] : [],
                "afterTotals": [["lineId": line.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": result.contributions.map { $0.id.string }]],
                "shopRevision": 1, "authorityEpoch": 1]
            preview = resultJSON; return try data(resultJSON)
        }
        if path.hasSuffix("/demand") {
            if !commands.isEmpty, let after {
                return try data(["schemaVersion": 1, "shopId": shop.string, "shopRevision": 2, "authorityEpoch": 1,
                    "status": "enabled", "graph": try object(after), "legacySources": NSNull(),
                    "totals": [["lineId": line.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": after.contributions.map { $0.id.string }]]])
            }
            if initiallyEnabled {
                let graph = try initialGraph()
                return try data(["schemaVersion": 1, "shopId": shop.string, "shopRevision": 1 + pageDelta, "authorityEpoch": 1,
                    "status": recovery ? "reviewRequired" : "enabled", "graphDigest": recovery ? NSNull() : String(repeating: "a", count: 64) as Any, "graph": try object(graph), "legacySources": NSNull(),
                    "totals": [["lineId": line.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": [manualID.string]]]])
            }
            return try data(["schemaVersion": 1, "shopId": shop.string, "shopRevision": 1 + pageDelta, "authorityEpoch": 1,
                "status": "legacy", "graph": NSNull(), "totals": [], "legacySources": ["sources": []]])
        }
        if path.hasSuffix("/commands") {
            guard preview != nil else { throw ClientError.invalidResponse }
            let bytes = try body(request); commands.append(bytes)
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bytes)
            committedPatch = try JSONDecoder().decode(SharedDemandShopPatch.self, from: JSONEncoder().encode(envelope.body))
            if commands.count == 1 { throw URLError(.networkConnectionLost) }
            return try data(["operationId": operation.string, "kind": "shop.patch", "shopId": shop.string, "shopRevision": 2, "authorityEpoch": 1, "disposition": "patched"])
        }
        if path.hasSuffix("/shops/\(shop.string)") {
            return try data(["shopId": shop.string, "shopRevision": commands.isEmpty ? 1 : 2, "authorityEpoch": 1, "phase": "draft", "meals": [["occurrenceId": occurrence.string, "revision": 1, "meal": try object(SharedMeal(title: "Tacos", day: nil, kind: "dinner", portions: 2, protected: false))]], "quote": try object(committedPatch?.quote ?? quote), "lines": try object(committedPatch?.lines ?? [basket]), "frozenRevision": NSNull(), "placedRevision": NSNull()])
        }
        throw ClientError.invalidResponse
    }
}
private final class MealFoodHTTPRegistry: @unchecked Sendable {
    private struct Weak { weak var fixture: MealFoodHTTPFixture? }
    private let lock = NSLock(); private var values: [String: Weak] = [:]
    func add(_ fixture: MealFoodHTTPFixture) { lock.lock(); defer { lock.unlock() }; values[fixture.host] = .init(fixture: fixture) }
    func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: host) }
    func fixture(_ host: String?) -> MealFoodHTTPFixture? { lock.lock(); defer { lock.unlock() }; return host.flatMap { values[$0]?.fixture } }
}
private final class MealFoodHTTPProtocol: URLProtocol {
    static let registry = MealFoodHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.fixture(request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.registry.fixture(request.url?.host) else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        if fixture.holdIfRequested(self) { return }
        complete(using: fixture)
    }
    func complete(using fixture: MealFoodHTTPFixture) {
        do {
            let bytes = try fixture.respond(request)
            let status = request.url?.path.hasSuffix("/demand/action-sources") == true ? fixture.catalogStatus : ((request.url?.path.hasSuffix("/demand") == true || request.url?.path.hasSuffix("/demand/tracking") == true) ? fixture.demandStatus : 200)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.registry.fixture(request.url?.host)?.cancel(self) }
}

@MainActor private final class MealDraftAccess: SharedDemandFlowAccess {
    let page: SharedDemandPage
    let foodShop: ShopperShop?
    var canReadFood = true
    var foodPending = false
    var foodEditorID: UUID?
    var reviewBuilder: ((SharedDemandPreviewRequest) throws -> SharedDemandReview)?
    var holdPreview = false
    var previewContinuation: CheckedContinuation<SharedDemandReview, Never>?
    var heldReview: SharedDemandReview?
    var applies = 0
    init(page: SharedDemandPage, shop: ShopperShop) { self.page = page; foodShop = shop }
    func readFood() async throws -> SharedDemandPage { page }
    func previewFood(_ request: SharedDemandPreviewRequest) async throws -> SharedDemandReview {
        guard let reviewBuilder else { throw ClientError.configuration }
        let value = try reviewBuilder(request)
        if holdPreview { heldReview = value; return await withCheckedContinuation { previewContinuation = $0 } }
        return value
    }
    func applyFood(_ review: SharedDemandReview) async throws { applies += 1 }
}
