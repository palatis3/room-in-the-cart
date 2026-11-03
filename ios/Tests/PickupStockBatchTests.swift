import XCTest
import CoreDomain
@testable import RoomInTheCart

final class PickupStockBatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func quantity(_ n: Int64) -> Quantity {
        Quantity(amount: try! Rational(n), unit: .count, originalLiteral: String(n))
    }

    @MainActor func testReviewedCorrectionReallocatesOnceAndCarriesOnlyFreshlyCountedFood() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = UUID(), lunch = UUID(), batch = UUID()
        let dinner = UrgentMealNeed(id: food, food: "Wraps", meal: "Dinner", required: quantity(4),
                                    available: quantity(0), due: nil, confirmedAt: now)
        let started = await model.addUrgent(dinner)
        XCTAssertTrue(started)
        let shop = try XCTUnwrap(model.journey?.id)
        let addedLunch = await model.change { value in
            value.stockNeeds.append(StockNeed(id: lunch, foodID: food, name: "Lunch", amount: quantity(2), priority: .protected))
        }
        XCTAssertTrue(addedLunch)
        func lot(_ n: Int64, _ date: Date) -> ConfirmedStockLot {
            ConfirmedStockLot(id: batch, foodID: food, name: "Freezer wraps", usable: quantity(n),
                              confirmedAt: date, source: .freezer, useFirst: true)
        }
        let five = lot(5, now.addingTimeInterval(-86400)), three = lot(3, now)
        let saved = await model.saveStockLot(five, in: shop)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.stockAllocation?.demands.first { $0.id == lunch }?.allocated, try Rational(2))
        XCTAssertEqual(model.stockAllocation?.demands.first { $0.id == food }?.shortfall, try Rational(1))
        let invalidDate = await model.saveStockLot(lot(8, now.addingTimeInterval(86400)), in: shop, replacing: five)
        XCTAssertFalse(invalidDate)
        let corrected = await model.saveStockLot(three, in: shop, replacing: five)
        XCTAssertTrue(corrected)
        let revision = model.journey?.revision
        let retry = await model.saveStockLot(three, in: shop, replacing: five)
        let stale = await model.saveStockLot(lot(4, now), in: shop, replacing: five)
        XCTAssertTrue(retry); XCTAssertFalse(stale)
        XCTAssertEqual(model.journey?.revision, revision)
        XCTAssertEqual(model.stockAllocation?.demands.first { $0.id == food }?.shortfall, try Rational(3))
        let reopened = PickupModel(databaseURL: url, clock: { self.now })
        await reopened.load()
        XCTAssertEqual(reopened.journey?.stockLots.last, three)
        let moved = await reopened.startNextShop(accept: [])
        XCTAssertTrue(moved)
        let target = try XCTUnwrap(reopened.journey?.id)
        XCTAssertTrue(try XCTUnwrap(reopened.journey?.stockLots).isEmpty)
        let wrongJourney = await reopened.saveStockLot(three, in: shop, carriedFrom: three)
        let staleBatch = await reopened.saveStockLot(three, in: target, carriedFrom: five)
        XCTAssertFalse(wrongJourney); XCTAssertFalse(staleBatch)
        let counted = lot(1, now)
        let carried = await reopened.saveStockLot(counted, in: target, carriedFrom: three)
        let repeated = await reopened.saveStockLot(counted, in: target, carriedFrom: three)
        XCTAssertTrue(carried); XCTAssertTrue(repeated)
        XCTAssertEqual(reopened.journey?.stockLots, [counted])
        XCTAssertEqual(reopened.stockAllocation?.demands.first?.shortfall, try Rational(2))
        XCTAssertNil(reopened.journey?.pickup)
        XCTAssertNil(reopened.journey?.quote)
    }

    @MainActor func testUnassignedBatchOnFreshInstallNeedsExplicitMatchEvenWithSameFoodName() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let id = UUID(), workspace = UUID(), needID = UUID()
        let observed = ConfirmedStockLot(id: id, foodID: id, name: "Beans", usable: quantity(3),
                                        confirmedAt: now, source: .pantry)
        let saved = await model.saveStockLot(observed, in: workspace, createIfEmpty: true)
        XCTAssertTrue(saved)
        XCTAssertNil(model.journey?.basket)
        XCTAssertTrue(try XCTUnwrap(model.allocation).allocations.isEmpty)
        let urgent = UrgentMealNeed(id: needID, food: "Beans", meal: "Dinner", required: quantity(4),
                                    available: quantity(0), due: nil, confirmedAt: now)
        let added = await model.addUrgent(urgent)
        XCTAssertTrue(added)
        XCTAssertEqual(model.allocation?.demands.first?.shortfall, try Rational(4))
        let reviewed = ConfirmedStockLot(id: id, foodID: needID, name: "Beans", usable: quantity(2),
                                        confirmedAt: now, source: .pantry)
        let matched = await model.saveStockLot(reviewed, in: workspace, replacing: observed)
        XCTAssertTrue(matched)
        XCTAssertEqual(model.allocation?.demands.first?.shortfall, try Rational(2))
        XCTAssertEqual(model.journey?.stockLots.filter { $0.source == .pantry }.count, 1)
    }

    @MainActor func testDatedStockCanReserveAnIngredientBeforePlacementWithoutCreatingAReceipt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let shop = UUID(), line = UUID(), lunch = UUID()
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "",
                                      commitmentsID: shop, observedAt: now, source: "Shopper")
        let started = await model.start(from: [BasketLine(id: line, name: "Rice", quantity: quantity(4),
                                                          expectedCost: .unknown(reason: "No price"))],
                                        shopID: shop, context: context, plannedNeeds: [
                                            AllocationNeed(id: lunch, orderLineID: line, name: "Lunch",
                                                           amount: quantity(2), priority: .protected)
                                        ])
        XCTAssertTrue(started)
        let batch = ConfirmedStockLot(id: UUID(), foodID: line, name: "Brown rice", usable: quantity(1),
                                      confirmedAt: now, source: .pantry)
        let saved = await model.saveStockLot(batch, in: shop)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.allocation?.allocations.first?.needID, lunch)
        XCTAssertEqual(model.allocation?.demands.first?.shortfall, .one)
        XCTAssertEqual(model.journey?.basket?.phase, .draft)
        XCTAssertNil(model.journey?.pickup)
        XCTAssertNil(model.journey?.quote)
    }

    func testUseFirstReservesPreferredLotAndLegacyBytesDecodeWithoutAHint() throws {
        let food = UUID(), old = ConfirmedStockLot(id: UUID(), foodID: food, name: "Pantry", usable: quantity(4),
                                                  confirmedAt: now, source: .pantry)
        let bytes = try JSONEncoder().encode(old)
        XCTAssertNil((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["useFirst"])
        XCTAssertEqual(try JSONDecoder().decode(ConfirmedStockLot.self, from: bytes), old)
        let preferred = ConfirmedStockLot(id: UUID(), foodID: food, name: "Opened batch", usable: quantity(3),
                                         confirmedAt: now, source: .freezer, useFirst: true)
        let need = StockNeed(id: UUID(), foodID: food, name: "Dinner", amount: quantity(4), priority: .required)
        let result = try ConfirmedStockAllocator.allocate(lots: [old, preferred], needs: [need])
        XCTAssertEqual(result.allocations.map(\.lotID), [preferred.id, old.id])
        XCTAssertEqual(result.remainingLots.first { $0.lotID == old.id }?.remainingUnallocated, try Rational(3))
    }
}
