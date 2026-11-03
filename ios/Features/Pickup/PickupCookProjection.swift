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
        for need in value.urgent {
            lines += ["\(need.meal): \(need.food)", "\(pCook("Required", language: language)): \(pQuantity(need.required, language: language)); \(pCook("Confirmed available", language: language)): \(need.carriedFromID == nil ? pQuantity(need.available, language: language) : (pCook("Reconfirmation required", language: language)))", need.due.map { "\(pCook("Needed by", language: language)): \(formatter.string(from: $0))" } ?? (pCook("Deadline unknown", language: language))]
            if !need.resolved { lines.append(pCook("Open need: review before cooking.", language: language)) }
        }
        for need in value.needs {
            lines.append("\(need.name): \(pQuantity(need.amount, language: language))\(need.priority == .protected ? (" — " + pCook("set aside first", language: language)) : "")")
            if let coverage = allocation?.demands.first(where: { $0.id == need.id }) {
                if let amount = coverage.allocated {
                    let quantity = Quantity(amount: amount, unit: coverage.unit, originalLiteral: "")
                    lines.append("\(pCook("Allocated", language: language)): \(pQuantity(quantity, language: language))")
                }
                if coverage.shortfall != .zero { lines.append(pCook("Short or unverified amount. Review.", language: language)) }
            }
        }
        for detail in value.needDetails where value.needs.contains(where: { $0.id == detail.id }) {
            if !detail.exclusions.isEmpty { lines.append("\(detail.mealName) · \(pCook("Keep these exclusions", language: language)): \(detail.exclusions.joined(separator: ", "))") }
            if let day = detail.scheduledDay { lines.append("\(detail.mealName): \(day.iso8601) · \(day.timeZoneIdentifier)") }
            if let minutes = detail.leadTimeMinutes { lines.append("\(pCook("Saved elapsed preparation minutes", language: language)): \(minutes)") }
            if !detail.completedSteps.isEmpty { lines.append("\(pCook("Steps already marked complete", language: language)): \(detail.completedSteps.joined(separator: "; "))") }
        }
        lines += value.repairs.map { "\($0.instruction)\n" + ($0.timingConfirmed ? (pCook("Entered preparation time fits the deadline", language: language)) : (pCook("Timing conditional or deadline missed · review before cooking", language: language))) }
        if includeBudget, let result { lines.append("\(pCook("Private budget included", language: language)): \(budgetText(result))") }
        return lines.joined(separator: "\n\n")
    }
    private static func budgetText(_ result: CheckoutResult) -> String {
        if let exact = result.total.exact { return pMoney(exact) }
        if let upper = result.total.upperBound { return "\(pMoney(result.total.lowerBound)) – \(pMoney(upper))" }
        return "\(pTr("At least")) \(pMoney(result.total.lowerBound)) · \(pTr("total unresolved"))"
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
