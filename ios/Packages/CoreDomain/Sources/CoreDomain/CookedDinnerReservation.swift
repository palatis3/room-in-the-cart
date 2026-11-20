import Foundation

/// The calendar entry and the physical batch hold share one reservation head.
public struct CookedDinnerReservation: Codable, Equatable, Sendable {
    public let ledgerID: UUID
    public let shopID: UUID
    public let cookID: UUID
    public var day: MealDay
    public var servedAt: Date?

    public init(ledgerID: UUID, shopID: UUID, cookID: UUID, day: MealDay) {
        self.ledgerID = ledgerID
        self.shopID = shopID
        self.cookID = cookID
        self.day = day
    }

    public enum Action: Codable, Equatable, Sendable {
        case move(MealDay), cancel, serve
    }

    /// The store commits the updated hold and any measured use against the same inventory revision.
    public static func update(_ reservation: InventoryReservation, action: Action, operationID: UUID,
                              lots: [InventoryLot], reservations: [InventoryReservation], at now: Date) throws
        -> (reservation: InventoryReservation, consumption: InventoryPreparedChange?) {
        guard var dinner = reservation.cookedDinner, reservation.state == .active, dinner.servedAt == nil,
              reservations.contains(reservation), reservation.revision < Int64.max,
              let amount = reservation.amount, let lot = lots.first(where: { $0.id == reservation.lotID }),
              lot.foodID == reservation.foodID, lot.unit == .count, lot.updatedAt <= now,
              lot.source == .manual(originID: reservation.originID, sourceID: lot.id)
        else { throw InventoryError.stale }
        try reservation.validate()
        let state: InventoryReservationState
        var consumption: InventoryPreparedChange?
        switch action {
        case .move(let day):
            try day.validate()
            guard day != dinner.day else { throw InventoryError.invalid("sameDinnerDay") }
            dinner.day = day
            state = .active
        case .cancel:
            state = .released
        case .serve:
            let before = try InventoryProjection.build(originID: reservation.originID, lots: lots, reservations: reservations, at: now)
            let holds = before.reservations(for: lot, among: reservations)
            guard let total = lot.count.quantity, total.amount >= amount.amount,
                  holds.contains(where: { $0.id == reservation.id && $0.allocation?.amount == amount.amount }),
                  holds.allSatisfy({ !$0.coverage.unresolved && $0.coverage.shortfall?.amount == .zero })
            else { throw InventoryError.invalid("cookedPortionHolds") }
            let balance = try total.amount.subtracting(amount.amount)
            let reading = InventoryCountRevision(count: .exact(Quantity(amount: balance, unit: .count, originalLiteral: balance.description)),
                                                 observationID: UUID(), observedAt: now)
            let command = InventoryCommand(id: operationID, originID: reservation.originID, lotID: lot.id,
                eventID: UUID(), expectedRevision: lot.revision, occurredAt: now,
                change: .revise(.init(observation: reading, usage: [.init(id: operationID, kind: .measured(amount))])))
            consumption = try InventoryEngine.prepare(command, current: lot, at: now)
            dinner.servedAt = now
            state = .released
        }
        let updated = InventoryReservation(id: reservation.id, originID: reservation.originID, revision: reservation.revision + 1,
            foodID: lot.foodID, lotID: lot.id, name: reservation.name, amount: amount, priority: .protected,
            state: state, cookedDinner: dinner)
        try updated.validate()
        return (updated, consumption)
    }
}
