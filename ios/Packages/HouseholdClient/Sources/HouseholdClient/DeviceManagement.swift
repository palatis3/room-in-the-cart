import Foundation

public struct ManagedHouseholdDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { deviceId }
    public let deviceId: String
    public let memberId: String
    public let memberAlias: String
    public let memberKind: String
    public let createdAt: String
    public let revokedAt: String?
    public let isCurrentDevice: Bool
    public func validate() throws {
        guard UUID(uuidString: deviceId) != nil, UUID(uuidString: memberId) != nil,
              !memberAlias.isEmpty, memberAlias.count <= 80, ["adult", "child"].contains(memberKind),
              deviceDate(createdAt) != nil, revokedAt.map({ deviceDate($0) != nil }) ?? true else { throw ClientError.invalidResponse }
    }
}
public struct HouseholdDevicePage: Codable, Equatable, Sendable {
    public let scope: String
    public let devices: [ManagedHouseholdDevice]
    public let nextCursor: String?
    public func validate(cursor: String? = nil) throws {
        let ids = devices.map(\.id)
        guard ["household", "guardian_children"].contains(scope), ids.count <= 100, Set(ids).count == ids.count,
              !ids.contains(where: { $0 == cursor }), nextCursor == nil || (nextCursor == ids.last && nextCursor != cursor),
              scope != "guardian_children" || devices.allSatisfy({ $0.memberKind == "child" && !$0.isCurrentDevice }),
              devices.filter(\.isCurrentDevice).count <= 1 else { throw ClientError.invalidResponse }
        try devices.forEach { try $0.validate() }
    }
}
public struct DeviceRevocationReceipt: Codable, Equatable, Sendable {
    public let deviceId: String
    public let memberId: String
    public let revoked: Bool
    public let revokedAt: String
}

/// A naturally idempotent operation: the immutable enrollment ID is the retry key.
/// New enrollment always creates a different ID. Retrying cannot revoke a replacement.
public struct DeviceRevocationIntent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { targetDeviceID }
    public let subject: String
    public let householdID: String
    public let memberID: String
    public let deviceID: String
    var binding: GuardianActorBinding { .init(subject: subject, householdID: householdID, memberID: memberID, deviceID: deviceID) }
    public let targetDeviceID: String
    public let targetMemberID: String
    public let bytes: Data
    init(binding: GuardianActorBinding, device: ManagedHouseholdDevice) throws {
        try device.validate()
        guard !device.isCurrentDevice, device.revokedAt == nil, device.deviceId != binding.deviceID else { throw ClientError.configuration }
        subject = binding.subject; householdID = binding.householdID; memberID = binding.memberID; deviceID = binding.deviceID
        targetDeviceID = device.deviceId; targetMemberID = device.memberId
        struct Input: Encodable { let memberId: String }
        bytes = try encoded(Input(memberId: targetMemberID)); try validate()
    }
    public func validate() throws {
        guard !binding.subject.isEmpty, [binding.householdID, binding.memberID, binding.deviceID, targetDeviceID, targetMemberID].allSatisfy({ UUID(uuidString: $0) != nil }),
              targetDeviceID != binding.deviceID else { throw ClientError.configuration }
        struct Input: Codable { let memberId: String }
        let input = try JSONDecoder().decode(Input.self, from: bytes)
        guard input.memberId == targetMemberID, bytes == (try encoded(input)) else { throw ClientError.configuration }
    }
}

extension HouseholdService {
    public func managedDevices(cursor: String? = nil) async throws -> HouseholdDevicePage {
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        let value: HouseholdDevicePage = try await guardianRequest(path: "devices", query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
        try value.validate(cursor: cursor)
        let actor = try guardianContext()
        guard value.devices.allSatisfy({ $0.isCurrentDevice == ($0.deviceId == actor.deviceID) && (!$0.isCurrentDevice || $0.memberId == actor.memberID) }) else { throw ClientError.invalidResponse }
        return value
    }
    public func prepareDeviceRevocation(_ device: ManagedHouseholdDevice) async throws -> DeviceRevocationIntent {
        let binding = try guardianContext()
        try await guardianAuthorize(binding: binding)
        return try .init(binding: binding, device: device)
    }
    public func authorizeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws {
        try intent.validate(); try await guardianAuthorize(binding: intent.binding)
    }
    public func executeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws -> DeviceRevocationReceipt {
        try intent.validate()
        let value: DeviceRevocationReceipt = try await guardianRequest(binding: intent.binding,
            path: "devices/\(intent.targetDeviceID)/revocation", method: "POST", body: intent.bytes)
        guard value.revoked, value.deviceId == intent.targetDeviceID, value.memberId == intent.targetMemberID,
              deviceDate(value.revokedAt) != nil else { throw ClientError.invalidResponse }
        return value
    }
}

public actor DeviceRevocationStore {
    private let url: URL
    private var generation = UUID()
    public init(url: URL) { self.url = url }
    public func epoch() -> UUID { generation }
    public func read() throws -> DeviceRevocationIntent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let intent = try JSONDecoder().decode(DeviceRevocationIntent.self, from: Data(contentsOf: url)); try intent.validate(); return intent
    }
    public func save(_ intent: DeviceRevocationIntent, epoch: UUID) throws {
        guard epoch == generation else { throw ClientError.cancelled }; try intent.validate()
        if let old = try read() { guard old == intent else { throw ClientError.configuration }; return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try encoded(intent).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoded(intent).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try file.setResourceValues(values)
    }
    public func remove(_ intent: DeviceRevocationIntent, epoch: UUID) throws {
        guard epoch == generation else { throw ClientError.cancelled }
        guard try read() == intent else { throw ClientError.configuration }
        try FileManager.default.removeItem(at: url)
    }
    public func purge() throws {
        generation = UUID()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func purge(householdID: String, subject: String) throws {
        generation = UUID()
        guard let intent = try read(), intent.householdID == householdID, intent.subject == subject else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private func deviceDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]; return parser.date(from: value)
}
