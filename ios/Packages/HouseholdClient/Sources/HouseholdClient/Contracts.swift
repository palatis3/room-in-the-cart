import Foundation

public struct HouseholdBootstrap: Codable, Equatable, Sendable {
    public struct Household: Codable, Equatable, Sendable { public let id: String; public let label: String }
    public let household: Household
    public let memberId: String
    public let role: String
    public let grantId: String?
    public let shopId: String?
    public let enrolled: Bool
    public let selectionRequired: Bool?
    public let canSelectShop: Bool?
    public private(set) var canSetRequestQueue: Bool? = nil
    public private(set) var requestQueueGrant: UUID? = nil
    public private(set) var requestQueueUntil: String? = nil
    // Older clients use this wire flag to enable retries without a generation.
    public let queueConsent: Bool
    public var requestQueueEnabled: Bool {
        guard enrolled, canSetRequestQueue == true, capabilities.contains("request_queue_permission"),
              requestQueueGrant != nil, let requestQueueUntil,
              let expiry = HistoryValidation.date(requestQueueUntil) else { return false }
        return expiry > Date()
    }
    public let capabilities: [String]
}
public enum ConfirmedRequestPurchase: String, Codable, Sendable { case bought, notBought }
public struct OwnRequest: Codable, Equatable, Identifiable, Sendable {
    public private(set) var fromPreviousShop: Bool? = nil
    public private(set) var carriedForward: Bool? = nil
    public var id: String { requestId }
    public let requestId: String; public let shopId: String; public let revision: Int; public let originalItem: String
    public let ownQuantity: String?; public let authoredAt: String; public let receivedAt: String
    public let route: String; public let status: String; public let ownActionAllowed: Bool
    public let clarification: String?; public let followupTo: String?
    public let authorAlias: String?
    public private(set) var purchaseOutcome: ConfirmedRequestPurchase? = nil
    public private(set) var linkedLineId: UUID? = nil
}
public struct OwnRequestsPage: Codable, Equatable, Sendable { public let requests: [OwnRequest]; public let nextCursor: String? }
public struct ReplayWindow: Codable, Equatable, Sendable { public let id: String; public let expiresAt: String
    public init(id: String, expiresAt: String) { self.id = id; self.expiresAt = expiresAt }
}
public struct DeviceEnrollment: Codable, Sendable { public let deviceId: String; public let deviceToken: String }
public struct CommandBase: Codable, Equatable, Sendable {
    public let shopRevision: Int; public let authorityEpoch: Int; public let requestRevision: Int?
    public init(shopRevision: Int, authorityEpoch: Int, requestRevision: Int? = nil) {
        self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.requestRevision = requestRevision
    }
}
public struct OwnReceipt: Codable, Equatable, Sendable { public let operationId: String; public let kind: String; public let request: OwnRequest }
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v); case .string(let v): try c.encode(v)
        case .object(let v): try c.encode(v); case .array(let v): try c.encode(v) }
    }
}
public struct CommandEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let replayWindow: String; public let clientKey: String; public let shopId: String
    public let kind: String; public let base: CommandBase; public let body: [String: JSONValue]
    public init(replayWindow: String, clientKey: UUID = UUID(), shopId: String, kind: String,
                base: CommandBase, body: [String: JSONValue]) {
        v = 1; self.replayWindow = replayWindow; self.clientKey = clientKey.uuidString.lowercased()
        self.shopId = shopId; self.kind = kind; self.base = base; self.body = body
    }
}
/// Fixed encoded bytes and original replay window survive retries; a changed intent requires a new operation.
public struct PendingOperation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { clientKey }
    public let clientKey: String; public let householdID: String; public let memberID: String
    public let requestQueueGrant: UUID?
    public let sharedDemandBinding: SharedDemandOperationBinding?
    public let sharedTrackingBinding: SharedTrackingOperationBinding?
    public let deviceID: String; public let bytes: Data
    public func targetsShop(_ shopID: String?, includeCreation: Bool = false) -> Bool {
        guard let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: bytes) else { return false }
        if includeCreation, envelope.kind == "shop.create" { return true }
        guard let shopID else { return envelope.kind != "request.carry" && envelope.kind != "request.confirmPurchase" && !envelope.kind.hasPrefix("cookCopy.") && !envelope.kind.hasPrefix("pantry.") && envelope.kind != "mealRecovery.apply" }
        return envelope.shopId.caseInsensitiveCompare(shopID) == .orderedSame
    }
    public init(envelope: CommandEnvelope, householdID: String, memberID: String, deviceID: String, requestQueueGrant: UUID? = nil, sharedDemandBinding: SharedDemandOperationBinding? = nil, sharedTrackingBinding: SharedTrackingOperationBinding? = nil) throws {
        self.sharedDemandBinding = sharedDemandBinding
        self.sharedTrackingBinding = sharedTrackingBinding
        self.requestQueueGrant = requestQueueGrant
        clientKey = envelope.clientKey; self.householdID = householdID; self.memberID = memberID
        self.deviceID = deviceID; bytes = try encoded(envelope)
    }
}
public enum DeliveryState: Equatable, Sendable {
    case localDraft
    case waiting(operationID: String)
    case needsReview(operationID: String, code: String)
    case received(OwnReceipt)
    case accessEnded
}
public struct WorkspaceList: Codable, Equatable, Sendable {
    public struct Workspace: Codable, Equatable, Identifiable, Sendable {
        public var id: String { householdId }
        public let householdId: String; public let label: String; public let role: String
    }
    public let workspaces: [Workspace]
}
