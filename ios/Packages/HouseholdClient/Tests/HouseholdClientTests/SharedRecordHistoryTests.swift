import XCTest
@testable import HouseholdClient

final class SharedRecordHistoryTests: XCTestCase {
    func testHistoricalFamiliesPreserveIndependentEvidenceAndRequiredNulls() throws {
        let snapshot = try SharedRecordHistoryWire.snapshot(from: sharedRecordFixture("history-v1"))
        let record = snapshot.record
        XCTAssertEqual(record.foodHistoryCoverage, .notCaptured)
        XCTAssertEqual(record.stockHistoryCoverage, .notCaptured)
        XCTAssertNil(record.foodHistory); XCTAssertNil(record.stockHistory)
        XCTAssertEqual(record.basketRevisions.map(\.purpose), ["create", "freeze", "placed"])
        XCTAssertEqual(record.mealRevisions.first?.meal?.planning?.groups.first?.protected, true)
        XCTAssertEqual(record.mealRevisions.last?.revision, 3)
        XCTAssertNil(record.mealRevisions.last?.meal)
        XCTAssertEqual(record.cookCopies.first?.language, "es")
        XCTAssertEqual(record.cookCopies.first?.text, "Reserve dos tortillas para el almuerzo. Sin sal.")
        XCTAssertEqual(record.cookSends.first?.copyId, record.cookCopies.first?.copyId)
        XCTAssertEqual(record.deliveries.observations.count, 2)
        guard case .usable(let usable) = record.deliveries.observations.last?.body else { return XCTFail("Expected usable evidence") }
        XCTAssertEqual(usable.usable?.amount.numerator, 6)
        XCTAssertEqual(record.deliveries.reservations.first?.quantity?.originalLiteral, "2 wraps")
        XCTAssertNil(record.decisions.first?.outcome)
        XCTAssertEqual(record.financialEntries.map(\.kind), [.postedCharge, .pendingCredit])
        XCTAssertEqual(record.priceObservations.first?.price, .exact(minor: 200))
        let bytes = try record.independentData()
        XCTAssertEqual(try SharedRecordHistoryWire.independentRecord(from: bytes), record)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-v1")) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary, original["record"] as? NSDictionary)
        for key in ["authorityEpoch", "privacyRevision", "deviceToken", "replayWindow", "operationId", "clientKey", "previewDigest"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(key), key)
        }
    }

    func testCapturedAllocationAndStockCorrectionsRemainHistoricalEvidence() throws {
        let record = try SharedRecordHistoryWire.snapshot(from: sharedRecordFixture("history-food-v1")).record
        XCTAssertEqual(record.foodHistoryCoverage, .captured); XCTAssertEqual(record.stockHistoryCoverage, .captured)
        let food = try XCTUnwrap(record.foodHistory), stock = try XCTUnwrap(record.stockHistory)
        XCTAssertEqual(food.demandRevisions.map { $0.graph.revision }, [1, 2])
        XCTAssertNil(food.demandRevisions[0].predecessorRevision)
        XCTAssertEqual(food.demandRevisions[1].predecessorRevision, 1)
        let allocation = try XCTUnwrap(food.demandRevisions[0].graph.edges.first)
        XCTAssertEqual(allocation.kind, .withinExisting)
        XCTAssertEqual(allocation.quantity.amount.numerator, 2)
        XCTAssertEqual(allocation.quantity.originalLiteral, "2 original wraps")
        let transferred = try XCTUnwrap(food.trackingRevisions[1].food.unbound.first?.transferred)
        XCTAssertEqual(transferred.quantity?.originalLiteral, "2 original wraps")
        XCTAssertTrue(food.trackingRevisions[1].food.graph.edges.isEmpty)
        XCTAssertTrue(food.trackingRevisions[1].food.bindings.isEmpty)
        XCTAssertEqual(stock.lots.map(\.location), ["freezer", "pantry"])
        XCTAssertEqual(stock.events.map(\.pantryRevision), Array(1...8))
        let observations = stock.events.filter { $0.kind == "observe" }
        let quantities: [SharedMealQuantity?] = observations.map { event in
            guard case .observe(_, let quantity) = event.details else { return nil }; return quantity
        }
        XCTAssertEqual(quantities.map { $0?.amount.numerator }, [4, 2, nil, 0])
        XCTAssertEqual(quantities[1]?.originalLiteral, "two usable freezer wraps after correction")
        guard case .reserve(_, _, _, _, let promised) = stock.events[3].details,
              case .reserve(_, _, _, _, let released) = stock.events[4].details else { return XCTFail("Missing reservation chronology") }
        XCTAssertEqual(promised?.amount.numerator, 2); XCTAssertNil(released)
        let bytes = try record.independentData()
        XCTAssertEqual(try SharedRecordHistoryWire.independentRecord(from: bytes), record)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-food-v1")) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary, original["record"] as? NSDictionary)
        for key in ["authorityEpoch", "privacyRevision", "replayWindow", "operationId", "clientKey", "quoteDigest"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(key), key)
        }
    }

    func testCapturedHistoryRejectsMissingProvenanceAndAmbiguousCorrections() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-food-v1")) as? [String: Any])
        for variant in 0..<11 {
            var object = original, record = object["record"] as! [String: Any]
            var food = record["foodHistory"] as! [String: Any], demand = food["demandRevisions"] as! [[String: Any]]
            var tracking = food["trackingRevisions"] as! [[String: Any]]
            var stock = record["stockHistory"] as! [String: Any], events = stock["events"] as! [[String: Any]], lots = stock["lots"] as! [[String: Any]]
            switch variant {
            case 0: demand.removeFirst() // The second graph cannot lose its predecessor.
            case 1: demand[0].removeValue(forKey: "predecessorRevision")
            case 2: demand[0]["packReviews"] = []
            case 3:
                var partition = tracking[0]["food"] as! [String: Any], basket = partition["basket"] as! [[String: Any]]
                basket[0]["packs"] = 3; partition["basket"] = basket; tracking[0]["food"] = partition
            case 4: events[7]["pantryRevision"] = events[6]["pantryRevision"]
            case 5: events[6].removeValue(forKey: "quantity") // Unknown must remain explicit null.
            case 6: events[3]["groupId"] = UUID().uuidString
            case 7: lots[1]["deliverySourceId"] = UUID().uuidString
            case 8: events[0]["lotId"] = lots[1]["lotId"] // Delivery observations use the delivery evidence family.
            default: break
            }
            food["demandRevisions"] = demand; food["trackingRevisions"] = tracking
            stock["events"] = events; stock["lots"] = lots
            record["foodHistory"] = variant == 9 ? NSNull() : food
            record["stockHistory"] = variant == 10 ? NSNull() : stock
            object["record"] = record
            XCTAssertThrowsError(try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: object)), "variant \(variant)")
        }
    }

    func testCapturedEmptySectionsDifferFromLegacyAbsence() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-v1")) as? [String: Any])
        var record = object["record"] as! [String: Any]
        record["foodHistory"] = ["demandRevisions": [], "trackingRevisions": []]
        record["stockHistory"] = ["lots": [], "events": []]
        object["record"] = record
        let captured = try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: object)).record
        XCTAssertEqual(captured.foodHistoryCoverage, .captured); XCTAssertEqual(captured.stockHistoryCoverage, .captured)
        XCTAssertTrue(try XCTUnwrap(captured.foodHistory).demandRevisions.isEmpty)
        XCTAssertTrue(try XCTUnwrap(captured.stockHistory).events.isEmpty)
    }

    func testInjectedAuthorityRejectsAtEveryObjectBoundary() throws {
        // Walk every object, including quantity fractions, fee variants, meal
        // planning and price evidence, so reused permissive DTOs cannot leak keys.
        func variants(_ value: Any) -> [Any] {
            if let object = value as? [String: Any] {
                var injected = object; injected["authorityEpoch"] = 77
                var results: [Any] = [injected]
                for (key, child) in object {
                    for variant in variants(child) { var copy = object; copy[key] = variant; results.append(copy) }
                }
                return results
            }
            if let array = value as? [Any] {
                return array.indices.flatMap { index in variants(array[index]).map { variant -> Any in
                    var copy = array; copy[index] = variant; return copy
                } }
            }
            return []
        }
        for name in ["history-v1", "history-food-v1"] {
            let original = try JSONSerialization.jsonObject(with: sharedRecordFixture(name))
            let injected = variants(original)
            XCTAssertGreaterThan(injected.count, 40)
            for variant in injected {
                XCTAssertThrowsError(try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: variant)))
            }
        }
    }

    func testMissingRequiredNullAndForeignShopOrMissingHistoryReject() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-v1")) as? [String: Any])
        for variant in 0..<6 {
            var object = original, record = object["record"] as! [String: Any]
            switch variant {
            case 0:
                var decisions = record["decisions"] as! [[String: Any]]
                decisions[0].removeValue(forKey: "outcome"); record["decisions"] = decisions
            case 1:
                var prices = record["priceObservations"] as! [[String: Any]]
                prices[0]["shopId"] = UUID().uuidString; record["priceObservations"] = prices
            case 2: record["mealRevisions"] = []
            case 3: record["basketRevisions"] = []
            case 4:
                var copies = record["cookCopies"] as! [[String: Any]]
                copies[0]["mealRevision"] = 3; record["cookCopies"] = copies
            default:
                var deliveries = record["deliveries"] as! [String: Any]
                var observations = deliveries["observations"] as! [[String: Any]], body = observations[0]["body"] as! [String: Any]
                body.removeValue(forKey: "predecessorId"); observations[0]["body"] = body
                deliveries["observations"] = observations; record["deliveries"] = deliveries
            }
            object["record"] = record
            XCTAssertThrowsError(try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testObservationTimestampDoesNotChangeIndependentBytes() throws {
        let original = try sharedRecordFixture("history-v1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["asOf"] = "2026-11-11T14:00:00.000Z"
        let first = try SharedRecordHistoryWire.snapshot(from: original)
        let second = try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotEqual(first.asOf, second.asOf)
        XCTAssertEqual(try first.record.independentData(), try second.record.independentData())
    }

    func testOversizedDepthAndFamilyBoundsReject() throws {
        XCTAssertThrowsError(try SharedRecordHistoryWire.snapshot(from: Data(repeating: 32, count: SharedRecordHistoryWire.maximumResponseBytes + 1)))
        XCTAssertThrowsError(try SharedRecordHistoryWire.independentRecord(from: Data((String(repeating: "[", count: 49) + String(repeating: "]", count: 49)).utf8)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-v1")) as? [String: Any])
        var record = object["record"] as! [String: Any]
        record["cookSends"] = Array(repeating: (record["cookSends"] as! [Any])[0], count: 2001)
        object["record"] = record
        XCTAssertThrowsError(try SharedRecordHistoryWire.snapshot(from: JSONSerialization.data(withJSONObject: object)))
    }
}

extension HouseholdClientTests {
    func testSharedRecordHistoryUsesAuthorizedGetAndRejectsForeignOrigin() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedRecordFixture("history-v1")) as? [String: Any])
        var record = object["record"] as! [String: Any], origin = record["origin"] as! [String: Any]
        origin["householdId"] = household; record["origin"] = origin; object["record"] = record
        let bytes = try JSONSerialization.data(withJSONObject: object), page = try SharedRecordHistoryWire.snapshot(from: bytes)
        let auth = try auth(), service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        origin["householdId"] = "00000000-0000-4000-8000-000000000099"
        record["origin"] = origin; object["record"] = record
        let foreignBytes = try JSONSerialization.data(withJSONObject: object)
        var reads = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/devices") { return (201, Data(#"{"deviceId":"device","deviceToken":"test"}"#.utf8)) }
            if path.hasSuffix("/bootstrap") {
                return (200, try JSONSerialization.data(withJSONObject: ["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": page.record.origin.shopId.string, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]]))
            }
            XCTAssertTrue(path.hasSuffix("/records/history/v1")); XCTAssertEqual(request.httpMethod, "GET"); reads += 1
            return (200, reads == 1 ? bytes : foreignBytes)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let result = try await service.sharedRecordHistory(shopID: page.record.origin.shopId.uuid)
        XCTAssertEqual(result.record, page.record)
        do { _ = try await service.sharedRecordHistory(shopID: page.record.origin.shopId.uuid); XCTFail("Foreign origin accepted") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        XCTAssertEqual(reads, 2)
    }
}
