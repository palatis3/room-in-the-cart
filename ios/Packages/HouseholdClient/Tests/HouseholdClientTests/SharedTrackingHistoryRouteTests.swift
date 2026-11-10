import Foundation
import XCTest
@testable import HouseholdClient

final class SharedTrackingHistoryRouteTests: XCTestCase {
    private func item(_ route: Any? = nil, extra: Bool = false) throws -> SharedTrackingHistoryItem {
        var value: [String: Any] = ["operationId": "00000000-0000-4000-8000-000000000001", "shopRevision": 2,
            "committedAt": "2026-11-10T12:00:00Z", "status": "current_preview_required"]
        if let route { value["reviewRoute"] = route }
        if extra { value["eligible"] = true }
        return try JSONDecoder().decode(SharedTrackingHistoryItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testOldProvenHistoryAbsenceRetainsTrackingRoute() throws { XCTAssertEqual(try item().reviewRoute, .tracking) }
    func testKnownRoutesRemainExplicitAndDoNotPromiseEligibility() throws {
        XCTAssertEqual(try item("tracking").reviewRoute, .tracking)
        XCTAssertEqual(try item("requestAcceptance").reviewRoute, .requestAcceptance)
    }
    func testNullUnknownMistypedAndExtraFieldsNeverFallback() {
        for route: Any in [NSNull(), "futureCompound", 1, false] { XCTAssertThrowsError(try item(route)) }
        XCTAssertThrowsError(try item("tracking", extra: true))
    }
}
