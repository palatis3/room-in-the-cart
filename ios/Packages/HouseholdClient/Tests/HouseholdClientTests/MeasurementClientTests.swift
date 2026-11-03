import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testMeasurementCodesKeepUnverifiedBenefitUnknownAndKnownLateTieZero() throws {
        for outcome in MeasurementAnswer.Outcome.allCases {
            XCTAssertEqual(MeasurementAnswer(outcome: outcome, baseline: .list, comparison: .same).incrementalBenefit, 0)
        }
        for outcome in [MeasurementAnswer.Outcome.late, .alreadyKnew, .unchanged, .wrong] {
            XCTAssertEqual(MeasurementAnswer(outcome: outcome, baseline: .retailer, comparison: .different).incrementalBenefit, 0)
        }
        XCTAssertNil(MeasurementAnswer(outcome: .acted, baseline: .list, comparison: .different).incrementalBenefit)
        let legacy = Data(#"{"noticeVersion":"old","consent":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MeasurementStatus.self, from: legacy).validate())
    }

    func testMeasurementConsentSendRemovalAndWithdrawalUseOnlyExplicitAllowlistedFields() async throws {
        let auth = try auth(), shop = UUID(), consent = UUID(), feedback = UUID()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var writes: [(String, [String: Any])] = []
        let status: [String: Any] = ["noticeVersion": MeasurementNotice.currentVersion, "consent": ["consentId": consent.uuidString, "noticeVersion": MeasurementNotice.currentVersion, "grantedAt": "2026-11-03T15:00:00Z"]]
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            if request.url!.path.hasSuffix("/devices") { return (201, Data(#"{"deviceId":"device","deviceToken":"secret"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") {
                return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": shop.uuidString, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands"]]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "secret")
            let path = request.url!.path
            if request.httpMethod != "GET" {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
                }
                writes.append((path, try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])))
            }
            if path.hasSuffix("/status") || path.hasSuffix("/consent") { return (200, try JSONSerialization.data(withJSONObject: status)) }
            if path.hasSuffix("/withdraw") { return (200, Data(#"{"withdrawn":true}"#.utf8)) }
            if request.httpMethod == "DELETE" { return (200, Data(#"{"removed":true}"#.utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["feedbackId": feedback.uuidString, "shopId": shop.uuidString, "eligibleWeek": "2026-W45", "consentVersion": MeasurementNotice.currentVersion, "outcome": "late", "baseline": "list", "comparison": "different", "incrementalBenefit": 0, "recordedAt": "2026-11-03T15:01:00Z"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        XCTAssertTrue(writes.isEmpty, "Enrollment must never grant measurement consent")
        let enabled = try await service.grantMeasurementConsent(noticeVersion: MeasurementNotice.currentVersion)
        let grant = try XCTUnwrap(enabled.consent)
        let result = try await service.sendMeasurementFeedback(shopID: shop, answer: .init(outcome: .late, baseline: .list, comparison: .different), consent: grant)
        XCTAssertEqual(result.feedbackId, feedback)
        try await service.removeMeasurementFeedback(shopID: shop, feedbackID: feedback)
        try await service.withdrawMeasurementConsent(grant)
        XCTAssertEqual(writes.count, 4)
        XCTAssertEqual(Set(writes[0].1.keys), ["noticeVersion"])
        XCTAssertEqual(Set(writes[1].1.keys), ["consentId", "noticeVersion", "outcome", "baseline", "comparison"])
        XCTAssertEqual(Set(writes[2].1.keys), ["feedbackId"])
        XCTAssertEqual(Set(writes[3].1.keys), ["consentId"])
        XCTAssertFalse(try JSONSerialization.data(withJSONObject: writes.map(\.1)).isEmpty)
    }
}
