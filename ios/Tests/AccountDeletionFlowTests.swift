import XCTest
import HouseholdClient
@testable import RoomInTheCart

private final class ReceiptTestVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    var refuseWrites = false
    private var value: String?
    func read() throws -> String? { lock.withLock { value } }
    func write(_ token: String) throws {
        try lock.withLock {
            if refuseWrites { throw ClientError.configuration }
            value = token
        }
    }
    func clear() throws { lock.withLock { value = nil } }
}

private final class DeletionProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, bytes) = try Self.handle(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class AccountDeletionFlowTests: XCTestCase {
    private let receiptVault = ReceiptTestVault()
    private let exitVault = ReceiptTestVault()
    private let otherHouse = UUID().uuidString.lowercased()
    private let consentID = UUID().uuidString.lowercased()
    private var testingMemberships = false
    private var soleGuardian = true
    private var exited = false
    private var loseExitReply = false
    private var exitCode = 200
    private var exitBodies = [Data]()
    private var withdrawn = false
    private var withdrawals = 0
    private var statusCode = 404
    private var postCode = 202
    private var available = true
    private var recent = true
    private var adult = true
    private var complete = false
    private var loseResponse = false
    private var posted = [[String: Any]]()
    private let house = UUID().uuidString.lowercased()
    private let shop = UUID().uuidString.lowercased()
    private let child = UUID().uuidString.lowercased()
    private let successor = UUID().uuidString.lowercased()

    private func respond(_ req: URLRequest) throws -> (Int, Data) {
        let path = req.url!.path
        let user = ["id":"same-subject","email":"adult@example.test","email_confirmed_at":"2026-10-01T00:00:00Z"]
        var code = 200
        var output: [String: Any] = [:]
        switch path {
        case "/auth/v1/verify": output = ["access_token":"verified","refresh_token":"rotated","expires_in":3600,"user":user]
        case "/auth/v1/user": output = user
        case "/auth/v1/logout": break
        case "/v1/me/workspaces":
            let ids = testingMemberships ? (exited ? [otherHouse] : [house, otherHouse]) : []
            output = ["workspaces": ids.map { ["householdId":$0,"label":"House","role":"organizer"] }]
        case "/v1/households/\(house)/devices": output = ["deviceId":"device","deviceToken":"device-token"]
        case "/v1/households/\(house)/devices/current": break
        case "/v1/households/\(house)/bootstrap":
            output = ["household":["id":house,"label":"House"],"memberId":"guardian","role":"organizer",
                      "enrolled":true,"queueConsent":false,"capabilities":[]]
        case "/v1/households/\(house)/guardian/consents":
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Token"), "device-token")
            output = ["enrollmentEnabled":false,"consents":[["consentId":consentID,"childId":child,"childAlias":"B",
                      "noticeVersion":"1","grantedAt":"2026-10-01T00:00:00Z","revokedAt":withdrawn ? "2026-10-02T00:00:00Z" as Any : NSNull()]]]
        case "/v1/households/\(house)/guardian/consents/\(consentID)/revoke":
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Token"), "device-token")
            withdrawn = true; withdrawals += 1
            if loseResponse { throw URLError(.networkConnectionLost) }
            output = ["consentId":consentID,"revoked":true]
        case "/v1/households/\(house)/exit":
            XCTAssertNil(req.value(forHTTPHeaderField: "X-Device-Token"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer verified")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertNotNil(try exitVault.read())
            exitBodies.append(requestBody(req))
            code = exitCode
            if code == 200 {
                exited = true
                if loseExitReply { throw URLError(.networkConnectionLost) }
                output = ["householdId":house,"left":true,"accountDeleted":false]
            }

        case "/v1/privacy/deletion-preview":
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer verified")
            output = ["adult":adult,"deletionAvailable":available,"reauthenticationRequired":!recent,"verifiedBackupRetentionDays":7,
                      "households":[["householdId":house,"memberId":"guardian","label":"House","state":"active","organizer":true,
                                     "otherAdults":[["memberId":successor,"alias":"A","organizer":false]],
                                     "activeShops":[["shopId":shop,"phase":"draft","revision":3,"authorityEpoch":2]],
                                     "soleGuardianChildren":soleGuardian ? [["memberId":child,"alias":"B"]] : []]]]
        case "/v1/privacy/deletions":
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer verified")
            XCTAssertNil(req.value(forHTTPHeaderField: "X-Device-Token"))
            let data = requestBody(req)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            posted.append(input)
            XCTAssertTrue(try XCTUnwrap(receiptVault.read()).contains(try XCTUnwrap(input["statusToken"] as? String)))
            if loseResponse { throw URLError(.networkConnectionLost) }
            code = postCode
            if code == 202 { output = try result() }
        default:
            guard path.hasPrefix("/v1/privacy/jobs/") else { XCTFail("Unexpected endpoint"); throw URLError(.badURL) }
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(req.value(forHTTPHeaderField: "X-Device-Token"))
            XCTAssertNil(req.url?.query)
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Deletion-Token"), posted.last?["statusToken"] as? String)
            XCTAssertEqual(path.split(separator: "/").last.map(String.init), posted.last?["clientKey"] as? String)
            code = statusCode
            if code == 200 { output = try result() }
        }
        return (code, try JSONSerialization.data(withJSONObject: output))
    }
    private func requestBody(_ req: URLRequest) -> Data {
        var data = req.httpBody ?? Data()
        if let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return data
    }
    private func result() throws -> [String: Any] {
        ["jobId":try XCTUnwrap(posted.last?["clientKey"]),"status":complete ? "complete" : "pending",
         "appDataErased":complete,"providerAccountDeleted":complete,
         "completedAt":complete ? "2026-10-03T00:00:00Z" as Any : NSNull(),"receiptExpiresAt":"2026-11-03T00:00:00Z"]
    }
    private func model(signIn: Bool = true) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeletionProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://auth.test")!, publishableKey: "sb_publishable_test"), vault: ReceiptTestVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://app.test")!), auth: auth, deviceVault: ReceiptTestVault(), transport: transport)
        DeletionProtocol.handle = { request in try DispatchQueue.main.sync { try self.respond(request) } }
        let model = HouseholdModel(auth: auth, service: service,
            outboxURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json"), deletionVault: receiptVault, exitVault: exitVault)
        if signIn { model.email = "adult@example.test"; model.code = "123456"; await model.verifyCode(); XCTAssertNotNil(model.identity) }
        return model
    }
    private func review(_ flow: AccountDeletionModel) async {
        await flow.review(subject: "same-subject")
        flow.choices.organizers[house] = .transfer(successor)
        flow.choices.shops[.init(household: house, id: shop)] = .archiveOrClose
        flow.choices.children.insert(.init(household: house, id: child))
    }
    func testLostHouseholdExitRetriesOriginalBytesWithoutADeviceAfterMembershipIsGone() async throws {
        testingMemberships = true; soleGuardian = false; available = false
        let account = try await model()
        account.keepLocalPrivate = true
        let workspace = try XCTUnwrap(account.workspaces.first { $0.id == house })
        await account.join(workspace)
        XCTAssertEqual(account.projection?.household.id, house)
        let exit = try XCTUnwrap(account.householdExit)
        await exit.review(subject: "same-subject")
        exit.select(try XCTUnwrap(exit.preview?.households.first))
        XCTAssertFalse(exit.canLeave)
        exit.choices.organizers[house] = .transfer(successor)
        exit.choices.shops[.init(household: house, id: shop)] = .archiveOrClose
        XCTAssertTrue(exit.canLeave)
        loseExitReply = true
        let uncertain = await exit.confirm(subject: "same-subject")
        XCTAssertNil(uncertain)
        XCTAssertNotNil(exit.pending)
        let reopened = try await model()
        XCTAssertEqual(reopened.workspaces.map(\.id), [otherHouse])
        let recovered = try XCTUnwrap(reopened.householdExit)
        await recovered.review(subject: "same-subject")
        XCTAssertNotNil(recovered.pending)
        let wrongAccount = await recovered.send(subject: "different")
        XCTAssertNil(wrongAccount)
        loseExitReply = false
        let left = await recovered.send(subject: "same-subject")
        XCTAssertEqual(left?.householdID, house)
        XCTAssertNil(try exitVault.read())
        XCTAssertEqual(exitBodies.count, 2)
        XCTAssertEqual(exitBodies.first, exitBodies.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exitBodies.first)) as? [String:Any])
        XCTAssertEqual(payload["confirm"] as? Bool, true)
        let choices = try XCTUnwrap(payload["disposition"] as? [String:Any])
        XCTAssertEqual(choices["householdId"] as? String, house)
        XCTAssertEqual(choices["eraseChildProfiles"] as? [String], [])
        await account.householdExited(try XCTUnwrap(left))
        XCTAssertNil(account.projection)
        XCTAssertEqual(account.identity?.subject, "same-subject")
        XCTAssertEqual(account.workspaces.map(\.id), [otherHouse])
        XCTAssertTrue(posted.isEmpty)
        DeletionProtocol.handle = nil
    }

    func testExitRejectsChildErasureAndStaleAuthAndRequiresNewReviewAfterConflict() async throws {
        let account = try await model()
        let exit = try XCTUnwrap(account.householdExit)
        func choose() async throws {
            await exit.review(subject: "same-subject")
            exit.select(try XCTUnwrap(exit.preview?.households.first))
            exit.choices.organizers[house] = .archiveOrClose
            exit.choices.shops[.init(household: house, id: shop)] = .transfer(successor)
        }
        try await choose()
        exit.choices.children.insert(.init(household: house, id: child))
        XCTAssertFalse(exit.canLeave)
        soleGuardian = false; recent = false
        try await choose()
        XCTAssertTrue(exit.needsSignIn)
        XCTAssertFalse(exit.canLeave)
        recent = true; exitCode = 409
        try await choose()
        _ = await exit.confirm(subject: "same-subject")
        XCTAssertNil(exit.pending)
        XCTAssertNil(exit.preview)
        XCTAssertFalse(exit.canLeave)
        XCTAssertEqual(exitBodies.count, 1)
        DeletionProtocol.handle = nil
    }

    func testGuardianWithdrawalAfterLostReplyRefreshesScopedConsentAndRejectsStaleConfirmation() async throws {
        testingMemberships = true
        let account = try await model()
        account.keepLocalPrivate = true
        await account.join(try XCTUnwrap(account.workspaces.first))
        let lifecycle = try XCTUnwrap(account.lifecycle)
        await lifecycle.loadConsents()
        let consent = try XCTUnwrap(lifecycle.consents.first)
        XCTAssertNil(consent.revokedAt)
        loseResponse = true
        await lifecycle.withdrawConsent(consent)
        XCTAssertEqual(withdrawals, 1)
        await lifecycle.loadConsents()
        XCTAssertNotNil(lifecycle.consents.first?.revokedAt)
        await lifecycle.withdrawConsent(consent)
        XCTAssertEqual(withdrawals, 1)
        lifecycle.clearScope()
        await lifecycle.withdrawConsent(consent)
        XCTAssertEqual(withdrawals, 1)
        XCTAssertTrue(exitBodies.isEmpty)
        XCTAssertTrue(posted.isEmpty)
        DeletionProtocol.handle = nil
    }

    func testLostResponseSurvivesRecreationAndSignedOutStatusIsReadOnly() async throws {
        let account = try await model()
        let flow = try XCTUnwrap(account.accountDeletion)
        await flow.review(subject: "same-subject")
        XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        await review(flow)
        XCTAssertFalse(flow.canSubmit(subject: "other"))
        XCTAssertTrue(flow.canSubmit(subject: "same-subject"))
        loseResponse = true
        await account.submitAccountDeletion(subject: "same-subject")
        XCTAssertNil(account.identity)
        let input = try XCTUnwrap(posted.first)
        XCTAssertEqual((input["statusToken"] as? String)?.count, 43)
        let disposition = try XCTUnwrap((input["households"] as? [[String:Any]])?.first)
        XCTAssertEqual(disposition["organizerMemberId"] as? String, successor)
        XCTAssertEqual(disposition["eraseChildProfiles"] as? [String], [child])
        let shopChoice = try XCTUnwrap((disposition["shops"] as? [[String:Any]])?.first)
        XCTAssertEqual(shopChoice["action"] as? String, "close")
        XCTAssertEqual(shopChoice["revision"] as? Int, 3)
        XCTAssertEqual(shopChoice["authorityEpoch"] as? Int, 2)
        let reopened = try await model(signIn: false)
        let recovery = try XCTUnwrap(reopened.accountDeletion)
        recovery.readReceipts()
        let receipt = try XCTUnwrap(recovery.receipts.first)
        statusCode = 200
        let accepted = await recovery.check(receipt)
        XCTAssertTrue(accepted)
        XCTAssertEqual(recovery.statuses[receipt.id]?.status, .pending)
        await account.deletionAccepted(subject: receipt.subject)
        XCTAssertNil(account.identity)
        recovery.forget(receipt)
        XCTAssertEqual(recovery.receipts.count, 1)
        complete = true
        _ = await recovery.check(receipt)
        XCTAssertEqual(recovery.statuses[receipt.id]?.status, .complete)
        recovery.forget(receipt)
        XCTAssertTrue(recovery.receipts.isEmpty)
        XCTAssertEqual(posted.count, 1)
        DeletionProtocol.handle = nil
    }
    func testRetryRequiresReceiptCheckFreshChoicesAndSameKey() async throws {
        let account = try await model()
        let flow = try XCTUnwrap(account.accountDeletion)
        await review(flow)
        postCode = 401
        _ = await flow.submit(subject: "same-subject")
        XCTAssertTrue(flow.needsSignIn)
        let receipt = try XCTUnwrap(flow.receipts.first)
        await account.signOut()
        XCTAssertNil(account.identity)
        account.email = "adult@example.test"; account.code = "654321"; await account.verifyCode()
        XCTAssertEqual(account.identity?.subject, "same-subject")
        await review(flow)
        XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        _ = await flow.check(receipt)
        XCTAssertTrue(flow.missing.contains(receipt.id))
        XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        await review(flow)
        postCode = 202
        let accepted = await flow.submit(subject: "same-subject")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[0]["clientKey"] as? String, posted[1]["clientKey"] as? String)
        XCTAssertEqual(posted[0]["statusToken"] as? String, posted[1]["statusToken"] as? String)
        DeletionProtocol.handle = nil
    }
    func testIdenticalShopAndChildIDsInDifferentHouseholdsRequireIndependentConsent() throws {
        let second = UUID().uuidString.lowercased()
        let view = ["adult": true, "deletionAvailable": true, "reauthenticationRequired": false,
                    "households": [house, second].map { household in
                        ["householdId": household, "memberId": "guardian", "label": "H", "state": "active", "organizer": false, "otherAdults": [],
                         "activeShops": [["shopId": shop, "phase": "draft", "revision": 1, "authorityEpoch": 1]],
                         "soleGuardianChildren": [["memberId": child, "alias": "C"]]] as [String:Any]
                    }] as [String:Any]
        let preview = try JSONDecoder().decode(DeletionPreview.self, from: JSONSerialization.data(withJSONObject: view))
        var choices = DeletionChoices()
        choices.shops[.init(household: house, id: shop)] = .archiveOrClose
        choices.children.insert(.init(household: house, id: child))
        XCTAssertThrowsError(try choices.dispositions(for: preview))
        choices.shops[.init(household: second, id: shop)] = .archiveOrClose
        XCTAssertThrowsError(try choices.dispositions(for: preview))
        choices.children.insert(.init(household: second, id: child))
        XCTAssertEqual(try choices.dispositions(for: preview).count, 2)
    }
    func testUnavailableChildStaleAuthLockAndReceiptWriteFailureCannotSubmit() async throws {
        let account = try await model()
        let flow = try XCTUnwrap(account.accountDeletion)
        available = false; await review(flow); XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        available = true; adult = false; await review(flow); XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        adult = true; recent = false; await review(flow); XCTAssertTrue(flow.needsSignIn); XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        recent = true; await review(flow)
        flow.choices.organizers[house] = .transfer("foreign")
        XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        await review(flow)
        receiptVault.refuseWrites = true
        let submitted = await flow.submit(subject: "same-subject")
        XCTAssertEqual(submitted, .rejected)
        XCTAssertTrue(posted.isEmpty)
        await review(flow)
        account.lock()
        XCTAssertNil(flow.preview)
        XCTAssertFalse(flow.canSubmit(subject: "same-subject"))
        DeletionProtocol.handle = nil
    }
}
