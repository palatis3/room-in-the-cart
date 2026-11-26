import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testDinnerQuestionAsksAboutOnlyTheSelectedDinnerAndRecipient() async throws {
        let shop = UUID(), dinner = UUID(), recipient = UUID(), command = UUID()
        let page: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 2, "authorityEpoch": 3, "pairRevision": 4,
                                   "shopper": true, "recipient": ["id": recipient.uuidString, "label": "Alex"],
                                   "dinners": [["id": dinner.uuidString, "label": "Frijoles", "day": "2026-12-02"]],
                                   "items": [], "checks": [], "validUntil": "2026-12-02T18:01:00Z"]
        let bytes = try JSONSerialization.data(withJSONObject: page)
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["adult_checks"], role: "shopper") { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/shops/" + shop.uuidString.lowercased() + "/adult-checks"))
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["action","id","kind","sourceId","recipientId","shopRevision","authorityEpoch","pairRevision","expiresAt"])
                XCTAssertEqual(body["kind"] as? String, "attendance")
                XCTAssertEqual(body["sourceId"] as? String, dinner.uuidString.lowercased())
                XCTAssertEqual(body["recipientId"] as? String, recipient.uuidString.lowercased())
                XCTAssertEqual(body["pairRevision"] as? Int, 4)
                XCTAssertEqual(body["id"] as? String, command.uuidString.lowercased())
            }
            return (200, bytes)
        }
        let draft = try await service.fetchAdultChecks(in: session)
        _ = try await service.askAdultCheck(in: session, page: draft, id: command, kind: .attendance, source: dinner, expires: Date().addingTimeInterval(3600))
    }

    func testQuestionRecipientRejectsUnrequestedGroceryChoicesAndUnrelatedAnswers() throws {
        let shop = UUID()
        let check: [String: Any] = ["id": UUID().uuidString, "sourceId": UUID().uuidString, "kind": "cupboard", "label": "Arroz",
                                     "expiresAt": "2026-12-02T18:00:00Z", "answer": "out", "answeredAt": "2026-12-02T17:01:00Z",
                                     "reviewed": false, "canAnswer": false]
        var body: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 2, "authorityEpoch": 1, "pairRevision": 0,
                                    "shopper": false, "dinners": [], "items": [], "checks": [check], "validUntil": "2026-12-02T17:02:00Z"]
        func validate() throws {
            let bytes = try JSONSerialization.data(withJSONObject: body)
            try JSONDecoder().decode(AdultCheckPage.self, from: bytes).validate(shop: shop)
        }
        XCTAssertThrowsError(try validate())
        var reply = check
        reply["answer"] = "cannotCheck"
        reply["quantity"] = ["value": "2", "unit": "count"]
        body["checks"] = [reply]
        XCTAssertThrowsError(try validate())
        reply["answer"] = "low"
        body["checks"] = [reply]
        XCTAssertNoThrow(try validate())
        reply["quantity"] = ["value": "0.0", "unit": "count"]
        body["checks"] = [reply]
        XCTAssertThrowsError(try validate())
        body["checks"] = []
        body["items"] = [["id": UUID().uuidString, "label": "Private"]]
        XCTAssertThrowsError(try validate())
        body["items"] = []
        XCTAssertNoThrow(try validate())
    }
}
