import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var shopID: String { "00000000-0000-4000-8000-000000000010" }
    private var requestID: String { "00000000-0000-4000-8000-000000000011" }
    private var previewID: String { "00000000-0000-4000-8000-000000000012" }
    private func bootstrapBytes(role: String) -> Data {
        Data("{\"household\":{\"id\":\"\(household)\",\"label\":\"Home\"},\"memberId\":\"\(member)\",\"role\":\"\(role)\",\"shopId\":\"\(shopID)\",\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[\"shopper_inbox\",\"request_preview\",\"shopper_commands\"]}".utf8)
    }
    private func requestBytes(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private func budget(total: Int, overage: Int) -> String {
        "{\"currency\":\"USD\",\"totalMinor\":\(total),\"overCapMinor\":\(overage),\"headroomMinor\":\(3800-total),\"status\":\"\(overage > 0 ? "overCap" : "withinCap")\",\"scope\":\"wholeCheckout\",\"missing\":[],\"lowerBoundMinor\":\(total),\"upperBoundMinor\":\(total),\"wholeCheckoutWithinCap\":\(overage == 0)}"
    }
    func testContributorCannotFetchShopperPayloadDespiteAdvertisedCapabilities() async throws {
        let auth = try auth(); var privateCalls = 0
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") { return (200, self.bootstrapBytes(role: "contributor")) }
            privateCalls += 1; return (500, Data())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        do { _ = try await service.shopperShop(shopID: shopID); XCTFail("Contributor fetched prices") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.shopperInbox(shopID: shopID); XCTFail("Contributor fetched other requests") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(privateCalls, 0)
    }
    func testPreviewUsesReviewedBaseAndDecisionRetryKeepsExactBytes() async throws {
        let auth = try auth(); var role = "shopper"; var previews: [Data] = []; var commands: [Data] = []
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "device-token")
            if request.url!.path.hasSuffix("/bootstrap") { return (200, self.bootstrapBytes(role: role)) }
            if request.url!.path.hasSuffix("/previews") {
                previews.append(self.requestBytes(request))
                return (200, Data("{\"previewId\":\"\(self.previewID)\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"shopRevision\":7,\"authorityEpoch\":3,\"requestRevision\":2,\"choice\":\"add\",\"before\":\(self.budget(total: 3720, overage: 0)),\"after\":\(self.budget(total: 4069, overage: 269)),\"changeMinor\":349,\"requiresOverageAcceptance\":true,\"requiresUnknownAcceptance\":false}".utf8))
            }
            commands.append(self.requestBytes(request)); throw URLError(.networkConnectionLost)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let projection = try await service.enroll(householdID: household)
        let result = try await service.shopperPreview(shopID: shopID, requestID: requestID,
            base: .init(shopRevision: 7, authorityEpoch: 3, requestRevision: 2),
            decision: .add(line: .init(originalItem: "Cereal", packs: 1, unitPriceMinor: 349, feeEligible: true), promote: false))
        XCTAssertEqual(result.after.totalMinor, 4069); XCTAssertEqual(result.after.overCapMinor, 269); XCTAssertTrue(result.requiresOverageAcceptance)
        let previewBody = try XCTUnwrap(JSONSerialization.jsonObject(with: previews[0]) as? [String: Any])
        XCTAssertEqual((previewBody["base"] as? [String: Int])?["shopRevision"], 7)
        XCTAssertEqual((previewBody["decision"] as? [String: Any])?["choice"] as? String, "add")
        let operation = try await service.prepare(envelope: .init(replayWindow: UUID().uuidString, shopId: shopID, kind: "request.apply", base: result.base,
            body: ["requestId": .string(requestID), "previewId": .string(result.previewId), "acceptOverage": .bool(true), "acceptUnknown": .bool(false)]), bootstrap: projection)
        for _ in 0..<2 { do { _ = try await service.executeShopper(operation); XCTFail("Expected lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) } }
        XCTAssertEqual(commands, [operation.bytes, operation.bytes])
        role = "contributor"
        do { _ = try await service.executeShopper(operation); XCTFail("Old shopper retried after transfer") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(commands.count, 2)
    }
    func testShopperDecisionsEncodeOnlyDocumentedDiscriminatedFields() throws {
        for decision in [ShopperDecision.deferRequest, .dismiss, .handled] {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(decision)) as? [String: String])
            XCTAssertEqual(value, ["choice": decision.choice])
        }
        let line = UUID().uuidString.lowercased()
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(ShopperDecision.link(lineID: line, promote: true))) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["choice", "lineId", "promote"]))
        XCTAssertEqual(value["lineId"] as? String, line); XCTAssertEqual(value["promote"] as? Bool, true)
    }
}

extension HouseholdClientTests {
    func testCarryUsesBothReviewedShopsAndRejectsSubstitutedPagesOrReceipts() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                      auth: auth, deviceVault: MemoryVault(), transport: transport())
        let sourceShop = UUID().uuidString.lowercased()
        var rowShop = sourceShop, echoedRequest = requestID, role = "shopper"
        var posts: [Data] = []
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") {
                var scope = try XCTUnwrap(JSONSerialization.jsonObject(with: self.bootstrapBytes(role: role)) as? [String: Any])
                scope["capabilities"] = ["shopper_inbox", "request_preview", "shopper_commands", "deferred_requests"]
                return (200, try JSONSerialization.data(withJSONObject: scope))
            }
            if path.hasSuffix("/deferred-requests") {
                let row: [String:Any] = ["requestId":self.requestID, "sourceShopId":rowShop, "sourceAuthorityEpoch":2,
                    "requestRevision":4, "originalItem":"School coffee", "ownQuantity":"one bag", "authorAlias":"Ana",
                    "authoredAt":"2026-11-01T12:00:00Z", "receivedAt":"2026-11-01T12:00:01Z"]
                return (200, try JSONSerialization.data(withJSONObject:["shopId":self.shopID, "shopRevision":3,
                    "authorityEpoch":5, "requests":[row], "nextCursor":NSNull()]))
            }
            XCTAssertTrue(path.hasSuffix("/commands"))
            posts.append(self.requestBytes(request))
            let receipt: [String:Any] = ["operationId":self.previewID, "kind":"request.carry", "shopId":self.shopID,
                "shopRevision":3, "authorityEpoch":5, "disposition":"recorded", "sourceRequestId":echoedRequest,
                "requestId":self.previewID, "requestRevision":1]
            return (200, try JSONSerialization.data(withJSONObject:receipt))
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456")
        let scope = try await service.enroll(householdID:household)
        let page = try await service.deferredRequests(shopID:shopID)
        let row = try XCTUnwrap(page.requests.first)
        XCTAssertEqual(row.sourceShopId.uuidString.lowercased(), sourceShop)
        let envelope = CommandEnvelope(replayWindow:UUID().uuidString, shopId:shopID, kind:"request.carry",
            base:.init(shopRevision:page.shopRevision, authorityEpoch:page.authorityEpoch,requestRevision:row.requestRevision),
            body:["sourceShopId":.string(sourceShop),"sourceAuthorityEpoch":.integer(row.sourceAuthorityEpoch),"requestId":.string(requestID)])
        let operation = try await service.prepare(envelope:envelope, bootstrap:scope)
        XCTAssertFalse(operation.targetsShop(nil))
        rowShop = shopID
        do { _ = try await service.deferredRequests(shopID:shopID); XCTFail("A draft supplied its own row as a previous request") }
        catch ClientError.invalidResponse {}
        echoedRequest = UUID().uuidString.lowercased()
        do { _ = try await service.executeShopper(operation); XCTFail("A receipt named a different source request") }
        catch ClientError.invalidResponse {}
        echoedRequest = requestID
        let receipt = try await service.executeShopper(operation)
        XCTAssertEqual(receipt.requestId,previewID)
        XCTAssertEqual(posts,[operation.bytes,operation.bytes])
        role = "contributor"
        do { _ = try await service.executeShopper(operation); XCTFail("Former shopper replayed") }
        catch ClientError.accessEnded {}
        XCTAssertEqual(posts.count,2)
    }
    func testPurchaseRetryValidatesDeviceScopeCapabilityAndExactReceipt() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                      auth: auth, deviceVault: MemoryVault(), transport: transport())
        let line = UUID().uuidString.lowercased()
        var role = "shopper", capability = true, reply = "loss"
        var posts: [Data] = []
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") {
                var scope = try XCTUnwrap(JSONSerialization.jsonObject(with: self.bootstrapBytes(role: role)) as? [String: Any])
                if capability { scope["capabilities"] = ["shopper_inbox", "request_preview", "shopper_commands", "request_purchase_confirmation"] }
                return (200, try JSONSerialization.data(withJSONObject: scope))
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/commands"))
            posts.append(self.requestBytes(request))
            if reply == "loss" { throw URLError(.networkConnectionLost) }
            let receipt: [String: Any] = ["operationId": self.previewID, "kind": "request.confirmPurchase", "shopId": self.shopID,
                "shopRevision": 7, "authorityEpoch": 3, "requestId": self.requestID, "requestRevision": 3,
                "disposition": "recorded", "purchaseOutcome": reply]
            return (200, try JSONSerialization.data(withJSONObject: receipt))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let scope = try await service.enroll(householdID: household)
        let operation = try await service.prepare(envelope: .init(replayWindow: UUID().uuidString, shopId: shopID,
            kind: "request.confirmPurchase", base: .init(shopRevision: 7, authorityEpoch: 3, requestRevision: 2),
            body: ["requestId": .string(requestID), "lineId": .string(line), "placedRevision": .integer(5), "outcome": .string("bought")]),
            bootstrap: scope)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shopper.json")
        try await OperationOutbox(url: file).append(operation)
        do { _ = try await service.executeShopper(operation); XCTFail("Expected initial delivery loss") }
        catch { XCTAssertEqual(error as? ClientError, .transport) }
        let saved = try await OperationOutbox(url: file).operations()
        let restored = try XCTUnwrap(saved.first)
        XCTAssertEqual(restored, operation)
        XCTAssertFalse(restored.targetsShop(nil))
        XCTAssertFalse(restored.targetsShop(UUID().uuidString))
        reply = "notBought"
        do { _ = try await service.executeShopper(restored); XCTFail("A different outcome was accepted") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        reply = "bought"
        let receipt = try await service.executeShopper(restored)
        XCTAssertEqual(receipt.purchaseOutcome, reply)
        capability = false
        do { _ = try await service.executeShopper(restored); XCTFail("Missing purchase capability") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        role = "contributor"; capability = true
        do { _ = try await service.executeShopper(restored); XCTFail("Transferred shopper could replay") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(posts, [operation.bytes, operation.bytes, operation.bytes])
    }

    func testOwnPurchaseReadbackAcceptsOnlyRecordedOutcomesAndRejectsPrivateLinks() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                      auth: auth, deviceVault: MemoryVault(), transport: transport())
        var outcome: String?, privateLink = false
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") { return (200, self.bootstrapBytes(role: "contributor")) }
            XCTAssertTrue(request.url!.path.hasSuffix("/requests/mine"))
            var row: [String: Any] = ["requestId": self.requestID, "shopId": self.shopID, "revision": 2, "originalItem": "Lunch fruit",
                "ownQuantity": "a bag", "authoredAt": "2026-11-07T09:00:00Z", "receivedAt": "2026-11-07T09:01:00Z",
                "status": "added", "route": "current", "ownActionAllowed": false]
            row["purchaseOutcome"] = outcome
            if privateLink { row["linkedLineId"] = self.previewID }
            return (200, try JSONSerialization.data(withJSONObject: ["requests": [row]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        for known: ConfirmedRequestPurchase? in [nil, .bought, .notBought] {
            outcome = known?.rawValue
            let page = try await service.ownRequests()
            XCTAssertEqual(page.requests.count, 1)
            XCTAssertEqual(page.requests[0].purchaseOutcome, known)
            XCTAssertEqual(page.requests[0].status, "added")
        }
        privateLink = true
        do { _ = try await service.ownRequests(); XCTFail("Own view accepted a private link") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }
}

extension HouseholdClientTests {
    func testPurchaseMatchRequiresTheReviewedPlacedLineAndCurrentAuthorityEvenAfterClose() throws {
        let line = UUID()
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 300, capScope: "wholeCheckout",
                                     fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0,
                                     observedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        func shop(_ phase: String = "placed") -> ShopperShop {
            .init(shopId: shopID, shopRevision: 8, authorityEpoch: 3, phase: phase, meals: nil, quote: quote,
                  lines: [], frozenRevision: 6, placedRevision: 6)
        }
        func request(_ status: String = "added") throws -> OwnRequest {
            let fields: [String: Any] = ["requestId": requestID, "shopId": shopID, "revision": 2, "originalItem": "Cereal",
                "ownQuantity": "one box", "authoredAt": "2026-11-07T09:00:00Z", "receivedAt": "2026-11-07T09:01:00Z",
                "authorAlias": "Jo", "status": status, "route": "current", "ownActionAllowed": false,
                "linkedLineId": line.uuidString]
            return try JSONDecoder().decode(OwnRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        func placed(_ changes: [String: Any] = [:]) throws -> SharedDeliveryPage {
            let fields: [String: Any] = ["shopId": shopID, "shopRevision": 8, "placedRevision": 6, "authorityEpoch": 3,
                "supplyRevision": 0, "sources": [], "lines": [["lineId": line.uuidString, "name": "Original line"]]]
            return try JSONDecoder().decode(SharedDeliveryPage.self, from: JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new }))
        }
        let own = try request(), snapshot = try placed()
        for phase in ["placed", "closed"] {
            let match = try XCTUnwrap(RequestPurchaseMatch(request: own, shop: shop(phase), placed: snapshot))
            XCTAssertEqual(match.line.name, "Original line")
            XCTAssertNil(match.line.packs, "A legacy sealed line carries no ordered pack count")
            XCTAssertEqual(match.base, .init(shopRevision: 8, authorityEpoch: 3, requestRevision: 2))
            XCTAssertEqual(match.body(outcome: nil)["outcome"], .string("unknown"))
        }
        for changed: [String: Any] in [["shopId": UUID().uuidString], ["shopRevision": 7],
                                         ["placedRevision": 5], ["authorityEpoch": 4],
                                         ["lines": [["lineId": UUID().uuidString, "name": "Cereal"]]], ["lines": []]] {
            XCTAssertNil(RequestPurchaseMatch(request: own, shop: shop(), placed: try placed(changed)))
        }
        XCTAssertNil(RequestPurchaseMatch(request: try request("handled"), shop: shop(), placed: snapshot))
        XCTAssertNil(RequestPurchaseMatch(request: own, shop: shop("draft"), placed: snapshot))
    }
}
