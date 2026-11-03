import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var managementDevice: String { "10000000-0000-4000-8000-000000000001" }
    private var managementTarget: String { "10000000-0000-4000-8000-000000000002" }
    private func deviceRow(id: String? = nil, current: Bool = false, kind: String = "adult", revoked: String? = nil) throws -> ManagedHouseholdDevice {
        try JSONDecoder().decode(ManagedHouseholdDevice.self, from: JSONSerialization.data(withJSONObject: [
            "deviceId": id ?? managementTarget, "memberId": member, "memberAlias": "Reviewed alias", "memberKind": kind,
            "createdAt": "2026-11-03T10:00:00.000Z", "revokedAt": revoked as Any? ?? NSNull(), "isCurrentDevice": current]))
    }
    private func managementSetup(_ request: URLRequest, role: String = "organizer", grantID: String? = nil) throws -> (Int, Data)? {
        if let response = authResponse(request) { return response }
        if request.url!.path.hasSuffix("/devices"), request.httpMethod == "POST" {
            return (200, try JSONSerialization.data(withJSONObject: ["deviceId": managementDevice, "deviceToken": "private-device-credential"]))
        }
        if request.url!.path.hasSuffix("/bootstrap") {
            var value: [String: Any] = ["household": ["id": household, "label": "Our home"], "memberId": member,
                "role": role, "enrolled": true, "queueConsent": false, "capabilities": role == "organizer" ? ["household_admin"] : []]
            if let grantID { value["grantId"] = grantID; value["shopId"] = managementTarget; value["capabilities"] = ["helper_view", "helper_propose"] }
            return (200, try JSONSerialization.data(withJSONObject: value))
        }
        return nil
    }
    private func managementBytes(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
        return bytes
    }
    func testDeviceInventoryUsesEnrolledHeadersAndValidatesCurrentReferenceAndGuardianScope() async throws {
        let auth = try auth(), service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var wrongCurrent = false, guardianScope = false
        MockURLProtocol.handler = { req in
            if let value = try self.managementSetup(req) { return value }
            XCTAssertEqual(req.url!.path, "/v1/households/\(self.household)/devices")
            XCTAssertEqual(req.httpMethod, "GET"); XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Token"), "private-device-credential")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Household-ID"), self.household); XCTAssertNil(req.value(forHTTPHeaderField: "X-View-Grant-ID"))
            let row = try self.deviceRow(id: self.managementDevice, current: !wrongCurrent)
            return (200, try JSONSerialization.data(withJSONObject: ["scope": guardianScope ? "guardian_children" : "household", "devices": [JSONSerialization.jsonObject(with: encoded(row))], "nextCursor": NSNull()]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let page = try await service.managedDevices(); XCTAssertEqual(page.devices.first?.id, managementDevice)
        wrongCurrent = true
        do { _ = try await service.managedDevices(); XCTFail("Accepted incorrect current-device flag") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        wrongCurrent = false; guardianScope = true
        do { _ = try await service.managedDevices(); XCTFail("Guardian inventory included adult/current enrollment") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }
    func testDeviceRevocationRetainsExactTargetBytesAndRejectsReceiptSubstitution() async throws {
        let auth = try auth(), service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var bodies: [Data] = [], lost = true, wrongReceipt = false
        MockURLProtocol.handler = { req in
            if let value = try self.managementSetup(req) { return value }
            XCTAssertEqual(req.url!.path, "/v1/households/\(self.household)/devices/\(self.managementTarget)/revocation")
            bodies.append(self.managementBytes(req)); if lost { throw URLError(.networkConnectionLost) }
            return (200, try JSONSerialization.data(withJSONObject: ["deviceId": wrongReceipt ? self.managementDevice : self.managementTarget,
                "memberId": self.member, "revoked": true, "revokedAt": "2026-11-03T12:00:00.000Z"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let intent = try await service.prepareDeviceRevocation(deviceRow())
        for _ in 0..<2 { do { _ = try await service.executeDeviceRevocation(intent); XCTFail() } catch { XCTAssertEqual(error as? ClientError, .transport) } }
        XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.bytes) as? [String: String]); XCTAssertEqual(input, ["memberId": member])
        lost = false; wrongReceipt = true
        do { _ = try await service.executeDeviceRevocation(intent); XCTFail("Accepted another device receipt") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        wrongReceipt = false; _ = try await service.executeDeviceRevocation(intent)
        XCTAssertTrue(bodies.allSatisfy { $0 == intent.bytes })
        await service.clearScope()
        do { _ = try await service.executeDeviceRevocation(intent); XCTFail("Rebound action after access ended") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(bodies.count, 4)
    }
    func testDeviceRevocationRejectsCurrentDeviceRevokedTargetAndTamperedStoredIntent() throws {
        let binding = GuardianActorBinding(subject: "account", householdID: household, memberID: member, deviceID: managementDevice)
        XCTAssertThrowsError(try DeviceRevocationIntent(binding: binding, device: deviceRow(id: managementDevice, current: true)))
        XCTAssertThrowsError(try DeviceRevocationIntent(binding: binding, device: deviceRow(revoked: "2026-11-03T12:00:00Z")))
        let intent = try DeviceRevocationIntent(binding: binding, device: deviceRow())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(intent)) as? [String: Any]); raw["targetMemberID"] = managementTarget
        let changed = try JSONDecoder().decode(DeviceRevocationIntent.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try changed.validate())
    }
    func testScopedHelperCannotUseDeviceManagementAndRevokedSessionClearsEnrollment() async throws {
        let auth = try auth(), vault = MemoryVault(), service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: vault, transport: transport())
        let grant = "10000000-0000-4000-8000-000000000003"; var managementCalls = 0, helper = true
        MockURLProtocol.handler = { req in
            if let value = try self.managementSetup(req, role: helper ? "editor" : "organizer", grantID: helper ? grant : nil) { return value }
            managementCalls += 1; return (403, Data(#"{"error":{"code":"access_ended"}}"#.utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household, grantID: grant)
        do { _ = try await service.managedDevices(); XCTFail() } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(managementCalls, 0)
        await service.clearScope(); helper = false; _ = try await service.enroll(householdID: household)
        do { _ = try await service.managedDevices(); XCTFail() } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(managementCalls, 1); XCTAssertNil(try vault.read())
    }
    func testDeviceIntentStorePreservesExactRetryAndScopedPurgeInvalidatesStaleEpoch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("device-revocation.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DeviceRevocationStore(url: url), binding = GuardianActorBinding(subject: "account", householdID: household, memberID: member, deviceID: managementDevice)
        let intent = try DeviceRevocationIntent(binding: binding, device: deviceRow()), epoch = await store.epoch()
        try await store.save(intent, epoch: epoch)
        let restored = try await DeviceRevocationStore(url: url).read(); XCTAssertEqual(restored, intent)
        try await store.purge(householdID: managementTarget, subject: "account")
        let retained = try await store.read(); XCTAssertEqual(retained, intent)
        do { try await store.save(intent, epoch: epoch); XCTFail("Stale writer survived purge") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        try await store.purge(householdID: household, subject: "account")
        let empty = try await store.read(); XCTAssertNil(empty)
    }
}
