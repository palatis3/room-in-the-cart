import XCTest
import CoreDomain
import DeviceSurfaces
@testable import RoomInTheCart

#if DEBUG
@MainActor final class ContextualReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)
    private struct Fixture {
        let directory: URL
        let ledger: LedgerModel
        let pickup: PickupModel
        let household: HouseholdModel
        let access: WorkspaceAccess
        let surfaces: DeviceSurfacesComposition
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { self.now })
        await ledger.open()
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        let shopID = UUID(), lineID = UUID()
        let quantity = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let line = BasketLine(id: lineID, name: "Wraps", quantity: quantity, expectedCost: .exact(.zero))
        let checkout = CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Evening",
            commitmentsID: shopID, observedAt: now, source: "Reviewed quote")
        let started = await pickup.start(from: [line], shopID: shopID, context: checkout)
        let quoted = await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: checkout, pricing: .inclusiveTotal(.exact(.zero))), cap: nil)
        let frozen = await pickup.freeze()
        let placed = await pickup.reportPlaced()
        XCTAssertTrue(started && quoted && frozen && placed)
        let offer = PickupOffer(id: UUID(), lineID: lineID, replacement: "Large wraps", required: quantity,
            remainingOriginal: Quantity(amount: .zero, unit: .count, originalLiteral: "0"), price: .exact(.zero), ceiling: nil,
            deadline: try RetailerDeadline(cutoff: now.addingTimeInterval(86_400), timeZoneID: "America/New_York"),
            fallback: "Leave unresolved", householdPreference: "", retailerResponse: "")
        let saved = await pickup.change {
            $0.offers = [offer]
            $0.deferred = [DeferredPickupNeed(id: UUID(), sourceShopID: shopID, line: line)]
        }
        XCTAssertTrue(saved)
        let suite = "ContextualReminderTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let household = HouseholdModel(outboxURL: directory.appendingPathComponent("household.json"))
        let surfaces = DeviceSurfacesComposition(directory: directory.appendingPathComponent("surfaces"), clock: { self.now }, launchArguments: ["--ui-testing"])
        surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        await surfaces.foreground()
        await settle { surfaces.reminderTargets.count == 2 }
        // Composition owns asynchronous SQLite actors without a public close port.
        // Keep these private simulator temporary files until process/container cleanup.
        return Fixture(directory: directory, ledger: ledger, pickup: pickup, household: household, access: access, surfaces: surfaces)
    }

    func testContextualOpeningKeepsTypedIdentityAndCreatesNoReminderOrShopMutation() async throws {
        let f = try await fixture()
        let before = try XCTUnwrap(f.pickup.journey)
        for target in f.surfaces.reminderTargets {
            let request = ContextualReminderRequest(target: target.target, sourceRevision: before.revision, sourceSavedAt: before.savedAt)
            XCTAssertEqual(request.resolve(in: f.surfaces.reminderTargets, at: now), target)
            let first = try await f.surfaces.reminderContext(target, expiresAt: now.addingTimeInterval(172_800))
            let reopened = try await f.surfaces.reminderContext(target, expiresAt: now.addingTimeInterval(172_800))
            XCTAssertEqual(first.reminderID, reopened.reminderID)
            XCTAssertEqual(first.routeHandle, reopened.routeHandle)
            XCTAssertEqual(first.targetID, target.id)
            XCTAssertEqual(first.sourceRevision, before.revision)
            XCTAssertEqual(first.personaID, f.access.localActorID)
            XCTAssertEqual(first.initialQuietHours, try QuietHours(startMinute: 22 * 60, endMinute: 7 * 60))
            switch target.target {
            case .offer: XCTAssertEqual(first.subject, .offer); XCTAssertEqual(first.cutoff, target.cutoff); XCTAssertEqual(first.expiresAt, target.cutoff)
            case .deferral: XCTAssertEqual(first.subject, .deferral); XCTAssertNil(first.cutoff); XCTAssertEqual(first.expiresAt, now.addingTimeInterval(172_800))
            case .shop: XCTFail("A general shopping list cannot be a deadline reminder")
            }
            let unscheduled = try await f.surfaces.reminders?.current(first.reminderID)
            XCTAssertNil(unscheduled)
        }
        let stored = try await f.surfaces.reminderStore?.all()
        XCTAssertEqual(stored?.count, 0)
        XCTAssertEqual(f.pickup.journey, before)
    }

    func testContextualResolutionRejectsOtherWorkspaceShopKindRevisionAndPassedCutoff() async throws {
        let f = try await fixture()
        let target = try XCTUnwrap(f.surfaces.reminderTargets.first { $0.cutoff != nil })
        let journey = try XCTUnwrap(f.pickup.journey)
        let workspace = try XCTUnwrap(f.pickup.sourceWorkspaceID)
        let requests: [ContextualReminderRequest] = [
            .init(target: .offer(workspaceID: UUID(), journeyID: journey.id, offerID: target.id), sourceRevision: journey.revision, sourceSavedAt: journey.savedAt),
            .init(target: .offer(workspaceID: workspace, journeyID: UUID(), offerID: target.id), sourceRevision: journey.revision, sourceSavedAt: journey.savedAt),
            .init(target: .deferral(workspaceID: workspace, journeyID: journey.id, needID: target.id), sourceRevision: journey.revision, sourceSavedAt: journey.savedAt),
            .init(target: target.target, sourceRevision: journey.revision - 1, sourceSavedAt: journey.savedAt)
        ]
        for request in requests { XCTAssertNil(request.resolve(in: f.surfaces.reminderTargets, at: now)) }
        let exact = ContextualReminderRequest(target: target.target, sourceRevision: journey.revision, sourceSavedAt: journey.savedAt)
        XCTAssertNil(exact.resolve(in: [target, target], at: now))
        XCTAssertNil(exact.resolve(in: f.surfaces.reminderTargets, at: try XCTUnwrap(target.cutoff)))
    }

    func testEditedSourceAndLockedWorkspaceInvalidatePreviouslyReviewedReminder() async throws {
        let f = try await fixture()
        let target = try XCTUnwrap(f.surfaces.reminderTargets.first)
        let context = try await f.surfaces.reminderContext(target, expiresAt: now.addingTimeInterval(172_800))
        XCTAssertNotNil(f.surfaces.reminderAuthorization(target))
        let changed = await f.pickup.change { $0.offers[0].householdPreference = "Review again" }
        XCTAssertTrue(changed)
        XCTAssertNil(f.surfaces.reminderAuthorization(target))
        do { _ = try await f.surfaces.reminderContext(target, expiresAt: context.expiresAt); XCTFail("Stale source must require a fresh review") }
        catch {}
        f.access.protect()
        XCTAssertTrue(f.surfaces.reminderTargets.isEmpty)
        XCTAssertNil(f.surfaces.reminderAuthorization(target))
    }

    func testExplicitSaveDeniedAndOffRemainSeparateFromPendingOfferAndDeferral() async throws {
        let f = try await fixture()
        let target = try XCTUnwrap(f.surfaces.reminderTargets.first { $0.cutoff == nil })
        let before = f.pickup.journey
        // The live app coordinator uses the system clock. Choose a future instant
        // against that clock while keeping the source fixture's dates deterministic.
        let schedulingNow = Date()
        let context = try await f.surfaces.reminderContext(target, expiresAt: schedulingNow.addingTimeInterval(172_800))
        let coordinator = try XCTUnwrap(f.surfaces.reminders)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: schedulingNow.addingTimeInterval(3600))
        let local = CivilReminderTime(year: try XCTUnwrap(parts.year), month: try XCTUnwrap(parts.month), day: try XCTUnwrap(parts.day),
            hour: try XCTUnwrap(parts.hour), minute: try XCTUnwrap(parts.minute), timeZoneID: "UTC", confirmedGMTOffset: 0)
        let intent = try ReminderIntent(id: context.reminderID, personaID: context.personaID, targetID: context.targetID,
            subject: context.subject, sourceRevision: context.sourceRevision, routeHandle: context.routeHandle,
            localTime: local, expiresAt: context.expiresAt, language: .english, now: schedulingNow)
        // The test runtime never invokes an OS authorization or notification API.
        let denied = try await coordinator.save(intent, expectedVersion: nil, requestPermission: true)
        XCTAssertEqual(denied.status, .denied)
        let reopened = try await f.surfaces.reminderContext(target, expiresAt: context.expiresAt)
        XCTAssertEqual(reopened.timeZoneID, local.timeZoneID)
        XCTAssertEqual(reopened.initialFireAt, intent.fireAt)
        XCTAssertNil(reopened.initialQuietHours)
        XCTAssertEqual(reopened.expectedVersion, denied.version)
        try await coordinator.cancel(intent.id)
        let cancelled = try await coordinator.current(intent.id)
        XCTAssertEqual(cancelled?.status, .cancelled)
        XCTAssertEqual(f.pickup.journey, before)
        XCTAssertEqual(f.pickup.journey?.deferred.first?.status, "review")
        XCTAssertEqual(f.pickup.journey?.offers.first?.retailerResponse, "")
    }

    func testAcceptedNextShopRetiresPreviousContextualTargetsWithoutChangingOldPurchase() async throws {
        let f = try await fixture()
        let previous = try XCTUnwrap(f.pickup.journey)
        let target = try XCTUnwrap(f.surfaces.reminderTargets.first { $0.cutoff == nil })
        let originalOrder = previous.pickup
        let created = await f.pickup.startNextShop(accept: [], sourceID: previous.id, sourceRevision: previous.revision)
        XCTAssertTrue(created)
        XCTAssertNil(f.surfaces.reminderAuthorization(target))
        XCTAssertTrue(f.surfaces.reminderTargets.allSatisfy { $0.target != target.target })
        XCTAssertEqual(f.pickup.journeys.first { $0.id == previous.id }?.pickup, originalOrder)
        XCTAssertNil(f.pickup.journey?.pickup)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Device surfaces did not finish loading their durable source identities")
    }
}
#endif
