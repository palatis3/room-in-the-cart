import Foundation

/// Only an explicitly created private hold can be released from a pantry lot.
public struct InventoryPersonalReservation: Codable, Equatable, Sendable {
    public let day: MealDay?
    public init(day: MealDay?) { self.day = day }
}

public enum InventoryReservationEdit: Codable, Equatable, Sendable {
    case reserve(id: UUID, purpose: String, amount: Quantity, day: MealDay?)
    /// A nil amount releases the whole selected promise, including its unbacked part.
    case release(id: UUID, expectedRevision: Int64, amount: Quantity?)

    public var id: UUID {
        switch self {
        case .reserve(let id, _, _, _), .release(let id, _, _): return id
        }
    }

    public var previousRevision: Int64 {
        switch self {
        case .reserve: return 0
        case .release(_, let revision, _): return revision
        }
    }

    public func validate() throws {
        switch self {
        case let .reserve(_, purpose, amount, day):
            guard !purpose.isEmpty, purpose == purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                  purpose.utf8.count <= 512, amount.amount > .zero else { throw InventoryError.invalid("reservationPurposeOrAmount") }
            try amount.validate()
            try day?.validate()
        case let .release(_, revision, amount):
            guard revision > 0, revision < Int64.max, amount.map({ $0.amount > .zero }) != false else {
                throw InventoryError.invalid("reservationRelease")
            }
            try amount?.validate()
        }
    }

    public func prepare(command: InventoryCommand, lots: [InventoryLot], reservations: [InventoryReservation],
                        before: InventoryProjection, at now: Date) throws -> (InventoryReservation, InventoryProjection) {
        try validate()
        guard command.change == .reservation(self), let lot = lots.first(where: { $0.id == command.lotID }),
              lot.source.originID == command.originID, lot.revision == command.expectedRevision else { throw InventoryError.stale }
        guard command.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              command.occurredAt >= lot.updatedAt, command.occurredAt <= now else { throw InventoryError.invalid("reservationTime") }
        let current = reservations.first { $0.id == id }
        let updated: InventoryReservation
        switch self {
        case let .reserve(_, purpose, amount, day):
            guard current == nil else { throw InventoryError.stale }
            guard let free = before.lots.first(where: { $0.id == lot.id })?.free,
                  amount.unit == lot.unit, free.unit == amount.unit, amount.amount <= free.amount else {
                throw InventoryError.invalid("reservationExceedsFree")
            }
            updated = InventoryReservation(id: id, originID: command.originID, revision: 1, foodID: lot.foodID, lotID: lot.id,
                name: purpose, amount: amount, priority: .protected, personal: .init(day: day))
        case let .release(_, revision, amount):
            guard let current, current.personal != nil, current.originID == command.originID, current.lotID == lot.id,
                  current.foodID == lot.foodID, current.state == .active, current.revision == revision,
                  let held = current.amount else { throw InventoryError.stale }
            let remaining: Quantity?
            if let amount {
                guard amount.unit == held.unit, amount.amount < held.amount else { throw InventoryError.invalid("partialRelease") }
                let value = try held.amount.subtracting(amount.amount)
                remaining = Quantity(amount: value, unit: held.unit, originalLiteral: value.description,
                                     confirmedConversion: held.confirmedConversion)
            } else { remaining = nil }
            updated = InventoryReservation(id: id, originID: current.originID, revision: revision + 1, foodID: current.foodID,
                lotID: lot.id, name: current.name, amount: remaining ?? held, priority: current.priority,
                state: remaining == nil ? .released : .active, personal: current.personal)
        }
        let after = try InventoryProjection.build(originID: command.originID, lots: lots,
            reservations: reservations.filter { $0.id != id } + [updated], at: now)
        if case .reserve = self {
            guard let amount = updated.amount, let coverage = after.reservations.first(where: { $0.id == id }),
                  !coverage.unresolved, coverage.shortfall?.amount == .zero, coverage.backed?.amount == amount.amount,
                  after.allocations.filter({ $0.needID == id }).allSatisfy({ $0.lotID == lot.id }),
                  after.allocations.filter({ $0.needID != id }) == before.allocations else {
                throw InventoryError.invalid("reservationWouldMoveOtherFood")
            }
        }
        return (updated, after)
    }
}
