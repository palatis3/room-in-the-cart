import CoreDomain
import CryptoKit
import Foundation
import LocalStore

struct PantryCookUndoReceipt: Codable, Equatable {
    let id: UUID
    let confirmedAt: Date
    let observations: [UUID: UUID]
}

struct PantryCookUndoReview: Codable, Equatable {
    struct Input: Codable, Equatable {
        let lotID: UUID
        let name: String
        let count: InventoryCount
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
    let restoredHoldCount: Int
    var restoredInputCount: Int { restoredInputs.count }
    var removedLeftoverCount: Int { removedLeftovers.count }
}

extension PantryCookSession {
    func reviewUndo(shopID: UUID, mealID: UUID) async throws -> PantryCookUndoReview {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).reviewUndo(shopID: shopID, mealID: mealID)
    }
    func applyUndo(_ review: PantryCookUndoReview) async throws {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).applyUndo(review)
        if authorize() { await pickup.load() }
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

    private func undoPlan(_ read: Read, operationID: UUID) throws -> UndoPlan {
        let context = read.context
        let inventory = context.inventory
        guard let records = read.journey.cookedMeals, let index = records.firstIndex(where: {
            $0.isActive && $0.draft.meal.id == context.meal.id
        }) else { throw Failure.changed }
        let record = records[index]
        guard !record.hasResolvedUses, context.matches(record.draft) else { throw Failure.changed }
        let lots = Dictionary(uniqueKeysWithValues: inventory.lots.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: inventory.reservations.map { ($0.id, $0) })
        var changes: [InventoryPreparedChange] = []
        func change(_ lot: InventoryLot, _ edit: InventoryChange) throws -> InventoryPreparedChange {
            guard lot.observationID == record.resultingObservations[lot.id] else { throw Failure.changed }
            let command = InventoryCommand(id: operationID, originID: inventory.state.workspaceID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: context.asOf, change: edit)
            return try InventoryEngine.prepare(command, current: lot, at: context.asOf)
        }
        let restoredInputs = try record.priorCounts.map { prior -> PantryCookUndoReview.Input in
            guard let lot = lots[prior.lotID], prior.revision > 0, lot.revision - 1 == prior.revision else { throw Failure.changed }
            changes.append(try change(lot, .count(prior.count, observationID: UUID())))
            return .init(lotID: lot.id, name: lot.name, count: prior.count)
        }
        let outputs = Set(record.draft.leftovers.map(\.id))
        let outputFoods = Set(record.draft.leftovers.map(\.foodID))
        let allocatedOutputs = inventory.availability.allocations.contains { outputs.contains($0.lotID) }
        let outputClaims = inventory.reservations.contains { claim in
            guard claim.state != .released else { return false }
            if let lotID = claim.lotID { return outputs.contains(lotID) }
            return claim.state == .unresolved && outputFoods.contains(claim.foodID)
        }
        guard !allocatedOutputs, !outputClaims else { throw Failure.changed }
        let removedLeftovers = try record.draft.leftovers.map { output -> String in
            guard let lot = lots[output.id], lot.revision == 1, lot.foodID == output.foodID,
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
        let touched = Set(changes.map(\.lot.id)), owned = Set(restoredClaims.map(\.id))
        let after = try InventoryProjection.build(originID: inventory.state.workspaceID,
            lots: inventory.lots.filter { !touched.contains($0.id) } + changes.map(\.lot),
            reservations: inventory.reservations.filter { !owned.contains($0.id) } + restoredClaims, at: context.asOf)
        let coverage = Dictionary(uniqueKeysWithValues: after.reservations.map { ($0.id, $0) })
        for before in inventory.availability.reservations where !owned.contains(before.id) {
            guard let updated = coverage[before.id],
                  Set(updated.issues).isSubset(of: before.issues),
                  (updated.backed?.amount ?? .zero) >= (before.backed?.amount ?? .zero) else { throw Failure.changed }
        }
        let review = PantryCookUndoReview(id: operationID, cookID: record.draft.id,
            inventoryID: inventory.state.workspaceID, inventoryRevision: inventory.state.revision, ledgerID: context.ledgerID,
            shopID: context.shop.id, mealID: context.meal.id, journeyRevision: read.journey.revision,
            restoredInputs: restoredInputs, removedLeftovers: removedLeftovers, restoredHoldCount: restoredClaims.count)
        return .init(review: review, index: index, changes: changes, claims: restoredClaims)
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
        let plan = try undoPlan(read, operationID: review.id)
        guard plan.review == review else { throw Failure.changed }
        var next = read.journey
        next.cookedMeals?[plan.index].undo = .init(id: review.id, confirmedAt: read.context.asOf,
            observations: Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.lot.id, $0.lot.observationID) }))
        var writes = try plan.changes.flatMap(PantryPersistenceCodec.writes)
        writes += try plan.claims.map { try PantryPersistenceCodec.write($0, expectedRevision: $0.revision - 1) }
        try await persist(next, read: read, writes: writes, request: request, operationID: review.id)
    }
}
