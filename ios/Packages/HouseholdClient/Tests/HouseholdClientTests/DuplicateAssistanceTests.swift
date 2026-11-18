import Foundation
import XCTest
@testable import HouseholdClient

final class DuplicateAssistanceTests: XCTestCase {
    func testConsentWireNamesOnlyReviewedCandidatesAndReplyCannotSubstituteAnIdentity() throws {
        let source = LanguageSourceLine(id: UUID(), text: "FRJ NEG")
        let known = LanguageSourceLine(id: UUID(), text: "FRJ NEG · Frijoles negros")
        let request = try DuplicateAssistanceRequest(consentingTo: source, candidates: [known], locale: "es")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["version", "requestID", "issuedAt", "consent", "locale", "sourceLines", "candidates"])
        XCTAssertEqual(body["consent"] as? Bool, true)
        func reply(_ values: [[String: String]], id: UUID? = nil) throws -> DuplicateAssistanceReply {
            try JSONDecoder().decode(DuplicateAssistanceReply.self, from: JSONSerialization.data(withJSONObject: [
                "version": 1, "requestID": (id ?? request.base.requestID).uuidString, "suggestions": values
            ]))
        }
        let match = ["sourceLineID": source.id.uuidString, "candidateID": known.id.uuidString]
        XCTAssertEqual(try reply([match]).candidate(for: request), known.id)
        XCTAssertNil(try reply([]).candidate(for: request))
        XCTAssertThrowsError(try reply([match, match]).candidate(for: request))
        XCTAssertThrowsError(try reply([match], id: UUID()).candidate(for: request))
        XCTAssertThrowsError(try reply([["sourceLineID": source.id.uuidString, "candidateID": UUID().uuidString]]).candidate(for: request))
        XCTAssertThrowsError(try reply([["sourceLineID": UUID().uuidString, "candidateID": known.id.uuidString]]).candidate(for: request))
        XCTAssertThrowsError(try DuplicateAssistanceRequest(consentingTo: source, candidates: [], locale: "es"))
        XCTAssertThrowsError(try DuplicateAssistanceRequest(consentingTo: source, candidates: [known, known], locale: "es"))

        let family = FamilyDuplicateBasis(shopID: UUID(), shopRevision: 5, authorityEpoch: 1, requestRevision: 3)
        let shared = try DuplicateAssistanceRequest(consentingTo: source, candidates: [known], locale: "en", family: family)
        let scoped = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any])
        XCTAssertEqual(scoped["shopID"] as? String, family.shopID.uuidString)
        XCTAssertEqual(scoped["requestRevision"] as? Int, 3)
        XCTAssertEqual(shared.purpose, "request-duplicate")
        XCTAssertEqual(request.purpose, "receipt-alias")
    }
}
