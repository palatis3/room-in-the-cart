import Foundation
import CoreDomain

/// Compares the complete offer price only with the shopper's offer-specific limit.
/// This does not establish whole-checkout affordability or retailer acceptance.
enum PickupOfferCeilingAssessment: Equatable {
    case within, over, conditional, unknown, noCeiling
}

enum PickupOfferReview {
    private static let largestAmount: Int64 = 1_000_000_000
    private static let largestMinorCost: Int64 = 1_000_000_000_000

    static func assess(price: CostEvidence, ceiling: Money?) throws -> PickupOfferCeilingAssessment {
        try validate(price)
        if let ceiling { try validate(ceiling) }
        guard let ceiling else { return .noCeiling }
        switch price {
        case .exact(let amount): return amount <= ceiling ? .within : .over
        case .bounded(let lower, let upper, _):
            if upper <= ceiling { return .within }
            if lower > ceiling { return .over }
            return .conditional
        case .unknown: return .unknown
        }
    }

    static func validate(_ offer: PickupOffer, ordered: Quantity) throws {
        guard text(offer.replacement, maximum: 512, required: true),
              text(offer.fallback), text(offer.householdPreference), text(offer.retailerResponse),
              text(ordered.originalLiteral), offer.required.amount > .zero else { throw PickupOfferReviewError.invalid }
        // Offer evidence has a 2 KiB text limit. List imports can retain longer source labels.
        // Conversion also verifies any declared cross-unit basis.
        _ = try ordered.converted(to: ordered.unit)
        for quantity in [offer.required, offer.remainingOriginal] {
            guard text(quantity.originalLiteral), quantity.amount >= .zero, quantity.amount <= (try Rational(largestAmount)),
                  quantity.unit.dimension == ordered.unit.dimension,
                  let converted = try quantity.converted(to: ordered.unit),
                  converted <= (try Rational(largestAmount)) else { throw PickupOfferReviewError.invalid }
        }
        guard let remaining = try offer.remainingOriginal.converted(to: ordered.unit),
              remaining <= ordered.amount else { throw PickupOfferReviewError.invalid }
        _ = try assess(price: offer.price, ceiling: offer.ceiling)
        _ = try RetailerDeadline(cutoff: offer.deadline.cutoff, timeZoneID: offer.deadline.timeZoneID)
    }

    private static func validate(_ money: Money) throws {
        guard (0...largestMinorCost).contains(money.minorUnits) else { throw PickupOfferReviewError.invalid }
    }
    private static func validate(_ price: CostEvidence) throws {
        switch price {
        case .exact(let money): try validate(money)
        case .bounded(let lower, let upper, let reason):
            try validate(lower); try validate(upper)
            guard lower <= upper, text(reason, required: true) else { throw PickupOfferReviewError.invalid }
        case .unknown(let reason):
            guard text(reason, required: true) else { throw PickupOfferReviewError.invalid }
        }
    }
    private static func text(_ value: String, maximum: Int = 2_048, required: Bool = false) -> Bool {
        value.utf8.count <= maximum && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private enum PickupOfferReviewError: Error { case invalid }

extension PickupModel {
    /// The original offer, not the journey revision, is the edit precondition:
    /// unrelated receipt/stock activity must not overwrite or prevent an offer edit.
    @discardableResult
    func saveReviewedOffer(_ offer: PickupOffer, journeyID: UUID, original: PickupOffer?) async -> Bool {
        guard ready, !saving, !hasPendingSave else { return false }
        guard let current = journey, current.id == journeyID,
              let line = current.pickup?.orderLines.first(where: { $0.id == offer.lineID }),
              original == nil || (original?.id == offer.id && original?.lineID == offer.lineID) else {
            error = pTr("Reopen this pickup and review the saved offer before changing it."); return false
        }
        let matching = current.offers.filter { $0.id == offer.id }
        guard matching.count <= 1 else { return false }
        if matching.first == offer { error = nil; return true } // Exact replay: no new revision or action.
        guard matching.first == original else {
            error = pTr("This offer changed. Reopen it before saving your review."); return false
        }
        if offer.evaluation != nil, (try? PickupOfferEvaluation.isCurrent(offer: offer, journey: current)) != true {
            error = pTr("The checkout or meal evidence changed. Review the combined offer forecast again."); return false
        }
        do { try PickupOfferReview.validate(offer, ordered: line.ordered) }
        catch {
            self.error = pTr("Check the offer amounts, original remaining quantity, price, and retailer deadline. Nothing was changed.")
            return false
        }
        return await change { value in
            if let index = value.offers.firstIndex(where: { $0.id == offer.id }) { value.offers[index] = offer }
            else { value.offers.append(offer) }
        }
    }

    /// Copy audit events are attached only to the exact saved offer the user reviewed.
    @discardableResult
    func recordReviewedOfferAction(_ action: PickupOfferAction, offer: PickupOffer, journeyID: UUID) async -> Bool {
        guard ready, !saving, !hasPendingSave, let current = journey, current.id == journeyID,
              current.offers.first(where: { $0.id == offer.id }) == offer,
              action.offerID == offer.id, [.copyAttempted, .copied].contains(action.kind),
              action.occurredAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        if offer.evaluation != nil, (try? PickupOfferEvaluation.isCurrent(offer: offer, journey: current)) != true { return false }
        if let saved = current.offerActions.first(where: { $0.id == action.id }) { return saved == action }
        return await change { $0.offerActions.append(action) }
    }
}
