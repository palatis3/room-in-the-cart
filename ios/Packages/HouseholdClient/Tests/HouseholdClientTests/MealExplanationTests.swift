import XCTest
@testable import HouseholdClient

final class MealExplanationTests: XCTestCase {
    private func request() throws -> MealExplanationRequest {
        let id = UUID()
        return try .init(consentingTo: [.init(id: id, text: "Tacos")], candidates: [.init(id: id, allowedReasons: [.pantryMatch, .needsMoreFood])], locale: "es")
    }
    private func data(_ request: MealExplanationRequest, suggestion: [String: Any], extra: Bool = false) throws -> Data {
        var object: [String: Any] = ["version": 1, "requestID": request.requestID.uuidString, "suggestions": [suggestion]]
        if extra { object["stock"] = 100 }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testOnlyExactEligibleIDsAndAllowedReasonsAreAccepted() throws {
        let request = try request(), id = request.candidates[0].id.uuidString
        let valid: [String: Any] = ["sourceLineID": id, "reasons": ["pantry_match", "needs_more_food"]]
        let decoded = try JSONDecoder().decode(MealExplanationReply.self, from: data(request, suggestion: valid))
        XCTAssertNoThrow(try decoded.validate(for: request))
        for bad in [["sourceLineID": UUID().uuidString, "reasons": ["pantry_match"]],
                    ["sourceLineID": id, "reasons": ["ingredients_covered"]]] as [[String: Any]] {
            let reply = try JSONDecoder().decode(MealExplanationReply.self, from: data(request, suggestion: bad))
            XCTAssertThrowsError(try reply.validate(for: request))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(MealExplanationReply.self, from: data(request, suggestion: valid, extra: true)))
        var invented = valid; invented["explanation"] = "Safe and free"
        XCTAssertThrowsError(try JSONDecoder().decode(MealExplanationReply.self, from: data(request, suggestion: invented)))
        var repeated = valid; repeated["reasons"] = ["pantry_match", "pantry_match"]
        XCTAssertThrowsError(try JSONDecoder().decode(MealExplanationReply.self, from: data(request, suggestion: repeated)))
    }
    func testRequestContainsOnlySelectedTitlesAndReasonCodesAndBoundsTime() throws {
        let request = try request()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "requestID", "issuedAt", "consent", "locale", "sourceLines", "candidates"])
        XCTAssertThrowsError(try MealExplanationRequest(consentingTo: request.sourceLines, candidates: request.candidates, locale: "es", now: .init(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try MealExplanationRequest(consentingTo: request.sourceLines, candidates: [.init(id: UUID(), allowedReasons: [.pantryMatch])], locale: "es"))
    }
}
