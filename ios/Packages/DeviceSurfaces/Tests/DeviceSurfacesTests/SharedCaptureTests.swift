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
        // One Unix timestamp ULP past a whole second requires more than 15 decimal digits.
        let now = Date(timeIntervalSince1970: Double(1_800_000_000).nextUp)
        let id = UUID()
        let receipt = try await extensionInbox.stage(envelope, id: id, now: now)
        XCTAssertEqual(receipt.createdAt, now)
        XCTAssertEqual(receipt.expiresAt, now.addingTimeInterval(SelectedTextInbox.lifetime))
        let rows = try await hostInbox.pendingRecipes(now: now)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.receipt, receipt)
        XCTAssertEqual(row.envelope.value, url.absoluteString)
        XCTAssertThrowsError(try SelectedTextInbox(url: file))
        try await hostInbox.discard(row, now: now)
        let replay = try await extensionInbox.stage(envelope, id: id, now: now)
        XCTAssertEqual(replay.disposition, .discarded)
        let second = try await extensionInbox.stage(envelope, id: UUID(), now: now)
        let reopened = try SharedCaptureInbox(url: file)
        let justBefore = Date(timeIntervalSince1970: second.expiresAt.timeIntervalSince1970.nextDown)
        // On older SQLite this exact rounded date was persisted in the private review journal.
        XCTAssertTrue(second.matchesRecordedExpiry(justBefore))
        XCTAssertTrue(second.matchesRecordedExpiry(second.expiresAt))
        XCTAssertFalse(second.matchesRecordedExpiry(Date(timeIntervalSince1970: second.expiresAt.timeIntervalSince1970.nextUp)))
        let pending = try await reopened.pendingRecipes(now: justBefore)
        XCTAssertEqual(pending.map(\.receipt), [second])
        let expired = try await reopened.pendingRecipes(now: second.expiresAt)
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
