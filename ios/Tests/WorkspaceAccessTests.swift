import XCTest
@testable import RoomInTheCart

@MainActor final class WorkspaceAccessTests: XCTestCase {
    func testFirstPrivateUseDoesNotRequireAnAccountOrDeviceAuthentication() {
        let name = "WorkspaceAccessTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let access = WorkspaceAccess(defaults: defaults)
        XCTAssertTrue(access.unlocked)
        XCTAssertFalse(access.isProtected)
        access.background()
        XCTAssertTrue(access.unlocked)
    }

    func testSharedPersonaProtectionSurvivesRelaunch() {
        let name = "WorkspaceAccessTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let access = WorkspaceAccess(defaults: defaults)
        access.protect()
        XCTAssertFalse(access.unlocked)
        XCTAssertTrue(access.isProtected)
        let reopened = WorkspaceAccess(defaults: defaults)
        XCTAssertEqual(reopened.localActorID, access.localActorID)
        XCTAssertFalse(reopened.unlocked)
        XCTAssertTrue(reopened.isProtected)
        reopened.background()
        XCTAssertFalse(reopened.unlocked)
    }
}
