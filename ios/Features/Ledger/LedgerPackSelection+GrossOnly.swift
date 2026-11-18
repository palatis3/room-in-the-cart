import CoreDomain

extension LedgerPackSelection {
    /// A ledger-scoped purchase of the complete requirement. Nil home credit is
    /// absence of pantry evidence, never a numeric observation of zero stock.
    var isGrossOnlyPurchase: Bool {
        guard formatVersion == 1, stockEvidence == nil, canonicalStockEvidence == nil,
              request.confirmedAtHome == nil, outcome == nil,
              (try? validate()) != nil,
              let packs = selectedResult.packsToBuy, packs > 0,
              let purchased = selectedResult.purchasedAmount, purchased > .zero else { return false }
        return true
    }
}
