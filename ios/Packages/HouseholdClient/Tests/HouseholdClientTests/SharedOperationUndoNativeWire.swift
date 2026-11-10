import Security
import XCTest
@testable import HouseholdClient

private final class OperationUndoLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
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
private final class OperationUndoWireVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private let url: URL
    init(url: URL) { self.url = url }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return FileManager.default.fileExists(atPath:url.path) ? try String(contentsOf:url,encoding:.utf8) : nil }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; try Data(value.utf8).write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
    func clear() throws { lock.lock(); defer { lock.unlock() }; if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
private struct OperationUndoWireInput: Decodable {
    let phase, householdId: String
    let shopId: UUID
    let targetOperationId: SharedDemandID
    let packs: [SharedDemandPackReview]
    let before: SharedDemandPage?
    let expectedMeal: SharedOperationUndoMeal?
    let expectedStoreBasis: SharedOperationUndoStoreBasis?
}
/// Written from the actual typed server preview, not a fixture-computed inverse.
private struct OperationUndoWireExpectation: Codable {
    let reservedOperationID: SharedDemandID
    let afterGraph: SharedDemandGraph
    let afterTotals: [SharedDemandLineTotal]
    let action: SharedOperationUndoAction
    let storeBasis: SharedOperationUndoStoreBasis?
}
private func saveUndoWire<T: Encodable>(_ value: T, to url: URL) throws {
    try encoded(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
extension SharedMealNativeWireTests {
    func exerciseOperationUndoWire() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = try JSONDecoder().decode(OperationUndoWireInput.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_OPERATION_UNDO_FIXTURE"]))))
        XCTAssertEqual(input.phase, try XCTUnwrap(env["RITC_WIRE_OPERATION_UNDO_PHASE"]))
        let base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try XCTUnwrap(env["RITC_WIRE_PORT"]))"))
        let cert = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration: .ephemeral, delegate: OperationUndoLoopbackTrust(certificate: cert), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session: session)
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_undo_fixture"), vault: MemoryVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "wire@example.invalid", code: XCTUnwrap(env["RITC_WIRE_CODE"]))
        let state = URL(fileURLWithPath: try XCTUnwrap(env["RITC_WIRE_OPERATION_UNDO_STATE"]), isDirectory: true)
        let vault = OperationUndoWireVault(url: state.appendingPathComponent(try XCTUnwrap(env["RITC_WIRE_OPERATION_UNDO_VAULT"]) + ".json"))
        let service = HouseholdService(configuration: try ServiceConfiguration(baseURL: base), auth: auth, deviceVault: vault, transport: transport)
        _ = try await service.enroll(householdID: input.householdId)
        _ = try await service.selectShop(input.shopId)
        let pendingURL = state.appendingPathComponent("undo-pending.json")
        let confirmedURL = state.appendingPathComponent("undo-confirmed-operation.json")
        let expectedURL = state.appendingPathComponent("undo-expectation.json")
        let outbox = OperationOutbox(url: pendingURL)
        if input.phase == "revoked" {
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            do { _ = try await service.executeSharedDemand(operation); XCTFail("Revoked shopper prepared a typed replay") }
            catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
            // Defense in depth: the real server also denies an exact raw old command.
            do { let _: ShopperReceipt = try await service.perform("commands", method: "POST", body: operation.bytes); XCTFail("Server replayed revoked shopper success") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 404) }
            return
        }
        let page = try await service.sharedDemand(shopID: input.shopId)
        XCTAssertEqual(page, input.before)
        if input.phase == "store-erased" {
            // The selected option author is independent of these food sources.
            // Losing that proof denies old success replay, but must not erase the food.
            XCTAssertEqual(page.status, .enabled)
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            let expected = try JSONDecoder().decode(OperationUndoWireExpectation.self, from: Data(contentsOf: expectedURL))
            XCTAssertEqual(expected.storeBasis, input.expectedStoreBasis)
            do { _ = try await service.executeSharedDemand(operation); XCTFail("Erased selected basis replayed a prior inverse") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "food_undo_store_action_unsupported") }
            let after = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(after, page)
            return
        }
        if input.phase == "privacy" {
            XCTAssertEqual(page.status, .reviewRequired)
            let history = try await service.sharedOperationHistory(shopID: input.shopId, page: page)
            XCTAssertTrue(history.items.allSatisfy { $0.eligibility.status == .unavailable })
            let operation = try JSONDecoder().decode(PendingOperation.self, from: Data(contentsOf: confirmedURL))
            do { _ = try await service.executeSharedDemand(operation); XCTFail("Erased target lineage replayed a prior success") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 409) }
            let after = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(after, page)
            return
        }
        if input.phase == "retry" {
            // Separate XCTest invocation/process, with original file-backed device enrollment.
            let pending = try await outbox.operations(); XCTAssertEqual(pending.count, 1)
            let operation = try XCTUnwrap(pending.first)
            let expected = try JSONDecoder().decode(OperationUndoWireExpectation.self, from: Data(contentsOf: expectedURL))
            XCTAssertEqual(operation.sharedDemandBinding?.reservedOperationID, expected.reservedOperationID)
            XCTAssertEqual(expected.storeBasis, input.expectedStoreBasis)
            XCTAssertEqual(page.graph, expected.afterGraph); XCTAssertEqual(page.totals, expected.afterTotals)
            let receipt = try await service.executeSharedDemand(operation)
            XCTAssertEqual(receipt.operationId, expected.reservedOperationID.string)
            let after = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(after, page)
            let shop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
            XCTAssertEqual(shop.lines.sorted { $0.lineId < $1.lineId }, expected.action.body.lines.sorted { $0.lineId < $1.lineId }); XCTAssertEqual(shop.quote, expected.action.body.quote)
            if let basis = expected.storeBasis { XCTAssertEqual(shop.storeBasisRevision, basis.revision); XCTAssertEqual(shop.storeReviewRequired, false) }
            if let edit = expected.action.body.mealEdit {
                let restored = try XCTUnwrap(shop.meals?.first { $0.id == edit.occurrenceId.uuid })
                XCTAssertEqual(restored.meal, edit.meal)
                XCTAssertEqual(restored.revision, page.shopRevision)
                XCTAssertEqual(expected.action.body.mealEdit?.meal, input.expectedMeal?.restoredMeal)
                XCTAssertEqual(operation.sharedDemandBinding?.action, expected.action.commandAction)
            }
            try saveUndoWire(operation, to: confirmedURL)
            try await outbox.remove(operation.id)
            let remaining = try await OperationOutbox(url: pendingURL).operations(); XCTAssertTrue(remaining.isEmpty)
            return
        }
        let shop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
        let history = try await service.sharedOperationHistory(shopID: input.shopId, page: page)
        let target = try XCTUnwrap(history.items.first { $0.operationId == input.targetOperationId })
        XCTAssertEqual(target.eligibility.status, .reviewable)
        let candidate = try await service.sharedOperationUndoCandidate(page: page, shop: shop, target: target)
        XCTAssertEqual(candidate.targetOperationId, input.targetOperationId)
        XCTAssertEqual(candidate.storeBasis, input.expectedStoreBasis)
        if let basis = input.expectedStoreBasis { XCTAssertEqual(shop.storeBasisRevision, basis.revision); XCTAssertEqual(shop.storeReviewRequired, false) }
        if let meal = input.expectedMeal {
            XCTAssertEqual(candidate.mealUndo, meal)
            XCTAssertEqual(candidate.action.body.mealEdit?.occurrenceId, meal.occurrenceId)
            XCTAssertEqual(candidate.action.body.mealEdit?.meal, meal.restoredMeal)
            XCTAssertNil(candidate.action.body.mealEdit?.proposalId)
            XCTAssertNil(candidate.action.body.mealEdit?.changeProposalId)
        }
        XCTAssertEqual(candidate.before, page.graph); XCTAssertEqual(candidate.beforeTotals, page.totals)
        XCTAssertEqual(Set(candidate.packReviewLineIds), Set(input.packs.map(\.lineId)))
        let readOnly = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(readOnly, page)
        let review = try await service.previewSharedOperationUndo(page: page, shop: shop, target: target, candidate: candidate, packs: input.packs)
        XCTAssertEqual(review.response.action, candidate.action)
        XCTAssertEqual(review.response.storeBasis, candidate.storeBasis)
        XCTAssertEqual(review.response.mealUndo, input.expectedMeal)
        XCTAssertEqual(review.response.preview.packs, input.packs)
        let cancelled = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(cancelled, page)
        if input.phase == "cancel" {
            let pending = try await outbox.operations(); XCTAssertTrue(pending.isEmpty)
            return // Neither prepare Apply nor any command is called.
        }
        let operation = try await service.prepareSharedOperationUndoApply(review)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        var expectedBody = try review.response.action.commandAction.bodyValues()
        expectedBody["demandReview"] = .object(["previewId": .string(review.response.preview.previewId.string), "previewDigest": .string(review.response.preview.previewDigest)])
        XCTAssertEqual(envelope.body, expectedBody); XCTAssertEqual(envelope.kind, "shop.patch")
        XCTAssertEqual(envelope.base, .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch))
        if let meal = input.expectedMeal {
            guard case .object(let edit)? = envelope.body["mealEdit"] else { XCTFail("Complete mealEdit omitted"); return }
            XCTAssertEqual(Set(edit.keys), ["occurrenceId", "baseMealRevision", "meal"])
            XCTAssertEqual(try JSONDecoder().decode(SharedMeal.self, from: encoded(try XCTUnwrap(edit["meal"]))), meal.restoredMeal)
            XCTAssertEqual(operation.sharedDemandBinding?.action, review.response.action.commandAction)
        }
        if input.phase == "store-revoked-apply" {
            XCTAssertNotNil(input.expectedStoreBasis)
            try await outbox.append(operation)
            // beforeCommand revokes the real original quote author's permission
            // once after this exact preview, before either command reaches PG.
            for _ in 0..<2 {
                do { _ = try await service.executeSharedDemand(operation); XCTFail("Revoked selected basis admitted Apply or its exact retry") }
                catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "food_undo_store_action_unsupported") }
            }
            let fresh = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(fresh, page)
            let retained = try await OperationOutbox(url: pendingURL).operations()
            XCTAssertEqual(retained, [operation]); XCTAssertEqual(retained.first?.bytes, operation.bytes)
            return
        }
        if input.phase == "meal-apply" {
            XCTAssertNotNil(input.expectedMeal)
            let first = try await service.executeSharedDemand(operation)
            let replay = try await service.executeSharedDemand(operation)
            XCTAssertEqual(first, replay)
            XCTAssertEqual(first.operationId, review.response.preview.receipt.operationId.string)
            let after = try await service.sharedDemand(shopID: input.shopId)
            XCTAssertEqual(after.graph, review.response.preview.after)
            XCTAssertEqual(after.totals, review.response.preview.afterTotals)
            let savedShop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
            let edit = try XCTUnwrap(review.response.action.body.mealEdit)
            let savedMeal = try XCTUnwrap(savedShop.meals?.first { $0.id == edit.occurrenceId.uuid })
            XCTAssertEqual(savedMeal.meal, edit.meal)
            XCTAssertEqual(savedMeal.revision, page.shopRevision + 1)
            XCTAssertEqual(savedShop.lines, review.response.action.body.lines)
            XCTAssertEqual(savedShop.quote, review.response.action.body.quote)
            return
        }
        if input.phase == "stale" {
            // Fixture commits a genuine newer touched-field edit before dispatching this command.
            do { _ = try await service.executeSharedDemand(operation); XCTFail("Stale Undo applied after changed target") }
            catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 409) }
            let fresh = try await service.sharedDemand(shopID: input.shopId)
            XCTAssertEqual(fresh.shopRevision, page.shopRevision + 1)
            let currentShop = try await service.shopperShop(shopID: input.shopId.uuidString.lowercased())
            XCTAssertEqual(currentShop.lines.first?.packs, 4)
            let latest = try await service.sharedOperationHistory(shopID: input.shopId, page: fresh)
            XCTAssertEqual(latest.items.first { $0.operationId == target.operationId }?.eligibility.reason, .food_undo_line_conflict)
            do { _ = try await service.sharedOperationUndoCandidate(page: fresh, shop: currentShop, target: target); XCTFail("Fresh read hid touched-field conflict") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "food_undo_line_conflict") }
            return
        }
        XCTAssertEqual(input.phase, "apply-lost")
        let existing = try await outbox.operations(); XCTAssertTrue(existing.isEmpty)
        try await outbox.append(operation)
        try saveUndoWire(OperationUndoWireExpectation(reservedOperationID: review.response.preview.receipt.operationId,
            afterGraph: review.response.preview.after, afterTotals: review.response.preview.afterTotals, action: review.response.action, storeBasis: review.response.storeBasis), to: expectedURL)
        do { _ = try await service.executeSharedDemand(operation); XCTFail("Expected actual committed response to be dropped") }
        catch { XCTAssertEqual(error as? ClientError, .transport) }
        let stored = try await OperationOutbox(url: pendingURL).operations()
        XCTAssertEqual(stored, [operation]); XCTAssertEqual(stored.first?.bytes, operation.bytes)
        // Exit this process with the exact command retained; the next scenario retries it.
    }
}
