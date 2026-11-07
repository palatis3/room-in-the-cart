import Foundation

public struct SharedDeliveryPage: Decodable, Equatable, Sendable {
    public struct Line: Decodable, Equatable, Identifiable, Sendable {
        public let lineId: UUID
        public let name: String
        public var id: UUID { lineId }
    }
    public struct Arrival: Decodable, Equatable, Sendable {
        public let observationId: UUID
        public let sourceId: UUID
        public let arrivedAt: String?
        public let received: SharedMealQuantity?
    }
    public struct Usable: Decodable, Equatable, Sendable {
        public let observationId: UUID
        public let sourceId: UUID
        public let arrivalObservationId: UUID
        public let confirmedAt: String
        public let usable: SharedMealQuantity?
    }
    public struct Lot: Decodable, Equatable, Sendable {
        public let sourceId: UUID
        public let foodId: UUID
        public let quantity: SharedMealQuantity
        public let arrivalId: UUID
        public let usableId: UUID
    }
    public struct Source: Decodable, Equatable, Identifiable, Sendable {
        public let sourceId: UUID
        public let foodId: UUID
        public let lineId: UUID
        public let segmentKey: UUID
        public let foodName: String
        public let exclusionTags: [String]
        public let arrival: Arrival?
        public let usable: Usable?
        public let confirmed: Lot?
        public var id: UUID { sourceId }

        func validate() throws {
            guard arrival.map({ $0.sourceId == id }) ?? true, usable.map({ $0.sourceId == id }) ?? true else { throw ClientError.invalidResponse }
            if let confirmed {
                guard confirmed.sourceId == id, confirmed.foodId == foodId, confirmed.arrivalId == arrival?.observationId,
                      confirmed.usableId == usable?.observationId, usable?.arrivalObservationId == confirmed.arrivalId,
                      confirmed.quantity == usable?.usable else { throw ClientError.invalidResponse }
            }
        }
    }
    public let shopId: UUID
    public let placedRevision: Int
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let supplyRevision: Int
    public let lines: [Line]
    public internal(set) var sources: [Source]
    public internal(set) var nextCursor: UUID?
}

/// Every edit retains the reviewed observation head. Null is distinct from a confirmed zero.
public enum SharedDeliveryEdit: Equatable, Sendable {
    case register(lineID: UUID, segment: UUID, name: String, exclusions: [String])
    case arrival(source: UUID, previous: UUID?, observation: UUID, date: Date?, received: SharedMealQuantity?)
    case usable(source: UUID, previous: UUID?, arrival: UUID, observation: UUID, date: Date, quantity: SharedMealQuantity?)

    public var kind: String {
        switch self { case .register: return "delivery.register"; case .arrival: return "delivery.arrival"; case .usable: return "delivery.usable" }
    }
    public func body(reviewed page: SharedDeliveryPage) throws -> [String: JSONValue] {
        func id(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
        func quantity(_ value: SharedMealQuantity?) throws -> JSONValue {
            guard let value else { return .null }
            guard (0...1_000_000_000).contains(value.amount.numerator), (1...1_000_000_000).contains(value.amount.denominator),
                  HistoryUnit(rawValue: value.unit) != nil, !value.originalLiteral.isEmpty, value.originalLiteral.count <= 240 else { throw ClientError.configuration }
            return try JSONDecoder().decode(JSONValue.self, from: encoded(value))
        }
        var body: [String:JSONValue] = ["supplyRevision": .integer(page.supplyRevision)]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        switch self {
        case let .register(line, segment, name, exclusions):
            guard page.lines.contains(where: { $0.id == line }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 240, exclusions.count <= 20, exclusions.allSatisfy({ !$0.isEmpty && $0.count <= 240 }) else { throw ClientError.configuration }
            body["placedRevision"] = .integer(page.placedRevision); body["lineId"] = id(line); body["segmentKey"] = id(segment)
            body["foodName"] = .string(name); body["exclusionTags"] = .array(exclusions.map(JSONValue.string))
        case let .arrival(source, previous, observation, date, received):
            guard let row = page.sources.first(where: { $0.id == source }), row.arrival?.observationId == previous else { throw ClientError.configuration }
            body["sourceId"] = id(source); body["predecessorId"] = id(previous); body["observationId"] = id(observation)
            body["arrivedAt"] = date.map { .string(formatter.string(from: $0)) } ?? .null; body["received"] = try quantity(received)
        case let .usable(source, previous, arrival, observation, date, usable):
            guard let row = page.sources.first(where: { $0.id == source }), row.usable?.observationId == previous,
                  row.arrival?.observationId == arrival else { throw ClientError.configuration }
            body["sourceId"] = id(source); body["predecessorId"] = id(previous); body["observationId"] = id(observation)
            body["arrivalObservationId"] = id(arrival); body["confirmedAt"] = .string(formatter.string(from: date)); body["usable"] = try quantity(usable)
        }
        return body
    }
}
