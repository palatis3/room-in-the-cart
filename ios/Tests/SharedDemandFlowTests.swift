import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedDemandFlowTests: XCTestCase {
    private let household = SharedDemandID(), shopID = SharedDemandID(), lineID = SharedDemandID()
    private let at = "2026-11-09T12:00:00Z"
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func decode<T: Decodable>(_ value: Any, as: T.Type = T.self) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func shop() throws -> ShopperShop {
        try decode(["shopId": shopID.string, "shopRevision": 3, "authorityEpoch": 2, "phase": "draft", "meals": [],
            "lines": [["lineId": lineID.string, "originalItem": "Wraps", "packs": 2, "unitPriceMinor": 120, "feeEligible": true]],
            "frozenRevision": NSNull(), "placedRevision": NSNull(),
            "quote": ["currency": "USD", "scope": "wholeCheckout", "complete": true, "capScope": "wholeCheckout", "capMinor": 10000,
                "observedAt": "2026-11-09T12:00:00Z", "expiresAt": "2099-11-09T13:00:00Z",
                "taxesMinor": 0, "depositsMinor": 0, "discountsMinor": 0, "fee": ["kind": "fixed", "amountMinor": 0]]])
    }
    private func page(sources: [[String: Any]]? = [], graph: SharedDemandGraph? = nil, totals: [[String: Any]] = []) throws -> SharedDemandPage {
        var value: [String: Any] = ["schemaVersion": 1, "shopId": shopID.string, "shopRevision": 3, "authorityEpoch": 2,
            "status": graph == nil ? "legacy" : "enabled", "graph": try graph.map(object) ?? NSNull(), "totals": totals]
        if let sources { value["legacySources"] = graph == nil ? ["sources": sources] : NSNull() }
        let result: SharedDemandPage = try decode(value)
        try result.validate(householdID: household.string, shopID: shopID.uuid); return result
    }
    private func manual(amount: String = "12") -> SharedFoodSourceDraft {
        var source = SharedFoodSourceDraft(); source.lineID = lineID; source.productName = "Wraps"; source.originalText = "Twelve wraps for the week"
        source.amount = .init(literal: amount, unit: .count, unknown: false); source.productConfirmed = true; return source
    }
    private func draft() throws -> (SharedFoodDraft, SharedDemandPage, ShopperShop) {
        let page = try page(), shop = try shop(); var draft = try SharedFoodDraft(page: page, shop: shop)
        draft.sources = [manual()]; draft.lines[0].acceptUnresolved = true; return (draft, page, shop)
    }
    private func descriptor(source: SharedDemandSource, quantity: SharedDemandQuantity? = nil, line: SharedDemandID? = nil) throws -> [String: Any] {
        ["id": SharedDemandID().string, "source": try object(source), "sourceLabel": "Tacos", "productName": "Wraps", "originalText": "Wraps",
         "originalQuantityText": "six wraps", "quantity": try quantity.map(object) ?? NSNull(), "sourceExclusions": [], "requiredLineId": line.map { $0.string as Any } ?? NSNull()]
    }
    func testExplicitManualAmountDoesNotComeFromTwoPacksAndPreservesOriginalQuote() throws {
        let (draft, page, shop) = try draft()
        let request = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(request.change.contributions[0].quantity?.amount.numerator, 12)
        XCTAssertEqual(request.change.contributions[0].quantity?.originalLiteral, "12")
        guard case .patch(let patch) = request.action else { return XCTFail() }
        XCTAssertEqual(patch.lines, shop.lines); XCTAssertEqual(patch.quote, shop.quote)
        XCTAssertNil(request.packs[0].usablePerPack); XCTAssertTrue(request.packs[0].acceptUnresolved)
        XCTAssertEqual(request.base, .init(shopRevision: 3, authorityEpoch: 2, graphRevision: 0))
    }
    func testNoImplicitManualSourceFromLegacyBasketAndNoMissingCatalogGuess() throws {
        let shop = try shop(), page = try page(); var draft = try SharedFoodDraft(page: page, shop: shop)
        draft.lines[0].acceptUnresolved = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        XCTAssertThrowsError(try SharedFoodDraft(page: self.page(sources: nil), shop: shop))
    }
    func testUnknownFoodRemainsNullAndOriginalWordsSurvive() throws {
        var (draft, page, shop) = try draft(); draft.sources[0].amount.unknown = true
        let value = try draft.request(page: page, shop: shop, at: at)
        XCTAssertNil(value.change.contributions[0].quantity)
        XCTAssertEqual(value.change.contributions[0].originalText, "Twelve wraps for the week")
    }
    func testExactDecimalFractionAndSpanishDecimalNeverRoundThroughDouble() throws {
        let cases: [(String, Int64, Int64)] = [("1,25", 5, 4), ("15/16", 15, 16), ("0.000000001", 1, 1_000_000_000)]
        for (literal, n, d) in cases {
            let q = try SharedFoodAmountDraft(literal: literal, unit: .ounce, unknown: false).quantity()
            XCTAssertEqual(q?.amount.numerator, n); XCTAssertEqual(q?.amount.denominator, d); XCTAssertEqual(q?.originalLiteral, literal)
        }
        for invalid in ["0", "-1", "1/0", "1e3", "1,000.25", "99999999999999999999999999"] {
            XCTAssertThrowsError(try SharedFoodAmountDraft(literal: invalid, unknown: false).quantity())
        }
    }
    func testManualDuplicateRequiresExplicitEdgeAndKeepsBothStableSourceIDs() throws {
        var (draft, page, shop) = try draft(); draft.sources.append(manual())
        let without = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(without.change.contributions.count, 2); XCTAssertTrue(without.change.edges.isEmpty)
        var link = SharedFoodLinkDraft(); link.kind = .duplicate; link.demandID = draft.sources[1].id; link.supplyID = draft.sources[0].id
        link.amount = .init(literal: "12", unknown: false); link.evidence = "Same twelve wraps entered again"
        draft.links = [link]; XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.links[0].confirmed = true
        let reviewed = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(reviewed.change.contributions.map(\.id), without.change.contributions.map(\.id))
        XCTAssertEqual(reviewed.change.edges[0].demandId, draft.sources[1].id)
        XCTAssertEqual(reviewed.change.edges[0].supplyId, draft.sources[0].id)
    }
    func testMealWithinExistingKeepsProtectedUnknownSeparateAndNeverQuantifiesIt() throws {
        let occurrence = SharedDemandID(), ingredient = SharedDemandID(), group = SharedDemandID()
        let meal = try descriptor(source: .meal(occurrenceId: occurrence, ingredientId: ingredient, groupId: nil, bindingId: nil), quantity: .init(amount: try .init(numerator: 6), unit: .count, originalLiteral: "6"))
        let protected = try descriptor(source: .reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: occurrence, ingredientId: ingredient, groupId: group, bindingId: nil))
        let page = try page(sources: [meal, protected]), shop = try shop(); var draft = try SharedFoodDraft(page: page, shop: shop)
        for index in draft.sources.indices { draft.sources[index].lineID = lineID; draft.sources[index].productConfirmed = true }
        let mealID = draft.sources[0].id, protectedID = draft.sources[1].id
        draft.sources[1].amount = .init(literal: "99", unknown: false) // Locked authoritative unknown wins.
        draft.sources.append(manual()); draft.lines[0].acceptUnresolved = true
        var link = SharedFoodLinkDraft(); link.demandID = mealID; link.supplyID = draft.sources[2].id
        link.amount = .init(literal: "6", unknown: false); link.confirmed = true; link.evidence = "Six from the twelve"
        draft.links = [link]
        let value = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(value.change.contributions.map(\.id), [mealID, protectedID, draft.sources[2].id])
        XCTAssertNil(value.change.contributions[1].quantity); XCTAssertNil(value.change.quantifyReservationIds)
        XCTAssertEqual(value.change.edges[0].quantity.amount.numerator, 6)
    }
    func testRequestCannotMoveToAnotherLineOrGuessQuantityFromOwnWording() throws {
        let requestID = SharedDemandID()
        let item = try descriptor(source: .request(requestId: requestID, appliedRequestRevision: 7), line: lineID)
        let page = try page(sources: [item]), shop = try shop(); var draft = try SharedFoodDraft(page: page, shop: shop)
        draft.sources[0].productConfirmed = true; draft.lines[0].acceptUnresolved = true
        let value = try draft.request(page: page, shop: shop, at: at)
        XCTAssertNil(value.change.contributions[0].quantity)
        XCTAssertEqual(value.change.contributions[0].source, .request(requestId: requestID, appliedRequestRevision: 7))
        draft.lines.append(.init(id: .init(), name: "Other", unit: .count, packs: 1, priceMinor: nil, feeEligible: true))
        draft.sources[0].lineID = draft.lines[1].id
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
    }
    func testInheritedRestrictionRequiresExactExplicitMappingOrStaysUnresolved() throws {
        var (draft, page, shop) = try draft()
        let occurrence = SharedDemandID(), ingredient = SharedDemandID()
        draft.sources[0].source = .meal(occurrenceId: occurrence, ingredientId: ingredient, groupId: nil, bindingId: nil)
        draft.sources[0].restrictions = [.init(occurrenceId: occurrence, ingredientId: ingredient, label: "Family's exact restriction", resolution: .unresolved)]
        draft.sources[0].restrictionTags = [""]
        let unresolved = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(unresolved.change.contributions[0].sourceExclusions?[0].resolution, .unresolved)
        draft.sources[0].restrictionTags = ["dairy"]
        let mapped = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(mapped.change.contributions[0].exclusions, ["dairy"])
        XCTAssertEqual(mapped.change.contributions[0].sourceExclusions?[0].label, "Family's exact restriction")
        draft.sources[0].contains = "dairy"
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
    }
    func testStaleBaseAndUnconfirmedProductAreRejectedBeforePreview() throws {
        var (draft, page, shop) = try draft(); draft.sources[0].productConfirmed = false
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.sources[0].productConfirmed = true
        var encoded = try XCTUnwrap(object(shop) as? [String: Any]); encoded["shopRevision"] = 4
        XCTAssertThrowsError(try draft.request(page: page, shop: decode(encoded), at: at))
    }
    private func existingUnknownProduct() throws -> (SharedDemandPage, ShopperShop, SharedDemandContribution) {
        let source = SharedDemandContribution(lineId: lineID, source: .manual, productKey: nil, productName: "Wraps", originalText: "Previously entered twelve", quantity: .init(amount: try .init(numerator: 12), unit: .count, originalLiteral: "12"))
        let line = SharedDemandLine(id: lineID, name: "Wraps", unit: .count, originalOrder: 0)
        let graph = SharedDemandGraph(householdId: household, shopId: shopID, revision: 1, lines: [line], contributions: [source], edges: [], usedIds: [lineID, source.id])
        let total: [String: Any] = ["lineId": lineID.string, "unit": "count", "quantity": ["numerator": "12", "denominator": "1"], "activeContributionIds": [source.id.string]]
        return (try page(graph: graph, totals: [total]), try shop(), source)
    }
    func testExistingNilProductNeedsExplicitIdentityReviewAndRetainsEveryOldFact() throws {
        let (page, shop, old) = try existingUnknownProduct()
        var draft = try SharedFoodDraft(page: page, shop: shop)
        draft.sources = [manual(amount: "4")]; draft.lines[0].acceptUnresolved = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.lines[0].confirmExistingSources = true
        let request = try draft.request(page: page, shop: shop, at: at)
        var expected = old; expected.productKey = "food.\(lineID.string)"
        XCTAssertEqual(request.change.contributions[0], expected)
        XCTAssertEqual(request.change.contributions[1].productKey, expected.productKey)
        XCTAssertTrue(request.change.removeSourceIds.isEmpty)
        XCTAssertEqual(request.change.contributions[0].id, old.id)
    }
    func testRemovingUnsavedItemKeepsSourceTextAndIDsAndCannotRemoveSavedBasketLine() throws {
        var (draft, _, _) = try self.draft()
        let newID = SharedDemandID()
        draft.lines.append(.init(id: newID, name: "Accidental item", unit: .count, packs: 1, priceMinor: nil, feeEligible: true, existing: false))
        draft.sources[0].lineID = newID
        let source = draft.sources[0]
        var link = SharedFoodLinkDraft(); link.demandID = source.id; link.confirmed = true; draft.links = [link]
        draft.removeUnsavedLine(newID)
        XCTAssertEqual(draft.lines.map(\.id), [lineID]); XCTAssertEqual(draft.sources[0].id, source.id)
        XCTAssertEqual(draft.sources[0].originalText, source.originalText); XCTAssertEqual(draft.sources[0].amount, source.amount)
        XCTAssertNil(draft.sources[0].lineID); XCTAssertFalse(draft.sources[0].productConfirmed); XCTAssertFalse(draft.links[0].confirmed)
        draft.removeUnsavedLine(lineID); XCTAssertEqual(draft.lines.map(\.id), [lineID])
    }
    func testPackOnlyAndUnchangedEnabledReviewUseReviewModeWithoutFabricatingGraphEdits() throws {
        let (page, shop, _) = try existingUnknownProduct()
        var draft = try SharedFoodDraft(page: page, shop: shop); draft.lines[0].acceptUnresolved = true
        let unchanged = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(unchanged.mode, .review); XCTAssertTrue(unchanged.change.isEmpty)
        draft.lines[0].packs = 3
        let packOnly = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(packOnly.mode, .review); XCTAssertTrue(packOnly.change.isEmpty)
        guard case .patch(let action) = packOnly.action else { return XCTFail() }
        XCTAssertEqual(action.lines[0].packs, 3); XCTAssertEqual(action.quote, shop.quote)
        draft.lines[0].confirmExistingSources = true
        let identityEdit = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(identityEdit.mode, .change); XCTAssertFalse(identityEdit.change.isEmpty)
    }
    func testProtectedNilProductRequiresDedicatedIntentAndKeepsUnknownReservationIdentity() throws {
        let old = SharedDemandContribution(lineId: lineID,
            source: .reservation(reservationId: .init(), purpose: "Protected lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: .init(), bindingId: nil),
            productKey: nil, productName: "Wraps", originalText: "Protected lunch", quantity: nil)
        let line = SharedDemandLine(id: lineID, name: "Wraps", unit: .count, originalOrder: 0)
        let graph = SharedDemandGraph(householdId: household, shopId: shopID, revision: 1, lines: [line], contributions: [old], edges: [], usedIds: [lineID, old.id])
        let total: [String: Any] = ["lineId": lineID.string, "unit": "count", "quantity": NSNull(), "activeContributionIds": [old.id.string]]
        let page = try page(graph: graph, totals: [total]), shop = try shop()
        var draft = try SharedFoodDraft(page: page, shop: shop); draft.sources = [manual()]; draft.lines[0].acceptUnresolved = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.lines[0].confirmExistingSources = true
        let request = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(request.change.clarifyReservationProductIds, [old.id])
        var expected = old; expected.productKey = "food.\(lineID.string)"
        XCTAssertEqual(request.change.contributions[0], expected)
        XCTAssertNil(request.change.quantifyReservationIds)
    }
    func testPrivacyRecoveryReviewCannotSmuggleEditsOrIdentityBindings() throws {
        let (enabled, shop, _) = try existingUnknownProduct()
        var value = try XCTUnwrap(object(enabled) as? [String: Any]); value["status"] = "reviewRequired"
        let page: SharedDemandPage = try decode(value)
        var draft = try SharedFoodDraft(page: page, shop: shop); draft.lines[0].acceptUnresolved = true
        let unchanged = try draft.request(page: page, shop: shop, at: at)
        XCTAssertEqual(unchanged.mode, .review); XCTAssertEqual(unchanged.change, .init())
        draft.sources = [manual()]
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.sources = []; draft.lines[0].confirmExistingSources = true
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
        draft.lines[0].confirmExistingSources = false; draft.lines[0].packs += 1
        XCTAssertThrowsError(try draft.request(page: page, shop: shop, at: at))
    }
    func testConversionRequiresCrossDimensionAndExplicitEvidenceWithoutReplacingLiteral() throws {
        var value = SharedFoodAmountDraft(literal: "2", unit: .cup, unknown: false)
        value.useConversion = true; value.conversionUnit = .gram; value.conversionRate = "120"; value.conversionNote = "Measured this flour"
        let quantity = try XCTUnwrap(value.quantity())
        XCTAssertEqual(quantity.originalLiteral, "2")
        XCTAssertEqual(quantity.confirmedConversion?.targetAmountPerSourceUnit.numerator, 120)
        value.conversionUnit = .liter
        XCTAssertThrowsError(try value.quantity(), "Same-dimension conversions belong to the canonical table")
        value.conversionUnit = .gram; value.conversionNote = ""
        XCTAssertThrowsError(try value.quantity())
    }
    func testCancelWhileReadIsHeldDiscardsReturnedPrivateGraphAndMakesNoPreviewOrApply() async throws {
        let access = FoodAccessStub(shop: try shop(), page: try page()); access.holdRead = true
        let model = SharedDemandFlowModel(access: access)
        let task = Task { await model.load() }
        for _ in 0..<1000 { if access.readContinuation != nil { break }; await Task.yield() }
        let continuation = try XCTUnwrap(access.readContinuation)
        model.cancel(); continuation.resume(returning: access.page)
        await task.value
        XCTAssertNil(model.page); XCTAssertNil(model.shop); XCTAssertTrue(model.draft.sources.isEmpty)
        XCTAssertEqual(access.previews, 0); XCTAssertEqual(access.applies, 0)
    }
    func testRevocationBeforeReadReturnsHidesSourcesAndCannotApply() async throws {
        let access = FoodAccessStub(shop: try shop(), page: try page()); access.holdRead = true
        let model = SharedDemandFlowModel(access: access)
        let task = Task { await model.load() }
        for _ in 0..<1000 { if access.readContinuation != nil { break }; await Task.yield() }
        let continuation = try XCTUnwrap(access.readContinuation)
        access.canReadFood = false; continuation.resume(returning: access.page); await task.value
        model.acknowledged = true; await model.apply()
        XCTAssertNil(model.page); XCTAssertEqual(access.applies, 0)
    }
}

@MainActor private final class FoodAccessStub: SharedDemandFlowAccess {
    var foodShop: ShopperShop?
    var canReadFood = true
    var foodPending = false
    let page: SharedDemandPage
    var holdRead = false
    var readContinuation: CheckedContinuation<SharedDemandPage, Never>?
    var previews = 0, applies = 0
    init(shop: ShopperShop, page: SharedDemandPage) { foodShop = shop; self.page = page }
    func readFood() async throws -> SharedDemandPage {
        if holdRead { return await withCheckedContinuation { readContinuation = $0 } }; return page
    }
    func previewFood(_ request: SharedDemandPreviewRequest) async throws -> SharedDemandReview { previews += 1; throw ClientError.configuration }
    func applyFood(_ review: SharedDemandReview) async throws { applies += 1 }
}

/// Real HouseholdService, persisted outbox and parent model; only HTTP is fake.
/// The fixed preview has one twelve-count manual source, not a second reducer.
@MainActor final class SharedDemandOutboxFlowTests: XCTestCase {
    func testCancelledPreviewWritesNothingThenLostApplyRelaunchRetriesExactReservedOperation() async throws {
        let fixture = FoodHTTPFixture(); FoodHTTPProtocol.registry.add(fixture)
        defer { FoodHTTPProtocol.registry.remove(fixture.host) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FoodHTTPProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: configuration))
        let url = URL(string: "https://\(fixture.host)")!
        let auth = AdultAuth(configuration: try .init(projectURL: url, publishableKey: "sb_publishable_test"), vault: FoodHTTPVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: url), auth: auth, deviceVault: FoodHTTPVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "fixture@example.test", code: "123456")
        _ = try await service.enroll(householdID: fixture.household.string)
        let scope = try await service.bootstrap()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("shared-shop.json")
        let outbox = OperationOutbox(url: outboxURL)
        let parent = HouseholdShopModel(scope: scope, service: service, outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        await parent.load()
        let flow = SharedDemandFlowModel(access: parent); await flow.load()
        XCTAssertNotNil(flow.page)
        func enter() {
            var row = SharedFoodSourceDraft(); row.lineID = fixture.line; row.productName = "Wraps"; row.originalText = "Twelve wraps"
            row.productConfirmed = true; row.amount = .init(literal: "12", unknown: false)
            flow.draft.sources = [row]; flow.draft.lines[0].acceptUnresolved = true
        }
        enter(); await flow.preview(); XCTAssertNotNil(flow.review)
        flow.cancel()
        let cancelled = try await outbox.operations()
        XCTAssertTrue(cancelled.isEmpty); XCTAssertTrue(fixture.commandBytes.isEmpty)
        await flow.load(); enter(); await flow.preview()
        let reviewed = try XCTUnwrap(flow.review)
        flow.acknowledged = true; await flow.apply()
        let pending = try XCTUnwrap(parent.pending)
        XCTAssertEqual(pending.sharedDemandBinding?.reservedOperationID, reviewed.preview.receipt.operationId)
        XCTAssertEqual(fixture.commandBytes, [pending.bytes])
        let persisted = try await outbox.operations(); XCTAssertEqual(persisted, [pending])
        // A fresh parent restores the same file, rather than constructing a new
        // preview or replacing the key after the simulated lost receipt.
        let restarted = HouseholdShopModel(scope: scope, service: service, outbox: OperationOutbox(url: outboxURL), onConfirmed: {}, onAccessEnded: {})
        await restarted.load(); XCTAssertEqual(restarted.pending, pending)
        await restarted.retry()
        XCTAssertNil(restarted.pending)
        guard case .confirmed(let receipt) = restarted.delivery else { return XCTFail("Exact retry was not confirmed") }
        XCTAssertEqual(receipt.operationId, reviewed.preview.receipt.operationId.string)
        XCTAssertEqual(fixture.commandBytes, [pending.bytes, pending.bytes])
        let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
        let reopened = SharedDemandFlowModel(access: restarted); await reopened.load()
        XCTAssertEqual(reopened.page?.status, .enabled)
        XCTAssertEqual(reopened.page?.graph?.contributions.count, 1)
        XCTAssertEqual(reopened.page?.totals.first?.quantity?.numerator, 12)
    }
}

private final class FoodHTTPVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private final class FoodHTTPFixture: @unchecked Sendable {
    let host = "food-\(UUID().uuidString.lowercased()).test"
    let household = SharedDemandID(), member = SharedDemandID(), shop = SharedDemandID(), line = SharedDemandID()
    private let lock = NSLock()
    private var commands: [Data] = [], preview: [String: Any]?, after: SharedDemandGraph?
    private var operation = SharedDemandID()
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
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/auth/v1/verify") { return try data(["access_token": "adult", "refresh_token": "refresh", "expires_in": 3600, "user": ["id": "adult", "email_confirmed_at": "date"]]) }
        if path.hasSuffix("/auth/v1/user") { return try data(["id": "adult", "email_confirmed_at": "date"]) }
        if path.hasSuffix("/devices") { return try data(["deviceId": "device", "deviceToken": "token"]) }
        if path.hasSuffix("/bootstrap") { return try data(["household": ["id": household.string, "label": "Home"], "memberId": member.string,
            "role": "shopper", "shopId": shop.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]]) }
        if path.hasSuffix("/replay-windows") { return try data(["id": UUID().uuidString.lowercased(), "expiresAt": "2099-01-01T00:00:00Z"]) }
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 2000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let basket = ShopperBasketLine(lineId: line.uuid, originalItem: "Wraps", packs: 2, unitPriceMinor: 100, feeEligible: true)
        if path.hasSuffix("/demand/previews") {
            let input = try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: body(request))
            let twelve = try SharedDemandAmount(numerator: 12)
            guard input.mode == .adopt, input.change.contributions.count == 1, input.change.edges.isEmpty,
                  input.change.contributions[0].quantity?.amount == twelve else { throw ClientError.invalidResponse }
            let before = SharedDemandGraph(householdId: household, shopId: shop, revision: 0, lines: [], contributions: [], edges: [], usedIds: [])
            let result = SharedDemandGraph(householdId: household, shopId: shop, revision: 1, lines: input.change.lines, contributions: input.change.contributions, edges: [], usedIds: input.change.lines.map(\.id) + input.change.contributions.map(\.id))
            after = result; operation = .init()
            let receipt: [String: Any] = ["schemaVersion": 1, "operationId": operation.string, "householdId": household.string, "shopId": shop.string, "baseRevision": 0, "resultRevision": 1,
                "lines": try input.change.lines.map { ["id": $0.id.string, "before": NSNull(), "after": try object($0)] },
                "contributions": try input.change.contributions.map { ["id": $0.id.string, "before": NSNull(), "after": try object($0)] }, "edges": []]
            let resultJSON: [String: Any] = ["previewId": SharedDemandID().string, "previewDigest": String(repeating: "a", count: 64), "expiresAt": "2099-01-01T00:00:00Z",
                "before": try object(before), "after": try object(result), "receipt": receipt, "packs": try object(input.packs), "beforeTotals": [],
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
            return try data(["schemaVersion": 1, "shopId": shop.string, "shopRevision": 1, "authorityEpoch": 1,
                "status": "legacy", "graph": NSNull(), "totals": [], "legacySources": ["sources": []]])
        }
        if path.hasSuffix("/commands") {
            guard preview != nil else { throw ClientError.invalidResponse }
            let bytes = try body(request); commands.append(bytes)
            if commands.count == 1 { throw URLError(.networkConnectionLost) }
            return try data(["operationId": operation.string, "kind": "shop.patch", "shopId": shop.string, "shopRevision": 2, "authorityEpoch": 1, "disposition": "patched"])
        }
        if path.hasSuffix("/shops/\(shop.string)") {
            return try data(["shopId": shop.string, "shopRevision": commands.isEmpty ? 1 : 2, "authorityEpoch": 1, "phase": "draft", "meals": [], "quote": try object(quote), "lines": try object([basket]), "frozenRevision": NSNull(), "placedRevision": NSNull()])
        }
        throw ClientError.invalidResponse
    }
}
private final class FoodHTTPRegistry: @unchecked Sendable {
    private struct Weak { weak var fixture: FoodHTTPFixture? }
    private let lock = NSLock(); private var values: [String: Weak] = [:]
    func add(_ fixture: FoodHTTPFixture) { lock.lock(); defer { lock.unlock() }; values[fixture.host] = .init(fixture: fixture) }
    func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: host) }
    func fixture(_ host: String?) -> FoodHTTPFixture? { lock.lock(); defer { lock.unlock() }; return host.flatMap { values[$0]?.fixture } }
}
private final class FoodHTTPProtocol: URLProtocol {
    static let registry = FoodHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.fixture(request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.registry.fixture(request.url?.host) else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        do {
            let bytes = try fixture.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
