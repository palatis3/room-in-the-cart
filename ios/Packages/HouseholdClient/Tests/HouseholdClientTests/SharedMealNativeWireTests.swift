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
}
