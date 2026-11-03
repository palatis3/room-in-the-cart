import XCTest
@testable import RoomInTheCart

final class ContextualNavigationTests: XCTestCase {
    private func scope(subject: String = "adult", household: String = "home", member: String = "member",
                       shop: String? = "shop", role: String = "shopper", capabilities: Set<String> = ["shopper_inbox", "request_preview", "shopper_commands"]) -> ContextualHouseholdScope {
        .init(subject: subject, householdID: household, memberID: member, shopID: shop, role: role, capabilities: capabilities)
    }
    func testInboxRequiresAssignedShopperAndAllPreviewCapabilities() {
        let current = scope()
        XCTAssertTrue(current.allows(.inbox, current: current))
        XCTAssertFalse(scope(shop: nil).permits(.inbox))
        XCTAssertFalse(scope(role: "organizer", capabilities: ["household_admin"]).permits(.inbox))
        XCTAssertFalse(scope(role: "contributor").permits(.inbox))
        XCTAssertFalse(scope(role: "editor").permits(.inbox))
        XCTAssertFalse(scope(capabilities: ["shopper_inbox", "shopper_commands"]).permits(.inbox))
    }
    func testOpenDestinationCannotFollowAnotherAccountHouseholdMemberShopOrRole() {
        let original = scope()
        for current in [scope(subject: "other"), scope(household: "other"), scope(member: "other"),
                        scope(shop: "other"), scope(role: "organizer"), scope(capabilities: [])] {
            XCTAssertFalse(original.allows(.inbox, current: current))
            XCTAssertFalse(original.allows(.composer, current: current))
        }
        XCTAssertFalse(original.allows(.composer, current: nil))
        XCTAssertTrue(original.allows(.composer, current: original))
    }
    func testManagingViewsDoesNotGrantAComposerOrHouseholdAuthorityToHelpers() {
        let organizer = scope(shop: nil, role: "organizer", capabilities: ["household_admin"])
        XCTAssertTrue(organizer.permits(.managedViews))
        XCTAssertFalse(organizer.permits(.composer))
        XCTAssertFalse(scope(role: "helper", capabilities: ["household_admin"]).permits(.managedViews))
        XCTAssertFalse(scope(role: "child", capabilities: ["household_admin"]).permits(.managedViews))
        XCTAssertFalse(scope(subject: "").permits(.composer))
    }
}
