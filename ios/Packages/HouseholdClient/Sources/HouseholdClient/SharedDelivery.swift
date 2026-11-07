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
    public struct IngredientMatch: Codable, Hashable, Sendable {
        public let occurrenceId: UUID
        public let mealRevision: Int
        public let ingredientId: UUID

        init(occurrenceId: UUID, mealRevision: Int, ingredientId: UUID) {
            self.occurrenceId = occurrenceId
            self.mealRevision = mealRevision
            self.ingredientId = ingredientId
        }

        public init(occurrence: SharedMealOccurrence, ingredient: SharedMealPlanning.Ingredient) {
            occurrenceId = occurrence.id
            mealRevision = occurrence.revision
            ingredientId = ingredient.id
        }
    }
    public struct Reservation: Decodable, Equatable, Sendable {
        public let occurrenceId: UUID
        public let mealRevision: Int
        public let ingredientId: UUID
        public let groupId: UUID
        public let reservationId: UUID
        public let quantity: SharedMealQuantity?

        // A missing quantity must never turn an active reservation into a release.
        private enum CodingKeys: CodingKey { case occurrenceId, mealRevision, ingredientId, groupId, reservationId, quantity }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            occurrenceId = try values.decode(UUID.self, forKey: .occurrenceId)
            mealRevision = try values.decode(Int.self, forKey: .mealRevision)
            ingredientId = try values.decode(UUID.self, forKey: .ingredientId)
            groupId = try values.decode(UUID.self, forKey: .groupId)
            reservationId = try values.decode(UUID.self, forKey: .reservationId)
            quantity = try values.decode(SharedMealQuantity?.self, forKey: .quantity)
        }

        func belongs(to target: IngredientMatch, group: UUID) -> Bool {
            occurrenceId == target.occurrenceId && mealRevision == target.mealRevision &&
                ingredientId == target.ingredientId && groupId == group
        }
    }
    public struct Source: Decodable, Equatable, Identifiable, Sendable {
        public let sourceId: UUID
        public let foodId: UUID
        public let lineId: UUID
        public let segmentKey: UUID
        public let foodName: String
        public let exclusionTags: [String]
        public let matches: [IngredientMatch]?
        public let reservations: [Reservation]?
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
    public let coverageAvailable: Bool?
    public let reservationsAvailable: Bool?
    public let meals: [SharedMealOccurrence]?
    public let lines: [Line]
    public internal(set) var sources: [Source]
    public internal(set) var nextCursor: UUID?
}

/// Every edit retains the reviewed observation head. Null is distinct from a confirmed zero.
public enum SharedDeliveryEdit: Equatable, Sendable {
    case reserve(source: UUID, ingredient: SharedDeliveryPage.IngredientMatch, group: UUID, previous: UUID?, quantity: SharedMealQuantity?)
    case match(source: UUID, ingredient: SharedDeliveryPage.IngredientMatch, matched: Bool)
    case register(lineID: UUID, segment: UUID, name: String, exclusions: [String])
    case arrival(source: UUID, previous: UUID?, observation: UUID, date: Date?, received: SharedMealQuantity?)
    case usable(source: UUID, previous: UUID?, arrival: UUID, observation: UUID, date: Date, quantity: SharedMealQuantity?)

    public var kind: String {
        switch self {
        case .reserve: return "delivery.reserve"
        case .match: return "delivery.match"
        case .register: return "delivery.register"
        case .arrival: return "delivery.arrival"
        case .usable: return "delivery.usable"
        }
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
        case let .reserve(source, target, group, previous, value):
            guard page.reservationsAvailable == true, page.nextCursor == nil,
                  let row = page.sources.first(where: { $0.id == source }), let heads = row.reservations,
                  row.matches?.contains(target) == true,
                  let required = page.reservableQuantity(for: target, group: group) else { throw ClientError.configuration }
            let head = heads.first { $0.belongs(to: target, group: group) }
            guard head?.reservationId == previous else { throw ClientError.configuration }
            if let value {
                try value.amount.validate()
                guard sharedMealText(value.originalLiteral, 240), DeliveryUnit.compatible(value.unit, required.unit) else {
                    throw ClientError.configuration
                }
                // Reducing an existing promise is valid after the physical count becomes unknown.
                if !DeliveryUnit.isReduction(value, from: head?.quantity) {
                    guard let stock = row.confirmed?.quantity, DeliveryUnit.compatible(value.unit, stock.unit) else {
                        throw ClientError.configuration
                    }
                }
            } else if head?.quantity == nil { throw ClientError.configuration }
            body["sourceId"] = id(source)
            body["occurrenceId"] = id(target.occurrenceId)
            body["mealRevision"] = .integer(target.mealRevision)
            body["ingredientId"] = id(target.ingredientId)
            body["groupId"] = id(group)
            body["predecessorId"] = id(previous)
            body["quantity"] = try quantity(value)
        case let .match(source, target, matched):
            if !matched, page.sources.first(where: { $0.id == source })?.reservations?.contains(where: {
                $0.quantity != nil && $0.occurrenceId == target.occurrenceId &&
                    $0.mealRevision == target.mealRevision && $0.ingredientId == target.ingredientId
            }) == true { throw ClientError.configuration }
            guard let matches = page.sources.first(where: { $0.id == source })?.matches,
                  matches.contains(target) != matched, let occurrence = page.meals?.first(where: { $0.id == target.occurrenceId }),
                  occurrence.revision == target.mealRevision,
                  occurrence.meal.planning?.ingredients.contains(where: { $0.id == target.ingredientId }) == true else {
                throw ClientError.configuration
            }
            body["sourceId"] = id(source); body["occurrenceId"] = id(target.occurrenceId)
            body["mealRevision"] = .integer(target.mealRevision); body["ingredientId"] = id(target.ingredientId)
            body["matched"] = .bool(matched)
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

public struct SharedDeliveryCoverage: Decodable, Sendable {
    /// The service keeps exact conversion and summation results as unbounded integers.
    public struct Fraction: Decodable, Sendable {
        public let numerator: String
        public let denominator: String
        public var formatted: String { denominator == "1" ? numerator : numerator + "/" + denominator }

        var valid: Bool {
            func digits(_ s: String) -> Bool {
                !s.isEmpty && (s.count == 1 || s.first != "0") && s.utf8.allSatisfy { (48...57).contains($0) }
            }
            return digits(numerator) && digits(denominator) && denominator != "0"
        }
    }
    public struct Reservation: Decodable, Sendable {
        public let sourceId: UUID
        public let reservationId: UUID
        public let requested: Fraction
        public let backed: Fraction
    }
    public struct Allocation: Decodable, Sendable {
        public let sourceId: UUID
        public let amount: Fraction
    }
    public struct Need: Decodable, Sendable {
        public let occurrenceId: UUID
        public let mealRevision: Int
        public let ingredientId: UUID
        public let groupIds: [UUID]
        public let protected: Bool
        public let required: SharedMealQuantity?
        public let covered: Fraction?
        public let missing: Fraction?
        public let allocations: [Allocation]
        public let issues: [String]
        public let reservations: [Reservation]?

        fileprivate func validateAmounts(eligible: Set<UUID>) throws {
            if required == nil {
                guard covered == nil, missing == nil, allocations.isEmpty else { throw ClientError.invalidResponse }
            } else {
                guard covered?.valid == true, missing?.valid == true else { throw ClientError.invalidResponse }
            }
            var used = Set<UUID>()
            for allocation in allocations {
                guard allocation.amount.valid, allocation.amount.numerator != "0",
                      eligible.contains(allocation.sourceId), used.insert(allocation.sourceId).inserted else { throw ClientError.invalidResponse }
            }
        }
    }
    public let shopId: UUID
    public let shopRevision: Int
    public let placedRevision: Int
    public let authorityEpoch: Int
    public let supplyRevision: Int
    public let asOf: String
    public let unplannedOccurrenceIds: [UUID]
    public let needs: [Need]

    public func validate(reviewed page: SharedDeliveryPage) throws {
        guard shopId == page.shopId, authorityEpoch == page.authorityEpoch, shopRevision == page.shopRevision,
              placedRevision == page.placedRevision, supplyRevision == page.supplyRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        guard let meals = page.meals else { throw ClientError.invalidResponse }
        let unplanned = meals.filter { $0.meal.planning?.ingredients.isEmpty != false }.map(\.id)
        guard Set(unplanned) == Set(unplannedOccurrenceIds), unplanned.count == unplannedOccurrenceIds.count else {
            throw ClientError.invalidResponse
        }
        // Match each row back to the entire sealed requirement, including legacy unsplit group quantities.
        var eligibleSources = [SharedDeliveryPage.IngredientMatch: Set<UUID>]()
        for source in page.sources where source.confirmed != nil {
            for target in source.matches ?? [] { eligibleSources[target, default: []].insert(source.id) }
        }
        let sources = Dictionary(page.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard sources.count == page.sources.count else { throw ClientError.invalidResponse }
        try page.validateReservations()
        var claims = [DeliveryReservationTarget: [UUID: SharedDeliveryPage.Reservation]]()
        for source in page.sources {
            for head in source.reservations ?? [] where head.quantity != nil {
                claims[head.target, default: [:]][source.id] = head
            }
        }
        var remaining = Dictionary(grouping: needs, by: { $0.occurrenceId })
        for occurrence in meals {
            let rows = remaining.removeValue(forKey: occurrence.id) ?? []
            var byIngredient = Dictionary(grouping: rows, by: { $0.ingredientId })
            for ingredient in occurrence.meal.planning?.ingredients ?? [] {
                let bindings = (occurrence.meal.planning?.bindings ?? []).filter { $0.ingredientId == ingredient.id }
                var parts: [([UUID], SharedMealQuantity?)] = [ (ingredient.groupIds, ingredient.quantity) ]
                if !bindings.isEmpty && bindings.count == ingredient.groupIds.count {
                    parts = bindings.map { ([$0.groupId], $0.quantity) }
                }
                let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
                for row in byIngredient.removeValue(forKey: ingredient.id) ?? [] {
                    let protectedGroups = occurrence.meal.planning?.groups.filter { row.groupIds.contains($0.id) && $0.protected } ?? []
                    guard let index = parts.firstIndex(where: { $0.0 == row.groupIds && $0.1 == row.required }),
                          row.mealRevision == occurrence.revision,
                          row.protected == (occurrence.meal.protected || !protectedGroups.isEmpty) else { throw ClientError.invalidResponse }
                    try row.validateAmounts(eligible: eligibleSources[target] ?? [])
                    var expected = [UUID: SharedDeliveryPage.Reservation]()
                    if row.groupIds.count == 1, let group = row.groupIds.first {
                        expected = claims.removeValue(forKey: .init(ingredient: target, group: group)) ?? [:]
                    }
                    try row.validateReservations(expected: expected, sources: sources)
                    parts.remove(at: index)
                }
                guard parts.isEmpty else { throw ClientError.invalidResponse }
            }
            guard byIngredient.isEmpty else { throw ClientError.invalidResponse }
        }
        guard remaining.isEmpty, claims.isEmpty else { throw ClientError.invalidResponse }
    }
}
