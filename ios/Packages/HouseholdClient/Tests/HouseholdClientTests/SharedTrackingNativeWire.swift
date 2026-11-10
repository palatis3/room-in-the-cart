import Security
import XCTest
@testable import HouseholdClient

private final class TrackingLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Private fixture-only enrollment storage to exercise actual process restart.
private final class TrackingWireVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private let url: URL
    init(url: URL) { self.url = url }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return FileManager.default.fileExists(atPath:url.path) ? try String(contentsOf:url,encoding:.utf8) : nil }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; try Data(value.utf8).write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
    func clear() throws { lock.lock(); defer { lock.unlock() }; if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
private struct TrackingWireInput: Decodable {
    let phase, householdId: String
    let shopId: UUID
    let before: SharedTrackingPage?
    let action: SharedDemandAction?
    let change: SharedDemandChange?
    let packs: [SharedDemandPackReview]
    let targetOperationId: SharedDemandID?
    let requestId: UUID?
    let requestRevision: Int?
    let line: SharedDemandLine?
    let survivor: SharedDemandContribution?
}
private struct TrackingApplyToken: Encodable { let previewId, previewDigest: String; let trackingVersion = 2 }
private func saveTrackingWire<T: Encodable>(_ value: T, _ url: URL) throws {
    try encoded(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

extension SharedMealNativeWireTests {
    func exerciseTrackingWire() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = try JSONDecoder().decode(TrackingWireInput.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_TRACKING_FIXTURE"]))))
        XCTAssertEqual(input.phase, env["RITC_WIRE_TRACKING_PHASE"])
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try XCTUnwrap(env["RITC_WIRE_PORT"]))"))
        let cert = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration: .ephemeral, delegate: TrackingLoopbackTrust(certificate: cert), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session: session)
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_tracking_fixture"), vault: MemoryVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "wire@example.invalid", code: XCTUnwrap(env["RITC_WIRE_CODE"]))
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(env["RITC_WIRE_TRACKING_STATE"]), isDirectory: true)
        let vault = TrackingWireVault(url: stateURL.appendingPathComponent(try XCTUnwrap(env["RITC_WIRE_TRACKING_VAULT"]) + ".json"))
        let service = HouseholdService(configuration: try ServiceConfiguration(baseURL: base), auth: auth, deviceVault: vault, transport: transport)
        _ = try await service.enroll(householdID: input.householdId)
        let selected = try await service.selectShop(input.shopId)
        let outbox = OperationOutbox(url: stateURL.appendingPathComponent("tracking-pending.json"))
        let confirmedURL = stateURL.appendingPathComponent("tracking-confirmed.json")
        let expectedGraphURL = stateURL.appendingPathComponent("tracking-expected-graph.json")
        let acceptedTokenURL = stateURL.appendingPathComponent("tracking-apply-token.json")
        if input.phase == "revoked" {
            XCTAssertNotEqual(selected.role, "shopper")
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            do { _ = try await service.sharedTracking(shopID: input.shopId); XCTFail("Old shopper read private tracking after transfer") }
            catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Old shopper replayed tracking command") }
            catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
            let pending = try await outbox.operations()
            XCTAssertFalse(pending.contains { $0.sharedTrackingBinding?.shopID.uuid == input.shopId })
            do { let _: ShopperReceipt = try await service.perform("commands", method: "POST", body: operation.bytes); XCTFail("Server accepted old shopper replay") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 404) }
            return
        }
        let page = try await service.sharedTracking(shopID: input.shopId)
        XCTAssertEqual(page, input.before)
        if let survivor = input.survivor {
            XCTAssertEqual(page.graph.contributions.first { $0.id == survivor.id }, input.phase == "privacy-adopt" ? nil : survivor)
        }
        if input.phase == "adopt-retry" {
            let operations = try await outbox.operations(); XCTAssertEqual(operations.count, 1)
            let operation = try XCTUnwrap(operations.first)
            let original = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            XCTAssertEqual(operation, original); XCTAssertEqual(operation.bytes, original.bytes)
            let graph = try JSONDecoder().decode(SharedDemandGraph.self, from: Data(contentsOf: expectedGraphURL))
            XCTAssertEqual(page.graph, graph)
            let receipt = try await service.sendSharedTracking(operation, outbox: outbox)
            XCTAssertEqual(receipt.shopRevision, page.shopRevision)
            let after = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(after, page)
            let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
            return
        }
        if input.phase == "freeze-place" {
            XCTAssertEqual(page.coverage?.status, .partial)
            XCTAssertEqual(page.coverage?.completeFoodCoverage, false)
            let freeze = try await service.prepareSharedTrackingFreeze(page: page)
            let applyToken = try JSONSerialization.jsonObject(with: Data(contentsOf: acceptedTokenURL))
            var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: freeze.bytes) as? [String: Any])
            invalid["clientKey"] = UUID().uuidString.lowercased(); invalid["body"] = ["trackingReview": applyToken]
            do { let _: ShopperReceipt = try await service.perform("commands", method: "POST", body: JSONSerialization.data(withJSONObject: invalid)); XCTFail("Apply token authorized freeze") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 409) }
            let unchanged = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(unchanged, page)
            _ = try await service.sendSharedTracking(freeze, outbox: outbox)
            let frozen = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
            XCTAssertEqual(frozen.phase, "frozen"); XCTAssertEqual(frozen.shopRevision, page.shopRevision + 1)
            let prepared = try await service.preparePlacementSnapshot(reviewed: frozen)
            let receipt = try await service.executePlacementReport(try .init(prepared: prepared, occurredAt: ISO8601DateFormatter().string(from: Date())))
            XCTAssertEqual(receipt.disposition, "placed")
            let placed = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
            XCTAssertEqual(placed.phase, "placed"); XCTAssertEqual(placed.lines, frozen.lines); XCTAssertEqual(placed.quote, frozen.quote)
            let after = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(after.state?.unbound, page.state?.unbound)
            return
        }
        if input.phase == "recover" {
            XCTAssertEqual(page.status, .reviewRequired)
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Erased lineage replayed old tracking success") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 409) }
            // A retained conflict is not invented proof of session revocation.
            let unchanged = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(unchanged, page)
        }
        let kind: SharedTrackingIntentKind
        var requestPreview: ShopperPreview?
        switch input.phase {
        case "adopt-cancel", "adopt-lost", "privacy-adopt":
            XCTAssertEqual(page.status, .legacy)
            kind = .adopt(action: try XCTUnwrap(input.action), change: try XCTUnwrap(input.change), packs: input.packs)
        case "first-undo":
            let history = try await service.sharedTrackingHistory(page: page)
            XCTAssertTrue(history.items.contains { $0.operationId == input.targetOperationId && $0.status == .current_preview_required })
            kind = .firstAdoptionUndo(targetOperationId: try XCTUnwrap(input.targetOperationId), packs: input.packs)
        case "rebind":
            let current = try XCTUnwrap(page.state), line = try XCTUnwrap(input.line)
            XCTAssertEqual(page.coverage?.status, .partial)
            XCTAssertTrue(current.unbound.contains { $0.transferred?.source.isReservation == true && $0.transferred?.quantity == nil })
            let basket = try XCTUnwrap(current.basket.first { $0.id == line.id })
            let pack = SharedDemandPackReview(lineId: line.id, usablePerPack: .init(amount: try .init(numerator: 6), unit: .count, originalLiteral: "6 wraps"), acceptUnresolved: true)
            kind = .rebind(bindings: current.unbound.map { .init(factId: $0.factId, line: line, basket: basket, packReview: pack) })
        case "recover": kind = .recover(packs: input.packs)
        case "request":
            let requestId = try XCTUnwrap(input.requestId), revision = try XCTUnwrap(input.requestRevision), line = try XCTUnwrap(input.line)
            let preview = try await service.shopperPreview(shopID: input.shopId.uuidString.lowercased(), requestID: requestId.uuidString.lowercased(),
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, requestRevision: revision), decision: .link(lineID: line.id.string, promote: false))
            XCTAssertEqual(preview.requestRevision, 2); XCTAssertEqual(preview.requestRevision, revision)
            requestPreview = preview
            kind = .change(action: .request(.init(requestId: .init(requestId), previewId: .init(try XCTUnwrap(UUID(uuidString: preview.previewId))), acceptOverage: false, acceptUnknown: false)),
                change: try XCTUnwrap(input.change), packs: input.packs, unboundFactIds: try XCTUnwrap(page.state).unbound.map(\.factId))
        default: return XCTFail("Unexpected tracking wire selector")
        }
        let candidate = try await service.sharedTrackingCandidate(page: page, kind: kind, requestPreview: requestPreview)
        XCTAssertEqual(candidate.page, page)
        // Complete typed disclosure is acknowledged by the production method.
        let accepted = try await service.acceptSharedTrackingCandidate(candidate)
        XCTAssertEqual(accepted.preview.disclosure, candidate.candidate.disclosure)
        XCTAssertEqual(accepted.preview.action, candidate.candidate.action)
        let cancelled = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(cancelled, page)
        if input.phase == "adopt-cancel" { return }
        let operation = try await service.prepareSharedTrackingApply(accepted)
        XCTAssertEqual(operation.sharedTrackingBinding?.base.requestRevision, requestPreview?.requestRevision)
        try saveTrackingWire(operation, confirmedURL)
        try saveTrackingWire(candidate.candidate.after.graph, expectedGraphURL)
        try saveTrackingWire(TrackingApplyToken(previewId: accepted.preview.previewId.string, previewDigest: accepted.preview.previewDigest.value), acceptedTokenURL)
        if input.phase == "adopt-lost" {
            var failed = false
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox) } catch { failed = true }
            XCTAssertTrue(failed, "Real successful command reply was deliberately dropped")
            let pending = try await outbox.operations(); XCTAssertEqual(pending, [operation]); XCTAssertEqual(pending.first?.bytes, operation.bytes)
            return
        }
        let receipt = try await service.sendSharedTracking(operation, outbox: outbox)
        XCTAssertEqual(receipt.shopRevision, page.shopRevision + 1)
        let after = try await service.sharedTracking(shopID: input.shopId)
        XCTAssertEqual(after.state, candidate.candidate.after)
        if let survivor = input.survivor { XCTAssertEqual(after.graph.contributions.first { $0.id == survivor.id }, survivor) }
        if input.phase == "first-undo" {
            XCTAssertEqual(after.coverage?.status, .partial); XCTAssertEqual(after.coverage?.completeFoodCoverage, false)
            XCTAssertEqual(after.coverage?.allocatableUnboundFactIds, [])
            XCTAssertTrue(try XCTUnwrap(after.state).unbound.contains { $0.transferred?.source.isReservation == true && $0.transferred?.quantity == nil })
            XCTAssertEqual(Set(after.graph.usedIds), Set(page.graph.usedIds))
        }
        if input.phase == "rebind" {
            XCTAssertTrue(try XCTUnwrap(after.state).unbound.isEmpty)
            for transferred in try XCTUnwrap(page.state).unbound.compactMap(\.transferred) {
                XCTAssertEqual(after.graph.contributions.first { $0.id == transferred.id }, transferred)
            }
        }
        if input.phase == "request" { XCTAssertEqual(after.state?.unbound, page.state?.unbound) }
    }
}
