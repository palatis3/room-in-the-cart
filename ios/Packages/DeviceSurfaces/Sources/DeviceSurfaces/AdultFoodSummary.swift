import Foundation

public enum AdultFoodSummaryKind: String, Codable, CaseIterable, Sendable {
    case useSoon, tonight
    public var widgetKind: String { "RoomInTheCartAdult-" + rawValue }
}

/// Widget-only data. Scope and generation are random tokens, never account or store identifiers.
public struct AdultFoodSummaryProjection: Codable, Equatable, Sendable {
    public let kind: AdultFoodSummaryKind
    public let scope: UUID
    public let generation: UUID
    public let writtenAt: Date
    public let expiresAt: Date
    public let timeZoneID: String
    public let count: Int
    public let reviewedTitle: String?
    public let plannedDinner: Bool?
    public let route: RouteHandle
    public static let maximumAge: TimeInterval = 6 * 60 * 60

    public init(kind: AdultFoodSummaryKind, scope: UUID, now: Date, zone: TimeZone,
                count: Int, reviewedTitle: String? = nil, plannedDinner: Bool = false) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let day = calendar.dateInterval(of: .day, for: now) else { throw SurfaceError.invalidCivilTime }
        self.kind = kind; self.scope = scope; self.generation = UUID()
        self.writtenAt = now; self.expiresAt = min(now.addingTimeInterval(Self.maximumAge), day.end)
        self.timeZoneID = zone.identifier; self.count = count; self.reviewedTitle = reviewedTitle
        self.plannedDinner = plannedDinner ? true : nil
        self.route = .random()
        try validate()
    }

    private func validate() throws {
        guard validDate(writtenAt), validDate(expiresAt), let zone = TimeZone(identifier: timeZoneID),
              (0...1_000_000).contains(count), expiresAt > writtenAt,
              expiresAt.timeIntervalSince(writtenAt) <= Self.maximumAge else { throw SurfaceError.invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let day = calendar.dateInterval(of: .day, for: writtenAt), expiresAt <= day.end else { throw SurfaceError.invalid }
        if plannedDinner == true {
            guard kind == .tonight, count > 0, count == 1 || reviewedTitle == nil else { throw SurfaceError.invalid }
        }
        if let title = reviewedTitle {
            guard kind == .tonight, count > 0, !title.isEmpty, title.count <= 64, title.utf8.count <= 256,
                  title.rangeOfCharacter(from: .controlCharacters) == nil else { throw SurfaceError.invalid }
        }
    }
    public func isFresh(at now: Date, zone: TimeZone) -> Bool {
        zone.identifier == timeZoneID && now >= writtenAt && now < expiresAt
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2048, let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys,
              Set(keys).isSubset(of: ["kind","scope","generation","writtenAt","expiresAt","timeZoneID","count","reviewedTitle","plannedDinner","route"]) else {
            throw SurfaceError.corrupt
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
}

public struct AdultFoodSummaryFile: Sendable {
    public let url: URL
    public let kind: AdultFoodSummaryKind
    public init(directory: URL, kind: AdultFoodSummaryKind) throws {
        guard directory.isFileURL else { throw SurfaceError.unconfigured }
        self.kind = kind
        url = directory.appendingPathComponent("adult-food-" + kind.rawValue + "-v1.json")
    }
    public func read() throws -> AdultFoodSummaryProjection {
        let value = try AdultFoodSummaryProjection.decode(readRegularFile(at: url, maximumBytes: 2048))
        guard value.kind == kind else { throw SurfaceError.invalid }
        return value
    }
    public func publish(_ value: AdultFoodSummaryProjection) throws {
        let data = try canonical(value)
        guard try AdultFoodSummaryProjection.decode(data).kind == kind else { throw SurfaceError.invalid }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
    public func clear() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
}
