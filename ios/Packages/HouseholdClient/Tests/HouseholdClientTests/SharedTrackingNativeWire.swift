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
private struct TrackingWireTransferredInput: Decodable {
    let factId: SharedDemandID
    let after: SharedDemandContribution?
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
    let originalQuantityText: String?
    let acceptOverage: Bool?
    let unboundFactIds: [SharedDemandID]?
    let transferredChanges: [TrackingWireTransferredInput]?
    let expectedMealCatalog: SharedTrackingMealSources?
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
        if input.phase.hasPrefix("partial-") {
            try await exercisePartialTrackingWire(input, service: service, page: page, stateURL: stateURL)
            return
        }
        if input.phase.hasPrefix("request-undo-") && !["request-undo-accept", "request-undo-reaccept"].contains(input.phase) {
            try await exerciseRequestUndoWire(input, service: service, page: page, stateURL: stateURL)
            return
        }
        if input.phase == "compound-undo-retry" {
            let rows = try await outbox.operations(), operation = try XCTUnwrap(rows.first)
            XCTAssertEqual(rows.count, 1)
            let saved = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            XCTAssertEqual(operation, saved); XCTAssertEqual(operation.bytes, saved.bytes)
            let receipt = try await service.sendSharedTracking(operation, outbox: outbox)
            XCTAssertEqual(receipt.shopRevision, operation.sharedTrackingBinding!.base.shopRevision + 1)
            let unchanged = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(unchanged, page)
            let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
            return
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
        var actionSources: SharedTrackingActionSources?
        switch input.phase {
        case "adopt-cancel", "adopt-lost", "privacy-adopt", "compound-adopt":
            XCTAssertEqual(page.status, .legacy)
            let action = try XCTUnwrap(input.action)
            if input.phase == "compound-adopt" { actionSources = try await service.sharedTrackingActionSources(page: page, action: action) }
            kind = .adopt(action: action, change: try XCTUnwrap(input.change), packs: input.packs)
        case "first-undo", "compound-undo-cancel", "compound-undo-lost":
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
        case "request", "request-undo-accept", "request-undo-reaccept":
            let requestId = try XCTUnwrap(input.requestId), revision = try XCTUnwrap(input.requestRevision), line = try XCTUnwrap(input.line)
            let preview = try await service.shopperPreview(shopID: input.shopId.uuidString.lowercased(), requestID: requestId.uuidString.lowercased(),
                base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, requestRevision: revision), decision: .link(lineID: line.id.string, promote: false))
            if input.phase == "request" { XCTAssertEqual(preview.requestRevision, 2) }; XCTAssertEqual(preview.requestRevision, revision)
            requestPreview = preview
            kind = .change(action: .request(.init(requestId: .init(requestId), previewId: .init(try XCTUnwrap(UUID(uuidString: preview.previewId))), acceptOverage: false, acceptUnknown: false)),
                change: try XCTUnwrap(input.change), packs: input.packs, unboundFactIds: try XCTUnwrap(page.state).unbound.map(\.factId))
        default: return XCTFail("Unexpected tracking wire selector")
        }
        let candidate = try await service.sharedTrackingCandidate(page: page, kind: kind, requestPreview: requestPreview, actionSources: actionSources)
        XCTAssertEqual(candidate.page, page)
        // These wire fixtures deliberately review unknown pickup cost/coverage.
        // Explicit unknown consent is separate from echoing the full disclosure;
        // no over-cap consent is granted by this fixture.
        let overage = input.acceptOverage ?? false
        if input.phase.hasPrefix("compound-undo-") {
            XCTAssertEqual(candidate.candidate.disclosure.money.after.status, "overCap")
            guard case .compoundAdoptionUndo(let disclosure) = candidate.candidate.disclosure.changes else { return XCTFail("Compound inverse disclosure missing") }
            XCTAssertNotNil(disclosure.mealUndo)
            do { _ = try await service.acceptSharedTrackingCandidate(candidate, acceptUnknown: true); XCTFail("Over-cap inverse accepted without explicit choice") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
        let accepted = try await service.acceptSharedTrackingCandidate(candidate, acceptOverage: overage, acceptUnknown: true)
        XCTAssertEqual(accepted.preview.moneyAcknowledgments, .init(acceptOverage: overage, acceptUnknown: true))
        XCTAssertEqual(accepted.preview.disclosure, candidate.candidate.disclosure)
        XCTAssertEqual(accepted.preview.action, candidate.candidate.action)
        let cancelled = try await service.sharedTracking(shopID: input.shopId); XCTAssertEqual(cancelled, page)
        if ["adopt-cancel", "compound-undo-cancel"].contains(input.phase) { return }
        let operation = try await service.prepareSharedTrackingApply(accepted)
        XCTAssertEqual(operation.sharedTrackingBinding?.base.requestRevision, requestPreview?.requestRevision)
        try saveTrackingWire(operation, confirmedURL)
        try saveTrackingWire(candidate.candidate.after.graph, expectedGraphURL)
        try saveTrackingWire(TrackingApplyToken(previewId: accepted.preview.previewId.string, previewDigest: accepted.preview.previewDigest.value), acceptedTokenURL)
        if ["adopt-lost", "compound-undo-lost"].contains(input.phase) {
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


extension SharedMealNativeWireTests {
    private func exerciseRequestUndoWire(_ input: TrackingWireInput, service: HouseholdService, page: SharedTrackingPage, stateURL: URL) async throws {
        let outbox = OperationOutbox(url: stateURL.appendingPathComponent("request-undo-pending.json"))
        let savedURL = stateURL.appendingPathComponent("request-undo-confirmed.json")
        let shop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
        if ["request-undo-retry", "request-undo-replay-after-reaccept"].contains(input.phase) {
            let saved = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: savedURL))
            let rows = try await outbox.operations()
            if input.phase == "request-undo-retry" { XCTAssertEqual(rows, [saved]) }
            else { XCTAssertTrue(rows.isEmpty) }
            let receipt = try await service.sendRequestAcceptanceUndo(saved, outbox: outbox)
            XCTAssertEqual(receipt.operationId, saved.sharedRequestUndoBinding?.reservedOperationID.string)
            XCTAssertEqual(receipt.shopRevision, saved.sharedRequestUndoBinding!.base.shopRevision + 1)
            let afterPage = try await service.sharedTracking(shopID: input.shopId)
            let afterShop = try await service.shopperShop(shopID: shop.shopId)
            XCTAssertEqual(afterPage, page); XCTAssertEqual(afterShop, shop)
            let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
            return
        }
        let target = try XCTUnwrap(input.targetOperationId)
        print("Request Undo wire: reading history")
        let history = try await service.requestAcceptanceHistory(shop: shop)
        XCTAssertTrue(history.items.contains { $0.operationId == target && $0.eligibility.status == .reviewable })
        print("Request Undo wire: reading candidate")
        let candidate = try await service.requestAcceptanceUndoCandidate(shop: shop, targetOperationID: target)
        XCTAssertEqual(candidate.requestUndo.originalQuantityText, input.originalQuantityText)
        XCTAssertEqual(candidate.requestUndo.targetBefore.revision, input.requestRevision)
        XCTAssertEqual(candidate.requestUndo.beforeLink.reviewedRevision, input.requestRevision)
        XCTAssertEqual(candidate.foodBefore.graph, page.graph)
        XCTAssertFalse(candidate.scope.quoteChanged)
        print("Request Undo wire: preparing exact pack order")
        let packs = try requestUndoWirePacks(candidate: candidate, existing: input.packs)
        print("Request Undo wire: requesting preview")
        let review = try await service.previewRequestAcceptanceUndo(shop: shop, candidate: candidate, packs: packs, acceptOverage: false, acceptUnknown: true)
        print("Request Undo wire: preview validated")
        XCTAssertEqual(review.candidate, candidate)
        let unchanged = try await service.sharedTracking(shopID: input.shopId)
        let unchangedShop = try await service.shopperShop(shopID: shop.shopId)
        XCTAssertEqual(unchanged, page); XCTAssertEqual(unchangedShop, shop)
        let empty = try await outbox.operations(); XCTAssertTrue(empty.isEmpty)
        if input.phase == "request-undo-cancel" { return }
        XCTAssertEqual(input.phase, "request-undo-lost")
        let operation = try await service.prepareRequestAcceptanceUndo(review)
        XCTAssertEqual(operation.sharedRequestUndoBinding?.reservedOperationID, review.response.operationId)
        try saveTrackingWire(operation, savedURL)
        do { _ = try await service.sendRequestAcceptanceUndo(operation, outbox: outbox); XCTFail("Lost real receipt unexpectedly delivered") }
        catch { XCTAssertEqual(error as? ClientError, .transport) }
        let retained = try await outbox.operations(); XCTAssertEqual(retained, [operation]); XCTAssertEqual(retained.first?.bytes, operation.bytes)
    }
}

// Existing tracking evidence retains insertion order; the dedicated Undo input
// binds its array to the fresh candidate's basket order. Reorder only by exact
// identity: no omitted/duplicate/foreign row or reconstructed quantity is allowed.
func requestUndoWirePacks(candidate: SharedRequestUndoCandidate, existing: [SharedDemandPackReview]) throws -> [SharedDemandPackReview] {
    try demandRequire(demandUnique(existing.map(\.lineId)) &&
        Set(existing.map(\.lineId)) == Set(candidate.packReviewLineIds))
    return try candidate.packReviewLineIds.map { id in
        try XCTUnwrap(existing.first { $0.lineId == id })
    }
}


extension SharedMealNativeWireTests {
    /// Every page, catalog, candidate, acknowledgment and command response comes
    /// from the real service. Fixture inputs are explicitly entered intent only.
    private func exercisePartialTrackingWire(_ input: TrackingWireInput, service: HouseholdService, page: SharedTrackingPage, stateURL: URL) async throws {
        XCTAssertEqual(page.status, .enabled)
        XCTAssertEqual(page.coverage?.status, .partial)
        XCTAssertEqual(page.coverage?.allocatableUnboundFactIds, [])
        let outbox = OperationOutbox(url: stateURL.appendingPathComponent("partial-tracking-pending.json"))
        let savedURL = stateURL.appendingPathComponent("partial-tracking-confirmed.json")
        let beforeShop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
        if input.phase.hasSuffix("-retry") {
            let saved = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: savedURL))
            let pending = try await outbox.operations(); XCTAssertEqual(pending, [saved])
            XCTAssertEqual(pending.first?.bytes, saved.bytes)
            let receipt = try await service.sendSharedTracking(saved, outbox: outbox)
            XCTAssertEqual(receipt.shopRevision, saved.sharedTrackingBinding!.base.shopRevision + 1)
            let unchanged = try await service.sharedTracking(shopID: input.shopId)
            let unchangedShop = try await service.shopperShop(shopID: beforeShop.shopId)
            XCTAssertEqual(unchanged, page); XCTAssertEqual(unchangedShop, beforeShop)
            let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
            return
        }
        let kind: SharedTrackingIntentKind
        var catalog: SharedTrackingMealSources?
        let transfers = input.transferredChanges?.map { SharedTrackingTransferredChange(factId: $0.factId, after: $0.after) }
        if input.phase.hasPrefix("partial-store-") {
            XCTAssertEqual(beforeShop.storeReviewRequired, true)
            kind = .review(action: try XCTUnwrap(input.action), packs: input.packs)
        } else if input.phase.hasPrefix("partial-meal-undo-") {
            let target = try XCTUnwrap(input.targetOperationId)
            let history = try await service.sharedTrackingHistory(page: page)
            XCTAssertTrue(history.items.contains { $0.operationId == target && $0.reviewRoute == .trackingMeal && $0.status == .current_preview_required })
            kind = .mealOperationUndo(targetOperationId: target, packs: input.packs)
        } else {
            XCTAssertTrue(input.phase.hasPrefix("partial-meal-") || input.phase == "partial-protected-apply")
            let action = try XCTUnwrap(input.action)
            catalog = try await service.sharedTrackingMealActionSources(page: page, action: action)
            XCTAssertEqual(catalog, input.expectedMealCatalog)
            kind = .change(action: action, change: try XCTUnwrap(input.change), packs: input.packs, unboundFactIds: try XCTUnwrap(input.unboundFactIds))
        }
        let candidate = try await service.sharedTrackingCandidate(page: page, kind: kind, mealSources: catalog, transferredChanges: transfers)
        XCTAssertEqual(candidate.page, page)
        if input.phase.hasPrefix("partial-store-") {
            XCTAssertEqual(candidate.candidate.after.unbound, page.state?.unbound)
            XCTAssertEqual(candidate.candidate.after.catalog, page.state?.catalog)
            XCTAssertEqual(candidate.candidate.after.graph.contributions, page.state?.graph.contributions)
            XCTAssertEqual(candidate.candidate.disclosure.money.after.status, "overCap")
            do { _ = try await service.acceptSharedTrackingCandidate(candidate, acceptUnknown: true); XCTFail("Store overage lacked explicit consent") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        } else if input.phase.hasPrefix("partial-meal-undo-") {
            guard case .mealOperationUndo(let disclosure) = candidate.candidate.disclosure.changes else { return XCTFail("Whole-meal Undo disclosure missing") }
            XCTAssertEqual(disclosure.targetOperationId, input.targetOperationId)
        } else {
            guard case .mealActionChange(let disclosure) = candidate.candidate.disclosure.changes else { return XCTFail("Enabled meal disclosure missing") }
            XCTAssertEqual(disclosure.mealChange, catalog?.mealChange)
            XCTAssertEqual(disclosure.transferredChanges.map(\.factId), transfers?.map(\.factId) ?? [])
            if input.phase == "partial-protected-apply" {
                let transfer = try XCTUnwrap(transfers?.first), after = try XCTUnwrap(transfer.after)
                XCTAssertEqual(after.quantity?.unit, .gram)
                XCTAssertEqual(after.quantity?.confirmedConversion?.targetUnit, .count)
                XCTAssertTrue(candidate.candidate.after.unbound.contains { $0.factId == transfer.factId && $0.transferred == after })
                XCTAssertFalse(candidate.candidate.after.graph.contributions.contains { $0.id == after.id })
                XCTAssertFalse(candidate.candidate.after.graph.edges.contains { $0.demandId == after.id || $0.supplyId == after.id })
            } else {
                let changed = try XCTUnwrap(input.change?.contributions.first)
                XCTAssertEqual(changed.quantity?.unit, .cup)
                XCTAssertEqual(changed.quantity?.confirmedConversion?.targetUnit, .gram)
                XCTAssertEqual(candidate.candidate.after.graph.edges, page.state?.graph.edges)
                XCTAssertEqual(candidate.candidate.after.graph.contributions.first { $0.id == changed.id }, changed)
            }
        }
        let accepted = try await service.acceptSharedTrackingCandidate(candidate, acceptOverage: input.acceptOverage ?? false, acceptUnknown: true)
        XCTAssertEqual(accepted.preview.disclosure, candidate.candidate.disclosure)
        let unchanged = try await service.sharedTracking(shopID: input.shopId)
        let unchangedShop = try await service.shopperShop(shopID: beforeShop.shopId)
        XCTAssertEqual(unchanged, page); XCTAssertEqual(unchangedShop, beforeShop)
        let pendingBefore = try await outbox.operations(); XCTAssertTrue(pendingBefore.isEmpty)
        if input.phase.hasSuffix("-cancel") { return }
        let operation = try await service.prepareSharedTrackingApply(accepted)
        try saveTrackingWire(operation, savedURL)
        if input.phase.hasSuffix("-lost") {
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Actual successful command reply should be dropped") }
            catch { XCTAssertEqual(error as? ClientError, .transport) }
            let pending = try await outbox.operations(); XCTAssertEqual(pending, [operation]); XCTAssertEqual(pending.first?.bytes, operation.bytes)
        } else {
            let receipt = try await service.sendSharedTracking(operation, outbox: outbox)
            XCTAssertEqual(receipt.shopRevision, page.shopRevision + 1)
        }
        let after = try await service.sharedTracking(shopID: input.shopId)
        XCTAssertEqual(after.state, candidate.candidate.after)
        XCTAssertEqual(after.coverage?.allocatableUnboundFactIds, [])
        if let survivor = input.survivor { XCTAssertEqual(after.graph.contributions.first { $0.id == survivor.id }, survivor) }
        if input.phase.hasPrefix("partial-store-") {
            let updatedShop = try await service.shopperShop(shopID: beforeShop.shopId)
            XCTAssertEqual(updatedShop.storeReviewRequired, false)
            XCTAssertEqual(updatedShop.storeBasisRevision, beforeShop.storeBasisRevision)
        }
    }
}
