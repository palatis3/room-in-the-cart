import CoreDomain
import CryptoKit
import Foundation
import LocalStore

/// The receipt and all stock effects live in one pickup-database transaction.
/// A later correction can inspect the pre-cook counts and the exact observations it created.
struct PantryCookRecord: Codable, Equatable {
    struct BeforeCount: Codable, Equatable {
        let lotID: UUID
        let observationID: UUID
        let count: InventoryCount
        let revision: Int64
    }
    let draft: CookCompletionDraft
    let priorCounts: [BeforeCount]
    let priorClaims: [InventoryReservation]
    /// Original journey need IDs with the amount already consumed by this meal.
    let fulfilledNeeds: [StockNeed]
    let resultingObservations: [UUID: UUID]

    var resolutions: [PantryCookResolution.Receipt]? = nil
    var undo: PantryCookUndoReceipt? = nil
    var isActive: Bool { undo == nil }

    func validate(shopID: UUID) throws {
        let inputs = Set(draft.parts.compactMap { part -> UUID? in
            if case .lot(let id, _, _) = part.use { return id }
            return nil
        })
        let outputs = Set(draft.leftovers.map(\.id))
        guard draft.shopID == shopID, draft.meal.removedAt == nil, draft.hasValidIngredientSnapshot, draft.inventoryRevision >= 0,
              draft.servingsMade > .zero, draft.cookedAt.timeIntervalSinceReferenceDate.isFinite,
              draft.parts.count <= 500, draft.leftovers.count <= 20, Set(draft.parts.map(\.id)).count == draft.parts.count,
              Set(draft.parts.map(\.contributionID)) == Set(draft.ingredientRowIDs),
              draft.recoveredMeal.map({ $0.id == draft.meal.id }) ?? true,
              Set(priorCounts.map(\.lotID)) == inputs, priorCounts.count == inputs.count,
              inputs.isDisjoint(with: outputs), outputs.count == draft.leftovers.count,
              Set(resultingObservations.keys) == inputs.union(outputs),
              Set(resultingObservations.values).count == resultingObservations.count,
              Set(priorClaims.map(\.id)).count == priorClaims.count else { throw PantryCookPort.Failure.changed }
        guard fulfilledNeeds.count == priorClaims.count, Set(fulfilledNeeds.map(\.id)).count == fulfilledNeeds.count,
              fulfilledNeeds.allSatisfy({ $0.amount.amount > .zero }) else { throw PantryCookPort.Failure.changed }
        try validateResolutions()
        if let undo {
            let deductions = (resolutions ?? []).compactMap { row -> UUID? in
                if case .deduct(let id, _) = row.decision { return id }
                return nil
            }
            guard !(resolutions ?? []).contains(where: { $0.decision.action == .recount }),
                  undo.resolvedEventIDs == resolutions?.map(\.eventID),
                  (resolutions ?? []).allSatisfy({ $0.confirmedAt <= undo.confirmedAt }),
                  undo.id != draft.id, undo.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
                  undo.confirmedAt >= draft.cookedAt, Set(undo.observations.keys) == inputs.union(outputs).union(deductions),
                  Set(undo.observations.values).count == undo.observations.count,
                  Set(undo.observations.values).isDisjoint(with: resultingObservations.values),
                  Set(undo.observations.values).isDisjoint(with: (resolutions ?? []).compactMap(\.resultObservationID))
            else { throw PantryCookPort.Failure.changed }
        }
        for output in draft.leftovers { _ = try draft.outputReservations(for: output) }
        for row in priorCounts { try row.count.validate() }
        for row in priorClaims { try row.validate() }
    }
}

@MainActor final class PantryCookSession {
    struct Context {
        let inventory: PantryRepository.Snapshot
        let ledgerID: UUID
        let shop: ShoppingLedger
        let meal: MealOccurrence
        let completedRecord: PantryCookRecord?
        var completed: CookCompletionDraft? { completedRecord?.draft }
        var remainingUnresolvedUseIDs: [UUID] { completedRecord?.remainingUnresolvedUseIDs ?? [] }
        let asOf: Date
        let preferences: MealPreferenceProfile?
        let recovery: PickupRecoveryMealDefinition?

        func matches(_ draft: CookCompletionDraft) -> Bool {
            guard draft.recoveredMeal == recovery?.meal, draft.ledgerID == ledgerID,
                  draft.inventoryID == inventory.state.workspaceID else { return false }
            if draft.recoveredMeal != nil { return draft.meal == meal }
            return draft.meal.matchesIgnoringScheduledDay(meal)
        }
        var title: String { recovery?.meal.title ?? meal.title }
        var servings: Rational { recovery?.meal.servings ?? meal.servings }
        var exclusions: [String] { recovery?.meal.exclusions ?? meal.exclusions }
    }
    let ledger: LedgerModel
    let pickup: PickupModel
    let authorize: @MainActor () -> Bool
    init(ledger: LedgerModel, pickup: PickupModel, authorize: @escaping @MainActor () -> Bool) {
        self.ledger = ledger; self.pickup = pickup; self.authorize = authorize
    }
    func load(shopID: UUID, mealID: UUID) async throws -> Context {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).load(shopID: shopID, mealID: mealID)
    }
    func review(_ draft: CookCompletionDraft) async throws -> CookCompletion.Review {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).review(draft)
    }
    func apply(_ review: CookCompletion.Review) async throws {
        try await pickup.cookCompletionPort(ledger: ledger, authorize: authorize).apply(review)
        if authorize() { await pickup.refreshPantryStock() }
    }
}

private extension MealOccurrence {
    func matchesIgnoringScheduledDay(_ other: Self) -> Bool {
        var rescheduled = self
        rescheduled.scheduledDay = other.scheduledDay
        return rescheduled == other
    }
}

private extension PickupCheckoutMealSource {
    /// Moving a dinner keeps its holds. Match each food to the sealed checkout before
    /// crediting it, so editing or dropping one ingredient cannot spend its old hold.
    func claimableContributions(for meal: MealOccurrence, in live: ShoppingLedger, ledgerID: UUID,
                                planning: DinnerPlanningState) -> Set<UUID> {
        guard ledgerWorkspaceID == ledgerID, shop.id == live.id,
              let sealed = shop.mealOccurrences.first(where: { $0.id == meal.id }),
              sealed.matchesIgnoringScheduledDay(meal) else { return [] }
        let originals = Dictionary(uniqueKeysWithValues: shop.contributions.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: live.contributions.map { ($0.id, $0) })
        let originalLinks = Dictionary(grouping: shop.allocations, by: \.demandContributionID)
        let currentLinks = Dictionary(grouping: live.allocations, by: \.demandContributionID)
        let originalPortions = Dictionary(grouping: bindings, by: \.contributionID)
        let currentPortions = Dictionary(grouping: planning.portionBindings, by: \.contributionID)
        return Set(meal.ingredientContributionIDs.filter { id in
            guard let row = current[id], row.removedAt == nil, row.source == .meal(occurrenceID: meal.id) else { return false }
            return originals[id] == row && originalLinks[id] == currentLinks[id] && originalPortions[id] == currentPortions[id]
        })
    }
}

@MainActor final class PantryCookPort {
    enum Failure: Error, Equatable { case unavailable, changed, alreadyCompleted, capacity }
    let store: ComparisonStore
    let ledger: LedgerStore
    let gate: PantryMutationGate
    private let repository: PantryRepository
    let authorize: () -> Bool
    let clock: () -> Date
    init(store: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate, authorize: @escaping () -> Bool,
         clock: @escaping () -> Date = Date.init) {
        self.store = store; self.ledger = ledger; self.gate = gate; self.authorize = authorize; self.clock = clock
        repository = PantryRepository(store: store, authorize: authorize)
    }

    struct Read {
        let context: PantryCookSession.Context
        let journey: PickupJourney
        let saved: SavedComparison?
        let ledgerRevision: Int64
        let claims: [UUID: Set<UUID>]
        let sourceNeeds: [UUID: StockNeed]
    }
    func read(shopID: UUID, mealID: UUID) async throws -> Read {
        guard authorize(), let ledgerRecord = try await ledger.load(), authorize() else { throw Failure.unavailable }
        let workspace = try LedgerModel.validatePayload(ledgerRecord.payload)
        guard let shop = workspace.shops.first(where: { $0.id == shopID }),
              let meal = shop.mealOccurrences.first(where: { $0.id == mealID && $0.removedAt == nil })
        else { throw Failure.changed }
        let now = clock(), inventory = try await repository.load(at: now)
        let saved = try await store.load(id: shopID)
        guard authorize() else { throw Failure.unavailable }
        let journey: PickupJourney
        if let saved {
            journey = try JSONDecoder().decode(PickupJourney.self, from: saved.payload)
            try PickupModel.validate(journey)
            guard journey.id == shopID, journey.savedAt == saved.savedAt else { throw Failure.changed }
        } else {
            // A ledger-only dinner already belongs to a real shopping plan. Its
            // local cook receipt is created only when the shopper commits.
            journey = PickupJourney(id: shopID, savedAt: now)
        }
        let recovery: PickupRecoveryMealDefinition?
        if let history = journey.mealRecovery, history.domain.events.contains(where: { $0.request.target.id == mealID }) {
            guard history.source.ledgerWorkspaceID == ledger.workspaceID,
                  let sealed = history.source.shop.mealOccurrences.first(where: { $0.id == mealID }),
                  let calendar = history.ledgerCalendarBasis.first(where: { $0.occurrenceID == mealID }),
                  calendar.day == meal.scheduledDay,
                  let current = try history.definition(for: mealID) else { throw Failure.changed }
            var compared = meal
            compared.scheduledDay = sealed.scheduledDay
            guard compared == sealed else { throw Failure.changed }
            recovery = current
        } else { recovery = nil }
        let completedRecord = journey.cookedMeals?.first { $0.isActive && $0.draft.meal.id == mealID }
        let context = PantryCookSession.Context(inventory: inventory, ledgerID: ledger.workspaceID, shop: shop, meal: meal,
            completedRecord: completedRecord, asOf: now, preferences: workspace.dinnerPlanning.privateMealPreferences, recovery: recovery)
        var owned: [UUID: Set<UUID>] = [:]
        var sourceNeeds: [UUID: StockNeed] = [:]
        let originalContributions = journey.mealSource?.claimableContributions(for: meal, in: shop, ledgerID: ledger.workspaceID,
                                                                               planning: workspace.dinnerPlanning) ?? []
        if recovery != nil || !originalContributions.isEmpty {
            let sources = try await store.list().map(PantryLegacyMigration.SourceHead.init)
            guard authorize() else { throw Failure.unavailable }
            let plan = try PantryLegacyMigration.map(originID: store.workspaceID, heads: sources,
                ledger: .available(originID: ledger.workspaceID, revision: ledgerRecord.revision, workspace: workspace), at: now)
            let exclusive = Set(plan.claimLinks.filter { $0.journeyIDs == [shopID] }.map(\.reservationID))
            let needs = Dictionary(uniqueKeysWithValues: try journey.remainingPhysicalNeeds().map { ($0.id, $0) })
            let bindings: [(UUID, UUID)]
            if let recovery {
                bindings = recovery.meal.ingredients.map { ($0.need.id, $0.need.id) }
            } else {
                bindings = journey.needDetails.compactMap { detail in
                    guard detail.sourceOccurrenceID == mealID, let row = detail.sourceContributionID,
                          originalContributions.contains(row) else { return nil }
                    return (row, detail.id)
                }
            }
            for (contribution, needID) in bindings {
                guard let need = needs[needID], need.priority != .protected else { continue }
                let id = try PantryLegacyMigration.claimIdentity(originID: store.workspaceID, needID: need.id, foodID: need.foodID)
                if exclusive.contains(id), inventory.reservations.contains(where: { $0.id == id && $0.foodID == need.foodID && $0.state == .active }) {
                    owned[contribution, default: []].insert(id)
                    sourceNeeds[id] = need
                }
            }
        }
        return Read(context: context, journey: journey, saved: saved, ledgerRevision: ledgerRecord.revision, claims: owned, sourceNeeds: sourceNeeds)
    }
    func load(shopID: UUID, mealID: UUID) async throws -> PantryCookSession.Context {
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        return try await read(shopID: shopID, mealID: mealID).context
    }
    private func compute(_ draft: CookCompletionDraft, from read: Read) throws -> CookCompletion.Review {
        let context = read.context
        guard context.completed == nil else { throw Failure.alreadyCompleted }
        guard draft.preferenceRevision == context.preferences?.revision else { throw Failure.changed }
        if context.recovery != nil {
            guard let event = read.journey.mealRecovery?.domain.events.last(where: { $0.request.target.id == draft.meal.id }),
                  event.appliedAt <= draft.cookedAt else { throw Failure.changed }
        }
        return try CookCompletion.review(draft, inventoryID: context.inventory.state.workspaceID, inventoryRevision: context.inventory.state.revision,
            ledgerID: context.ledgerID, shop: context.shop, lots: context.inventory.lots, reservations: context.inventory.reservations,
            mealClaims: read.claims, at: context.asOf, recoveredMeal: context.recovery?.meal)
    }
    func review(_ draft: CookCompletionDraft) async throws -> CookCompletion.Review {
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        return try await compute(draft, from: read(shopID: draft.shopID, mealID: draft.meal.id))
    }
    func apply(_ reviewed: CookCompletion.Review) async throws {
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let draft = reviewed.draft
        guard authorize(), draft.ledgerID == ledger.workspaceID, draft.inventoryID == store.workspaceID else { throw Failure.unavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = Data("cook-completion/v1/".utf8)
        request.append(contentsOf: SHA256.hash(data: try encoder.encode(draft)))
        if try await store.inventoryCommittedOperation(id: draft.id, request: request) != nil {
            guard authorize() else { throw Failure.unavailable }
            return
        }
        let read = try await read(shopID: draft.shopID, mealID: draft.meal.id)
        let actual = try compute(draft, from: read)
        guard actual == reviewed else { throw Failure.changed }
        let inventory = read.context.inventory
        let usedLots = Set(actual.changes.compactMap { $0.command.expectedRevision == nil ? nil : $0.lot.id })
        let changedClaims = Set(actual.reservations.map(\.id))
        let priorClaims = inventory.reservations.filter { changedClaims.contains($0.id) }
        let fulfilled = try actual.reservations.map { updated -> StockNeed in
            guard let original = priorClaims.first(where: { $0.id == updated.id })?.amount,
                  let remainder = updated.amount, let need = read.sourceNeeds[updated.id] else { throw Failure.changed }
            let spent = updated.state == .released ? original.amount : try original.amount.subtracting(remainder.amount)
            let value = Quantity(amount: spent, unit: original.unit, originalLiteral: spent.description, confirmedConversion: original.confirmedConversion)
            return StockNeed(id: need.id, foodID: need.foodID, name: need.name, amount: value, priority: need.priority)
        }
        let saved = PantryCookRecord(draft: draft, priorCounts: inventory.lots.filter { usedLots.contains($0.id) }.map {
            .init(lotID: $0.id, observationID: $0.observationID, count: $0.count, revision: $0.revision)
        }, priorClaims: priorClaims, fulfilledNeeds: fulfilled,
            resultingObservations: Dictionary(uniqueKeysWithValues: actual.changes.map { ($0.lot.id, $0.lot.observationID) }))
        var next = read.journey
        next.cookedMeals = (next.cookedMeals ?? []) + [saved]
        var writes = try actual.changes.flatMap(PantryPersistenceCodec.writes)
        writes += try (actual.reservations + actual.outputReservations).map { try PantryPersistenceCodec.write($0, expectedRevision: $0.revision - 1) }
        try await persist(next, read: read, writes: writes, request: request, operationID: draft.id)
    }

    func persist(_ journey: PickupJourney, read: Read, writes: [InventoryWrite], request: Data, operationID: UUID) async throws {
        var next = journey
        guard next.revision < Int64.max else { throw Failure.capacity }
        next.revision += 1
        next.savedAt = read.context.asOf
        try PickupModel.validate(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(next)
        guard payload.count <= ComparisonStore.maximumPayloadBytes else { throw Failure.capacity }
        let inventory = read.context.inventory
        try repository.validateCapacity(of: writes, replacing: inventory)
        let effect = InventoryComparisonEffect(action: .save, id: next.id, expectedRevision: read.saved?.revision ?? 0,
            title: read.saved?.title ?? read.context.shop.title, payload: payload)
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: operationID, expectedRevision: inventory.state.revision,
            request: request, writes: writes, comparisons: [effect])
        guard try await ledger.load()?.revision == read.ledgerRevision, authorize() else { throw Failure.changed }
        _ = try await store.commitInventory(batch, at: next.savedAt)
        guard authorize() else { throw Failure.unavailable }
    }
}

extension PantryRepository {
    /// Cook corrections and undo live on the latest journey head. Its original ingredient
    /// part is the use, even when a later correction identifies the batch or amount.
    func cookUsageHistory(lotID: UUID, basis: InventoryState) async throws -> [PantryUsageHistoryRow] {
        try requireAccess()
        let source = try await store.inventorySourceToken()
        try requireAccess()
        guard basis.active, basis.workspaceID == originID, source.workspaceID == originID else { throw Failure.wrongWorkspace }
        var cursor: UUID?
        var bytes = 0
        var heads = 0
        var rows = [PantryUsageHistoryRow]()
        let pageSize = 8
        repeat {
            let page = try await store.inventorySourcePage(token: source, after: cursor, limit: pageSize)
            try requireAccess()
            for head in page {
                heads += 1
                bytes += head.payload.count
                guard heads <= PantryLegacyMigration.maximumHeads, bytes <= limits.payloadBytes else { throw InventoryError.capacity }
                let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
                guard journey.id == head.id, journey.savedAt == head.savedAt else { throw Failure.invalidProvenance }
                try PickupModel.validate(journey)
                for cook in journey.cookedMeals ?? [] where cook.isActive {
                    guard cook.draft.inventoryID == originID, cook.draft.inventoryRevision < basis.revision,
                          cook.resolutions?.last.map({ $0.inventoryRevision < basis.revision }) ?? true
                    else { throw Failure.invalidProvenance }
                    rows += try cook.usageHistory(for: lotID)
                }
            }
            cursor = page.count == pageSize ? page.last?.id : nil
        } while cursor != nil
        let current = try await store.inventorySourceToken()
        try requireAccess()
        guard current == source else { throw PantryConsumptionFailure.stale }
        return rows
    }
}

extension PantryCookRecord {
    func usageHistory(for lotID: UUID) throws -> [PantryUsageHistoryRow] {
        let amendments = Dictionary(uniqueKeysWithValues: (resolutions ?? []).map { ($0.eventID, $0.decision) })
        return try draft.parts.compactMap { part in
            let used: Quantity?
            if let decision = amendments[part.id] {
                guard decision.lotID == lotID else { return nil }
                switch decision {
                case .alreadyIncluded(_, let amount), .recount(_, _, let amount): used = amount
                case .deduct(_, let amount): used = amount
                case .outsidePantry: return nil
                }
            } else {
                guard case .lot(let id, _, let amount) = part.use, id == lotID else { return nil }
                used = amount
            }
            if let used {
                try used.validate()
                guard used.amount > .zero else { throw PantryRepository.Failure.invalidProvenance }
            }
            return .init(id: part.id, occurredAt: draft.cookedAt, kind: used.map(InventoryUsage.Kind.measured) ?? .some,
                         remainingWording: nil)
        }
    }
}
