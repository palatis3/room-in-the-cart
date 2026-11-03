import Foundation

/// Route identity is captured when a destination opens. A different selected shop
/// or account never silently turns an already-open destination into a new authority.
struct ContextualHouseholdScope: Equatable {
    let subject: String
    let householdID: String
    let memberID: String
    let shopID: String?
    let role: String
    let capabilities: Set<String>

    func allows(_ destination: ContextualHouseholdDestination, current: Self?) -> Bool {
        current == self && permits(destination)
    }

    func permits(_ destination: ContextualHouseholdDestination) -> Bool {
        guard !subject.isEmpty, !householdID.isEmpty, !memberID.isEmpty,
              ["shopper", "organizer"].contains(role) else { return false }
        switch destination {
        case .inbox:
            return role == "shopper" && shopID != nil && Set(["shopper_inbox", "request_preview", "shopper_commands"]).isSubset(of: capabilities)
        case .managedViews:
            return capabilities.contains("household_admin") || permits(.composer)
        case .composer: return role == "shopper" && shopID != nil
        }
    }
}
enum ContextualHouseholdDestination: String, Codable, Hashable { case inbox, managedViews, composer }
