import XCTest
@testable import HouseholdClient

private final class GuardianTestChildSession: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionID = "child-live-session"
    func replace() { lock.lock(); defer { lock.unlock() }; sessionID = "replacement-session" }
    func read() -> ChildInvitationAccess {
        lock.lock(); defer { lock.unlock() }
        return .init(issuer: "https://identity.test", subject: "child-subject", sessionID: sessionID, accessToken: "child-access")
    }
}

extension HouseholdClientTests {
    private var guardianEnrollmentID: String { "00000000-0000-4000-8000-000000000061" }
    private var guardianChildID: String { "00000000-0000-4000-8000-000000000062" }
    private var guardianClaimID: String { "00000000-0000-4000-8000-000000000063" }
    private var guardianInviteID: String { "00000000-0000-4000-8000-000000000064" }
    private var guardianDeviceID: String { "00000000-0000-4000-8000-000000000065" }
    private var guardianDigest: String { String(repeating: "d", count: 64) }
    private func guardianNoticeBytes(available: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["available": available,
            "reason": available ? NSNull() : "provider_configuration_required",
            "notice": ["version": "approved-v1", "digest": guardianDigest, "locale": "en", "text": "Operator-approved notice fixture.", "scope": "own_requests", "methodVersion": "approved-method-v1"]])
    }
    private func guardianEnrollmentBytes(state: GuardianEnrollmentState = .awaitingVerification, revision: Int = 1,
                                         enrollmentID: String? = nil) throws -> Data {
        let verified = [.verified, .consented, .childClaimed, .childApproved, .active].contains(state)
        let consented = [.consented, .childClaimed, .childApproved, .active].contains(state)
        let reviewedID: String = enrollmentID ?? guardianEnrollmentID
        let value: [String: Any] = ["enrollmentId": reviewedID, "revision": revision,
            "childId": guardianChildID, "state": state.rawValue, "childAlias": consented ? "Child alias" : NSNull(),
            "noticeVersion": "approved-v1", "noticeDigest": guardianDigest, "scope": "own_requests", "expiresAt": "2099-01-01T00:00:00Z",
            "verifiedAt": verified ? "2026-11-03T00:01:00Z" : NSNull(), "consentedAt": consented ? "2026-11-03T00:02:00Z" : NSNull(),
            "claimId": [.childClaimed, .childApproved, .active].contains(state) ? guardianClaimID : NSNull()]
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func guardianBytes(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private func guardianSetupResponse(_ request: URLRequest) throws -> (Int, Data)? {
        if let result = authResponse(request) { return result }
        if request.url!.path.hasSuffix("/devices") {
            return (200, try JSONSerialization.data(withJSONObject: ["deviceId": guardianDeviceID, "deviceToken": "adult-device-secret"]))
        }
        if request.url!.path.hasSuffix("/bootstrap") {
            return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": household, "label": "Home"],
                "memberId": member, "role": "organizer", "enrolled": true, "queueConsent": false, "capabilities": ["household_admin", "own_requests"]]))
        }
        return nil
    }
    private func guardianService() throws -> (HouseholdService, AdultAuth) {
        let auth = try auth()
        return (HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport()), auth)
    }
    private func guardianBinding(householdID: String? = nil) -> GuardianActorBinding {
        .init(subject: "account", householdID: householdID ?? household, memberID: member, deviceID: guardianDeviceID)
    }
    private func guardianChildJWT(issuer: String = "https://identity.test/auth/v1", subject: String = "child-account", sessionID: String) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["iss": issuer, "sub": subject, "session_id": sessionID])
        return "fixture-header." + GuardianSecret.canonical(body) + ".fixture-signature"
    }
    private func guardianChildAuthResponse(_ request: URLRequest, token: String) throws -> (Int, Data)? {
        if request.url!.path == "/auth/v1/verify" || request.url!.path == "/auth/v1/token" {
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": token, "refresh_token": "child-refresh-fixture", "expires_in": 3600,
                "user": ["id": "child-account", "email": "intended-child@example.invalid", "email_confirmed_at": "2026-11-03T00:00:00Z"]]))
        }
        if request.url!.path == "/auth/v1/user" {
            return (200, try JSONSerialization.data(withJSONObject: ["id": "child-account", "email": "intended-child@example.invalid", "email_confirmed_at": "2026-11-03T00:00:00Z"]))
        }
        return nil
    }
    private func guardianChildReceipt() throws -> ChildEnrollmentReceipt {
        try JSONDecoder().decode(ChildEnrollmentReceipt.self, from: JSONSerialization.data(withJSONObject: ["householdId": household, "memberId": guardianChildID,
            "role": "contributor", "deviceId": guardianDeviceID, "deviceToken": GuardianSecret.canonical(Data(repeating: 7, count: 32))]))
    }
    private func guardianChildBootstrap(changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["household": ["id": household, "label": "Home"], "memberId": guardianChildID,
            "role": "contributor", "enrolled": true, "queueConsent": false, "capabilities": ["own_requests"], "canSelectShop": false]
        changes.forEach { value[$0.key] = $0.value }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testGuardianSecretsAreThirtyTwoCanonicalRandomBytesAndPairingIsEightBase32Symbols() throws {
        var secrets = Set<String>(); var codes = Set<String>()
        for _ in 0..<64 {
            let secret = try GuardianSecret.generate(); XCTAssertTrue(GuardianSecret.isCanonical(secret)); secrets.insert(secret)
            let code = try GuardianPairingCode.generate(); XCTAssertTrue(GuardianPairingCode.isValid(code)); codes.insert(code)
        }
        XCTAssertEqual(secrets.count, 64); XCTAssertEqual(codes.count, 64)
        XCTAssertFalse(GuardianSecret.isCanonical(String(repeating: "a", count: 43))) // Unused base64 pad bits are nonzero.
        XCTAssertFalse(GuardianSecret.isCanonical(UUID().uuidString)); XCTAssertFalse(GuardianSecret.isCanonical(String(repeating: "A", count: 44)))
        XCTAssertFalse(GuardianPairingCode.isValid("abcd2345")); XCTAssertFalse(GuardianPairingCode.isValid("ABCD0189"))
    }

    func testGuardianIntentStorePreservesExactSecretAndRejectsTamperedBytesAndConcurrentActions() async throws {
        let enrollment = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes(state: .consented, revision: 3))
        let intent = try GuardianEnrollmentIntent(binding: guardianBinding(), kind: .childInvitation, enrollment: enrollment)
        let vault = MemoryVault(); let store = GuardianIntentStore(vault: vault); let epoch = await store.epoch()
        try await store.save(intent, expectedEpoch: epoch); try await store.save(intent, expectedEpoch: epoch)
        let restored = try await GuardianIntentStore(vault: vault).read(); XCTAssertEqual(restored, [intent])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: restored[0].bytes) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["clientKey", "baseRevision", "secret"]))
        XCTAssertTrue(GuardianSecret.isCanonical(try XCTUnwrap(value["secret"] as? String)))
        XCTAssertFalse(String(describing: intent).contains(try XCTUnwrap(value["secret"] as? String)))
        let other = try GuardianEnrollmentIntent(binding: guardianBinding(), kind: .cancel, enrollment: enrollment)
        do { try await store.save(other, expectedEpoch: epoch); XCTFail("Concurrent enrollment action retained") } catch {}
        var persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(intent)) as? [String: Any])
        persisted["bytes"] = Data("{}".utf8).base64EncodedString()
        let tampered = try JSONDecoder().decode(GuardianEnrollmentIntent.self, from: JSONSerialization.data(withJSONObject: persisted))
        XCTAssertThrowsError(try tampered.validate())
    }

    func testGuardianScopedPurgeInvalidatesLateSaveAndPreservesOtherHousehold() async throws {
        let enrollment = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes())
        let a = try GuardianEnrollmentIntent(binding: guardianBinding(), kind: .verification, enrollment: enrollment)
        let b = try GuardianEnrollmentIntent(binding: guardianBinding(householdID: UUID().uuidString.lowercased()), kind: .verification, enrollment: enrollment)
        let store = GuardianIntentStore(vault: MemoryVault()); let epoch = await store.epoch()
        try await store.save(a, expectedEpoch: epoch); try await store.save(b, expectedEpoch: epoch)
        try await store.purge(householdID: household, subject: "account")
        do { try await store.save(a, expectedEpoch: epoch); XCTFail("Late post-purge save accepted") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        let remaining = try await store.read(); XCTAssertEqual(remaining, [b])
        try await store.purge(); let empty = try await store.read(); XCTAssertTrue(empty.isEmpty)
    }

    func testGuardianNoticeAvailabilityAndDeclarationFailClosedWithoutCreatingSetup() async throws {
        let (service, auth) = try guardianService(); var mutations = 0
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            if request.url!.path.hasSuffix("/guardian/notice") { return (200, try self.guardianNoticeBytes(available: false)) }
            mutations += 1; return (500, Data())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let response = try await service.guardianNotice(language: .en); XCTAssertFalse(response.available)
        let notice = try XCTUnwrap(response.notice)
        do { _ = try await service.prepareGuardianEnrollment(notice: notice, childLocation: "US", guardianDeclaration: false); XCTFail("Missing declaration accepted") } catch {}
        do { _ = try await service.prepareGuardianEnrollment(notice: notice, childLocation: "US", guardianDeclaration: true); XCTFail("Unavailable provider accepted") } catch {}
        XCTAssertEqual(mutations, 0)
    }

    func testGuardianVerificationIsSeparateFromConsentAndRetriesOriginalRevisionAndBytes() async throws {
        let (service, auth) = try guardianService(); var bodies: [Data] = []; var readState = GuardianEnrollmentState.awaitingVerification
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            if request.httpMethod == "GET" { return (200, try self.guardianEnrollmentBytes(state: readState)) }
            XCTAssertTrue(request.url!.path.hasSuffix("/verification")); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "adult-device-secret")
            bodies.append(self.guardianBytes(request)); return (200, try self.guardianEnrollmentBytes(state: .verificationPending, revision: 2))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let reviewed = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes())
        let intent = try await service.prepareGuardianVerification(enrollment: reviewed)
        let first = try await service.executeGuardianEnrollment(intent); let second = try await service.executeGuardianEnrollment(intent)
        XCTAssertEqual(first, second); XCTAssertEqual(first.state, .verificationPending); XCTAssertNil(first.consentedAt)
        XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.bytes) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["clientKey", "baseRevision"])); XCTAssertEqual(value["baseRevision"] as? Int, 1)
        XCTAssertNil(value["email"]); XCTAssertNil(value["childAlias"])
        let notice = try XCTUnwrap(JSONDecoder().decode(GuardianNoticeResponse.self, from: guardianNoticeBytes()).notice)
        do { _ = try await service.prepareGuardianConsent(enrollment: reviewed, notice: notice, childAlias: "Child alias", childSignInEmail: "intended-child@example.invalid"); XCTFail("Proof-free consent prepared") } catch {}
        readState = .verificationUncertain
        let uncertain = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes(state: .verificationUncertain))
        do { _ = try await service.prepareGuardianVerification(enrollment: uncertain); XCTFail("Uncertain delivery prepared a fresh send") }
        catch { XCTAssertEqual(error as? ClientError, .configuration) }
        XCTAssertEqual(bodies.count, 2)
    }

    func testGuardianConsentBindsExactIntendedChildEmailOnlyAfterExplicitReviewAndRetainsExactRetry() async throws {
        let (service, auth) = try guardianService(); var bodies: [Data] = []; var lost = true
        let intendedEmail = "Intended.Child+ritc@example.invalid"
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            if request.url!.path.hasSuffix("/guardian/notice") { return (200, try self.guardianNoticeBytes()) }
            if request.httpMethod == "GET" { return (200, try self.guardianEnrollmentBytes(state: .verified, revision: 2)) }
            XCTAssertTrue(request.url!.path.hasSuffix("/consent")); XCTAssertNil(request.url!.query)
            bodies.append(self.guardianBytes(request))
            if lost { throw URLError(.networkConnectionLost) }
            return (200, try self.guardianEnrollmentBytes(state: .consented, revision: 3))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let reviewed = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes(state: .verified, revision: 2))
        let notice = try XCTUnwrap(JSONDecoder().decode(GuardianNoticeResponse.self, from: guardianNoticeBytes()).notice)
        for invalid in ["", "child", "@example.invalid", "child@", "two@@example.invalid", " child@example.invalid", "child@example.invalid\n", String(repeating: "a", count: 321) + "@example.invalid"] {
            do { _ = try await service.prepareGuardianConsent(enrollment: reviewed, notice: notice, childAlias: "Child alias", childSignInEmail: invalid); XCTFail("Invalid child sign-in address accepted") }
            catch { XCTAssertEqual(error as? ClientError, .configuration) }
        }
        XCTAssertTrue(bodies.isEmpty)
        let intent = try await service.prepareGuardianConsent(enrollment: reviewed, notice: notice, childAlias: "Child alias", childSignInEmail: intendedEmail)
        let vault = MemoryVault(); let store = GuardianIntentStore(vault: vault); let epoch = await store.epoch()
        try await store.save(intent, expectedEpoch: epoch)
        let retained = try await GuardianIntentStore(vault: vault).read(); let restored = try XCTUnwrap(retained.first)
        XCTAssertEqual(restored.childSignInEmail, intendedEmail)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.bytes) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["clientKey", "baseRevision", "noticeVersion", "noticeDigest", "childAlias", "decision", "childSignInEmail"]))
        XCTAssertEqual(body["childSignInEmail"] as? String, intendedEmail); XCTAssertEqual(body["decision"] as? String, "grant")
        XCTAssertFalse(String(describing: intent).contains(intendedEmail))
        for value in [intent, restored] {
            do { _ = try await service.executeGuardianEnrollment(value); XCTFail("Expected lost consent response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        }
        lost = false; let result = try await service.executeGuardianEnrollment(restored)
        XCTAssertEqual(result.state, .consented); XCTAssertEqual(bodies, [intent.bytes, intent.bytes, intent.bytes])
        XCTAssertThrowsError(try GuardianEnrollmentIntent(binding: guardianBinding(), kind: .consent, enrollment: reviewed, notice: notice, childAlias: "Child alias"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(intent)) as? [String: Any])
        var oldBody = try XCTUnwrap(old["body"] as? [String: Any]); oldBody.removeValue(forKey: "childSignInEmail"); old["body"] = oldBody
        old["bytes"] = try JSONSerialization.data(withJSONObject: oldBody, options: .sortedKeys).base64EncodedString()
        let unsupportedOld = try JSONDecoder().decode(GuardianEnrollmentIntent.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertThrowsError(try unsupportedOld.validate())
        let verification = try GuardianEnrollmentIntent(binding: guardianBinding(), kind: .verification, enrollment: reviewed)
        let verificationBody = try XCTUnwrap(JSONSerialization.jsonObject(with: verification.bytes) as? [String: Any]); XCTAssertNil(verificationBody["childSignInEmail"])
    }

    func testGuardianInvitationLostResponseRetriesPersistedSecretAndNeverUsesSharedOutbox() async throws {
        let (service, auth) = try guardianService(); var bodies: [Data] = []
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            if request.httpMethod == "GET" { return (200, try self.guardianEnrollmentBytes(state: .consented, revision: 3)) }
            XCTAssertTrue(request.url!.path.hasSuffix("/child-invitations")); XCTAssertNil(request.url!.query)
            bodies.append(self.guardianBytes(request)); throw URLError(.networkConnectionLost)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let reviewed = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes(state: .consented, revision: 3))
        let intent = try await service.prepareGuardianChildInvitation(enrollment: reviewed)
        let vault = MemoryVault(); let store = GuardianIntentStore(vault: vault); let epoch = await store.epoch()
        try await store.save(intent, expectedEpoch: epoch)
        let restoredIntents = try await GuardianIntentStore(vault: vault).read()
        let restored = try XCTUnwrap(restoredIntents.first)
        for retained in [intent, restored] {
            do { _ = try await service.executeGuardianChildInvitation(retained); XCTFail("Lost response expected") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        }
        XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        await service.clearScope()
        do { try await service.authorizeGuardianEnrollment(restored); XCTFail("Retained action rebound after sign-out") } catch {}
        XCTAssertEqual(bodies.count, 2)
    }

    func testGuardianRejectsStaleReviewAndWrongEnrollmentReceipt() async throws {
        let (service, auth) = try guardianService(); var stale = true
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            if request.httpMethod == "GET" { return (200, try self.guardianEnrollmentBytes(revision: stale ? 2 : 1)) }
            return (200, try self.guardianEnrollmentBytes(state: .verificationPending, revision: 2, enrollmentID: UUID().uuidString.lowercased()))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let reviewed = try JSONDecoder().decode(GuardianEnrollment.self, from: guardianEnrollmentBytes())
        do { _ = try await service.prepareGuardianVerification(enrollment: reviewed); XCTFail("Stale review accepted") }
        catch { XCTAssertEqual(error as? ClientError, .service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil)) }
        stale = false; let intent = try await service.prepareGuardianVerification(enrollment: reviewed)
        do { _ = try await service.executeGuardianEnrollment(intent); XCTFail("Wrong enrollment accepted") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }

    func testGuardianLateResultCannotRestoreClearedScope() async throws {
        let (service, auth) = try guardianService(); let held = HeldResponse(); let began = expectation(description: "guardian request in flight")
        MockURLProtocol.handler = { request in
            if let response = try self.guardianSetupResponse(request) { return response }
            return (200, try self.guardianEnrollmentBytes())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        MockURLProtocol.intercept = { proto in
            if proto.request.url!.path.hasSuffix("/guardian/enrollments/\(self.guardianEnrollmentID)") { held.set(proto); began.fulfill(); return true }; return false
        }
        let task = Task { try await service.guardianEnrollment(enrollmentID: guardianEnrollmentID) }
        await fulfillment(of: [began], timeout: 3); await service.clearScope()
        held.finish(status: 200, data: try guardianEnrollmentBytes())
        do { _ = try await task.value; XCTFail("Late guardian completion accepted") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
    }

    func testGuardianChildClaimAndFinishUseSeparateWireSchemaAndExactDeviceSecret() async throws {
        let session = GuardianTestChildSession(); var paths: [String] = []; var finishBodies: [Data] = []
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test")!), transport: transport(), access: { session.read() })
        MockURLProtocol.handler = { request in
            paths.append(request.url!.path); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer child-access")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Token")); XCTAssertNil(request.value(forHTTPHeaderField: "X-Household-ID"))
            if request.url!.path == "/v1/child-invitations/claim" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.guardianBytes(request)) as? [String: Any])
                XCTAssertEqual(Set(body.keys), Set(["clientKey", "token", "pairingCode"])); XCTAssertTrue(GuardianPairingCode.isValid(try XCTUnwrap(body["pairingCode"] as? String)))
                XCTAssertNil(body["adultAttestation"]); XCTAssertNil(body["email"]); XCTAssertNil(request.url!.query)
                return (200, try JSONSerialization.data(withJSONObject: ["householdId": self.household, "claimId": self.guardianClaimID, "status": "awaiting_guardian", "expiresAt": "2099-01-01T00:00:00Z"]))
            }
            if request.httpMethod == "GET" {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "householdId", value: self.household)])
                return (200, try JSONSerialization.data(withJSONObject: ["claimId": self.guardianClaimID, "status": "approved", "expiresAt": "2099-01-01T00:00:00Z"]))
            }
            XCTAssertEqual(request.url!.path, "/v1/child-invitations/finish")
            let bytes = self.guardianBytes(request); finishBodies.append(bytes)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(body.keys), Set(["clientKey", "householdId", "claimId", "pairingCode", "deviceSecret"]))
            let secret = try XCTUnwrap(body["deviceSecret"] as? String); XCTAssertTrue(GuardianSecret.isCanonical(secret))
            return (200, try JSONSerialization.data(withJSONObject: ["householdId": self.household, "memberId": self.guardianChildID, "role": "contributor", "deviceId": self.guardianDeviceID, "deviceToken": secret]))
        }
        let intent = try await client.prepareClaim(token: "bounded-opaque-fixture-token")
        let receipt = try await client.claim(intent)
        do { _ = try await client.prepareFinish(receipt: receipt, pairingCode: "ABCDEFG2"); XCTFail("Changed child pairing code accepted") } catch {}
        let finish = try await client.prepareFinish(receipt: receipt, pairingCode: intent.pairingCode)
        let restored = try JSONDecoder().decode(ChildInvitationIntent.self, from: encoded(finish))
        let first = try await client.finish(finish); let second = try await client.finish(restored)
        XCTAssertEqual(first, second); XCTAssertEqual(finishBodies, [finish.bytes, finish.bytes])
        XCTAssertFalse(paths.contains(where: { $0.hasSuffix("/devices") || $0 == "/v1/invites/redeem" || $0.contains("/bootstrap") }))
        session.replace()
        do { _ = try await client.finish(finish); XCTFail("Same subject with replacement session accepted") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(finishBodies.count, 2)
    }

    func testGuardianChildLateResultIsRejectedAfterLiveSessionChanges() async throws {
        let session = GuardianTestChildSession(); let held = HeldResponse(); let began = expectation(description: "child claim in flight")
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test")!), transport: transport(), access: { session.read() })
        MockURLProtocol.intercept = { proto in held.set(proto); began.fulfill(); return true }
        let intent = try await client.prepareClaim(token: "bounded-opaque-fixture-token")
        let task = Task { try await client.claim(intent) }; await fulfillment(of: [began], timeout: 3)
        session.replace()
        held.finish(status: 200, data: try JSONSerialization.data(withJSONObject: ["householdId": household, "claimId": guardianClaimID, "status": "awaiting_guardian", "expiresAt": "2099-01-01T00:00:00Z"]))
        do { _ = try await task.value; XCTFail("Late child response crossed sessions") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }

    func testGuardianNativeChallengeAndAdmissionRetryExactSecretsWithNoGenericCodeRequest() async throws {
        let childAuth = try auth(MemoryVault()); var sessionID = UUID().uuidString.lowercased(); var paths: [String] = []
        var startBodies: [Data] = []; var admitBodies: [Data] = []; var lost = true
        let challengeID = UUID().uuidString.lowercased()
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test")!), transport: transport(), access: { try await childAuth.childInvitationAccess() })
        MockURLProtocol.handler = { request in
            paths.append(request.url!.path)
            if let value = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID)) { return value }
            if request.url!.path == "/v1/child-invitations/native-auth/start" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.url!.query)
                startBodies.append(self.guardianBytes(request)); if lost { throw URLError(.networkConnectionLost) }
                return (200, try JSONSerialization.data(withJSONObject: ["householdId": self.household, "challengeId": challengeID, "status": "check_email", "expiresAt": "2099-01-01T00:00:00Z"]))
            }
            XCTAssertEqual(request.url!.path, "/v1/child-invitations/native-auth/admit")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization")); admitBodies.append(self.guardianBytes(request))
            return (200, Data(#"{"admitted":true}"#.utf8))
        }
        let start = try await client.prepareNativeAuthentication(token: "opaque-approved-invitation", email: "Intended.Child+ritc@example.invalid")
        let retainedStart = try JSONDecoder().decode(ChildNativeAuthStartIntent.self, from: encoded(start))
        let startBody = try XCTUnwrap(JSONSerialization.jsonObject(with: start.bytes) as? [String: Any])
        XCTAssertEqual(Set(startBody.keys), Set(["clientKey", "token", "email", "challengeSecret"]))
        XCTAssertTrue(GuardianSecret.isCanonical(try XCTUnwrap(startBody["challengeSecret"] as? String)))
        XCTAssertEqual(startBody["email"] as? String, "Intended.Child+ritc@example.invalid")
        do { _ = try await client.startNativeAuthentication(start); XCTFail("Expected ambiguous delivery") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        lost = false; let challenge = try await client.startNativeAuthentication(retainedStart)
        XCTAssertEqual(startBodies, [start.bytes, start.bytes])
        do { _ = try await client.prepareNativeAdmission(challenge: challenge, startIntent: retainedStart); XCTFail("Unauthenticated admission prepared") } catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
        _ = try await childAuth.verifyEmailCode(email: retainedStart.email, code: "123456")
        let admit = try await client.prepareNativeAdmission(challenge: challenge, startIntent: retainedStart)
        let retainedAdmit = try JSONDecoder().decode(ChildNativeAuthAdmitIntent.self, from: encoded(admit))
        do { _ = try await client.prepareClaim(startIntent: retainedStart, admissionIntent: retainedAdmit); XCTFail("Claim prepared before server admission") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        let admitted = try await client.admitNativeAuthentication(admit); XCTAssertTrue(admitted.admitted)
        _ = try await client.admitNativeAuthentication(retainedAdmit)
        let claim = try await client.prepareClaim(startIntent: retainedStart, admissionIntent: retainedAdmit); XCTAssertTrue(GuardianPairingCode.isValid(claim.pairingCode))
        let admitBody = try XCTUnwrap(JSONSerialization.jsonObject(with: admit.bytes) as? [String: Any])
        XCTAssertEqual(Set(admitBody.keys), Set(["clientKey", "householdId", "challengeId", "challengeSecret"]))
        XCTAssertEqual(admitBody["challengeSecret"] as? String, startBody["challengeSecret"] as? String)
        XCTAssertEqual(admitBodies, [admit.bytes, admit.bytes]); XCTAssertFalse(paths.contains("/auth/v1/otp"))
        sessionID = UUID().uuidString.lowercased(); _ = try await childAuth.verifyEmailCode(email: retainedStart.email, code: "654321")
        do { _ = try await client.admitNativeAuthentication(retainedAdmit); XCTFail("Admission rebound to replacement child session") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(admitBodies.count, 2)
    }

    func testGuardianNativeChallengeLateResultCannotReviveAfterClose() async throws {
        let held = HeldResponse(); let began = expectation(description: "native child challenge in flight")
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test")!), transport: transport(), access: { throw ClientError.sessionNeeded })
        MockURLProtocol.intercept = { proto in held.set(proto); began.fulfill(); return true }
        let intent = try await client.prepareNativeAuthentication(token: "opaque-approved-invitation", email: "child@example.invalid")
        let task = Task { try await client.startNativeAuthentication(intent) }; await fulfillment(of: [began], timeout: 3)
        await client.close()
        held.finish(status: 200, data: try JSONSerialization.data(withJSONObject: ["householdId": household, "challengeId": UUID().uuidString.lowercased(), "status": "check_email", "expiresAt": "2099-01-01T00:00:00Z"]))
        do { _ = try await task.value; XCTFail("Closed challenge completion accepted") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
    }

    func testGuardianChildContinuityProjectionRequiresVerifiedUserAndStrictIssuerSubjectSession() async throws {
        let sessionID = UUID().uuidString.lowercased()
        for invalid in [try guardianChildJWT(issuer: "https://other.test/auth/v1", sessionID: sessionID),
                        try guardianChildJWT(subject: "other-child", sessionID: sessionID),
                        try guardianChildJWT(sessionID: "not-a-session-uuid"), "opaque-provider-token"] {
            let childAuth = try auth(); var userVerified = false
            MockURLProtocol.handler = { request in
                if request.url!.path == "/auth/v1/user" { userVerified = true }
                return try XCTUnwrap(self.guardianChildAuthResponse(request, token: invalid))
            }
            _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456")
            XCTAssertTrue(userVerified)
            do { _ = try await childAuth.childInvitationAccess(); XCTFail("Invalid continuity projection accepted") } catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
        }
    }

    func testGuardianChildCredentialAdoptionPersistsOnlyAfterOwnScopeBootstrapAndNeverRegistersDevice() async throws {
        let childAuth = try auth(); let vault = MemoryVault(); let receipt = try guardianChildReceipt(); let sessionID = UUID().uuidString.lowercased()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            if let result = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID)) { return result }
            paths.append(request.url!.path)
            if paths.count == 1 { XCTAssertNil(try vault.read()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), receipt.deviceToken)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Household-ID"), self.household)
            XCTAssertTrue(request.url!.path.hasSuffix("/bootstrap")); return (200, try self.guardianChildBootstrap())
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456"); let access = try await childAuth.childInvitationAccess()
        let scope = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        XCTAssertEqual(scope.memberId, guardianChildID); XCTAssertEqual(scope.capabilities, ["own_requests"])
        XCTAssertNotNil(try vault.read()); XCTAssertEqual(paths, ["/v1/households/\(household)/bootstrap"])
        let installed = try vault.read()
        // Installation may succeed immediately before the UI callback is cancelled; retry the exact finish receipt on the same actor.
        let recovered = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        XCTAssertEqual(recovered, scope); XCTAssertEqual(try vault.read(), installed)
        XCTAssertEqual(paths, ["/v1/households/\(household)/bootstrap", "/v1/households/\(household)/bootstrap"])
    }

    func testGuardianChildRequestPickupsPageUsesOnlyOwnScopeAndStopsAtSessionChange() async throws {
        let childAuth = try auth(), vault = MemoryVault(), receipt = try guardianChildReceipt()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: childAuth, deviceVault: vault, transport: transport())
        let first = UUID(), second = UUID(), timestamp = "2026-11-14T14:00:00.000Z"
        let base = "/v1/households/\(household)/"
        var session = UUID().uuidString.lowercased(), paths: [String] = []
        let began = expectation(description: "request pickups in flight"), held = HeldResponse()
        MockURLProtocol.handler = { request in
            if let response = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: session)) { return response }
            paths.append(request.url!.path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), receipt.deviceToken)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Household-ID"), self.household)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-View-Grant-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Shop-ID"))
            if request.url!.path == base + "bootstrap" { return (200, try self.guardianChildBootstrap(changes: ["selectionRequired": true])) }
            XCTAssertEqual(request.url!.path, base + "requests/pickups")
            let later = request.url!.query != nil
            if later { XCTAssertEqual(request.url!.query, "cursor=" + first.uuidString.lowercased()) }
            let page: [String: Any] = ["shops": [["shopId": (later ? second : first).uuidString,
                                                   "createdAt": timestamp, "nextShopOnly": later]],
                                       "nextCursor": later ? NSNull() as Any : first.uuidString as Any]
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456")
        let access = try await childAuth.childInvitationAccess()
        _ = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        let firstPage = try await service.requestPickups()
        XCTAssertEqual(firstPage, .init(shops: [.init(shopId: first, createdAt: timestamp, nextShopOnly: false)], nextCursor: first))
        let secondPage = try await service.requestPickups(cursor: firstPage.nextCursor)
        XCTAssertEqual(secondPage, .init(shops: [.init(shopId: second, createdAt: timestamp, nextShopOnly: true)], nextCursor: nil))
        do { _ = try await service.selectableShops(closedAndOwned: false, cursor: nil); XCTFail("Child listed adult shops") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.selectShop(first); XCTFail("Child selected an adult shop") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.guardianConsents(); XCTFail("Child accessed guardian consents") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.enroll(householdID: household); XCTFail("Adult enrollment replaced child binding") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(paths, [base + "bootstrap", base + "requests/pickups", base + "requests/pickups"])
        MockURLProtocol.intercept = { instance in
            guard instance.request.url?.path == base + "requests/pickups" else { return false }
            held.set(instance); began.fulfill(); return true
        }
        let task = Task { try await service.requestPickups() }
        await fulfillment(of: [began], timeout: 3)
        session = UUID().uuidString.lowercased()
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "654321")
        held.finish(status: 200, data: Data(#"{"shops":[],"nextCursor":null}"#.utf8))
        do { _ = try await task.value; XCTFail("Pickup page crossed child sessions") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }

    func testGuardianChildCanRevokeOwnDeviceAndSignOutAfterReadingRequestPickups() async throws {
        let childAuth = try auth(), session = UUID().uuidString.lowercased(), receipt = try guardianChildReceipt()
        let vault = MemoryVault()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: childAuth, deviceVault: vault, transport: transport())
        let token = try guardianChildJWT(sessionID: session)
        let base = "/v1/households/\(household)/"
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            if let response = try self.guardianChildAuthResponse(request, token: token) { return response }
            let path = try XCTUnwrap(request.url).path
            paths.append(path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            if path == "/auth/v1/logout" {
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.query, "scope=local")
                return (200, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), receipt.deviceToken)
            if path == base + "bootstrap" { return (200, try self.guardianChildBootstrap()) }
            if path == base + "requests/pickups" { return (200, Data(#"{"shops":[],"nextCursor":null}"#.utf8)) }
            XCTAssertEqual(path, base + "devices/current"); XCTAssertEqual(request.httpMethod, "DELETE")
            return (204, Data())
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456")
        let access = try await childAuth.childInvitationAccess()
        _ = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        _ = try await service.requestPickups()
        try await service.revokeCurrentDevice()
        try await childAuth.signOut()
        XCTAssertNil(try vault.read())
        XCTAssertEqual(paths, [base + "bootstrap", base + "requests/pickups", base + "devices/current", "/auth/v1/logout"])
    }

    func testRequestPickupPageRejectsUnexpectedFieldsAndMalformedPagination() throws {
        let shop = UUID().uuidString
        let row: [String: Any] = ["shopId": shop, "createdAt": "2026-11-14T14:00:00Z", "nextShopOnly": false]
        let malformed: [[String: Any]] = [
            ["shops": [row]],
            ["shops": [], "nextCursor": shop],
            ["shops": [row], "nextCursor": UUID().uuidString],
            ["shops": [row, row], "nextCursor": NSNull()],
            ["shops": [row], "nextCursor": NSNull(), "shopper": "private"],
            ["shops": [row.merging(["phase": "draft"]) { $1 }], "nextCursor": NSNull()],
            ["shops": [row.merging(["createdAt": "yesterday"]) { $1 }], "nextCursor": NSNull()],
            ["shops": [row.merging(["nextShopOnly": "false"]) { $1 }], "nextCursor": NSNull()]
        ]
        for value in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(RequestPickupPage.self, from: JSONSerialization.data(withJSONObject: value)))
        }
    }

    func testGuardianChildCredentialAdoptionRejectsWrongSessionBootstrapAndUnrelatedVaultWithoutWriting() async throws {
        let childAuth = try auth(); let sessionID = UUID().uuidString.lowercased(); let receipt = try guardianChildReceipt()
        var bootstrapChanges: [String: Any] = [:]; var bootstrapCalls = 0
        MockURLProtocol.handler = { request in
            if let result = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID)) { return result }
            bootstrapCalls += 1; XCTAssertTrue(request.url!.path.hasSuffix("/bootstrap")); return (200, try self.guardianChildBootstrap(changes: bootstrapChanges))
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456"); let access = try await childAuth.childInvitationAccess()
        let wrong = ChildInvitationAccess(issuer: access.issuer, subject: access.subject, sessionID: UUID().uuidString.lowercased(), accessToken: access.accessToken)
        let vault = MemoryVault(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        do { _ = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: wrong); XCTFail("Wrong child session adopted") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(bootstrapCalls, 0); XCTAssertNil(try vault.read())
        let invalidBootstraps: [[String: Any]] = [["role": "organizer"], ["memberId": UUID().uuidString.lowercased()],
            ["household": ["id": UUID().uuidString.lowercased(), "label": "Other"]], ["capabilities": ["own_requests", "store_quotes"]],
            ["capabilities": ["own_requests", "household_admin"]], ["grantId": UUID().uuidString.lowercased()], ["canSelectShop": true]]
        for invalid in invalidBootstraps {
            bootstrapChanges = invalid
            do { _ = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access); XCTFail("Broader or mismatched bootstrap adopted") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
            XCTAssertNil(try vault.read())
        }
        try vault.write("unrelated-adult-device-vault-fixture")
        let before = bootstrapCalls
        do { _ = try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access); XCTFail("Unrelated vault overwritten") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(try vault.read(), "unrelated-adult-device-vault-fixture"); XCTAssertEqual(bootstrapCalls, before)
    }

    func testGuardianChildCredentialAdoptionLateBootstrapCannotPersistAfterClose() async throws {
        let childAuth = try auth(); let vault = MemoryVault(); let receipt = try guardianChildReceipt(); let sessionID = UUID().uuidString.lowercased()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        let held = HeldResponse(); let began = expectation(description: "child adoption bootstrap in flight")
        MockURLProtocol.handler = { request in try XCTUnwrap(self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID))) }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456"); let access = try await childAuth.childInvitationAccess()
        MockURLProtocol.intercept = { proto in
            if proto.request.url!.path.hasSuffix("/bootstrap") { held.set(proto); began.fulfill(); return true }; return false
        }
        let task = Task { try await service.adoptChildEnrollment(receipt: receipt, expectedAccess: access) }
        await fulfillment(of: [began], timeout: 3); await service.clearScope(); held.finish(status: 200, data: try guardianChildBootstrap())
        do { _ = try await task.value; XCTFail("Late child bootstrap persisted after close") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        XCTAssertNil(try vault.read())
    }

    func testGuardianChildCredentialColdLaunchResumeRefreshesSameSessionAndPreservesValidatedMarker() async throws {
        let authVault = MemoryVault(); let childAuth = try auth(authVault); let vault = MemoryVault()
        let receipt = try guardianChildReceipt(); let sessionID = UUID().uuidString.lowercased(); var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url!.path)
            if let result = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID)) { return result }
            XCTAssertEqual(request.url!.path, "/v1/households/\(self.household)/bootstrap")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), receipt.deviceToken)
            return (200, try self.guardianChildBootstrap())
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456")
        let access = try await childAuth.childInvitationAccess()
        let first = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        _ = try await first.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        let restartedAuth = try auth(authVault)
        let restarted = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: restartedAuth, deviceVault: vault, transport: transport())
        let refreshed = try await restartedAuth.childInvitationAccess()
        XCTAssertEqual(refreshed.binding, access.binding)
        let resumed = try await restarted.resumeChildEnrollment(expectedAccess: refreshed)
        XCTAssertEqual(resumed.memberId, guardianChildID); XCTAssertEqual(resumed.capabilities, ["own_requests"])
        _ = try await restarted.bootstrap()
        let stored = try XCTUnwrap(try vault.read())
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        XCTAssertEqual(record["childMemberID"] as? String, guardianChildID)
        XCTAssertEqual((record["childBinding"] as? [String: Any])?["sessionID"] as? String, sessionID)
        XCTAssertTrue(paths.contains("/auth/v1/token")); XCTAssertFalse(paths.contains(where: { $0.hasSuffix("/devices") }))
    }

    func testGuardianChildCredentialResumeRejectsMissingForeignTamperedMarkersAndReplacedSession() async throws {
        let childAuth = try auth(); let vault = MemoryVault(); let receipt = try guardianChildReceipt()
        var sessionID = UUID().uuidString.lowercased(); var bootstrapCalls = 0
        MockURLProtocol.handler = { request in
            if let result = try self.guardianChildAuthResponse(request, token: self.guardianChildJWT(sessionID: sessionID)) { return result }
            bootstrapCalls += 1; XCTAssertTrue(request.url!.path.hasSuffix("/bootstrap"))
            guard request.value(forHTTPHeaderField: "X-Device-Token") == receipt.deviceToken else { return (403, Data()) }
            return (200, try self.guardianChildBootstrap())
        }
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "123456"); let access = try await childAuth.childInvitationAccess()
        let first = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        _ = try await first.adoptChildEnrollment(receipt: receipt, expectedAccess: access)
        let original = try XCTUnwrap(try vault.read())
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let binding = try XCTUnwrap(record["childBinding"] as? [String: Any])
        var missingBinding = record; missingBinding.removeValue(forKey: "childBinding")
        var missingMember = record; missingMember.removeValue(forKey: "childMemberID")
        var foreign = record; var foreignBinding = binding; foreignBinding["sessionID"] = UUID().uuidString.lowercased(); foreign["childBinding"] = foreignBinding
        var tampered = record; tampered["childMemberID"] = UUID().uuidString.lowercased()
        for invalid in [missingBinding, missingMember, foreign, tampered] {
            let stored = String(decoding: try JSONSerialization.data(withJSONObject: invalid, options: .sortedKeys), as: UTF8.self)
            try vault.write(stored)
            let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
            do { _ = try await service.resumeChildEnrollment(expectedAccess: access); XCTFail("Invalid child marker resumed") } catch {}
            XCTAssertEqual(try vault.read(), stored)
        }
        try vault.clear()
        let missing = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        let before = bootstrapCalls
        do { _ = try await missing.resumeChildEnrollment(expectedAccess: access); XCTFail("Missing child device registered implicitly") } catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
        XCTAssertEqual(bootstrapCalls, before)
        try vault.write(original); sessionID = UUID().uuidString.lowercased()
        _ = try await childAuth.verifyEmailCode(email: "child@example.invalid", code: "654321")
        let replaced = try await childAuth.childInvitationAccess()
        let restarted = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: childAuth, deviceVault: vault, transport: transport())
        do { _ = try await restarted.resumeChildEnrollment(expectedAccess: replaced); XCTFail("Child credential rebound to replacement session") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await restarted.resumeChildEnrollment(expectedAccess: access); XCTFail("Old marker bypassed current session") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(try vault.read(), original); XCTAssertEqual(bootstrapCalls, before)
    }

    func testGuardianPublicAvailabilityUsesOnlyConfiguredOriginAndNoAuthenticatedIdentity() async throws {
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test/api")!), transport: transport(), access: { XCTFail("Public availability requested a child identity"); throw ClientError.sessionNeeded })
        var response = Data(#"{"available":false,"reason":"provider_configuration_required"}"#.utf8)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.absoluteString, "https://service.test/api/v1/guardian/availability?language=es")
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Token")); XCTAssertNil(request.value(forHTTPHeaderField: "X-CSRF-Token"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return (200, response)
        }
        let unavailable = try await client.childEnrollmentAvailability(language: .es)
        XCTAssertFalse(unavailable.available); XCTAssertEqual(unavailable.reason, .providerConfigurationRequired)
        response = Data(#"{"available":false,"reason":"notice_approval_required"}"#.utf8)
        let unapproved = try await client.childEnrollmentAvailability(language: .es); XCTAssertEqual(unapproved.reason, .noticeApprovalRequired)
        response = Data(#"{"available":true,"reason":null}"#.utf8)
        let available = try await client.childEnrollmentAvailability(language: .es); XCTAssertTrue(available.available); XCTAssertNil(available.reason)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(available)) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), Set(["available", "reason"])); XCTAssertTrue(wire["reason"] is NSNull)
    }

    func testGuardianPublicAvailabilityRejectsMalformedInconsistentAndLateResponses() async throws {
        let client = ChildInvitationClient(configuration: try .init(baseURL: URL(string: "https://service.test")!), transport: transport(), access: { throw ClientError.sessionNeeded })
        var response = Data()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.absoluteString, "https://service.test/v1/guardian/availability?language=en")
            return (200, response)
        }
        for invalid in [#"{"available":true,"reason":"provider_configuration_required"}"#,
            #"{"available":false,"reason":null}"#, #"{"available":true}"#,
            #"{"available":false,"reason":"unrecognized_configuration"}"#] {
            response = Data(invalid.utf8)
            do { _ = try await client.childEnrollmentAvailability(language: .en); XCTFail("Invalid readiness accepted") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
        let held = HeldResponse(); let began = expectation(description: "public availability in flight")
        MockURLProtocol.intercept = { proto in held.set(proto); began.fulfill(); return true }
        let task = Task { try await client.childEnrollmentAvailability(language: .en) }
        await fulfillment(of: [began], timeout: 3); await client.close()
        held.finish(status: 200, data: Data(#"{"available":true,"reason":null}"#.utf8))
        do { _ = try await task.value; XCTFail("Late readiness revived a closed flow") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
    }
}
