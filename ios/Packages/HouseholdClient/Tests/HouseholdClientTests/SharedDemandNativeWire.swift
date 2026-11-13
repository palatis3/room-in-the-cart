import Security
import XCTest
@testable import HouseholdClient

private final class SharedDemandLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
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
private final class DemandWireVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private let url: URL
    init(url: URL) { self.url = url }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return FileManager.default.fileExists(atPath:url.path) ? try String(contentsOf:url,encoding:.utf8) : nil }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; try Data(value.utf8).write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
    func clear() throws { lock.lock(); defer { lock.unlock() }; if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
private struct DemandWireInput: Decodable {
    let phase, householdId: String
    let shopId: UUID
    let requests: [SharedDemandPreviewRequest]
    let before: SharedDemandPage?
}
extension SharedMealNativeWireTests {
    func exerciseSharedDemandWire() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = try JSONDecoder().decode(DemandWireInput.self,from:Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(env["RITC_WIRE_DEMAND_FIXTURE"]))))
        let base = try XCTUnwrap(URL(string:"https://127.0.0.1:\(try XCTUnwrap(env["RITC_WIRE_PORT"]))"))
        let cert = try Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(env["RITC_WIRE_CERT"])))
        let session = URLSession(configuration:.ephemeral,delegate:SharedDemandLoopbackTrust(certificate:cert),delegateQueue:nil); defer { session.invalidateAndCancel() }
        let transport = HTTPTransport(session:session)
        let auth = AdultAuth(configuration:try .init(projectURL:base,publishableKey:"sb_publishable_demand_fixture"),vault:MemoryVault(),transport:transport)
        _ = try await auth.verifyEmailCode(email:"wire@example.invalid",code:XCTUnwrap(env["RITC_WIRE_CODE"]))
        let state = URL(fileURLWithPath:try XCTUnwrap(env["RITC_WIRE_DEMAND_STATE"]),isDirectory:true)
        let vault = DemandWireVault(url:state.appendingPathComponent(try XCTUnwrap(env["RITC_WIRE_DEMAND_VAULT"])+".json"))
        let configuration = try ServiceConfiguration(baseURL:base)
        var service = HouseholdService(configuration:configuration,auth:auth,deviceVault:vault,transport:transport)
        _ = try await service.enroll(householdID:input.householdId)
        _ = try await service.selectShop(input.shopId)
        if input.phase == "denied" {
            do { _ = try await service.sharedDemand(shopID:input.shopId); XCTFail("Contributor received raw graph") } catch { XCTAssertEqual(error as? ClientError,.accessEnded) }
            do { let _:SharedDemandPage = try await service.perform("shops/\(input.shopId.uuidString.lowercased())/demand",method:"GET"); XCTFail("Server exposed graph") }
            catch ClientError.service(let status,_,_,_) { XCTAssertEqual(status,404) }
            return
        }
        let page = try await service.sharedDemand(shopID:input.shopId); XCTAssertEqual(page,input.before)
        if input.phase.hasPrefix("meal-") {
            try await exerciseMealActionWire(input: input, page: page, service: service, configuration: configuration,
                auth: auth, vault: vault, transport: transport, state: state)
            return
        }
        let outbox = OperationOutbox(url:state.appendingPathComponent("pending.json"))
        if input.phase == "privacy" {
            XCTAssertEqual(page.status,.reviewRequired)
            let pending = try await outbox.operations(); XCTAssertEqual(pending.count,1)
            do { _ = try await service.executeSharedDemand(try XCTUnwrap(pending.first)); XCTFail("Erased receipt replayed") }
            catch ClientError.service(let status,_,_,_) { XCTAssertEqual(status,409) }
            return
        }
        if input.phase == "stale-device" {
            let request = try XCTUnwrap(input.requests.first), review = try await service.previewSharedDemand(shopID:input.shopId,request:request)
            let saved = try await service.prepareSharedDemandApply(review)
            let second = HouseholdService(configuration:configuration,auth:auth,deviceVault:MemoryVault(),transport:transport)
            _ = try await second.enroll(householdID:input.householdId); _ = try await second.selectShop(input.shopId)
            do { _ = try await second.prepareSharedDemandApply(review); XCTFail("Cross-device review prepared") } catch { XCTAssertEqual(error as? ClientError,.accessEnded) }
            // Adversarial cloned pending metadata must still fail at the real server.
            let context = try await second.sharedDemandContext(shopID:input.shopId), old = try XCTUnwrap(saved.sharedDemandBinding)
            let copied = SharedDemandOperationBinding(context:context,shopID:old.shopID,reservedOperationID:old.reservedOperationID,previewID:old.previewID,previewDigest:old.previewDigest,action:old.action,base:old.base,graphRevision:old.graphRevision)
            let originalEnvelope = try JSONDecoder().decode(CommandEnvelope.self,from:saved.bytes)
            let freshWindow = try await second.replayWindow()
            let envelope = CommandEnvelope(replayWindow:freshWindow.id,shopId:originalEnvelope.shopId,kind:originalEnvelope.kind,base:originalEnvelope.base,body:originalEnvelope.body)
            let cloned = try PendingOperation(envelope:envelope,householdID:context.householdID,memberID:context.memberID,deviceID:context.deviceID,sharedDemandBinding:copied)
            do { _ = try await second.executeSharedDemand(cloned); XCTFail("Server accepted another device preview") }
            catch ClientError.service(let status,let code,_,_) { XCTAssertEqual(status,409); XCTAssertEqual(code,"refresh_required") }
            let fresh = try await second.previewSharedDemand(shopID:input.shopId,request:request)
            let accepted = try await second.prepareSharedDemandApply(fresh); _ = try await second.executeSharedDemand(accepted)
            do { _ = try await service.executeSharedDemand(saved); XCTFail("Stale revision applied") }
            catch ClientError.service(let status,_,_,_) { XCTAssertEqual(status,409) }
            let reread = try await service.sharedDemand(shopID:input.shopId); XCTAssertEqual(reread.graph,fresh.preview.after)
            return
        }
        for request in input.requests {
            if input.phase == "request" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded(request)) as? [String:Any])
                var change = try XCTUnwrap(object["change"] as? [String:Any]), rows = try XCTUnwrap(change["contributions"] as? [[String:Any]])
                XCTAssertTrue(rows[0]["quantity"] is NSNull, "Explicit unknown must be an actual JSON null")
                rows[0].removeValue(forKey:"quantity"); change["contributions"] = rows; object["change"] = change
                do { let _:SharedDemandPreview = try await service.perform("shops/\(input.shopId.uuidString.lowercased())/demand/previews",method:"POST",body:JSONSerialization.data(withJSONObject:object)); XCTFail("Server accepted omitted required unknown") }
                catch ClientError.service(let status,_,_,_) { XCTAssertEqual(status,422) }
            }
            let current = try await service.sharedDemand(shopID:input.shopId)
            let review = try await service.previewSharedDemand(shopID:input.shopId,request:request)
            XCTAssertEqual(review.preview.before,current.graph ?? review.preview.before)
            let cancelled = try await service.sharedDemand(shopID:input.shopId); XCTAssertEqual(cancelled,current,"Preview without Apply changes no persisted graph")
            for source in request.change.contributions {
                XCTAssertEqual(review.preview.after.contributions.first { $0.id == source.id }?.originalText,source.originalText)
            }
            if input.phase == "adopt-cancel" { XCTAssertEqual(current.status,.legacy); continue }
            let operation = try await service.prepareSharedDemandApply(review)
            try await outbox.purge(); try await outbox.append(operation)
            if input.phase == "adopt-apply" {
                do { _ = try await service.executeSharedDemand(operation); XCTFail("Expected intentionally dropped successful response") } catch {}
                service = HouseholdService(configuration:configuration,auth:auth,deviceVault:vault,transport:transport)
                _ = try await service.enroll(householdID:input.householdId)
            }
            let restored = try await OperationOutbox(url:state.appendingPathComponent("pending.json")).operations()
            XCTAssertEqual(restored,[operation]); XCTAssertEqual(restored.first?.bytes,operation.bytes)
            let receipt = try await service.executeSharedDemand(try XCTUnwrap(restored.first))
            XCTAssertEqual(receipt.operationId,review.preview.receipt.operationId.string)
            let after = try await service.sharedDemand(shopID:input.shopId)
            XCTAssertEqual(after.graph,review.preview.after); XCTAssertEqual(after.totals,review.preview.afterTotals)
            if input.phase == "request" { XCTAssertNil(after.totals.first?.quantity); XCTAssertNil(after.graph?.contributions.last?.quantity) }
        }
    }
}

private extension SharedMealNativeWireTests {
    func exerciseMealActionWire(input: DemandWireInput, page: SharedDemandPage, service initialService: HouseholdService,
        configuration: ServiceConfiguration, auth: AdultAuth, vault: DemandWireVault, transport: HTTPTransport, state: URL) async throws {
        var service = initialService
        let template = try XCTUnwrap(input.requests.first)
        guard case .patch(let patch) = template.action else { return XCTFail("Expected exact typed meal patch") }
        let request = try SharedDemandActionSourceRequest(page: page, patch: patch)
        let catalog = try await service.sharedDemandActionSources(shopID: input.shopId, page: page, request: request)
        XCTAssertEqual(catalog.base, request.base); XCTAssertEqual(catalog.graphDigest, page.graphDigest)
        XCTAssertEqual(catalog.normalizedAction, request.action)
        let before = try XCTUnwrap(page.graph)
        for row in catalog.sources {
            if let old = row.before { XCTAssertEqual(before.contributions.first { $0.id == old.id }, old) }
        }
        let cancelled = try await service.sharedDemand(shopID: input.shopId)
        XCTAssertEqual(cancelled, page, "Catalog without Apply changes nothing")
        if input.phase == "meal-catalog-cancel" {
            XCTAssertEqual(patch.mealEdit?.meal?.title, "  Proposed title only  ", "Caller draft must remain unchanged")
            guard case .patch(let normalized) = request.action else { return XCTFail("Expected normalized patch") }
            XCTAssertEqual(normalized.mealEdit?.meal?.title, "Proposed title only")
            XCTAssertEqual(normalized.mealEdit?.meal?.planning?.groups.first?.name, "Dinner group")
            XCTAssertEqual(normalized.mealEdit?.meal?.planning?.ingredients.first?.name, "Wraps")
            return
        }
        var change = SharedDemandChange()
        let protectedApply = input.phase == "meal-protected-apply"
        let conversionApply = input.phase == "meal-conversion-apply"
        if protectedApply {
            let rows = catalog.sources.filter { $0.transition == .quantifyReservation }
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first), old = try XCTUnwrap(row.before)
            XCTAssertNil(old.quantity); XCTAssertTrue(old.source.isReservation)
            XCTAssertEqual(row.proposed.id, old.id); XCTAssertEqual(row.proposed.source, old.source)
            XCTAssertEqual(row.proposed.originalText, old.originalText)
            var quantified = old; quantified.quantity = try XCTUnwrap(row.proposed.quantity)
            XCTAssertEqual(quantified.source, old.source); XCTAssertEqual(quantified.productKey, old.productKey)
            XCTAssertEqual(quantified.exclusions, old.exclusions); XCTAssertEqual(quantified.contains, old.contains)
            change = .init(contributions: [quantified], quantifyReservationIds: [old.id])
        } else if conversionApply {
            let row = try XCTUnwrap(catalog.sources.first { $0.transition == .update }), old = try XCTUnwrap(row.before)
            let original = try XCTUnwrap(old.quantity), fixed = try XCTUnwrap(row.proposed.quantity)
            XCTAssertEqual(original.unit, .cup); XCTAssertEqual(original.amount, try .init(numerator: 1))
            XCTAssertNotNil(original.confirmedConversion)
            XCTAssertEqual(fixed.unit, .cup); XCTAssertEqual(fixed.amount, try .init(numerator: 2)); XCTAssertEqual(fixed.originalLiteral, "2 measured cups")
            XCTAssertNil(fixed.confirmedConversion, "Changed facts cannot inherit the old basis")
            XCTAssertEqual(row.proposed.source, old.source); XCTAssertEqual(row.proposed.id, old.id)
            var reconfirmed = fixed
            reconfirmed.confirmedConversion = .init(sourceUnit: .cup, targetUnit: .gram,
                targetAmountPerSourceUnit: try .init(numerator: 120),
                sourceNote: "Explicit reconfirmation for changed meal", confirmedAt: ISO8601DateFormatter().string(from: Date()))
            var updated = old; updated.quantity = reconfirmed
            change = .init(contributions: [updated])
        } else { XCTAssertEqual(input.phase, "meal-proposal-revoked"); XCTAssertTrue(catalog.sources.allSatisfy { $0.transition == .retain }) }
        let base = SharedDemandBase(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, graphRevision: before.revision)
        let previewRequest = SharedDemandPreviewRequest(mode: (protectedApply || conversionApply) ? .change : .review, base: base,
            change: change, action: catalog.normalizedAction, packs: template.packs)
        if protectedApply {
            var unconfirmed = previewRequest; unconfirmed.change.quantifyReservationIds = nil
            do { _ = try await service.previewSharedDemand(shopID: input.shopId, request: unconfirmed); XCTFail("Unconfirmed protected quantity accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 422); XCTAssertEqual(code, "protected_unknown_changed") }
        }
        if conversionApply {
            var missing = previewRequest; missing.change.contributions[0].quantity?.confirmedConversion = nil
            do { _ = try await service.previewSharedDemand(shopID: input.shopId, request: missing); XCTFail("Missing conversion reconfirmation accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 422); XCTAssertEqual(code, "incompatible_units") }
            var conflicting = previewRequest
            conflicting.change.contributions[0].quantity?.confirmedConversion?.targetAmountPerSourceUnit = try .init(numerator: 100)
            do { _ = try await service.previewSharedDemand(shopID: input.shopId, request: conflicting); XCTFail("Conflicting conversion basis accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 422); XCTAssertEqual(code, "conflicting_conversion_basis") }
        }
        let review = try await service.previewSharedDemand(shopID: input.shopId, request: previewRequest)
        let afterPreview = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(afterPreview, page)
        let operation = try await service.prepareSharedDemandApply(review)
        if !protectedApply && !conversionApply {
            // The fixture revokes the ordinary planner grant before this second catalog is dispatched.
            do { _ = try await service.sharedDemandActionSources(shopID: input.shopId, page: page, request: request); XCTFail("Revoked proposal catalog accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "stale_proposal") }
            do { _ = try await service.previewSharedDemand(shopID: input.shopId, request: previewRequest); XCTFail("Revoked proposal preview accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "stale_proposal") }
            do { _ = try await service.executeSharedDemand(operation); XCTFail("Revoked proposal Apply accepted") }
            catch ClientError.service(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "stale_proposal") }
            let rejected = try await service.sharedDemand(shopID: input.shopId); XCTAssertEqual(rejected, page)
            return
        }
        let outbox = OperationOutbox(url: state.appendingPathComponent("meal-action-pending.json"))
        try await outbox.append(operation)
        if protectedApply {
            var dropped = false
            do { _ = try await service.executeSharedDemand(operation) } catch { dropped = true }
            XCTAssertTrue(dropped, "Fixture must drop first committed response")
            service = HouseholdService(configuration: configuration, auth: auth, deviceVault: vault, transport: transport)
            _ = try await service.enroll(householdID: input.householdId)
        }
        let pending = try await OperationOutbox(url: state.appendingPathComponent("meal-action-pending.json")).operations()
        XCTAssertEqual(pending, [operation]); XCTAssertEqual(pending.first?.bytes, operation.bytes)
        let receipt = try await service.executeSharedDemand(try XCTUnwrap(pending.first))
        XCTAssertEqual(receipt.operationId, review.preview.receipt.operationId.string)
        let after = try await service.sharedDemand(shopID: input.shopId)
        XCTAssertEqual(after.graph, review.preview.after); XCTAssertEqual(after.totals, review.preview.afterTotals)
        for old in before.contributions where !change.contributions.contains(where: { $0.id == old.id }) {
            XCTAssertEqual(after.graph?.contributions.first { $0.id == old.id }, old)
        }
        XCTAssertEqual(after.graph?.edges, before.edges)
        do { _ = try await service.sharedDemandActionSources(shopID: input.shopId, page: page, request: request); XCTFail("Old catalog base remained current") }
        catch ClientError.service(let status, _, _, _) { XCTAssertEqual(status, 409) }
    }
}
