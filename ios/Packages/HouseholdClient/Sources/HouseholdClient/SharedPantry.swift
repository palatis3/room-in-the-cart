import Foundation

private typealias Match = SharedDeliveryPage.IngredientMatch

extension SharedMealQuantity {
    var validStockQuantity: Bool {
        (0...1_000_000_000).contains(amount.numerator) && (1...1_000_000_000).contains(amount.denominator) &&
            HistoryUnit(rawValue: unit) != nil && sharedMealText(originalLiteral, 240)
    }
}

public struct SharedPantryPage: Decodable, Equatable, Sendable {
    public struct Observation: Decodable, Equatable, Sendable {
        public let observationId: UUID
        public let confirmedAt: String
        public let quantity: SharedMealQuantity?
        enum CodingKeys: CodingKey { case observationId, confirmedAt, quantity }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            observationId = try values.decode(UUID.self, forKey: .observationId)
            confirmedAt = try values.decode(String.self, forKey: .confirmedAt)
            quantity = try values.decode(SharedMealQuantity?.self, forKey: .quantity)
        }
    }
    public struct Lot: Decodable, Equatable, Sendable, Identifiable {
        public var id: UUID { lotId }
        public let lotId: UUID
        public let origin: String
        public let location: String
        public let storedAt: String?
        public let useFirstAt: String?
        public let foodName: String
        public let exclusionTags: [String]
        public let selected: Bool
        public let observation: Observation?
        public let matches: [SharedDeliveryPage.IngredientMatch]
        public let reservations: [SharedDeliveryPage.Reservation]

        enum CodingKeys: CodingKey { case lotId, origin, location, storedAt, useFirstAt, foodName, exclusionTags, selected, observation, matches, reservations }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lotId = try values.decode(UUID.self, forKey: .lotId)
            origin = try values.decode(String.self, forKey: .origin)
            location = try values.decode(String.self, forKey: .location)
            storedAt = try values.decode(String?.self, forKey: .storedAt)
            useFirstAt = try values.decode(String?.self, forKey: .useFirstAt)
            foodName = try values.decode(String.self, forKey: .foodName)
            exclusionTags = try values.decode([String].self, forKey: .exclusionTags)
            selected = try values.decode(Bool.self, forKey: .selected)
            observation = try values.decode(Observation?.self, forKey: .observation)
            matches = try values.decode([SharedDeliveryPage.IngredientMatch].self, forKey: .matches)
            reservations = try values.decode([SharedDeliveryPage.Reservation].self, forKey: .reservations)
        }
    }
    public let shopId: UUID
    public let shopRevision: Int
    public let placedRevision: Int
    public let authorityEpoch: Int
    public let supplyRevision: Int
    public let pantryRevision: Int
    public let asOf: String
    public internal(set) var lots: [Lot]
    public internal(set) var nextCursor: UUID?

    enum CodingKeys: CodingKey { case shopId, shopRevision, placedRevision, authorityEpoch, supplyRevision, pantryRevision, asOf, lots, nextCursor }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shopId = try values.decode(UUID.self, forKey: .shopId)
        shopRevision = try values.decode(Int.self, forKey: .shopRevision)
        placedRevision = try values.decode(Int.self, forKey: .placedRevision)
        authorityEpoch = try values.decode(Int.self, forKey: .authorityEpoch)
        supplyRevision = try values.decode(Int.self, forKey: .supplyRevision)
        pantryRevision = try values.decode(Int.self, forKey: .pantryRevision)
        asOf = try values.decode(String.self, forKey: .asOf)
        lots = try values.decode([Lot].self, forKey: .lots)
        nextCursor = try values.decode(UUID?.self, forKey: .nextCursor)
    }

    func validateScope(delivery: SharedDeliveryPage) throws {
        guard delivery.nextCursor == nil, shopId == delivery.shopId, shopRevision == delivery.shopRevision,
              placedRevision == delivery.placedRevision, authorityEpoch == delivery.authorityEpoch, supplyRevision == delivery.supplyRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        guard pantryRevision >= 0, validHelperTimestamp(asOf) else { throw ClientError.invalidResponse }
    }

    func validate(delivery: SharedDeliveryPage) throws {
        try validateScope(delivery: delivery)
        try delivery.validateReservations()
        guard let readAt = householdTimestamp(asOf), nextCursor == nil, Set(lots.map(\.id)).count == lots.count else { throw ClientError.invalidResponse }
        let targets = Set((delivery.meals ?? []).flatMap { occurrence in
            (occurrence.meal.planning?.ingredients ?? []).map { Match(occurrence: occurrence, ingredient: $0) }
        })
        let sources = Dictionary(delivery.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reservationIDs = Set(delivery.sources.flatMap { ($0.reservations ?? []).map(\.reservationId) })
        var observationIDs = Set<UUID>()
        for lot in lots {
            let matches = Set(lot.matches)
            guard ["manual", "delivery"].contains(lot.origin), ["pantry", "freezer"].contains(lot.location),
                  lot.storedAt.map({ householdTimestamp($0).map({ $0 <= readAt }) == true }) ?? true, lot.useFirstAt.map(validHelperTimestamp) ?? true,
                  sharedMealText(lot.foodName, 240), lot.exclusionTags.count <= 20, lot.exclusionTags.allSatisfy({ sharedMealText($0, 240) }),
                  targets.isSuperset(of: matches), matches.count == lot.matches.count, lot.selected || matches.isEmpty else { throw ClientError.invalidResponse }
            if let observation = lot.observation {
                guard let confirmed = householdTimestamp(observation.confirmedAt), confirmed <= readAt,
                      observationIDs.insert(observation.observationId).inserted,
                      observation.quantity?.validStockQuantity != false else { throw ClientError.invalidResponse }
            }
            if let source = sources[lot.id] {
                guard lot.origin == "delivery", lot.foodName == source.foodName, lot.exclusionTags == source.exclusionTags,
                      lot.observation?.observationId == source.usable?.observationId, lot.observation?.confirmedAt == source.usable?.confirmedAt,
                      lot.observation?.quantity == source.confirmed?.quantity,
                      matches.isDisjoint(with: source.matches ?? []) else { throw ClientError.invalidResponse }
            }
            var seen = Set<DeliveryReservationTarget>()
            for head in lot.reservations {
                guard seen.insert(head.target).inserted, reservationIDs.insert(head.reservationId).inserted,
                      let required = delivery.reservableQuantity(for: head.target.ingredient, group: head.groupId) else { throw ClientError.invalidResponse }
                if let quantity = head.quantity {
                    guard matches.contains(head.target.ingredient), quantity.validStockQuantity, quantity.amount.numerator > 0,
                          DeliveryUnit.compatible(quantity.unit, required.unit) else { throw ClientError.invalidResponse }
                }
            }
        }
    }
}

public enum SharedPantryEdit: Equatable, Sendable {
    case create(location: String, storedAt: Date?, useFirstAt: Date?, name: String, exclusions: [String])
    case storeDelivery(source: UUID, location: String, storedAt: Date?, useFirstAt: Date?)
    case observe(lot: UUID, previous: UUID?, confirmedAt: Date, quantity: SharedMealQuantity?)
    case select(lot: UUID, selected: Bool)
    case match(lot: UUID, ingredient: SharedDeliveryPage.IngredientMatch, matched: Bool)
    case reserve(lot: UUID, ingredient: SharedDeliveryPage.IngredientMatch, group: UUID, previous: UUID?, quantity: SharedMealQuantity?)

    public var kind: String {
        switch self {
        case .create: return "pantry.create"
        case .storeDelivery: return "pantry.storeDelivery"
        case .observe: return "pantry.observe"
        case .select: return "pantry.select"
        case .match: return "pantry.match"
        case .reserve: return "pantry.reserve"
        }
    }

    public func body(reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) throws -> [String: JSONValue] {
        try pantry.validate(delivery: delivery)
        func id(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
        func lot(_ id: UUID) throws -> SharedPantryPage.Lot {
            guard let lot = pantry.lots.first(where: { $0.id == id }) else { throw ClientError.configuration }
            return lot
        }
        func quantity(_ value: SharedMealQuantity?) throws -> JSONValue {
            guard let value else { return .null }
            guard value.validStockQuantity else { throw ClientError.configuration }
            return try JSONDecoder().decode(JSONValue.self, from: encoded(value))
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: JSONValue] = ["pantryRevision": .integer(pantry.pantryRevision), "supplyRevision": .integer(pantry.supplyRevision)]
        func storage(_ location: String, _ stored: Date?, _ useFirst: Date?) throws {
            guard ["pantry", "freezer"].contains(location), stored.map({ $0 <= Date() }) ?? true else { throw ClientError.configuration }
            body["location"] = .string(location)
            body["storedAt"] = stored.map { .string(format.string(from: $0)) } ?? .null
            body["useFirstAt"] = useFirst.map { .string(format.string(from: $0)) } ?? .null
        }
        func target(_ identifier: UUID, _ ingredient: SharedDeliveryPage.IngredientMatch) {
            body["lotId"] = id(identifier)
            body["occurrenceId"] = id(ingredient.occurrenceId)
            body["mealRevision"] = .integer(ingredient.mealRevision)
            body["ingredientId"] = id(ingredient.ingredientId)
        }
        switch self {
        case let .create(location, stored, useFirst, name, exclusions):
            guard sharedMealText(name, 240), exclusions.count <= 20, exclusions.allSatisfy({ sharedMealText($0, 240) }) else { throw ClientError.configuration }
            try storage(location, stored, useFirst)
            body["foodName"] = .string(name); body["exclusionTags"] = .array(exclusions.map(JSONValue.string))
        case let .storeDelivery(source, location, stored, useFirst):
            guard delivery.sources.contains(where: { $0.id == source && $0.confirmed != nil }), !pantry.lots.contains(where: { $0.id == source }) else { throw ClientError.configuration }
            try storage(location, stored, useFirst)
            body["sourceId"] = id(source)
        case let .observe(identifier, previous, confirmed, value):
            let current = try lot(identifier)
            guard current.origin == "manual", current.observation?.observationId == previous, confirmed <= Date() else { throw ClientError.configuration }
            body["lotId"] = id(identifier); body["predecessorId"] = id(previous); body["quantity"] = try quantity(value)
            body["confirmedAt"] = .string(format.string(from: confirmed))
        case let .select(identifier, selected):
            let current = try lot(identifier)
            guard current.selected != selected, selected || current.matches.isEmpty else { throw ClientError.configuration }
            body["lotId"] = id(identifier); body["selected"] = .bool(selected)
        case let .match(identifier, ingredient, matched):
            let current = try lot(identifier)
            guard current.selected, current.matches.contains(ingredient) != matched,
                  let meal = delivery.meals?.first(where: { $0.id == ingredient.occurrenceId && $0.revision == ingredient.mealRevision }),
                  meal.meal.planning?.ingredients.contains(where: { $0.id == ingredient.ingredientId }) == true,
                  delivery.sources.first(where: { $0.id == identifier })?.matches?.contains(ingredient) != true,
                  matched || !current.reservations.contains(where: { $0.target.ingredient == ingredient && $0.quantity != nil }) else { throw ClientError.configuration }
            target(identifier, ingredient); body["matched"] = .bool(matched)
        case let .reserve(identifier, ingredient, group, previous, value):
            let current = try lot(identifier)
            let head = current.reservations.first { $0.belongs(to: ingredient, group: group) }
            guard current.selected, current.matches.contains(ingredient), head?.reservationId == previous,
                  let required = delivery.reservableQuantity(for: ingredient, group: group) else { throw ClientError.configuration }
            if let value {
                guard value.validStockQuantity, value.amount.numerator > 0, DeliveryUnit.compatible(value.unit, required.unit) else { throw ClientError.configuration }
                if !DeliveryUnit.isReduction(value, from: head?.quantity) {
                    guard let stock = current.observation?.quantity, DeliveryUnit.compatible(value.unit, stock.unit) else { throw ClientError.configuration }
                }
            } else if head?.quantity == nil { throw ClientError.configuration }
            target(identifier, ingredient); body["groupId"] = id(group); body["predecessorId"] = id(previous); body["quantity"] = try quantity(value)
        }
        return body
    }
}
