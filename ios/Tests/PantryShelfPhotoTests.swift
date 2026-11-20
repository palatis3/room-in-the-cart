import CoreDomain
import CoreGraphics
import Foundation
import ImageIO
import LocalStore
import UniformTypeIdentifiers
import XCTest
@testable import RoomInTheCart

@MainActor final class PantryShelfPhotoTests: XCTestCase {
    func testImportedDateSurvivesMetadataRemovalAndOpeningOnAnotherTrip() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PantryShelfPhotoStore(folder: root)
        let access = authorization()
        let source = try original(exifDate: "2025:09:04 13:16:35")
        let chosen = try PantryShelfImage(original: source)
        let day = try XCTUnwrap(chosen.suggestedDay)
        XCTAssertEqual(day.iso8601, "2025-09-04")
        try store.save(chosen, captureDay: day, at: .fridge, replacing: nil, access: access)
        let reopened = PantryShelfPhotoStore(folder: root)
        let loaded = try XCTUnwrap(reopened.photo(at: .fridge, access: access))
        XCTAssertEqual(loaded.captureDay, day)
        XCTAssertEqual(loaded.jpeg, chosen.jpeg)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(loaded.jpeg as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [CFString: Any])
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertNil((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(try reopened.photo(at: .cupboard, access: access))
    }

    func testCanceledInvalidOrConflictingReplacementPreservesCurrentPhotoAndOldBytesAreRetired() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PantryShelfPhotoStore(folder: root)
        let access = authorization()
        let old = try PantryShelfImage(original: original(exifDate: nil, gray: 0))
        let next = try PantryShelfImage(original: original(exifDate: nil, gray: 1))
        XCTAssertNil(old.suggestedDay)
        let day = try MealDay(year: 2025, month: 2, day: 9, timeZoneIdentifier: "UTC")
        try store.save(old, captureDay: day, at: .fridge, replacing: nil, access: access)
        let before = try XCTUnwrap(store.photo(at: .fridge, access: access))
        // Choosing a replacement only prepares bytes. The user can still cancel the picker or the date review.
        XCTAssertEqual(try store.photo(at: .fridge, access: access)?.id, before.id)
        XCTAssertThrowsError(try PantryShelfImage(original: Data("unreadable".utf8)))
        XCTAssertThrowsError(try store.save(next, captureDay: day, at: .fridge, replacing: UUID(), access: access))
        XCTAssertEqual(try store.photo(at: .fridge, access: access)?.jpeg, old.jpeg)
        try store.save(next, captureDay: day, at: .fridge, replacing: before.id, access: access)
        let after = try XCTUnwrap(store.photo(at: .fridge, access: access))
        XCTAssertNotEqual(after.id, before.id)
        XCTAssertNotEqual(before.jpeg, after.jpeg)
        XCTAssertThrowsError(try store.remove(before.id, at: .fridge, access: access))
        let files = try regularFiles(in: root)
        XCTAssertEqual(files.count, 1)
        let record = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertNil(record.range(of: before.jpeg))
        XCTAssertNotNil(record.range(of: after.jpeg))
        try store.remove(after.id, at: .fridge, access: access)
        XCTAssertTrue(try regularFiles(in: root).isEmpty)
    }

    func testRevokedAccessAndWorkspaceSwitchProtectPendingOperationsAndCleanupIsScoped() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PantryShelfPhotoStore(folder: root)
        let origin = UUID(), actor = UUID()
        var allowed = true
        let first = authorization(origin: origin, actor: actor, subject: "A", authorize: { allowed })
        let differentAccount = authorization(origin: origin, actor: actor, subject: "B")
        let differentPantry = authorization(actor: actor, subject: "A")
        let image = try PantryShelfImage(original: original(exifDate: nil), capturedNow: Date(timeIntervalSince1970: 1_720_000_000))
        let day = try XCTUnwrap(image.suggestedDay)
        try store.save(image, captureDay: day, at: .freezer, replacing: nil, access: first)
        let initialID = try XCTUnwrap(store.photo(at: .freezer, access: first)?.id)
        XCTAssertNil(try store.photo(at: .freezer, access: differentAccount))
        XCTAssertNil(try store.photo(at: .freezer, access: differentPantry))
        try store.save(image, captureDay: day, at: .freezer, replacing: nil, access: differentPantry)
        try store.save(image, captureDay: day, at: .cupboard, replacing: nil, access: differentAccount)
        allowed = false
        XCTAssertThrowsError(try store.photo(at: .freezer, access: first))
        XCTAssertThrowsError(try store.save(image, captureDay: day, at: .freezer, replacing: initialID, access: first))
        XCTAssertThrowsError(try store.remove(initialID, at: .freezer, access: first))
        try store.erase(origin: origin)
        try store.erase(origin: origin)
        allowed = true
        XCTAssertNil(try store.photo(at: .freezer, access: first))
        XCTAssertNil(try store.photo(at: .cupboard, access: differentAccount))
        XCTAssertNotNil(try store.photo(at: .freezer, access: differentPantry))
        XCTAssertEqual(try regularFiles(in: root).count, 1)
    }

    func testPantryErasureHookPreservesPhotosForFoodDeletionsAndRetiresAllWhenThePantryIsDeleted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try ComparisonStore(url: root.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        let digest = PantryDigestStore(folder: root.appendingPathComponent("digests"), scheduler: PantryDigestNotifications(isolated: true))
        let access = authorization(origin: db.workspaceID)
        let picture = try PantryShelfImage(original: original(exifDate: "2025:07:09 12:00:00"))
        let day = try XCTUnwrap(picture.suggestedDay)
        try digest.shelfPhotos.save(picture, captureDay: day, at: .cupboard, replacing: nil, access: access)
        try await digest.erase(origin: db.workspaceID, whole: false, inventory: db)
        XCTAssertNotNil(try digest.shelfPhotos.photo(at: .cupboard, access: access))
        try await digest.erase(origin: db.workspaceID, whole: true, inventory: db)
        XCTAssertNil(try digest.shelfPhotos.photo(at: .cupboard, access: access))
        try await db.close()
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func authorization(origin: UUID = UUID(), actor: UUID = UUID(), subject: String? = nil,
                               authorize: @escaping @MainActor () -> Bool = { true }) -> PantryDigestAccess {
        let identity = CapturePrivateIdentity(actorID: actor, subject: subject, householdID: nil, memberID: nil, role: nil)
        return PantryDigestAccess(scope: .init(origin: origin, identity: identity), authorized: authorize)
    }

    private func regularFiles(in root: URL) throws -> [URL] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        return try walker.compactMap { item in
            guard let url = item as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    private func original(exifDate: String?, gray: CGFloat = 0.5) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let output = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3,
                                                                          kCGImagePropertyGPSLongitude: 45.6]]
        if let exifDate { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate] }
        CGImageDestinationAddImage(encoder, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        return output as Data
    }
}
