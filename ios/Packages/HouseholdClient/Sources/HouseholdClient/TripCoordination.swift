import Foundation

public enum TripSubstitutionChoice: String, Codable, CaseIterable, Sendable {
    case undecided, exact, alternative, skip
}

public struct TripSubstitution: Decodable, Equatable, Sendable {
    public let requestId: UUID
    public let originalItem: String
    public let own: Bool
    public let requestRevision, authorityEpoch, revision: Int
    public let choice: TripSubstitutionChoice
    public let alternative: String?

    func validate(requestID: UUID) throws {
        guard requestId == requestID, !originalItem.isEmpty, requestRevision > 0, authorityEpoch > 0,
              revision >= 0, choice == .undecided || revision > 0,
              choice == .alternative ? validTripLabel(alternative) : alternative == nil else { throw ClientError.invalidResponse }
    }
}

private func validTripLabel(_ text: String?) -> Bool {
    guard let text else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 240 && !text.contains("\0")
}

public struct SharedPickingPage: Decodable, Equatable, Sendable {
    public struct Member: Decodable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let label: String
    }
    public struct AvailableRow: Decodable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let label: String
        public let packs: Int
    }
    public struct Row: Decodable, Equatable, Identifiable, Sendable {
        public let id, safetyId: UUID
        public let label: String
        public let packs, picked, revision: Int
        public let claimedBy: UUID?
        public let claimedByLabel, lastActorLabel: String?
        public let undoOperationId: UUID?
        public var remaining: Int { packs - picked }
    }
    public let managed: Bool
    public let authorityEpoch, shopRevision: Int
    public let permissionId, recipientId: UUID?
    public let expiresAt: String?
    public var expiry: Date? { expiresAt.flatMap(HistoryValidation.date) }
    public let members: [Member]
    public let availableRows: [AvailableRow]
    public let rows: [Row]

    func validate(in session: AdultShopRequestSession, now: Date = Date()) throws {
        let member = session.device.memberID
        guard managed == session.shopper, authorityEpoch > 0, shopRevision > 0,
              managed || (members.isEmpty && availableRows.isEmpty && recipientId == member),
              Set(members.map(\.id)).count == members.count, members.allSatisfy({ !$0.label.isEmpty && $0.id != member }),
              Set(availableRows.map(\.id)).count == availableRows.count,
              availableRows.allSatisfy({ (1...10_000).contains($0.packs) && validTripLabel($0.label) }),
              Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ row in
                  (1...10_000).contains(row.packs) && (0...row.packs).contains(row.picked) && row.revision >= 0 &&
                  validTripLabel(row.label) && (row.claimedBy == nil) == (row.claimedByLabel == nil)
              }) else { throw ClientError.invalidResponse }
        if permissionId == nil {
            guard managed, recipientId == nil, rows.isEmpty, expiresAt == nil else { throw ClientError.invalidResponse }
        } else {
            guard recipientId != nil, let expiry else { throw ClientError.invalidResponse }
            guard expiry > now else { throw ClientError.service(status: 404, code: "expired", correlationID: nil, retryAfter: nil) }
        }
    }
}

public enum SharedPickAction: String, Codable, Sendable { case claim, pick, undo }

/// The retry contains only identifiers, versions and counts. Display text lives in the current authorized page.
public struct SharedPickIntent: Codable, Equatable, Identifiable, Sendable {
    public struct Operation: Codable, Equatable, Sendable {
        public let operationId, permissionId, actorId, deviceId, rowId: UUID
        public let expectedRevision: Int
        public let action: SharedPickAction
        public let packs: Int?
        public let undoOperationId: UUID?
    }

    public var id: UUID { operation.operationId }
    public let householdID, shopID: UUID
    public let expiresAt: Date
    public let operation: Operation

    public init(page: SharedPickingPage, row: SharedPickingPage.Row, in session: AdultShopRequestSession,
                action: SharedPickAction, packs: Int? = nil, now: Date = Date()) throws {
        try page.validate(in: session, now: now)
        guard session.picking, let permission = page.permissionId, let expiry = page.expiry, page.rows.contains(row) else { throw ClientError.accessEnded }
        switch action {
        case .claim: guard packs == nil, row.remaining > 0, row.claimedBy == nil else { throw ClientError.configuration }
        case .pick: guard let packs, packs > 0, packs <= row.remaining,
                         row.claimedBy == nil || row.claimedBy == session.device.memberID else { throw ClientError.configuration }
        case .undo: guard packs == nil, row.undoOperationId != nil else { throw ClientError.configuration }
        }
        householdID = session.device.householdID
        shopID = session.shopID
        expiresAt = expiry
        operation = .init(operationId: UUID(), permissionId: permission, actorId: session.device.memberID, deviceId: session.device.deviceID,
                          rowId: row.id, expectedRevision: row.revision, action: action, packs: packs,
                          undoOperationId: action == .undo ? row.undoOperationId : nil)
    }

    public func matches(_ session: AdultShopRequestSession, now: Date = Date()) -> Bool {
        session.picking && session.shopID == shopID && session.device.householdID == householdID &&
        session.device.deviceID == operation.deviceId && session.device.memberID == operation.actorId && expiresAt > now
    }
}

public struct SharedPickReceipt: Decodable, Equatable, Sendable {
    public let operationId, rowId: UUID
    public let revision, picked: Int
}

extension HouseholdService {
    public func coordinationDevice(for bootstrap: HouseholdBootstrap) throws -> HouseholdDeviceSession {
        let device = try currentHouseholdDeviceSession()
        guard bootstrap.enrolled, bootstrap.grantId == nil, ["organizer", "shopper", "contributor"].contains(bootstrap.role),
              UUID(uuidString: bootstrap.household.id) == device.householdID,
              UUID(uuidString: bootstrap.memberId) == device.memberID else { throw ClientError.accessEnded }
        return device
    }

    private func tripRequest<T: Decodable & Sendable>(_ path: String, in session: AdultShopRequestSession,
                                                      enabled: Bool, data: Data? = nil) async throws -> T {
        guard enabled, generation == session.generation, try currentHouseholdDeviceSession() == session.device else { throw ClientError.accessEnded }
        let shop = session.shopID.uuidString.lowercased()
        return try await perform("shops/" + shop + "/" + path, method: data == nil ? "GET" : "POST", body: data, reportingShopID: shop)
    }

    public func substitution(for requestID: UUID, in session: AdultShopRequestSession) async throws -> TripSubstitution {
        let result: TripSubstitution = try await tripRequest("requests/" + requestID.uuidString.lowercased() + "/substitution",
                                                             in: session, enabled: session.substitutions)
        try result.validate(requestID: requestID)
        guard session.shopper != result.own else { throw ClientError.invalidResponse }
        return result
    }

    public func saveSubstitution(_ choice: TripSubstitutionChoice, alternative: String?, reviewed: TripSubstitution,
                                 in session: AdultShopRequestSession, key: UUID) async throws -> TripSubstitution {
        struct Change: Encodable {
            let clientKey: UUID
            let expectedRevision, requestRevision, authorityEpoch: Int
            let choice: TripSubstitutionChoice
            let alternative: String?
        }
        guard !session.shopper, reviewed.own, choice != .undecided, choice == .alternative ? validTripLabel(alternative) : alternative == nil else { throw ClientError.configuration }
        let body = Change(clientKey: key, expectedRevision: reviewed.revision, requestRevision: reviewed.requestRevision,
                          authorityEpoch: reviewed.authorityEpoch, choice: choice, alternative: alternative)
        let result: TripSubstitution = try await tripRequest("requests/" + reviewed.requestId.uuidString.lowercased() + "/substitution",
                                                             in: session, enabled: session.substitutions, data: encoded(body))
        try result.validate(requestID: reviewed.requestId)
        guard result.own else { throw ClientError.invalidResponse }
        return result
    }

    public func sharedPicking(in session: AdultShopRequestSession) async throws -> SharedPickingPage {
        let result: SharedPickingPage = try await tripRequest("shared-picking", in: session, enabled: session.picking)
        try result.validate(in: session)
        return result
    }

    public func setSharedPicking(recipient: UUID?, lineIDs: Set<UUID>, until expiry: Date?, reviewed: SharedPickingPage,
                                 in session: AdultShopRequestSession, key: UUID) async throws -> SharedPickingPage {
        try reviewed.validate(in: session)
        guard reviewed.managed else { throw ClientError.accessEnded }
        if let recipient {
            guard let expiry, expiry > Date(), expiry.timeIntervalSinceNow <= 86400, !lineIDs.isEmpty,
                  reviewed.members.contains(where: { $0.id == recipient }), lineIDs.isSubset(of: Set(reviewed.availableRows.map(\.id))) else {
                throw ClientError.configuration
            }
        } else if expiry != nil || !lineIDs.isEmpty { throw ClientError.configuration }
        let body: [String: JSONValue] = ["clientKey": .string(key.uuidString.lowercased()),
            "expectedPermissionId": reviewed.permissionId.map { .string($0.uuidString.lowercased()) } ?? .null,
            "authorityEpoch": .integer(reviewed.authorityEpoch), "shopRevision": .integer(reviewed.shopRevision),
            "recipientId": recipient.map { .string($0.uuidString.lowercased()) } ?? .null,
            "lineIds": .array(lineIDs.map { $0.uuidString.lowercased() }.sorted().map(JSONValue.string)),
            "expiresAt": expiry.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null]
        let result: SharedPickingPage = try await tripRequest("shared-picking/permission", in: session, enabled: session.picking, data: encoded(body))
        try result.validate(in: session)
        return result
    }

    public func applySharedPick(_ intent: SharedPickIntent, in session: AdultShopRequestSession) async throws -> SharedPickReceipt {
        guard intent.matches(session) else { throw ClientError.accessEnded }
        let result: SharedPickReceipt = try await tripRequest("shared-picking/operations", in: session, enabled: session.picking, data: encoded(intent.operation))
        guard result.operationId == intent.id, result.rowId == intent.operation.rowId, result.revision > intent.operation.expectedRevision,
              (0...10_000).contains(result.picked) else { throw ClientError.invalidResponse }
        return result
    }
}
