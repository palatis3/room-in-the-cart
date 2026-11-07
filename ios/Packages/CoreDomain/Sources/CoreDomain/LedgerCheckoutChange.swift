import Foundation

/// The two retailer observations the shopper reviewed before starting a pickup.
/// Subsequent list or budget edits have their own revision and cannot rewrite this evidence.
public struct LedgerCheckoutChange: Codable, Equatable, Sendable {
    public struct Observation: Codable, Equatable, Sendable {
        public let amount: Money?
        public let includesAllCharges: Bool
        public init(amount: Money?, includesAllCharges: Bool) {
            self.amount = amount
            self.includesAllCharges = includesAllCharges
        }
        public var confirmedTotal: Money? { includesAllCharges ? amount : nil }
    }

    public let name: String
    public let basis: ShopBasis
    public let before: Observation
    public let after: Observation

    public init(name: String, basis: ShopBasis, before: Observation, after: Observation) {
        self.name = name
        self.basis = basis
        self.before = before
        self.after = after
    }

    public func comparison(for shopID: UUID) throws -> CheckoutComparison {
        try basis.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              basis.mode == .pickup, basis.capScope == .wholeShop, basis.capFirmness == .firm,
              let preview = basis.retailerPreview, preview.total == after.confirmedTotal,
              before.amount != nil || after.amount != nil,
              [before.amount, after.amount].compactMap({ $0 }).allSatisfy({ $0 >= .zero }) else {
            throw CheckoutError.invalidEvidence
        }
        // The shopper confirmed the slot matched even if its time wasn't recorded.
        let context = CheckoutContext(storeID: basis.branch, branchID: basis.branch, mode: .pickup,
            slot: basis.slot?.ISO8601Format() ?? "same-undated-slot", commitmentsID: shopID,
            observedAt: preview.capturedAt, source: preview.source)
        func quote(_ observation: Observation) -> CheckoutQuote {
            let evidence = observation.confirmedTotal.map(CostEvidence.exact) ?? .unknown(reason: "Not confirmed")
            return CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(evidence))
        }
        let cap = basis.cap.map { CheckoutCap(scope: .wholeCheckout, commitmentsID: shopID, amount: $0) }
        return try CheckoutEngine.compare(before: quote(before), after: quote(after), cap: cap)
    }
}
