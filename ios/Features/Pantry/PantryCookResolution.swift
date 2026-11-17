import CoreDomain
import CryptoKit
import Foundation
import LocalStore

/// Reconciliation is an append-only amendment to one original ingredient-use event.
enum PantryCookResolution {
    enum Action: Hashable { case outsidePantry, alreadyIncluded, deduct, recount }

    enum Decision: Codable, Equatable {
        case outsidePantry
        case alreadyIncluded(lotID: UUID, used: Quantity?)
        case deduct(lotID: UUID, used: Quantity)
        case recount(lotID: UUID, remaining: Quantity, used: Quantity?)

        var lotID: UUID? {
            switch self {
            case .outsidePantry: nil
            case .alreadyIncluded(let id, _), .deduct(let id, _), .recount(let id, _, _): id
            }
        }
        var action: Action {
            switch self {
            case .outsidePantry: .outsidePantry
            case .alreadyIncluded: .alreadyIncluded
            case .deduct: .deduct
            case .recount: .recount
            }
        }
    }

    struct Basis: Codable, Equatable {
        let revision: Int64
        let observationID: UUID
        let confirmedAt: Date
        let unit: UnitOfMeasure
        let count: InventoryCount
    }

    struct Reconstruction: Equatable {
        let original: Quantity
        let previouslyAccounted: Rational
        let otherUnmeasured: Int
    }

    struct Receipt: Codable, Equatable {
        let eventID: UUID
        let operationID: UUID
        let inventoryRevision: Int64
        let confirmedAt: Date
        let decision: Decision
        let basis: Basis?
        let after: InventoryCount?
        let resultObservationID: UUID?
    }

    struct Context {
        let record: PantryCookRecord
        let lots: [InventoryLot]
        let reservations: [InventoryReservation]
        let inventoryRevision: Int64
        let ledgerRevision: Int64
        let journeyRevision: Int64
        var remainingEventIDs: [UUID] { record.remainingUnresolvedUseIDs }

        func actions(eventID: UUID, lotID: UUID?) -> Set<Action> {
            guard remainingEventIDs.contains(eventID),
                  let part = record.draft.parts.first(where: { $0.id == eventID }) else { return [] }
            var result = Set<Action>()
            switch part.use {
            case .untracked: result.insert(.outsidePantry)
            case .lot(let id, _, nil): guard lotID == id else { return [] }
            default: return []
            }
            guard let lotID, let lot = lots.first(where: { $0.id == lotID }),
                  !record.draft.leftovers.contains(where: { $0.id == lotID }) else { return result }
            result.insert(.recount)
            if lot.count.quantity == nil {
                if record.originalCount(lotID: lotID, observationID: lot.observationID)?.unit == lot.unit {
                    result.insert(.deduct)
                }
                return result
            }
            let prior = record.resolutions?.first { $0.resultObservationID == lot.observationID }
            if let action = record.countAction(lotID: lotID, observationID: lot.observationID, confirmedAt: lot.confirmedAt, prior: prior) {
                result.insert(action)
            }
            return result
        }
    }

    struct Review: Equatable {
        let cookID: UUID
        let inventoryID: UUID
        let ledgerID: UUID
        let shopID: UUID
        let mealID: UUID
        let journeyRevision: Int64
        let ledgerRevision: Int64
        let receipt: Receipt
        let affectedHolds: [InventoryReservationCoverage]
        let otherUnresolvedEventsForLot: [UUID]
        let reconstruction: Reconstruction?
        var reconstructionBasis: Quantity? { reconstruction?.original }
        var eventID: UUID { receipt.eventID }
        var decision: Decision { receipt.decision }
        var before: InventoryCount? { receipt.basis?.count }
        var after: InventoryCount? { receipt.after }
    }

    static func identity(_ kind: String, draft: CookCompletionDraft, eventID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("private-cook-resolution/v1/\(kind)/\(draft.inventoryID)/\(draft.id)/\(eventID)".utf8))
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Both the live transaction and the recovered record use the same count arithmetic.
    static func result(_ decision: Decision, basis: Basis?, reconstruction: Reconstruction?) throws -> InventoryCount? {
        guard let basis else {
            guard case .outsidePantry = decision else { throw PantryCookPort.Failure.changed }
            return nil
        }
        let conversion = basis.count.quantity?.confirmedConversion ?? reconstruction?.original.confirmedConversion
        func normalized(_ amount: Quantity, allowZero: Bool = false) throws -> Rational {
            try amount.validate()
            guard amount.amount > .zero || (allowZero && amount.amount == .zero),
                  let converted = try amount.converted(to: basis.unit, using: amount.confirmedConversion ?? conversion)
            else { throw InventoryError.invalid("cookResolutionAmount") }
            return converted
        }
        func quantity(_ amount: Rational) -> InventoryCount {
            .exact(.init(amount: amount, unit: basis.unit, originalLiteral: amount.description,
                         confirmedConversion: conversion))
        }
        switch decision {
        case .outsidePantry: throw PantryCookPort.Failure.changed
        case .alreadyIncluded(_, let used):
            if let used { _ = try normalized(used) }
            guard basis.count.quantity != nil else { throw PantryCookPort.Failure.changed }
            return basis.count
        case .deduct(_, let used):
            let value = try normalized(used)
            let available: Rational
            if let reconstruction {
                available = try reconstruction.original.amount.subtracting(reconstruction.previouslyAccounted)
            } else if let current = basis.count.quantity {
                available = current.amount
            } else {
                throw PantryCookPort.Failure.changed
            }
            guard value <= available else { throw InventoryError.invalid("cookUseExceedsAvailable") }
            if let reconstruction, reconstruction.otherUnmeasured > 0 { return .unknown }
            return try quantity(available.subtracting(value))
        case .recount(_, let remaining, let used):
            if let used { _ = try normalized(used) }
            return try quantity(normalized(remaining, allowZero: true))
        }
    }
}

extension PantryCookRecord {
    var remainingUnresolvedUseIDs: [UUID] {
        let closed = Set((resolutions ?? []).map(\.eventID))
        return draft.unresolvedUseIDs.filter { !closed.contains($0) }
    }

    fileprivate func originalCount(lotID: UUID, observationID: UUID) -> Quantity? {
        guard resultingObservations[lotID] == observationID else { return nil }
        return priorCounts.first { $0.lotID == lotID }?.count.quantity
    }

    /// Only the original unknown head can be reconstructed. A subsequent count or another
    /// cook's unknown head breaks the chain and must be reviewed on its own basis.
    fileprivate func reconstruction(for decision: PantryCookResolution.Decision, eventID: UUID,
                                    basis: PantryCookResolution.Basis?, priorRows: ArraySlice<PantryCookResolution.Receipt>) throws
        -> PantryCookResolution.Reconstruction? {
        guard case .deduct(let lotID, _) = decision, let basis, basis.count.quantity == nil else { return nil }
        guard let original = originalCount(lotID: lotID, observationID: basis.observationID),
              original.unit == basis.unit else { throw PantryCookPort.Failure.changed }
        var accounted = Rational.zero
        var unknown = Set<UUID>()
        func add(_ used: Quantity) throws {
            try used.validate()
            guard used.amount > .zero, let amount = try used.converted(to: original.unit, using: used.confirmedConversion ?? original.confirmedConversion)
            else { throw PantryCookPort.Failure.changed }
            accounted = try accounted.adding(amount)
        }
        for part in draft.parts {
            guard case .lot(let id, _, let used) = part.use, id == lotID else { continue }
            if let used { try add(used) } else { unknown.insert(part.id) }
        }
        for prior in priorRows where prior.decision.lotID == lotID {
            // A recount or external observation can never be the predecessor of this original head.
            guard case .deduct(_, let used) = prior.decision, prior.basis?.observationID == basis.observationID,
                  prior.resultObservationID == nil else { throw PantryCookPort.Failure.changed }
            try add(used)
            unknown.remove(prior.eventID)
        }
        unknown.remove(eventID)
        return .init(original: original, previouslyAccounted: accounted, otherUnmeasured: unknown.count)
    }

    fileprivate func countAction(lotID: UUID, observationID: UUID, confirmedAt: Date,
                                 prior: PantryCookResolution.Receipt?) -> PantryCookResolution.Action? {
        // A physical recount covers all preceding uses. A subtraction covers only its own event.
        if prior?.decision.action == .recount { return .alreadyIncluded }
        if prior?.decision.action == .deduct || resultingObservations[lotID] == observationID || confirmedAt < draft.cookedAt {
            return .deduct
        }
        // A newer count needs explicit confirmation from the person who knows its basis.
        // With equal times and no causal link, only a fresh recount establishes a safe balance.
        return confirmedAt > draft.cookedAt ? .alreadyIncluded : nil
    }

    func validateResolutions() throws {
        guard let resolutions else { return }
        let unresolved = Set(draft.unresolvedUseIDs)
        guard !resolutions.isEmpty, resolutions.count <= unresolved.count,
              Set(resolutions.map(\.eventID)).count == resolutions.count else { throw PantryCookPort.Failure.changed }
        var priorByObservation = [UUID: PantryCookResolution.Receipt]()
        var previousRevision = draft.inventoryRevision
        for (index, row) in resolutions.enumerated() {
            guard unresolved.contains(row.eventID), row.inventoryRevision > previousRevision,
                  row.confirmedAt.timeIntervalSinceReferenceDate.isFinite, row.confirmedAt >= draft.cookedAt,
                  row.operationID == PantryCookResolution.identity("operation", draft: draft, eventID: row.eventID),
                  let part = draft.parts.first(where: { $0.id == row.eventID }) else { throw PantryCookPort.Failure.changed }
            previousRevision = row.inventoryRevision
            if case .lot(let id, _, _) = part.use {
                guard row.decision.lotID == id else { throw PantryCookPort.Failure.changed }
            }
            guard (row.decision.lotID != nil) == (row.basis != nil),
                  !draft.leftovers.contains(where: { $0.id == row.decision.lotID }) else { throw PantryCookPort.Failure.changed }
            if let basis = row.basis, let lotID = row.decision.lotID {
                try basis.count.validate()
                if row.decision.action != .recount {
                    guard row.decision.action == countAction(lotID: lotID, observationID: basis.observationID,
                        confirmedAt: basis.confirmedAt, prior: priorByObservation[basis.observationID]) else { throw PantryCookPort.Failure.changed }
                }
                guard basis.revision >= 1, basis.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
                      basis.confirmedAt <= row.confirmedAt, basis.count.quantity.map({ $0.unit == basis.unit }) ?? true
                else { throw PantryCookPort.Failure.changed }
            }
            let reconstruction = try reconstruction(for: row.decision, eventID: row.eventID, basis: row.basis, priorRows: resolutions[..<index])
            let after = try PantryCookResolution.result(row.decision, basis: row.basis, reconstruction: reconstruction)
            let writes = row.decision.action == .recount || (row.decision.action == .deduct && after?.quantity != nil)
            let expectedID = writes ? PantryCookResolution.identity("observation", draft: draft, eventID: row.eventID) : nil
            if let expectedID { priorByObservation[expectedID] = row }
            guard row.resultObservationID == expectedID, row.after == after else { throw PantryCookPort.Failure.changed }
        }
    }
}

extension PantryCookSession {
    func loadResolutions(shopID: UUID, mealID: UUID) async throws -> PantryCookResolution.Context {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).loadResolutions(shopID: shopID, mealID: mealID)
    }
    func reviewResolution(_ context: PantryCookResolution.Context, eventID: UUID,
                          decision: PantryCookResolution.Decision) async throws -> PantryCookResolution.Review {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).reviewResolution(context, eventID: eventID, decision: decision)
    }
    func applyResolution(_ review: PantryCookResolution.Review) async throws {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).applyResolution(review)
        if authorize() { await pickup.refreshPantryStock() }
    }
}

extension PantryCookPort {
    private typealias Resolution = PantryCookResolution

    private func resolutionContext(_ read: Read) throws -> PantryCookResolution.Context {
        guard let record = read.context.completedRecord, read.context.matches(record.draft) else { throw Failure.changed }
        return .init(record: record, lots: read.context.inventory.lots, reservations: read.context.inventory.reservations,
                     inventoryRevision: read.context.inventory.state.revision,
                     ledgerRevision: read.ledgerRevision, journeyRevision: read.journey.revision)
    }

    func loadResolutions(shopID: UUID, mealID: UUID) async throws -> PantryCookResolution.Context {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        return try await resolutionContext(read(shopID: shopID, mealID: mealID))
    }

    private func resolutionPlan(_ read: Read, eventID: UUID, decision: Resolution.Decision, at confirmedAt: Date) throws
        -> (review: Resolution.Review, writes: [InventoryWrite]) {
        let context = try resolutionContext(read)
        let draft = context.record.draft
        guard confirmedAt >= draft.cookedAt, confirmedAt <= read.context.asOf,
              context.actions(eventID: eventID, lotID: decision.lotID).contains(decision.action) else { throw Failure.changed }
        let inventory = read.context.inventory
        let lot = context.lots.first { $0.id == decision.lotID }
        let basis = lot.map { Resolution.Basis(revision: $0.revision, observationID: $0.observationID,
                                              confirmedAt: $0.confirmedAt, unit: $0.unit, count: $0.count) }
        let priorRows = context.record.resolutions ?? []
        let reconstruction = try context.record.reconstruction(for: decision, eventID: eventID, basis: basis, priorRows: priorRows[...])
        let after = try Resolution.result(decision, basis: basis, reconstruction: reconstruction)
        let operationID = Resolution.identity("operation", draft: draft, eventID: eventID)
        var observationID: UUID?
        var writes = [InventoryWrite]()
        var affected = [InventoryReservationCoverage]()
        if decision.action == .recount || (decision.action == .deduct && after?.quantity != nil) {
            guard let lot, let after else { throw Failure.changed }
            if decision.action == .deduct && reconstruction == nil {
                guard let free = inventory.availability.lots.first(where: { $0.id == lot.id })?.free,
                      let beforeAmount = lot.count.quantity?.amount, let afterAmount = after.quantity?.amount,
                      try beforeAmount.subtracting(afterAmount) <= free.amount else { throw InventoryError.invalid("cookUseExceedsAvailable") }
            }
            let id = Resolution.identity("observation", draft: draft, eventID: eventID)
            observationID = id
            let command = InventoryCommand(id: operationID, originID: draft.inventoryID, lotID: lot.id,
                eventID: Resolution.identity("stockEvent", draft: draft, eventID: eventID), expectedRevision: lot.revision,
                occurredAt: confirmedAt, change: .count(after, observationID: id))
            let change = try InventoryEngine.prepare(command, current: lot, at: read.context.asOf)
            writes = try PantryPersistenceCodec.writes(change)
            let projection = try InventoryProjection.build(originID: draft.inventoryID,
                lots: context.lots.map { $0.id == lot.id ? change.lot : $0 },
                reservations: inventory.reservations, at: read.context.asOf)
            let prior = Dictionary(uniqueKeysWithValues: inventory.availability.reservations.map { ($0.id, $0) })
            affected = projection.reservations.filter { prior[$0.id] != $0 }
        }
        let receipt = Resolution.Receipt(eventID: eventID, operationID: operationID, inventoryRevision: context.inventoryRevision,
            confirmedAt: confirmedAt, decision: decision, basis: basis, after: after, resultObservationID: observationID)
        let pending = Set(context.remainingEventIDs)
        let siblings = draft.parts.compactMap { part -> UUID? in
            guard part.id != eventID, pending.contains(part.id), case .lot(let lotID, _, nil) = part.use, lotID == decision.lotID else { return nil }
            return part.id
        }
        let review = Resolution.Review(cookID: draft.id, inventoryID: draft.inventoryID, ledgerID: draft.ledgerID,
            shopID: draft.shopID, mealID: draft.meal.id, journeyRevision: context.journeyRevision, ledgerRevision: context.ledgerRevision,
            receipt: receipt, affectedHolds: affected, otherUnresolvedEventsForLot: siblings, reconstruction: reconstruction)
        return (review, writes)
    }

    func reviewResolution(_ context: PantryCookResolution.Context, eventID: UUID,
                          decision: PantryCookResolution.Decision) async throws -> PantryCookResolution.Review {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        let draft = context.record.draft
        let read = try await read(shopID: draft.shopID, mealID: draft.meal.id)
        let current = try resolutionContext(read)
        guard current.record.draft.id == draft.id, current.inventoryRevision == context.inventoryRevision,
              current.ledgerRevision == context.ledgerRevision, current.journeyRevision == context.journeyRevision else { throw Failure.changed }
        return try resolutionPlan(read, eventID: eventID, decision: decision, at: read.context.asOf).review
    }

    func applyResolution(_ review: PantryCookResolution.Review) async throws {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        guard authorize(), review.inventoryID == store.workspaceID, review.ledgerID == ledger.workspaceID else { throw Failure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = Data("cook-resolution/v1/\(review.cookID)/\(review.mealID)/\(review.shopID)/\(review.ledgerID)/\(review.journeyRevision)/\(review.ledgerRevision)/".utf8)
        request.append(contentsOf: SHA256.hash(data: try encoder.encode(review.receipt)))
        let id = review.receipt.operationID
        if try await store.inventoryCommittedOperation(id: id, request: request) != nil {
            guard authorize() else { throw Failure.unavailable }
            return
        }
        let read = try await read(shopID: review.shopID, mealID: review.mealID)
        let plan = try resolutionPlan(read, eventID: review.eventID, decision: review.decision, at: review.receipt.confirmedAt)
        guard plan.review == review, let index = read.journey.cookedMeals?.firstIndex(where: { $0.draft.id == review.cookID && $0.isActive }),
              var records = read.journey.cookedMeals else { throw Failure.changed }
        records[index].resolutions = (records[index].resolutions ?? []) + [review.receipt]
        var next = read.journey
        next.cookedMeals = records
        try await persist(next, read: read, writes: plan.writes, request: request, operationID: id)
    }
}
