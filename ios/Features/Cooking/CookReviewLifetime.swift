import Foundation
import Combine

/// Authorization belongs to one visible review, not the ambient SwiftUI task.
/// Reopening the same route replaces the token so an older suspended action
/// cannot regain authority when the view becomes visible again.
@MainActor final class CookReviewLifetime: ObservableObject {
    private var active: UUID?
    func begin() -> UUID {
        let value = UUID(); active = value; return value
    }
    func end() { active = nil }
    func permits(_ token: UUID) -> Bool { active == token }
}
