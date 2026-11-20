import CoreDomain
import CryptoKit
import Foundation
import LocalStore

struct PantryCookUndoReceipt: Codable, Equatable {
    let id: UUID
    let confirmedAt: Date
    let observations: [UUID: UUID]
    var resolvedEventIDs: [UUID]? = nil
}

enum PantryCookUndoFailure: Error, Equatable {
    case independentPhysicalCount(lot: String?)
    case amendedInputChanged(lot: String?)
}

struct PantryCookUndoReview: Codable, Equatable {
    struct Input: Codable, Equatable {
        let lotID: UUID
        let name: String
        let count: InventoryCount
        var countWording: String? = nil
    }
    let id: UUID
    let cookID: UUID
    let inventoryID: UUID
    let inventoryRevision: Int64
    let ledgerID: UUID
    let shopID: UUID
    let mealID: UUID
    let journeyRevision: Int64
    let restoredInputs: [Input]
    let removedLeftovers: [String]
    struct Amendments: Codable, Equatable {
        let eventIDs: [UUID]
        let preservedCountNames: [String]
    }
    let restoredHoldCount: Int
    var releasedOutputHolds: [InventoryReservation]? = nil
    var amendments: Amendments? = nil
    var resolvedUseCount: Int { amendments?.eventIDs.count ?? 0 }
    var preservedCountNames: [String] { amendments?.preservedCountNames ?? [] }
    var restoredInputCount: Int { restoredInputs.count }
    var removedLeftoverCount: Int { removedLeftovers.count }
}

extension PantryCookSession {
    func reviewUndo(shopID: UUID, mealID: UUID) async throws -> PantryCookUndoReview {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).reviewUndo(shopID: shopID, mealID: mealID)
    }
    func applyUndo(_ review: PantryCookUndoReview) async throws {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).applyUndo(review)
        if authorize() { await pickup.refreshPantryStock() }
    }
}

extension PantryCookPort {
    private struct UndoPlan {
        let review: PantryCookUndoReview
        let index: Int
        let changes: [InventoryPreparedChange]
        let claims: [InventoryReservation]
    }

    func reviewUndo(shopID: UUID, mealID: UUID) async throws -> PantryCookUndoReview {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        return try await undoPlan(read(shopID: shopID, mealID: mealID), operationID: UUID()).review
    }

    private struct UndoInput {
        let restore: InventoryCount
        let originalObservationID: UUID
        var revision: Int64
        var observation: UUID
        var amended = false
    }

    /// Follow only this cook's stock changes. A physical recount is independent evidence;
    /// an intervening edit on a balance to restore is a descendant we cannot compensate.
    private func undoInputs(_ record: PantryCookRecord, lots: [UUID: InventoryLot]) throws
        -> (inputs: [UUID: UndoInput], amendments: PantryCookUndoReview.Amendments?) {
        var inputs = [UUID: UndoInput]()
        for prior in record.priorCounts {
            guard prior.revision > 0, prior.revision < Int64.max,
                  let observation = record.resultingObservations[prior.lotID] else { throw Failure.changed }
            inputs[prior.lotID] = UndoInput(restore: prior.count, originalObservationID: prior.observationID,
                                            revision: prior.revision + 1, observation: observation)
        }
        guard let resolutions = record.resolutions else { return (inputs, nil) }
        var preserved = Set<UUID>()
        for row in resolutions {
            guard let lotID = row.decision.lotID else { continue } // Outside-pantry evidence has no stock effect.
            let name = lots[lotID]?.name
            switch row.decision {
            case .outsidePantry: throw Failure.changed
            case .recount:
                throw PantryCookUndoFailure.independentPhysicalCount(lot: name)
            case .alreadyIncluded:
                // The current physical count on a previously untouched lot always wins.
                guard inputs[lotID] == nil else { throw PantryCookUndoFailure.independentPhysicalCount(lot: name) }
                preserved.insert(lotID)
            case .deduct:
                guard let basis = row.basis else { throw Failure.changed }
                var input = inputs[lotID] ?? UndoInput(restore: basis.count, originalObservationID: basis.observationID,
                                                       revision: basis.revision, observation: basis.observationID)
                guard input.revision == basis.revision, input.observation == basis.observationID,
                      !preserved.contains(lotID) else { throw PantryCookUndoFailure.amendedInputChanged(lot: name) }
                input.amended = true
                if let id = row.resultObservationID {
                    guard input.revision < Int64.max else { throw Failure.capacity }
                    input.revision += 1
                    input.observation = id
                }
                inputs[lotID] = input
            }
        }
        let names = try preserved.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            guard let name = lots[id]?.name else { throw Failure.changed }
            return name
        }
        return (inputs, .init(eventIDs: resolutions.map(\.eventID), preservedCountNames: names))
    }

    private func undoPlan(_ read: Read, operationID: UUID) async throws -> UndoPlan {
        let context = read.context
        let inventory = context.inventory
        guard let records = read.journey.cookedMeals, let index = records.firstIndex(where: {
            $0.isActive && $0.draft.meal.id == context.meal.id
        }) else { throw Failure.changed }
        let record = records[index]
        guard context.matches(record.draft) else { throw Failure.changed }
        let lots = Dictionary(uniqueKeysWithValues: inventory.lots.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: inventory.reservations.map { ($0.id, $0) })
        var changes: [InventoryPreparedChange] = []
        func change(_ lot: InventoryLot, _ edit: InventoryChange) throws -> InventoryPreparedChange {
            let command = InventoryCommand(id: operationID, originID: inventory.state.workspaceID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: context.asOf, change: edit)
            return try InventoryEngine.prepare(command, current: lot, at: context.asOf)
        }
        let lineage = try undoInputs(record, lots: lots)
        var restoredInputs: [PantryCookUndoReview.Input] = []
        for id in lineage.inputs.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let input = lineage.inputs[id] else { throw Failure.changed }
            guard let lot = lots[id], lot.revision == input.revision, lot.observationID == input.observation else {
                if input.amended { throw PantryCookUndoFailure.amendedInputChanged(lot: lots[id]?.name) }
                throw Failure.changed
            }
            var wording: String?
            if input.restore == .someLeft {
                // Existing cook receipts already point to the immutable pre-cook reading.
                guard let stored = try await store.inventoryRecord(.init(.observation, input.originalObservationID)),
                      authorize() else { throw Failure.unavailable }
                let original = try PantryPersistenceCodec.observation(stored)
                guard original.lotID == id, original.count == input.restore else { throw Failure.changed }
                wording = original.countWording
            }
            let restore: InventoryChange
            if let wording {
                let reading = InventoryCountRevision(count: input.restore, observationID: UUID(), observedAt: context.asOf, countWording: wording)
                restore = .revise(.init(observation: reading))
            } else {
                restore = .count(input.restore, observationID: UUID())
            }
            changes.append(try change(lot, restore))
            restoredInputs.append(.init(lotID: id, name: lot.name, count: input.restore, countWording: wording))
        }
        let outputs = Set(record.draft.leftovers.map(\.id))
        let outputFoods = Set(record.draft.leftovers.map(\.foodID))
        // Reconstruct exactly what this cook created, including revision one and the original date.
        // Even moving the dinner back to that date is an independently recorded change.
        let originalHolds = try record.draft.leftovers.flatMap { try record.draft.outputReservations(for: $0) }
        let ownIDs = Set(originalHolds.map(\.id))
        let currentCoverage = Dictionary(uniqueKeysWithValues: inventory.availability.reservations.map { ($0.id, $0) })
        let released = try originalHolds.map { original -> InventoryReservation in
            guard claims[original.id] == original, let coverage = currentCoverage[original.id], let amount = original.amount,
                  !coverage.unresolved, coverage.shortfall?.amount == .zero, coverage.backed?.amount == amount.amount
            else { throw Failure.changed }
            return .init(id: original.id, originID: original.originID, revision: original.revision + 1,
                foodID: original.foodID, lotID: original.lotID, name: original.name, amount: amount, priority: original.priority,
                state: .released, personal: original.personal, cookedDinner: original.cookedDinner)
        }
        let allocatedOutputs = inventory.availability.allocations.contains { outputs.contains($0.lotID) && !ownIDs.contains($0.needID) }
        let outputClaims = inventory.reservations.contains { claim in
            guard claim.state != .released, !ownIDs.contains(claim.id) else { return false }
            if let lotID = claim.lotID { return outputs.contains(lotID) }
            guard outputFoods.contains(claim.foodID), let coverage = currentCoverage[claim.id] else { return false }
            return coverage.unresolved || (coverage.shortfall?.amount ?? .zero) > .zero
        }
        guard !allocatedOutputs, !outputClaims else { throw Failure.changed }
        let removedLeftovers = try record.draft.leftovers.map { output -> String in
            guard let lot = lots[output.id], lot.revision == 1, lot.observationID == record.resultingObservations[output.id],
                  lot.foodID == output.foodID,
                  lot.count.quantity?.amount == output.portions else { throw Failure.changed }
            changes.append(try change(lot, .usedUp(observationID: UUID())))
            return lot.name
        }
        let restoredClaims = try record.priorClaims.map { prior -> InventoryReservation in
            guard let current = claims[prior.id], current.revision - 1 == prior.revision,
                  current.revision < Int64.max else { throw Failure.changed }
            return .init(id: prior.id, originID: prior.originID, revision: current.revision + 1,
                foodID: prior.foodID, lotID: prior.lotID, name: prior.name, amount: prior.amount,
                priority: prior.priority, state: prior.state, personal: prior.personal)
        }
        let updatedClaims = restoredClaims + released
        let touched = Set(changes.map(\.lot.id)), owned = Set(updatedClaims.map(\.id))
        let after = try InventoryProjection.build(originID: inventory.state.workspaceID,
            lots: inventory.lots.filter { !touched.contains($0.id) } + changes.map(\.lot),
            reservations: inventory.reservations.filter { !owned.contains($0.id) } + updatedClaims, at: context.asOf)
        let coverage = Dictionary(uniqueKeysWithValues: after.reservations.map { ($0.id, $0) })
        for before in inventory.availability.reservations where !owned.contains(before.id) {
            guard let updated = coverage[before.id],
                  Set(updated.issues).isSubset(of: before.issues),
                  (updated.backed?.amount ?? .zero) >= (before.backed?.amount ?? .zero) else { throw Failure.changed }
        }
        let review = PantryCookUndoReview(id: operationID, cookID: record.draft.id,
            inventoryID: inventory.state.workspaceID, inventoryRevision: inventory.state.revision, ledgerID: context.ledgerID,
            shopID: context.shop.id, mealID: context.meal.id, journeyRevision: read.journey.revision,
            restoredInputs: restoredInputs, removedLeftovers: removedLeftovers, restoredHoldCount: restoredClaims.count,
            releasedOutputHolds: originalHolds.isEmpty ? nil : originalHolds, amendments: lineage.amendments)
        return .init(review: review, index: index, changes: changes, claims: updatedClaims)
    }

    func applyUndo(_ review: PantryCookUndoReview) async throws {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        guard authorize(), review.inventoryID == store.workspaceID, review.ledgerID == ledger.workspaceID else { throw Failure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = Data("cook-undo/v1/".utf8)
        request.append(contentsOf: SHA256.hash(data: try encoder.encode(review)))
        if try await store.inventoryCommittedOperation(id: review.id, request: request) != nil {
            guard authorize() else { throw Failure.unavailable }
            return
        }
        let read = try await read(shopID: review.shopID, mealID: review.mealID)
        let plan = try await undoPlan(read, operationID: review.id)
        guard plan.review == review else { throw Failure.changed }
        var next = read.journey
        next.cookedMeals?[plan.index].undo = .init(id: review.id, confirmedAt: read.context.asOf,
            observations: Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.lot.id, $0.lot.observationID) }),
            resolvedEventIDs: review.amendments?.eventIDs)
        var writes = try plan.changes.flatMap(PantryPersistenceCodec.writes)
        writes += try plan.claims.map { try PantryPersistenceCodec.write($0, expectedRevision: $0.revision - 1) }
        try await persist(next, read: read, writes: writes, request: request, operationID: review.id)
    }
}
