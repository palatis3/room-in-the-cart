import Foundation

/// Historical, reproducible evidence from one complete private pantry snapshot.
/// The app must compare the exact basis and resulting claims at the durable save
/// boundary. Decoding this value does not establish current authority or freshness.
public struct CanonicalRecoveryAllocation: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 1_048_576
    public struct Binding: Codable, Equatable, Sendable {
        public let needID: UUID
        public let reservationID: UUID
        public init(needID: UUID, reservationID: UUID) {
            self.needID = needID; self.reservationID = reservationID
        }
    }
    public let version: Int
    public let basis: LedgerCanonicalPackStockEvidence.Basis
    public let journeyRevision: Int64
    public let lots: [InventoryLot]
    public let claims: [InventoryReservation]
    /// Exactly the selected journey's current effective positive demands. Fully
    /// transferred zero remainders have no claim and must not appear here.
    public let bindings: [Binding]
    public let replacementBindings: [Binding]
    public let eligibility: [LedgerCanonicalPackStockEvidence.LotEligibility]
    public let asOf: Date

    public static func review(basis: LedgerCanonicalPackStockEvidence.Basis, journeyRevision: Int64,
                              lots: [InventoryLot], claims: [InventoryReservation], bindings: [Binding],
                              replacementBindings: [Binding],
                              eligibility: [LedgerCanonicalPackStockEvidence.LotEligibility], at instant: Date) throws -> Self {
        let value = Self(version: 1, basis: .init(originID: basis.originID, inventoryRevision: basis.inventoryRevision,
            sourceHeads: basis.sourceHeads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString }),
            journeyRevision: journeyRevision, lots: lots.sorted { $0.id.uuidString < $1.id.uuidString },
            claims: claims.sorted { $0.id.uuidString < $1.id.uuidString }, bindings: bindings.sorted(by: bindingOrder),
            replacementBindings: replacementBindings.sorted(by: bindingOrder),
            eligibility: eligibility.sorted { $0.lotID.uuidString < $1.lotID.uuidString }, asOf: instant)
        try value.validate()
        return value
    }

    public func validate() throws {
        guard version == 1, basis.inventoryRevision >= 0, journeyRevision >= 0,
              asOf.timeIntervalSinceReferenceDate.isFinite, !basis.sourceHeads.isEmpty,
              basis.sourceHeads.count <= LedgerCanonicalPackStockEvidence.maximumSourceHeads,
              Set(basis.sourceHeads.map(\.journeyID)).count == basis.sourceHeads.count,
              basis.sourceHeads.allSatisfy({ $0.revision > 0 }),
              basis.sourceHeads == basis.sourceHeads.sorted(by: { $0.journeyID.uuidString < $1.journeyID.uuidString }),
              lots.count <= InventoryProjection.maximumLots, claims.count <= InventoryProjection.maximumReservations,
              bindings.count <= 10_000, replacementBindings.count <= 1_000,
              Set(lots.map(\.id)).count == lots.count, Set(claims.map(\.id)).count == claims.count,
              lots == lots.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
              claims == claims.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
              Set(eligibility.map(\.lotID)) == Set(lots.map(\.id)), eligibility.count == lots.count,
              eligibility == eligibility.sorted(by: { $0.lotID.uuidString < $1.lotID.uuidString }) else {
            throw MealRecoveryError.invalid
        }
        for values in [bindings, replacementBindings] {
            guard values == values.sorted(by: Self.bindingOrder),
                  Set(values.map(\.needID)).count == values.count,
                  Set(values.map(\.reservationID)).count == values.count else { throw MealRecoveryError.invalid }
        }
        guard Set(bindings.map(\.needID)).isDisjoint(with: replacementBindings.map(\.needID)),
              Set(claims.map(\.id)).isDisjoint(with: replacementBindings.map(\.reservationID)) else { throw MealRecoveryError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(self).count <= Self.maximumEncodedBytes else { throw InventoryError.capacity }
        for (lot, eligible) in zip(lots, eligibility) {
            guard eligible.lotID == lot.id, eligible.source == lot.source,
                  eligible.observationID == lot.observationID else { throw MealRecoveryError.invalid }
            switch lot.source {
            case .manual: guard eligible.receiptEvidenceDigest == nil else { throw MealRecoveryError.invalid }
            case .receipt: guard eligible.receiptEvidenceDigest?.count == 32 else { throw MealRecoveryError.invalid }
            }
        }
        _ = try InventoryProjection.build(originID: basis.originID, lots: lots, reservations: claims, at: asOf)
    }

    struct Evaluation {
        let before: StockAllocationResult
        let after: StockAllocationResult
        let afterClaims: [InventoryReservation]
    }

    func evaluate(before: [StockNeed], after: [StockNeed], replacedNeedIDs: Set<UUID>) throws -> Evaluation {
        try validate()
        let claimIndex = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        let bindingIndex = Dictionary(uniqueKeysWithValues: bindings.map { ($0.needID, $0.reservationID) })
        let replacementIndex = Dictionary(uniqueKeysWithValues: replacementBindings.map { ($0.needID, $0.reservationID) })
        guard Set(before.map(\.id)) == Set(bindingIndex.keys),
              Set(after.map(\.id)).subtracting(before.map(\.id)) == Set(replacementIndex.keys) else { throw MealRecoveryError.invalid }
        for need in before {
            guard let claim = bindingIndex[need.id].flatMap({ claimIndex[$0] }),
                  claim.state != .released, claim.foodID == need.foodID, claim.priority == need.priority,
                  claim.state == .unresolved || claim.amount == need.amount else { throw MealRecoveryError.invalid }
        }
        var updated = claimIndex
        let released = Set(replacedNeedIDs.compactMap { bindingIndex[$0] })
        for id in released {
            guard let claim = updated[id], claim.state == .active, claim.priority != .protected,
                  claim.lotID == nil else { throw MealRecoveryError.protectedAllocation }
            let revision = claim.revision.addingReportingOverflow(1)
            guard !revision.overflow else { throw DomainError.overflow }
            updated[id] = .init(id: id, originID: claim.originID, revision: revision.partialValue,
                foodID: claim.foodID, lotID: claim.lotID, name: claim.name, amount: claim.amount,
                priority: claim.priority, state: .released)
        }
        for need in after where replacementIndex[need.id] != nil {
            guard need.priority == .required, need.amount.amount > .zero else { throw MealRecoveryError.invalid }
            let id = replacementIndex[need.id]!
            updated[id] = .init(id: id, originID: basis.originID, revision: 1, foodID: need.foodID,
                lotID: nil, name: need.name, amount: need.amount, priority: need.priority)
        }
        let afterClaims = updated.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let oldProjection = try InventoryProjection.build(originID: basis.originID, lots: lots, reservations: claims, at: asOf)
        let newProjection = try InventoryProjection.build(originID: basis.originID, lots: lots, reservations: afterClaims, at: asOf)
        let oldCoverage = Dictionary(uniqueKeysWithValues: oldProjection.reservations.map { ($0.id, $0) })
        let newCoverage = Dictionary(uniqueKeysWithValues: newProjection.reservations.map { ($0.id, $0) })
        let oldEdges = Dictionary(grouping: oldProjection.allocations, by: \.needID)
        let newEdges = Dictionary(grouping: newProjection.allocations, by: \.needID)
        let eligible = Dictionary(uniqueKeysWithValues: eligibility.map { ($0.lotID, $0.status) })
        let affectedFoods = Set(before.filter { replacedNeedIDs.contains($0.id) }.map(\.foodID) +
            after.filter { replacementIndex[$0.id] != nil }.map(\.foodID))
        // Every other shop and protected/unknown claim stays in the same graph.
        // A replacement cannot take backing from one of them, even if its own
        // selected-shop display would otherwise look feasible.
        for claim in claims where claim.state != .released && !released.contains(claim.id) {
            guard let old = oldCoverage[claim.id], let new = newCoverage[claim.id] else { throw MealRecoveryError.invalid }
            if old.issues.isEmpty, new.issues.isEmpty, let oldAmount = old.backed, let newAmount = new.backed {
                guard let compared = try newAmount.converted(to: oldAmount.unit, using: claim.amount?.confirmedConversion),
                      compared >= oldAmount.amount else { throw MealRecoveryError.protectedAllocation }
                let oldEligible = (oldEdges[claim.id] ?? []).allSatisfy { eligible[$0.lotID] == .eligible }
                let newEligible = (newEdges[claim.id] ?? []).allSatisfy { eligible[$0.lotID] == .eligible }
                guard !oldEligible || newEligible else { throw MealRecoveryError.protectedAllocation }
            } else if old != new || affectedFoods.contains(claim.foodID) { throw MealRecoveryError.protectedAllocation }
            if claim.lotID != nil {
                guard (oldEdges[claim.id] ?? []).sorted(by: Self.edgeOrder) ==
                      (newEdges[claim.id] ?? []).sorted(by: Self.edgeOrder) else { throw MealRecoveryError.protectedAllocation }
            }
        }
        var afterBindings = bindingIndex.filter { !replacedNeedIDs.contains($0.key) }
        afterBindings.merge(replacementIndex) { _, new in new }
        return Evaluation(before: try scoped(oldProjection, needs: before, bindings: bindingIndex),
            after: try scoped(newProjection, needs: after, bindings: afterBindings), afterClaims: afterClaims)
    }

    private func scoped(_ projection: InventoryProjection, needs: [StockNeed], bindings: [UUID: UUID]) throws -> StockAllocationResult {
        let coverage = Dictionary(uniqueKeysWithValues: projection.reservations.map { ($0.id, $0) })
        let edges = Dictionary(grouping: projection.allocations, by: \.needID)
        let eligible = Dictionary(uniqueKeysWithValues: eligibility.map { ($0.lotID, $0.status) })
        var selectedEdges: [StockAllocationEdge] = []
        let demands = try needs.map { need -> StockDemandCoverage in
            guard let id = bindings[need.id], let row = coverage[id] else { throw MealRecoveryError.invalid }
            let backedEdges = edges[id] ?? []
            let resolved = row.issues.isEmpty && backedEdges.allSatisfy { eligible[$0.lotID] == .eligible }
            selectedEdges += backedEdges.map { .init(lotID: $0.lotID, needID: need.id, foodID: $0.foodID, unit: $0.unit, amount: $0.amount) }
            return .init(id: need.id, foodID: need.foodID, unit: need.amount.unit, needed: need.amount.amount,
                allocated: resolved ? try row.backed?.converted(to: need.amount.unit, using: need.amount.confirmedConversion) : nil,
                shortfall: resolved ? try row.shortfall?.converted(to: need.amount.unit, using: need.amount.confirmedConversion) : nil,
                issues: resolved ? [] : [.usableUnverified])
        }
        let lotIndex = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        let balances = projection.lots.map { row -> StockLotBalance in
            let lot = lotIndex[row.id]!
            let resolved = row.issues.isEmpty && eligible[row.id] == .eligible && row.free != nil
            return .init(lotID: row.id, foodID: lot.foodID, unit: lot.unit,
                remainingUnallocated: resolved ? row.free!.amount : .zero, issues: resolved ? [] : [.usableUnverified])
        }
        return .init(demands: demands, allocations: selectedEdges, remainingLots: balances)
    }
    private static func bindingOrder(_ a: Binding, _ b: Binding) -> Bool { a.needID.uuidString < b.needID.uuidString }
    private static func edgeOrder(_ a: StockAllocationEdge, _ b: StockAllocationEdge) -> Bool {
        (a.needID.uuidString, a.lotID.uuidString) < (b.needID.uuidString, b.lotID.uuidString)
    }
}
