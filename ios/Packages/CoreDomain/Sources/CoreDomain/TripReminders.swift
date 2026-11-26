import Foundation

/// A physical departure reminder attached to this list row. A packed jug says
/// nothing about the water bought, an exchange or a refundable deposit.
public enum EmptyJugReminder: String, Codable, Sendable {
    case toPack, packed
}

extension ShoppingLedger {
    public var outstandingMainTripReason: ShoppingLine? {
        guard let id = mainTripReasonID,
              let line = lines.first(where: { $0.id == id }),
              !line.isChecked, !line.isTrashed, !line.isHandled,
              !isLeftForNextTrip(line) else { return nil }
        return line
    }

    public var departureReminderLines: [ShoppingLine] {
        lines.filter { $0.emptyJug != nil && !$0.isTrashed && !$0.isHandled }
    }
}
