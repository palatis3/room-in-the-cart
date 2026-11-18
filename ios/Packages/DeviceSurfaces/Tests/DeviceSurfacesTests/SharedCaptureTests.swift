import XCTest
@testable import DeviceSurfaces

final class SharedCaptureTests: XCTestCase {
    func testURLProviderStagesBoundedReopenableLinkAndPreservesReplayDisposition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared-captures.sqlite")
        let extensionInbox = try SharedCaptureInbox(url: file)
        let hostInbox = try SharedCaptureInbox(url: file)
        let url = try XCTUnwrap(URL(string: "https://recipes.example.org/beans?serves=4"))
        let provider = NSItemProvider(object: url as NSURL)
        let result = await withCheckedContinuation { continuation in
            SharedCaptureEnvelope.loadRecipeURL(from: provider) { continuation.resume(returning: $0) }
        }
        let envelope = try result.get()
        let id = UUID(), now = Date()
        let receipt = try await extensionInbox.stage(envelope, id: id, now: now)
        let rows = try await hostInbox.pendingRecipes(now: now)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.receipt, receipt)
        XCTAssertEqual(row.envelope.value, url.absoluteString)
        XCTAssertThrowsError(try SelectedTextInbox(url: file))
        try await hostInbox.discard(row, now: now)
        let replay = try await extensionInbox.stage(envelope, id: id, now: now)
        XCTAssertEqual(replay.disposition, .discarded)
        let second = try await extensionInbox.stage(envelope, id: UUID(), now: now)
        let expired = try await hostInbox.pendingRecipes(now: second.expiresAt)
        XCTAssertTrue(expired.isEmpty)
    }

    func testFileCredentialsInsecureAndOversizeURLsAreRejectedBeforeStaging() throws {
        for value in ["file:///some/receipt", "http://example.org/recipe", "https://me:pass@example.org/",
                      "https://example.org:10443/", "https://example.org/" + String(repeating: "x", count: 4096)] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try SharedCaptureEnvelope(recipeURL: url))
        }
    }
}
