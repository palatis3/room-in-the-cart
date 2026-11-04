import XCTest
import CoreDomain
import HouseholdClient
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class ContributorRequestCaptureTests: XCTestCase {
    private func model(_ fixture: ContributorCaptureFixture, queue: URL, deviceVault: ContributorCaptureVault = .init(),
                       captureCorrections: CaptureCorrectionStore = .shared) async throws -> HouseholdModel {
        ContributorCaptureProtocol.handler = fixture.respond
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ContributorCaptureProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_test"), vault: ContributorCaptureVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://household.test")!), auth: auth, deviceVault: deviceVault, transport: transport)
        let model = HouseholdModel(auth: auth, service: service, outboxURL: queue, deletionVault: ContributorCaptureVault(),
                                   exitVault: ContributorCaptureVault(), captureCorrections: captureCorrections)
        model.email = "sam@example.test"; model.code = "123456"; await model.verifyCode()
        model.keepLocalPrivate = true; await model.join(try XCTUnwrap(model.workspaces.first))
        return model
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json") }
    private func captured(_ text: String, scope: ContributorRequestScope, edit: (inout CaptureLineDraft) -> Void = { _ in }) throws -> ReviewedCapture {
        var draft = try XCTUnwrap(StructuredCaptureParser.lines(text, destination: scope.destination).first)
        edit(&draft); draft.confirmed = true
        return ReviewedCapture(id: UUID(), text: text, originalText: text, source: .speech, localeIdentifier: "en-US", sourceImageData: nil,
            lines: [try XCTUnwrap(draft.reviewed(expectedDestination: scope.destination))], fieldDrafts: [draft])
    }
    func testReviewedFieldsPreserveOriginalPacksPurposeAndExclusionsWithoutSending() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        let scope = try XCTUnwrap(model.contributorRequestScope)
        let capture = try captured("2 packs of 8 wraps for lunch without sesame", scope: scope) { $0.name = "Wholemeal wraps" }
        let review = try ContributorRequestReview.captured(capture, scope: scope)
        XCTAssertTrue(review.item.contains("Wholemeal wraps")); XCTAssertTrue(review.item.contains("lunch")); XCTAssertTrue(review.item.contains("sesame"))
        XCTAssertTrue(review.item.contains(capture.originalText)); XCTAssertTrue(review.quantity.contains("2")); XCTAssertTrue(review.quantity.contains("8"))
        XCTAssertEqual(review.originalText, capture.originalText)
        XCTAssertEqual(fixture.commands.count, 0); XCTAssertTrue(model.requests.isEmpty)
        await model.sendRequest(reviewed: review, approved: false)
        XCTAssertEqual(fixture.commands.count, 0)
        await model.sendRequest(reviewed: review, approved: true)
        XCTAssertEqual(fixture.commands.count, 1); XCTAssertEqual(fixture.rows.count, 1)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: XCTUnwrap(fixture.commands.first))
        XCTAssertEqual(envelope.kind, "request.send"); XCTAssertEqual(envelope.body["originalItem"], .string(review.item))
        XCTAssertEqual(envelope.body["ownQuantity"], .string(review.quantity)); XCTAssertNil(envelope.body["price"]); XCTAssertNil(envelope.body["sourceImage"])
        XCTAssertEqual(Set(envelope.body.keys), ["originalItem", "ownQuantity", "clientRequestId", "authoredAt", "route"])
        XCTAssertEqual(fixture.privateReads, 0)
    }
    func testOversizedMultipleAndWrongDestinationStopWithoutTruncation() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        let scope = try XCTUnwrap(model.contributorRequestScope), ordinary = try captured("rice", scope: scope)
        var many = ordinary; many.lines = ordinary.lines! + ordinary.lines!
        XCTAssertThrowsError(try ContributorRequestReview.captured(many, scope: scope))
        let long = try captured(String(repeating: "x", count: 241), scope: scope)
        XCTAssertThrowsError(try ContributorRequestReview.captured(long, scope: scope))
        var wrong = try XCTUnwrap(StructuredCaptureParser.lines("rice", destination: "Other shop").first); wrong.confirmed = true
        var moved = ordinary; moved.lines = [try XCTUnwrap(wrong.reviewed(expectedDestination: "Other shop"))]
        XCTAssertThrowsError(try ContributorRequestReview.captured(moved, scope: scope))
        XCTAssertEqual(fixture.commands.count, 0)
        let unknown = try ContributorRequestReview.captured(ordinary, scope: scope)
        XCTAssertEqual(unknown.quantity, "") // Missing quantity is never an invented zero.
    }
    func testChangedDraftRouteOrBackgroundInvalidatesReviewAndCancellationIsLocal() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        model.item = "Rice"; model.quantity = "2 packs"
        let review = try ContributorRequestReview.typed(scope: XCTUnwrap(model.contributorRequestScope))
        model.forNextShop = true
        await model.sendRequest(reviewed: review, approved: true)
        XCTAssertTrue(fixture.commands.isEmpty)
        model.forNextShop = false; model.quantity = "3 packs"
        await model.sendRequest(reviewed: review, approved: true)
        XCTAssertTrue(fixture.commands.isEmpty)
        model.quantity = "2 packs"; model.lock()
        XCTAssertNil(model.contributorRequestScope)
        await model.sendRequest(reviewed: review, approved: true)
        XCTAssertTrue(fixture.commands.isEmpty); XCTAssertTrue(fixture.rows.isEmpty)
    }
    func testSpellingScopeRequiresTheCurrentContributorReview() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        let review = try XCTUnwrap(model.contributorRequestScope)
        let english = try XCTUnwrap(model.contributorCorrectionScope(for: review, localeIdentifier: "en-US"))
        let spanish = try XCTUnwrap(model.contributorCorrectionScope(for: review, localeIdentifier: "es-US"))
        let expected = try XCTUnwrap(CaptureCorrectionScope.connected(subject: review.subject, householdID: fixture.household,
                                                                     memberID: fixture.member, localeIdentifier: "en-US"))
        XCTAssertEqual(english, expected)
        XCTAssertEqual(english.profileID, spanish.profileID)
        XCTAssertNotEqual(english, spanish)

        model.item = "A different review"
        XCTAssertNil(model.contributorCorrectionScope(for: review, localeIdentifier: "en-US"))
        let updated = try XCTUnwrap(model.contributorRequestScope)
        XCTAssertEqual(model.contributorCorrectionScope(for: updated, localeIdentifier: "en-US"), english)
        model.lock()
        XCTAssertNil(model.contributorCorrectionScope(for: updated, localeIdentifier: "en-US"))
    }
    func testAcceptedAccountDeletionRetriesSpellingCleanupAfterSignOut() async throws {
        let queue = location(), directory = queue.deletingLastPathComponent().appendingPathComponent("Spellings")
        defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let store = CaptureCorrectionStore(directory: directory)
        let model = try await model(ContributorCaptureFixture(), queue: queue, captureCorrections: store)
        let review = try XCTUnwrap(model.contributorRequestScope)
        let spelling = try XCTUnwrap(model.contributorCorrectionScope(for: review, localeIdentifier: "en-US"))
        try await store.setEnabled(true, scope: spelling)
        let connected = directory.appendingPathComponent("Connected"), parked = directory.appendingPathComponent("Parked")
        try FileManager.default.moveItem(at: connected, to: parked)
        try Data().write(to: connected)

        await model.deletionAccepted(subject: review.subject)
        XCTAssertNil(model.identity)
        XCTAssertTrue(model.pendingSpellingCleanup.contains(review.subject))
        try FileManager.default.removeItem(at: connected)
        try FileManager.default.moveItem(at: parked, to: connected)
        await model.retryDeletedAccountSpellingCleanup(subject: review.subject)
        XCTAssertFalse(model.pendingSpellingCleanup.contains(review.subject))
        let removed = try await store.load(spelling)
        XCTAssertFalse(removed.enabled)
    }
    func testLostReplyRestartUsesExactProtectedRequestAndNeverChangesBasket() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), device = ContributorCaptureVault()
        let first = try await model(fixture, queue: queue, deviceVault: device)
        let scope = try XCTUnwrap(first.contributorRequestScope)
        let review = try ContributorRequestReview.captured(captured("2 packs of 8 wraps for lunch", scope: scope), scope: scope)
        fixture.loseReply = true
        await first.sendRequest(reviewed: review, approved: true)
        XCTAssertEqual(fixture.rows.count, 1)
        guard case .waiting = first.delivery else { return XCTFail("Ambiguous send must retain the same retry") }
        let bytes = try XCTUnwrap(fixture.commands.first)
        let reopened = try await model(fixture, queue: queue, deviceVault: device)
        guard case .waiting = reopened.delivery else { return XCTFail("Restart must restore the original device-bound pending request") }
        reopened.item = "Do not silently replace the pending request"
        await reopened.retry()
        XCTAssertEqual(fixture.rows.count, 1); XCTAssertEqual(fixture.commands, [bytes, bytes])
        guard case .received = reopened.delivery else { return XCTFail("Exact retry should recover the first receipt") }
        XCTAssertEqual(reopened.requests.first?.originalItem, review.item)
        XCTAssertEqual(fixture.privateReads, 0)
    }
    func testOfflineBeforeSendQueuesExactRequestUntilAnAuthorizedRetryAfterRestart() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), device = ContributorCaptureVault()
        let first = try await model(fixture, queue: queue, deviceVault: device)
        first.item = "Rice"; first.quantity = "2 bags"
        let review = try ContributorRequestReview.typed(scope: XCTUnwrap(first.contributorRequestScope))
        fixture.windowFailure = .offline
        await first.sendRequest(reviewed: review, approved: true)
        guard case .waiting = first.delivery else { return XCTFail("A reviewed offline request must wait in the local outbox") }
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertTrue(first.requests.isEmpty)
        let outbox = OperationOutbox(url: queue)
        let operations = try await outbox.operations()
        let pending = try XCTUnwrap(operations.first)
        XCTAssertEqual(operations.count, 1)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: pending.bytes)
        XCTAssertEqual(envelope.replayWindow, fixture.windowID)
        XCTAssertEqual(envelope.body["originalItem"], .string("Rice"))
        XCTAssertEqual(envelope.body["ownQuantity"], .string("2 bags"))

        fixture.windowFailure = nil
        let reopened = try await model(fixture, queue: queue, deviceVault: device)
        guard case .waiting = reopened.delivery else { return XCTFail("Authorized restart must recover the pending request") }
        XCTAssertTrue(fixture.commands.isEmpty)
        await reopened.retry()
        XCTAssertEqual(fixture.commands, [pending.bytes])
        XCTAssertEqual(reopened.requests.first?.originalItem, "Rice")
        let remaining = try await outbox.operations()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testOfflineWithoutUsableWindowAndExplicitDenialNeverQueue() async throws {
        for failure in [ContributorCaptureFixture.WindowFailure.offline, .revoked] {
            let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
            let fixture = ContributorCaptureFixture()
            if failure == .offline { fixture.windowExpiry = "2000-01-01T00:00:00.000Z" }
            let model = try await model(fixture, queue: queue)
            model.item = "Rice"
            let review = try ContributorRequestReview.typed(scope: XCTUnwrap(model.contributorRequestScope))
            fixture.windowFailure = failure
            await model.sendRequest(reviewed: review, approved: true)
            XCTAssertTrue(fixture.commands.isEmpty)
            let operations = try await OperationOutbox(url: queue).operations()
            XCTAssertTrue(operations.isEmpty)
            if failure == .revoked { XCTAssertNil(model.projection) }
            else { XCTAssertEqual(model.item, "Rice") }
        }
    }
    func testRevokedEnrollmentClearsAnOfflineRequestBeforeSending() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        model.item = "Rice"
        let review = try ContributorRequestReview.typed(scope: XCTUnwrap(model.contributorRequestScope))
        fixture.windowFailure = .offline
        await model.sendRequest(reviewed: review, approved: true)
        guard case .waiting = model.delivery else { return XCTFail("The offline review must be queued first") }

        fixture.windowFailure = nil
        fixture.enrollmentRevoked = true
        await model.retry()
        XCTAssertEqual(model.delivery, .accessEnded)
        XCTAssertNil(model.projection)
        XCTAssertTrue(fixture.commands.isEmpty)
        let remaining = try await OperationOutbox(url: queue).operations()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testDraftMutationWhilePreparingCannotSendAnUnreviewedBody() async throws {
        let queue = location(); defer { try? FileManager.default.removeItem(at: queue.deletingLastPathComponent()) }
        let fixture = ContributorCaptureFixture(), model = try await model(fixture, queue: queue)
        model.item = "Rice"
        let review = try ContributorRequestReview.typed(scope: XCTUnwrap(model.contributorRequestScope))
        let started = expectation(description: "replay window requested")
        let gate = DispatchSemaphore(value: 0); fixture.replayStarted = started; fixture.replayGate = gate
        let sending = Task { await model.sendRequest(reviewed: review, approved: true) }
        await fulfillment(of: [started], timeout: 3)
        model.item = "Changed after review"; gate.signal(); await sending.value
        XCTAssertTrue(fixture.commands.isEmpty)
    }
    func testColdContributorCaptureURLDoesNotNeedAdultStoresAndRejectsPrivateHandle() async throws {
        let queue = location(), directory = queue.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ContributorCaptureFixture(), household = try await model(fixture, queue: queue)
        let suite = "ContributorSurface." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults); access.protect()
        let bundleURL = directory.appendingPathComponent("Surface.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"invalid.fixture.surface", SurfaceInfo.schemeKey:"roominthecart-fixture"], format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("unopened-ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("unopened-pickup.sqlite"))
        let surfaces = DeviceSurfacesComposition(directory: directory.appendingPathComponent("surfaces"), bundle: bundle, launchArguments: ["--ui-testing"])
        surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let codec = try SurfaceURLCodec(scheme: "roominthecart-fixture")
        surfaces.handle(url: codec.url(handle: nil))
        for _ in 0..<100 {
            if case .ownRequest = surfaces.destination { break }
            await Task.yield()
        }
        guard case .ownRequest = surfaces.destination else { return XCTFail("Generic capture must open only the live contributor's own request") }
        surfaces.handle(url: codec.url(handle: .random()))
        guard case .unavailable = surfaces.destination else { return XCTFail("An opaque adult handle cannot grant contributor access") }
        XCTAssertFalse(access.unlocked); XCTAssertFalse(ledger.ready); XCTAssertFalse(pickup.ready)
        XCTAssertFalse(surfaces.privateAuthorized); XCTAssertEqual(fixture.privateReads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unopened-ledger.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unopened-pickup.sqlite").path))
    }
}

private final class ContributorCaptureFixture: @unchecked Sendable {
    enum WindowFailure { case offline, revoked }
    let household = UUID().uuidString.lowercased(), member = UUID().uuidString.lowercased(), shop = UUID().uuidString.lowercased()
    let windowID = UUID().uuidString.lowercased()
    var windowExpiry = "2099-01-01T00:00:00.000Z", windowFailure: WindowFailure?
    var enrollmentRevoked = false
    var commands: [Data] = [], rows: [[String: Any]] = [], receipts: [String: [String: Any]] = [:]
    var loseReply = false, privateReads = 0
    var replayStarted: XCTestExpectation?, replayGate: DispatchSemaphore?
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        func response(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if path == "/auth/v1/verify" { return try response(["access_token":"sam","refresh_token":"refresh","expires_in":3600,"user":["id":"sam","email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try response(["id":"sam","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try response(["workspaces":[["householdId":household,"label":"Home","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try response(["deviceId":"sam-device","deviceToken":"sam-device-token"],201) }
        if path.hasSuffix("/bootstrap") {
            if enrollmentRevoked { return try response(["error": ["code": "access_ended"]], 403) }
            return try response(["household":["id":household,"label":"Home"],"memberId":member,"role":"contributor","shopId":shop,"enrolled":true,"queueConsent":false,"capabilities":["own_requests"]])
        }
        if path.hasSuffix("/requests/mine") { return try response(["requests":rows,"nextCursor":NSNull()]) }
        if path.hasSuffix("/replay-windows") {
            replayStarted?.fulfill(); _ = replayGate?.wait(timeout: .now() + 5)
            if windowFailure == .offline { throw URLError(.notConnectedToInternet) }
            if windowFailure == .revoked { return try response(["error": ["code": "access_ended"]], 403) }
            return try response(["id":windowID,"expiresAt":windowExpiry])
        }
        if path.hasSuffix("/commands") {
            commands.append(data)
            let key = json["clientKey"] as! String
            if let receipt = receipts[key] { return try response(receipt) }
            XCTAssertEqual(json["kind"] as? String, "request.send")
            let body = json["body"] as! [String: Any]
            let row: [String: Any] = ["requestId":UUID().uuidString.lowercased(),"shopId":shop,"revision":1,"originalItem":body["originalItem"]!,"ownQuantity":body["ownQuantity"]!,"authoredAt":body["authoredAt"]!,"receivedAt":"2026-11-03T00:00:00Z","route":body["route"]!,"status":"pending","ownActionAllowed":true,"clarification":NSNull(),"followupTo":NSNull()]
            rows.append(row); let receipt: [String: Any] = ["operationId":UUID().uuidString,"kind":"request.send","request":row]; receipts[key] = receipt
            if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
            return try response(receipt)
        }
        privateReads += 1; throw URLError(.unsupportedURL)
    }
}
private final class ContributorCaptureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }; func write(_ value: String) throws { self.value = value }; func clear() throws { value = nil }
}
private final class ContributorCaptureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status,data) = try Self.handler(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
