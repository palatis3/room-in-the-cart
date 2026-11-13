import XCTest
@testable import HouseholdClient

func sharedRecordFixture(_ name: String = "partial-v2") throws -> Data {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/\(name).json"))
}
final class SharedRecordSnapshotTests: XCTestCase {
    func testExactPartialUnknownProtectedFoodAndMoneySurviveIndependentRoundtrip() throws {
        let page = try SharedRecordWire.snapshot(from: sharedRecordFixture()), record = page.record
        XCTAssertEqual(record.food.coverage?.status, .partial)
        XCTAssertFalse(try XCTUnwrap(record.food.coverage).completeFoodCoverage)
        XCTAssertNil(record.food.catalog.first?.quantity); XCTAssertNil(record.food.unbound.first?.transferred?.quantity)
        XCTAssertEqual(record.food.catalog.first?.sourceLabel, "Protected lunch")
        XCTAssertEqual(record.food.basket.last?.packs, 2); XCTAssertNil(record.food.basket.last?.priceMinor)
        XCTAssertNil(record.quote.fee.amountMinor)
        let bytes = try record.independentData()
        XCTAssertEqual(try SharedRecordWire.independentRecord(from: bytes), record)
        for key in ["authorityEpoch", "freezeReview", "previewId", "previewDigest", "basisDigest", "quoteDigest", "replayWindow", "operationId"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(key), key)
        }
    }
    func testErasedRecordKeepsSurvivingPartitionWithoutPackOrCoverageClaim() throws {
        let record = try SharedRecordWire.snapshot(from: sharedRecordFixture("erased-v2")).record
        XCTAssertEqual(record.food.status, .reviewRequired); XCTAssertEqual(record.food.packReview.state, .erased)
        XCTAssertNil(record.food.packReview.values); XCTAssertNil(record.food.coverage)
        XCTAssertEqual(record.privacyRevision, 3); XCTAssertEqual(record.food.unbound.count, 1)
    }
    func testUnknownAuthorityFieldsRejectAtNestedAndRootBoundaries() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture()) as? [String: Any])
        for path in [[], ["record"], ["record", "food"], ["record", "food", "graph"], ["record", "quote"]] as [[String]] {
            func inject(_ value: [String: Any], _ remaining: ArraySlice<String>) -> [String: Any] {
                var result = value
                if let key = remaining.first { result[key] = inject(value[key] as! [String: Any], remaining.dropFirst()) }
                else { result["authorityEpoch"] = 77 }
                return result
            }
            let bytes = try JSONSerialization.data(withJSONObject: inject(original, path[...]))
            XCTAssertThrowsError(try SharedRecordWire.snapshot(from: bytes))
        }
    }
    func testMissingSourceMealPartitionAndPackFieldsReject() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture()) as? [String: Any])
        for variant in 0..<4 {
            var value = original, record = value["record"] as! [String: Any], food = record["food"] as! [String: Any]
            if variant == 0 { record["mealOccurrences"] = [] }
            if variant == 1 { food["unbound"] = [] }
            if variant == 2 { food["packReview"] = ["state": "recorded"] }
            if variant == 3 { var c = food["coverage"] as! [String: Any]; c["completeFoodCoverage"] = true; food["coverage"] = c }
            record["food"] = food; value["record"] = record
            XCTAssertThrowsError(try SharedRecordWire.snapshot(from: JSONSerialization.data(withJSONObject: value)))
        }
    }
    func testOversizedAndDeepInputRejectBeforeTypedDecode() throws {
        XCTAssertThrowsError(try SharedRecordWire.snapshot(from: Data(repeating: 32, count: SharedRecordWire.maximumResponseBytes + 1)))
        XCTAssertThrowsError(try SharedRecordWire.independentRecord(from: Data((String(repeating: "[", count: 49) + String(repeating: "]", count: 49)).utf8)))
    }
}

extension HouseholdClientTests {
    func testSharedRecordsUsesExplicitV2ReadAndDoesNotCreateAnyReplayOrMutation() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture()) as? [String: Any])
        var record = object["record"] as! [String: Any], origin = record["origin"] as! [String: Any]
        var food = record["food"] as! [String: Any], graph = food["graph"] as! [String: Any]
        origin["householdId"] = household; graph["householdId"] = household
        record["origin"] = origin; food["graph"] = graph; record["food"] = food; object["record"] = record
        let bytes = try JSONSerialization.data(withJSONObject: object), page = try SharedRecordWire.snapshot(from: bytes)
        let auth = try auth(), service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var reads = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, Data(#"{"deviceId":"device","deviceToken":"test"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") {
                return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": page.record.origin.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]]))
            }
            XCTAssertTrue(path.hasSuffix("/records/snapshot/v2")); XCTAssertEqual(request.httpMethod, "GET"); reads += 1
            return (200, bytes)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let result = try await service.sharedRecordSnapshot(shopID: page.record.origin.shopId.uuid)
        XCTAssertEqual(result.record, page.record); XCTAssertEqual(reads, 1)
    }
}
