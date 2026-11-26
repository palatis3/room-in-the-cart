import CoreDomain
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor
final class PackageRowPhotoTests: XCTestCase {
    private var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func owner(_ actor: UUID = UUID(), subject: String? = nil) -> PackageRowPhoto.Owner {
        .init(.init(actorID: actor, subject: subject, householdID: nil, memberID: nil, role: nil))
    }

    private func record(_ target: CaptureTarget, photo: Bool = true) -> SourceMediaRecord {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 320), format: format)
            .jpegData(withCompressionQuality: 0.85) { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
            }
        return .init(id: UUID(), target: target, originalText: "LECHE", reviewedLabel: "Leche", imageJPEG: photo ? data : nil,
                     barcode: nil, receiptLines: [], capturedAt: Date())
    }

    func testPrivateOptInReopensForSameActorShopAndWorkspaceOnly() async throws {
        let directory = root
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureMediaStore(directory: directory)
        let actorID = UUID(), first = owner(actorID), other = owner(actorID, subject: "another adult")
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .packageReference)
        let source = record(target)
        _ = try await store.save(source) { true }
        let initial = try await store.packagePhotos(target: target, owner: first) { true }
        XCTAssertTrue(initial.isEmpty)
        try await store.setPackagePhoto(source.reference, target: target, owner: first, cue: "  Tapa azul  ") { true }

        let reopened = CaptureMediaStore(directory: directory)
        let rows = try await reopened.packagePhotos(target: target, owner: first) { true }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.target.objectID, target.objectID)
        XCTAssertEqual(row.cue, "Tapa azul")
        XCTAssertEqual(row.source, source.reference)
        XCTAssertTrue(PackageRowPhoto.validThumbnail(row.thumbnail))
        XCTAssertLessThanOrEqual(row.thumbnail.count, PackageRowPhoto.maximumBytes)
        let otherAdult = try await reopened.packagePhotos(target: target, owner: other) { true }
        XCTAssertTrue(otherAdult.isEmpty)
        for wrong in [CaptureTarget(workspaceID: UUID(), containerID: target.containerID, objectID: target.objectID, revision: 1, kind: .packageReference),
                      CaptureTarget(workspaceID: target.workspaceID, containerID: UUID(), objectID: target.objectID, revision: 1, kind: .packageReference)] {
            let hidden = try await reopened.packagePhotos(target: wrong, owner: first) { true }
            XCTAssertTrue(hidden.isEmpty)
        }
        do {
            _ = try await reopened.packagePhotos(target: target, owner: first) { false }
            XCTFail("Locked read")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let alternate = record(target)
        _ = try await reopened.save(alternate) { true }
        var reads = 0
        do {
            try await reopened.setPackagePhoto(alternate.reference, target: target, owner: first, cue: "New container") {
                reads += 1
                return reads < 5 // Revoke after the guarded write.
            }
            XCTFail("Revoked display choice")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let restored = try await reopened.packagePhotos(target: target, owner: first) { true }
        XCTAssertEqual(restored, rows)
        let archive = try await reopened.archiveListing(workspaceID: target.workspaceID) { true }
        XCTAssertEqual(Set(archive.records.map(\.id)), [source.id, alternate.id])
        XCTAssertEqual(archive.unavailableCount, 0)
    }

    func testLaterTripConfirmsOneExactPhotoAndClearsStaleOrDeletedAssociations() async throws {
        let directory = root
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureMediaStore(directory: directory), adult = owner(), workspaceID = UUID()
        var old = ShoppingLedger(), next = ShoppingLedger()
        let oldID = try old.addManualLine(name: "Milk", quantity: nil, notes: "Blue cap")
        let wanted = try next.addManualLine(name: "Milk", quantity: nil, notes: "One liter")
        let other = try next.addManualLine(name: "Milk", quantity: nil, notes: "Red cap")
        let workspace = LedgerWorkspace(shops: [old, next], selectedShopID: next.id)
        let a = CaptureTarget(workspaceID: workspaceID, containerID: old.id, objectID: oldID, revision: 0, kind: .packageReference)
        let b = CaptureTarget(workspaceID: workspaceID, containerID: next.id, objectID: wanted, revision: 0, kind: .packageReference)
        let source = record(a)
        _ = try await store.save(source) { true }
        try await store.setPackagePhoto(source.reference, target: a, owner: adult, cue: "Azul") { true }
        let choices = try await store.earlierPackagePhotos(for: b, owner: adult) { true }
        let photo = try XCTUnwrap(choices.first)
        let link = PackageRowPhoto.Destination(id: UUID(), target: b,
            originalProduct: try XCTUnwrap(PackageRowPhoto.productSignature(a, in: workspace)),
            destinationProduct: try XCTUnwrap(PackageRowPhoto.productSignature(b, in: workspace)))
        let unconfirmed = try await store.packagePhotos(target: b, owner: adult) { true }
        XCTAssertTrue(unconfirmed.isEmpty)
        var permitReads = 0
        do {
            try await store.reusePackagePhoto(photo, destination: link, owner: adult) {
                permitReads += 1
                return permitReads == 1
            }
            XCTFail("An interrupted confirmation must leave the destination unchanged")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let interrupted = try await store.packagePhotos(target: b, owner: adult) { true }
        XCTAssertTrue(interrupted.isEmpty)
        try await store.reusePackagePhoto(photo, destination: link, owner: adult) { true }
        let fresh = CaptureMediaStore(directory: directory)
        let rows = try await fresh.packagePhotos(target: b, owner: adult) { true }
        let reused = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.map(\.target.objectID), [wanted])
        XCTAssertNotEqual(reused.target.objectID, other)
        XCTAssertEqual(reused.source, photo.source)
        XCTAssertEqual(CurrentStopSourceCaption.photoCue(for: photo, matched: false), .photo)
        XCTAssertEqual(CurrentStopSourceCaption.photoCue(for: reused, matched: false), .earlierPhoto)
        XCTAssertEqual(CurrentStopSourceCaption.photoCue(for: reused, matched: true), .matchedEarlierPhoto)
        XCTAssertTrue(reused.matchesCurrentGroceries(in: workspace))
        var changed = workspace
        try changed.shops[1].updateLine(lineID: wanted, name: "Milk", notes: "Red cap", aisle: "")
        XCTAssertFalse(reused.matchesCurrentGroceries(in: changed))
        let wrongActor = try await fresh.packagePhotos(target: b, owner: owner()) { true }
        XCTAssertTrue(wrongActor.isEmpty)
        let replacement = record(b)
        _ = try await fresh.save(replacement) { true }
        var checks = 0
        do {
            try await fresh.setPackagePhoto(replacement.reference, target: b, owner: adult, cue: "Otra") {
                checks += 1
                return checks < 5
            }
            XCTFail("Revoked change must restore the previously linked cue")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let restored = try await fresh.packagePhotos(target: b, owner: adult) { true }
        XCTAssertEqual(restored.first?.association, link)
        try await fresh.removeReusedPackagePhoto(reused, target: b, owner: adult) { true }
        let removed = try await fresh.packagePhotos(target: b, owner: adult) { true }
        XCTAssertTrue(removed.isEmpty)
        try await fresh.reusePackagePhoto(photo, destination: link, owner: adult) { true }
        try await fresh.setPackagePhoto(photo.source, target: a, owner: adult, cue: nil) { true }
        let hidden = try await fresh.packagePhotos(target: b, owner: adult) { true }
        XCTAssertTrue(hidden.isEmpty)
        try await fresh.setPackagePhoto(photo.source, target: a, owner: adult, cue: "New cue") { true }
        do {
            try await fresh.reusePackagePhoto(photo, destination: link, owner: adult) { true }
            XCTFail("Old preview cannot opt in to a corrected source")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let latest = try await fresh.earlierPackagePhotos(for: b, owner: adult) { true }
        try await fresh.reusePackagePhoto(try XCTUnwrap(latest.first), destination: link, owner: adult) { true }
        try await fresh.remove(photo.source, target: a) { true }
        let erased = try await fresh.packagePhotos(target: b, owner: adult) { true }
        XCTAssertTrue(erased.isEmpty)
    }

    func testReplacementHideAndDeletionRemoveOnlySelectedEvidence() async throws {
        let directory = root
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureMediaStore(directory: directory), local = owner()
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .packageReference)
        let a = record(target), b = record(target), typed = record(target, photo: false)
        for item in [a, b, typed] { _ = try await store.save(item) { true } }
        do {
            try await store.setPackagePhoto(typed.reference, target: target, owner: local, cue: "Azul") { true }
            XCTFail("Typed reference cannot become a photo")
        } catch { XCTAssertEqual(error as? ScanFailure, .invalidImage) }
        for item in [a, b] { try await store.setPackagePhoto(item.reference, target: target, owner: local, cue: " Azul ") { true } }
        // An old detail screen cannot hide a newer selection of a different source.
        try await store.setPackagePhoto(a.reference, target: target, owner: local, cue: nil) { true }
        let replaced = try await store.packagePhotos(target: target, owner: local) { true }
        XCTAssertEqual(replaced.map(\.source), [b.reference])
        try await store.setPackagePhoto(b.reference, target: target, owner: local, cue: nil) { true }
        let hidden = try await store.packagePhotos(target: target, owner: local) { true }
        XCTAssertTrue(hidden.isEmpty)
        let retained = try await store.read(b.reference, target: target) { true }
        XCTAssertEqual(retained, b)
        try await store.setPackagePhoto(b.reference, target: target, owner: local, cue: "Blue cap") { true }
        try await store.remove(b.reference, target: target) { true }
        let removed = try await CaptureMediaStore(directory: directory).packagePhotos(target: target, owner: local) { true }
        XCTAssertTrue(removed.isEmpty)
        try await store.setPackagePhoto(a.reference, target: target, owner: local, cue: "Different carton") { true }
        try await store.eraseWorkspace(target.workspaceID)
        let cleared = try await store.packagePhotos(target: target, owner: local) { true }
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertThrowsError(try PackageRowPhoto.normalizedCue(" "))
        XCTAssertThrowsError(try PackageRowPhoto.normalizedCue(String(repeating: "x", count: 101)))
    }
}
