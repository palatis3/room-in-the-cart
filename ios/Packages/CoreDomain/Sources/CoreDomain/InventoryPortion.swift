import Foundation

/// A physical transfer or discard is separate from consumption and paid acquisition.
public enum InventoryPortionAction: Codable, Equatable, Sendable {
    case split(amount: Quantity, destination: InventoryLocation, lotID: UUID, eventID: UUID, observationID: UUID)
    case discard(amount: Quantity?, reason: String?)
    case undoDiscard(eventID: UUID)

    public func remainder(of lot: InventoryLot) throws -> InventoryCount {
        switch self {
        case let .split(amount, destination, child, _, _):
            guard child != lot.id, destination != lot.location else { throw InventoryError.invalid("split") }
            let remaining = try subtract(amount, from: lot)
            guard remaining.quantity?.amount != .zero else { throw InventoryError.invalid("wholeBatch") }
            return remaining
        case let .discard(amount, reason):
            guard reason.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                  lot.count.quantity?.amount != .zero else { throw InventoryError.invalid("discard") }
            if let amount { return try subtract(amount, from: lot) }
            return .unknown
        case let .undoDiscard(eventID):
            guard let prior = lot.discardUndo, prior.eventID == eventID else { throw InventoryError.stale }
            return prior.previousCount
        }
    }

    private func subtract(_ amount: Quantity, from lot: InventoryLot) throws -> InventoryCount {
        try amount.validate()
        guard let physical = lot.count.quantity, physical.unit.dimension == amount.unit.dimension,
              amount.amount > .zero, let used = try amount.converted(to: physical.unit), used <= physical.amount else { throw InventoryError.invalid("portion") }
        let balance = try physical.amount.subtracting(used)
        return .exact(Quantity(amount: balance, unit: physical.unit, originalLiteral: balance.description,
                               confirmedConversion: physical.confirmedConversion))
    }
}

public struct InventoryDiscardUndo: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let previousCount: InventoryCount
    public let previousWording: String?
    public let previousConfirmedAt: Date
}

extension InventoryLot {
    /// Resolve split provenance once for every lot, including splits of a split.
    /// A missing or cyclic transfer chain cannot qualify a portion as independent stock.
    public static func splitRoots(in lots: [InventoryLot]) throws -> [UUID: UUID] {
        var byID: [UUID: InventoryLot] = [:], roots: [UUID: UUID] = [:]
        for lot in lots {
            guard byID.updateValue(lot, forKey: lot.id) == nil else { throw InventoryError.duplicateIdentity }
        }
        for lot in lots where roots[lot.id] == nil {
            var current = lot
            var visited = Set<UUID>()
            while let parentID = current.splitFromLotID, roots[current.id] == nil {
                guard visited.insert(current.id).inserted, let parent = byID[parentID],
                      parent.source.originID == lot.source.originID else { throw InventoryError.invalid("splitProvenance") }
                current = parent
            }
            let root = roots[current.id] ?? current.id
            roots[current.id] = root
            for id in visited { roots[id] = root }
        }
        return roots
    }
}
