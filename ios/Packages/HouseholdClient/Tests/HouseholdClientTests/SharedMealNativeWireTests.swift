import Security
import XCTest
@testable import HouseholdClient

private final class SharedMealLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class SharedMealNativeWireTests: XCTestCase {
    func testSharedMealClientAgainstPostgres() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPort = env["RITC_WIRE_PORT"] else { throw XCTSkip("Run isolated shared meal PostgreSQL tests with RITC_TEST_NATIVE_WIRE=1.") }
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(rawPort)"))
        let cert = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration: .ephemeral, delegate: SharedMealLoopbackTrust(certificate: cert), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session: session)
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_meal_fixture"), vault: MemoryVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "wire@example.invalid", code: XCTUnwrap(env["RITC_WIRE_CODE"]))
        let service = HouseholdService(configuration: try .init(baseURL: base), auth: auth, deviceVault: MemoryVault(), transport: transport)
        _ = try await service.enroll(householdID: XCTUnwrap(env["RITC_WIRE_HOUSEHOLD"]))
        let shopID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(env["RITC_WIRE_SHOP"])))
        let scope = try await service.selectShop(shopID)
        let page = try await service.sharedMealChanges(shopID: shopID)
        if env["RITC_WIRE_SHOPPER"] == "1" {
            XCTAssertTrue(page.shopper)
            let proposal = try XCTUnwrap(page.proposals.first)
            XCTAssertTrue(proposal.isCurrent(in: page)); XCTAssertNotNil(proposal.request.meal.planning?.bindings)
            let current = try await service.shopperShop(shopID: shopID.uuidString.lowercased())
            var body = try ShopperShopCandidate(quote: current.quote, lines: current.lines).commandBody()
            var edit = SharedMealEdit(occurrenceID: proposal.request.occurrenceId, meal: proposal.request.meal, changeProposalID: proposal.id)
            edit.baseMealRevision = proposal.request.baseMealRevision
            body["mealEdit"] = try edit.commandValue()
            let window = try await service.replayWindow()
            let op = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: current.shopId, kind: "shop.patch", base: .init(shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch), body: body), bootstrap: scope)
            let first = try await service.executeSharedShop(op), retry = try await service.executeSharedShop(op)
            XCTAssertEqual(first.operationId, retry.operationId)
            let updated = try await service.sharedMealChanges(shopID: shopID)
            XCTAssertEqual(updated.proposals.first?.state, "applied")
            XCTAssertEqual(updated.meals.first?.meal, proposal.request.meal)
            let reviewedShop = try await service.shopperShop(shopID: current.shopId)
            XCTAssertEqual(reviewedShop.shopRevision, current.shopRevision + 1)
            let prepared = try await service.preparePlacementSnapshot(reviewed: reviewedShop)
            let placed = try await service.executePlacementReport(try .init(prepared: prepared, occurredAt: ISO8601DateFormatter().string(from: Date())))
            XCTAssertEqual(placed.disposition, "placed")
            try await exerciseDelivery(service, scope: scope, shopID: current.shopId)

        } else {
            XCTAssertFalse(page.shopper)
            let occurrence = try XCTUnwrap(page.meals.first)
            var meal = occurrence.meal; meal.title = "Reviewed native guest plan"
            let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: occurrence.id, meal: meal, reason: "Exact native proposal across two adults")
            try await service.executeSharedMealChange(intent)
            try await service.executeSharedMealChange(intent)
            let updated = try await service.sharedMealChanges(shopID: shopID)
            XCTAssertEqual(updated.proposals.count, 1); XCTAssertEqual(updated.proposals[0].request, intent.request)
            XCTAssertEqual(updated.meals, page.meals)
        }
    }
    private func exerciseDelivery(_ service: HouseholdService, scope: HouseholdBootstrap, shopID: String) async throws {
        func save(_ change: SharedDeliveryEdit, page: SharedDeliveryPage) async throws -> ShopperReceipt {
            let window = try await service.replayWindow()
            let operation = try await service.prepare(envelope: .init(replayWindow: window.id, shopId: shopID, kind: change.kind,
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), body: change.body(reviewed: page)), bootstrap: scope)
            let first = try await service.executeSharedShop(operation)
            let replay = try await service.executeSharedShop(operation)
            XCTAssertEqual(replay, first)
            return first
        }
        let empty = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertTrue(empty.sources.isEmpty)
        let sealed = try XCTUnwrap(empty.lines.first)
        let receipt = try await save(.register(lineID: sealed.id, segment: UUID(), name: "Cannellini beans", exclusions: []), page: empty)
        let source = try XCTUnwrap(receipt.sourceId)
        let registered = try await service.deliveryEvidence(shopID: shopID)
        let amount: (Int) -> SharedMealQuantity = { .init(amount: .init(numerator: $0), unit: "gram", originalLiteral: String($0)) }
        let arrival = UUID()
        _ = try await save(.arrival(source: source, previous: nil, observation: arrival, date: Date().addingTimeInterval(-90), received: amount(8)), page: registered)
        let arrived = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertNil(arrived.sources.first?.confirmed)
        let usable = UUID()
        _ = try await save(.usable(source: source, previous: nil, arrival: arrival, observation: usable, date: Date(), quantity: amount(6)), page: arrived)
        let counted = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(counted.sources.first?.confirmed?.quantity, amount(6))
        _ = try await save(.usable(source: source, previous: usable, arrival: arrival, observation: UUID(), date: Date(), quantity: amount(7)), page: counted)
        let corrected = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(corrected.lines, empty.lines)
        XCTAssertEqual(corrected.shopRevision, empty.shopRevision)
        XCTAssertEqual(corrected.supplyRevision, 4)
        XCTAssertEqual(corrected.sources.count, 1)
        XCTAssertEqual(corrected.sources.first?.confirmed?.quantity, amount(7))
        XCTAssertEqual(corrected.sources.first?.arrival?.received, amount(8))
        let occurrence = try XCTUnwrap(corrected.meals?.first)
        let ingredient = try XCTUnwrap(occurrence.meal.planning?.ingredients.first)
        let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
        XCTAssertEqual(occurrence.meal.title, "Reviewed native guest plan")
        XCTAssertEqual(ingredient.name, "Beans")
        XCTAssertEqual(corrected.sources.first?.matches, [])
        _ = try await save(.match(source: source, ingredient: target, matched: true), page: corrected)
        let matched = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(matched.sources.first?.matches, [target])
        XCTAssertEqual(matched.sources.first?.confirmed, corrected.sources.first?.confirmed)
        let coverage = try await service.deliveryCoverage(reviewed: matched)
        let lunch = try XCTUnwrap(coverage.needs.first(where: { $0.protected }))
        let dinner = try XCTUnwrap(coverage.needs.first(where: { !$0.protected }))
        XCTAssertEqual(lunch.covered?.formatted, "7"); XCTAssertEqual(lunch.missing?.formatted, "193")
        XCTAssertEqual(lunch.allocations.map(\.sourceId), [source])
        XCTAssertEqual(dinner.covered?.formatted, "0")
        _ = try await save(.match(source: source, ingredient: target, matched: false), page: matched)
        let removed = try await service.deliveryEvidence(shopID: shopID)
        XCTAssertEqual(removed.sources.first?.matches, [])
        XCTAssertEqual(removed.supplyRevision, 6)
        let unlinked = try await service.deliveryCoverage(reviewed: removed)
        XCTAssertTrue(unlinked.needs.allSatisfy { $0.covered?.formatted == "0" && $0.issues.contains("noMatch") })
        do { _ = try await service.deliveryCoverage(reviewed: matched); XCTFail("Displayed stale counts after removing match") }
        catch { XCTAssertEqual(error as? ClientError, .service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)) }
    }

}
