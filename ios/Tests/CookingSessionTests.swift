import XCTest
import ImageIO
import UIKit
import UniformTypeIdentifiers
import LocalStore
import CoreDomain
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

    func testSelectedPhotoIsDownsampledAndStrippedBeforePrivateStepSave() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { context in
            UIColor.brown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        let original = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0,
            kCGImagePropertyGPSLatitudeRef: "N"] as [CFString: Any]]
        CGImageDestinationAddImage(output, try XCTUnwrap(image.cgImage), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let thumbnail = try PackageRowPhoto.makeThumbnail(original as Data, dimension: CookingStepPhoto.maximumDimension,
            byteLimit: CookingStepPhoto.maximumBytes)
        let cue = CookingStepPhoto(jpeg: thumbnail, description: "Golden edges")
        XCTAssertTrue(cue.valid)
        let input = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, CookingStepPhoto.maximumDimension)

        var allowed = true
        let model = CookingSessionModel(context: .init(key: try key(), authorize: { allowed }), count: 2, store: store(),
            schedule: { _, _, _ in false }, removeAlerts: { _ in })
        model.load()
        let note = CookingStepNote(revision: model.context.noteKey.revision, step: 0, instruction: "Stir", text: "", photo: cue)
        XCTAssertTrue(model.setStepNote(nil, with: note))
        XCTAssertEqual(model.currentStepNote(note)?.photo, cue)
        allowed = false
        XCTAssertNil(model.currentStepNote(note))
        XCTAssertFalse(model.setStepNote(note, with: nil))
    }

    func testPrivateStepNoteFollowsExactStepAndNeedsExplicitReattachmentAfterRevision() throws {
        let disk = store(), original = try key(revision: "first"), revised = try key(revision: "second")
        let first = CookingStepNote(revision: original.revision, step: 1, instruction: "Fold", text: "  Half the lime  ")
        try disk.replaceStepNote(nil, with: first, for: original)
        XCTAssertEqual(try disk.stepNotes(for: revised), [first])
        XCTAssertEqual(first.text, "Half the lime")
        XCTAssertTrue(first.belongs(to: original, step: 1, instruction: "Fold"))
        XCTAssertFalse(first.belongs(to: original, step: 0, instruction: "Fold"))
        XCTAssertFalse(first.belongs(to: revised, step: 1, instruction: "Fold"))
        XCTAssertFalse(first.belongs(to: original, step: 1, instruction: "Chill"))
        XCTAssertTrue(try disk.stepNotes(for: key(actor: UUID())).isEmpty)
        XCTAssertTrue(try disk.stepNotes(for: key(source: UUID())).isEmpty)
        XCTAssertTrue(try disk.stepNotes(for: key(kind: .dinner)).isEmpty)
        let moved = CookingStepNote(id: first.id, revision: revised.revision, step: 0, instruction: "Mix", text: first.text)
        try disk.replaceStepNote(first, with: moved, for: revised)
        XCTAssertThrowsError(try disk.replaceStepNote(first, with: nil, for: original))
        let dupe = CookingStepNote(revision: revised.revision, step: 0, instruction: "Mix", text: "Other scene")
        XCTAssertThrowsError(try disk.replaceStepNote(nil, with: dupe, for: revised))
        let hidden = CookingStepNote(id: moved.id, revision: moved.revision, step: moved.step, instruction: moved.instruction,
                                     text: moved.text, hidden: true)
        try disk.replaceStepNote(moved, with: hidden, for: revised)
        XCTAssertTrue(try XCTUnwrap(disk.stepNotes(for: revised).first).hidden)
        try disk.replaceStepNote(hidden, with: nil, for: revised)
        XCTAssertTrue(try disk.stepNotes(for: original).isEmpty)
    }

    func testReusableAndChosenDinnerShareOnlyNotesWhileEndingAndErasureRespectOwner() throws {
        let disk = store(), reusable = try key(kind: .reusableDinner), occurrence = try key(kind: .dinner)
        var allowed = true
        let model = CookingSessionModel(context: .init(key: occurrence, authorize: { allowed }, sourceNoteKey: reusable),
            count: 2, store: disk, schedule: { _, _, _ in false }, removeAlerts: { _ in })
        model.load()
        let note = CookingStepNote(revision: reusable.revision, step: 1, instruction: "Taste", text: "Try half")
        XCTAssertTrue(model.setStepNote(nil, with: note))
        model.choose(1)
        XCTAssertTrue(model.end())
        model.load()
        XCTAssertEqual(try disk.stepNotes(for: reusable), [note])
        XCTAssertNil(try disk.load(occurrence, stepCount: 2))
        XCTAssertTrue(try disk.stepNotes(for: occurrence).isEmpty)
        allowed = false
        XCTAssertFalse(model.setStepNote(note, with: nil))
        XCTAssertNil(model.currentStepNote(note))
        model.retire()
        XCTAssertTrue(model.stepNotes.isEmpty)
        let other = try key(), otherNote = CookingStepNote(revision: other.revision, step: 0, instruction: "Taste", text: "Private")
        try disk.replaceStepNote(nil, with: otherNote, for: other)
        _ = try disk.eraseUnretainedRecipes(retaining: [])
        XCTAssertTrue(try disk.stepNotes(for: other).isEmpty)
        XCTAssertEqual(try disk.stepNotes(for: reusable), [note])
        _ = try disk.erase(workspace: workspace)
        XCTAssertTrue(try disk.stepNotes(for: reusable).isEmpty)
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

extension CookingSessionTests {
    func testMeasuredAllocationsReopenOnlyForSameRevisionAndSurviveEndingTimers() async throws {
        let disk = store(), source = try key()
        let model = CookingSessionModel(context: .init(key: source, authorize: { true }), count: 2, store: disk,
            clock: { self.start }, schedule: { _, _, _ in false }, removeAlerts: { _ in })
        model.load()
        let amounts = CookingStepAmounts(recipeServings: try Rational(4), cookingServings: try Rational(2),
            allocations: [.init(ingredient: 0, originalAmount: try Rational(4), unit: .tablespoons,
                byStep: [0: try Rational(3), 1: .one])])
        XCTAssertTrue(model.saveAmounts(amounts, replacing: nil, ingredientCount: 1))
        await model.start(minutes: 12, alert: false)
        XCTAssertEqual(try disk.load(source, stepCount: 2)?.timers.first?.seconds, 720)
        XCTAssertTrue(model.end())
        let fresh = try XCTUnwrap(disk.load(source, stepCount: 2))
        XCTAssertEqual(fresh.stepAmounts, amounts)
        XCTAssertTrue(fresh.timers.isEmpty)
        XCTAssertNil(try disk.load(key(revision: "edited ingredients"), stepCount: 2))
    }
}
