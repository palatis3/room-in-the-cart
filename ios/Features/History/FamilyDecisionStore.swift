import Foundation
import HouseholdClient

struct FamilyDecisionReference: Codable, Equatable, Identifiable, Sendable {
    let subject: String
    let householdID: String
    let memberID: String
    let shopID: UUID
    let id: UUID
}

struct FamilyDecisionCache: Codable, Equatable, Sendable {
    var pending: [FamilyDecisionIntent] = []
    var records: [FamilyDecisionReference] = []
}

struct FamilyDecisionAccess: Hashable {
    let generation: UUID
    let subject: String
    let householdID: String
    let memberID: String
    let shopID: UUID?
    func matches(_ reference: FamilyDecisionReference) -> Bool {
        reference.subject == subject && reference.householdID == householdID && reference.memberID == memberID
    }
    func matches(_ intent: FamilyDecisionIntent) -> Bool {
        intent.subject == subject && intent.householdID == householdID && intent.memberID == memberID
    }
}
