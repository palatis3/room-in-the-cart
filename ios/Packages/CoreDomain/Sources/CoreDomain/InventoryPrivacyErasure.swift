import Foundation

/// Pure food semantics for an explicitly reviewed source graph. This does not
/// discover opaque app histories, erase SQL, or change other databases.
public enum InventoryPrivacyErasure {
  public struct Review: Equatable, Sendable {
    public let erasedLotIDs: Set<UUID>
    public let erasedReservationIDs: Set<UUID>
    public let redactedReservations: [InventoryReservation]
    public let remainingLots: [InventoryLot]
    public let remainingReservations: [InventoryReservation]
    public let projection: InventoryProjection
  }

  /// Removed promises must be explicitly selected. A surviving promise whose
  /// physical backing is erased becomes unresolved; it is never silently freed.
  /// A lost exact pin is cleared only because its physical identity is retired;
  /// persistence retains that UUID in a payload-free redaction marker.
  public static func review(
    originID: UUID, lots: [InventoryLot], reservations: [InventoryReservation],
    erasingLots: Set<UUID>, erasingReservations: Set<UUID>, at now: Date
  ) throws -> Review {
    _ = try InventoryProjection.build(
      originID: originID, lots: lots, reservations: reservations, at: now)
    guard erasingLots.isSubset(of: Set(lots.map(\.id))),
      erasingReservations.isSubset(of: Set(reservations.map(\.id)))
    else {
      throw InventoryError.invalid("erasureIdentity")
    }
    let foods = Set(lots.filter { erasingLots.contains($0.id) }.map(\.foodID))
    var redacted: [InventoryReservation] = []
    let retained = try reservations.filter { !erasingReservations.contains($0.id) }.map {
      claim -> InventoryReservation in
      let lostPin = claim.lotID.map { erasingLots.contains($0) } ?? false
      let uncertainBacking =
        claim.state != .released
        && (lostPin || (claim.lotID == nil && foods.contains(claim.foodID)))
      // Even a released reservation must drop a SQL pin to an erased lot.
      guard lostPin || uncertainBacking else { return claim }
      guard claim.revision < Int64.max else { throw InventoryError.capacity }
      let value = InventoryReservation(
        id: claim.id, originID: claim.originID, revision: claim.revision + 1,
        foodID: claim.foodID, lotID: lostPin ? nil : claim.lotID, name: claim.name,
        amount: uncertainBacking ? nil : claim.amount, priority: claim.priority,
        state: claim.state == .released ? .released : .unresolved)
      try value.validate()
      redacted.append(value)
      return value
    }
    let remaining = lots.filter { !erasingLots.contains($0.id) }
    return Review(
      erasedLotIDs: erasingLots, erasedReservationIDs: erasingReservations,
      redactedReservations: redacted.sorted { $0.id.uuidString < $1.id.uuidString },
      remainingLots: remaining,
      remainingReservations: retained,
      projection: try InventoryProjection.build(
        originID: originID, lots: remaining, reservations: retained, at: now))
  }
}
