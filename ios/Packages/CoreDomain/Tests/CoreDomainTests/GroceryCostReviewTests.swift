import Foundation
import XCTest
@testable import CoreDomain

final class GroceryCostReviewTests: XCTestCase {
    func testWholePackBasketCoverageAndComparableChange() throws {
        for currency in Currency.allCases {
            let other = UUID(), oil = UUID(), unknown = UUID()
            func basket(oilCost: Int64?, missing: UUID) throws -> GroceryCostReview {
                try GroceryCostReview(lines: [(other, Money(minorUnits: 3100, currency: currency)),
                    (oil, oilCost.map { Money(minorUnits: $0, currency: currency) }), (missing, nil)],
                    currency: currency, inventoryComplete: true)
            }
            let first = try basket(oilCost: 800, missing: unknown)
            let later = try basket(oilCost: 0, missing: unknown)
            XCTAssertEqual(first.known?.minorUnits, 3900)
            XCTAssertEqual(later.known?.minorUnits, 3100)
            XCTAssertEqual(try later.pricedChange(from: first)?.minorUnits, -800)
            XCTAssertNil(try basket(oilCost: nil, missing: unknown).pricedChange(from: first))
            XCTAssertNil(try basket(oilCost: 0, missing: UUID()).pricedChange(from: first))
            let empty = try GroceryCostReview(lines: [(oil, nil)], currency: currency, inventoryComplete: true)
            XCTAssertNil(empty.known)
        }
    }
    func testSplitStopsReconcileAndTravelReversesGroceryAdvantage() throws {
        let a = UUID(), b = UUID()
        let rows = [GroceryStoreSplit.Line(id: a, first: Money(minorUnits: 600), second: Money(minorUnits: 400), secondStop: true),
                    GroceryStoreSplit.Line(id: b, first: Money(minorUnits: 300), second: nil, secondStop: false)]
        func preview(_ trip: Int64?, confirmed: Bool = true) throws -> GroceryStoreSplit {
            try .init(lines: rows, currency: .usd, travel: trip.map { Money(minorUnits: $0) }, conditionsConfirmed: confirmed)
        }
        let split = try preview(300)
        XCTAssertEqual(split.single.known?.minorUnits, 900)
        XCTAssertEqual(split.firstStop.known?.minorUnits, 300)
        XCTAssertEqual(split.secondStop.known?.minorUnits, 400)
        XCTAssertEqual(split.split.known?.minorUnits, 700)
        XCTAssertEqual(split.changeWithTravel?.minorUnits, 100)
        XCTAssertEqual(try preview(0).changeWithTravel?.minorUnits, -200)
        XCTAssertNil(try preview(nil).changeWithTravel)
        XCTAssertNil(try preview(0, confirmed: false).changeWithTravel)
        XCTAssertThrowsError(try GroceryStoreSplit(lines: rows, currency: .mxn, travel: nil, conditionsConfirmed: true))
        XCTAssertThrowsError(try GroceryStoreSplit(lines: [rows[0], rows[0]], currency: .usd, travel: nil, conditionsConfirmed: true))
    }
}
