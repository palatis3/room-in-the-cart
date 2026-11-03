import XCTest
import CoreDomain
@testable import RoomInTheCart

final class PickupStockPrivateScopeTests: XCTestCase {
    private let workspace = UUID(), actor = UUID()
    private func presentation(subject: String? = "signed-in-adult", locked: Bool = true, unlocked: Bool = true,
                              active: Bool = true, child: Bool = false, childOnly: Bool = false,
                              projection: PickupStockReviewProjection? = nil, workspace: UUID? = nil, actor: UUID? = nil) -> PickupStockReviewPresentation {
        .init(workspaceID: workspace ?? self.workspace, localActorID: actor ?? self.actor,
            workspaceUnlocked: unlocked, sceneActive: active, childPresented: child, guardianChildOnly: childOnly,
            accountSubject: subject, householdLocked: locked, projection: projection)
    }
    private func projection(role: String = "shopper", enrolled: Bool = true, household: String = "home",
                            member: String = "member", shop: String? = "shop", grant: String? = nil,
                            capabilities: [String] = []) -> PickupStockReviewProjection {
        .init(householdID: household, memberID: member, role: role, enrolled: enrolled,
            shopID: shop, grantID: grant, capabilities: capabilities)
    }

    func testOwnerUnlockedPrivateScopeAllowsRetainedAccountWhileHouseholdRemainsLocked() throws {
        let value = presentation(), scope = try XCTUnwrap(value.scope(presentationID: UUID()))
        XCTAssertTrue(scope.permitsReview)
        XCTAssertEqual(scope.workspaceID, workspace); XCTAssertEqual(scope.localActorID, actor)
        XCTAssertEqual(scope.accountSubject, "signed-in-adult"); XCTAssertTrue(scope.householdLocked)
        XCTAssertNil(scope.householdID); XCTAssertNil(scope.memberID); XCTAssertNil(scope.role)
        XCTAssertNil(scope.projection, "This admission must not fabricate a household grant.")
        XCTAssertNotNil(presentation(subject: nil, locked: false).scope(presentationID: UUID()))
    }
    func testAnyLiveContributorHelperOrEditorProjectionRemainsDenied() {
        for role in ["contributor", "helper", "editor", "child", "unknown"] {
            for locked in [true, false] {
                XCTAssertNil(presentation(locked: locked, projection: projection(role: role)).scope(presentationID: UUID()), role)
            }
        }
        XCTAssertNil(presentation(subject: nil, projection: projection()).scope(presentationID: UUID()))
        XCTAssertNil(presentation(projection: projection(enrolled: false)).scope(presentationID: UUID()))
        for role in ["shopper", "organizer"] {
            XCTAssertNotNil(presentation(locked: false, projection: projection(role: role)).scope(presentationID: UUID()))
        }
    }
    func testLockedDeviceInactiveSceneAndChildBoundaryCannotMintPrivateReview() {
        for value in [presentation(unlocked: false), presentation(active: false), presentation(child: true), presentation(childOnly: true)] {
            XCTAssertNil(value.scope(presentationID: UUID()))
        }
        let noWorkspace = PickupStockReviewPresentation(workspaceID: nil, localActorID: actor, workspaceUnlocked: true,
            sceneActive: true, childPresented: false, guardianChildOnly: false, accountSubject: "adult", householdLocked: true, projection: nil)
        XCTAssertNil(noWorkspace.scope(presentationID: UUID()))
    }
    func testSessionFailsClosedBeforeObservedBoundaryAndRotatesForAccountLockAndProjectionChanges() throws {
        let original = presentation(locked: false, projection: projection())
        var session = PickupStockReviewSession()
        XCTAssertNil(session.scope(for: original))
        XCTAssertTrue(session.refresh(original))
        let initial = try XCTUnwrap(session.scope(for: original))
        XCTAssertFalse(session.refresh(original)); XCTAssertEqual(session.scope(for: original), initial)
        let changes = [presentation(subject: "other", locked: false, projection: projection()),
            presentation(locked: true, projection: projection()),
            presentation(locked: false, projection: projection(household: "other")),
            presentation(locked: false, projection: projection(member: "other")),
            presentation(locked: false, projection: projection(shop: "other")),
            presentation(locked: false, projection: projection(grant: "other")),
            presentation(locked: false, projection: projection(capabilities: ["new-capability"])),
            presentation(locked: false, projection: projection(role: "organizer")),
            presentation(locked: false, projection: projection(), workspace: UUID()),
            presentation(locked: false, projection: projection(), actor: UUID())]
        for change in changes {
            XCTAssertNil(session.scope(for: change), "A queued callback cannot use a new boundary before its invalidation handler runs.")
            XCTAssertTrue(session.refresh(change))
            XCTAssertNotEqual(session.scope(for: change), initial)
            XCTAssertTrue(session.refresh(original))
            XCTAssertNotEqual(session.scope(for: original), initial, "Returning to A after B must not revive the original lease.")
        }
    }
    @MainActor func testAccountAndHouseholdLockABAInvalidateModelReviewWithoutChangingStock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), model = PickupModel(databaseURL: directory, clock: { now }), food = UUID()
        func q(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
        let started = await model.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try q(4), available: try q(0), due: nil, confirmedAt: now))
        XCTAssertTrue(started)
        let shop = try XCTUnwrap(model.journey?.id), id = UUID()
        let original = ConfirmedStockLot(id: id, foodID: food, name: "Counted batch", usable: try q(3), confirmedAt: now, source: .freezer)
        let corrected = ConfirmedStockLot(id: id, foodID: food, name: "Counted batch", usable: try q(1), confirmedAt: now, source: .freezer)
        let saved = await model.saveStockLot(original, in: shop); XCTAssertTrue(saved)
        let baseline = model.journey
        let a = presentation(workspace: try XCTUnwrap(model.sourceWorkspaceID))
        var session = PickupStockReviewSession(); session.refresh(a)
        let review = try model.previewStockLot(corrected, in: shop, replacing: original, scope: XCTUnwrap(session.scope(for: a)))
        for b in [presentation(subject: "other", workspace: try XCTUnwrap(model.sourceWorkspaceID)),
                  presentation(locked: false, workspace: try XCTUnwrap(model.sourceWorkspaceID)),
                  presentation(unlocked: false, workspace: try XCTUnwrap(model.sourceWorkspaceID)),
                  presentation(child: true, workspace: try XCTUnwrap(model.sourceWorkspaceID))] {
            session.refresh(b)
            let changed = await model.applyStockLotReview(review, scope: session.scope(for: b), confirmed: true)
            XCTAssertFalse(changed)
            session.refresh(a)
            let returned = await model.applyStockLotReview(review, scope: session.scope(for: a), confirmed: true)
            XCTAssertFalse(returned); XCTAssertEqual(model.journey, baseline)
        }
        let currentScope = try XCTUnwrap(session.scope(for: a))
        let fresh = try model.previewStockLot(corrected, in: shop, replacing: original, scope: currentScope)
        let applied = await model.applyStockLotReview(fresh, scope: currentScope, confirmed: true)
        XCTAssertTrue(applied)
        XCTAssertEqual(model.journey?.revision, try XCTUnwrap(baseline?.revision) + 1)
        XCTAssertEqual(model.allocation?.demands.first { $0.id == food }?.shortfall, try Rational(3))
    }
}
