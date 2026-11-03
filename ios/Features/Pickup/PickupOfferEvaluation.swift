import Foundation
import CryptoKit
import CoreDomain

enum PickupOfferDishDecision: String, Codable, CaseIterable { case accepted, declined, unreviewed }
struct PickupOfferDishRule: Codable, Equatable {
    var needID: UUID
    var decision: PickupOfferDishDecision
    var exclusionsConfirmed: Bool
}
struct PickupOfferEvaluationInputs: Codable, Equatable {
    var offeredUsable: Quantity?
    var retainedOriginalCharge: CostEvidence
    var lineAllowance: Money?
    var dishRules: [PickupOfferDishRule]
    var includedOfferIDs: [UUID]
    /// Complete net cost of unaffected lines and ALL retained charges, taxes,
    /// deposits and discounts; excludes selected original lines and replacements.
    /// Never derived by subtracting an unknown line from an inclusive frozen quote.
    var otherCheckoutCost: CostEvidence
    var wholeCheckoutCap: Money?
    var checkoutSource: String
    var checkoutObservedAt: Date
}
struct PickupOfferEvaluationEvidence: Codable, Equatable {
    let inputs: PickupOfferEvaluationInputs
    let sourceStamp: String
    let dishSourceStamp: String
    let reviewedAt: Date
    let effectiveNoteCeiling: Money?
}
enum PickupOfferEvaluationIssue: String, Equatable, Hashable {
    case unknownUsable, conversionUnknown, dishUnreviewed, exclusionsUnreviewed
    case missingOfferEvidence, noLinkedNeeds, unknownCost, staleSource
}
struct PickupOfferDishCoverage: Equatable {
    let needID: UUID
    let name: String
    let unit: UnitOfMeasure
    let priority: AllocationPriority
    let decision: PickupOfferDishDecision
    let originalAllocated: Rational?
    let replacementAllocated: Rational?
    let shortfall: Rational?
    let issues: [PickupOfferEvaluationIssue]
}
struct PickupOfferSelectedAssessment: Identifiable {
    let id: UUID
    let name: String
    let offerAssessment: PickupOfferCeilingAssessment
    let lineAssessment: PickupOfferCeilingAssessment
    let lineMaximum: Money?
}
struct PickupOfferEvaluationResult {
    let selectedOffers: [PickupOfferSelectedAssessment]
    let combinedCost: CostEvidence
    let minimumCost: Money
    let maximumCost: Money?
    let minimumOverage: Money?
    let lineMaximum: Money?
    let checkoutAssessment: PickupOfferCeilingAssessment
    let offerAssessment: PickupOfferCeilingAssessment
    let replacementMaximum: Money?
    let dishes: [PickupOfferDishCoverage]
    let issues: [PickupOfferEvaluationIssue]
    let cutoff: RetailerCutoffStatus
    let isCurrent: Bool
}
private enum PickupOfferEvaluationError: Error { case invalid, missing }

/// A private, explicit WHAT-IF review. It never writes a receipt, retailer response,
/// frozen checkout, placement fee, stock lot, or cash entry.
enum PickupOfferEvaluation {
    static func review(offer: PickupOffer, inputs: PickupOfferEvaluationInputs,
                       journey: PickupJourney, at: Date) throws -> PickupOfferEvaluationEvidence {
        guard at.timeIntervalSinceReferenceDate.isFinite else { throw PickupOfferEvaluationError.invalid }
        var candidate = offer
        candidate.evaluation = PickupOfferEvaluationEvidence(inputs: inputs, sourceStamp: "", dishSourceStamp: try dishStamp(offer: offer, inputs: inputs, journey: journey), reviewedAt: at, effectiveNoteCeiling: nil)
        let result = try calculate(offer: candidate, journey: journey, at: at, current: true)
        return PickupOfferEvaluationEvidence(inputs: inputs, sourceStamp: try stamp(offer: candidate, journey: journey), dishSourceStamp: try dishStamp(offer: offer, inputs: inputs, journey: journey), reviewedAt: at, effectiveNoteCeiling: effectiveCeiling(offer: offer, result: result))
    }

    static func evaluate(offer: PickupOffer, journey: PickupJourney, at: Date) throws -> PickupOfferEvaluationResult {
        guard offer.evaluation != nil else { throw PickupOfferEvaluationError.missing }
        return try calculate(offer: offer, journey: journey, at: at,
            current: isCurrent(offer: offer, journey: journey))
    }
    static func isCurrent(offer: PickupOffer, journey: PickupJourney) throws -> Bool {
        guard let evidence = offer.evaluation else { return false }
        guard evidence.reviewedAt.timeIntervalSinceReferenceDate.isFinite,
              try evidence.sourceStamp == stamp(offer: offer, journey: journey),
              try evidence.dishSourceStamp == dishStamp(offer: offer, inputs: evidence.inputs, journey: journey) else { return false }
        let result = try calculate(offer: offer, journey: journey, at: evidence.reviewedAt, current: true)
        return evidence.effectiveNoteCeiling == effectiveCeiling(offer: offer, result: result)
    }
    private static func effectiveCeiling(offer: PickupOffer, result: PickupOfferEvaluationResult) -> Money? {
        [offer.ceiling, result.lineMaximum, result.replacementMaximum].compactMap { $0 }.min()
    }

    private static func selected(offer: PickupOffer, journey: PickupJourney) throws -> [PickupOffer] {
        guard let inputs = offer.evaluation?.inputs, !inputs.includedOfferIDs.isEmpty,
              inputs.includedOfferIDs.count <= 200,
              Set(inputs.includedOfferIDs).count == inputs.includedOfferIDs.count,
              inputs.includedOfferIDs.contains(offer.id) else { throw PickupOfferEvaluationError.invalid }
        let result = try inputs.includedOfferIDs.map { id -> PickupOffer in
            if id == offer.id { return offer }
            guard let value = journey.offers.first(where: { $0.id == id }) else { throw PickupOfferEvaluationError.missing }
            return value
        }
        // Alternatives for the same original line cannot both reserve its quantity or charge.
        guard Set(result.map(\.lineID)).count == result.count else { throw PickupOfferEvaluationError.invalid }
        return result
    }

    private struct Basis: Encodable {
        let journeyID: UUID
        let pickup: PickupLedger?
        let basket: BasketPlan?
        let quote: CheckoutQuote?
        let cap: CheckoutCap?
        let context: CheckoutContext?
        let needs: [AllocationNeed]
        let details: [PickupNeedDetail]
        let offers: [OfferBasis]
        let scenario: PickupOfferEvaluationInputs
    }
    private struct SelectedInputs: Encodable {
        let offeredUsable: Quantity?
        let retainedOriginalCharge: CostEvidence
        let dishRules: [PickupOfferDishRule]
        let dishSourceStamp: String?
    }
    private struct OfferBasis: Encodable {
        var offer: PickupOffer
        let inputs: SelectedInputs?
        init(_ original: PickupOffer) {
            inputs = original.evaluation.map { SelectedInputs(offeredUsable: $0.inputs.offeredUsable,
                retainedOriginalCharge: $0.inputs.retainedOriginalCharge, dishRules: $0.inputs.dishRules,
                dishSourceStamp: $0.dishSourceStamp) }
            offer = original; offer.evaluation = nil
        }
    }
    private static func stamp(offer: PickupOffer, journey: PickupJourney) throws -> String {
        let selected = try selected(offer: offer, journey: journey)
        let basis = Basis(journeyID: journey.id, pickup: journey.pickup, basket: journey.basket,
            quote: journey.quote, cap: journey.cap, context: journey.context, needs: journey.needs, details: journey.needDetails,
            offers: selected.sorted { $0.id.uuidString < $1.id.uuidString }.map(OfferBasis.init), scenario: offer.evaluation!.inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(basis)).map { String(format: "%02x", $0) }.joined()
    }

    private struct DishBasis: Encodable {
        let offerID: UUID
        let lineID: UUID
        let replacement: String
        let required: Quantity
        let remaining: Quantity
        let usable: Quantity?
        let rules: [PickupOfferDishRule]
        let needs: [AllocationNeed]
        let details: [PickupNeedDetail]
    }
    private static func dishStamp(offer: PickupOffer, inputs: PickupOfferEvaluationInputs, journey: PickupJourney) throws -> String {
        let needs = journey.needs.filter { $0.orderLineID == offer.lineID }
        let ids = Set(needs.map(\.id))
        let basis = DishBasis(offerID: offer.id, lineID: offer.lineID, replacement: offer.replacement,
            required: offer.required, remaining: offer.remainingOriginal, usable: inputs.offeredUsable,
            rules: inputs.dishRules, needs: needs, details: journey.needDetails.filter { ids.contains($0.id) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(basis)).map { String(format: "%02x", $0) }.joined()
    }

    private static func calculate(offer: PickupOffer, journey: PickupJourney, at: Date,
                                  current: Bool) throws -> PickupOfferEvaluationResult {
        guard let input = offer.evaluation?.inputs, let context = journey.context,
              input.checkoutObservedAt.timeIntervalSinceReferenceDate.isFinite,
              input.checkoutObservedAt <= at.addingTimeInterval(300),
              !input.checkoutSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.checkoutSource.utf8.count <= 2_048 else { throw PickupOfferEvaluationError.invalid }
        let offers = try selected(offer: offer, journey: journey)
        var costs = [input.otherCheckoutCost], costsWithoutCurrentReplacement = [input.otherCheckoutCost]
        var allDishes: [PickupOfferDishCoverage] = [], issues: [PickupOfferEvaluationIssue] = []
        var selectedAssessments: [PickupOfferSelectedAssessment] = []
        for selected in offers {
            guard let line = journey.pickup?.orderLines.first(where: { $0.id == selected.lineID }) else { throw PickupOfferEvaluationError.missing }
            try PickupOfferReview.validate(selected, ordered: line.ordered)
            let evidence = selected.evaluation?.inputs
            let retained = evidence?.retainedOriginalCharge ?? .unknown(reason: pTr("Original charge has not been reviewed"))
            costs.append(retained); costs.append(selected.price)
            costsWithoutCurrentReplacement.append(retained)
            if selected.id != offer.id { costsWithoutCurrentReplacement.append(selected.price) }
            if evidence == nil { issues.append(.missingOfferEvidence) }
            if let evidence {
                _ = try PickupOfferReview.assess(price: evidence.retainedOriginalCharge, ceiling: evidence.lineAllowance)
                if let usable = evidence.offeredUsable {
                    guard usable.amount <= (try Rational(1_000_000_000)) else { throw PickupOfferEvaluationError.invalid }
                    _ = try usable.converted(to: usable.unit)
                }
                let allowed = Set(journey.needs.filter { $0.orderLineID == selected.lineID }.map(\.id))
                guard evidence.dishRules.count <= 500,
                      Set(evidence.dishRules.map(\.needID)).count == evidence.dishRules.count,
                      evidence.dishRules.allSatisfy({ allowed.contains($0.needID) }) else { throw PickupOfferEvaluationError.invalid }
            }
            var quantityEvidence = evidence
            if let evidence, selected.evaluation?.dishSourceStamp != (try dishStamp(offer: selected, inputs: evidence, journey: journey)) {
                // Another offer's old acceptance cannot silently approve changed dishes or exclusions.
                quantityEvidence?.dishRules = []
                issues.append(.dishUnreviewed)
            }
            let lineCost = try sum([retained, selected.price], context: context, cap: evidence?.lineAllowance)
            let lineMaximum: Money?
            if let allowance = evidence?.lineAllowance, let retainedUpper = upper(retained) {
                lineMaximum = Money(minorUnits: max(0, try allowance.subtracting(retainedUpper).minorUnits))
            } else { lineMaximum = nil }
            selectedAssessments.append(PickupOfferSelectedAssessment(id: selected.id, name: selected.replacement,
                offerAssessment: try PickupOfferReview.assess(price: selected.price, ceiling: selected.ceiling),
                lineAssessment: current ? assessment(lineCost) : .unknown, lineMaximum: current ? lineMaximum : nil))
            let dishResults = try allocate(offer: selected, inputs: quantityEvidence, journey: journey, line: line)
            if dishResults.isEmpty { issues.append(.noLinkedNeeds) }
            allDishes += dishResults
            issues += dishResults.flatMap(\.issues)
        }
        let priced = try sum(costs, context: context, cap: input.wholeCheckoutCap)
        let total = cost(priced.total)
        let without = try sum(costsWithoutCurrentReplacement, context: context).total
        let checkoutAssessment = assessment(priced)
        if upper(total) == nil { issues.append(.unknownCost) }
        var lineMaximum: Money?
        if let allowance = input.lineAllowance, let retained = upper(input.retainedOriginalCharge) {
            lineMaximum = Money(minorUnits: max(0, try allowance.subtracting(retained).minorUnits))
        }
        var maximum: Money?
        if let cap = input.wholeCheckoutCap, let otherUpper = without.upperBound {
            let remaining = Money(minorUnits: max(0, try cap.subtracting(otherUpper).minorUnits))
            if let line = input.lineAllowance, let retained = upper(input.retainedOriginalCharge) {
                maximum = try CheckoutEngine.replacementCeiling(lineAllowance: line, retainedOriginalCharge: retained, wholeCheckoutRemaining: remaining)
            } else if input.lineAllowance == nil { maximum = remaining }
            if let ceiling = offer.ceiling, let existing = maximum { maximum = min(existing, ceiling) }
        }
        if !current { issues.append(.staleSource) }
        let overage = input.wholeCheckoutCap.flatMap { cap -> Money? in
            guard priced.total.lowerBound > cap else { return nil }
            return Money(minorUnits: priced.total.lowerBound.minorUnits - cap.minorUnits)
        }
        return PickupOfferEvaluationResult(selectedOffers: selectedAssessments, combinedCost: total, minimumCost: priced.total.lowerBound,
            maximumCost: priced.total.upperBound, minimumOverage: current ? overage : nil,
            lineMaximum: current ? lineMaximum : nil,
            checkoutAssessment: current ? checkoutAssessment : .unknown,
            offerAssessment: try PickupOfferReview.assess(price: offer.price, ceiling: offer.ceiling),
            replacementMaximum: current ? maximum : nil, dishes: allDishes,
            issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue },
            cutoff: try offer.deadline.status(at: at), isCurrent: current)
    }

    private static func assessment(_ result: CheckoutResult) -> PickupOfferCeilingAssessment {
        switch result.cap {
        case .within: return .within
        case .over: return .over
        case .notProvided: return .noCeiling
        case .unresolved, .scopeMismatch: return result.total.upperBound == nil ? .unknown : .conditional
        }
    }

    private static func upper(_ evidence: CostEvidence) -> Money? {
        switch evidence { case .exact(let value): return value; case .bounded(_, let value, _): return value; case .unknown: return nil }
    }
    private static func sum(_ costs: [CostEvidence], context: CheckoutContext, cap: Money? = nil) throws -> CheckoutResult {
        for cost in costs { _ = try PickupOfferReview.assess(price: cost, ceiling: nil) }
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .components(lines: costs.enumerated().map { index, cost in
                CheckoutLine(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, name: "Reviewed component", cost: cost)
            }, lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        return try CheckoutEngine.evaluate(quote, cap: cap.map { CheckoutCap(scope: .wholeCheckout, commitmentsID: context.commitmentsID, amount: $0) })
    }
    private static func cost(_ amount: CheckoutAmount) -> CostEvidence {
        if let exact = amount.exact { return .exact(exact) }
        if let upper = amount.upperBound { return .bounded(lower: amount.lowerBound, upper: upper, reason: pTr("Reviewed checkout charges have a range")) }
        return .unknown(reason: pTr("Reviewed checkout charges are not fully known"))
    }

    private static func allocate(offer: PickupOffer, inputs: PickupOfferEvaluationInputs?,
                                 journey: PickupJourney, line: PickupOrderLine) throws -> [PickupOfferDishCoverage] {
        let needs = journey.needs.enumerated().filter { $0.element.orderLineID == offer.lineID }
            .sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element)
        var original = try offer.remainingOriginal.converted(to: line.ordered.unit) ?? .zero
        var replacement = try inputs?.offeredUsable?.converted(to: line.ordered.unit)
        var blockedByUnknownDemand = false
        var results: [PickupOfferDishCoverage] = []
        for need in needs {
            let rule = inputs?.dishRules.first { $0.needID == need.id }
            let decision = rule?.decision ?? .unreviewed
            let exclusions = journey.needDetails.first { $0.id == need.id }?.exclusions ?? []
            let cleared = exclusions.isEmpty || rule?.exclusionsConfirmed == true
            var issues: [PickupOfferEvaluationIssue] = []
            if decision == .unreviewed { issues.append(.dishUnreviewed) }
            if decision == .accepted && !cleared { issues.append(.exclusionsUnreviewed) }
            let allowed = decision == .accepted && cleared
            guard let needed = try need.amount.converted(to: line.ordered.unit), !blockedByUnknownDemand else {
                issues.append(.conversionUnknown); blockedByUnknownDemand = true
                results.append(PickupOfferDishCoverage(needID: need.id, name: need.name, unit: line.ordered.unit,
                    priority: need.priority, decision: decision, originalAllocated: nil, replacementAllocated: nil, shortfall: nil, issues: issues)); continue
            }
            // Consume reviewed replacement first for accepted dishes, conserving original
            // supply for protected/declined dishes that cannot use the substitute.
            let usedReplacement = allowed ? min(needed, replacement ?? .zero) : .zero
            if let available = replacement { replacement = try available.subtracting(usedReplacement) }
            let afterReplacement = try needed.subtracting(usedReplacement)
            let usedOriginal = min(afterReplacement, original)
            original = try original.subtracting(usedOriginal)
            let shortfall = try afterReplacement.subtracting(usedOriginal)
            var unresolved = false
            if shortfall > .zero && allowed && replacement == nil {
                issues.append(inputs?.offeredUsable == nil ? .unknownUsable : .conversionUnknown); unresolved = true
            }
            if shortfall > .zero && decision == .unreviewed { unresolved = true }
            results.append(PickupOfferDishCoverage(needID: need.id, name: need.name, unit: line.ordered.unit,
                priority: need.priority, decision: decision, originalAllocated: usedOriginal,
                replacementAllocated: allowed && replacement == nil ? nil : usedReplacement,
                shortfall: unresolved ? nil : shortfall, issues: issues))
        }
        return results
    }
}
