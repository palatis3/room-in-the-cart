import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testCookingStepOfferSendsOnlyReviewedWordsAndNamedRecipient() async throws {
        let shop = UUID(), peer = UUID(), id = UUID()
        let body: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 2, "authorityEpoch": 1, "pairRevision": 4,
                                   "validUntil": "2027-12-02T18:00:00Z", "otherAdult": ["id": peer.uuidString, "label": "Alex"], "offers": []]
        let bytes = try JSONSerialization.data(withJSONObject: body)
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["cook_step_handoff"]) { req in
            XCTAssertEqual(req.url?.path.components(separatedBy: "/").last, "cooking-step")
            if req.httpMethod == "POST" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
                XCTAssertEqual(Set(json.keys), ["action","id","recipientId","instruction","expiresAt","reviewed","authorityEpoch","shopRevision","pairRevision"])
                XCTAssertEqual(json["instruction"] as? String, "Enjuaga el arroz")
                XCTAssertEqual(json["recipientId"] as? String, peer.uuidString.lowercased())
                XCTAssertEqual(json["reviewed"] as? Bool, true)
            }
            return (200, bytes)
        }
        let page = try await service.fetchCookingStep(in: session)
        _ = try await service.offerCookingStep(in: session, page: page, id: id, instruction: "Enjuaga el arroz", expires: Date().addingTimeInterval(3600))
    }

    func testCookingStepRejectsUnscopedSessionAndImpossibleExpiry() async throws {
        let shop = UUID()
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["adult_checks"]) { _ in
            XCTFail("Unscoped session sent a request")
            return (500, Data())
        }
        do { _ = try await service.fetchCookingStep(in: session); XCTFail("Missing capability") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        let body: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 2, "authorityEpoch": 1, "pairRevision": 4,
                                   "otherAdult": ["id": UUID().uuidString, "label": "Alex"], "validUntil": "2027-12-02T18:02:00Z",
                                   "offers": [["id": UUID().uuidString, "mine": false, "instruction": "Start the rice", "expiresAt": "2027-12-02T18:01:00Z"]]]
        let decoded = try JSONDecoder().decode(CookingStepHandoff.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertThrowsError(try decoded.validate(shop: shop))
    }

    func testOfflineCookingHandoffRefreshCannotReplayOffer() async throws {
        let shop = UUID(), peer = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: ["shopId": shop.uuidString, "shopRevision": 1, "authorityEpoch": 1,
                                                                 "pairRevision": 1, "validUntil": "2027-12-02T18:00:00Z",
                                                                 "otherAdult": ["id": peer.uuidString, "label": "Alex"], "offers": []] as [String: Any])
        var posts = 0
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["cook_step_handoff"]) { req in
            if req.httpMethod == "POST" { posts += 1; throw URLError(.notConnectedToInternet) }
            return (200, bytes)
        }
        let page = try await service.fetchCookingStep(in: session)
        do {
            _ = try await service.offerCookingStep(in: session, page: page, id: UUID(), instruction: "Start the rice", expires: Date().addingTimeInterval(3600))
            XCTFail("An offline offer must remain unconfirmed")
        } catch {}
        let reconnected = try await service.fetchCookingStep(in: session)
        XCTAssertTrue(reconnected.offers.isEmpty)
        XCTAssertEqual(posts, 1)
    }
}
