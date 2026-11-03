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
