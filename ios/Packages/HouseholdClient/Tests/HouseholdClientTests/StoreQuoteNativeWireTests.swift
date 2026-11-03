import Security
import XCTest
@testable import HouseholdClient

private final class StoreQuoteLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate,
              SecTrustSetAnchorCertificates(trust,[leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess, SecTrustEvaluateWithError(trust,nil) else {
            completionHandler(.cancelAuthenticationChallenge,nil); return
        }
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
}
final class StoreQuoteNativeWireTests: XCTestCase {
    func testStoreQuoteClientAgainstPostgres() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["RITC_QUOTES_PORT"] else { throw XCTSkip("Run isolated store quote PostgreSQL tests with RITC_TEST_NATIVE_WIRE=1.") }
        let base = try XCTUnwrap(URL(string:"https://127.0.0.1:\(port)"))
        let cert = try Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(env["RITC_QUOTES_CERT"])))
        let session = URLSession(configuration:.ephemeral,delegate:StoreQuoteLoopbackTrust(certificate:cert),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session:session)
        let auth = AdultAuth(configuration:try .init(projectURL:base,publishableKey:"sb_publishable_quote_fixture"),vault:MemoryVault(),transport:transport)
        _ = try await auth.verifyEmailCode(email:"wire@example.invalid",code:XCTUnwrap(env["RITC_QUOTES_CODE"]))
        let service = HouseholdService(configuration:try .init(baseURL:base),auth:auth,deviceVault:MemoryVault(),transport:transport)
        _ = try await service.enroll(householdID:XCTUnwrap(env["RITC_QUOTES_HOUSEHOLD"]))
        let shop = try XCTUnwrap(UUID(uuidString:XCTUnwrap(env["RITC_QUOTES_SHOP"])))
        let scope = try await service.selectShop(shop)
        XCTAssertTrue(scope.capabilities.contains("store_quotes"))
        let page = try await service.storeQuotes(shopID:shop)
        if env["RITC_QUOTES_SHOPPER"] == "1" {
            XCTAssertTrue(page.shopper)
            let pair = try XCTUnwrap(page.pairs.first(where: { !$0.own && !$0.proposals.isEmpty }))
            XCTAssertTrue(pair.current(in:page)); XCTAssertEqual(page.pairs.count,1,"Adult private saves must not leak to shopper")
            let proposal = try XCTUnwrap(pair.proposals.first)
            let intent = try await service.prepareStoreQuote(shopID:shop,action:.adoptions,request:.init(page:page,pairId:pair.id,choice:proposal.choice,proposalId:proposal.id))
            let first = try await service.executeStoreQuote(intent), retry = try await service.executeStoreQuote(intent)
            XCTAssertEqual(first,retry)
            let current = try await service.storeQuotes(shopID:shop), basket = try await service.shopperShop(shopID:shop.uuidString.lowercased())
            XCTAssertEqual(current.shopRevision,page.shopRevision+1); XCTAssertEqual(current.currentBasis?.branch,"West branch")
            XCTAssertTrue(current.pairs.allSatisfy { !$0.current(in:current) })
            XCTAssertTrue(basket.lines.allSatisfy { $0.unitPriceMinor == nil })
            XCTAssertFalse(basket.quote.complete)
        } else {
            XCTAssertFalse(page.shopper); XCTAssertTrue(page.adults.isEmpty)
            let options = EnteredStoreQuoteOptions(first:option(label:"First",checkout:3800,trip:0,minutes:0),second:option(label:"Second",checkout:3500,trip:400,minutes:18))
            let save = try await service.prepareStoreQuote(shopID:shop,action:.pairs,request:.init(page:page,options:options))
            let first = try await service.executeStoreQuote(save), retry = try await service.executeStoreQuote(save)
            XCTAssertEqual(first,retry)
            var current = try await service.storeQuotes(shopID:shop)
            let pair = try XCTUnwrap(current.pairs.first { $0.id == save.id })
            XCTAssertTrue(pair.own); XCTAssertTrue(pair.proposals.isEmpty); XCTAssertEqual(current.shopRevision,page.shopRevision)
            XCTAssertEqual(pair.comparison.firstCheckout,3800); XCTAssertEqual(pair.comparison.secondCheckout,3500)
            XCTAssertEqual(pair.comparison.checkoutDelta,-300); XCTAssertEqual(pair.comparison.cashDelta,100)
            XCTAssertEqual(pair.comparison.minutesDelta,18); XCTAssertEqual(pair.comparison.preferred,.first)
            let proposal = try await service.prepareStoreQuote(shopID:shop,action:.proposals,request:.init(page:current,pairId:pair.id,choice:.second))
            _ = try await service.executeStoreQuote(proposal); _ = try await service.executeStoreQuote(proposal)
            current = try await service.storeQuotes(shopID:shop)
            var unknown = options.second; unknown.tripMinor = nil
            let unknownIntent = try await service.prepareStoreQuote(shopID:shop,action:.pairs,request:.init(page:current,options:.init(first:options.first,second:unknown)))
            _ = try await service.executeStoreQuote(unknownIntent)
            current = try await service.storeQuotes(shopID:shop)
            let unresolved = try XCTUnwrap(current.pairs.first { $0.id == unknownIntent.id })
            XCTAssertNil(unresolved.comparison.preferred); XCTAssertNil(unresolved.comparison.cashDelta); XCTAssertEqual(unresolved.comparison.secondBreakEven,300)
            XCTAssertEqual(current.shopRevision,page.shopRevision); XCTAssertEqual(current.pairs.count,2)
            XCTAssertEqual(current.pairs.flatMap(\.proposals).count,1)
        }
    }
    private func option(label: String, checkout: Int, trip: Int?, minutes: Int) -> EnteredStoreQuote {
        let now = Date(), f = ISO8601DateFormatter()
        return .init(label:label,store:label,branch:label == "Second" ? "West branch":"East branch",mode:"pickup",
            slot:f.string(from:now.addingTimeInterval(3600)),observedAt:f.string(from:now),source:"Manual reviewed checkout",itemsMinor:checkout,
            checkoutMinor:checkout,allChargesIncluded:true,available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:trip == 0,
            tripMinor:trip,extraMinutes:minutes,capMinor:4000,eligibilityConfirmed:true)
    }
}
