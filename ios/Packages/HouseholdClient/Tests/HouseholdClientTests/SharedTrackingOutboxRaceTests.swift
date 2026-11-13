import os
import XCTest
@testable import HouseholdClient

/// Holds the actual storage boundary; no wall-clock sleeps or network timing
/// guesses. Production still uses the original atomic file-backed actor.
private actor HeldTrackingOutbox: SharedTrackingOutbox {
    enum Point { case append, remove, cleanup }
    private let store: OperationOutbox
    private let point: Point
    private let arrived: @Sendable () -> Void
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(store: OperationOutbox, point: Point, arrived: @escaping @Sendable () -> Void) {
        self.store = store; self.point = point; self.arrived = arrived
    }
    private func pause(_ point: Point) async {
        guard self.point == point, !held else { return }
        held = true
        await withCheckedContinuation { continuation in self.continuation = continuation; arrived() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func operations() async throws -> [PendingOperation] { try await store.operations() }
    func append(_ operation: PendingOperation) async throws { await pause(.append); try await store.append(operation) }
    func remove(_ id: String) async throws { await pause(.remove); try await store.remove(id) }
    func removeIfUnchanged(_ expected: [PendingOperation]) async throws {
        await pause(.cleanup)
        try await store.removeIfUnchanged(expected)
    }
}

extension TrackingWriteFixture {
    static func pending(shopID: String = id(2)) throws -> PendingOperation {
        let accepted = try accepted(scenario()), read = accepted.candidateReview.intent.base
        let binding = SharedTrackingOperationBinding(kind: .apply, mode: "review", context: context,
            shopID: SharedDemandID(UUID(uuidString: shopID)!), base: .init(shopRevision: 8, authorityEpoch: 3), graphRevision: 4,
            privacyRevision: read.privacyRevision, stateDigest: accepted.preview.disclosure.pickup.stateDigest.value,
            previewID: accepted.preview.previewId, previewDigest: accepted.preview.previewDigest.value, action: accepted.preview.action, targetOperationID: nil)
        let envelope = CommandEnvelope(replayWindow: id(80), shopId: shopID, kind: "shop.patch", base: binding.base, body: try binding.body())
        let operation = try PendingOperation(envelope: envelope, householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID, sharedTrackingBinding: binding)
        try binding.validate(operation); return operation
    }
    static func legacyPending(shopID: String = id(2)) throws -> PendingOperation {
        try PendingOperation(envelope: .init(replayWindow: id(80), shopId: shopID, kind: "shop.freeze", base: .init(shopRevision: 8, authorityEpoch: 3), body: [:]), householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID)
    }
}

extension HouseholdClientTests {
    func testTrackingWriteHeldAppendCannotEnterSameIdentityNewSessionButFreshRetryWorks() async throws {
        try await exerciseTrackingHeldOutbox(.append)
    }
    func testTrackingWriteHeldRemoveCannotReportSuccessAcrossSameIdentityNewSession() async throws {
        try await exerciseTrackingHeldOutbox(.remove)
    }
    private func exerciseTrackingHeldOutbox(_ point: HeldTrackingOutbox.Point) async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), auth = try auth(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        let posted = OSAllocatedUnfairLock(initialState: [Data]())
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            let body = trackingRaceBody(request)
            posted.withLock { $0.append(body) }
            return (200, try F.bytes(["operationId": F.id(95), "kind": "shop.patch", "shopId": F.id(2), "shopRevision": 9, "authorityEpoch": 3, "disposition": "patched"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let oldGeneration = await service.generation, oldContext = try await service.sharedDemandContext(shopID: UUID(uuidString: F.id(2))!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json")), arrived = expectation(description: "held outbox storage")
        let held = HeldTrackingOutbox(store: store, point: point, arrived: { arrived.fulfill() })
        let original = Task { try await service.sendSharedTracking(operation, outbox: held) }
        await fulfillment(of: [arrived], timeout: 2)
        await service.clearScope(); _ = try await service.enroll(householdID: household)
        let newGeneration = await service.generation, newContext = try await service.sharedDemandContext(shopID: UUID(uuidString: F.id(2))!)
        XCTAssertNotEqual(oldGeneration, newGeneration); XCTAssertEqual(oldContext, newContext)
        await held.release()
        do { _ = try await original.value; XCTFail("Old invocation survived outbox suspension") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        XCTAssertEqual(posted.withLock { $0.count }, point == .append ? 0 : 1)
        var saved = try await store.operations(); XCTAssertEqual(saved, point == .append ? [operation] : [])
        // Explicit retry is a new invocation, retaining the same exact command.
        _ = try await service.sendSharedTracking(operation, outbox: held)
        let bodies = posted.withLock { $0 }
        XCTAssertEqual(bodies.count, point == .append ? 1 : 2)
        XCTAssertTrue(bodies.allSatisfy { $0 == operation.bytes })
        saved = try await store.operations(); XCTAssertTrue(saved.isEmpty)
    }
    func testTrackingWrite404ConfirmsAssignmentLossBeforeScopedPurgeAndPreservesMissingResource() async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), sameShop = try F.pending(), otherShop = try F.pending(shopID: F.id(98)), legacy = try F.legacyPending()
        let auth = try auth(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        struct AssignmentState: Sendable {
            var assigned = true
            var loseOnPost = false
            var commands = 0
            var bootstraps = 0
        }
        let state = OSAllocatedUnfairLock(initialState: AssignmentState())
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") {
                let assigned = state.withLock { fixture in
                    fixture.bootstraps += 1
                    return fixture.assigned
                }
                return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": assigned ? "shopper" : "contributor", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": assigned ? ["shopper_inbox", "request_preview", "shopper_commands"] : ["own_requests"]]))
            }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            state.withLock { fixture in
                fixture.commands += 1
                if fixture.loseOnPost { fixture.assigned = false }
            }
            return (404, try F.bytes(["error": ["code": "unavailable"]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json"))
        for pending in [sameShop, otherShop, legacy] { try await store.append(pending) }
        let beforeBootstrap = state.withLock { $0.bootstraps }
        do { _ = try await service.sendSharedTracking(operation, outbox: store); XCTFail("Expected resource 404") } catch { XCTAssertEqual(error as? ClientError, .service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)) }
        var saved = try await store.operations()
        XCTAssertEqual(saved, [sameShop, otherShop, legacy, operation])
        XCTAssertEqual(state.withLock { $0.bootstraps } - beforeBootstrap, 2)
        let beforeLoss = state.withLock { fixture in
            fixture.loseOnPost = true
            return fixture.bootstraps
        }
        do { _ = try await service.sendSharedTracking(operation, outbox: store); XCTFail("Assignment loss accepted") } catch { XCTAssertEqual(error as? ClientError, .service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)) }
        saved = try await store.operations()
        let final = state.withLock { $0 }
        XCTAssertEqual(saved, [otherShop, legacy])
        XCTAssertEqual(final.bootstraps - beforeLoss, 2)
        XCTAssertEqual(final.commands, 2)
    }
    func testTrackingWriteTerminalPreviewErasureRemovesExactRowButAmbiguousRefreshRetains() async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), unrelated = try F.pending(), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let code = OSAllocatedUnfairLock(initialState: "refresh_required")
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            return (409, try F.bytes(["error": ["code": code.withLock { $0 }]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json")); try await store.append(unrelated)
        do { _ = try await service.sendSharedTracking(operation, outbox: store); XCTFail("Expected refresh") } catch {}
        var saved = try await store.operations(); XCTAssertEqual(saved, [unrelated, operation])
        code.withLock { $0 = "tracking_preview_expired" }
        do { _ = try await service.sendSharedTracking(operation, outbox: store); XCTFail("Expired/erased preview accepted") } catch {}
        saved = try await store.operations(); XCTAssertEqual(saved, [unrelated])
    }
    func testTrackingWriteLegacyOutboxWithoutBindingLoadsAndSurvivesTrackingScopePurge() async throws {
        typealias F = TrackingWriteFixture
        let legacy = try F.legacyPending(), tracking = try F.pending()
        var wire = try JSONSerialization.jsonObject(with: encoded(legacy)) as! [String: Any]
        wire.removeValue(forKey: "sharedTrackingBinding"); wire.removeValue(forKey: "sharedDemandBinding")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("outbox.json")
        try F.bytes([wire]).write(to: url)
        let store = OperationOutbox(url: url)
        var saved = try await store.operations(); XCTAssertEqual(saved, [legacy]); XCTAssertNil(saved[0].sharedTrackingBinding)
        try await store.append(tracking)
        try await store.removeIfUnchanged([tracking])
        saved = try await store.operations(); XCTAssertEqual(saved, [legacy]); XCTAssertEqual(saved[0].bytes, legacy.bytes)
    }
}

private func trackingRaceBody(_ request: URLRequest) -> Data {
    if let bytes = request.httpBody { return bytes }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
    return bytes
}

extension HouseholdClientTests {
    func testTrackingWriteHeldScopePurgePreservesNewUnrelatedRowsAndCancelsOldResult() async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let assigned = OSAllocatedUnfairLock(initialState: true)
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": assigned.withLock { $0 } ? "shopper" : "contributor", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            assigned.withLock { $0 = false }
            return (404, try F.bytes(["error": ["code": "unavailable"]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json")), arrived = expectation(description: "held confirmed shop purge")
        let held = HeldTrackingOutbox(store: store, point: .cleanup, arrived: { arrived.fulfill() })
        let original = Task { try await service.sendSharedTracking(operation, outbox: held) }
        await fulfillment(of: [arrived], timeout: 2)
        await service.clearScope()
        assigned.withLock { $0 = true }
        _ = try await service.enroll(householdID: household)
        let newOtherShop = try F.pending(shopID: F.id(98)), newSameShop = try F.pending(), newIndependentLegacy = try F.legacyPending()
        try await store.append(newOtherShop); try await store.append(newSameShop); try await store.append(newIndependentLegacy)
        await held.release()
        do { _ = try await original.value; XCTFail("Old cleanup result survived new session") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        let saved = try await store.operations(); XCTAssertEqual(saved, [newOtherShop, newSameShop, newIndependentLegacy])
    }
    func testTrackingWriteHeld404ReauthorizationCannotPurgeAfterReenrollment() async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), unrelated = try F.pending(), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let rechecking = OSAllocatedUnfairLock(initialState: false)
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            rechecking.withLock { $0 = true }
            return (404, try F.bytes(["error": ["code": "unavailable"]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json")); try await store.append(unrelated)
        let held = HeldResponse(), arrived = expectation(description: "held fresh assignment proof")
        MockURLProtocol.intercept = { request in
            guard request.request.url?.path.hasSuffix("/bootstrap") == true else { return false }
            let shouldHold = rechecking.withLock { pending in
                let wasPending = pending
                pending = false
                return wasPending
            }
            guard shouldHold else { return false }
            held.set(request)
            arrived.fulfill()
            return true
        }
        let original = Task { try await service.sendSharedTracking(operation, outbox: store) }
        await fulfillment(of: [arrived], timeout: 2)
        await service.clearScope(); _ = try await service.enroll(householdID: household)
        held.finish(status: 200, data: try F.bytes(["household": ["id": household, "label": "Home"], "memberId": member, "role": "contributor", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["own_requests"]]))
        do { _ = try await original.value; XCTFail("Old assignment proof admitted cleanup") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        let saved = try await store.operations(); XCTAssertEqual(saved, [unrelated, operation])
    }
}

extension HouseholdClientTests {
    func testTrackingWriteActual401ClearsServiceAndRemovesOnlyOriginalMemberSnapshot() async throws {
        try await exerciseTrackingServerInvalidation(status: 401, holdCleanup: false)
    }
    func testTrackingWriteActual403MembershipLossClearsServiceAndPurgesProtectedSnapshot() async throws {
        try await exerciseTrackingServerInvalidation(status: 403, holdCleanup: false)
    }
    func testTrackingWriteHeld401CleanupPreservesNewSameShopSessionWork() async throws {
        try await exerciseTrackingServerInvalidation(status: 401, holdCleanup: true)
    }
    private func exerciseTrackingServerInvalidation(status: Int, holdCleanup: Bool) async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), oldPeer = try F.pending(), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let unrelated = try PendingOperation(envelope: .init(replayWindow: F.id(80), shopId: F.id(2), kind: "shop.freeze", base: .init(shopRevision: 8, authorityEpoch: 3), body: [:]), householdID: F.id(99), memberID: member, deviceID: "device")
        let commands = OSAllocatedUnfairLock(initialState: 0)
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            commands.withLock { $0 += 1 }
            return (status, try F.bytes(["error": ["code": status == 401 ? "session_needed" : "access_ended"]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let oldGeneration = await service.generation
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OperationOutbox(url: dir.appendingPathComponent("outbox.json"))
        try await store.append(oldPeer); try await store.append(unrelated)
        if holdCleanup {
            let arrived = expectation(description: "held proven HTTP invalidation cleanup")
            let held = HeldTrackingOutbox(store: store, point: .cleanup, arrived: { arrived.fulfill() })
            let original = Task { try await service.sendSharedTracking(operation, outbox: held) }
            await fulfillment(of: [arrived], timeout: 2)
            let clearedGeneration = await service.generation; XCTAssertNotEqual(clearedGeneration, oldGeneration)
            do { _ = try await service.sharedDemandContext(shopID: UUID(uuidString: F.id(2))!); XCTFail("Server denial did not clear scope") } catch {}
            _ = try await service.enroll(householdID: household)
            let freshSameShop = try F.pending(), freshOtherShop = try F.pending(shopID: F.id(98))
            try await store.append(freshSameShop); try await store.append(freshOtherShop)
            await held.release()
            do { _ = try await original.value; XCTFail("Old denied invocation survived new session") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
            let saved = try await store.operations(); XCTAssertEqual(saved, [unrelated, freshSameShop, freshOtherShop])
        } else {
            do { _ = try await service.sendSharedTracking(operation, outbox: store); XCTFail("Server denial was accepted") } catch { XCTAssertEqual(error as? ClientError, status == 401 ? .sessionNeeded : .accessEnded) }
            let clearedGeneration = await service.generation; XCTAssertNotEqual(clearedGeneration, oldGeneration)
            do { _ = try await service.sharedDemandContext(shopID: UUID(uuidString: F.id(2))!); XCTFail("Server denial did not clear scope") } catch {}
            let saved = try await store.operations(); XCTAssertEqual(saved, [unrelated])
        }
        XCTAssertEqual(commands.withLock { $0 }, 1)
    }
    func testTrackingWriteCompareBeforeRemovalRetainsChangedBytesUnderSameKey() async throws {
        typealias F = TrackingWriteFixture
        let observed = try F.pending()
        var changed = try JSONSerialization.jsonObject(with: encoded(observed)) as! [String: Any]
        changed["bytes"] = Data("changed independently".utf8).base64EncodedString()
        let changedRow: PendingOperation = try F.decode(changed)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("outbox.json"); try encoded([changedRow]).write(to: url)
        let store = OperationOutbox(url: url)
        try await store.removeIfUnchanged([observed])
        let saved = try await store.operations(); XCTAssertEqual(saved, [changedRow])
    }
}
