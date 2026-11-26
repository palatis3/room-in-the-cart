import XCTest
@testable import CoreDomain

final class DinnerBasketSampleTests: XCTestCase {
    func testChangingNightsBuysFewerPacksAndKeepsTheLunchReservation() throws {
        for currency in Currency.allCases {
            let price: Int64 = currency == .mxn ? 3_200 : 200
            for (tuesday, thursday, packs) in [(true, true, Int64(2)), (false, true, 1), (true, false, 1), (false, false, 1)] {
                let week = try DinnerBasketSample.changedWeek(currency: currency, keepTuesday: tuesday, keepThursday: thursday)
                XCTAssertEqual(week.packs, packs)
                XCTAssertEqual(week.riceCost, Money(minorUnits: price * packs, currency: currency))
            }
        }
    }

    func testSwitchingDinnerPreservesTwoLunchesAndLeavesTheUnpricedLineOpen() throws {
        let held = try Rational(2)
        for currency in Currency.allCases {
            let baskets = try DinnerBasketSample.compare(currency: currency)
            XCTAssertEqual(baskets.tacos.tortillaPacks, 2)
            XCTAssertEqual(baskets.soup.tortillaPacks, 1)
            XCTAssertNil(baskets.tacos.brothPrice)
            XCTAssertEqual(baskets.soup.brothPrice?.minorUnits, currency == .mxn ? 1000 : 150)
            for (basket, expected) in [(baskets.tacos, currency == .mxn ? Int64(3000) : 400),
                                       (baskets.soup, currency == .mxn ? Int64(2500) : 350)] {
                XCTAssertEqual(basket.result.checkout.total.lowerBound, Money(minorUnits: expected, currency: currency))
                XCTAssertNil(basket.result.checkout.total.exact)
                XCTAssertNil(basket.result.checkout.total.upperBound)
                XCTAssertEqual(basket.result.stockAllocation.demands.first { $0.needed == held }?.allocated, held)
            }
        }
    }
}
