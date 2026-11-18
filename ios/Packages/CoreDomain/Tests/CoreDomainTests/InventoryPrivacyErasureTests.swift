import XCTest

@testable import CoreDomain

final class InventoryPrivacyErasureTests: XCTestCase {
  private let origin = UUID(), food = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
  private func lot(_ food: UUID, id: UUID = UUID()) throws -> InventoryLot {
    let seed = InventoryLotSeed(
      foodID: food, name: "Food", source: .manual(originID: origin, sourceID: id),
      location: .cupboard, unit: .count,
      count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8")))
    return try InventoryEngine.prepare(
      .init(
        id: UUID(), originID: origin, lotID: id, eventID: UUID(), expectedRevision: nil,
        occurredAt: now, change: .create(seed, observationID: UUID())), current: nil, at: now
    ).lot
  }
  private func claim(food: UUID, lot: UUID? = nil, state: InventoryReservationState = .active)
    throws -> InventoryReservation
  {
    .init(
      id: UUID(), originID: origin, revision: 1, foodID: food, lotID: lot,
      name: "Other shop promise",
      amount: .init(amount: try Rational(2), unit: .count, originalLiteral: "2"),
      priority: .protected, state: state)
  }
  func testLostPinAndUnpinnedBackingStayUnknownWhileOtherExactPinsRemain() throws {
    let erased = try lot(food)
    let same = try lot(food)
    let other = try lot(UUID())
    let lost = try claim(food: food, lot: erased.id)
    let unscoped = try claim(food: food)
    let exact = try claim(food: food, lot: same.id)
    let unrelated = try claim(food: other.foodID, lot: other.id)
    let review = try InventoryPrivacyErasure.review(
      originID: origin, lots: [erased, same, other],
      reservations: [lost, unscoped, exact, unrelated], erasingLots: [erased.id],
      erasingReservations: [], at: now)
    XCTAssertEqual(Set(review.redactedReservations.map(\.id)), [lost.id, unscoped.id])
    for claim in review.redactedReservations {
      XCTAssertEqual(claim.state, .unresolved)
      XCTAssertNil(claim.amount)
      XCTAssertNil(claim.lotID)
      XCTAssertEqual(claim.revision, 2)
    }
    XCTAssertEqual(review.remainingReservations.first { $0.id == exact.id }, exact)
    XCTAssertEqual(review.remainingReservations.first { $0.id == unrelated.id }, unrelated)
    XCTAssertNil(review.projection.lots.first { $0.id == same.id }?.free)
    XCTAssertEqual(
      review.projection.lots.first { $0.id == other.id }?.free?.amount, try Rational(6))
  }
  func testOnlyExplicitSelectedClaimsDisappearAndReleasedPinDoesNotBecomeHeld() throws {
    let erased = try lot(food)
    let retained = try lot(food)
    let selected = try claim(food: food, lot: erased.id)
    let released = try claim(food: food, lot: erased.id, state: .released)
    let review = try InventoryPrivacyErasure.review(
      originID: origin, lots: [erased, retained], reservations: [selected, released],
      erasingLots: [erased.id], erasingReservations: [selected.id], at: now)
    XCTAssertEqual(review.remainingReservations.count, 1)
    XCTAssertEqual(review.remainingReservations[0].id, released.id)
    XCTAssertEqual(review.remainingReservations[0].state, .released)
    XCTAssertNil(review.remainingReservations[0].lotID)
    XCTAssertEqual(review.projection.lots[0].free?.amount, try Rational(8))
  }
  func testUnknownSelectionAndWrongOriginFailBeforeProducingGraph() throws {
    let value = try lot(food)
    XCTAssertThrowsError(
      try InventoryPrivacyErasure.review(
        originID: origin, lots: [value], reservations: [], erasingLots: [UUID()],
        erasingReservations: [], at: now))
    XCTAssertThrowsError(
      try InventoryPrivacyErasure.review(
        originID: UUID(), lots: [value], reservations: [], erasingLots: [value.id],
        erasingReservations: [], at: now))
  }
}
