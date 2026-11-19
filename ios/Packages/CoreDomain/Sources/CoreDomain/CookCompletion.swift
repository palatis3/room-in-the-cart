import CryptoKit
import Foundation

/// Actual cooking is reviewed independently of recipe quantities and timers.
/// A persistent event ID distinguishes an unknown use from explicitly not using an ingredient.
public struct CookCompletionDraft: Codable, Equatable, Sendable, Identifiable {
    public struct Part: Codable, Equatable, Sendable, Identifiable {
        public enum Use: Codable, Equatable, Sendable {
            case notUsed
            case untracked
            case lot(id: UUID, revision: Int64, amount: Quantity?)
        }
        public let id: UUID
        public let contributionID: UUID
        public let use: Use
        public let substitution: String?
        public init(id: UUID = UUID(), contributionID: UUID, use: Use, substitution: String? = nil) {
            self.id = id; self.contributionID = contributionID; self.use = use; self.substitution = substitution
        }
    }

    public struct Leftovers: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let foodID: UUID
        public let name: String
        public let portions: Rational
        public let location: InventoryLocation
        public init(id: UUID = UUID(), foodID: UUID = UUID(), name: String, portions: Rational, location: InventoryLocation) {
            self.id = id; self.foodID = foodID; self.name = name; self.portions = portions; self.location = location
        }
    }

    public let id: UUID
    public let inventoryID: UUID
    public let inventoryRevision: Int64
    public let ledgerID: UUID
    public let shopID: UUID
    public let shopRevision: UUID
    public let meal: MealOccurrence
    /// A pickup replacement keeps the original ledger occurrence for provenance.
    /// Its individual portion needs are the reviewed rows, even when two use the same ingredient.
    public let recoveredMeal: RecoveryMeal?
    /// A removed shopping contribution stays on the occurrence for recipe step indices.
    /// Older and unedited dinners retain the original row list through a missing override.
    private let activeContributionIDs: [UUID]?
    public var ingredientRowIDs: [UUID] { recoveredMeal?.needs.map(\.id) ?? activeContributionIDs ?? meal.ingredientContributionIDs }

    public static func activeIngredientIDs(for meal: MealOccurrence, in shop: ShoppingLedger) -> [UUID] {
        let removed = Set(shop.contributions.lazy.filter {
            $0.source == .meal(occurrenceID: meal.id) && $0.removedAt != nil
        }.map(\.id))
        return meal.ingredientContributionIDs.filter { !removed.contains($0) }
    }

    public var hasValidIngredientSnapshot: Bool {
        guard let activeContributionIDs else { return true }
        let ids = Set(activeContributionIDs)
        return recoveredMeal == nil && activeContributionIDs == meal.ingredientContributionIDs.filter(ids.contains)
    }
    public var cookedTitle: String { recoveredMeal?.title ?? meal.title }
    public let preferenceRevision: UUID?
    public var unresolvedUseIDs: [UUID] {
        parts.compactMap { part in
            switch part.use {
            case .untracked, .lot(_, _, nil): return part.id
            default: return nil
            }
        }
    }
    public let cookedAt: Date
    public var servingsMade: Rational
    public var parts: [Part]
    public var leftovers: [Leftovers]

    public init(id: UUID = UUID(), inventoryID: UUID, inventoryRevision: Int64, ledgerID: UUID, shop: ShoppingLedger,
                meal: MealOccurrence, cookedAt: Date, servingsMade: Rational, parts: [Part], leftovers: [Leftovers], preferenceRevision: UUID? = nil, recoveredMeal: RecoveryMeal? = nil) {
        self.recoveredMeal = recoveredMeal
        let active = Self.activeIngredientIDs(for: meal, in: shop)
        activeContributionIDs = recoveredMeal == nil && active != meal.ingredientContributionIDs ? active : nil
        self.preferenceRevision = preferenceRevision
        self.id = id; self.inventoryID = inventoryID; self.inventoryRevision = inventoryRevision; self.ledgerID = ledgerID
        shopID = shop.id; shopRevision = shop.revisionID; self.meal = meal; self.cookedAt = cookedAt
        self.servingsMade = servingsMade; self.parts = parts; self.leftovers = leftovers
    }

    /// Stable, separate event and observation identities across retries of this one meal operation.
    fileprivate func derived(_ kind: String, for lot: UUID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("ritc.cook.v1/\(id)/\(kind)/\(lot)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum CookCompletion {
    public struct Review: Equatable, Sendable {
        public let draft: CookCompletionDraft
        public let changes: [InventoryPreparedChange]
        public let reservations: [InventoryReservation]
        public let unresolvedUseIDs: [UUID]
        public let affectedHolds: [InventoryReservationCoverage]
        public let availability: InventoryProjection
        public var needsInventoryReview: Bool { !unresolvedUseIDs.isEmpty }
    }

    private struct UsedLot {
        var measured = Rational.zero
        var unmeasured = false
    }

    /// The caller resolves meal-owned reservations from the current source ledger
    /// and pantry mapping. A draft cannot designate someone else's reservation.
    public static func review(_ draft: CookCompletionDraft, inventoryID: UUID, inventoryRevision: Int64,
                              ledgerID: UUID, shop: ShoppingLedger, lots: [InventoryLot], reservations: [InventoryReservation],
                              mealClaims: [UUID: Set<UUID>], at now: Date, recoveredMeal: RecoveryMeal? = nil) throws -> Review {
        guard draft.inventoryID == inventoryID, draft.inventoryRevision == inventoryRevision, draft.ledgerID == ledgerID,
              draft.shopID == shop.id, draft.shopRevision == shop.revisionID, draft.meal.removedAt == nil,
              shop.mealOccurrences.contains(draft.meal), draft.hasValidIngredientSnapshot, draft.recoveredMeal == recoveredMeal,
              recoveredMeal.map({ $0.id == draft.meal.id }) ?? true else { throw InventoryError.stale }
        guard draft.servingsMade > .zero, draft.cookedAt.timeIntervalSinceReferenceDate.isFinite, draft.cookedAt <= now,
              draft.parts.count <= 500, draft.leftovers.count <= 20 else { throw InventoryError.invalid("cookAmounts") }
        let rows = Dictionary(grouping: draft.parts, by: \.contributionID)
        let orderedIngredients = draft.ingredientRowIDs
        let ingredients = Set(orderedIngredients)
        if recoveredMeal == nil {
            let live = shop.contributions.filter { ingredients.contains($0.id) && $0.removedAt == nil &&
                $0.source == .meal(occurrenceID: draft.meal.id) }
            guard orderedIngredients == CookCompletionDraft.activeIngredientIDs(for: draft.meal, in: shop),
                  live.count == ingredients.count else { throw InventoryError.stale }
        }
        guard Set(rows.keys) == ingredients, Set(draft.parts.map(\.id)).count == draft.parts.count,
              Set(draft.leftovers.map(\.id)).count == draft.leftovers.count,
              Set(mealClaims.keys).isSubset(of: ingredients), ingredients.count == orderedIngredients.count
        else { throw InventoryError.invalid("cookIngredients") }
        let before = try InventoryProjection.build(originID: inventoryID, lots: lots, reservations: reservations, at: now)
        let stock = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        let balances = Dictionary(uniqueKeysWithValues: before.lots.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: reservations.map { ($0.id, $0) })
        let supportedClaims = Set(before.reservations.filter { !$0.unresolved }.map(\.id))
        let owned = mealClaims.values.flatMap { $0 }
        guard Set(owned).count == owned.count, owned.allSatisfy({ claims[$0]?.personal == nil && claims[$0] != nil }) else {
            throw InventoryError.invalid("cookReservationBinding")
        }
        var uses: [UUID: UsedLot] = [:], fulfilled: [UUID: Rational] = [:], credited: [UUID: Rational] = [:]
        var unresolved: [UUID] = []
        for ingredient in orderedIngredients {
            let entries = rows[ingredient] ?? []
            var perLot: [UUID: Rational] = [:]
            for part in entries {
                if let substitution = part.substitution { try ledgerText(substitution, nonempty: true, maximum: 512) }
                switch part.use {
                case .notUsed:
                    guard entries.count == 1, part.substitution == nil else { throw InventoryError.invalid("cookNotUsed") }
                case .untracked: unresolved.append(part.id)
                case .lot(let id, let revision, let amount):
                    guard let lot = stock[id], lot.revision == revision, lot.updatedAt <= draft.cookedAt else { throw InventoryError.stale }
                    guard let amount else {
                        uses[id, default: UsedLot()].unmeasured = true
                        unresolved.append(part.id)
                        continue
                    }
                    try amount.validate()
                    guard amount.amount > .zero, let available = lot.count.quantity,
                          let value = try amount.converted(to: lot.unit, using: amount.confirmedConversion ?? available.confirmedConversion)
                    else { throw InventoryError.invalid("cookCountOrConversion") }
                    uses[id, default: UsedLot()].measured = try (uses[id]?.measured ?? .zero).adding(value)
                    perLot[id] = try (perLot[id] ?? .zero).adding(value)
                }
            }
            let eligible = (mealClaims[ingredient] ?? []).intersection(supportedClaims)
            for edge in before.allocations where eligible.contains(edge.needID) {
                guard let lot = stock[edge.lotID], let claim = claims[edge.needID], let requested = claim.amount,
                      let used = perLot[lot.id], used > .zero else { continue }
                let allocation = Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description)
                guard let inLot = try allocation.converted(to: lot.unit, using: lot.count.quantity?.confirmedConversion) else {
                    throw InventoryError.invalid("cookReservationConversion")
                }
                let credit = min(used, inLot)
                let portion = Quantity(amount: credit, unit: lot.unit, originalLiteral: credit.description)
                guard let inClaim = try portion.converted(to: requested.unit, using: lot.count.quantity?.confirmedConversion ?? requested.confirmedConversion)
                else { throw InventoryError.invalid("cookReservationConversion") }
                perLot[lot.id] = try used.subtracting(credit)
                credited[lot.id] = try (credited[lot.id] ?? .zero).adding(credit)
                fulfilled[claim.id] = try (fulfilled[claim.id] ?? .zero).adding(inClaim)
            }
        }
        var changes: [InventoryPreparedChange] = []
        for id in uses.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let use = uses[id], let lot = stock[id] else { throw InventoryError.stale }
            var count = InventoryCount.unknown
            if use.measured > .zero {
                guard let quantity = lot.count.quantity, let free = balances[id]?.free,
                      use.measured <= (try free.amount.adding(credited[id] ?? .zero)) else {
                    throw InventoryError.invalid("cookUseExceedsAvailable")
                }
                let left = try quantity.amount.subtracting(use.measured)
                count = .exact(Quantity(amount: left, unit: lot.unit, originalLiteral: left.description, confirmedConversion: quantity.confirmedConversion))
            }
            if use.unmeasured { count = .unknown }
            let command = InventoryCommand(id: draft.id, originID: inventoryID, lotID: id, eventID: draft.derived("event", for: id),
                expectedRevision: lot.revision, occurredAt: draft.cookedAt, change: .count(count, observationID: draft.derived("observation", for: id)))
            changes.append(try InventoryEngine.prepare(command, current: lot, at: now))
        }
        var total = Rational.zero
        for output in draft.leftovers {
            guard stock[output.id] == nil, output.portions > .zero else { throw InventoryError.invalid("cookedOutput") }
            total = try total.adding(output.portions)
            guard total <= draft.servingsMade else { throw InventoryError.invalid("cookedPortions") }
            let amount = Quantity(amount: output.portions, unit: .count, originalLiteral: output.portions.description)
            let seed = InventoryLotSeed(foodID: output.foodID, name: output.name, source: .manual(originID: inventoryID, sourceID: output.id),
                location: output.location, unit: .count, count: .exact(amount))
            let command = InventoryCommand(id: draft.id, originID: inventoryID, lotID: output.id, eventID: draft.derived("event", for: output.id),
                expectedRevision: nil, occurredAt: draft.cookedAt, change: .create(seed, observationID: draft.derived("observation", for: output.id)))
            changes.append(try InventoryEngine.prepare(command, current: nil, at: now))
        }
        var changedClaims: [InventoryReservation] = []
        for claim in reservations {
            guard let spent = fulfilled[claim.id], let need = claim.amount, spent > .zero else { continue }
            guard claim.revision < Int64.max else { throw DomainError.overflow }
            let left = try need.amount.subtracting(spent)
            let amount = left == .zero ? need : Quantity(amount: left, unit: need.unit, originalLiteral: left.description, confirmedConversion: need.confirmedConversion)
            changedClaims.append(.init(id: claim.id, originID: inventoryID, revision: claim.revision + 1, foodID: claim.foodID, lotID: claim.lotID,
                name: claim.name, amount: amount, priority: claim.priority, state: left == .zero ? .released : .active))
        }
        let changedLotIDs = Set(changes.map(\.lot.id)), changedClaimIDs = Set(changedClaims.map(\.id))
        let after = try InventoryProjection.build(originID: inventoryID, lots: lots.filter { !changedLotIDs.contains($0.id) } + changes.map(\.lot),
            reservations: reservations.filter { !changedClaimIDs.contains($0.id) } + changedClaims, at: now)
        let original = Dictionary(uniqueKeysWithValues: before.reservations.map { ($0.id, $0) })
        let affected = after.reservations.filter { !changedClaimIDs.contains($0.id) && $0 != original[$0.id] }
        return Review(draft: draft, changes: changes, reservations: changedClaims, unresolvedUseIDs: unresolved,
                      affectedHolds: affected, availability: after)
    }
}
