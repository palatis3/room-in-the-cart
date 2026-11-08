import Security
import XCTest
@testable import HouseholdClient
private final class RollbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
 let certificate: Data
 init(_ data: Data) { certificate = data }
 func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
  guard challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust,
    let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
    SecCertificateCopyData(leaf) as Data == certificate, SecTrustSetAnchorCertificates(trust,[leaf] as CFArray) == errSecSuccess,
    SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess, SecTrustEvaluateWithError(trust,nil) else {
    completionHandler(.cancelAuthenticationChallenge,nil); return
  }
  completionHandler(.useCredential,URLCredential(trust: trust))
 }
}
final class Rollback041ProbeTests: XCTestCase {
 func testReleasedClientDeliveryProjection() async throws {
  let env = ProcessInfo.processInfo.environment
  let base = try XCTUnwrap(URL(string: "https://127.0.0.1:" + XCTUnwrap(env["PROBE_PORT"])))
  let trust = RollbackTrust(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["PROBE_CERT"]))))
  let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  let transport = HTTPTransport(session: session)
  let auth = AdultAuth(configuration: try .init(projectURL: base,publishableKey: "sb_publishable_fixture"),vault: MemoryVault(),transport: transport)
  _ = try await auth.verifyEmailCode(email: "fixture@example.invalid", code: XCTUnwrap(env["PROBE_CODE"]))
  let service = HouseholdService(configuration: try .init(baseURL: base),auth: auth,deviceVault: MemoryVault(),transport: transport)
  _ = try await service.enroll(householdID: XCTUnwrap(env["PROBE_HOUSEHOLD"]))
  let shopID = try XCTUnwrap(env["PROBE_SHOP"])
  _ = try await service.selectShop(UUID(uuidString: shopID))
  if env["PROBE_INVALID"] == "1" {
   do { _ = try await service.deliveryEvidence(shopID: shopID); XCTFail("Released client must expose its current >200 validation rejection") }
   catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
   return
  }
  let page = try await service.deliveryEvidence(shopID: shopID)
  XCTAssertEqual(page.lines.count, Int(env["PROBE_LINES"]!))
  XCTAssertEqual(page.sources.count, Int(env["PROBE_SOURCES"]!))
  let orphaned = page.sources.filter { source in !page.lines.contains { $0.id == source.lineId } }
  XCTAssertEqual(orphaned.count, Int(env["PROBE_ORPHANS"]!))
  if let added = env["PROBE_ADDED"], let id = UUID(uuidString: added) {
   let edit = SharedDeliveryEdit.register(lineID: id, segment: UUID(), name: "Added replacement", exclusions: [])
   if page.lines.contains(where: { $0.id == id }) { XCTAssertNoThrow(try edit.body(reviewed: page)) }
   else { XCTAssertThrowsError(try edit.body(reviewed: page)) }
  }
 }
}
