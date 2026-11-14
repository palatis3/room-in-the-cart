import Foundation

public enum SurfaceError: Error, Equatable, Sendable {
    case unconfigured, invalid, unsupported, corrupt, unavailable, capacity, changedReplay, stale, cancelled, busy
    case invalidCivilTime, ambiguousCivilTime, quietHours, expired, permissionRequired
}
public enum SurfaceLanguage: String, Codable, Sendable { case english, spanish }
public enum CaptureDestination: String, Codable, Sendable { case capture, shoppingList, ownRequest }

func validDate(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && (-62_135_596_800 ... 253_402_300_799).contains(date.timeIntervalSince1970)
}
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// A handle is only a locator. It must never be interpreted as a grant.
public struct RouteHandle: Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        guard value.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SurfaceError.invalid }
        rawValue = value
    }
    public static func random() -> RouteHandle { try! RouteHandle(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct SurfaceURLCodec: Sendable {
    public let scheme: String
    public init(scheme: String?) throws {
        guard let scheme, (3...48).contains(scheme.count), scheme.first?.isASCII == true,
              scheme.first?.isLetter == true, scheme.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !["http", "https", "file", "javascript", "data"].contains(scheme) else { throw SurfaceError.unconfigured }
        self.scheme = scheme
    }
    public func url(handle: RouteHandle?) -> URL {
        var c = URLComponents(); c.scheme = scheme; c.host = "surface"; c.path = handle == nil ? "/capture" : "/open"
        if let handle { c.queryItems = [URLQueryItem(name: "handle", value: handle.rawValue)] }
        return c.url!
    }
    public func parse(_ url: URL) throws -> RouteHandle? {
        guard url.absoluteString.utf8.count <= 256, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == scheme,
              c.host == "surface", c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { throw SurfaceError.invalid }
        if c.path == "/capture", c.query == nil, url == self.url(handle: nil) { return nil }
        guard c.path == "/open", let items = c.queryItems, items.count == 1, items[0].name == "handle", let value = items[0].value else { throw SurfaceError.invalid }
        let handle = try RouteHandle(value)
        guard url == self.url(handle: handle) else { throw SurfaceError.invalid }
        return handle
    }
}

/// Safe even when stale, rendered on a locked device, or read by another group process.
/// No food names, financial values, counts, member identities, or arbitrary display text.
public struct WidgetProjection: Codable, Equatable, Sendable {
    static let maximumBytes = 4096
    public let version: Int
    public let generation: UUID
    public let writtenAt: Date
    public let routeHandle: RouteHandle?
    public let destination: CaptureDestination
    public init(generation: UUID = UUID(), writtenAt: Date, routeHandle: RouteHandle?, destination: CaptureDestination) throws {
        guard validDate(writtenAt) else { throw SurfaceError.invalid }
        version = 1; self.generation = generation; self.writtenAt = writtenAt; self.routeHandle = routeHandle; self.destination = destination
    }
    public static func decode(_ data: Data) throws -> WidgetProjection {
        guard data.count <= maximumBytes, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "generation", "writtenAt", "routeHandle", "destination"]) else { throw SurfaceError.corrupt }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, validDate(result.writtenAt) else { throw SurfaceError.unsupported }
        return result
    }
}

public enum SurfacePersona: String, Codable, Sendable { case localAdult, adult, contributor, helper }
public struct PrivateRoute: Codable, Equatable, Sendable {
    public let handle: RouteHandle
    public let personaID: UUID
    public let targetID: UUID
    public let generation: UUID
    public let destination: CaptureDestination
    public let expiresAt: Date
    public init(handle: RouteHandle, personaID: UUID, targetID: UUID, generation: UUID, destination: CaptureDestination, expiresAt: Date) throws {
        guard validDate(expiresAt) else { throw SurfaceError.invalid }
        self.handle = handle; self.personaID = personaID; self.targetID = targetID; self.generation = generation; self.destination = destination; self.expiresAt = expiresAt
    }
}
/// Construct in the containing app after current session/target checks; never decode from a URL or shared container.
public struct RouteAuthorization: Sendable {
    public let personaID: UUID
    public let role: SurfacePersona
    public let generation: UUID
    public let unlocked: Bool
    public let permittedTargetIDs: Set<UUID>
    public init(personaID: UUID, role: SurfacePersona, generation: UUID, unlocked: Bool, permittedTargetIDs: Set<UUID>) {
        self.personaID = personaID; self.role = role; self.generation = generation; self.unlocked = unlocked; self.permittedTargetIDs = permittedTargetIDs
    }
}
public enum SurfaceRouter {
    public static func resolve(_ route: PrivateRoute, handle: RouteHandle, authorization: RouteAuthorization, now: Date) -> CaptureDestination? {
        guard validDate(now), validDate(route.expiresAt), now < route.expiresAt, handle == route.handle,
              authorization.personaID == route.personaID, authorization.generation == route.generation,
              authorization.permittedTargetIDs.contains(route.targetID) else { return nil }
        switch authorization.role {
        case .contributor: return route.destination == .ownRequest ? .ownRequest : nil
        case .helper: return nil
        case .adult, .localAdult: return authorization.unlocked && route.destination != .ownRequest ? route.destination : nil
        }
    }
}

public struct SurfaceConfiguration: Sendable {
    public let inboxGroup: String
    public let widgetGroup: String
    public let urls: SurfaceURLCodec
    public init(inboxGroup: String?, widgetGroup: String?, urlScheme: String?) throws {
        func group(_ value: String?) throws -> String {
            guard let value, value.hasPrefix("group."), value.count <= 150, value.count > 6,
                  value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }) else { throw SurfaceError.unconfigured }
            return value
        }
        self.inboxGroup = try group(inboxGroup); self.widgetGroup = try group(widgetGroup)
        guard self.inboxGroup != self.widgetGroup else { throw SurfaceError.unconfigured }
        urls = try SurfaceURLCodec(scheme: urlScheme)
    }
}
