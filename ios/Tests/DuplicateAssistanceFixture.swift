import Foundation
import HouseholdClient

extension DuplicateAssistanceRequest {
    func fixtureCandidate(id: UUID) throws -> UUID? {
        let envelope: [String: Any] = ["version": 1, "requestID": base.requestID.uuidString,
            "suggestions": [["sourceLineID": base.sourceLines[0].id.uuidString, "candidateID": id.uuidString]]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try JSONDecoder().decode(DuplicateAssistanceReply.self, from: data).candidate(for: self)
    }
}
