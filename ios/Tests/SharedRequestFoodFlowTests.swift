import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedRequestFoodFlowTests: XCTestCase {
    private struct Context {
        let fixture: RequestFoodHTTPFixture
        let service: HouseholdService
        let scope: HouseholdBootstrap
        let inbox: HouseholdInboxModel
        let outbox: OperationOutbox
        let directory: URL
        var queue: URL { directory.appendingPathComponent("request.json") }
        func close() { fixture.release(); RequestFoodProtocol.registry.remove(fixture.host); try? FileManager.default.removeItem(at: directory) }
    }
    private func setup(enabled: Bool = true) async throws -> Context {
        let fixture = RequestFoodHTTPFixture(enabled: enabled); RequestFoodProtocol.registry.add(fixture)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RequestFoodProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config)); let url = URL(string: "https://\(fixture.host)")!
        let auth = AdultAuth(configuration: try .init(projectURL: url, publishableKey: "sb_publishable_fixture"), vault: RequestFoodVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: url), auth: auth, deviceVault: RequestFoodVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "fixture@example.test", code: "123456")
        _ = try await service.enroll(householdID: fixture.household.string)
        let scope = try await service.bootstrap(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = OperationOutbox(url: directory.appendingPathComponent("request.json"))
        let inbox = HouseholdInboxModel(bootstrap: scope, service: service, outbox: outbox, onAccessEnded: {})
        await inbox.load(); inbox.select(try XCTUnwrap(inbox.requests.first))
        return .init(fixture: fixture, service: service, scope: scope, inbox: inbox, outbox: outbox, directory: directory)
    }
    private func open(_ context: Context, link: Bool = false) async throws -> SharedRequestFoodContext {
        let inbox = context.inbox
        inbox.choice = link ? .link : .add
        if link { inbox.linkedLineID = context.fixture.line.string }
        else { inbox.lineItem = "Guest wraps"; inbox.packs = 1; inbox.price = "1.25" }
        await inbox.review(); XCTAssertNotNil(inbox.preview)
        inbox.acceptOverage = true; inbox.acceptUnknown = true; await inbox.apply()
        XCTAssertNil(inbox.pending); XCTAssertTrue(context.fixture.commands.isEmpty)
        return try XCTUnwrap(inbox.requestFood)
    }
    private func draft(_ context: SharedRequestFoodContext, unknown: Bool = false) throws -> SharedFoodDraft {
        var draft = try context.draft(); draft.sources[0].productConfirmed = true
        draft.sources[0].amount = .init(literal: "2", unknown: unknown)
        for index in draft.lines.indices { draft.lines[index].acceptUnresolved = true }
        return draft
    }
    private func waitHeld(_ fixture: RequestFoodHTTPFixture) async throws {
        for _ in 0..<200 { if fixture.heldCount == 1 { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        fixture.release(); XCTFail("Expected request reached neither the held demand read nor preview"); throw ClientError.configuration
    }
    func testAddRetainsOriginalReviewedLineUUIDAndRequestWordingWithoutParsingItsQuantity() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c)
        guard case .add(let line, _, _) = context.reviewed.decision else { return XCTFail() }
        XCTAssertEqual(line.lineId, c.fixture.reviewedAddID)
        XCTAssertEqual(context.targetLineID.string, line.lineId)
        let entered = try draft(context, unknown: true)
        let request = try entered.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context)
        XCTAssertEqual(request.change.lines.map(\.id), [context.targetLineID])
        let source = try XCTUnwrap(request.change.contributions.first)
        XCTAssertEqual(source.source, .request(requestId: c.fixture.requestID, appliedRequestRevision: 5))
        XCTAssertEqual(source.originalText, "Wraps for guests"); XCTAssertNil(source.quantity)
        XCTAssertEqual(entered.sources[0].originalQuantityText, "two bags maybe?")
        XCTAssertEqual(request.action, .request(context.action)); XCTAssertEqual(context.action.previewId.string, c.inbox.preview?.previewId)
        XCTAssertEqual(context.basket.last, line)
    }
    func testReviewedPackAmountsAndOriginalLiteralsSurviveWithoutParsingContributorWording() async throws {
        let c = try await setup(); defer { c.close() }; let original = try await open(c)
        guard case .add(let line, let promote, _) = original.reviewed.decision else { return XCTFail() }
        let needed = ReviewedRequestPackEvidence.Quantity(numerator: "2", denominator: "1", unit: "count", originalLiteral: "two usable wraps")
        let usable = ReviewedRequestPackEvidence.Quantity(numerator: "6", denominator: "1", unit: "count", originalLiteral: "six usable wraps in this pack")
        let evidence = try ReviewedRequestPackEvidence(offerId: "offer", label: line.originalItem, needed: needed, usablePerPack: usable, packs: line.packs, unitPriceMinor: line.unitPriceMinor, availablePackLimit: 3, quoteSource: "Reviewed shelf label", quoteObservedAt: Date(), reviewedAt: Date())
        let reviewed = SharedRequestDecisionReview(request: original.reviewed.request, shop: original.reviewed.shop, decision: .add(line: line, promote: promote, reviewedPackEvidence: evidence), preview: original.reviewed.preview)
        let context = try SharedRequestFoodContext(reviewed: reviewed, page: original.page, acceptOverage: true, acceptUnknown: true)
        var value = try context.draft(); value.sources[0].productConfirmed = true
        for index in value.lines.indices { value.lines[index].acceptUnresolved = true }
        let request = try value.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context)
        XCTAssertEqual(request.change.contributions[0].quantity?.originalLiteral, needed.originalLiteral)
        XCTAssertEqual(request.change.contributions[0].quantity?.amount.numerator, 2)
        XCTAssertEqual(request.packs.first(where: { $0.lineId == context.targetLineID })?.usablePerPack?.originalLiteral, usable.originalLiteral)
        XCTAssertEqual(value.sources[0].originalQuantityText, "two bags maybe?")
        value.sources[0].fixedQuantity = nil
        XCTAssertThrowsError(try value.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context))
    }
    func testLinkRequiresExplicitAdditionalOrWithinExistingQuantityAndKeepsOriginalSources() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c, link: true)
        var entered = try draft(context)
        let additional = try entered.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context)
        XCTAssertTrue(additional.change.edges.isEmpty); XCTAssertTrue(additional.change.lines.isEmpty)
        var link = SharedFoodLinkDraft(); link.demandID = context.sourceID; link.supplyID = c.fixture.manualID
        link.amount = .init(literal: "2", unknown: false); link.evidence = "Two of the twelve already included"
        entered.links = [link]
        XCTAssertThrowsError(try entered.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context))
        entered.links[0].confirmed = true
        let request = try entered.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context)
        XCTAssertEqual(request.change.edges[0].demandId, context.sourceID); XCTAssertEqual(request.change.edges[0].supplyId, c.fixture.manualID)
        XCTAssertEqual(request.change.contributions.map(\.id), [context.sourceID]); XCTAssertTrue(request.change.removeSourceIds.isEmpty)
        XCTAssertEqual(context.page.graph?.contributions[0].quantity?.amount.numerator, 12)
    }
    func testRequestReviewRejectsRewordingRetargetingExtraSourcePacksAndUnrelatedRelationships() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c, link: true); let original = try draft(context)
        func rejects(_ value: SharedFoodDraft) { XCTAssertThrowsError(try value.request(page: context.page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context)) }
        var value = original; value.sources[0].originalText = "Changed author wording"; rejects(value)
        value = original; value.sources[0].lineID = .init(); rejects(value)
        value = original; value.sources.removeAll(); rejects(value)
        value = original; value.sources.append(.init()); rejects(value)
        value = original; value.lines[0].packs += 1; rejects(value)
        value = original; value.lines[0].priceMinor = 999; rejects(value)
        value = original; value.lines[0].name = "Other food"; rejects(value)
        value = original; var link = SharedFoodLinkDraft(); link.kind = .duplicate; link.demandID = c.fixture.manualID; link.supplyID = context.sourceID
        value.links = [link]; rejects(value)
    }
    func testRequestCannotClarifyOrMutateMealAndProtectedIdentityAndKeepsKnownFacts() async throws {
        let c = try await setup(); defer { c.close() }; let original = try await open(c, link: true)
        let kinds: [SharedDemandSource] = [.meal(occurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil),
                .reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil)]
        for source in kinds {
            var graph = try XCTUnwrap(original.page.graph); graph.contributions[0].source = source; graph.contributions[0].productKey = nil
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.page)) as? [String: Any])
            raw["graph"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(graph))
            let page = try JSONDecoder().decode(SharedDemandPage.self, from: JSONSerialization.data(withJSONObject: raw))
            let context = try SharedRequestFoodContext(reviewed: original.reviewed, page: page, acceptOverage: true, acceptUnknown: true)
            var value = try draft(context); value.lines[0].confirmExistingSources = true
            XCTAssertThrowsError(try value.request(page: page, shop: context.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: context))
            graph.contributions[0].productKey = "wraps"; raw["graph"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(graph))
            let knownPage = try JSONDecoder().decode(SharedDemandPage.self, from: JSONSerialization.data(withJSONObject: raw))
            let known = try SharedRequestFoodContext(reviewed: original.reviewed, page: knownPage, acceptOverage: true, acceptUnknown: true)
            let request = try draft(known).request(page: knownPage, shop: known.reviewed.shop, at: "2026-11-09T12:00:00Z", requestContext: known)
            XCTAssertEqual(request.change.contributions.map(\.id), [known.sourceID]); XCTAssertTrue(request.change.removeSourceIds.isEmpty)
            XCTAssertNil(request.change.clarifyReservationProductIds)
            XCTAssertEqual(knownPage.graph?.contributions, graph.contributions)
        }
    }
    func testExpiredMonetaryPreviewCannotOpenFoodReviewOrSendCommand() async throws {
        let c = try await setup(); defer { c.close() }; c.fixture.readFailure = "expired"
        c.inbox.choice = .add; c.inbox.price = "1.25"; await c.inbox.review(); c.inbox.acceptOverage = true; c.inbox.acceptUnknown = true
        XCTAssertFalse(c.inbox.canApply); await c.inbox.apply()
        XCTAssertNil(c.inbox.requestFood); XCTAssertTrue(c.fixture.commands.isEmpty)
    }
    func testBothMonetaryAcknowledgmentsPrecedeFoodReviewAndCannotChangeItsAction() async throws {
        let c = try await setup(); defer { c.close() }
        c.inbox.choice = .add; c.inbox.price = "1.25"; await c.inbox.review()
        XCTAssertFalse(c.inbox.canApply); await c.inbox.apply(); XCTAssertNil(c.inbox.requestFood)
        c.inbox.acceptOverage = true; XCTAssertFalse(c.inbox.canApply)
        c.inbox.acceptUnknown = true; await c.inbox.apply(); XCTAssertNotNil(c.inbox.requestFood)
        c.inbox.acceptUnknown = false; XCTAssertNil(c.inbox.requestFood)
        XCTAssertTrue(c.fixture.commands.isEmpty)
    }
    func testHeldDemandReadCannotAttachToChangedRequestDraftOrRevokedInbox() async throws {
        for revoke in [false, true] {
            let c = try await setup(); defer { c.close() }
            c.inbox.choice = .add; c.inbox.price = "1.25"; await c.inbox.review(); c.inbox.acceptOverage = true; c.inbox.acceptUnknown = true
            c.fixture.holdPath = "/demand"; let task = Task { await c.inbox.apply() }; try await waitHeld(c.fixture)
            if revoke { c.inbox.clear() } else { c.inbox.lineItem = "A different candidate" }
            c.fixture.release(); await task.value
            XCTAssertNil(c.inbox.requestFood); XCTAssertNil(c.inbox.preview); XCTAssertTrue(c.fixture.commands.isEmpty)
        }
    }
    func testUnavailableStaleAndPrivacyReadsNeverSendLegacyApply() async throws {
        for mode in ["unavailable", "stale", "privacy", "revoked"] {
            let c = try await setup(); defer { c.close() }
            c.inbox.choice = .link; c.inbox.linkedLineID = c.fixture.line.string; await c.inbox.review(); c.inbox.acceptOverage = true; c.inbox.acceptUnknown = true
            c.fixture.readFailure = mode
            await c.inbox.apply()
            XCTAssertNil(c.inbox.requestFood); XCTAssertTrue(c.fixture.commands.isEmpty)
            let pending = try await c.outbox.operations(); XCTAssertTrue(pending.isEmpty)
            if mode == "revoked" { XCTAssertFalse(c.inbox.authorized) }
        }
    }
    func testExplicitLegacyPreservesOriginalDecisionApplyWithoutDemandBinding() async throws {
        let c = try await setup(enabled: false); defer { c.close() }
        c.inbox.choice = .add; c.inbox.price = "1.25"; await c.inbox.review(); c.inbox.acceptOverage = true; c.inbox.acceptUnknown = true
        let originalID = c.fixture.reviewedAddID
        await c.inbox.apply()
        XCTAssertNil(c.inbox.requestFood)
        let pending = try XCTUnwrap(c.inbox.pending); XCTAssertNil(pending.sharedDemandBinding)
        XCTAssertEqual(c.fixture.reviewedAddID, originalID)
        XCTAssertEqual(c.fixture.commands, [pending.bytes])
    }
    func testCancelFoodPreviewWritesNothingAndHeldPreviewCannotApproveChangedFoodAmount() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c, link: true)
        let flow = SharedDemandFlowModel(access: c.inbox, request: context); await flow.load(); flow.draft = try draft(context)
        c.fixture.holdPath = "/demand/previews"; let task = Task { await flow.preview() }; try await waitHeld(c.fixture)
        flow.draft.sources[0].amount.literal = "3"
        c.fixture.release(); await task.value
        XCTAssertNil(flow.review); XCTAssertFalse(flow.acknowledged)
        flow.cancel(); c.inbox.cancelRequestFood()
        XCTAssertTrue(c.fixture.commands.isEmpty); let saved = try await c.outbox.operations(); XCTAssertTrue(saved.isEmpty)
    }
    func testAddLostResponseRelaunchRetriesExactDemandAndRequestPreviewsAndReservedReceipt() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c)
        let flow = SharedDemandFlowModel(access: c.inbox, request: context); await flow.load(); flow.draft = try draft(context)
        await flow.preview(); let review = try XCTUnwrap(flow.review)
        flow.acknowledged = false; await flow.apply(); XCTAssertTrue(c.fixture.commands.isEmpty)
        flow.acknowledged = true; await flow.apply()
        let pending = try XCTUnwrap(c.inbox.pending)
        XCTAssertEqual(pending.sharedDemandBinding?.reservedOperationID, review.preview.receipt.operationId)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: pending.bytes)
        XCTAssertEqual(envelope.base.requestRevision, 5)
        XCTAssertEqual(envelope.body["previewId"], .string(context.action.previewId.string))
        XCTAssertEqual(envelope.body["demandReview"], .object(["previewId":.string(review.preview.previewId.string),"previewDigest":.string(review.preview.previewDigest)]))
        let saved = try await c.outbox.operations(); XCTAssertEqual(saved, [pending])
        let fresh = HouseholdInboxModel(bootstrap: c.scope, service: c.service, outbox: OperationOutbox(url: c.queue), onAccessEnded: {})
        await fresh.load(); XCTAssertEqual(fresh.pending, pending); await fresh.retry()
        XCTAssertNil(fresh.pending); XCTAssertEqual(c.fixture.commands, [pending.bytes, pending.bytes])
        guard case .confirmed(let receipt) = fresh.delivery else { return XCTFail("Reserved request receipt did not confirm") }
        XCTAssertEqual(receipt.operationId, review.preview.receipt.operationId.string); XCTAssertEqual(receipt.requestRevision, 6); XCTAssertEqual(receipt.disposition, "added")
        XCTAssertEqual(fresh.confirmedDecisionRequestID, c.fixture.requestID.string)
        XCTAssertEqual(fresh.shop?.lines.last?.lineId, context.targetLineID.string)
        let remaining = try await c.outbox.operations(); XCTAssertTrue(remaining.isEmpty)
    }
    func testWrongReservedRequestReceiptCannotClearDurablePendingOperation() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c)
        let flow = SharedDemandFlowModel(access: c.inbox, request: context); await flow.load(); flow.draft = try draft(context); await flow.preview()
        XCTAssertNotNil(flow.review); flow.acknowledged = true; await flow.apply()
        let pending = try XCTUnwrap(c.inbox.pending)
        flow.cancel(); c.inbox.cancelRequestFood()
        XCTAssertEqual(c.inbox.pending, pending, "Dismissing food review is not cancellation of a queued operation")
        c.fixture.readFailure = "wrongReceipt"
        let fresh = HouseholdInboxModel(bootstrap: c.scope, service: c.service, outbox: OperationOutbox(url: c.queue), onAccessEnded: {})
        await fresh.load(); await fresh.retry()
        XCTAssertEqual(fresh.pending, pending); XCTAssertNil(fresh.confirmedDecisionRequestID)
        let saved = try await c.outbox.operations(); XCTAssertEqual(saved, [pending])
        XCTAssertEqual(c.fixture.commands, [pending.bytes, pending.bytes])
    }
    func testLinkWithinExistingUsesCanonicalUnchangedTotalAndOriginalManualID() async throws {
        let c = try await setup(); defer { c.close() }; let context = try await open(c, link: true)
        let flow = SharedDemandFlowModel(access: c.inbox, request: context); await flow.load(); flow.draft = try draft(context)
        var link = SharedFoodLinkDraft(); link.demandID = context.sourceID; link.supplyID = c.fixture.manualID; link.amount = .init(literal: "2", unknown: false); link.confirmed = true; link.evidence = "Two from the twelve"
        flow.draft.links = [link]; await flow.preview(); let review = try XCTUnwrap(flow.review)
        XCTAssertEqual(review.preview.beforeTotals[0].quantity, review.preview.afterTotals[0].quantity)
        XCTAssertEqual(review.preview.afterTotals[0].activeContributionIds, [c.fixture.manualID, context.sourceID])
        XCTAssertEqual(review.preview.after.contributions[0], review.preview.before.contributions[0])
        flow.cancel(); c.inbox.cancelRequestFood(); XCTAssertTrue(c.fixture.commands.isEmpty)
    }
}

private final class RequestFoodVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
/// Fixed public-contract examples only: manual12, request2, and optional exact
/// two-from-twelve edge. This transport deliberately does not implement a reducer.
private final class RequestFoodHTTPFixture: @unchecked Sendable {
    let host = "request-food-\(UUID().uuidString.lowercased()).test"
    let household = SharedDemandID(), member = SharedDemandID(), shop = SharedDemandID(), line = SharedDemandID(), manualID = SharedDemandID(), requestID = SharedDemandID()
    private let enabled: Bool
    private let lock = NSLock()
    private var bodies: [Data] = [], decision: [String: Any]?, previewID = SharedDemandID(), operationID = SharedDemandID()
    private var result: SharedDemandGraph?, held: [RequestFoodProtocol] = [], heldPath: String?, failure = ""
    init(enabled: Bool) { self.enabled = enabled }
    var commands: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    var reviewedAddID: String? { lock.lock(); defer { lock.unlock() }; return (decision?["line"] as? [String: Any])?["lineId"] as? String }
    var holdPath: String? { get { lock.lock(); defer { lock.unlock() }; return heldPath } set { lock.lock(); defer { lock.unlock() }; heldPath = newValue } }
    var readFailure: String { get { lock.lock(); defer { lock.unlock() }; return failure } set { lock.lock(); defer { lock.unlock() }; failure = newValue } }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    func hold(_ loader: RequestFoodProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard let heldPath, loader.request.url?.path.hasSuffix(heldPath) == true else { return false }; held.append(loader); return true
    }
    func release() { lock.lock(); let pending = held; held = []; heldPath = nil; lock.unlock(); for loader in pending { loader.complete(self) } }
    func cancel(_ loader: RequestFoodProtocol) { lock.lock(); defer { lock.unlock() }; held.removeAll { $0 === loader } }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data("{}".utf8) }
        stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); guard n >= 0 else { throw ClientError.invalidResponse }; if n == 0 { break }; data.append(buffer, count: n); guard data.count <= 1_800_000 else { throw ClientError.invalidResponse } }
        return data
    }
    private func initial() throws -> SharedDemandGraph {
        .init(householdId: household, shopId: shop, revision: 1, lines: [.init(id: line, name: "Wraps", unit: .count, originalOrder: 0)],
            contributions: [.init(id: manualID, lineId: line, source: .manual, productKey: "wraps", productName: "Wraps", originalText: "Twelve wraps", quantity: .init(amount: try .init(numerator: 12), unit: .count, originalLiteral: "12"))], edges: [], usedIds: [line, manualID])
    }
    private func totals(_ graph: SharedDemandGraph) -> [[String: Any]] {
        graph.lines.map { row in
            let sources = graph.contributions.filter { $0.lineId == row.id }
            let quantity: Any
            if sources.contains(where: { $0.quantity == nil }) { quantity = NSNull() }
            else {
                let total = row.id == line ? (sources.count == 2 && graph.edges.isEmpty ? "14" : "12") : "2"
                quantity = ["numerator":total,"denominator":"1"]
            }
            return ["lineId":row.id.string,"unit":"count","quantity":quantity,"activeContributionIds":sources.map { $0.id.string }]
        }
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        func json(_ object: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: object)) }
        if path.hasSuffix("/auth/v1/verify") { return try json(["access_token":"fixture","refresh_token":"fixture-refresh","expires_in":3600,"user":["id":"adult","email_confirmed_at":"date"]]) }
        if path.hasSuffix("/auth/v1/user") { return try json(["id":"adult","email_confirmed_at":"date"]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":"device","deviceToken":"device-token"]) }
        if path.hasSuffix("/bootstrap") { return try json(["household":["id":household.string,"label":"Home"],"memberId":member.string,"role":"shopper","shopId":shop.string,"enrolled":true,"queueConsent":false,"capabilities":["shopper_commands","shopper_inbox","request_preview"]]) }
        if path.hasSuffix("/replay-windows") { return try json(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"]) }
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 100, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let basket = ShopperBasketLine(lineId: line.uuid, originalItem: "Wraps", packs: 2, unitPriceMinor: 100, feeEligible: true)
        if path.hasSuffix("/inbox") { return try json(["requests":[["requestId":requestID.string,"shopId":shop.string,"revision":bodies.isEmpty ? 5:6,"originalItem":"Wraps for guests","ownQuantity":"two bags maybe?","authoredAt":"2026-11-09T12:00:00Z","receivedAt":"2026-11-09T12:00:01Z","route":"current","status":bodies.isEmpty ? "pending":"added","ownActionAllowed":bodies.isEmpty]],"nextCursor":NSNull()]) }
        if path.hasSuffix("/shops/" + shop.string) {
            var lines = [try object(basket)]
            if !bodies.isEmpty, let added = decision?["line"] { lines.append(added) }
            return try json(["shopId":shop.string,"shopRevision":bodies.isEmpty ? 3:4,"authorityEpoch":1,"phase":"draft","meals":[],"quote":try object(quote),"lines":lines])
        }
        if path.hasSuffix("/demand") {
            if failure == "unavailable" || failure == "revoked" { return try json(["error":["code":"access_ended"]], failure == "revoked" ? 403:500) }
            let graph = try (!bodies.isEmpty ? result : nil) ?? initial()
            return try json(["schemaVersion":1,"shopId":shop.string,"shopRevision":bodies.isEmpty ? (failure == "stale" ? 4:3):4,"authorityEpoch":1,"status":enabled ? (failure == "privacy" ? "reviewRequired":"enabled"):"legacy","graph":enabled ? try object(graph):NSNull(),"totals":enabled ? totals(graph):[]])
        }
        if path.hasSuffix("/demand/previews") {
            let input = try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: body(request))
            let two = try SharedDemandAmount(numerator: 2)
            guard input.mode == .change, case .request(let action) = input.action, action.requestId == requestID, action.previewId == previewID,
                  action.acceptOverage, action.acceptUnknown, input.change.contributions.count == 1,
                  input.change.removeSourceIds.isEmpty, input.change.removeEdgeIds.isEmpty,
                  let contribution = input.change.contributions.first,
                  contribution.source == .request(requestId: requestID, appliedRequestRevision: 5),
                  contribution.quantity == nil || contribution.quantity?.amount == two,
                  input.change.edges.count <= 1 else { throw ClientError.invalidResponse }
            let before = try initial(); var after = before; after.revision = 2
            after.lines += input.change.lines; after.contributions += input.change.contributions; after.edges = input.change.edges
            if let edge = after.edges.first { guard edge.kind == .withinExisting, edge.demandId == contribution.id, edge.supplyId == manualID, edge.quantity.amount == two else { throw ClientError.invalidResponse } }
            after.usedIds += input.change.lines.map(\.id) + [contribution.id] + input.change.edges.map(\.id)
            result = after; operationID = .init()
            let receipt: [String: Any] = ["schemaVersion":1,"operationId":operationID.string,"householdId":household.string,"shopId":shop.string,"baseRevision":1,"resultRevision":2,
                "lines":try input.change.lines.map { ["id":$0.id.string,"before":NSNull(),"after":try object($0)] },
                "contributions":[["id":contribution.id.string,"before":NSNull(),"after":try object(contribution)]],
                "edges":try input.change.edges.map { ["id":$0.id.string,"before":NSNull(),"after":try object($0)] }]
            return try json(["previewId":SharedDemandID().string,"previewDigest":String(repeating:"b",count:64),"expiresAt":"2099-01-01T00:00:00Z","before":try object(before),"after":try object(after),"receipt":receipt,"packs":try object(input.packs),"beforeTotals":totals(before),"afterTotals":totals(after),"shopRevision":3,"authorityEpoch":1])
        }
        if path.hasSuffix("/previews") {
            let input = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            decision = input["decision"] as? [String: Any]; previewID = .init()
            let budget: [String: Any] = ["currency":"USD","totalMinor":NSNull(),"overCapMinor":NSNull(),"headroomMinor":NSNull(),"status":"unresolved","scope":"wholeCheckout","missing":["price"],"lowerBoundMinor":200,"upperBoundMinor":NSNull(),"wholeCheckoutWithinCap":false]
            return try json(["previewId":previewID.string,"expiresAt":failure == "expired" ? "2020-01-01T00:00:00Z":"2099-01-01T00:00:00Z","shopRevision":3,"authorityEpoch":1,"requestRevision":5,"choice":decision!["choice"]!,"before":budget,"after":budget,"changeMinor":NSNull(),"requiresOverageAcceptance":true,"requiresUnknownAcceptance":true])
        }
        if path.hasSuffix("/commands") {
            let data = try body(request); bodies.append(data)
            if bodies.count == 1 { throw URLError(.networkConnectionLost) }
            return try json(["operationId":operationID.string,"kind":"request.apply","shopId":shop.string,"shopRevision":4,"authorityEpoch":1,"disposition":"added","requestId":requestID.string,"requestRevision":failure == "wrongReceipt" ? 7:6])
        }
        throw ClientError.invalidResponse
    }
}
private final class RequestFoodRegistry: @unchecked Sendable {
    private struct Weak { weak var value: RequestFoodHTTPFixture? }
    private let lock = NSLock(); private var values: [String: Weak] = [:]
    func add(_ fixture: RequestFoodHTTPFixture) { lock.lock(); defer { lock.unlock() }; values[fixture.host] = .init(value: fixture) }
    func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: host) }
    func find(_ host: String?) -> RequestFoodHTTPFixture? { lock.lock(); defer { lock.unlock() }; return host.flatMap { values[$0]?.value } }
}
private final class RequestFoodProtocol: URLProtocol {
    static let registry = RequestFoodRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.find(request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { guard let fixture = Self.registry.find(request.url?.host) else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }; if !fixture.hold(self) { complete(fixture) } }
    func complete(_ fixture: RequestFoodHTTPFixture) {
        do { let (status, data) = try fixture.respond(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.registry.find(request.url?.host)?.cancel(self) }
}
