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
