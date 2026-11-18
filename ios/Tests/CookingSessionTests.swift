import XCTest
import LocalStore
@testable import RoomInTheCart

@MainActor final class CookingSessionTests: XCTestCase {
    private let workspace = UUID()
    private let actor = UUID()
    private let source = UUID()
    private let start = Date(timeIntervalSince1970: 1800000000)

    private func key(kind: CookingSourceKind = .recipe, revision: String = "review",
                     actor: UUID? = nil, source: UUID? = nil) throws -> CookingSessionKey {
        try CookingSessionKey(workspace: workspace, actor: actor ?? self.actor, audience: ["subject", nil],
            kind: kind, source: source ?? self.source, revision: revision)
    }
    private func store() -> CookingSessionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CookingSessionStore(directory: directory)
    }

    func testTwoTimersReopenPausedAndExpiredAndDeniedAlertRetainsDeadline() async throws {
        let disk = store(), source = try key(), origin = start
        var now = origin
        var attempted: [UUID] = []
        var removed: [UUID] = []
        let context = CookingSessionContext(key: source, authorize: { true })
        func open() -> CookingSessionModel {
            let model = CookingSessionModel(context: context, count: 2, store: disk, clock: { now },
                schedule: { timer, ask, current in
                    XCTAssertTrue(current())
                    if ask { attempted.append(timer.id) }
                    return false
                }, removeAlerts: { removed.append(contentsOf: $0.map(\.id)) })
            model.load()
            return model
        }
        let first = open()
        await first.start(minutes: 2, alert: true)
        XCTAssertNotNil(first.message)
        let running = try XCTUnwrap(first.session?.timers.first)
        XCTAssertEqual(running.deadline, origin.addingTimeInterval(120))
        first.choose(1)
        await first.start(minutes: 1, alert: false)
        let second = try XCTUnwrap(first.session?.timers.last)
        now = origin.addingTimeInterval(15)
        first.pause(running)
        XCTAssertEqual(removed, [running.id])
        first.retire()
        now = origin.addingTimeInterval(80)
        let restored = open()
        XCTAssertEqual(restored.session?.step, 1)
        let paused = try XCTUnwrap(restored.session?.timers.first)
        XCTAssertEqual(paused.pausedSeconds, 105)
        XCTAssertEqual(second.remaining(at: now), 0)
        XCTAssertEqual(restored.session?.timers.map(\.id), [running.id, second.id])
        await restored.resume(paused)
        XCTAssertEqual(restored.session?.timers.first?.deadline, now.addingTimeInterval(105))
        XCTAssertEqual(attempted, [running.id])
        restored.cancel(second)
        XCTAssertEqual(restored.session?.timers.count, 1)
        XCTAssertTrue(restored.end())
        XCTAssertNil(open().session)
        XCTAssertEqual(removed, [running.id, second.id, running.id])
    }

    func testRevokedScopeAndInterveningChangesCannotMutateTimers() async throws {
        let disk = store(), source = try key(), origin = start
        var allowed = true
        let context = CookingSessionContext(key: source, authorize: { allowed })
        func open() -> CookingSessionModel {
            let model = CookingSessionModel(context: context, count: 2, store: disk, clock: { origin },
                schedule: { _, _, _ in XCTFail("Alerts are disabled"); return false }, removeAlerts: { _ in })
            model.load()
            return model
        }
        let one = open(), stale = open()
        await one.start(minutes: 2, alert: false)
        stale.choose(1)
        XCTAssertEqual(stale.session, one.session)
        XCTAssertNotNil(stale.message)
        let before = try XCTUnwrap(one.session)
        allowed = false
        one.cancel(before.timers[0])
        XCTAssertFalse(one.ready)
        XCTAssertNil(one.session)
        XCTAssertFalse(one.end())
        XCTAssertEqual(try disk.load(source, stepCount: 2), before)
        XCTAssertNil(try disk.load(key(revision: "different"), stepCount: 2))
        XCTAssertNil(try disk.load(key(actor: UUID()), stepCount: 2))
    }

    func testErasingRecipeCopiesAndLedgerRetiresOnlyRelatedTimers() throws {
        let disk = store(), recipe = try key(), retained = UUID()
        let other = try key(source: retained), dinner = try key(kind: .dinner)
        var state = CookingSession()
        try state.start(minutes: 1, step: 0, alert: true, at: start)
        for source in [recipe, other, dinner] { try disk.replace(nil, with: state, for: source, stepCount: 1) }
        XCTAssertEqual(try disk.eraseUnretainedRecipes(retaining: [retained]), state.timers)
        XCTAssertNil(try disk.load(recipe, stepCount: 1))
        XCTAssertEqual(try disk.load(dinner, stepCount: 1), state)
        XCTAssertEqual(try disk.load(other, stepCount: 1), state)
        XCTAssertEqual(try disk.erase(workspace: workspace).count, 2)
        XCTAssertNil(try disk.load(other, stepCount: 1))
        XCTAssertNil(try disk.load(dinner, stepCount: 1))
    }

    func testLimitsAndLegacySinglePageSession() throws {
        var state = CookingSession()
        XCTAssertThrowsError(try state.start(minutes: 0, step: 0, alert: false, at: start))
        for _ in 0..<8 { try state.start(minutes: 1, step: 0, alert: false, at: start) }
        XCTAssertThrowsError(try state.start(minutes: 1, step: 0, alert: false, at: start))
        let disk = store(), recipe = try key()
        try disk.replace(nil, with: state, for: recipe, stepCount: 1)
        var changed = state
        changed.step = 1
        XCTAssertThrowsError(try disk.replace(state, with: changed, for: recipe, stepCount: 1))
        XCTAssertEqual(try disk.load(recipe, stepCount: 1), state)
    }
}
