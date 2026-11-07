import Foundation
import CoreDomain

extension PickupJourney {
    /// Update the cook's calendar from exact live meal links. The checkout copy,
    /// its quantities, and the text of every saved instruction stay historical.
    func withCurrentMealDates(from shop: ShoppingLedger) -> Self {
        guard id == shop.id, ledgerSourceRevisionID != nil else { return self }
        let sources = Dictionary(uniqueKeysWithValues: shop.contributions.filter { $0.removedAt == nil }.map { ($0.id, $0.source) })
        let meals = Dictionary(uniqueKeysWithValues: shop.mealOccurrences.filter { $0.removedAt == nil }.map { ($0.id, $0) })
        var current = self
        current.needDetails = needDetails.map { detail in
            let id = detail.sourceContributionID ?? detail.id
            guard case .meal(let occurrenceID) = sources[id], let meal = meals[occurrenceID],
                  meal.ingredientContributionIDs.contains(id) else { return detail }
            var detail = detail
            detail.scheduledDay = meal.scheduledDay
            return detail
        }
        return current
    }
}

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
        // Mirror the allocator's current demand set, including pre-placement plans and
        // stock-only protected reservations. Urgent metadata enriches the same need ID.
        let demands = value.physicalStockNeeds
        var renderedIDs = Set<UUID>()
        for need in value.recoveryCurrentUrgent where renderedIDs.insert(need.id).inserted {
            let name = "\(need.meal): \(need.food)"
            let demand = demands.first { $0.id == need.id }
            let coverage = allocation?.demands.first { $0.id == need.id }
            var lines = [name, "\(pCook("Required", language: language)): \(pQuantity(demand?.amount ?? need.required, language: language))"]
            if demand?.priority == .protected { lines.append(pCook("set aside first", language: language)) }
            lines += coverageLines(coverage, language: language)
            if need.carriedFromID == nil {
                lines.append("\(pCook("Initially observed available", language: language)): \(pQuantity(need.available, language: language)) · \(formatter.string(from: need.confirmedAt))")
            } else if coverage?.allocated == nil || coverage?.allocated == .zero {
                lines.append(pCook("Reconfirmation required", language: language))
            }
            lines.append(need.due.map { "\(pCook("Needed by", language: language)): \(formatter.string(from: $0))" } ?? pCook("Deadline unknown", language: language))
            let warning = pCook("Open need: review before cooking.", language: language)
            let unresolved = !need.resolved || coverage?.shortfall != .zero || coverage?.issues.isEmpty == false
            if unresolved { lines.append(warning) }
            pieces.append(.init(key: "urgent/\(need.id)", text: lines.joined(separator: "\n\n"), unresolved: unresolved ? "\(name) · \(warning)" : nil))
        }
        for need in demands where renderedIDs.insert(need.id).inserted {
            var lines = ["\(need.name): \(pQuantity(need.amount, language: language))\(need.priority == .protected ? (" — " + pCook("set aside first", language: language)) : "")"]
            if let record = value.awayCarryovers.first(where: {
                $0.intent.plan.link.reservationID == need.id && ($0.phase == .reserved || $0.phase == .completed)
            }) {
                let plan = record.intent.plan
                lines.append(pCook("Physical source", language: language) + ": " + record.intent.supply.name)
                lines.append(pCook("Carryover dinner date", language: language) + ": " + plan.day.iso8601 + " · " + plan.day.timeZoneIdentifier)
                if !plan.targetExclusions.isEmpty {
                    lines.append(pCook("Keep these exclusions", language: language) + ": " + pExclusions(plan.targetExclusions))
                }
                if record.phase == .reserved {
                    lines.append(pCook("The physical reservation is saved; the calendar target still needs confirmation.", language: language))
                }
            }
            let coverage = allocation?.demands.first { $0.id == need.id }
            lines += coverageLines(coverage, language: language)
            let warning = pCook("Short or unverified amount. Review.", language: language)
            let unresolved = coverage?.shortfall != .zero || coverage?.issues.isEmpty == false
            if unresolved { lines.append(warning) }
            pieces.append(.init(key: "need/\(need.id)", text: lines.joined(separator: "\n\n"), unresolved: unresolved ? "\(need.name) · \(warning)" : nil))
        }
        var renderedDetails: [UUID: Set<String>] = [:]
        for detail in value.recoveryCurrentDetails where renderedIDs.contains(detail.id) {
            // Lunch and dinner allocations can share the same original ingredient instructions.
            let sourceID = detail.sourceContributionID ?? detail.id
            var lines: [String] = []
            let exclusions = pExclusions(detail.exclusions)
            if !exclusions.isEmpty { lines.append("\(detail.mealName) · \(pCook("Keep these exclusions", language: language)): \(exclusions)") }
            if let day = detail.scheduledDay { lines.append("\(detail.mealName): \(day.iso8601) · \(day.timeZoneIdentifier)") }
            if let due = detail.due { lines.append("\(pCook("Needed by", language: language)): \(formatter.string(from: due))") }
            lines += detail.preparationNotes ?? []
            if let source = detail.sourceURL { lines.append(source) }
            if let minutes = detail.leadTimeMinutes { lines.append("\(pCook("Saved elapsed preparation minutes", language: language)): \(minutes)") }
            if let prep = detail.recoveryPreparation {
                if detail.due == nil { lines.append(pCook("Deadline unknown", language: language)) }
                if detail.leadTimeMinutes == nil { lines.append(pCook("Remaining preparation time unknown", language: language)) }
                if let lead = prep.requiredLeadMinutes {
                    lines.append(pCook("Required advance preparation (minutes)", language: language) + ": " + String(lead))
                }
                if prep.advanceComplete { lines.append(pCook("Advance preparation confirmed complete", language: language)) }
            }
            if !detail.completedSteps.isEmpty { lines.append("\(pCook("Steps already marked complete", language: language)): \(detail.completedSteps.joined(separator: "; "))") }
            let text = lines.joined(separator: "\n\n")
            if !text.isEmpty, renderedDetails[sourceID, default: []].insert(text).inserted {
                pieces.append(.init(key: "detail/\(detail.id)", text: text, unresolved: nil))
            }
        }
        for repair in value.currentRepairInstructions {
            let timing = pCook(repair.timingConfirmed ? "Entered preparation time fits the deadline" : "Timing conditional or deadline missed · review before cooking", language: language)
            pieces.append(.init(key: "repair/\(repair.id)", text: "\(repair.instruction)\n\(timing)", unresolved: repair.timingConfirmed ? nil : "\(repair.instruction) · \(timing)"))
        }
        return pieces
    }
    private static func coverageLines(_ coverage: StockDemandCoverage?, language: String) -> [String] {
        let unresolved = pCook("Unresolved", language: language)
        let allocated = coverage.flatMap { coverage in coverage.allocated.map { pQuantity($0, unit: coverage.unit, language: language) } } ?? unresolved
        let shortfall = coverage.flatMap { coverage in coverage.shortfall.map { pQuantity($0, unit: coverage.unit, language: language) } } ?? unresolved
        return ["\(pCook("Allocated", language: language)): \(allocated)", "\(pCook("Still short", language: language)): \(shortfall)"]
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

/// Ephemeral local view binding, deliberately not Codable or a remote access token.
struct PickupCookReadbackBinding {
    let authorityBindingID = UUID()
    let sourceID: UUID
    let sourceRevision: Int64
    let createdAt: Date
    let text: String
    let localeIdentifier: String
    let startBefore: Date
    private let scope: PickupCookReadbackScope
    private let timeZone: TimeZone
    var instruction: CookReadbackInstruction {
        .init(authorityBindingID: authorityBindingID, sourceID: sourceID, sourceRevision: sourceRevision,
              createdAt: createdAt, startBefore: startBefore, text: text, localeIdentifier: localeIdentifier,
              excludesPrivateBudget: true)
    }
    init?(journey: PickupJourney, allocation: StockAllocationResult?, result: CheckoutResult?,
          language: String, includeBudget: Bool, text: String, context: PickupCookReadbackContext,
          at: Date, timeZone: TimeZone = .current) {
        guard context.permitsLocalReadback, !includeBudget, journey.revision >= 0, !text.isEmpty,
              text == PickupCookProjection.text(journey: journey, allocation: allocation, result: result,
                  language: language, at: at, timeZone: timeZone) else { return nil }
        sourceID = journey.id; sourceRevision = journey.revision; createdAt = at
        self.text = text; localeIdentifier = language; startBefore = at.addingTimeInterval(60)
        scope = context.scope; self.timeZone = timeZone
    }
    /// Recheck live authority and content throughout playback; the model applies the start deadline separately.
    func isCurrent(journey: PickupJourney?, allocation: StockAllocationResult?, result: CheckoutResult?,
                   language: String, includeBudget: Bool, text: String, context: PickupCookReadbackContext, at: Date) -> Bool {
        guard context.permitsLocalReadback, context.scope == scope, !includeBudget,
              at >= createdAt, let journey, journey.id == sourceID, journey.revision == sourceRevision,
              language == localeIdentifier, text == self.text else { return false }
        return text == PickupCookProjection.text(journey: journey, allocation: allocation, result: result,
            language: language, at: createdAt, timeZone: timeZone)
    }
}
