import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testSelectedShopIsPinnedAcrossEnrollmentAndClearedForHouseholdOverview() async throws {
        let auth = try auth(), vault = MemoryVault(), shopID = UUID()
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        var ignoreSelection = false
        var bootstrapHeaders: [String?] = []
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (201, Data(#"{"deviceId":"device","deviceToken":"test"}"#.utf8)) }
            let selected = request.value(forHTTPHeaderField: "X-Shop-ID")
            if request.url!.path.hasSuffix("/bootstrap") {
                bootstrapHeaders.append(selected)
                var result: [String:Any] = ["household":["id":self.household,"label":"Home"],"memberId":self.member,
                    "role":"organizer","enrolled":true,"capabilities":["household_admin"],"queueConsent":false,"canSelectShop":true,
                    "selectionRequired":selected == nil]
                result["shopId"] = ignoreSelection ? nil : selected
                return (200,try JSONSerialization.data(withJSONObject:result))
            }
            if request.url!.path.hasSuffix("/shops") {
                XCTAssertNil(selected)
                let shop: [String:Any] = ["shopId":shopID.uuidString,"createdAt":"2026-11-01T00:00:00Z","phase":"draft","role":"contributor"]
                return (200,try JSONSerialization.data(withJSONObject:["shops":[shop],"nextCursor":NSNull()]))
            }
            throw URLError(.unsupportedURL)
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456")
        let initial = try await service.enroll(householdID: household)
        XCTAssertEqual(initial.selectionRequired,true)
        let choices = try await service.selectableShops(closedAndOwned:false,cursor:nil)
        XCTAssertEqual(choices.shops.map(\.id),[shopID])
        let selected = try await service.selectShop(shopID)
        XCTAssertEqual(selected.shopId,shopID.uuidString.lowercased())
        service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        let restored = try await service.enroll(householdID: household)
        XCTAssertEqual(restored.shopId, selected.shopId)
        let overview = try await service.selectShop(nil)
        XCTAssertNil(overview.shopId)
        XCTAssertEqual(bootstrapHeaders,[nil,selected.shopId,selected.shopId,nil])
        ignoreSelection = true
        do { _ = try await service.selectShop(shopID); XCTFail("Ignored shop selection must fail closed") }
        catch { XCTAssertEqual(error as? ClientError,.accessEnded) }
    }
    func testSharedQuoteEncodesRequiredNullsAndOnlyActiveFeeFields() throws {
        for fee in [ShopperQuote.Fee.fixed(nil), .threshold(3500, below: nil, above: 0)] {
            let quote = try ShopperQuote(scope: "wholeCheckout", complete: false, capMinor: nil, capScope: "unknown", fee: fee,
                taxesMinor: nil, depositsMinor: nil, discountsMinor: nil, observedAt: Date(), expiresAt: Date().addingTimeInterval(60))
            let candidate = try ShopperShopCandidate(quote: quote, lines: [.init(originalItem: "Wraps", packs: 2, unitPriceMinor: nil, feeEligible: true)])
            let body = try candidate.commandBody()
            guard case .object(let q) = body["quote"], case .object(let f) = q["fee"] else { return XCTFail("Missing quote") }
            for key in ["capMinor", "taxesMinor", "depositsMinor", "discountsMinor"] { XCTAssertEqual(q[key], .null) }
            if fee.kind == "fixed" { XCTAssertEqual(Set(f.keys), Set(["kind", "amountMinor"])); XCTAssertEqual(f["amountMinor"], .null) }
            else { XCTAssertEqual(Set(f.keys), Set(["kind", "thresholdMinor", "belowMinor", "aboveMinor"])); XCTAssertEqual(f["belowMinor"], .null) }
        }
    }
    func testSharedShopCreationRetriesExactBytesAfterBecomingShopperAndDeniesContributor() async throws {
        let auth = try auth(); let shop = UUID().uuidString.lowercased(); var created = false; var contributor = false; var commands: [Data] = []
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (201, Data(#"{"deviceId":"device","deviceToken":"token"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") {
                let role = contributor ? "contributor" : created ? "shopper" : "organizer"
                return (200, Data("{\"household\":{\"id\":\"\(self.household)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"\(role)\",\"shopId\":\(created ? "\"\(shop)\"" : "null"),\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[\"household_admin\",\"shopper_inbox\",\"request_preview\",\"shopper_commands\"]}".utf8))
            }
            guard request.url!.path.hasSuffix("/commands") else { throw URLError(.unsupportedURL) }
            let data: Data
            if let body = request.httpBody { data = body }
            else { let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 16384); let count = stream.read(&buffer, maxLength: buffer.count); data = Data(buffer.prefix(count)) }
            commands.append(data); created = true
            return (200, Data("{\"operationId\":\"op\",\"kind\":\"shop.create\",\"shopId\":\"\(shop)\",\"shopRevision\":1,\"authorityEpoch\":1,\"disposition\":\"created\"}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let scope = try await service.enroll(householdID: household)
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: false, capMinor: nil, capScope: "wholeCheckout", fee: .fixed(nil), taxesMinor: nil, depositsMinor: nil, discountsMinor: nil, observedAt: Date(), expiresAt: Date().addingTimeInterval(60))
        let candidate = try ShopperShopCandidate(quote: quote, lines: [])
        let operation = try await service.prepare(envelope: .init(replayWindow: UUID().uuidString, shopId: shop, kind: "shop.create", base: .init(shopRevision: 0, authorityEpoch: 0), body: candidate.commandBody()), bootstrap: scope)
        let first = try await service.executeSharedShop(operation); let second = try await service.executeSharedShop(operation)
        XCTAssertEqual(first, second); XCTAssertEqual(commands, [operation.bytes, operation.bytes])
        contributor = true
        do { _ = try await service.executeSharedShop(operation); XCTFail("Contributor used organizer capability") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(commands.count, 2)
    }
    func testSharedCandidateRejectsDuplicateLinesAndInvalidQuoteTimes() throws {
        let now = Date(); let line = ShopperBasketLine(originalItem: "Wraps", packs: 1, unitPriceMinor: nil, feeEligible: true)
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: false, capMinor: nil, capScope: "wholeCheckout", fee: .fixed(nil), taxesMinor: nil, depositsMinor: nil, discountsMinor: nil, observedAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertThrowsError(try ShopperShopCandidate(quote: quote, lines: [line, line]))
        XCTAssertThrowsError(try ShopperQuote(scope: "wholeCheckout", complete: false, capMinor: nil, capScope: "wholeCheckout", fee: .fixed(nil), taxesMinor: nil, depositsMinor: nil, discountsMinor: nil, observedAt: now, expiresAt: now))
    }
}
