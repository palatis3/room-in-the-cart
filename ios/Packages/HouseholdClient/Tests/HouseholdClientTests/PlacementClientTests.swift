import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var placementShopID: String { "00000000-0000-4000-8000-000000000063" }
    private var placementKey: String { "00000000-0000-4000-8000-000000000061" }
    private var placementWindow: ReplayWindow { .init(id: "00000000-0000-4000-8000-000000000062", expiresAt: "2099-01-01T00:00:00Z") }
    private var placementDate: String { "2026-11-03T00:00:00Z" }
    private var placementReportID: String { "00000000-0000-4000-8000-000000000064" }
    private var placementOperationID: String { "00000000-0000-4000-8000-000000000065" }
    private func placementShopValue() throws -> ShopperShop {
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 5000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0,
            observedAt: Date(timeIntervalSince1970: 1_790_000_000), expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        return .init(shopId: placementShopID, shopRevision: 4, authorityEpoch: 2, phase: "frozen", meals: nil, quote: quote,
            lines: [.init(lineId: UUID(uuidString: "00000000-0000-4000-8000-000000000066")!, originalItem: "Original dated basket", packs: 1, unitPriceMinor: 3720, feeEligible: true)], frozenRevision: 4, placedRevision: nil)
    }
    private func placementCapture() throws -> PlacementPreparedSnapshot {
        try .init(id: placementKey, subject: "account", householdID: household, memberID: member, deviceID: "device", snapshot: placementShopValue(), replayWindow: placementWindow, capturedAt: "2026-11-02T23:59:00Z")
    }
    private func placementPending() throws -> PlacementPendingReport {
        let shop = try placementShopValue()
        let budget = ShopperBudget(currency: "USD", totalMinor: 3720, overCapMinor: 0, headroomMinor: 1280, status: "withinCap", scope: "wholeCheckout", missing: [], lowerBoundMinor: 3720, upperBoundMinor: 3720, wholeCheckoutWithinCap: true)
        let snapshot = PlacementReportedSnapshot(shopId: shop.shopId, revision: 4, phase: "frozen", quote: shop.quote, lines: shop.lines, budget: budget)
        return .init(reportId: placementReportID, shopId: placementShopID, reportedRevision: 4, reportedAuthorityEpoch: 2, occurredAt: placementDate, receivedAt: placementDate,
            state: "pending_reconciliation", snapshot: snapshot, snapshotCreatedAt: "2026-11-02T23:59:00Z", snapshotDigest: String(repeating: "a", count: 64))
    }
    private func placementBootstrap(shopID: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["household": ["id": household, "label": "Home"], "memberId": member, "role": "shopper", "shopId": shopID ?? placementShopID,
            "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])
    }
    private func placementBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }; stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
    func testPlacementOfflineSealMatchesServerDigestAndPreservesOriginalWindowTimeAndSnapshot() throws {
        let capture = try placementCapture(), report = try capture.report(occurredAt: placementDate)
        XCTAssertEqual(report.commandDigest, "2c5085b9ab57695f68a2164a13508eb7b1a511f08aeaa6417a1fd357df7a1218")
        let restored = try JSONDecoder().decode(PlacementReportIntent.self, from: encoded(report)); try restored.validate()
        XCTAssertEqual(restored, report); XCTAssertEqual(restored.prepared.snapshot.lines.first?.originalItem, "Original dated basket")
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: report.bytes)
        XCTAssertEqual(envelope.replayWindow, placementWindow.id); XCTAssertEqual(envelope.base, .init(shopRevision: 4, authorityEpoch: 2))
        XCTAssertEqual(envelope.body, ["occurredAt": .string(placementDate)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(report)) as? [String: Any]); json["occurredAt"] = "2026-11-03T00:00:01Z"
        XCTAssertThrowsError(try JSONDecoder().decode(PlacementReportIntent.self, from: JSONSerialization.data(withJSONObject: json)).validate())
        let changed = try capture.report(occurredAt: "2026-11-03T00:00:01Z"); XCTAssertEqual(changed.id, report.id); XCTAssertNotEqual(changed.bytes, report.bytes)
    }
    func testPlacementReporterUsesOriginalShopAfterSelectionChangeAndNeverRefreshesShopOrWindowOnRetry() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let other = UUID().uuidString.lowercased(), report = try placementCapture().report(occurredAt: placementDate)
        var bootstraps = 0, bodies: [Data] = [], expired = false
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") { bootstraps += 1; return (200, try self.placementBootstrap(shopID: request.value(forHTTPHeaderField: "X-Shop-ID"))) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shop-ID"), self.placementShopID)
            if path.hasSuffix("/commands") {
                bodies.append(self.placementBody(request))
                if expired { return (409, Data(#"{"error":{"code":"refresh_required"}}"#.utf8)) }
                if bodies.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, try encoded(PlacementReporterReceipt(operationId: self.placementOperationID, reportId: self.placementReportID, disposition: "pending_reconciliation")))
            }
            XCTAssertEqual(path, "/v1/households/\(self.household)/shops/\(self.placementShopID)/placement-reports/mine/\(report.id)")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "commandDigest", value: report.commandDigest)])
            let status = PlacementReporterStatus(clientKey: report.id, operationId: self.placementOperationID, reportId: self.placementReportID, shopId: self.placementShopID,
                reportedRevision: 4, reportedAuthorityEpoch: 2, occurredAt: self.placementDate, receivedAt: self.placementDate, state: "applied")
            return (200, try JSONSerialization.data(withJSONObject: ["status": JSONSerialization.jsonObject(with: encoded(status))]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        _ = try await service.selectShop(UUID(uuidString: other))
        let before = bootstraps
        do { _ = try await service.executePlacementReport(report); XCTFail("Lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let receipt = try await service.executePlacementReport(report); XCTAssertEqual(receipt.disposition, "pending_reconciliation")
        expired = true
        do { _ = try await service.executePlacementReport(report); XCTFail("Expired replay") } catch { XCTAssertEqual(error as? ClientError, .service(status: 409, code: "refresh_required", correlationID: nil, retryAfter: nil)) }
        let status = try await service.placementReportStatus(report); XCTAssertEqual(status?.state, "applied")
        XCTAssertEqual(bootstraps, before); XCTAssertEqual(bodies, [report.bytes, report.bytes, report.bytes])
        let current = try await service.bootstrap(); XCTAssertEqual(current.shopId, other)
    }
    func testPlacementMinimalReporterDTOsRejectUnexpectedCurrentBudgetFields() throws {
        let receipt = PlacementReporterReceipt(operationId: placementOperationID, reportId: placementReportID, disposition: "placed")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(receipt)) as? [String: Any]); object["shopRevision"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(PlacementReporterReceipt.self, from: JSONSerialization.data(withJSONObject: object)))
        let status = PlacementReporterStatus(clientKey: placementKey, operationId: placementOperationID, reportId: placementReportID, shopId: placementShopID,
            reportedRevision: 4, reportedAuthorityEpoch: 2, occurredAt: placementDate, receivedAt: placementDate, state: "applied")
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(status)) as? [String: Any]); object["budget"] = ["totalMinor": 999]
        XCTAssertThrowsError(try JSONDecoder().decode(PlacementReporterStatus.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testPlacementReviewerExactRetryAndLostRoleKeepReporterEvidenceUsable() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let row = try placementPending(), page = PlacementReportPage(shopId: placementShopID, shopRevision: 4, authorityEpoch: 3, phase: "frozen", frozenRevision: 4, reports: [try placementPending()], nextCursor: nil)
        let review = try PlacementReviewIntent(subject: "account", householdID: household, memberID: member, deviceID: "device", page: page, report: row, choice: .apply, replayWindow: placementWindow)
        var bodies: [Data] = [], lostRole = false
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") { return (200, try self.placementBootstrap()) }
            if path.hasSuffix("/placement-reports") { return lostRole ? (404, Data(#"{"error":{"code":"unavailable"}}"#.utf8)) : (200, try encoded(page)) }
            bodies.append(self.placementBody(request))
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bodies.last!)
            if envelope.kind == "shop.reportPlaced" { return (200, try encoded(PlacementReporterReceipt(operationId: self.placementOperationID, reportId: self.placementReportID, disposition: "pending_reconciliation"))) }
            if lostRole { return (404, Data(#"{"error":{"code":"unavailable"}}"#.utf8)) }
            if bodies.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, try encoded(PlacementReviewReceipt(operationId: self.placementOperationID, shopId: self.placementShopID, shopRevision: 5, authorityEpoch: 3, disposition: "placed", reportId: row.reportId)))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let pending = try await service.pendingPlacementReports(shopID: placementShopID); XCTAssertEqual(pending, page)
        do { _ = try await service.executePlacementReview(review); XCTFail("Lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let receipt = try await service.executePlacementReview(review); XCTAssertEqual(receipt.shopRevision, 5); XCTAssertEqual(bodies, [review.bytes, review.bytes])
        lostRole = true
        do { _ = try await service.pendingPlacementReports(shopID: placementShopID); XCTFail("Former shopper read") } catch { XCTAssertEqual(error as? ClientError, .service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)) }
        let report = try placementCapture().report(occurredAt: placementDate)
        let reporterReceipt = try await service.executePlacementReport(report); XCTAssertEqual(reporterReceipt.disposition, "pending_reconciliation")
        let mismatched = PlacementReportPage(shopId: placementShopID, shopRevision: 6, authorityEpoch: 3, phase: "frozen", frozenRevision: 6, reports: [row], nextCursor: nil)
        XCTAssertThrowsError(try PlacementReviewIntent(subject: "account", householdID: household, memberID: member, deviceID: "device", page: mismatched, report: row, choice: .apply, replayWindow: placementWindow))
    }
}


extension HouseholdClientTests {
    func testPlacementCaptureFetchesReviewedSnapshotAndWindowOnceBeforeLocalOfflineSeal() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let reviewed = try placementShopValue(); var snapshots = 0, windows = 0, offline = false
        MockURLProtocol.handler = { request in
            if offline { XCTFail("Offline seal performed network work"); throw URLError(.notConnectedToInternet) }
            if let result = self.authResponse(request) { return result }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"token"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") { return (200, try self.placementBootstrap()) }
            if path.hasSuffix("/placement-reports/current-shop") { snapshots += 1; return (200, try encoded(reviewed)) }
            XCTAssertTrue(path.hasSuffix("/replay-windows")); windows += 1
            return (200, try encoded(self.placementWindow))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let prepared = try await service.preparePlacementSnapshot(reviewed: reviewed)
        XCTAssertEqual(prepared.snapshot, reviewed); XCTAssertEqual(prepared.replayWindow, placementWindow)
        offline = true
        let report = try prepared.report(occurredAt: placementDate)
        let restored = try JSONDecoder().decode(PlacementReportIntent.self, from: encoded(report)); try restored.validate()
        XCTAssertEqual(restored.bytes, report.bytes); XCTAssertEqual(snapshots, 1); XCTAssertEqual(windows, 1)
    }
}
