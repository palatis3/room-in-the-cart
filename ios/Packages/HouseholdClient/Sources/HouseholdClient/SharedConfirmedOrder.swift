import Foundation

/// Retailer evidence changes ordered expectations only. Original checkout and physical supply stay separate.
public struct SharedConfirmedOrder: Decodable, Equatable, Sendable {
    public struct Original: Decodable, Equatable, Sendable {
        public let lines: [ShopperBasketLine]
        public let quote: ShopperQuote
        public let snapshotCreatedAt: String
    }
    public struct Current: Decodable, Equatable, Sendable {
        public let lines: [ShopperBasketLine]
        public let amendmentId: UUID?
    }
    public struct Amendment: Decodable, Equatable, Identifiable, Sendable {
        public let amendmentId: UUID
        public let predecessorId: UUID?
        public let retailerReference: String
        public let confirmedAt: String
        public let recordedAt: String
        public let actorId: UUID
        public let actorLabel: String?
        public let lines: [ShopperBasketLine]
        public var id: UUID { amendmentId }
    }
    public let shopId: UUID
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let placedRevision: Int
    public let asOf: String
    public let original: Original
    public let current: Current
    public let amendments: [Amendment]

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func validateLines(_ lines: [ShopperBasketLine]) throws {
        guard lines.count <= 200, Set(lines.compactMap { UUID(uuidString: $0.lineId) }).count == lines.count,
              lines.allSatisfy({ !$0.originalItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.originalItem.utf16.count <= 240 && !$0.originalItem.contains("\0") &&
                  (1...10_000).contains($0.packs) && ($0.unitPriceMinor.map { (0...1_000_000_000).contains($0) } ?? true) }) else {
            throw ClientError.invalidResponse
        }
    }
    static func byID(_ lines: [ShopperBasketLine]) -> [UUID: ShopperBasketLine] {
        Dictionary(uniqueKeysWithValues: lines.map { (UUID(uuidString: $0.lineId)!, $0) })
    }
    static func validateChange(from before: [ShopperBasketLine], to after: [ShopperBasketLine], history: Set<UUID>) throws {
        try validateLines(after)
        let old = byID(before), next = byID(after)
        guard old != next else { throw ClientError.configuration }
        for (id,line) in next {
            if let previous = old[id] {
                guard line.originalItem == previous.originalItem else { throw ClientError.configuration }
            } else if history.contains(id) { throw ClientError.configuration }
        }
    }
    public func validate(shopID: UUID) throws {
        guard shopId == shopID, placedRevision > 0, shopRevision >= placedRevision, authorityEpoch > 0,
              let instant = Self.date(asOf), let originalDate = Self.date(original.snapshotCreatedAt), originalDate <= instant else {
            throw ClientError.invalidResponse
        }
        try Self.validateLines(original.lines)
        var lines = original.lines, previous: UUID?, seen = Set<UUID>()
        var history = Set(Self.byID(lines).keys), lastTime = originalDate
        for event in amendments {
            guard seen.insert(event.id).inserted, event.predecessorId == previous,
                  !event.retailerReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.retailerReference.utf16.count <= 240, event.retailerReference.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  let confirmed = Self.date(event.confirmedAt), let recorded = Self.date(event.recordedAt),
                  confirmed >= lastTime, confirmed <= recorded, recorded <= instant else { throw ClientError.invalidResponse }
            do { try Self.validateChange(from: lines, to: event.lines, history: history) }
            catch { throw ClientError.invalidResponse }
            lines = event.lines; previous = event.id; lastTime = confirmed
            history.formUnion(Self.byID(lines).keys)
        }
        guard current.amendmentId == previous, current.lines == lines else { throw ClientError.invalidResponse }
    }
}

public struct SharedOrderConfirmation: Equatable, Sendable {
    public let reference: String
    public let confirmedAt: Date
    public let lines: [ShopperBasketLine]
    public init(reference: String, confirmedAt: Date, lines: [ShopperBasketLine]) {
        self.reference = reference; self.confirmedAt = confirmedAt; self.lines = lines
    }
    public func body(reviewed page: SharedConfirmedOrder, now: Date = Date()) throws -> [String: JSONValue] {
        try page.validate(shopID: page.shopId)
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reference.utf16.count <= 240, reference.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }), confirmedAt.timeIntervalSince1970.isFinite,
              confirmedAt <= now,
              let preceding = SharedConfirmedOrder.date(page.amendments.last?.confirmedAt ?? page.original.snapshotCreatedAt),
              confirmedAt >= preceding else { throw ClientError.configuration }
        let history = Set((page.original.lines + page.amendments.flatMap(\.lines)).compactMap { UUID(uuidString: $0.lineId) })
        try SharedConfirmedOrder.validateChange(from: page.current.lines, to: lines, history: history)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["placedRevision": .integer(page.placedRevision),
                "predecessorId": page.current.amendmentId.map { .string($0.uuidString.lowercased()) } ?? .null,
                "retailerReference": .string(reference), "confirmedAt": .string(formatter.string(from: confirmedAt)),
                "lines": try JSONDecoder().decode(JSONValue.self, from: encoded(lines))]
    }
}

extension ShopperReceipt {
    func validateAmendment(_ envelope: CommandEnvelope) throws {
        guard let amendmentId, amendmentId == UUID(uuidString: operationId),
              kind == "amendment.recordResponse", kind == envelope.kind, shopId == envelope.shopId,
              disposition == "recorded", authorityEpoch == envelope.base.authorityEpoch,
              envelope.base.shopRevision < Int(Int32.max), shopRevision == envelope.base.shopRevision + 1,
              let placedRevision, envelope.body["placedRevision"] == .integer(placedRevision) else {
            throw ClientError.invalidResponse
        }
    }
}
