import XCTest
@testable import RoomInTheCart

@MainActor
final class ShoppingDisplayTimerTests: XCTestCase {
    func testEndingOneTripPreservesAnotherAndRestoresPreviousSetting() {
        for previous in [false, true] {
            var systemValue = previous
            var writes: [Bool] = []
            let timer = ShoppingDisplayTimer(current: { systemValue }, apply: {
                systemValue = $0
                writes.append($0)
            })
            let first = UUID()
            let second = UUID()
            timer.begin(first)
            timer.begin(first)
            timer.begin(second)
            timer.end(first)
            timer.end(first)
            XCTAssertTrue(systemValue)
            timer.end(second)
            XCTAssertEqual(systemValue, previous)
            XCTAssertEqual(writes, [true, previous])
            XCTAssertTrue(timer.active.isEmpty)
        }
    }

    func testTimeoutReleasesTripAndAnEndedTripCanBeEnabledAgain() async {
        let expired = expectation(description: "Screen resumes the normal idle setting")
        var firstExpiration = true
        let timer = ShoppingDisplayTimer(duration: .milliseconds(10), current: { false }, apply: { enabled in
            if !enabled && firstExpiration {
                firstExpiration = false
                expired.fulfill()
            }
        })
        let owner = UUID()
        timer.begin(owner)
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertFalse(timer.active.contains(owner))
        timer.begin(owner)
        XCTAssertTrue(timer.active.contains(owner))
        timer.end(owner)
    }
}
