import Foundation

enum GuardianCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Guardian") }
    static func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    static func state(_ state: String) -> String {
        switch state {
        case "awaiting_verification": return text("Adulthood verification needed")
        case "verification_pending": return text("Waiting for verified adulthood result")
        case "verification_uncertain": return text("Verification result is not confirmed")
        case "verified": return text("Adulthood verified; permission still needed")
        case "consented": return text("Permission recorded; child invitation needed")
        case "child_claimed": return text("Child device is waiting for your confirmation")
        case "child_approved": return text("Child device confirmed; finish on that device")
        case "active": return text("Own-request access is active")
        case "cancelled": return text("Setup cancelled")
        case "expired": return text("Setup expired")
        case "withdrawn": return text("Permission withdrawn")
        default: return text("Check current setup status")
        }
    }
}
