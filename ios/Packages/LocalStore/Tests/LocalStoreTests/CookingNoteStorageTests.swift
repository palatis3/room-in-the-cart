import XCTest
@testable import LocalStore

final class CookingNoteStorageTests: XCTestCase {
    @MainActor func testReopensPrivateNotesWithoutSessionAndRejectsInvalidAndConcurrentReplacements() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let db = CookingSessionStore(directory: location)
        let actor = UUID(), source = UUID(), workspace = UUID()
        func key(_ revision: String, _ audience: [String?]) throws -> CookingSessionKey {
            try .init(workspace: workspace, actor: actor, audience: audience, kind: .recipe, source: source, revision: revision)
        }
        let first = try key("r1", ["actor", nil]), revised = try key("r2", ["actor", nil]), other = try key("r1", ["actor", ""])
        let note = CookingStepNote(revision: "r1", step: 1, instruction: "Turn", text: "Wait before turning")
        try db.replaceStepNote(nil, with: note, for: first)
        let reopened = CookingSessionStore(directory: location)
        XCTAssertNil(try reopened.load(first, stepCount: 2))
        XCTAssertEqual(try reopened.stepNotes(for: revised), [note])
        XCTAssertTrue(try reopened.stepNotes(for: other).isEmpty)
        let another = CookingStepNote(revision: "r1", step: 1, instruction: "Turn", text: "Other edit")
        XCTAssertThrowsError(try reopened.replaceStepNote(nil, with: another, for: first))
        let tooLong = CookingStepNote(id: note.id, revision: "r2", step: 0, instruction: "Turn again", text: String(repeating: "á", count: 1025))
        XCTAssertThrowsError(try reopened.replaceStepNote(note, with: tooLong, for: revised))
        XCTAssertEqual(try reopened.stepNotes(for: first), [note])
        let moved = CookingStepNote(id: note.id, revision: "r2", step: 0, instruction: "Turn again", text: note.text)
        try reopened.replaceStepNote(note, with: moved, for: revised)
        XCTAssertThrowsError(try db.replaceStepNote(note, with: nil, for: first))
        let removed = try db.eraseUnretainedRecipes(retaining: [])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(try reopened.stepNotes(for: revised).isEmpty)
    }
}
