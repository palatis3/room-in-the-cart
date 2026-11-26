import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LocalStore

final class CookingNoteStorageTests: XCTestCase {
    @MainActor func testStepPhotoNeedsExactRevisionAndAudienceAndCanBeRemovedWithoutLosingText() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let store = CookingSessionStore(directory: location)
        let source = UUID(), workspace = UUID(), actor = UUID()
        func key(_ revision: String, actor: UUID) throws -> CookingSessionKey {
            try .init(workspace: workspace, actor: actor, audience: ["adult"], kind: .recipe, source: source, revision: revision)
        }
        let first = try key("r1", actor: actor), revised = try key("r2", actor: actor)
        let jpeg = NSMutableData()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = CookingStepPhoto(jpeg: jpeg as Data, description: "  Golden edges  ")
        XCTAssertTrue(photo.valid)
        XCTAssertFalse(CookingStepPhoto(jpeg: Data([1, 2]), description: "Golden").valid)
        XCTAssertFalse(CookingStepPhoto(jpeg: jpeg as Data, description: " ").valid)
        let saved = CookingStepNote(revision: "r1", step: 1, instruction: "Stir", text: "", photo: photo)
        try store.replaceStepNote(nil, with: saved, for: first)
        let reopened = CookingSessionStore(directory: location)
        XCTAssertTrue(try reopened.stepNotes(for: key("r1", actor: UUID())).isEmpty)
        let old = try XCTUnwrap(reopened.stepNotes(for: revised).first)
        XCTAssertEqual(old.photo?.description, "Golden edges")
        XCTAssertFalse(old.belongs(to: revised, step: 1, instruction: "Stir"))
        XCTAssertFalse(old.belongs(to: first, step: 0, instruction: "Stir"))
        let moved = CookingStepNote(id: saved.id, revision: "r2", step: 0, instruction: "Stir", text: "Watch the edge", photo: old.photo)
        try reopened.replaceStepNote(old, with: moved, for: revised)
        XCTAssertThrowsError(try store.replaceStepNote(saved, with: nil, for: first))
        let without = CookingStepNote(id: moved.id, revision: "r2", step: 0, instruction: "Stir", text: moved.text)
        try reopened.replaceStepNote(moved, with: without, for: revised)
        XCTAssertEqual(try store.stepNotes(for: revised), [without])
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any]
        XCTAssertNil(legacy?["photo"])
        XCTAssertEqual(try JSONDecoder().decode(CookingStepNote.self, from: JSONEncoder().encode(without)), without)
    }

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
