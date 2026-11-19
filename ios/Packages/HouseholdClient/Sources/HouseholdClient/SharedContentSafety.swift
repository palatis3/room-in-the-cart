import Foundation

/// Selects one field of a currently authorized shared record. Sender identity is resolved by the service.
public struct SharedMessageSource: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, clarification, instruction, suggestion, cookCopy }
    public enum Field: String, Codable, Sendable { case item, amount, question, shopLabel, label, unit, action, correction, text }
    public let kind: Kind
    public let id: String
    public let revision: Int
    public let field: Field
    public let index: Int?

    public init?(kind: Kind, id: String, revision: Int, field: Field, index: Int? = nil) {
        guard let identifier = UUID(uuidString: id), revision > 0 else { return nil }
        switch (kind, field) {
        case (.instruction, .label), (.instruction, .amount), (.instruction, .unit), (.instruction, .action):
            guard let index, (0..<200).contains(index) else { return nil }
        case (.request, .item), (.request, .amount), (.clarification, .question), (.instruction, .shopLabel),
             (.suggestion, .correction), (.cookCopy, .text):
            guard index == nil else { return nil }
        default: return nil
        }
        self.kind = kind
        self.id = identifier.uuidString.lowercased()
        self.revision = revision
        self.field = field
        self.index = index
    }
}

public struct SharedContentAction: Encodable, Equatable, Sendable {
    public enum Action: String, Encodable, Sendable { case report, block }
    public enum Reason: String, Encodable, Sendable, CaseIterable { case harassment, unsafe, other }
    public let clientKey: String
    public let action: Action
    public let source: SharedMessageSource
    public let text: String?
    public let reason: Reason?

    public static func report(source: SharedMessageSource, reason: Reason, excerpt: String?, clientKey: UUID = UUID()) -> Self {
        Self(clientKey: clientKey.uuidString.lowercased(), action: .report, source: source, text: excerpt, reason: reason)
    }

    public static func block(source: SharedMessageSource, clientKey: UUID = UUID()) -> Self {
        Self(clientKey: clientKey.uuidString.lowercased(), action: .block, source: source, text: nil, reason: nil)
    }
}

public struct SharedContentReceipt: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable { case received, blocked }
    public let receiptId: UUID
    public let status: Status
}

public extension HouseholdBootstrap {
    var supportsSharedContentSafety: Bool { enrolled && capabilities.contains("shared_content_safety") }
    var hasOnlyChildRequestCapabilities: Bool {
        capabilities == ["own_requests"] || (capabilities.count == 2 && Set(capabilities) == ["own_requests", "shared_content_safety"])
    }
}
