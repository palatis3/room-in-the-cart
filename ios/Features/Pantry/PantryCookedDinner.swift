import Foundation
import CryptoKit
import CoreDomain
import LocalStore

struct CookedDinnerChange: Codable, Equatable {
    let id: UUID
    let inventoryID: UUID
    let ledgerID: UUID
    let shopID: UUID
    let reservationID: UUID
    let revision: Int64
    let action: CookedDinnerReservation.Action

    init?(_ claim: InventoryReservation, action: CookedDinnerReservation.Action) {
        guard let dinner = claim.cookedDinner, claim.state == .active else { return nil }
        id = UUID()
        inventoryID = claim.originID
        ledgerID = dinner.ledgerID
        shopID = dinner.shopID
        reservationID = claim.id
        revision = claim.revision
        self.action = action
    }
}

extension PantryCookPort {
    func changeDinner(_ change: CookedDinnerChange) async throws {
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }
        guard authorize(), change.inventoryID == store.workspaceID, change.ledgerID == ledger.workspaceID,
              let ledgerHead = try await ledger.load(), authorize(),
              try LedgerModel.validatePayload(ledgerHead.payload).selectedShopID == change.shopID
        else { throw Failure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = Data("cooked-dinner/v1/".utf8)
        request.append(contentsOf: SHA256.hash(data: try encoder.encode(change)))
        if try await store.inventoryCommittedOperation(id: change.id, request: request) != nil {
            guard authorize() else { throw Failure.unavailable }
            return
        }
        let repository = PantryRepository(store: store, authorize: authorize)
        let now = clock()
        let snapshot = try await repository.load(at: now)
        guard let claim = snapshot.reservations.first(where: { $0.id == change.reservationID }),
              claim.revision == change.revision, let dinner = claim.cookedDinner, dinner.ledgerID == change.ledgerID,
              dinner.shopID == change.shopID, let saved = try await store.load(id: change.shopID), authorize()
        else { throw Failure.changed }
        let journey = try JSONDecoder().decode(PickupJourney.self, from: saved.payload)
        try PickupModel.validate(journey)
        guard journey.id == change.shopID, let cook = journey.cookedMeals?.first(where: { $0.isActive && $0.draft.id == dinner.cookID }),
              cook.draft.ledgerID == change.ledgerID, cook.draft.inventoryID == change.inventoryID,
              let output = cook.draft.leftovers.first(where: { $0.id == claim.lotID && $0.foodID == claim.foodID }),
              try cook.draft.outputReservations(for: output).contains(where: { $0.id == claim.id && $0.amount == claim.amount })
        else { throw Failure.changed }
        let update = try CookedDinnerReservation.update(claim, action: change.action, operationID: change.id,
            lots: snapshot.lots, reservations: snapshot.reservations, at: now)
        var writes = try update.consumption.map(PantryPersistenceCodec.writes) ?? []
        writes.append(try PantryPersistenceCodec.write(update.reservation, expectedRevision: claim.revision))
        try repository.validateCapacity(of: writes, replacing: snapshot)
        guard try await ledger.load()?.revision == ledgerHead.revision, authorize() else { throw Failure.changed }
        _ = try await store.commitInventory(.init(workspaceID: change.inventoryID, operationID: change.id,
            expectedRevision: snapshot.state.revision, request: request, writes: writes), at: now)
        guard authorize() else { throw Failure.unavailable }
    }
}
