import Foundation

/// Exact confirmed bytes survive a lost response and fresh sign-in, even after device revocation.
public struct HouseholdExitIntent: Codable, Sendable {
    public let subject, householdID, memberID, householdLabel: String
    let bytes: Data
    public init(subject: String, household: DeletionPreview.Household, preview: DeletionPreview, choices: DeletionChoices) throws {
        guard !subject.isEmpty, UUID(uuidString: household.householdId) != nil else { throw ClientError.configuration }
        struct Input: Encodable { let clientKey: String; let confirm = true; let disposition: HouseholdDisposition }
        bytes = try encoded(Input(clientKey: UUID().uuidString.lowercased(), disposition: choices.exit(household, in: preview)))
        self.subject = subject
        householdID = household.householdId
        memberID = household.memberId
        householdLabel = household.label
    }
}
