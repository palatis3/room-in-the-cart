import XCTest
@testable import RoomInTheCart

@MainActor final class RegionalAgeCheckTests: XCTestCase {
    func testOptionalSharingIsNeverRequested() async {
        let check = RegionalAgeCheck()
        await check.start(required: { false }, request: {
            XCTFail("Optional age ranges must stay private")
            return false
        })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testMandatorySharingAndDuplicateRequests() async {
        let check = RegionalAgeCheck()
        let running = check.start(required: { true }, request: { true })
        XCTAssertNil(check.start(required: { true }, request: { XCTFail(); return true }))
        await running?.value
        XCTAssertEqual(check.state, .ready)
        XCTAssertNil(check.start(required: { true }, request: { XCTFail(); return true }))
    }

    func testDecliningNeverAuthorizesAndRetryCanSucceed() async {
        let check = RegionalAgeCheck()
        await check.start(required: { true }, request: { false })?.value
        XCTAssertEqual(check.state, .declined)
        await check.start(required: { true }, request: { true })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testUnknownEligibilityAndNetworkFailureAllowRetry() async {
        let check = RegionalAgeCheck()
        await check.start(required: { throw URLError(.notConnectedToInternet) }, request: {
            XCTFail("Never ask while eligibility is unknown")
            return false
        })?.value
        XCTAssertEqual(check.state, .unavailable)
        await check.start(required: { true }, request: { throw URLError(.timedOut) })?.value
        XCTAssertEqual(check.state, .unavailable)
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testStaleAppleAccountResponseCannotOpenNextSession() async throws {
        let check = RegionalAgeCheck()
        let entered = expectation(description: "Apple request started")
        var pending: CheckedContinuation<Bool, Never>?
        let first = check.start(required: { true }, request: {
            await withCheckedContinuation { pending = $0; entered.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 5)
        check.reset()
        await check.start(required: { true }, request: { false })?.value
        try XCTUnwrap(pending).resume(returning: true)
        await first?.value
        XCTAssertEqual(check.state, .declined)
    }
}
