import XCTest
@testable import CoreDomain

final class StaplePromptTests: XCTestCase {
    private let food = UUID()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func day(_ number: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: number, hour: 12))!
    }
    private func purchase(_ number: Int, _ amount: Int64 = 1, foodID: UUID? = nil,
                          unit: UnitOfMeasure = .liter, receiptID: UUID = UUID(), ordinal: Int = 0) throws -> ReceiptAcquisition {
        let quantity = Quantity(amount: try Rational(amount), unit: unit, originalLiteral: String(amount))
        return ReceiptAcquisition(receiptID: receiptID, ordinal: ordinal, lotID: UUID(), foodID: foodID ?? food,
            merchant: "Market", purchaseDate: day(number), transactionReference: nil, imageDigest: nil, originalLine: "MILK",
            name: "Milk", received: quantity, usable: quantity, paidLineTotal: nil, stock: .added(location: .fridge))
    }
    private func due(_ facts: [ReceiptAcquisition], _ number: Int = 25, plenty: [InventoryLot] = [],
                     ids: Set<UUID> = [], names: [String] = []) throws -> [StaplePrompt] {
        try StaplePrompt.due(purchases: facts, lots: plenty, openFoodIDs: ids, openLineNames: names, on: day(number), calendar: calendar)
    }
    func testVariedIntervalsAcrossDSTUseCivilMedianAndOnlyReviewedPurchases() throws {
        let first = try purchase(1), second = try purchase(8, 1000, unit: .milliliter), third = try purchase(17)
        let correction = try first.correctingPaidTotal(Money(minorUnits: 450))
        let history = [first, second, first, correction, third]
        XCTAssertTrue(try due(history, 24).isEmpty)
        let item = try XCTUnwrap(due(history).first)
        XCTAssertEqual(item.id, food)
        XCTAssertEqual(item.comparablePurchaseDays, 3)
        XCTAssertEqual(item.intervalDays, 8)
        XCTAssertEqual(item.latestAcquisitionID, third.id)
        XCTAssertEqual(item.dueDay, calendar.startOfDay(for: day(25)))
        XCTAssertTrue(try due([first, first, second, correction]).isEmpty)
        XCTAssertTrue(try due(history + [purchase(23, 2)]).isEmpty)
        XCTAssertTrue(try due(history + [purchase(23, unit: .count)]).isEmpty)
        XCTAssertTrue(try due([first, second, purchase(17, foodID: UUID())]).isEmpty)
    }
    func testOpenDemandAndHaveEnoughSuppressWithoutInventingStock() throws {
        let facts = try [purchase(1), purchase(8), purchase(15)]
        func lot(_ count: InventoryCount) -> InventoryLot {
            InventoryLot(id: UUID(), foodID: food, name: "Milk", source: .manual(originID: UUID(), sourceID: UUID()),
                revision: 1, location: .fridge, unit: .liter, count: count, observationID: UUID(),
                confirmedAt: day(21), updatedAt: day(21))
        }
        XCTAssertTrue(try due(facts, plenty: [lot(.haveEnough)]).isEmpty)
        XCTAssertTrue(try due(facts, ids: [food]).isEmpty)
        XCTAssertTrue(try due(facts, names: ["  MILK  "]).isEmpty)
        XCTAssertEqual(try due(facts, plenty: [lot(.unknown)]).count, 1)
        let empty = lot(.exact(Quantity(amount: .zero, unit: .liter, originalLiteral: "0")))
        XCTAssertEqual(try due(facts, 21, plenty: [empty]).first?.reason, .confirmedEmpty)
        XCTAssertTrue(try due(facts, 21, plenty: [empty, lot(.someLeft)]).isEmpty)
        XCTAssertTrue(try due(facts, 20, plenty: [empty]).isEmpty)
        let sameDay = try [purchase(1), purchase(8), purchase(8)]
        XCTAssertTrue(try due(sameDay).isEmpty)
    }
}
