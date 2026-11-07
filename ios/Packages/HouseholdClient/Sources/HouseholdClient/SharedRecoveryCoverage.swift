import Foundation

/// Joint physical allocation for the currently accepted needs, including replacements.
public struct SharedRecoveryCoverage: Decodable, Equatable, Sendable {
    @dynamicMemberLookup public struct Need: Decodable, Equatable, Sendable {
        public let needId: UUID
        private let physical: SharedFoodCoverage.Need
        public subscript<T>(dynamicMember key: KeyPath<SharedFoodCoverage.Need, T>) -> T { physical[keyPath: key] }

        private enum CodingKeys: CodingKey { case needId, required, covered, missing }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.required), values.contains(.covered), values.contains(.missing) else { throw ClientError.invalidResponse }
            needId = try values.decode(UUID.self, forKey: .needId)
            physical = try .init(from: decoder)
        }
    }
    public let shopId: UUID
    public let placedRevision: Int
    public let base: SharedRecoveryBase
    public let asOf: String
    public let needs: [Need]
    public let unplannedOccurrenceIds: [UUID]

    private enum CodingKeys: CodingKey { case shopId, placedRevision, asOf, needs, unplannedOccurrenceIds }
    public init(from decoder: Decoder) throws {
        base = try SharedRecoveryBase(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shopId = try values.decode(UUID.self, forKey: .shopId)
        placedRevision = try values.decode(Int.self, forKey: .placedRevision)
        asOf = try values.decode(String.self, forKey: .asOf)
        needs = try values.decode([Need].self, forKey: .needs)
        unplannedOccurrenceIds = try values.decode([UUID].self, forKey: .unplannedOccurrenceIds)
    }

    public func validate(reviewed page: SharedRecoveryPage) throws {
        guard shopId == page.shopId, placedRevision == page.placedRevision, base == page.base else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        guard let now = householdTimestamp(asOf), unplannedOccurrenceIds.count == page.unplannedOccurrenceIds.count,
              Set(unplannedOccurrenceIds) == Set(page.unplannedOccurrenceIds) else { throw ClientError.invalidResponse }
        var demands: [SharedRecoveryPreview.Demand] = [], allocations: [SharedRecoveryPreview.Allocation] = []
        for row in needs {
            guard let meal = page.meals.first(where: { $0.id == row.occurrenceId }), meal.sourceMealRevision == row.mealRevision,
                  let need = meal.needs.first(where: { $0.id == row.needId }), row.ingredientId == need.ingredientId,
                  Set(row.groupIds) == Set(need.groups), row.groupIds.count == need.groups.count,
                  row.protected == (need.priority == "protected"), row.required == need.quantity, let pins = row.reservations else {
                throw ClientError.invalidResponse
            }
            let knownIssues = ["unknownQuantity", "unknownSplit", "noMatch", "unconfirmed", "unitMismatch", "exclusion", "protectedQuantityUnknown", "reservationShortfall"]
            guard Set(knownIssues).isSuperset(of: row.issues) else { throw ClientError.invalidResponse }
            var totals = [String: SharedDeliveryCoverage.Fraction]()
            for allocation in row.allocations {
                guard let unit = row.required?.unit, allocation.amount.valid, let source = page.sourceOptions.first(where: { $0.id == allocation.sourceId }),
                      allocation.kind == source.kind || (allocation.kind == "delivery" && page.deliverySourceIDs.contains(source.id)) else {
                    throw ClientError.invalidResponse
                }
                totals[allocation.kind] = (totals[allocation.kind] ?? .zero).adding(allocation.amount)
                allocations.append(.init(needId: row.needId, sourceId: source.id, amount: allocation.amount, unit: unit))
            }
            for (kind, stated) in [("delivery", row.delivered), ("pantry", row.pantry), ("freezer", row.freezer)] {
                if row.required == nil {
                    guard stated == nil else { throw ClientError.invalidResponse }
                } else {
                    guard let stated, stated.valid, stated.compare(totals[kind] ?? .zero) == .orderedSame else { throw ClientError.invalidResponse }
                }
            }
            let deadline = householdTimestamp(need.due).map { $0 < now ? "pastDue" : "notPastDue" } ?? "unknown"
            demands.append(.init(needId: row.needId, due: need.due, deadlineStatus: deadline, allocated: row.covered, shortfall: row.missing,
                                 unit: row.required?.unit, issues: row.issues, sourceIssues: [], reservations: pins))
        }
        let projection = SharedRecoveryPreview.Projection(meals: page.meals, demands: demands, allocations: allocations)
        try projection.validate(page: page, asOf: now)
    }
}
