import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var lifecycleGrant: String { "00000000-0000-4000-8000-000000000021" }
    private var lifecycleShop: String { "00000000-0000-4000-8000-000000000022" }
    private func helperBootstrap() -> Data {
        Data("{\"household\":{\"id\":\"\(household)\",\"label\":\"Home\"},\"memberId\":\"\(member)\",\"role\":\"editor\",\"shopId\":\"\(lifecycleShop)\",\"grantId\":\"\(lifecycleGrant)\",\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[\"helper_view\",\"helper_propose\"]}".utf8)
    }
    private func helperViewBytes() -> Data {
        Data("{\"grantId\":\"\(lifecycleGrant)\",\"shopId\":\"\(lifecycleShop)\",\"revision\":2,\"asOf\":\"2026-11-03T00:00:00Z\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"mode\":\"edit\",\"canPropose\":true,\"shopLabel\":\"Tuesday pickup\",\"language\":\"en\",\"items\":[{\"label\":\"Wraps\",\"amount\":\"6\",\"unit\":null,\"action\":\"Save two for lunch.\"}]}".utf8)
    }
    private func lifecycleBytes(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    func testMembershipCreationRetriesExactIntentAndRejectsWrongAccount() async throws {
        let auth = try auth(); var bodies: [Data] = []
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            XCTAssertEqual(request.url!.path, "/v1/households"); XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Token"))
            bodies.append(self.lifecycleBytes(request))
            return (201, Data("{\"householdId\":\"\(self.household)\",\"memberId\":\"\(self.member)\",\"role\":\"organizer\"}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let intent = try MembershipIntent.create(subject: "account", label: "Our home", alias: "Mia", adultAttestation: true)
        let first = try await service.executeMembership(intent); let second = try await service.executeMembership(intent)
        XCTAssertEqual(first, second); XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["clientKey", "label", "alias", "adultAttestation"]))
        XCTAssertEqual(value["adultAttestation"] as? Bool, true)
        let other = try MembershipIntent.create(subject: "other-account", label: "Other", alias: "Other", adultAttestation: true)
        do { _ = try await service.executeMembership(other); XCTFail("Wrong account replay") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(bodies.count, 2)
    }
    func testInvitationRedemptionSendsTokenOnlyInBodyAndRequiresAdultDeclaration() async throws {
        let token = household + "." + String(repeating: "a", count: 43)
        XCTAssertThrowsError(try MembershipIntent.redeem(subject: "account", token: token, alias: nil, adultAttestation: false))
        XCTAssertThrowsError(try MembershipIntent.create(subject: "account", label: "Home", alias: "Mia", adultAttestation: false))
        let intent = try MembershipIntent.redeem(subject: "account", token: token, alias: nil, adultAttestation: true)
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            XCTAssertEqual(request.url!.absoluteString, "https://service.test/v1/invites/redeem")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.lifecycleBytes(request)) as? [String: Any])
            XCTAssertEqual(body["token"] as? String, token); XCTAssertEqual(body["intent"] as? String, "join"); XCTAssertNil(body["alias"])
            return (200, Data("{\"householdId\":\"\(self.household)\",\"memberId\":\"\(self.member)\",\"role\":\"editor\",\"grantId\":\"\(self.lifecycleGrant)\"}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let receipt = try await service.executeMembership(intent); XCTAssertEqual(receipt.grantId, lifecycleGrant)
    }
    func testNativeHelperBindingSurvivesResumeAndNeverFetchesBroadRoutes() async throws {
        let auth = try auth(); let vault = MemoryVault(); var registrations = 0; var broadCalls = 0
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { registrations += 1; return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-View-Grant-ID"), self.lifecycleGrant)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Household-ID"), self.household)
            if request.url!.path.hasSuffix("/bootstrap") { return (200, self.helperBootstrap()) }
            if request.url!.path == "/v1/views/\(self.lifecycleGrant)/current" { return (200, self.helperViewBytes()) }
            broadCalls += 1; return (500, Data())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        _ = try await service.enroll(householdID: household, grantID: lifecycleGrant)
        _ = try await service.currentHelperView(grantID: lifecycleGrant)
        do { _ = try await service.ownRequests(); XCTFail("Helper fetched contributor requests") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.currentDeviceToken(householdID: household, memberID: member); XCTFail("Helper exposed unscoped device credential") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.currentHelperView(grantID: UUID().uuidString); XCTFail("Helper switched grant") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        let recreated = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        let scope = try await recreated.enroll(householdID: household)
        XCTAssertEqual(scope.grantId, lifecycleGrant); XCTAssertEqual(registrations, 1); XCTAssertEqual(broadCalls, 0)
    }
    func testHelperRejectsServerIgnoringSelectedGrant() async throws {
        let auth = try auth(); let vault = MemoryVault()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: vault, transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            return (200, Data("{\"household\":{\"id\":\"\(self.household)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"shopper\",\"shopId\":\"\(self.lifecycleShop)\",\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[\"shopper_commands\"]}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        do { _ = try await service.enroll(householdID: household, grantID: lifecycleGrant); XCTFail("Broader fallback accepted") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertNil(try vault.read())
    }
    func testHelperProposalRetriesExactBytesAndStopsAfterRevocation() async throws {
        let auth = try auth(); var bodies: [Data] = []; var revoked = false
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") { return (200, self.helperBootstrap()) }
            if revoked { return (404, Data()) }
            if request.url!.path.hasSuffix("/current") { return (200, self.helperViewBytes()) }
            bodies.append(self.lifecycleBytes(request)); throw URLError(.networkConnectionLost)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household, grantID: lifecycleGrant)
        let intent = try await service.prepareHelperProposal(grantID: lifecycleGrant, baseRevision: 2, correction: "Keep three wraps for lunch.")
        for _ in 0..<2 { do { _ = try await service.executeHelperProposal(intent); XCTFail("Expected lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) } }
        XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        revoked = true
        do { _ = try await service.executeHelperProposal(intent); XCTFail("Revoked suggestion replay") } catch {}
        XCTAssertEqual(bodies.count, 2)
    }
    func testNullableWireFieldsAreExplicitAndHelperProjectionHasNoPrivateKeys() throws {
        let projection = try HelperProjection(shopLabel: "Pickup", language: "es", items: [.init(label: "Tortillas", amount: nil, unit: nil, action: "Guardar dos.")])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(projection)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["shopLabel", "language", "items"]))
        let item = try XCTUnwrap((value["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), Set(["label", "amount", "unit", "action"]))
        XCTAssertTrue(item["amount"] is NSNull); XCTAssertTrue(item["unit"] is NSNull)
        let line = ShopperBasketLine(originalItem: "Rice", packs: 1, unitPriceMinor: nil, feeEligible: true)
        let lineValue = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(line)) as? [String: Any])
        XCTAssertTrue(lineValue["unitPriceMinor"] is NSNull)
    }
    func testLifecycleStoreRetainsFixedMembershipBytesAcrossRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lifecycle.json")
        let intent = try MembershipIntent.create(subject: "account", label: "Home", alias: "Mia", adultAttestation: true)
        try await LifecycleIntentStore(url: url).save(.init(membership: intent))
        let restored = try await LifecycleIntentStore(url: url).read()
        XCTAssertEqual(restored.membership, intent)
        try await LifecycleIntentStore(url: url).purge()
        let purged = try await LifecycleIntentStore(url: url).read(); XCTAssertNil(purged.membership)
    }
}

extension HouseholdClientTests {
    func testShopperSuggestionPagesStayBoundToGrantAndCursor() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
            auth: auth, deviceVault: MemoryVault(), transport: transport())
        let cursor = UUID().uuidString
        var wrongGrant = false
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"token"}"#.utf8)) }
            if url.path.hasSuffix("/bootstrap") {
                return (200, try JSONSerialization.data(withJSONObject: ["household":["id":self.household,"label":"Home"],
                    "memberId":self.member,"role":"shopper","shopId":self.lifecycleShop,"enrolled":true,"queueConsent":false,"capabilities":["shopper_commands"]]))
            }
            XCTAssertTrue(url.path.hasSuffix("/views/\(self.lifecycleGrant)/proposals"))
            XCTAssertEqual(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems, [URLQueryItem(name:"cursor",value:cursor)])
            let row: [String:Any] = ["proposalId":UUID().uuidString,"grantId":wrongGrant ? self.lifecycleShop : self.lifecycleGrant,
                "baseRevision":2,"correction":"Two portions","status":"dismissed","createdAt":"2026-01-01T00:00:00Z"]
            // A legacy server can omit the final cursor.
            return (200, try JSONSerialization.data(withJSONObject:["proposals":[row]]))
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID:household)
        let page = try await service.helperProposals(grantID:lifecycleGrant,cursor:cursor)
        XCTAssertEqual(page.proposals.first?.status,"dismissed"); XCTAssertNil(page.nextCursor)
        wrongGrant = true
        do { _ = try await service.helperProposals(grantID:lifecycleGrant,cursor:cursor); XCTFail("Accepted another grant") }
        catch { XCTAssertEqual(error as? ClientError,.invalidResponse) }
    }
}
