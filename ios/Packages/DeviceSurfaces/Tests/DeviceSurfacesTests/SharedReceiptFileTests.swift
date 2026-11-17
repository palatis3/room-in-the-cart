import Foundation
import XCTest
@testable import DeviceSurfaces

final class SharedReceiptFileTests: XCTestCase {
    func testFileBytesSurviveRelaunchAndOnlyOpeningScopeCanConsumeOrEraseThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("inbox.sqlite"), now = Date(), id = UUID()
        let first = try SharedCaptureInbox(url: url), bytes = Data(repeating: 42, count: 580_000)
        let receipt = try await first.stageReceipt(bytes, kind: .pdf, id: id, now: now)
        let retry = try await first.stageReceipt(bytes, kind: .pdf, id: id, now: now)
        XCTAssertEqual(retry, receipt)
        let recipes = try await first.pendingRecipes(now: now)
        XCTAssertTrue(recipes.isEmpty)
        let scope = SharedReceiptScope(origin: UUID(), persona: UUID()), other = SharedReceiptScope(origin: scope.origin, persona: UUID())
        let reopened = try SharedCaptureInbox(url: url)
        let pending = try await reopened.pendingReceiptFiles(scope: scope, now: now)
        let item = try XCTUnwrap(pending.first)
        let opened = try await reopened.openReceipt(item, scope: scope, now: now)
        XCTAssertEqual(opened, bytes)
        let hidden = try await first.pendingReceiptFiles(scope: other, now: now)
        XCTAssertTrue(hidden.isEmpty)
        do { _ = try await first.openReceipt(item, scope: other, now: now); XCTFail("A stale choice may not open another profile's bytes") }
        catch SurfaceError.stale {}
        let clips = try await reopened.receiptErasureCandidates(origin: scope.origin, now: now)
        XCTAssertEqual(clips.map(\.id), [id])
        do { try await reopened.retireReceipts(clips, origin: UUID(), now: now); XCTFail("Wrong origin may not erase an attachment") }
        catch SurfaceError.stale {}
        try await reopened.retireReceipts(clips, origin: scope.origin, now: now)
        try await reopened.retireReceipts(clips, origin: scope.origin, now: now)
        let redacted = try await reopened.stageReceipt(bytes, kind: .pdf, id: id, now: now)
        XCTAssertEqual(redacted.disposition, .discarded)
        let gone = try await reopened.pendingReceiptFiles(scope: scope, now: now)
        XCTAssertTrue(gone.isEmpty)
        do { _ = try await reopened.openReceipt(item, scope: scope, now: now); XCTFail("Erased file must have no readable chunks") }
        catch SurfaceError.stale {}
    }

    func testBudgetExpiryAndSuccessfulReceiptConsumptionReleaseStoredChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = try SharedCaptureInbox(url: directory.appendingPathComponent("inbox.sqlite"))
        let bytes = Data(repeating: 7, count: 10_000_000), now = Date(), first = UUID()
        let scope = SharedReceiptScope(origin: UUID(), persona: UUID())
        _ = try await inbox.stageReceipt(bytes, kind: .image, id: first, now: now)
        _ = try await inbox.stageReceipt(bytes, kind: .pdf, id: UUID(), now: now)
        do { _ = try await inbox.stageReceipt(Data([1]), kind: .text, id: UUID(), now: now); XCTFail("Combined byte budget") }
        catch SurfaceError.capacity {}
        let rows = try await inbox.pendingReceiptFiles(scope: scope, now: now), item = try XCTUnwrap(rows.first(where: { $0.id == first }))
        _ = try await inbox.openReceipt(item, scope: scope, now: now)
        try await inbox.finishReceipt(item, scope: scope, committed: true, now: now)
        let committed = try await inbox.stageReceipt(bytes, kind: .image, id: first, now: now)
        XCTAssertEqual(committed.disposition, .consumed)
        _ = try await inbox.stageReceipt(bytes, kind: .text, id: UUID(), now: now)
        let expired = try await inbox.pendingReceiptFiles(scope: scope, now: now.addingTimeInterval(SelectedTextInbox.lifetime))
        XCTAssertTrue(expired.isEmpty)
        _ = try await inbox.stageReceipt(bytes, kind: .image, id: UUID(), now: now.addingTimeInterval(SelectedTextInbox.lifetime))
    }
}
