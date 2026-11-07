import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private func cookPage() throws -> SharedDeliveryPage {
        let meal: [String: Any] = ["title": "Lunch", "day": "2026-11-07", "kind": "lunch", "portions": 2, "protected": true]
        let occurrence: [String: Any] = ["occurrenceId": UUID().uuidString, "revision": 2, "meal": meal]
        let page: [String: Any] = ["shopId": UUID().uuidString, "shopRevision": 4, "placedRevision": 3, "authorityEpoch": 1,
                                   "supplyRevision": 9, "meals": [occurrence], "lines": [], "sources": []]
        return try JSONDecoder().decode(SharedDeliveryPage.self, from: JSONSerialization.data(withJSONObject: page))
    }

    func testCookCopyCommandsBindSealedFactsAndRejectMismatchedReceipts() throws {
        let page = try cookPage(), occurrence = try XCTUnwrap(page.meals?.first)
        let spanish = "  Almuerzo\nAparte. 🥣  "
        let save = SharedCookCopyEdit.save(text: spanish, language: "es", occurrence: occurrence)
        let fields = try save.body(reviewed: page)
        XCTAssertEqual(fields, ["supplyRevision": .integer(9), "placedRevision": .integer(3),
            "occurrenceId": .string(occurrence.id.uuidString.lowercased()), "mealRevision": .integer(2),
            "text": .string(spanish), "language": .string("es")])
        XCTAssertThrowsError(try save.body(reviewed: cookPage()))
        for (text, language) in [("  \n", "es"), ("note", "fr"), ("a\u{0}b", "en"), (String(repeating: "🥣", count: 8_001), "en")] {
            XCTAssertThrowsError(try SharedCookCopyEdit.save(text: text, language: language, occurrence: occurrence).body(reviewed: page))
        }
        XCTAssertEqual(try SharedCookCopyEdit.recipientLabel(" \u{FEFF}Ana\n"), "Ana")
        XCTAssertThrowsError(try SharedCookCopyEdit.recipientLabel("Ana\nMaría"))
        XCTAssertThrowsError(try SharedCookCopyEdit.recipientLabel(String(repeating: "🥣", count: 41)))
        let base = CommandBase(shopRevision: 4, authorityEpoch: 1), shop = page.shopId.uuidString.lowercased()
        let envelope = CommandEnvelope(replayWindow: "window", shopId: shop, kind: save.kind, base: base, body: fields)
        let pending = try PendingOperation(envelope: envelope, householdID: household, memberID: member, deviceID: "device")
        XCTAssertFalse(pending.targetsShop(nil, includeCreation: true))
        XCTAssertFalse(pending.targetsShop(UUID().uuidString))
        XCTAssertTrue(pending.targetsShop(shop))
        let copy = UUID().uuidString.lowercased()
        var receipt: [String: Any] = ["kind": save.kind, "operationId": copy, "copyId": copy, "shopId": shop,
                                      "shopRevision": 4, "authorityEpoch": 1, "disposition": "recorded"]
        func check(_ payload: [String: Any], for command: CommandEnvelope) throws {
            try JSONDecoder().decode(ShopperReceipt.self, from: JSONSerialization.data(withJSONObject: payload)).validateCookCopy(command)
        }
        try check(receipt, for: envelope)
        for (key, value): (String, Any) in [("copyId", UUID().uuidString), ("operationId", "invalid"), ("authorityEpoch", 2),
                                            ("shopId", UUID().uuidString), ("shopRevision", 5), ("disposition", "sent")] {
            var wrong = receipt; wrong[key] = value
            XCTAssertThrowsError(try check(wrong, for: envelope))
        }
        let mark = CommandEnvelope(replayWindow: "window", shopId: shop, kind: "cookCopy.markSent", base: base,
                                   body: ["copyId": .string(copy), "previousSendId": .null, "recipient": .string("Ana")])
        receipt["kind"] = mark.kind
        XCTAssertThrowsError(try check(receipt, for: mark))
        receipt["operationId"] = UUID().uuidString
        try check(receipt, for: mark)
        receipt["copyId"] = UUID().uuidString
        XCTAssertThrowsError(try check(receipt, for: mark))
    }

    func testCookCopyUnknownOrMalformedFactIndexFallsBackWithoutChangingReviewedText() throws {
        let meal = "Cena 🥣\n\ncon frijoles"
        let scope = "Sólo entregas"
        let text = [meal, scope + "\nFecha"].joined(separator: "\n\n")
        let sections: [SharedCookFactIndex.Section] = [
            .init(key: "meal", bytes: meal.utf8.count, unresolved: false),
            .init(key: "scope", bytes: scope.utf8.count, unresolved: false),
            .init(key: "stamp", bytes: 5, unresolved: false)]
        let index = try XCTUnwrap(SharedCookFactIndex(source: .delivery, sections: sections))
        XCTAssertEqual(index.pieces(in: text)?.map(\.wording), [meal, scope])
        XCTAssertNil(index.pieces(in: text + " private"))
        XCTAssertNil(SharedCookFactIndex(source: .delivery, sections: [sections[0]] + sections))
        let invalid = try XCTUnwrap(SharedCookFactIndex(source: .delivery, sections:
            [.init(key: "meal", bytes: 6, unresolved: false)] + sections.dropFirst()))
        XCTAssertNil(invalid.pieces(in: text))
        let ids: [String:Any] = ["copyId":UUID().uuidString, "previousCopyId":UUID().uuidString,
                                  "previousSendId":UUID().uuidString, "recipient":"Ana"]
        let wire = ids.merging(["currentFacts":["version":1,"source":"private","sections":[]], "previousFacts":NSNull()]) { _, new in new }
        let response = try JSONDecoder().decode(SharedCookCorrectionReview.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertNil(response.currentFacts)
        XCTAssertNil(response.previousFacts)
    }

    func testCookCopyHistoryAndBaselineRejectDuplicatesWrongMealRecipientAndAbsentHead() async throws {
        let page = try cookPage(), occurrence = try XCTUnwrap(page.meals?.first)
        let shop = page.shopId.uuidString.lowercased(), date = "2026-11-07T10:00:00.000Z"
        let copies: [[String: Any]] = (1...21).reversed().map { version in
            ["copyId": UUID().uuidString.lowercased(), "shopId": shop, "occurrenceId": occurrence.id.uuidString,
             "mealRevision": 2, "shopRevision": 4, "placedRevision": 3, "authorityEpoch": 1, "supplyRevision": 7,
             "version": version, "text": "Lunch", "language": "en", "createdAt": date]
        }
        let cursor = try XCTUnwrap(copies[19]["copyId"] as? String)
        var lastPage = copies[20]
        let first = copies[0]
        var send: [String: Any] = ["sendId": UUID().uuidString, "copyId": try XCTUnwrap(first["copyId"]), "recipient": "Ana", "sentAt": date]
        var missingHead = false, allow = true, reads = 0
        var returnedRecipient = "Ana"
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: auth, deviceVault: MemoryVault(), transport: transport())
        func response(_ value: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        MockURLProtocol.handler = { request in
            if let reply = self.authResponse(request) { return reply }
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/devices") { return try response(["deviceId": "device", "deviceToken": "test"]) }
            if url.path.hasSuffix("/bootstrap") {
                return try response(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper",
                    "shopId": shop, "enrolled": true, "queueConsent": false, "capabilities":
                        ["shopper_inbox", "request_preview", "shopper_commands"] + (allow ? ["cook_copies", "cook_corrections", "delivery_evidence"] : [])])
            }
            reads += 1
            if url.path.hasSuffix("/correction") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(url.query)
                return try response(["copyId":try XCTUnwrap(first["copyId"]), "previousCopyId":try XCTUnwrap(first["copyId"]),
                    "previousSendId":try XCTUnwrap(send["sendId"]), "recipient":returnedRecipient, "currentFacts":NSNull(), "previousFacts":NSNull()])
            }
            if url.path.hasSuffix("/baseline") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(url.query)
                return try response(missingHead ? [:] : ["baseline": ["copy": first, "send": send]])
            }
            XCTAssertTrue(url.path.hasSuffix("/cook-copies"))
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "occurrenceId" })?.value, occurrence.id.uuidString.lowercased())
            if let value = query?.first(where: { $0.name == "cursor" })?.value {
                XCTAssertEqual(value, cursor)
                return try response(["copies": [lastPage], "nextCursor": NSNull()])
            }
            return try response(["copies": Array(copies.prefix(20)), "nextCursor": cursor])
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let history = try await service.cookCopies(occurrence: occurrence, reviewed: page)
        XCTAssertEqual(history.map(\.version), Array((1...21).reversed()))
        lastPage["copyId"] = first["copyId"]
        do { _ = try await service.cookCopies(occurrence: occurrence, reviewed: page); XCTFail("Accepted a duplicate copy") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        lastPage = copies[20]; lastPage["occurrenceId"] = UUID().uuidString
        do { _ = try await service.cookCopies(occurrence: occurrence, reviewed: page); XCTFail("Accepted another meal") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        func baseline() async throws -> SharedCookCopyBaseline? {
            try await service.cookCopyBaseline(recipient: " Ana ", occurrence: occurrence, reviewed: page)
        }
        let found = try await baseline()
        XCTAssertEqual(found?.copy, history.first)
        let prior = try XCTUnwrap(found)
        func correction(_ destination: Bool) async throws -> SharedCookCorrectionReview {
            try await service.cookCorrection(copy: prior.copy, baseline: prior, recipient: "Ana",
                                             destinationConfirmed: destination, occurrence: occurrence, reviewed: page)
        }
        let noFacts = try await correction(true)
        XCTAssertNil(noFacts.previousFacts)
        var readCount = reads
        do { _ = try await correction(false); XCTFail("Compared an uncertain destination") } catch { XCTAssertEqual(error as? ClientError, .configuration) }
        XCTAssertEqual(reads, readCount)
        returnedRecipient = "A different cook"
        do { _ = try await correction(true); XCTFail("Compared another recipient") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        allow = false; readCount = reads
        do { _ = try await correction(true); XCTFail("Compared after scope loss") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(reads, readCount)
        allow = true
        send["recipient"] = "ana"
        do { _ = try await baseline(); XCTFail("Accepted another recipient") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        send["recipient"] = "Ana"; send["copyId"] = UUID().uuidString
        do { _ = try await baseline(); XCTFail("Accepted mismatched copy and send") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        missingHead = true
        do { _ = try await baseline(); XCTFail("Treated an omitted baseline as never sent") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        allow = false; let before = reads
        do { _ = try await baseline(); XCTFail("Read without capability") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(reads, before)
    }
}
