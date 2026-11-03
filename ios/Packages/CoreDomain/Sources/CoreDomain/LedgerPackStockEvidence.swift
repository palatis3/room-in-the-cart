import Foundation

/// The complete reviewed allocation basis, rather than a free-standing pantry total.
/// A caller must also compare this snapshot with the live pickup store before use.
public struct LedgerPackStockEvidence: Codable, Equatable, Sendable {
    public let sourceWorkspaceID: UUID
    public let journeyID: UUID
    public let journeyRevision: Int64
    public let basketRevisionID: UUID
    public let shopRevisionID: UUID
    public let lineID: UUID
    public let listNeedIDs: [UUID]
    public let lots: [ConfirmedStockLot]
    public let needs: [StockNeed]
    public let reservations: [ConfirmedStockReservation]

    public init(sourceWorkspaceID: UUID, journeyID: UUID, journeyRevision: Int64, basketRevisionID: UUID,
                shopRevisionID: UUID, lineID: UUID, listNeedIDs: [UUID], lots: [ConfirmedStockLot],
                needs: [StockNeed], reservations: [ConfirmedStockReservation]) {
        self.sourceWorkspaceID = sourceWorkspaceID; self.journeyID = journeyID; self.journeyRevision = journeyRevision
        self.basketRevisionID = basketRevisionID; self.shopRevisionID = shopRevisionID; self.lineID = lineID
        self.listNeedIDs = listNeedIDs; self.lots = lots; self.needs = needs; self.reservations = reservations
    }

    public func confirmedQuantity(for requirement: LedgerPackRequirement) throws -> Quantity {
        guard journeyRevision >= 0, lots.count <= 10_000, needs.count <= 10_000,
              reservations.count <= 1_000, !listNeedIDs.isEmpty, listNeedIDs.count <= 10_000,
              Set(listNeedIDs).count == listNeedIDs.count,
              lots.allSatisfy({ $0.source == .pantry || $0.source == .freezer }) else { throw LedgerPackError.invalidEvidence }
        let target = Set(listNeedIDs)
        let partition = needs.filter { target.contains($0.id) }
        guard partition.count == target.count, partition.allSatisfy({ $0.foodID == lineID }) else { throw LedgerPackError.invalidEvidence }
        var gross = Rational.zero, protected = Rational.zero
        for need in partition {
            guard let amount = try need.amount.converted(to: requirement.quantity.unit) else { throw LedgerPackError.invalidEvidence }
            gross = try gross.adding(amount)
            if need.priority == .protected { protected = try protected.adding(amount) }
        }
        guard gross == requirement.quantity.amount, protected == requirement.protectedQuantity.amount else { throw LedgerPackError.staleSource }
        let allocation = try ConfirmedCarryoverAllocator.allocate(lots: lots, needs: needs, reservations: reservations)
        var confirmed = Rational.zero
        for demand in allocation.demands where target.contains(demand.id) {
            guard demand.issues.isEmpty, let allocated = demand.allocated,
                  let converted = try Quantity(amount: allocated, unit: demand.unit, originalLiteral: allocated.description)
                    .converted(to: requirement.quantity.unit) else { throw LedgerPackError.invalidEvidence }
            confirmed = try confirmed.adding(converted)
        }
        guard confirmed <= gross else { throw LedgerPackError.invalidEvidence }
        return Quantity(amount: confirmed, unit: requirement.quantity.unit, originalLiteral: confirmed.description)
    }
}
