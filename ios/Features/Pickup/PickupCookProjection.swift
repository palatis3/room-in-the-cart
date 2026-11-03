import Foundation
import CoreDomain

/// Produces the same reviewed handoff for sharing and playback, without mutating the pickup.
/// The caller supplies its timestamp; tests can also supply a fixed local timezone.
enum PickupCookProjection {
    static func text(journey value: PickupJourney, allocation: StockAllocationResult?, result: CheckoutResult?,
                     language: String, includeBudget: Bool = false, at: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: language)
        formatter.timeZone = timeZone
        formatter.dateStyle = .full; formatter.timeStyle = .short
        var lines = [pCook("Cook instruction", language: language), "\(formatter.string(from: at)) · \(pCook("Revision", language: language)) \(value.revision)"]
        lines += pieces(journey: value, allocation: allocation, language: language, timeZone: timeZone).map(\.text)
        if includeBudget, let result { lines.append("\(pCook("Private budget included", language: language)): \(budgetText(result, language: language))") }
        return lines.joined(separator: "\n\n")
    }

    static func pieces(journey value: PickupJourney, allocation: StockAllocationResult?, language: String,
                       timeZone: TimeZone = .current) -> [HandoffPiece] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language); formatter.timeZone = timeZone
        formatter.dateStyle = .full; formatter.timeStyle = .short
        var pieces: [HandoffPiece] = []
        for need in value.urgent {
            let name = "\(need.meal): \(need.food)"
            let warning = pCook("Open need: review before cooking.", language: language)
            var lines = [name, "\(pCook("Required", language: language)): \(pQuantity(need.required, language: language)); \(pCook("Confirmed available", language: language)): \(need.carriedFromID == nil ? pQuantity(need.available, language: language) : (pCook("Reconfirmation required", language: language)))", need.due.map { "\(pCook("Needed by", language: language)): \(formatter.string(from: $0))" } ?? pCook("Deadline unknown", language: language)]
            if !need.resolved { lines.append(warning) }
            pieces.append(.init(key: "urgent/\(need.id)", text: lines.joined(separator: "\n\n"), unresolved: need.resolved ? nil : "\(name) · \(warning)"))
        }
        for need in value.needs {
            var lines = ["\(need.name): \(pQuantity(need.amount, language: language))\(need.priority == .protected ? (" — " + pCook("set aside first", language: language)) : "")"]
            let coverage = allocation?.demands.first { $0.id == need.id }
            if let coverage, let amount = coverage.allocated {
                let quantity = Quantity(amount: amount, unit: coverage.unit, originalLiteral: "")
                lines.append("\(pCook("Allocated", language: language)): \(pQuantity(quantity, language: language))")
            }
            let warning = pCook("Short or unverified amount. Review.", language: language)
            let unresolved = coverage?.shortfall != .zero
            if unresolved { lines.append(warning) }
            pieces.append(.init(key: "need/\(need.id)", text: lines.joined(separator: "\n\n"), unresolved: unresolved ? "\(need.name) · \(warning)" : nil))
        }
        for detail in value.needDetails where value.needs.contains(where: { $0.id == detail.id }) {
            var lines: [String] = []
            if !detail.exclusions.isEmpty { lines.append("\(detail.mealName) · \(pCook("Keep these exclusions", language: language)): \(detail.exclusions.joined(separator: ", "))") }
            if let day = detail.scheduledDay { lines.append("\(detail.mealName): \(day.iso8601) · \(day.timeZoneIdentifier)") }
            if let minutes = detail.leadTimeMinutes { lines.append("\(pCook("Saved elapsed preparation minutes", language: language)): \(minutes)") }
            if !detail.completedSteps.isEmpty { lines.append("\(pCook("Steps already marked complete", language: language)): \(detail.completedSteps.joined(separator: "; "))") }
            if !lines.isEmpty { pieces.append(.init(key: "detail/\(detail.id)", text: lines.joined(separator: "\n\n"), unresolved: nil)) }
        }
        for repair in value.repairs {
            let timing = pCook(repair.timingConfirmed ? "Entered preparation time fits the deadline" : "Timing conditional or deadline missed · review before cooking", language: language)
            pieces.append(.init(key: "repair/\(repair.id)", text: "\(repair.instruction)\n\(timing)", unresolved: repair.timingConfirmed ? nil : "\(repair.instruction) · \(timing)"))
        }
        return pieces
    }
    static func budgetText(_ result: CheckoutResult, language: String) -> String {
        if let exact = result.total.exact { return pMoney(exact) }
        if let upper = result.total.upperBound { return "\(pMoney(result.total.lowerBound)) – \(pMoney(upper))" }
        return "\(pCook("At least", language: language)) \(pMoney(result.total.lowerBound)) · \(pCook("total unresolved", language: language))"
    }
}

/// A live local presentation identity. Saved notes and imported records never supply these values.
struct PickupCookReadbackScope: Equatable {
    let localActorID: UUID
    let accountSubject: String?
    let householdID: String?
    let memberID: String?
    let role: String?
    var permitsLocalReadback: Bool {
        guard let role else { return householdID == nil && memberID == nil }
        return ["shopper", "organizer"].contains(role) && accountSubject != nil && householdID != nil && memberID != nil
    }
}
struct PickupCookReadbackContext: Equatable {
    let scope: PickupCookReadbackScope
    let workspaceUnlocked: Bool
    let householdLocked: Bool
    let saving: Bool
    let pendingSave: Bool
    var permitsLocalReadback: Bool {
        workspaceUnlocked && !householdLocked && !saving && !pendingSave && scope.permitsLocalReadback
    }
}

/// Ephemeral local-view lease, deliberately not Codable and not a remote access token or expiry.
struct PickupCookReadbackBinding {
    let authorityBindingID = UUID()
    let sourceID: UUID
    let sourceRevision: Int64
    let createdAt: Date
    let text: String
    let localeIdentifier: String
    let expiresAt: Date
    private let scope: PickupCookReadbackScope
    private let timeZone: TimeZone
    init?(journey: PickupJourney, allocation: StockAllocationResult?, result: CheckoutResult?,
          language: String, includeBudget: Bool, text: String, context: PickupCookReadbackContext,
          at: Date, timeZone: TimeZone = .current) {
        guard context.permitsLocalReadback, !includeBudget, journey.revision >= 0, !text.isEmpty,
              text == PickupCookProjection.text(journey: journey, allocation: allocation, result: result,
                  language: language, at: at, timeZone: timeZone) else { return nil }
        sourceID = journey.id; sourceRevision = journey.revision; createdAt = at
        self.text = text; localeIdentifier = language; expiresAt = at.addingTimeInterval(60)
        scope = context.scope; self.timeZone = timeZone
    }
    func isCurrent(journey: PickupJourney?, allocation: StockAllocationResult?, result: CheckoutResult?,
                   language: String, includeBudget: Bool, text: String, context: PickupCookReadbackContext, at: Date) -> Bool {
        guard context.permitsLocalReadback, context.scope == scope, !includeBudget,
              at >= createdAt, at < expiresAt, let journey, journey.id == sourceID, journey.revision == sourceRevision,
              language == localeIdentifier, text == self.text else { return false }
        return text == PickupCookProjection.text(journey: journey, allocation: allocation, result: result,
            language: language, at: createdAt, timeZone: timeZone)
    }
}
