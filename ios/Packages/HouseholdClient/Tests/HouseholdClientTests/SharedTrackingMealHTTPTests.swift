import Foundation
import XCTest
@testable import HouseholdClient

private func mealTrackingBody(_ request: URLRequest) -> Data {
    if let bytes = request.httpBody { return bytes }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
    return result
}
extension HouseholdClientTests {
    func testTrackingMealCatalogChangesAndWholeUndoHTTPKeepFullAcknowledgmentAndDurableExactRetry() async throws {
        typealias F = TrackingWriteFixture
        typealias M = TrackingMealFixture
        for mode in ["meal", "quantify", "undo"] {
            let raw: [String: Any], expected: SharedTrackingCandidateReview
            if mode == "undo" { raw = try M.inverse(); expected = try M.inverseReview(raw) }
            else { raw = try M.fixture(quantify: mode == "quantify"); expected = try M.review(raw) }
            let page = expected.page, auth = try auth(), vault = MemoryVault(), configuration = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
            var service = HouseholdService(configuration: configuration, auth: auth, deviceVault: vault, transport: transport())
            var posts: [Data] = [], sources = 0, candidates = 0, previews = 0, windows = 0
            MockURLProtocol.handler = { request in
                if let response = self.authResponse(request) { return response }
                let path = request.url!.path
                if path.hasSuffix("/devices") { return (201, try F.bytes(["deviceId": "device", "deviceToken": "test"])) }
                if path.hasSuffix("/bootstrap") { return (200, try F.bytes(["household": ["id": self.household, "label": "Home"], "memberId": self.member,
                    "role": "shopper", "shopId": F.id(2), "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
                if path.hasSuffix("/demand/tracking") { return (200, try F.bytes(raw["page"]!)) }
                if path.hasSuffix("/meal-action-sources") {
                    sources += 1
                    let sent = try JSONSerialization.jsonObject(with: mealTrackingBody(request)) as! [String: Any]
                    XCTAssertEqual(Set(sent.keys), ["base", "action"])
                    let sourceRequest = try SharedTrackingMealSourceRequest(page: page, action: expected.candidate.action.command)
                    XCTAssertEqual(try F.decode(sent, as: JSONValue.self), try JSONDecoder().decode(JSONValue.self, from: encoded(sourceRequest)))
                    return (200, try F.bytes(raw["catalog"]!))
                }
                if path.hasSuffix("/candidates") {
                    candidates += 1
                    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: mealTrackingBody(request)), try JSONDecoder().decode(JSONValue.self, from: encoded(expected.intent)))
                    return (200, try F.bytes(raw["candidate"]!))
                }
                if path.hasSuffix("/previews") {
                    previews += 1
                    let sent = try JSONSerialization.jsonObject(with: mealTrackingBody(request)) as! [String: Any]
                    XCTAssertEqual(sent["acceptUnknown"] as? Bool, true); XCTAssertEqual(sent["acceptOverage"] as? Bool, false)
                    XCTAssertEqual(try F.decode(sent["acknowledgedDisclosure"]!, as: JSONValue.self), expected.candidate.disclosure.wire)
                    return (200, try F.bytes(raw["preview"]!))
                }
                if path.hasSuffix("/replay-windows") { windows += 1; return (200, try F.bytes(["id": F.id(80), "expiresAt": "2099-01-01T00:00:00Z"])) }
                guard path.hasSuffix("/commands") else { throw ClientError.configuration }
                posts.append(mealTrackingBody(request))
                if posts.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, try F.bytes(["operationId": F.id(95), "kind": "shop.patch", "shopId": F.id(2), "shopRevision": 9, "authorityEpoch": 3, "disposition": "patched"]))
            }
            _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
            let current = try await service.sharedTracking(shopID: page.shopId.uuid)
            let catalog: SharedTrackingMealSources?
            if mode == "undo" { catalog = nil }
            else { catalog = try await service.sharedTrackingMealActionSources(page: current, action: expected.candidate.action.command) }
            let review = try await service.sharedTrackingCandidate(page: current, kind: expected.intent.kind, mealSources: catalog, transferredChanges: expected.intent.transferredChanges)
            XCTAssertEqual(previews, 0); XCTAssertEqual(windows, 0); XCTAssertTrue(posts.isEmpty)
            do { _ = try await service.acceptSharedTrackingCandidate(review); XCTFail("Missing independent unknown acceptance") } catch {}
            XCTAssertEqual(previews, 0)
            let accepted = try await service.acceptSharedTrackingCandidate(review, acceptUnknown: true)
            let operation = try await service.prepareSharedTrackingApply(accepted)
            XCTAssertEqual(operation.sharedTrackingBinding?.targetOperationID?.string, mode == "undo" ? F.id(90) : nil)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("pending.json"), outbox = OperationOutbox(url: url)
            do { _ = try await service.sendSharedTracking(operation, outbox: outbox); XCTFail("Lost reply must remain pending") }
            catch { XCTAssertEqual(error as? ClientError, .transport) }
            let restored = try await OperationOutbox(url: url).operations()
            XCTAssertEqual(restored, [operation]); XCTAssertEqual(restored.first?.bytes, operation.bytes)
            service = HouseholdService(configuration: configuration, auth: auth, deviceVault: vault, transport: transport()); _ = try await service.enroll(householdID: household)
            _ = try await service.sendSharedTracking(try XCTUnwrap(restored.first), outbox: outbox)
            XCTAssertEqual(posts, [operation.bytes, operation.bytes]); XCTAssertEqual(candidates, 1); XCTAssertEqual(previews, 1); XCTAssertEqual(windows, 1)
            XCTAssertEqual(sources, mode == "undo" ? 0 : 1)
            let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
        }
    }
}
