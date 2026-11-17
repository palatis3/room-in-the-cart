import Foundation
import CryptoKit
import CoreDomain

/// Produces a separate physical baseline, not executable old commands or ledger authority.
/// The Records owner stages this state only after all package chunks validate, and retains
/// large historical evidence in its protected archive storage rather than a 64 KiB intent row.
@MainActor enum PantryArchiveRestore {
    static func prepare(_ source: PantryArchiveCodec.Snapshot, newOriginID: UUID,
                        restorationID: UUID, at date: Date) throws -> PantryArchiveCodec.Snapshot {
        try PantryArchiveCodec.validate(source)
        guard !historicalOrigins(source).contains(newOriginID), date.timeIntervalSinceReferenceDate.isFinite,
              date >= source.descriptor.capturedAt else { throw PantryArchiveCodec.Failure.wrongOrigin }
        var lots: [InventoryLot] = [], observations: [InventoryObservation] = []
        var links: [PantryPersistenceCodec.SourceLink] = []
        var history = source.history + [.restoredFrom(source.descriptor)]
        history += source.lots.map(PantryArchiveCodec.History.originalLot)
        history += source.observations.map { .originalObservation(originID: source.descriptor.originID, $0) }
        history += source.events.map(PantryArchiveCodec.History.originalEvent)
        history += source.reservations.map(PantryArchiveCodec.History.originalReservation)
        history += source.sourceLinks.map(PantryArchiveCodec.History.originalSourceLink)
        for original in source.lots {
            let sourceKey: InventorySource
            switch original.source {
            case .manual(_, let id): sourceKey = .manual(originID: newOriginID, sourceID: id)
            case .receipt(_, let key): sourceKey = .receipt(originID: newOriginID, key: key)
            }
            let observationID = identity(restorationID: restorationID, originID: newOriginID, lotID: original.id)
            let lot = InventoryLot(id: original.id, foodID: original.foodID, name: original.name, source: sourceKey,
                revision: 1, location: original.location, openedAt: original.openedAt, unit: original.unit,
                count: original.count, observationID: observationID, confirmedAt: original.confirmedAt,
                updatedAt: original.updatedAt, useFirst: original.useFirst)
            lots.append(lot)
            observations.append(.init(id: observationID, lotID: lot.id, operationID: restorationID, revision: 1,
                supersedesID: nil, observedAt: original.confirmedAt, count: original.count))
            links.append(.init(lotID: lot.id, source: sourceKey))
            // This immutable local baseline lets later events be checked without inventing prior SQL revisions.
            history.append(.originalLot(lot))
        }
        let reservations = source.reservations.map { claim in
            InventoryReservation(id: claim.id, originID: newOriginID, revision: 1,
                foodID: claim.foodID, lotID: claim.lotID, name: claim.name, amount: claim.amount,
                priority: claim.priority, state: claim.state == .released ? .released : .unresolved)
        }
        var seen: Set<Data> = []
        history = try history.filter { seen.insert(try canonical($0)).inserted }
        let result = PantryArchiveCodec.Snapshot(descriptor: .init(originID: newOriginID, inventoryRevision: 1, capturedAt: date),
            lots: lots, observations: observations, events: [], reservations: reservations, sourceLinks: links, history: history)
        try PantryArchiveCodec.validate(result)
        return result
    }
    private static func historicalOrigins(_ source: PantryArchiveCodec.Snapshot) -> Set<UUID> {
        var result: Set<UUID> = [source.descriptor.originID]
        for evidence in source.history {
            switch evidence {
            case .migration(let value): result.insert(value.originID)
            case .sourceHead(let id, _), .originalObservation(let id, _): result.insert(id)
            case .pickupPending(let value):
                result.insert(value.submission.request.originID)
                if let ledger = value.submission.request.ledgerOriginID { result.insert(ledger) }
            case .foodPending(let value): result.insert(value.command.originID)
            case .projection(let value):
                result.insert(value.binding.binding.inventoryWorkspaceID); result.insert(value.binding.binding.ledgerWorkspaceID)
            case .originalLot(let value): result.insert(value.source.originID)
            case .originalEvent(let value): result.insert(value.originID)
            case .originalReservation(let value): result.insert(value.originID)
            case .originalSourceLink(let value): result.insert(value.source.originID)
            case .restoredFrom(let value): result.insert(value.originID)
            }
        }
        return result
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func identity(restorationID: UUID, originID: UUID, lotID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("pantry-independent-baseline/v1/\(restorationID)/\(originID)/\(lotID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
