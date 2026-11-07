import Foundation

public struct SharedCookCopy: Decodable, Equatable, Identifiable, Sendable {
    public var id: UUID { copyId }
    public let copyId: UUID
    public let shopId: UUID
    public let shopRevision: Int
    public let placedRevision: Int
    public let authorityEpoch: Int
    public internal(set) var recoveryRevision: Int? = nil
    public internal(set) var revisionId: UUID? = nil
    public let pantryRevision: Int?
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
              version > 0, shopRevision >= placedRevision, authorityEpoch > 0, supplyRevision >= 0, (pantryRevision ?? 0) >= 0,
              (revisionId == nil) == (recoveryRevision == nil), recoveryRevision == nil || pantryRevision != nil,
              (recoveryRevision ?? 0) >= 0, (recoveryRevision ?? 0) <= (page.recoveryRevision ?? 0),
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

/// Byte lengths bind typed sections to the immutable reviewed wording without
/// duplicating that wording on the wire or guessing boundaries from punctuation.
public struct SharedCookFactIndex: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public let key: String
        public let bytes: Int
        public let unresolved: Bool

        public init(key: String, bytes: Int, unresolved: Bool) {
            self.key = key; self.bytes = bytes; self.unresolved = unresolved
        }
    }

    public enum Source: String, Codable, Sendable { case delivery, food, recovered }
    public let source: Source
    public let version: Int
    public let sections: [Section]

    private static func validKey(_ key: String) -> Bool {
        if ["meal", "preparation", "unplanned", "scope", "stamp"].contains(key) { return true }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        return parts.first == "need" && parts.count > 1 && parts.dropFirst().allSatisfy {
            UUID(uuidString: String($0))?.uuidString.lowercased() == String($0)
        }
    }

    public init?(source: Source, sections: [Section]) {
        guard (3...256).contains(sections.count), sections.first?.key == "meal", sections.dropLast().last?.key == "scope", sections.last?.key == "stamp", sections.last?.unresolved == false,
              Set(sections.map(\.key)).count == sections.count,
              sections.allSatisfy({ (1...48_000).contains($0.bytes) && (1...300).contains($0.key.utf8.count) && Self.validKey($0.key) }) else { return nil }
        version = 1
        self.source = source
        self.sections = sections
    }

    public func pieces(in text: String) -> [(section: Section, wording: String)]? {
        guard version == 1, Self(source: source, sections: sections) != nil else { return nil }
        var rest = text.utf8[...]
        var pieces: [(Section, String)] = []
        for section in sections {
            guard rest.count >= section.bytes, let wording = String(bytes: rest.prefix(section.bytes), encoding: .utf8) else { return nil }
            rest = rest.dropFirst(section.bytes)
            if section.key == "stamp" { return rest.isEmpty ? pieces : nil }
            let separator: [UInt8] = section.key == "scope" ? [10] : [10, 10]
            guard rest.starts(with: separator) else { return nil }
            pieces.append((section, wording))
            rest = rest.dropFirst(separator.count)
        }
        return nil
    }

    var wire: JSONValue {
        .object(["version": .integer(version), "source": .string(source.rawValue), "sections": .array(sections.map { .object(["key": .string($0.key), "bytes": .integer($0.bytes), "unresolved": .bool($0.unresolved)]) })])
    }
}

public struct SharedCookCorrectionReview: Decodable, Equatable, Sendable {
    public let copyId: UUID
    public let previousCopyId: UUID
    public let previousSendId: UUID
    public let recipient: String
    public let currentFacts: SharedCookFactIndex?
    public let previousFacts: SharedCookFactIndex?

    private enum CodingKeys: CodingKey { case copyId, previousCopyId, previousSendId, recipient, currentFacts, previousFacts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        copyId = try values.decode(UUID.self, forKey: .copyId)
        previousCopyId = try values.decode(UUID.self, forKey: .previousCopyId)
        previousSendId = try values.decode(UUID.self, forKey: .previousSendId)
        recipient = try values.decode(String.self, forKey: .recipient)
        currentFacts = try? values.decode(SharedCookFactIndex.self, forKey: .currentFacts)
        previousFacts = try? values.decode(SharedCookFactIndex.self, forKey: .previousFacts)
    }
}

public enum SharedCookCopyEdit: Sendable {
    case save(text: String, language: String, occurrence: SharedMealOccurrence, facts: SharedCookFactIndex? = nil)
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

    public func body(reviewed page: SharedDeliveryPage, pantry: SharedPantryPage? = nil, recovery: SharedRecoveryPage? = nil) throws -> [String: JSONValue] {
        guard page.nextCursor == nil else { throw ClientError.configuration }
        switch self {
        case let .save(text, language, occurrence, facts):
            guard SharedCookCopyEdit.validText(text), ["en", "es"].contains(language),
                  page.meals?.contains(occurrence) == true else { throw ClientError.configuration }
            var body: [String: JSONValue] = ["placedRevision": .integer(page.placedRevision), "supplyRevision": .integer(page.supplyRevision),
                    "occurrenceId": .string(occurrence.id.uuidString.lowercased()), "mealRevision": .integer(occurrence.revision),
                    "language": .string(language), "text": .string(text)]
            if let pantry {
                try pantry.validate(delivery: page)
                body["pantryRevision"] = .integer(pantry.pantryRevision)
            }
            if let recovery {
                guard let pantry, let meal = recovery.meals.first(where: { $0.id == occurrence.id }) else { throw ClientError.configuration }
                try recovery.validate(delivery: page, pantry: pantry)
                guard let source = recovery.mealSources.first(where: { $0.occurrenceId == meal.id }) else { throw ClientError.configuration }
                if meal.revisionId != source.sealedRevisionId {
                    body["recoveryRevision"] = .integer(recovery.base.recoveryRevision)
                    body["revisionId"] = .string(meal.revisionId.uuidString.lowercased())
                }
            }
            if let facts {
                guard facts.pieces(in: text) != nil else { throw ClientError.configuration }
                body["factIndex"] = facts.wire
                // Preserve full-copy saves near the request limit; allow room for the command envelope.
                if try JSONEncoder().encode(body).count > 64_000 { body.removeValue(forKey: "factIndex") }
            }
            return body
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
