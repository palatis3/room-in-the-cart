import Foundation
import CoreDomain
import HouseholdClient

struct HouseholdRequestPackScope: Equatable {
    let generation: UUID
    let bootstrap: HouseholdBootstrap
    let request: OwnRequest
    let shop: ShopperShop
}
enum RequestPackAvailability: String, CaseIterable { case confirmed, unavailable, unknown }
struct HouseholdRequestPackCandidate: Identifiable, Equatable {
    let id: String
    var label: String
    var usable: Quantity?
    var price: Money?
    var availability: RequestPackAvailability
    var availablePacks: Int?
    var matchesRequest: Bool
    var feeEligible: Bool
    var source: String
    var observedAt: Date
    var offer: PackOffer { PackOffer(id: id, label: label, usableQuantity: usable, price: price) }
}
struct HouseholdRequestPackResult: Identifiable {
    let candidate: HouseholdRequestPackCandidate
    let calculation: OfferResult
    let available: Bool
    var id: String { candidate.id }
    var canSelect: Bool { candidate.matchesRequest && available && calculation.remainingNeed == .zero && (calculation.packsToBuy.map { (1...10_000).contains($0) } ?? false) }
}
struct HouseholdRequestPackComparison {
    let needed: Quantity
    let results: [HouseholdRequestPackResult]
    /// Only among the reviewed, explicitly matched and available offers with known terms.
    let cheapestIDs: Set<String>
    let hasUnresolvedAlternatives: Bool
}
struct HouseholdRequestPackSelection: Equatable {
    let scope: HouseholdRequestPackScope
    let needed: Quantity
    let candidate: HouseholdRequestPackCandidate
    let line: ShopperBasketLine
    let reviewedAt: Date
    func decisionEvidence() throws -> ReviewedRequestPackEvidence {
        guard let usable = candidate.usable else { throw RequestPackError.invalid }
        func amount(_ value: Quantity) -> ReviewedRequestPackEvidence.Quantity {
            .init(numerator: String(value.amount.numerator), denominator: String(value.amount.denominator), unit: value.unit.rawValue, originalLiteral: value.originalLiteral)
        }
        return try ReviewedRequestPackEvidence(offerId: candidate.id, label: candidate.label, needed: amount(needed), usablePerPack: amount(usable), packs: line.packs, unitPriceMinor: line.unitPriceMinor, availablePackLimit: candidate.availablePacks, quoteSource: candidate.source, quoteObservedAt: candidate.observedAt, reviewedAt: reviewedAt)
    }
    func validate(scope current: HouseholdRequestPackScope, at: Date = Date()) throws {
        guard scope == current, scope.bootstrap.role == "shopper", scope.bootstrap.grantId == nil, scope.bootstrap.enrolled,
              scope.shop.phase == "draft", scope.request.shopId == scope.shop.shopId,
              reviewedAt.timeIntervalSince1970.isFinite, candidate.observedAt <= reviewedAt.addingTimeInterval(300),
              reviewedAt <= at.addingTimeInterval(300) else { throw RequestPackError.stale }
        let result = try HouseholdRequestPackReview.calculate(needed: needed, candidates: [candidate], at: at).results[0]
        guard result.canSelect, result.calculation.packsToBuy == Int64(line.packs),
              candidate.label == line.originalItem, candidate.price.map({ Int($0.minorUnits) }) == line.unitPriceMinor,
              candidate.feeEligible == line.feeEligible else { throw RequestPackError.invalid }
    }
}
enum RequestPackError: Error { case invalid, stale }

enum HouseholdRequestPackReview {
    static func calculate(needed: Quantity, candidates: [HouseholdRequestPackCandidate], at: Date = Date()) throws -> HouseholdRequestPackComparison {
        guard needed.amount > .zero, needed.amount <= (try Rational(1_000_000_000)),
              !candidates.isEmpty, candidates.count <= 20, Set(candidates.map(\.id)).count == candidates.count,
              at.timeIntervalSince1970.isFinite else { throw RequestPackError.invalid }
        let rows = try candidates.map { candidate -> HouseholdRequestPackResult in
            guard !candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.label.count <= 240, candidate.label == candidate.label.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.source.utf8.count <= 2_048, candidate.observedAt.timeIntervalSince1970.isFinite,
                  candidate.observedAt <= at.addingTimeInterval(300),
                  candidate.price.map({ (0...1_000_000_000).contains($0.minorUnits) }) ?? true,
                  candidate.availablePacks.map({ (0...10_000).contains($0) }) ?? true,
                  candidate.usable.map({ $0.amount <= (try! Rational(1_000_000_000)) }) ?? true else { throw RequestPackError.invalid }
            // Same real offer evaluated by the existing engine against an unpriced
            // sentinel; no product identity, yield, stock or price is invented.
            let sentinel = PackOffer(id: "unpriced-" + UUID().uuidString, label: "", usableQuantity: nil, price: nil)
            let calculated = try PackComparison.evaluate(ComparisonRequest(itemName: candidate.label, needed: needed,
                offerA: candidate.offer, offerB: sentinel)).offerA
            let available = candidate.availability == .confirmed && (calculated.packsToBuy.map { count in
                candidate.availablePacks.map { count <= Int64($0) } ?? true
            } ?? false)
            return HouseholdRequestPackResult(candidate: candidate, calculation: calculated, available: available)
        }
        let eligible = rows.filter { $0.canSelect && $0.calculation.totalCost != nil }
        let cheapest = eligible.compactMap { $0.calculation.totalCost }.min()
        let ids = Set(eligible.filter { $0.calculation.totalCost == cheapest }.map(\.id))
        return HouseholdRequestPackComparison(needed: needed, results: rows, cheapestIDs: ids,
            hasUnresolvedAlternatives: rows.contains { $0.candidate.availability == .unknown || !$0.candidate.matchesRequest || ($0.candidate.availability != .unavailable && (!$0.available || $0.calculation.totalCost == nil)) })
    }
    static func select(_ row: HouseholdRequestPackResult, needed: Quantity, scope: HouseholdRequestPackScope, at: Date = Date()) throws -> HouseholdRequestPackSelection {
        guard row.canSelect, let packs = row.calculation.packsToBuy else { throw RequestPackError.invalid }
        let selection = HouseholdRequestPackSelection(scope: scope, needed: needed, candidate: row.candidate,
            line: ShopperBasketLine(originalItem: row.candidate.label, packs: Int(packs), unitPriceMinor: row.candidate.price.map { Int($0.minorUnits) }, feeEligible: row.candidate.feeEligible), reviewedAt: at)
        try selection.validate(scope: scope, at: at)
        return selection
    }
}
