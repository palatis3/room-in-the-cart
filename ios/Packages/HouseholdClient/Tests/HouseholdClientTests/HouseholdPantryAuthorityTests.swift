import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testHouseholdPurchaseEvidenceIsDistinctFromCurrentCookBalanceAndMissingOnOlderServers() throws {
        let time = "2026-11-17T12:00:00Z", purchaseID = UUID(), currentID = UUID()
        func quantity(_ count: Int) -> [String: Any] {
            ["amount": ["numerator": count, "denominator": 1], "unit": "count", "originalLiteral": String(count)]
        }
        var body: [String: Any] = ["lotId": UUID().uuidString, "origin": "delivery", "location": "pantry",
            "foodName": "Wraps", "storedAt": time, "useFirstAt": NSNull(), "exclusionTags": [],
            "observation": ["observationId": currentID.uuidString, "confirmedAt": time, "quantity": quantity(0)],
            "purchaseObservation": ["observationId": purchaseID.uuidString, "confirmedAt": time, "quantity": quantity(5)]]
        let lot: HouseholdPantryPage.Lot = try TrackingWriteFixture.decode(body)
        try lot.validate()
        XCTAssertEqual(lot.observation?.quantity?.amount.numerator, 0)
        XCTAssertEqual(lot.purchaseObservation?.quantity?.amount.numerator, 5)
        XCTAssertEqual(lot.purchaseObservation?.observationId, purchaseID)
        XCTAssertNotEqual(lot.observation?.observationId, purchaseID)
        body["origin"] = "manual"
        let manual: HouseholdPantryPage.Lot = try TrackingWriteFixture.decode(body)
        XCTAssertThrowsError(try manual.validate())
        body["origin"] = "delivery"
        body.removeValue(forKey: "purchaseObservation")
        let legacy: HouseholdPantryPage.Lot = try TrackingWriteFixture.decode(body)
        try legacy.validate()
        XCTAssertNil(legacy.purchaseObservation, "A missing purchase is never inferred from a current count")
    }

    func testHouseholdPantryRetryKeepsOriginalIntentAcrossShopSelectionAndRejectsAnotherDevice() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: auth, deviceVault: MemoryVault(), transport: transport())
        let device = UUID(), op = UUID()
        let time = "2026-11-17T12:00:00Z"
        var commands = [Data]()
        var bootstrapReads = 0
        var pantryReads = 0
        var replayWindows = 0
        let lock = MockURLProtocol.installHandlerWithStateLock { request in
            if let reply = self.authResponse(request) { return reply }
            let path = request.url!.lastPathComponent
            func reply(_ object: [String: Any]) throws -> (Int, Data) {
                (200, try JSONSerialization.data(withJSONObject: object))
            }
            if path == "devices" {
                return try reply(["deviceId": device.uuidString, "deviceToken": "enrolled"])
            }
            if path == "bootstrap" {
                bootstrapReads += 1
                return try reply(["household": ["id": self.household, "label": "Home"], "memberId": self.member,
                                  "role": "organizer", "enrolled": true, "queueConsent": false,
                                  "shopId": request.value(forHTTPHeaderField: "X-Shop-ID") as Any,
                                  "capabilities": ["household_pantry", "household_pantry_grants"]])
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Shop-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-View-Grant-ID"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "enrolled")
            switch path {
            case "pantry":
                pantryReads += 1
                return try reply(["v": 1, "householdId": self.household, "grantEpoch": 3, "pantryRevision": 12,
                                  "asOf": time, "lots": [], "nextCursor": NSNull()])
            case "replay-windows":
                replayWindows += 1
                return try reply(["id": UUID().uuidString, "expiresAt": "2099-01-01T00:00:00Z"])
            case "commands":
                commands.append(mockRequestBody(request))
                if commands.count == 1 { throw URLError(.networkConnectionLost) }
                return try reply(["v": 1, "kind": "pantry.addLot", "householdId": self.household,
                                  "operationId": op.uuidString, "lotId": op.uuidString, "grantEpoch": 3, "pantryRevision": 13])
            default:
                XCTFail("Unexpected request \(path)")
                return (404, Data())
            }
        }
        _ = try await auth.verifyEmailCode(email: "x", code: "123456")
        let bootstrap = try await service.enroll(householdID: household)
        let session = try await service.householdPantrySession(for: bootstrap)
        let page = try await service.householdPantryPage(for: session)
        let addition = HouseholdPantryAddition(foodName: "Chilled beans", location: .fridge, confirmedAt: time, quantity: nil)
        let intent = try await service.prepareHouseholdPantryAddition(addition, reviewed: page, session: session)
        do {
            _ = try await service.submitHouseholdPantryAddition(intent, session: session)
            XCTFail("Lost response reported as committed")
        } catch { XCTAssertEqual(error as? ClientError, .transport) }
        _ = try await service.selectShop(UUID())
        let restored = try JSONDecoder().decode(HouseholdPantryIntent.self, from: encoded(intent))
        let otherDevice = HouseholdPantrySession(householdID: session.householdID, memberID: session.memberID, deviceID: UUID())
        do {
            _ = try await service.submitHouseholdPantryAddition(restored, session: otherDevice)
            XCTFail("Wrong device reused a pantry intent")
        } catch { XCTAssertEqual(error as? ClientError, .configuration) }
        let receipt = try await service.submitHouseholdPantryAddition(restored, session: session)
        XCTAssertEqual(receipt.lotId, op)
        let counts = lock.withLock { (commands, bootstrapReads, replayWindows, pantryReads) }
        XCTAssertEqual(counts.0, [try encoded(intent.command), try encoded(intent.command)])
        XCTAssertEqual(counts.1, 2, "Only enrollment and selecting a shop need a bootstrap")
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 1)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: counts.0[0]) as? [String: Any])
        let body = try XCTUnwrap(wire["body"] as? [String: Any])
        XCTAssertTrue(body["quantity"] is NSNull)
        XCTAssertEqual(body["location"] as? String, "fridge")
    }

    func testHouseholdPantryPagesRejectChangedAccessStockAndOverlappingLots() throws {
        let session = HouseholdPantrySession(householdID: UUID(), memberID: UUID(), deviceID: UUID())
        let time = "2026-11-17T12:00:00Z"
        func page(_ ids: [Int], epoch: Int = 1, revision: Int = 2, cursor: Int? = nil) throws -> HouseholdPantryPage {
            let lots: [[String: Any]] = ids.map { id in
                let zero: [String: Any] = ["amount": ["numerator": 0, "denominator": 1], "unit": "count", "originalLiteral": "0"]
                return ["lotId": TrackingWriteFixture.id(id), "origin": "manual", "location": "fridge", "foodName": "Beans",
                        "exclusionTags": [], "storedAt": NSNull(), "useFirstAt": NSNull(),
                        "observation": ["observationId": UUID().uuidString, "confirmedAt": time, "quantity": id == 1 ? zero as Any : NSNull()]]
            }
            return try TrackingWriteFixture.decode(["v": 1, "householdId": session.householdID.uuidString,
                "grantEpoch": epoch, "pantryRevision": revision, "asOf": time, "lots": lots,
                "nextCursor": cursor.map(TrackingWriteFixture.id) as Any])
        }
        let first = try page(Array(1...50), cursor: 50)
        try first.validate(for: session, after: nil)
        XCTAssertEqual(first.lots[0].observation?.quantity?.amount.numerator, 0)
        XCTAssertNil(first.lots[1].observation?.quantity)
        try page([51]).validate(for: session, after: first)
        XCTAssertThrowsError(try page([51], epoch: 2).validate(for: session, after: first))
        XCTAssertThrowsError(try page([51], revision: 3).validate(for: session, after: first))
        XCTAssertThrowsError(try page([50, 51]).validate(for: session, after: first))
        XCTAssertThrowsError(try page([1, 2], cursor: 2).validate(for: session, after: nil))
        let other = HouseholdPantrySession(householdID: UUID(), memberID: session.memberID, deviceID: session.deviceID)
        XCTAssertThrowsError(try first.validate(for: other, after: nil))
    }
}
