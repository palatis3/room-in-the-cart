import Foundation

public enum FamilyDecisionKind: String, Codable, CaseIterable, Sendable { case approval, exclusion, preference }
public enum FamilyDecisionScope: String, Codable, Sendable { case oneShop = "one_shop", lasting }

public struct FamilyDecisionInput: Codable, Equatable, Sendable {
    public var kind: FamilyDecisionKind
    public var dish: String?
    public var product: String?
    public var occasion: String?
    public var decision: String
    public var outcome: String?
    public init(kind: FamilyDecisionKind, dish: String?, product: String?, occasion: String?, decision: String, outcome: String?) {
        self.kind = kind; self.dish = dish; self.product = product; self.occasion = occasion
        self.decision = decision; self.outcome = outcome
    }
    public func validate() throws {
        let fields = [dish, product, occasion].compactMap { $0 }
        guard !fields.isEmpty, fields.allSatisfy({ validDecisionText($0, limit: 120) }),
              validDecisionText(decision, limit: 500), outcome.map({ validDecisionText($0, limit: 500) }) ?? true else {
            throw ClientError.configuration
        }
    }
}

private func validDecisionText(_ text: String, limit: Int) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= limit && !text.contains("\0")
}

public struct FamilyDecisionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let shopId: UUID
    public let version: Int
    public let kind: FamilyDecisionKind
    public let product: String?
    public let dish: String?
    public let occasion: String?
    public let decision: String
    public let outcome: String?
    public let scope: FamilyDecisionScope
    public let recordedAt: String
    public let observedAt: String?
    public let promotedAt: String?
    func validate() throws {
        try FamilyDecisionInput(kind: kind, dish: dish, product: product, occasion: occasion, decision: decision, outcome: outcome).validate()
        guard version > 0, HistoryValidation.date(recordedAt) != nil, (outcome == nil) == (observedAt == nil),
              observedAt.map({ HistoryValidation.date($0) != nil }) ?? true,
              (scope == .lasting) == (promotedAt != nil), scope != .lasting || kind == .preference,
              promotedAt.map({ HistoryValidation.date($0) != nil }) ?? true else { throw ClientError.invalidResponse }
    }
}

public struct FamilyDecisionPage: Decodable, Sendable {
    public let decisions: [FamilyDecisionRecord]
    public let nextCursor: UUID?
}

public enum FamilyDecisionAction: Codable, Equatable, Sendable {
    case create(FamilyDecisionInput)
    case observe(version: Int, text: String)
    case promote(version: Int)
}

public struct FamilyDecisionIntent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let subject: String
    public let householdID: String
    public let memberID: String
    public let deviceID: String
    public let shopID: UUID
    public let recordID: UUID
    public let action: FamilyDecisionAction

    public func validate() throws {
        guard !subject.isEmpty, !deviceID.isEmpty, HistoryValidation.ids([householdID, memberID]) else { throw ClientError.configuration }
        switch action {
        case .create(let data):
            guard id == recordID else { throw ClientError.configuration }
            try data.validate()
        case .observe(let version, let text):
            guard version > 0, version <= Int(Int32.max), validDecisionText(text, limit: 500) else { throw ClientError.configuration }
        case .promote(let version):
            guard version > 0, version <= Int(Int32.max) else { throw ClientError.configuration }
        }
    }

    var path: String {
        let base = "shops/\(shopID.uuidString.lowercased())/decisions"
        switch action {
        case .create: return base
        case .observe: return base + "/\(recordID.uuidString.lowercased())/outcome"
        case .promote: return base + "/\(recordID.uuidString.lowercased())/promote"
        }
    }
    func body() throws -> Data {
        try validate()
        var body: [String: JSONValue] = ["clientKey": .string(id.uuidString.lowercased())]
        switch action {
        case .create(let value):
            body["kind"] = .string(value.kind.rawValue)
            body["decision"] = .string(value.decision)
            body["product"] = value.product.map(JSONValue.string) ?? .null
            body["dish"] = value.dish.map(JSONValue.string) ?? .null
            body["occasion"] = value.occasion.map(JSONValue.string) ?? .null
            body["outcome"] = value.outcome.map(JSONValue.string) ?? .null
        case .observe(let version, let text):
            body["baseVersion"] = .integer(version); body["outcome"] = .string(text)
        case .promote(let version):
            body["baseVersion"] = .integer(version)
        }
        return try encoded(body)
    }
}
