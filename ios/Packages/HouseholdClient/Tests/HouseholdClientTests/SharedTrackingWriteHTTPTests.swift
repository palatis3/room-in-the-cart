import XCTest
@testable import HouseholdClient

private func trackingBody(_ request: URLRequest) -> Data {
    if let bytes = request.httpBody { return bytes }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(contentsOf: buffer.prefix(n)) }
    return result
}

extension HouseholdClientTests {
    func testTrackingWriteHTTPAllModesCancelAcknowledgementAndDurableLostReply() async throws {
        typealias F = TrackingWriteFixture
        for mode in ["adopt", "change", "review", "firstAdoptionUndo", "rebind", "recover", "request"] {
            let f = try F.scenario(mode), page: SharedTrackingPage = try F.decode(f["page"]!), intent = try F.intent(f)
            let auth = try auth(), vault = MemoryVault(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
            var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
            var commands: [Data] = [], windows = 0, previews = 0, commits = 0, reads = 0
            MockURLProtocol.handler = { request in
                if let response = self.authResponse(request) { return response }
                let path = request.url!.path
                if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
                if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": page.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
                if path.hasSuffix("/replay-windows") { windows += 1; return (200, try F.bytes(["id": F.id(80), "expiresAt": "2099-01-01T00:00:00Z"])) }
                if path.hasSuffix("/demand/tracking") { reads += 1; return (200, try F.bytes(f["page"]!)) }
                if path.hasSuffix("/demand/tracking/operations") { return (200, try F.bytes(["schemaVersion": 2, "shopId": page.shopId.string, "shopRevision": page.shopRevision, "items": []])) }
                if path.hasSuffix("/demand/tracking/candidates") {
                    XCTAssertEqual(try F.decode(JSONSerialization.jsonObject(with: trackingBody(request)), as: JSONValue.self), try JSONDecoder().decode(JSONValue.self, from: encoded(intent)))
                    return (200, try F.bytes(f["candidate"]!))
                }
                if path.hasSuffix("/demand/tracking/previews") {
                    previews += 1
                    let sent = try JSONSerialization.jsonObject(with: trackingBody(request)) as! [String: Any]
                    XCTAssertEqual(Set(sent.keys), ["candidateId", "candidateDigest", "acknowledgedDisclosure"])
                    XCTAssertEqual(try F.decode(sent["acknowledgedDisclosure"]!, as: JSONValue.self), try F.decode((f["candidate"] as! [String: Any])["disclosure"]!, as: JSONValue.self))
                    return (200, try F.bytes(f["preview"]!))
                }
                guard path.hasSuffix("/commands") else { throw ClientError.configuration }
                commands.append(trackingBody(request))
                if commands.count == 1 { commits += 1; throw URLError(.networkConnectionLost) }
                var receipt: [String: Any] = ["operationId": F.id(95), "kind": mode == "request" ? "request.apply" : "shop.patch", "shopId": page.shopId.string, "shopRevision": page.shopRevision + 1, "authorityEpoch": page.authorityEpoch, "disposition": mode == "request" ? "added" : "patched"]
                if mode == "request" { receipt["requestId"] = F.id(90); receipt["requestRevision"] = 7 }
                return (200, try F.bytes(receipt))
            }
            _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
            let read = try await service.sharedTracking(shopID: page.shopId.uuid)
            XCTAssertEqual(read, page)
            _ = try await service.sharedTrackingHistory(page: read)
            let candidate = try await service.sharedTrackingCandidate(page: page, kind: intent.kind, requestPreview: intent.requestPreview)
            XCTAssertEqual(windows, 0); XCTAssertEqual(previews, 0); XCTAssertTrue(commands.isEmpty)
            // Dropping this candidate is Cancel: no command/outbox/window is created.
            let accepted = try await service.acceptSharedTrackingCandidate(candidate)
            XCTAssertTrue(commands.isEmpty); XCTAssertEqual(windows, 0)
            let operation = try await service.prepareSharedTrackingApply(accepted)
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
            XCTAssertEqual(envelope.body["demandReview"], .object(["previewId": .string(F.id(61)), "previewDigest": .string(String(repeating: "c", count: 64)), "trackingVersion": .integer(2)]))
            XCTAssertEqual(envelope.base.requestRevision, mode == "request" ? 6 : nil)
            XCTAssertEqual(operation.sharedTrackingBinding?.targetOperationID?.string, mode == "firstAdoptionUndo" ? F.id(90) : nil)
            XCTAssertNil(operation.sharedDemandBinding)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("outbox.json"), outbox = OperationOutbox(url: url)
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Lost reply must remain pending") } catch { XCTAssertEqual(error as? ClientError, .transport) }
            let persisted = try await OperationOutbox(url: url).operations()
            XCTAssertEqual(persisted, [operation]); XCTAssertEqual(persisted.first?.bytes, operation.bytes)
            let readsBeforeRetry = reads
            service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport()); _ = try await service.enroll(householdID: household)
            _ = try await service.sendSharedTracking(try XCTUnwrap(persisted.first), outbox: outbox)
            XCTAssertEqual(commands, [operation.bytes, operation.bytes]); XCTAssertEqual(commits, 1)
            XCTAssertEqual(windows, 1); XCTAssertEqual(previews, 1); XCTAssertEqual(reads, readsBeforeRetry)
            let left = try await outbox.operations(); XCTAssertTrue(left.isEmpty)
        }
    }
    func testTrackingWriteHTTPPartialFreezeUsesAcceptedFreezeTokenNotApplyPreview() async throws {
        typealias F = TrackingWriteFixture
        let p = try F.page(F.fixture()), auth = try auth(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        var commands: [Data] = []
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": p.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/demand/tracking") { return (200, try F.bytes(F.fixture())) }
            if path.hasSuffix("/replay-windows") { return (200, try F.bytes(["id": F.id(80), "expiresAt": "2099-01-01T00:00:00Z"])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            commands.append(trackingBody(request))
            return (200, try F.bytes(["operationId": F.id(95), "kind": "shop.freeze", "shopId": p.shopId.string, "shopRevision": 9, "authorityEpoch": 3, "disposition": "frozen"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let operation = try await service.prepareSharedTrackingFreeze(page: p)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        XCTAssertEqual(envelope.body, ["trackingReview": .object(["previewId": .string(F.id(60)), "previewDigest": .string(String(repeating: "c", count: 64)), "trackingVersion": .integer(2)])])
        _ = try await service.executeSharedShop(operation) // Generic dispatch cannot drop the v2 binding.
        XCTAssertEqual(commands.count, 1)
        let unbound = try PendingOperation(envelope: envelope, householdID: household, memberID: member, deviceID: "device")
        do { _ = try await service.executeSharedShop(unbound); XCTFail("Unbound v2 freeze reached HTTP") } catch {}
        XCTAssertEqual(commands.count, 1)
    }
}

extension HouseholdClientTests {
    func testTrackingWriteHTTPStaleReadTamperRevocationPrivacyAndBadReceipt() async throws {
        typealias F = TrackingWriteFixture
        let f = try F.scenario(), page: SharedTrackingPage = try F.decode(f["page"]!), intent = try F.intent(f)
        let auth = try auth(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        var currentPage: Any = f["page"]!, deny = false, commandError: String?, wrongReceipt = false, commands = 0, windows = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": deny ? "contributor" : "shopper", "shopId": page.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/demand/tracking") { return (200, try F.bytes(currentPage)) }
            if path.hasSuffix("/demand/tracking/candidates") { return (200, try F.bytes(f["candidate"]!)) }
            if path.hasSuffix("/demand/tracking/previews") { return (200, try F.bytes(f["preview"]!)) }
            if path.hasSuffix("/replay-windows") { windows += 1; return (200, try F.bytes(["id": F.id(80), "expiresAt": "2099-01-01T00:00:00Z"])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            commands += 1
            if let commandError { return (409, try F.bytes(["error": ["code": commandError]])) }
            return (200, try F.bytes(["operationId": F.id(95), "kind": "shop.patch", "shopId": page.shopId.string, "shopRevision": wrongReceipt ? 10 : 9, "authorityEpoch": 3, "disposition": "patched"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let candidate = try await service.sharedTrackingCandidate(page: page, kind: intent.kind)
        let accepted = try await service.acceptSharedTrackingCandidate(candidate)
        currentPage = F.edit(currentPage, "state.privacyRevision", 6)
        do { _ = try await service.prepareSharedTrackingApply(accepted); XCTFail("Stale privacy read prepared") } catch {}
        XCTAssertEqual(windows, 0); XCTAssertEqual(commands, 0)
        currentPage = f["page"]!
        let operation = try await service.prepareSharedTrackingApply(accepted)
        var object = try JSONSerialization.jsonObject(with: encoded(operation)) as! [String: Any]
        let envelope = try JSONSerialization.jsonObject(with: operation.bytes)
        object["bytes"] = try F.bytes(F.edit(envelope, "body.demandReview.trackingVersion", 1)).base64EncodedString()
        let tampered: PendingOperation = try F.decode(object)
        do { _ = try await service.executeSharedTracking(tampered); XCTFail("Changed durable token reached HTTP") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        XCTAssertEqual(commands, 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = OperationOutbox(url: directory.appendingPathComponent("outbox.json"))
        let unrelated = try PendingOperation(envelope: .init(replayWindow: F.id(80), shopId: F.id(2), kind: "shop.freeze", base: .init(shopRevision: 8, authorityEpoch: 3), body: [:]), householdID: F.id(99), memberID: member, deviceID: "device")
        try await outbox.append(unrelated)
        deny = true
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Revoked shopper sent command") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(commands, 0)
        var pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated])
        deny = false; commandError = "tracking_replay_unavailable"
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Erased source retry accepted") } catch {}
        pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated])
        commandError = "tracking_store_permission"
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Revoked store source retry accepted") } catch {}
        pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated])
        commandError = "tracking_stale_state"
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Stale command accepted") } catch {}
        pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated, operation])
        commandError = nil; wrongReceipt = true
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Wrong receipt removed pending command") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated, operation])
        XCTAssertEqual(windows, 1)
        wrongReceipt = false
        _ = try await service.sendSharedTracking(operation, outbox: outbox)
        pending = try await outbox.operations(); XCTAssertEqual(pending, [unrelated])
    }
    func testTrackingWriteHTTPHeldCandidateAndOversizedReadCannotCrossScope() async throws {
        typealias F = TrackingWriteFixture
        let f = try F.scenario(), p: SharedTrackingPage = try F.decode(f["page"]!), intent = try F.intent(f)
        let auth = try auth(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        var oversized = true
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": p.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/demand/tracking") { return (200, oversized ? Data(repeating: 32, count: 1_800_001) : try F.bytes(f["page"]!)) }
            return (200, try F.bytes(f["candidate"]!))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        do { _ = try await service.sharedTracking(shopID: p.shopId.uuid); XCTFail("Oversized read accepted") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        oversized = false
        let held = HeldResponse(), arrived = expectation(description: "held tracking candidate")
        MockURLProtocol.intercept = { request in
            if request.request.url?.path.hasSuffix("/tracking/candidates") == true { held.set(request); arrived.fulfill(); return true }; return false
        }
        let task = Task { try await service.sharedTrackingCandidate(page: p, kind: intent.kind) }
        await fulfillment(of: [arrived], timeout: 2)
        await service.clearScope()
        held.finish(status: 200, data: try F.bytes(f["candidate"]!))
        do { _ = try await task.value; XCTFail("Old candidate survived cleared scope") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
    }
}
