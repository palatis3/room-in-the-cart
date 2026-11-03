import XCTest
@testable import HouseholdClient

private func quoteOption(checkout: Int? = 3800, trip: Int? = 0) -> EnteredStoreQuote {
    .init(label: "Entered store", store: "Store", branch: "Uptown", mode: "pickup", slot: "2026-11-05T18:00:00Z", observedAt: "2026-11-03T12:00:00Z", source: "Retailer checkout reviewed", itemsMinor: 3500, checkoutMinor: checkout, allChargesIncluded: true, available: true, quantitiesMatched: true, singleStore: true, tripAlreadyPlanned: true, tripMinor: trip, extraMinutes: 0, capMinor: 4000, eligibilityConfirmed: true)
}
private func quotePage(shop: UUID, shopper: Bool = false, revision: Int = 3, epoch: Int = 2, grant: Int = 1) throws -> StoreQuotePage {
    try JSONDecoder().decode(StoreQuotePage.self, from: JSONSerialization.data(withJSONObject: ["shopId":shop.uuidString,"shopRevision":revision,"authorityEpoch":epoch,"grantRevision":shopper ? 0 : grant,"shopper":shopper,"phase":"draft","adults":[],"commitments":[["id":UUID().uuidString,"label":"Wraps","packs":2]],"currentBasis":NSNull(),"pairs":[],"nextCursor":NSNull()]))
}
extension HouseholdClientTests {
    func testStoreQuoteUnknownsEncodeNullAndAdoptionDoesNotLeakOtherActionFields() throws {
        var unknown = quoteOption(checkout: nil, trip: nil); unknown.itemsMinor = nil; unknown.available = nil; unknown.extraMinutes = nil; unknown.capMinor = nil
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String:Any])
        for key in ["itemsMinor","checkoutMinor","available","tripMinor","extraMinutes","capMinor"] { XCTAssertTrue(raw[key] is NSNull,key) }
        XCTAssertEqual(raw["currency"] as? String,"USD"); XCTAssertEqual(raw["eligibilityConfirmed"] as? Bool,true)
        let request = StoreQuoteWrite(page: try quotePage(shop: UUID(), shopper: true), pairId: UUID(), choice: .second)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body(for: .adoptions)) as? [String:Any])
        XCTAssertEqual(Set(body.keys),["operationId","shopRevision","authorityEpoch","grantRevision","pairId","choice","proposalId"])
        XCTAssertTrue(body["proposalId"] is NSNull)
        XCTAssertThrowsError(try request.body(for: .pairs))
    }
    func testStoreQuoteContractRejectsNegativeCashAndMissingIdentityBinding() throws {
        var value = quoteOption(); value.tripMinor = -1; XCTAssertThrowsError(try value.validate())
        value = quoteOption(); value.capScope = "dinnersOnly"; XCTAssertThrowsError(try value.validate())
        let request = StoreQuoteWrite(page: try quotePage(shop: UUID()), options: .init(first: quoteOption(),second: quoteOption()))
        XCTAssertThrowsError(try StoreQuoteIntent(context: .init(subject: "",householdID: household,memberID: member,deviceID: "device"),shopID: UUID(),action: .pairs,request: request))
    }
    func testStoreQuoteDefaultShopPinsHeaderAndExactRetrySurvivesStaleRevisionThenRevocation() async throws {
        let auth = try auth(), shop = UUID(), base = try quotePage(shop: shop), options = EnteredStoreQuoteOptions(first: quoteOption(),second: quoteOption(checkout: 3500,trip: 400))
        let service = HouseholdService(configuration: try .init(baseURL: URL(string:"https://service.test")!),auth:auth,deviceVault:MemoryVault(),transport:transport())
        var bodies: [Data] = [], revision = 3, revoked = false
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (201,Data(#"{"deviceId":"device","deviceToken":"secret"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") {
                return (200,try JSONSerialization.data(withJSONObject:["household":["id":self.household,"label":"Home"],"memberId":self.member,"role":"contributor","shopId":shop.uuidString.lowercased(),"enrolled":true,"queueConsent":false,"capabilities":["store_quotes"]]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Shop-ID"),shop.uuidString.lowercased())
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Device-Token"),"secret")
            if revoked { return (404,Data(#"{"error":{"code":"unavailable"}}"#.utf8)) }
            if request.url!.path.hasSuffix("/store-quotes") {
                return (200,try JSONEncoder().encode(quotePage(shop:shop,revision:revision)))
            }
            guard request.url!.path.hasSuffix("/pairs") else { throw URLError(.unsupportedURL) }
            let bytes = try self.storeQuoteBody(request); bodies.append(bytes)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            return (200,try JSONSerialization.data(withJSONObject:["operationId":raw["operationId"]!,"shopRevision":3]))
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID:household)
        let intent = try await service.prepareStoreQuote(shopID:shop,action:.pairs,request:.init(page:base,options:options))
        let first = try await service.executeStoreQuote(intent); revision = 4
        let retry = try await service.executeStoreQuote(intent)
        XCTAssertEqual(first,retry); XCTAssertEqual(bodies,[intent.bytes,intent.bytes])
        revoked = true
        do { _ = try await service.executeStoreQuote(intent); XCTFail("Revoked adult reused old receipt") } catch {}
        XCTAssertEqual(bodies.count,2)
    }
    func testStoreQuoteDifferentSelectedShopCannotReadOrReplay() async throws {
        let auth = try auth(), selected = UUID(), other = UUID()
        let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://service.test")!),auth:auth,deviceVault:MemoryVault(),transport:transport())
        var quoteReads = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (201,Data(#"{"deviceId":"device","deviceToken":"secret"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") {
                return (200,try JSONSerialization.data(withJSONObject:["household":["id":self.household,"label":"Home"],"memberId":self.member,"role":"contributor","shopId":request.value(forHTTPHeaderField:"X-Shop-ID") ?? selected.uuidString.lowercased(),"enrolled":true,"queueConsent":false,"capabilities":["store_quotes"]]))
            }
            quoteReads += 1; throw URLError(.unsupportedURL)
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID:household); _ = try await service.selectShop(selected)
        do { _ = try await service.storeQuotes(shopID:other); XCTFail("Cross-shop read") } catch { XCTAssertEqual(error as? ClientError,.accessEnded) }
        XCTAssertEqual(quoteReads,0)
    }
    private func storeQuoteBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(buffer,count:n) }
        return data
    }
}
