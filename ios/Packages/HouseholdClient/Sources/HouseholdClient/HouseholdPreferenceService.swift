import Foundation

public struct HouseholdPreferencePage<Settings: Codable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    public let v: Int
    public let householdId: UUID
    public let grantEpoch: Int
    public let revision: UUID?
    public let settings: Settings?
    public let canWrite: Bool

    func validate(in session: HouseholdDeviceSession) throws {
        guard v == 1, grantEpoch >= 0, householdId == session.householdID, revision != nil || settings == nil else {
            throw ClientError.invalidResponse
        }
    }
}

public struct HouseholdPreferenceWrite: Sendable {
    fileprivate let session: HouseholdDeviceSession
    fileprivate let bytes: Data
}

public struct HouseholdPreferenceSource: Encodable, Sendable {
    public enum Field: String, CaseIterable, Encodable, Sendable { case exclusions, dislikes, preferredBrands }
    public let shopId: UUID
    public let decisionId: UUID
    public let version: Int
    public let field: Field
    public let term: String
    public init(record: FamilyDecisionRecord, field: Field, term: String) {
        shopId = record.shopId
        decisionId = record.id
        version = record.version
        self.field = field
        self.term = term
    }
}

private struct PreferenceCommand<Settings: Codable>: Encodable {
    let clientKey: UUID
    let replayWindow: UUID
    let grantEpoch: Int
    let expectedRevision: UUID?
    let settings: Settings?
    let sourceDecision: HouseholdPreferenceSource?
    enum CodingKeys: CodingKey { case v, clientKey, replayWindow, grantEpoch, expectedRevision, settings, sourceDecision }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(1, forKey: .v)
        try box.encode(clientKey, forKey: .clientKey)
        try box.encode(replayWindow, forKey: .replayWindow)
        try box.encode(grantEpoch, forKey: .grantEpoch)
        try box.encode(expectedRevision, forKey: .expectedRevision)
        try box.encode(settings, forKey: .settings)
        try box.encodeIfPresent(sourceDecision, forKey: .sourceDecision)
    }
}

extension HouseholdService {
    public func preferenceSession(for bootstrap: HouseholdBootstrap) throws -> HouseholdDeviceSession {
        let session = try currentHouseholdDeviceSession()
        guard bootstrap.enrolled, bootstrap.grantId == nil, bootstrap.capabilities.contains("meal_preferences_read"),
              UUID(uuidString: bootstrap.household.id) == session.householdID,
              UUID(uuidString: bootstrap.memberId) == session.memberID else { throw ClientError.accessEnded }
        return session
    }

    public func preferencePage<S: Codable & Equatable & Sendable>(_ type: S.Type, session: HouseholdDeviceSession) async throws -> HouseholdPreferencePage<S> {
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        let result: HouseholdPreferencePage<S> = try await perform("meal-preferences", method: "GET", omitSelectedShop: true)
        try result.validate(in: session)
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        return result
    }

    public func preparePreferenceWrite<S>(_ settings: S?, reviewed: HouseholdPreferencePage<S>, session: HouseholdDeviceSession, sourceDecision: HouseholdPreferenceSource? = nil) async throws -> HouseholdPreferenceWrite {
        guard try currentHouseholdDeviceSession() == session, reviewed.canWrite else { throw ClientError.accessEnded }
        try reviewed.validate(in: session)
        let window: ReplayWindow = try await perform("replay-windows", method: "POST", body: Data("{}".utf8), omitSelectedShop: true)
        guard let id = UUID(uuidString: window.id), validHelperTimestamp(window.expiresAt) else { throw ClientError.invalidResponse }
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        let command = PreferenceCommand(clientKey: UUID(), replayWindow: id, grantEpoch: reviewed.grantEpoch,
                                        expectedRevision: reviewed.revision, settings: settings, sourceDecision: sourceDecision)
        return .init(session: session, bytes: try JSONEncoder().encode(command))
    }

    public func savePreferences<S: Codable & Equatable & Sendable>(_ intent: HouseholdPreferenceWrite, as type: S.Type) async throws -> HouseholdPreferencePage<S> {
        guard try currentHouseholdDeviceSession() == intent.session else { throw ClientError.accessEnded }
        let page: HouseholdPreferencePage<S> = try await perform("meal-preferences", method: "POST", body: intent.bytes, omitSelectedShop: true)
        try page.validate(in: intent.session)
        guard try currentHouseholdDeviceSession() == intent.session else { throw ClientError.accessEnded }
        return page
    }

    public func preferenceGrants(session: HouseholdDeviceSession) async throws -> HouseholdAdultGrants {
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        let result: HouseholdAdultGrants = try await perform("meal-preferences/grants", method: "GET", omitSelectedShop: true)
        try result.validate(for: session)
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        return result
    }
    public func setPreferenceRead(_ enabled: Bool, adult: HouseholdAdultGrants.Adult, session: HouseholdDeviceSession) async throws -> HouseholdAdultGrants {
        guard try currentHouseholdDeviceSession() == session, adult.id != session.memberID, adult.grantEpoch >= 0 else { throw ClientError.accessEnded }
        struct Change: Encodable { let v: Int; let memberId: UUID; let enabled: Bool; let expectedGrantEpoch: Int }
        let change = Change(v: 1, memberId: adult.id, enabled: enabled, expectedGrantEpoch: adult.grantEpoch)
        let result: HouseholdAdultGrants = try await perform("meal-preferences/grants", method: "POST", body: try JSONEncoder().encode(change), omitSelectedShop: true)
        try result.validate(for: session)
        guard try currentHouseholdDeviceSession() == session else { throw ClientError.accessEnded }
        return result
    }
}
