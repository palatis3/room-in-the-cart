import Foundation

private typealias Fraction = SharedDeliveryCoverage.Fraction
private typealias Match = SharedDeliveryPage.IngredientMatch

public struct SharedFoodCoverage: Decodable, Equatable, Sendable {
    public struct Allocation: Decodable, Equatable, Sendable {
        public let sourceId: UUID
        public let amount: SharedDeliveryCoverage.Fraction
        public let kind: String
    }
    public struct Need: Decodable, Equatable, Sendable {
        let base: SharedDeliveryCoverage.Need
        public var occurrenceId: UUID { base.occurrenceId }
        public var mealRevision: Int { base.mealRevision }
        public var ingredientId: UUID { base.ingredientId }
        public var groupIds: [UUID] { base.groupIds }
        public var `protected`: Bool { base.protected }
        public var required: SharedMealQuantity? { base.required }
        public var covered: SharedDeliveryCoverage.Fraction? { base.covered }
        public var missing: SharedDeliveryCoverage.Fraction? { base.missing }
        public var issues: [String] { base.issues }
        public var reservations: [SharedDeliveryCoverage.Reservation]? { base.reservations }
        public let allocations: [Allocation]
        public let delivered, pantry, freezer: SharedDeliveryCoverage.Fraction?

        enum CodingKeys: CodingKey { case allocations, delivered, pantry, freezer }
        public init(from decoder: Decoder) throws {
            base = try .init(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            allocations = try values.decode([Allocation].self, forKey: .allocations)
            delivered = try values.decode(SharedDeliveryCoverage.Fraction?.self, forKey: .delivered)
            pantry = try values.decode(SharedDeliveryCoverage.Fraction?.self, forKey: .pantry)
            freezer = try values.decode(SharedDeliveryCoverage.Fraction?.self, forKey: .freezer)
        }
    }
    public let shopId: UUID
    public let shopRevision, placedRevision, authorityEpoch, supplyRevision, pantryRevision: Int
    public let asOf: String
    public let unplannedOccurrenceIds: [UUID]
    public let needs: [Need]

    public func validate(reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) throws {
        try pantry.validate(delivery: delivery)
        guard pantryRevision == pantry.pantryRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        guard validHelperTimestamp(asOf) else { throw ClientError.invalidResponse }
        var supplies = [UUID: ReviewedFoodSupply]()
        var kinds = [Match: [UUID: String]]()
        for source in delivery.sources {
            guard supplies.updateValue(.init(source), forKey: source.id) == nil else { throw ClientError.invalidResponse }
            for match in source.matches ?? [] { kinds[match, default: [:]][source.id] = "delivery" }
        }
        for lot in pantry.lots where lot.selected {
            var supply = supplies[lot.id] ?? .init(id: lot.id, quantity: lot.observation?.quantity, matches: [], reservations: [])
            supply.matches += lot.matches
            supply.reservations += lot.reservations
            supplies[lot.id] = supply
            for match in lot.matches { kinds[match, default: [:]][lot.id] = lot.location }
        }
        let projection = SharedDeliveryCoverage(shopId: shopId, shopRevision: shopRevision, placedRevision: placedRevision, authorityEpoch: authorityEpoch,
            supplyRevision: supplyRevision, asOf: asOf, unplannedOccurrenceIds: unplannedOccurrenceIds, needs: needs.map(\.base))
        try projection.validate(reviewed: delivery, supplies: Array(supplies.values))

        // Charge every allocation to its physical lot in that lot's own unit. A delivery
        // and its stored alias share one identifier and therefore one physical limit.
        var consumed = [UUID: Fraction]()
        for need in needs {
            guard let required = need.required else {
                guard need.delivered == nil, need.pantry == nil, need.freezer == nil else { throw ClientError.invalidResponse }
                continue
            }
            guard let covered = need.covered, let missing = need.missing, let expected = DeliveryUnit.convert(required, to: required.unit),
                  required.validStockQuantity, covered.adding(missing).compare(expected) == .orderedSame else { throw ClientError.invalidResponse }
            let target = Match(occurrenceId: need.occurrenceId, mealRevision: need.mealRevision, ingredientId: need.ingredientId)
            var totals = [String: Fraction]()
            for allocation in need.allocations {
                guard kinds[target]?[allocation.sourceId] == allocation.kind, let stock = supplies[allocation.sourceId]?.quantity,
                      stock.validStockQuantity, let factor = DeliveryUnit.convert(.init(amount: .init(numerator: 1), unit: required.unit, originalLiteral: "1"), to: stock.unit) else {
                    throw ClientError.invalidResponse
                }
                totals[allocation.kind] = (totals[allocation.kind] ?? .zero).adding(allocation.amount)
                consumed[allocation.sourceId] = (consumed[allocation.sourceId] ?? .zero).adding(allocation.amount.multiplied(by: factor))
            }
            for (kind, stated) in [("delivery", need.delivered), ("pantry", need.pantry), ("freezer", need.freezer)] {
                guard let stated, stated.valid, stated.compare(totals[kind] ?? .zero) == .orderedSame else { throw ClientError.invalidResponse }
            }
            guard totals.values.reduce(Fraction.zero, { $0.adding($1) }).compare(covered) == .orderedSame else { throw ClientError.invalidResponse }
        }
        for (id, sum) in consumed {
            guard let stock = supplies[id]?.quantity, let limit = DeliveryUnit.convert(stock, to: stock.unit),
                  sum.compare(limit) != .orderedDescending else { throw ClientError.invalidResponse }
        }
    }
}

public struct SharedPantryObservationPreview: Decodable, Equatable, Sendable {
    public struct Need: Decodable, Equatable, Sendable {
        public let occurrenceId, ingredientId: UUID
        public let mealRevision: Int
        public let groupIds: [UUID]
        public let required: SharedMealQuantity?
        public let beforeCovered, afterCovered, beforeMissing, afterMissing: SharedDeliveryCoverage.Fraction?
        public let beforeReservations, afterReservations: [SharedDeliveryCoverage.Reservation]
    }
    public let shopId, lotId: UUID
    public let shopRevision, placedRevision, authorityEpoch, supplyRevision, pantryRevision: Int
    public let asOf, previewDigest: String
    public let needs: [Need]
    public let otherShopsAffected, otherShopsCommitted: Bool

    func validate(lot: SharedPantryPage.Lot, coverage: SharedFoodCoverage) throws {
        guard shopId == coverage.shopId, shopRevision == coverage.shopRevision, placedRevision == coverage.placedRevision,
              authorityEpoch == coverage.authorityEpoch, supplyRevision == coverage.supplyRevision, pantryRevision == coverage.pantryRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        guard lotId == lot.id, validHelperTimestamp(asOf), previewDigest.utf8.count == 64,
              previewDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ClientError.invalidResponse }
        var remaining = coverage.needs
        for row in needs {
            guard let index = remaining.firstIndex(where: {
                $0.occurrenceId == row.occurrenceId && $0.mealRevision == row.mealRevision && $0.ingredientId == row.ingredientId && $0.groupIds == row.groupIds
            }) else { throw ClientError.invalidResponse }
            let before = remaining.remove(at: index)
            guard row.required == before.required, row.beforeCovered == before.covered, row.beforeMissing == before.missing else { throw ClientError.invalidResponse }
            let prior = (before.reservations ?? []).sorted { $0.reservationId.uuidString < $1.reservationId.uuidString }
            guard row.beforeReservations.sorted(by: { $0.reservationId.uuidString < $1.reservationId.uuidString }) == prior,
                  row.afterReservations.count == prior.count else { throw ClientError.invalidResponse }
            var backed = Fraction.zero
            let after = row.afterReservations.sorted { $0.reservationId.uuidString < $1.reservationId.uuidString }
            for (old, updated) in zip(prior, after) {
                guard old.reservationId == updated.reservationId, old.sourceId == updated.sourceId, old.requested == updated.requested,
                      updated.backed.valid, updated.backed.compare(updated.requested) != .orderedDescending else { throw ClientError.invalidResponse }
                backed = backed.adding(updated.backed)
            }
            if let required = row.required {
                guard let covered = row.afterCovered, let missing = row.afterMissing, covered.valid, missing.valid,
                      let expected = DeliveryUnit.convert(required, to: required.unit), covered.adding(missing).compare(expected) == .orderedSame,
                      backed.compare(covered) != .orderedDescending else {
                    throw ClientError.invalidResponse
                }
            } else if row.afterCovered != nil || row.afterMissing != nil { throw ClientError.invalidResponse }
        }
        let matches = Set(lot.matches)
        guard !remaining.contains(where: { matches.contains(.init(occurrenceId: $0.occurrenceId, mealRevision: $0.mealRevision, ingredientId: $0.ingredientId)) }) else {
            throw ClientError.invalidResponse
        }
    }
}
