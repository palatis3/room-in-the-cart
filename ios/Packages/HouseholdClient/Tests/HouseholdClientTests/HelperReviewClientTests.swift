import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var reviewGrant: String { "00000000-0000-4000-8000-000000000031" }
    private var reviewShop: String { "00000000-0000-4000-8000-000000000032" }
    private var reviewProposal: String { "00000000-0000-4000-8000-000000000033" }
    private var reviewMutation: String { "00000000-0000-4000-8000-000000000034" }
    private func reviewProjection(revision: Int = 1) throws -> ManagedHelperProjection {
        let projection = try HelperProjection(shopLabel: "  Exact reviewed text  ", language: "en", items: [.init(label: "Rice", amount: nil, unit: " bag ", action: " Save two. ")])
        return ManagedHelperProjection(grantId: reviewGrant, shopId: reviewShop, revision: revision,
            asOf: "2026-11-03T00:00:00.000Z", expiresAt: "2099-01-01T00:00:00.000Z", mode: "edit", projection: projection)
    }
    private func reviewProposalValue() throws -> HelperProposal {
        try JSONDecoder().decode(HelperProposal.self, from: JSONSerialization.data(withJSONObject: [
            "proposalId": reviewProposal, "grantId": reviewGrant, "baseRevision": 1, "proposalRevision": 1,
            "correction": "Untrusted suggestion", "status": "pending", "createdAt": "2026-11-03T00:00:00.000Z", "resolution": NSNull()]))
    }
    private func reviewIntent(proposal: Bool = false, decision: HelperReviewDecision = .replace) throws -> HelperReviewIntent {
        let current = try reviewProjection()
        return try HelperReviewIntent(subject: "account", householdID: household, memberID: member, deviceID: "device",
            current: current, proposal: proposal ? reviewProposalValue() : nil, decision: decision,
            projection: decision == .replace ? current.projection : nil)
    }
    private func reviewBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    func testReviewIntentsEncodeOnlyExactDiscriminatedFieldsAndPersistLegacyState() async throws {
        for proposal in [false, true] {
            for decision in [HelperReviewDecision.replace, .dismiss] where proposal || decision == .replace {
                let intent = try reviewIntent(proposal: proposal, decision: decision)
                try intent.validate()
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.bytes) as? [String: Any])
                var keys = Set(["clientKey", "baseRevision"])
                if proposal { keys.formUnion(["proposalRevision", "decision"]) }
                if decision == .replace { keys.insert("projection") }
                XCTAssertEqual(Set(json.keys), keys)
                if decision == .replace {
                    let projection = try XCTUnwrap(json["projection"] as? [String: Any])
                    XCTAssertEqual(projection["shopLabel"] as? String, "  Exact reviewed text  ")
                    let item = try XCTUnwrap((projection["items"] as? [[String: Any]])?.first)
                    XCTAssertTrue(item["amount"] is NSNull); XCTAssertEqual(item["unit"] as? String, " bag ")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = LifecycleIntentStore(url: directory.appendingPathComponent("state.json"))
                let epoch = await store.reviewEpoch()
                try await store.saveReviewAction(intent, expectedEpoch: epoch)
                let restored = try await store.read(); XCTAssertEqual(restored.reviewActions, [intent])
            }
        }
        let old = try JSONDecoder().decode(LifecyclePendingState.self, from: Data(#"{"proposals":[]}"#.utf8))
        XCTAssertNil(old.reviewActions)
        let whitespace = try HelperProjection(shopLabel: " \n ", language: "en", items: [])
        XCTAssertThrowsError(try whitespace.validateReviewed())
        let oversizedUTF16 = try HelperProjection(shopLabel: String(repeating: "😀", count: 41), language: "en", items: [])
        XCTAssertThrowsError(try oversizedUTF16.validateReviewed())
    }
    func testReviewReceiptRejectsWrongScopeRevisionAndResolution() throws {
        let intent = try reviewIntent(proposal: true, decision: .dismiss)
        var value: [String: Any] = ["mutationId": reviewMutation, "grantId": reviewGrant, "proposalId": reviewProposal,
            "proposalRevision": 2, "baseRevision": 1, "revision": 1, "status": "dismissed", "resolution": "dismissed", "resolvedAt": "2026-11-03T00:00:00.000Z"]
        func receipt(_ input: [String: Any]) throws -> HelperReviewReceipt { try JSONDecoder().decode(HelperReviewReceipt.self, from: JSONSerialization.data(withJSONObject: input)) }
        try receipt(value).validate(for: intent)
        for (key, invalid) in [("grantId", reviewShop as Any), ("proposalRevision", 1 as Any), ("revision", 2 as Any), ("resolution", "replaced" as Any), ("resolvedAt", "invalid" as Any)] {
            var changed = value; changed[key] = invalid
            XCTAssertThrowsError(try receipt(changed).validate(for: intent), key)
        }
        value["asOf"] = "2026-11-03T00:00:00.000Z"
        XCTAssertThrowsError(try receipt(value).validate(for: intent))
    }
    func testReviewRetryReconcilesOriginalBytesAfterRevisionAdvancesAndStopsAfterAuthorityLoss() async throws {
        let auth = try auth(); var bodies: [Data] = []; var currentRevision = 1; var role = "shopper"
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") { return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": role, "shopId": self.reviewShop, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            XCTAssertNil(request.value(forHTTPHeaderField: "X-View-Grant-ID"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "device-token")
            if path.hasSuffix("/views/\(self.reviewGrant)") { return (200, try encoded(self.reviewProjection(revision: currentRevision))) }
            XCTAssertEqual(path, "/v1/households/\(self.household)/views/\(self.reviewGrant)/replacements")
            bodies.append(self.reviewBody(request))
            if bodies.count == 1 { currentRevision = 2; throw URLError(.networkConnectionLost) }
            return (200, try JSONSerialization.data(withJSONObject: ["mutationId": self.reviewMutation, "grantId": self.reviewGrant, "baseRevision": 1, "revision": 2, "status": "replaced", "asOf": "2026-11-03T00:00:00.000Z"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let current = try await service.managedHelperProjection(grantID: reviewGrant, shopID: reviewShop)
        let intent = try await service.prepareHelperReview(current: current, decision: .replace, projection: current.projection)
        do { _ = try await service.executeHelperReview(intent); XCTFail("Expected lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let receipt = try await service.reconcileHelperReview(intent)
        XCTAssertEqual(receipt.revision, 2); XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        role = "contributor"
        do { _ = try await service.executeHelperReview(intent); XCTFail("Former shopper retried") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(bodies.count, 2)
    }
    func testReviewTamperedStoredBytesAndWrongIdentityNeverSend() async throws {
        let original = try reviewIntent()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(original)) as? [String: Any])
        value["bytes"] = Data("{}".utf8).base64EncodedString()
        let changed = try JSONDecoder().decode(HelperReviewIntent.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try changed.validate())
        let auth = try auth(); var networkCalls = 0
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { _ in networkCalls += 1; throw URLError(.badURL) }
        do { _ = try await service.executeHelperReview(original); XCTFail("Unenrolled replay") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(networkCalls, 0)
    }
}


extension HouseholdClientTests {
    func testReviewStoreAtomicallyPreservesOtherIntentsAndRejectsPrePurgeEpoch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LifecycleIntentStore(url: directory.appendingPathComponent("state.json"))
        let membership = try MembershipIntent.create(subject: "account", label: "Home", alias: "Adult", adultAttestation: true)
        try await store.save(.init(membership: membership))
        let epoch = await store.reviewEpoch(), first = try reviewIntent(), second = try reviewIntent(proposal: true, decision: .dismiss)
        try await store.saveReviewAction(first, expectedEpoch: epoch)
        do { try await store.saveReviewAction(second, expectedEpoch: epoch); XCTFail("Competing review was queued") }
        catch { XCTAssertEqual(error as? ClientError, .service(status: 409, code: "helper_review_pending", correlationID: nil, retryAfter: nil)) }
        try await store.saveReviewAction(first, expectedEpoch: epoch)
        let saved = try await store.read()
        XCTAssertEqual(saved.reviewActions, [first]); XCTAssertEqual(saved.membership, membership)
        try await store.removeReviewAction(id: first.id)
        try await store.saveReviewAction(second, expectedEpoch: epoch)
        let remaining = try await store.read(); XCTAssertEqual(remaining.reviewActions, [second]); XCTAssertEqual(remaining.membership, membership)
        try await store.purge()
        do { try await store.saveReviewAction(first, expectedEpoch: epoch); XCTFail("Pre-purge save recreated private text") }
        catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        let purged = try await store.read(); XCTAssertNil(purged.reviewActions)
        let newEpoch = await store.reviewEpoch(); XCTAssertNotEqual(epoch, newEpoch)
    }
    func testResolutionRouteUsesProposalRevisionAndRejectsMismatchedReceipt() async throws {
        let auth = try auth(); var sent: [Data] = []; var wrongReceipt = false
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") { return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": self.reviewShop, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/views/\(self.reviewGrant)") { return (200, try encoded(self.reviewProjection())) }
            if path.hasSuffix("/proposals/\(self.reviewProposal)") { return (200, try encoded(self.reviewProposalValue())) }
            XCTAssertEqual(path, "/v1/households/\(self.household)/views/\(self.reviewGrant)/proposals/\(self.reviewProposal)/resolve")
            sent.append(self.reviewBody(request))
            return (200, try JSONSerialization.data(withJSONObject: ["mutationId": self.reviewMutation, "grantId": self.reviewGrant, "proposalId": self.reviewProposal, "proposalRevision": wrongReceipt ? 1 : 2, "baseRevision": 1, "revision": 1, "status": "dismissed", "resolution": "dismissed", "resolvedAt": "2026-11-03T00:00:00.000Z"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let current = try await service.managedHelperProjection(grantID: reviewGrant, shopID: reviewShop)
        let proposal = try await service.managedHelperProposal(grantID: reviewGrant, proposalID: reviewProposal, shopID: reviewShop)
        let intent = try await service.prepareHelperReview(current: current, proposal: proposal, decision: .dismiss)
        let receipt = try await service.executeHelperReview(intent)
        XCTAssertEqual(receipt.resolution, "dismissed"); XCTAssertEqual(receipt.revision, 1)
        wrongReceipt = true
        do { _ = try await service.executeHelperReview(intent); XCTFail("Accepted wrong proposal revision") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        XCTAssertEqual(sent, [intent.bytes, intent.bytes])
    }
}


extension HouseholdClientTests {
    func testLegacySnapshotSaveCannotEraseOrResurrectReviewActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LifecycleIntentStore(url: directory.appendingPathComponent("state.json"))
        var olderSnapshot = try await store.read()
        let intent = try reviewIntent()
        let epoch = await store.reviewEpoch()
        try await store.saveReviewAction(intent, expectedEpoch: epoch)
        olderSnapshot.membership = try MembershipIntent.create(subject: "account", label: "Home", alias: "Adult", adultAttestation: true)
        try await store.save(olderSnapshot)
        let merged = try await store.read()
        XCTAssertEqual(merged.reviewActions, [intent]); XCTAssertEqual(merged.membership, olderSnapshot.membership)
        try await store.purge()
        try await store.save(merged)
        let afterPurge = try await store.read()
        XCTAssertNil(afterPurge.reviewActions)
        // A stale snapshot cannot overwrite a subsequent action either.
        let freshIntent = try reviewIntent(proposal: true, decision: .dismiss)
        let freshEpoch = await store.reviewEpoch()
        try await store.saveReviewAction(freshIntent, expectedEpoch: freshEpoch)
        try await store.save(merged)
        let afterFreshAction = try await store.read()
        XCTAssertEqual(afterFreshAction.reviewActions, [freshIntent])
        try await store.removeReviewAction(id: freshIntent.id)
        try await store.save(afterFreshAction)
        let afterRemoval = try await store.read()
        XCTAssertEqual(afterRemoval.reviewActions, [])
    }
}
