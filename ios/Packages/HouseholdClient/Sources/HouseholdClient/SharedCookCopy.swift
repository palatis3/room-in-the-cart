import Foundation

public struct SharedCookCopy: Decodable, Equatable, Identifiable, Sendable {
    public var id: UUID { copyId }
    public let copyId: UUID
    public let shopId: UUID
    public let shopRevision: Int
    public let placedRevision: Int
    public let authorityEpoch: Int
    public let supplyRevision: Int
    public let occurrenceId: UUID
    public let mealRevision: Int
    public let version: Int
    public let language: String
    public let text: String
    public let createdAt: String

    func validate(occurrence: SharedMealOccurrence, reviewed page: SharedDeliveryPage) throws {
        guard shopId == page.shopId, placedRevision == page.placedRevision,
              occurrenceId == occurrence.id, mealRevision == occurrence.revision,
              version > 0, shopRevision >= placedRevision, authorityEpoch > 0, supplyRevision >= 0,
              ["en", "es"].contains(language), SharedCookCopyEdit.validText(text), validHelperTimestamp(createdAt) else {
            throw ClientError.invalidResponse
        }
        guard shopRevision <= page.shopRevision, authorityEpoch <= page.authorityEpoch, supplyRevision <= page.supplyRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
    }
}

public struct SharedCookCopyBaseline: Decodable, Equatable, Sendable {
    public struct SendRecord: Decodable, Equatable, Sendable {
        public let sendId: UUID
        public let copyId: UUID
        public let recipient: String
        public let sentAt: String
    }

    public let copy: SharedCookCopy
    public let send: SendRecord
}

struct SharedCookCopyPage: Decodable, Sendable {
    let copies: [SharedCookCopy]
    let nextCursor: UUID?

    enum CodingKeys: CodingKey { case copies, nextCursor }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        copies = try values.decode([SharedCookCopy].self, forKey: .copies)
        nextCursor = try values.decode(UUID?.self, forKey: .nextCursor)
    }
}

struct SharedCookCopyBaselineResult: Decodable, Sendable {
    let baseline: SharedCookCopyBaseline?

    enum CodingKeys: CodingKey { case baseline }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try values.decode(SharedCookCopyBaseline?.self, forKey: .baseline)
    }
}

public enum SharedCookCopyEdit: Sendable {
    case save(text: String, language: String, occurrence: SharedMealOccurrence)
    case markSent(copy: SharedCookCopy, recipient: String, previousSendId: UUID?)

    public var kind: String {
        switch self {
        case .save: return "cookCopy.save"
        case .markSent: return "cookCopy.markSent"
        }
    }

    // The service applies ECMAScript trim to recipient labels and blank-text checks.
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines
        .subtracting(CharacterSet(charactersIn: "\u{0085}\u{200B}")).union(CharacterSet(charactersIn: "\u{FEFF}"))

    static func validText(_ value: String) -> Bool {
        value.utf16.count <= 16_000 && !value.utf8.contains(0) && !value.trimmingCharacters(in: trimCharacters).isEmpty
    }

    public static func recipientLabel(_ input: String) throws -> String {
        let label = input.trimmingCharacters(in: trimCharacters)
        guard !label.isEmpty, label.utf16.count <= 80, label.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw ClientError.configuration }
        return label
    }

    public func body(reviewed page: SharedDeliveryPage) throws -> [String: JSONValue] {
        guard page.nextCursor == nil else { throw ClientError.configuration }
        switch self {
        case let .save(text, language, occurrence):
            guard SharedCookCopyEdit.validText(text), ["en", "es"].contains(language),
                  page.meals?.contains(occurrence) == true else { throw ClientError.configuration }
            return ["placedRevision": .integer(page.placedRevision), "supplyRevision": .integer(page.supplyRevision),
                    "occurrenceId": .string(occurrence.id.uuidString.lowercased()), "mealRevision": .integer(occurrence.revision),
                    "language": .string(language), "text": .string(text)]
        case let .markSent(copy, recipient, previous):
            guard let occurrence = page.meals?.first(where: { $0.id == copy.occurrenceId }) else { throw ClientError.configuration }
            try copy.validate(occurrence: occurrence, reviewed: page)
            return ["copyId": .string(copy.copyId.uuidString.lowercased()), "recipient": .string(try Self.recipientLabel(recipient)),
                    "previousSendId": previous.map { .string($0.uuidString.lowercased()) } ?? .null]
        }
    }
}

extension ShopperReceipt {
    func validateCookCopy(_ envelope: CommandEnvelope) throws {
        guard disposition == "recorded", kind == envelope.kind, UUID(uuidString: shopId) == UUID(uuidString: envelope.shopId),
              shopRevision == envelope.base.shopRevision, authorityEpoch == envelope.base.authorityEpoch,
              let operation = UUID(uuidString: operationId), let copyId else { throw ClientError.invalidResponse }
        if kind == "cookCopy.save" {
            guard copyId == operation else { throw ClientError.invalidResponse }
        } else {
            guard copyId != operation, envelope.body["copyId"] == .string(copyId.uuidString.lowercased()),
                  envelope.body["previousSendId"] != .string(operation.uuidString.lowercased()) else { throw ClientError.invalidResponse }
        }
    }
}
