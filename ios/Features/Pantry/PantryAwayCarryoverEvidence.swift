import Foundation
import CoreDomain

/// The original reviewed identities survive the prepared phase and restart.
/// Other shops are never serialized as an invented local stock allowance.
struct PantryAwayCarryoverBinding: Codable, Equatable {
    let version: Int
    let basis: LedgerCanonicalPackStockEvidence.Basis
    let lot: InventoryLot
    let sourceClaim: InventoryReservation
    /// False only when reviewing a reservation that already exists. Its old
    /// counted amount is history, not a fresh instruction to recount today's lot.
    let recountsPhysicalSource: Bool
    init(version: Int, basis: LedgerCanonicalPackStockEvidence.Basis, lot: InventoryLot,
         sourceClaim: InventoryReservation, recountsPhysicalSource: Bool = true) {
        self.version = version; self.basis = basis; self.lot = lot; self.sourceClaim = sourceClaim
        self.recountsPhysicalSource = recountsPhysicalSource
    }
    private enum CodingKeys: String, CodingKey { case version, basis, lot, sourceClaim, recountsPhysicalSource }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        basis = try values.decode(LedgerCanonicalPackStockEvidence.Basis.self, forKey: .basis)
        lot = try values.decode(InventoryLot.self, forKey: .lot)
        sourceClaim = try values.decode(InventoryReservation.self, forKey: .sourceClaim)
        recountsPhysicalSource = try values.decodeIfPresent(Bool.self, forKey: .recountsPhysicalSource) ?? true
    }
    func validate(for intent: AwayCarryoverIntent) throws {
        try lot.validate(); try sourceClaim.validate()
        guard version == 1, basis.inventoryRevision >= 0, !basis.sourceHeads.isEmpty,
              basis.sourceHeads.count <= 1_000, basis.sourceHeads.allSatisfy({ $0.revision > 0 }),
              Set(basis.sourceHeads.map(\.journeyID)).count == basis.sourceHeads.count,
              basis.sourceHeads == basis.sourceHeads.sorted(by: { $0.journeyID.uuidString < $1.journeyID.uuidString }),
              basis.sourceHeads.contains(where: { $0.journeyID == intent.plan.link.sourceShopID }),
              lot.source.originID == basis.originID, sourceClaim.originID == basis.originID,
              lot.foodID == intent.supply.foodID, sourceClaim.foodID == intent.sourceNeed.orderLineID else { throw AwayCarryoverError.invalid }
        switch (intent.supply, lot.source) {
        case (.batch(let prior), .manual(_, let id)): guard prior.id == id else { throw AwayCarryoverError.invalid }
        case (.received(let receipt, _), .receipt(_, let key)): guard receipt.key == key else { throw AwayCarryoverError.invalid }
        default: throw AwayCarryoverError.invalid
        }
    }
}

@MainActor enum PantryAwayCarryoverEvidence {
    struct Review {
        let candidate: PickupJourney
        let writeReview: PickupModel.PantryWriteReview
    }
    static func basis(_ context: PantryPackStockReview.Context) -> LedgerCanonicalPackStockEvidence.Basis {
        .init(originID: context.snapshot.state.workspaceID, inventoryRevision: context.snapshot.state.revision,
            sourceHeads: context.mapping.sourceHeads.map { .init(journeyID: $0.id, revision: $0.revision) }
                .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
    }
    static func selectedLot(_ supply: AwayCarryoverSupply, context: PantryPackStockReview.Context) throws -> PantryLiveStockProjection.Lot {
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let source: InventorySource
        switch supply {
        case .batch(let lot): source = .manual(originID: context.snapshot.state.workspaceID, sourceID: lot.id)
        case .received(let receipt, _): source = .receipt(originID: context.snapshot.state.workspaceID, key: receipt.key)
        }
        guard let row = live.lots.first(where: { $0.current.source == source }) else { throw AwayCarryoverError.stale }
        return row
    }
    static func bind(_ intent: AwayCarryoverIntent, context: PantryPackStockReview.Context,
                     recountsPhysicalSource: Bool = true) throws -> AwayCarryoverIntent {
        let row = try selectedLot(intent.supply, context: context)
        try eligible(row)
        let sourceID = try claimID(intent.sourceNeed.id, intent: intent, context: context)
        guard let claim = context.snapshot.reservations.first(where: { $0.id == sourceID }) else { throw AwayCarryoverError.stale }
        var bound = intent
        bound.canonical = .init(version: 1, basis: basis(context), lot: row.current, sourceClaim: claim,
            recountsPhysicalSource: recountsPhysicalSource)
        try AwayCarryoverEngine.validate(bound)
        return bound
    }
    static func preview(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                        context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws {
        guard intent.canonical?.basis == basis(context) else { throw AwayCarryoverError.stale }
        _ = try reserve(intent, journey: journey, context: context, ledger: ledger, at: instant)
    }
    static func prepare(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                        context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> Review {
        try preview(intent, journey: journey, context: context, ledger: ledger, at: instant)
        guard !journey.awayCarryovers.contains(where: { $0.id == intent.id }) else { throw AwayCarryoverError.stale }
        var candidate = journey; candidate.awayCarryovers.append(.init(intent: intent, phase: .prepared))
        let result = try delta(candidate, original: journey, intent: intent, context: context, ledger: ledger, at: instant)
        let target = try targetID(intent, context: context)
        let pin = try selectedLot(intent.supply, context: context).id
        guard let hold = result.reservations.first(where: { $0.id == target }),
              exactHold(hold, intent: intent, pin: pin, origin: context.snapshot.state.workspaceID), hold.revision == 1,
              result.reservations.filter({ $0.id != target }) == context.snapshot.reservations,
              result.lots == context.snapshot.lots else { throw AwayCarryoverError.stale }
        return try review(candidate, delta: result, context: context, ledger: ledger)
    }
    static func reserve(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                        context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> Review {
        guard let captured = intent.canonical, captured.recountsPhysicalSource, captured.basis.originID == context.snapshot.state.workspaceID,
              captured.sourceClaim.id == (try claimID(intent.sourceNeed.id, intent: intent, context: context)),
              let currentSource = context.snapshot.reservations.first(where: { $0.id == captured.sourceClaim.id }),
              currentSource == captured.sourceClaim, currentSource.state == .active, currentSource.lotID == nil,
              currentSource.amount == intent.sourceNeed.amount, currentSource.priority == intent.sourceNeed.priority,
              try selectedLot(intent.supply, context: context).current == captured.lot,
              intent.plan.link.observedAt >= captured.lot.confirmedAt else { throw AwayCarryoverError.stale }
        try eligible(selectedLot(intent.supply, context: context))
        let target = try targetID(intent, context: context)
        let existing = context.snapshot.reservations.first { $0.id == target }
        if let record = journey.awayCarryovers.first(where: { $0.id == intent.id }) {
            guard record.intent == intent, record.phase == .prepared, let existing,
                  exactHold(existing, intent: intent, pin: captured.lot.id, origin: context.snapshot.state.workspaceID) else { throw AwayCarryoverError.stale }
        } else { guard existing == nil, captured.basis == basis(context) else { throw AwayCarryoverError.stale } }
        let candidate = try AwayCarryoverEngine.reservingCanonicalSource(intent, in: journey, at: instant)
        let result = try delta(candidate, original: journey, intent: intent, context: context, ledger: ledger, at: instant)
        try validateTransfer(intent, context: context, result: result, removingHold: existing?.id)
        return try review(candidate, delta: result, context: context, ledger: ledger)
    }

    /// Explicitly adopts an already-reserved migrated operation, without replaying
    /// its historic recount. Only its exact lineage hold may become a live claim.
    static func adoptReserved(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                              context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> Review {
        guard let old = journey.awayCarryovers.first(where: { $0.id == intent.id }), old.phase == .reserved,
              old.intent.canonical == nil, intent.canonical?.recountsPhysicalSource == false,
              intent.canonical?.basis == basis(context) else { throw AwayCarryoverError.stale }
        var compared = intent; compared.canonical = nil
        guard compared == old.intent else { throw AwayCarryoverError.stale }
        try AwayCarryoverEngine.assertTransferred(old.intent, in: journey, at: instant)
        let row = try selectedLot(intent.supply, context: context); try eligible(row)
        let target = try targetID(intent, context: context)
        guard let held = context.snapshot.reservations.first(where: { $0.id == target }),
              held.state != .released, held.lotID == row.id, held.amount == intent.plan.link.quantity,
              held.foodID == intent.supply.foodID, held.priority == .required else { throw AwayCarryoverError.stale }
        var candidate = journey
        candidate.awayCarryovers[candidate.awayCarryovers.firstIndex(where: { $0.id == intent.id })!] = .init(intent: intent, phase: .reserved)
        let result = try delta(candidate, original: journey, intent: intent, context: context, ledger: ledger, at: instant)
        guard result.lots == context.snapshot.lots,
              result.reservations.filter({ $0.id != target }) == context.snapshot.reservations.filter({ $0.id != target }) else { throw AwayCarryoverError.stale }
        try requireTarget(intent, lots: result.lots, claims: result.reservations, projection: result.availability, context: context)
        // An active target already owns its backing. Remove only this operation's
        // unresolved migration hold when checking the reconciliation allocation.
        let baseline = held.state == .unresolved
            ? context.snapshot.reservations.filter { $0.id != target } : context.snapshot.reservations
        try preserveOtherClaims(before: baseline,
            beforeLots: context.snapshot.lots, after: result, excluding: [target], context: context)
        return try review(candidate, delta: result, context: context, ledger: ledger)
    }
    static func assertReserved(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                               context: PantryPackStockReview.Context, at instant: Date) throws {
        try AwayCarryoverEngine.assertTransferred(intent, in: journey, at: instant)
        let row = try selectedLot(intent.supply, context: context); try eligible(row)
        try requireTarget(intent, lots: context.snapshot.lots, claims: context.snapshot.reservations,
            projection: context.snapshot.availability, context: context)
    }
    static func complete(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                         context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> Review {
        try AwayCarryoverEngine.assertTransferred(intent, in: journey, at: instant)
        guard var shop = ledger.workspace.shops.first(where: { $0.id == intent.plan.link.sourceShopID }),
              shop.mealOccurrences.contains(where: { $0.id == intent.plan.occurrenceID }) else { throw AwayCarryoverError.stale }
        try shop.appendConfirmedCarryover(intent.plan, at: instant)
        var candidate = journey
        candidate.awayCarryovers[candidate.awayCarryovers.firstIndex(where: { $0.id == intent.id })!].phase = .completed
        let result = try delta(candidate, original: journey, intent: intent, context: context, ledger: ledger, at: instant)
        guard result.lots == context.snapshot.lots, result.reservations == context.snapshot.reservations else { throw AwayCarryoverError.stale }
        return try review(candidate, delta: result, context: context, ledger: ledger)
    }
    static func cancelPrepared(_ intent: AwayCarryoverIntent, journey: PickupJourney,
                               context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> Review {
        guard journey.awayCarryovers.first(where: { $0.id == intent.id }) == .init(intent: intent, phase: .prepared) else { throw AwayCarryoverError.stale }
        let target = try targetID(intent, context: context), pin = try selectedLot(intent.supply, context: context).id
        guard let held = context.snapshot.reservations.first(where: { $0.id == target }), exactHold(held, intent: intent, pin: pin, origin: context.snapshot.state.workspaceID) else { throw AwayCarryoverError.stale }
        var candidate = journey
        candidate.awayCarryovers[candidate.awayCarryovers.firstIndex(where: { $0.id == intent.id })!].phase = .cancelled
        let result = try delta(candidate, original: journey, intent: intent, context: context, ledger: ledger, at: instant)
        guard held.revision < Int64.max, let released = result.reservations.first(where: { $0.id == target }), released.state == .released,
              released.revision == held.revision + 1, released.amount == held.amount, released.lotID == held.lotID,
              released.originID == held.originID, released.foodID == held.foodID, released.priority == held.priority,
              result.reservations.filter({ $0.id != target }) == context.snapshot.reservations.filter({ $0.id != target }),
              result.lots == context.snapshot.lots else { throw AwayCarryoverError.stale }
        return try review(candidate, delta: result, context: context, ledger: ledger)
    }

    private static func delta(_ candidate: PickupJourney, original: PickupJourney, intent: AwayCarryoverIntent,
                              context: PantryPackStockReview.Context, ledger: LedgerModel, at instant: Date) throws -> PantryPickupDelta.Review {
        guard context.snapshot.state.active, let head = context.mapping.sourceHeads.first(where: { $0.id == original.id }),
              try JSONDecoder().decode(PickupJourney.self, from: head.payload) == original,
              original.revision < Int64.max, head.revision < Int64.max else { throw AwayCarryoverError.stale }
        let ledgerBasis = try PickupModel.CheckoutLedgerBasis(ledger: ledger)
        guard ledgerBasis.originID == intent.workspaceID else { throw AwayCarryoverError.stale }
        var saved = candidate; saved.revision += 1; saved.savedAt = instant
        try saved.synchronizeRecoveryOutside(at: instant); try PickupModel.validate(saved)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let updated = PantryLegacyMigration.SourceHead(id: head.id, revision: head.revision + 1, payload: try encoder.encode(saved), savedAt: instant)
        return try PantryPickupDelta.prepare(operationID: AwayCarryoverEngine.targetID(intent.id, "canonical-preview"),
            originID: context.snapshot.state.workspaceID, prior: context.mapping.sourceHeads,
            proposed: context.mapping.sourceHeads.map { $0.id == head.id ? updated : $0 }, inventory: context.snapshot,
            ledger: .available(originID: ledgerBasis.originID, revision: ledgerBasis.revision, workspace: ledger.workspace), at: instant)
    }
    private static func review(_ candidate: PickupJourney, delta: PantryPickupDelta.Review,
                               context: PantryPackStockReview.Context, ledger: LedgerModel) throws -> Review {
        .init(candidate: candidate, writeReview: .init(inventory: basis(context), ledger: try .init(ledger: ledger),
            resultingReservations: delta.reservations))
    }
    private static func validateTransfer(_ intent: AwayCarryoverIntent, context: PantryPackStockReview.Context,
                                         result: PantryPickupDelta.Review, removingHold: UUID?) throws {
        let source = try claimID(intent.sourceNeed.id, intent: intent, context: context)
        let target = try targetID(intent, context: context)
        let before = context.snapshot.reservations.filter { $0.id != removingHold }
        guard let oldSource = before.first(where: { $0.id == source }) else { throw AwayCarryoverError.stale }
        guard oldSource.revision < Int64.max, let newSource = result.reservations.first(where: { $0.id == source }),
              newSource.revision == oldSource.revision + 1, newSource.originID == oldSource.originID,
              newSource.foodID == oldSource.foodID, newSource.name == oldSource.name,
              newSource.lotID == oldSource.lotID, newSource.priority == oldSource.priority else { throw AwayCarryoverError.stale }
        let remainder = try AwayCarryoverEngine.reducedNeed(intent)
        guard remainder.amount.amount == .zero
            ? (newSource.state == .released && newSource.amount == oldSource.amount)
            : (newSource.state == .active && newSource.amount == remainder.amount) else { throw AwayCarryoverError.stale }
        guard result.reservations.filter({ $0.id != source && $0.id != target }) == before.filter({ $0.id != source }),
              result.lots.filter({ $0.id != intent.canonical?.lot.id }) == context.snapshot.lots.filter({ $0.id != intent.canonical?.lot.id }),
              let selected = result.lots.first(where: { $0.id == intent.canonical?.lot.id }),
              selected.count.quantity == intent.counted else { throw AwayCarryoverError.stale }
        try requireTarget(intent, lots: result.lots, claims: result.reservations, projection: result.availability, context: context)
        let baseline = try InventoryProjection.build(originID: context.snapshot.state.workspaceID, lots: context.snapshot.lots, reservations: before, at: context.asOf)
        let oldBacking = baseline.reservations.first { $0.id == source }
        let newBacking = result.availability.reservations.first { $0.id == source }
        let targetBacking = result.availability.reservations.first { $0.id == target }
        guard targetBacking?.issues.isEmpty == true, let targetAmount = try targetBacking?.backed?.converted(to: intent.sourceNeed.amount.unit) else { throw AwayCarryoverError.insufficient }
        let remainderBacking: Rational
        if newSource.state == .released { remainderBacking = .zero }
        else {
            guard newBacking?.issues.isEmpty == true, let amount = try newBacking?.backed?.converted(to: intent.sourceNeed.amount.unit) else { throw AwayCarryoverError.insufficient }
            remainderBacking = amount
        }
        let total = try remainderBacking.adding(targetAmount)
        if oldBacking?.issues.isEmpty == true, let previous = try oldBacking?.backed?.converted(to: intent.sourceNeed.amount.unit) {
            guard total >= previous else { throw AwayCarryoverError.insufficient }
        } else { guard total >= intent.sourceNeed.amount.amount else { throw AwayCarryoverError.insufficient } }
        try preserveOtherClaims(before: before, beforeLots: context.snapshot.lots, after: result,
            excluding: [source, target], context: context)
    }
    private static func preserveOtherClaims(before: [InventoryReservation], beforeLots: [InventoryLot],
                                             after: PantryPickupDelta.Review, excluding: Set<UUID>, context: PantryPackStockReview.Context) throws {
        let baseline = try InventoryProjection.build(originID: context.snapshot.state.workspaceID, lots: beforeLots, reservations: before, at: context.asOf)
        let old = Dictionary(uniqueKeysWithValues: baseline.reservations.map { ($0.id, $0) })
        let next = Dictionary(uniqueKeysWithValues: after.availability.reservations.map { ($0.id, $0) })
        for claim in before where claim.state != .released && !excluding.contains(claim.id) {
            guard let previous = old[claim.id], let current = next[claim.id] else { throw AwayCarryoverError.stale }
            if previous.issues.isEmpty, current.issues.isEmpty, let p = previous.backed, let n = current.backed,
               let converted = try n.converted(to: p.unit, using: claim.amount?.confirmedConversion) {
                guard converted >= p.amount else { throw AwayCarryoverError.insufficient }
            } else if previous != current {
                guard current.issues.isEmpty, current.shortfall?.amount == .zero else { throw AwayCarryoverError.insufficient }
            }
        }
    }
    private static func requireTarget(_ intent: AwayCarryoverIntent, lots: [InventoryLot], claims: [InventoryReservation],
                                       projection: InventoryProjection, context: PantryPackStockReview.Context) throws {
        let target = try targetID(intent, context: context), selected = try selectedLot(intent.supply, context: context)
        try eligible(selected)
        guard let claim = claims.first(where: { $0.id == target }), claim.state == .active,
              claim.lotID == selected.id, claim.foodID == intent.supply.foodID, claim.priority == .required,
              claim.amount == intent.plan.link.quantity, let coverage = projection.reservations.first(where: { $0.id == target }),
              coverage.issues.isEmpty, coverage.shortfall?.amount == .zero,
              projection.allocations.filter({ $0.needID == target }).allSatisfy({ $0.lotID == selected.id }) else { throw AwayCarryoverError.insufficient }
    }
    private static func eligible(_ row: PantryLiveStockProjection.Lot) throws {
        guard !row.issues.contains(where: { issue in
            switch issue { case .receiptEvidenceUnresolved, .receiptIneligible, .receiptNotCurrent: return true; default: return false }
        }) else { throw AwayCarryoverError.insufficient }
    }
    private static func exactHold(_ claim: InventoryReservation, intent: AwayCarryoverIntent, pin: UUID, origin: UUID) -> Bool {
        claim.state == .unresolved && claim.originID == origin && claim.revision == 1 && claim.name == intent.plan.source.title &&
            claim.lotID == pin && claim.foodID == intent.supply.foodID && claim.amount == intent.plan.link.quantity && claim.priority == .required
    }
    private static func claimID(_ need: UUID, intent: AwayCarryoverIntent, context: PantryPackStockReview.Context) throws -> UUID {
        try PantryLegacyMigration.claimIdentity(originID: context.snapshot.state.workspaceID, needID: need, foodID: intent.supply.foodID)
    }
    private static func targetID(_ intent: AwayCarryoverIntent, context: PantryPackStockReview.Context) throws -> UUID {
        try claimID(intent.plan.link.reservationID, intent: intent, context: context)
    }
}
