import CoreDomain
import Foundation
import ImageIO
import SwiftUI

/// Only this type can supply image bytes to the shelf photo store. The original stays in memory.
struct PantryShelfImage: Sendable {
    let jpeg: Data
    let suggestedDay: MealDay?

    init(original: Data, capturedNow: Date? = nil, zone: TimeZone = .current) throws {
        jpeg = try ScanImageNormalizer.normalize(original)
        if let capturedNow {
            suggestedDay = try MealDay(date: capturedNow, timeZoneIdentifier: zone.identifier)
        } else {
            suggestedDay = Self.originalDay(original, zone: zone)
        }
    }

    private static func originalDay(_ data: Data, zone: TimeZone) -> MealDay? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let fields = stamp.prefix(10).split(separator: ":")
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]) else { return nil }
        return try? MealDay(year: year, month: month, day: day, timeZoneIdentifier: zone.identifier)
    }
}

struct PantryShelfPhoto: Codable {
    let id: UUID
    let captureDay: MealDay
    let jpeg: Data

    var dateLabel: String {
        guard let date = captureDay.date, let zone = TimeZone(identifier: captureDay.timeZoneIdentifier) else { return "" }
        var format = Date.FormatStyle(date: .long, time: .omitted)
        format.timeZone = zone
        return date.formatted(format)
    }
}

/// The one display copy is an atomic record. No independent thumbnail or Photos asset is created.
@MainActor final class PantryShelfPhotoStore: ObservableObject {
    private struct Record: Codable {
        let version: Int
        let origin: UUID
        let owner: String
        let location: InventoryLocation
        let photo: PantryShelfPhoto
    }

    private let folder: URL
    @Published private(set) var generation = 0

    init(folder: URL) { self.folder = folder }

    private func url(_ scope: PantryDigestScope, _ location: InventoryLocation) -> URL {
        folder.appendingPathComponent(scope.origin.uuidString, isDirectory: true)
            .appendingPathComponent(scope.owner, isDirectory: true)
            .appendingPathComponent(location.rawValue + ".plist")
    }

    func photo(at location: InventoryLocation, access: PantryDigestAccess) throws -> PantryShelfPhoto? {
        guard access.authorized() else { throw PantryDigestFailure.denied }
        let file = url(access.scope, location)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try PantryArchiveFiles.read(file, maximum: ScanLimits.maximumReferenceBytes + 8192)
        let record = try PropertyListDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.origin == access.scope.origin, record.owner == access.scope.owner,
              record.location == location else { throw PantryDigestFailure.invalid }
        try record.photo.captureDay.validate()
        try ScanImageNormalizer.validateReference(record.photo.jpeg)
        return record.photo
    }

    func save(_ image: PantryShelfImage, captureDay: MealDay, at location: InventoryLocation,
              replacing expected: UUID?, access: PantryDigestAccess) throws {
        guard try photo(at: location, access: access)?.id == expected else { throw PantryDigestFailure.changed }
        try captureDay.validate()
        let record = Record(version: 1, origin: access.scope.origin, owner: access.scope.owner, location: location,
                            photo: PantryShelfPhoto(id: UUID(), captureDay: captureDay, jpeg: image.jpeg))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        let file = url(access.scope, location)
        try PantryArchiveFiles.directory(file.deletingLastPathComponent(), create: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        generation += 1
    }

    func remove(_ id: UUID, at location: InventoryLocation, access: PantryDigestAccess) throws {
        guard try photo(at: location, access: access)?.id == id else { throw PantryDigestFailure.changed }
        try FileManager.default.removeItem(at: url(access.scope, location))
        generation += 1
    }

    func erase(origin: UUID) throws {
        let directory = folder.appendingPathComponent(origin.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        generation += 1
    }
}
