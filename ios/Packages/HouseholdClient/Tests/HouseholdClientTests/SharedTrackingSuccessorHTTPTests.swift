import Foundation
import XCTest
@testable import HouseholdClient

private func successorBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}

extension HouseholdClientTests {
    func testTrackingCandidateChangedRetiresOnlyProvenUncommittedRowAndCommittedReplayStaysExact() async throws {
        typealias F = TrackingWriteFixture
        let operation = try F.pending(), unrelated = try F.pending(), auth = try auth()
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let service = HouseholdService(configuration: config, auth: auth, deviceVault: MemoryVault(), transport: transport())
        var committed = false, code = "tracking_candidate_changed", events: [String] = [], posted: [Data] = []
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            posted.append(successorBody(request)); events.append("lookupExactOperation")
            // Matches repository.execute: immutable receipt replay precedes
            // preview lookup/recompute. The client never fabricates this proof.
            if committed { events.append("returnReceipt"); return (200, try F.bytes(["operationId": F.id(95), "kind": "shop.patch", "shopId": F.id(2), "shopRevision": 9, "authorityEpoch": 3, "disposition": "patched"])) }
            events.append("recomputeUncommittedCandidate")
            return (409, try F.bytes(["error": ["code": code]]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = OperationOutbox(url: dir.appendingPathComponent("outbox.json"))
        try await outbox.append(unrelated)
        do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Stale monetary proof accepted") } catch {}
        var rows = try await outbox.operations(); XCTAssertEqual(rows, [unrelated])
        XCTAssertEqual(events, ["lookupExactOperation", "recomputeUncommittedCandidate"])
        for ambiguous in ["refresh_required", "stale_base", "tracking_stale_state"] {
            code = ambiguous
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Conflict accepted") } catch {}
            rows = try await outbox.operations(); XCTAssertEqual(rows, [unrelated, operation]); XCTAssertEqual(rows.last?.bytes, operation.bytes)
        }
        committed = true; events = []
        _ = try await service.sendSharedTracking(operation, outbox: outbox)
        rows = try await outbox.operations(); XCTAssertEqual(rows, [unrelated])
        XCTAssertEqual(events, ["lookupExactOperation", "returnReceipt"])
        XCTAssertTrue(posted.allSatisfy { $0 == operation.bytes })
    }
    func testTrackingMoneyAcknowledgmentEchoCannotGrantUnselectedConsent() async throws {
        typealias F = TrackingWriteFixture
        let fixture = try F.scenario(), review = try F.candidateReview(fixture), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var previews = 0, grantExtra = true
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            guard path.hasSuffix("/demand/tracking/previews") else { throw ClientError.configuration }
            previews += 1
            let input = try JSONSerialization.jsonObject(with: successorBody(request)) as! [String: Any]
            XCTAssertEqual(input["acceptUnknown"] as? Bool, true); XCTAssertEqual(input["acceptOverage"] as? Bool, false)
            return (200, try F.bytes(grantExtra ? F.edit(fixture["preview"]!, "moneyAcknowledgments.acceptOverage", true) : fixture["preview"]!))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        do { _ = try await service.acceptSharedTrackingCandidate(review); XCTFail("Unknown accepted without choice") } catch {}
        XCTAssertEqual(previews, 0)
        do { _ = try await service.acceptSharedTrackingCandidate(review, acceptUnknown: true); XCTFail("Server changed consent") } catch {}
        grantExtra = false
        let result = try await service.acceptSharedTrackingCandidate(review, acceptUnknown: true)
        XCTAssertEqual(result.preview.moneyAcknowledgments, .init(acceptOverage: false, acceptUnknown: true)); XCTAssertEqual(previews, 2)
    }
    func testRequestUndoHTTPWholeReviewReservedReceiptAndDurableExactRetry() async throws {
        typealias F = RequestUndoFixture
        let auth = try auth(), vault = MemoryVault(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        let shop = try F.shop(), raw = F.candidate("partition"), rawPreview = try F.preview(raw)
        var posted: [Data] = [], commits = 0, reads = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/requests/operations") { return (200, try F.bytes(["schemaVersion": 1, "shopId": F.id(2), "shopRevision": 8, "authorityEpoch": 3, "items": [["operationId": F.id(90), "kind": "request.apply", "shopRevision": 7, "committedAt": "2026-11-10T12:00:00Z", "eligibility": ["status": "reviewable", "reason": "explicit_current_preview_required"]]], "nextBeforeRevision": NSNull()])) }
            if path.hasSuffix("/requests/operation-undo-candidates") { reads += 1; return (200, try F.bytes(raw)) }
            if path.hasSuffix("/requests/operation-undo-previews") { reads += 1; return (200, try F.bytes(rawPreview)) }
            if path.hasSuffix("/shops/\(F.id(2))") { return (200, try encoded(shop)) }
            if path.hasSuffix("/replay-windows") { return (200, try F.bytes(["id": F.id(80), "expiresAt": "2099-01-01T00:00:00Z"])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            posted.append(successorBody(request))
            if posted.count == 1 { commits += 1; throw URLError(.networkConnectionLost) }
            return (200, try F.bytes(["operationId": F.id(95), "kind": "request.undoAcceptance", "shopId": F.id(2), "shopRevision": 9, "authorityEpoch": 3, "disposition": "acceptanceUndone", "requestId": F.id(20), "requestRevision": 5]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let history = try await service.requestAcceptanceHistory(shop: shop); XCTAssertEqual(history.items.count, 1)
        let candidate = try await service.requestAcceptanceUndoCandidate(shop: shop, targetOperationID: .init(UUID(uuidString: F.id(90))!))
        XCTAssertTrue(posted.isEmpty)
        let review = try await service.previewRequestAcceptanceUndo(shop: shop, candidate: candidate, packs: F.packs(), acceptOverage: false, acceptUnknown: false)
        let operation = try await service.prepareRequestAcceptanceUndo(review)
        XCTAssertEqual(operation.sharedRequestUndoBinding?.reservedOperationID.string, F.id(95))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("outbox.json"), outbox = OperationOutbox(url: url)
        do { _ = try await service.sendRequestAcceptanceUndo(operation, outbox: outbox); XCTFail("Lost receipt accepted") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let rows = try await OperationOutbox(url: url).operations(); XCTAssertEqual(rows, [operation])
        service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport()); _ = try await service.enroll(householdID: household)
        _ = try await service.sendRequestAcceptanceUndo(try XCTUnwrap(rows.first), outbox: outbox)
        XCTAssertEqual(posted, [operation.bytes, operation.bytes]); XCTAssertEqual(commits, 1); XCTAssertEqual(reads, 2)
        let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
    }
}

private actor HeldRequestUndoOutbox: SharedTrackingOutbox {
    enum Point { case append, cleanup }
    let store: OperationOutbox
    let point: Point
    let arrived: @Sendable () -> Void
    var continuation: CheckedContinuation<Void, Never>?
    var held = false
    init(store: OperationOutbox, point: Point, arrived: @escaping @Sendable () -> Void) { self.store = store; self.point = point; self.arrived = arrived }
    func pause(_ requested: Point) async {
        guard requested == point, !held else { return }; held = true
        await withCheckedContinuation { continuation in self.continuation = continuation; arrived() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func operations() async throws -> [PendingOperation] { try await store.operations() }
    func append(_ operation: PendingOperation) async throws { await pause(.append); try await store.append(operation) }
    func remove(_ id: String) async throws { try await store.remove(id) }
    func removeIfUnchanged(_ rows: [PendingOperation]) async throws { await pause(.cleanup); try await store.removeIfUnchanged(rows) }
}
extension RequestUndoFixture {
    static func pending() throws -> PendingOperation {
        let review = try review(), response = review.response
        let binding = SharedRequestUndoOperationBinding(context: review.context, shopID: review.candidate.shopId, targetOperationID: review.candidate.targetOperationId,
            reservedOperationID: response.operationId, previewID: response.previewId, previewDigest: response.previewDigest,
            base: .init(shopRevision: 8, authorityEpoch: 3, requestRevision: 4), action: response.candidate.action)
        return try PendingOperation(envelope: .init(replayWindow: id(80), shopId: id(2), kind: "request.undoAcceptance", base: binding.base, body: binding.body()),
            householdID: review.context.householdID, memberID: review.context.memberID, deviceID: review.context.deviceID, sharedRequestUndoBinding: binding)
    }
}
extension HouseholdClientTests {
    func testRequestUndoHeldAppendDoesNotEnterReenrolledSessionAndFreshRetryWorks() async throws {
        try await exerciseRequestUndoLease(.append)
    }
    func testRequestUndoHTTP401HeldCleanupPreservesNewSessionRows() async throws {
        try await exerciseRequestUndoLease(.cleanup)
    }
    private func exerciseRequestUndoLease(_ point: HeldRequestUndoOutbox.Point) async throws {
        typealias F = RequestUndoFixture
        let operation = try F.pending(), auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var deny = point == .cleanup, commands = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }; commands += 1
            if deny { return (401, try F.bytes(["error": ["code": "session_needed"]])) }
            return (200, try F.bytes(["operationId": F.id(95), "kind": "request.undoAcceptance", "shopId": F.id(2), "shopRevision": 9, "authorityEpoch": 3, "disposition": "acceptanceUndone", "requestId": F.id(20), "requestRevision": 5]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationOutbox(url: directory.appendingPathComponent("outbox.json")), arrived = expectation(description: "request Undo storage lease")
        let held = HeldRequestUndoOutbox(store: store, point: point, arrived: { arrived.fulfill() })
        let original = Task { try await service.sendRequestAcceptanceUndo(operation, outbox: held) }
        await fulfillment(of: [arrived], timeout: 2)
        if point == .append { XCTAssertEqual(commands, 0); await service.clearScope() }
        deny = false; _ = try await service.enroll(householdID: household)
        let newOperation = try F.pending(); try await store.append(newOperation)
        await held.release()
        do { _ = try await original.value; XCTFail("Old invocation crossed lease") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        var rows = try await store.operations(); XCTAssertTrue(rows.contains(newOperation))
        if point == .append {
            XCTAssertEqual(commands, 0); XCTAssertTrue(rows.contains(operation))
            _ = try await service.sendRequestAcceptanceUndo(operation, outbox: store)
            rows = try await store.operations(); XCTAssertEqual(rows, [newOperation])
        } else { XCTAssertEqual(rows, [newOperation]); XCTAssertEqual(commands, 1) }
    }
}
