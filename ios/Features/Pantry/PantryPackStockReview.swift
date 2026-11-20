import Foundation
import CryptoKit
import CoreDomain

/// Converts a complete authorized pantry read into pack evidence. Context is a
/// read snapshot, not a lease: callers must obtain and compare a fresh context
/// inside the paired-store commit gate before applying a new selection.
@MainActor enum PantryPackStockReview {
    struct Context {
        let snapshot: PantryRepository.Snapshot
        let mapping: PantryLegacyMigration.Plan
        let asOf: Date
    }

    static func evidence(shop: ShoppingLedger, lineID: UUID, requirement: LedgerPackRequirement,
                         bindings: [DinnerPortionBinding], context: Context) throws -> LedgerCanonicalPackStockEvidence {
        let live = try PantryLiveStockProjection.build(snapshot: context.snapshot, mapping: context.mapping,
            journeyID: shop.id, at: context.asOf)
        guard let head = context.mapping.sourceHeads.first(where: { $0.id == shop.id }) else { throw LedgerPackError.staleSource }
        let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
        try PickupModel.validate(journey)
        guard journey.closedAt == nil, journey.pickup == nil, let basket = journey.basket,
              basket.phase != .reportedPlaced, journey.ledgerSourceRevisionID == shop.revisionID,
              journey.ledgerBasis == shop.basis else { throw LedgerPackError.staleSource }
        let gross = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 0, previous: nil, bindings: bindings)
        guard gross.needs == journey.plannedNeeds else { throw LedgerPackError.staleSource }
        let targetIDs = Set(journey.plannedNeeds.filter { $0.orderLineID == lineID }.map(\.id))
        let needs = journey.physicalStockNeeds.filter { targetIDs.contains($0.id) }
        guard !targetIDs.isEmpty, needs.count == targetIDs.count else { throw LedgerPackError.invalidEvidence }
        let demands = Dictionary(uniqueKeysWithValues: live.demands.map { ($0.id, $0) })
        let claimBindings = try needs.map { need -> LedgerCanonicalPackStockEvidence.ClaimBinding in
            if need.amount.amount == .zero {
                guard live.zeroNeeds.contains(need) else { throw LedgerPackError.invalidEvidence }
                return .init(need: need, reservationID: nil)
            }
            guard let demand = demands[need.id] else { throw LedgerPackError.invalidEvidence }
            return .init(need: need, reservationID: demand.canonicalReservationID)
        }
        let eligibility = try lotEligibility(live: live, context: context)
        return try LedgerCanonicalPackStockEvidence.review(
            scope: .init(journeyID: journey.id, journeyRevision: journey.revision, basketRevisionID: basket.current.id,
                shopRevisionID: shop.revisionID, lineID: lineID),
            basis: .init(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
                sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) }),
            requirement: requirement, claimBindings: claimBindings, canonicalLots: context.snapshot.lots,
            canonicalReservations: context.snapshot.reservations, projection: context.snapshot.availability, eligibility: eligibility)
    }

    /// Receipt provenance is shared by pack and meal-recovery projections. The
    /// canonical count remains authoritative; historical receipts only qualify it.
    static func lotEligibility(live: PantryLiveStockProjection, context: Context) throws -> [LedgerCanonicalPackStockEvidence.LotEligibility] {
        let receiptDigests = try receiptMaterial(context.mapping)
        return try live.lots.map { lot -> LedgerCanonicalPackStockEvidence.LotEligibility in
            let digest: Data?
            if case .receipt(_, let key) = lot.current.source {
                // Even missing receipt evidence has a deterministic explicit proof;
                // the live reader marks it unresolved and cannot grant coverage.
                if let existing = receiptDigests[key] { digest = existing }
                else { digest = Data(SHA256.hash(data: try encoded(MissingReceipt(key: key)))) }
            } else { digest = nil }
            let status: LedgerCanonicalPackStockEvidence.LotEligibility.Status
            if lot.issues.contains(.receiptIneligible) { status = .ineligible }
            else if lot.issues.isEmpty { status = .eligible }
            else { status = .unresolved }
            return .init(lotID: lot.id, source: lot.current.source, observationID: lot.currentObservationID,
                status: status, receiptEvidenceDigest: digest)
        }
    }

    static func currentEvidence(for selection: LedgerPackSelection, shop: ShoppingLedger,
                                bindings: [DinnerPortionBinding], context: Context) throws -> LedgerCanonicalPackStockEvidence {
        guard selection.canonicalStockEvidence != nil else { throw LedgerPackError.staleSource }
        return try evidence(shop: shop, lineID: selection.lineID,
            requirement: LedgerPackRequirement.review(shop: shop, lineID: selection.lineID, bindings: bindings),
            bindings: bindings, context: context)
    }

    /// Applied baskets may survive bookkeeping-only source revisions. This is not
    /// evidence for a new checkout change; only the exact retained basket qualifies.
    static func basketBasisIsCurrent(_ journey: PickupJourney, shop: ShoppingLedger, workspaceID: UUID,
                                     bindings: [DinnerPortionBinding], context: Context) -> Bool {
        guard let basket = journey.basket else { return true }
        if basket.phase == .reportedPlaced { return true }
        guard let head = context.mapping.sourceHeads.first(where: { $0.id == journey.id }),
              (try? JSONDecoder().decode(PickupJourney.self, from: head.payload)) == journey else { return false }
        for selection in journey.ledgerPackSelections {
            if selection.isGrossOnlyPurchase {
                guard (try? selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: bindings)) == true,
                      let line = basket.current.lines.first(where: { $0.id == selection.lineID }),
                      selection.matchesAppliedPurchase(line, shop: shop),
                      line.expectedCost == selection.selectedResult.totalCost.map(CostEvidence.exact) else { return false }
                continue
            }
            guard selection.canonicalStockEvidence != nil,
                  let current = try? currentEvidence(for: selection, shop: shop, bindings: bindings, context: context),
                  (try? selection.isCurrentForAppliedBasket(in: shop, workspaceID: workspaceID, bindings: bindings,
                    currentCanonicalEvidence: current, basket: basket, retainedSelections: journey.ledgerPackSelections)) == true else { return false }
        }
        return true
    }

    private struct MissingReceipt: Encodable { let key: ReceiptKey }
    private struct ReceiptRow: Encodable {
        let journeyID: UUID
        let orderID: UUID
        let orderLines: [PickupOrderLine]
        let fragments: [ReceiptFragment]
        let observations: [UsableObservation]
    }
    private struct ReceiptMaterial: Encodable {
        let key: ReceiptKey
        let receipts: [ReceiptRow]
        let aliases: [PantryLegacyMigration.LegacyReference]
    }
    /// Preserve original receipt and alias facts across every saved source. Do not
    /// include savedAt, quote/note revisions or a newly applied basket in this hash.
    private static func receiptMaterial(_ mapping: PantryLegacyMigration.Plan) throws -> [ReceiptKey: Data] {
        var rows: [ReceiptKey: [ReceiptRow]] = [:]
        for head in mapping.sourceHeads.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            try PickupModel.validate(journey)
            guard let pickup = journey.pickup else { continue }
            let fragments = Dictionary(grouping: pickup.receipts, by: \.key)
            let observations = Dictionary(grouping: pickup.usableObservations, by: \.receipt)
            for key in Set(fragments.keys).union(observations.keys) {
                rows[key, default: []].append(.init(journeyID: journey.id, orderID: pickup.orderID,
                    orderLines: pickup.orderLines.filter { $0.id == key.orderLineID }, fragments: fragments[key] ?? [], observations: observations[key] ?? []))
            }
        }
        var aliases: [ReceiptKey: [PantryLegacyMigration.LegacyReference]] = [:]
        for link in mapping.sourceLinks {
            guard case .receipt(_, let key) = link.source else { continue }
            aliases[key] = link.references.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString }
        }
        var result: [ReceiptKey: Data] = [:]
        for key in Set(rows.keys).union(aliases.keys) {
            result[key] = Data(SHA256.hash(data: try encoded(ReceiptMaterial(key: key,
                receipts: rows[key] ?? [], aliases: aliases[key] ?? []))))
        }
        return result
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
