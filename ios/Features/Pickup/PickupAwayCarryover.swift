import Foundation
import Combine
import CryptoKit
import CoreDomain

enum AwayCarryoverSupply: Codable, Equatable, Identifiable {
    case batch(ConfirmedStockLot)
    case received(ReceiptFragment, UsableObservation)
    var id: UUID { switch self { case .batch(let lot): return lot.id; case .received(_, let observation): return observation.id } }
    var foodID: UUID { switch self { case .batch(let lot): return lot.foodID; case .received(let receipt, _): return receipt.key.orderLineID } }
    var name: String { switch self { case .batch(let lot): return lot.name; case .received(let receipt, _): return receipt.itemName } }
    var quantity: Quantity { switch self { case .batch(let lot): return lot.usable; case .received(_, let observation): return observation.usable } }
    var observedAt: Date { switch self { case .batch(let lot): return lot.confirmedAt; case .received(_, let observation): return observation.confirmedAt } }
    func currentID(in journey: PickupJourney) -> UUID? {
        switch self {
        case .batch(let lot): return journey.stockLots.first { $0.id == lot.id }?.id
        case .received(let receipt, _):
            return journey.pickup?.usableObservations.last { $0.receipt == receipt.key && $0.confirmedMatchToOrderLine }?.id
        }
    }
    func matches(_ journey: PickupJourney) -> Bool {
        switch self {
        case .batch(let lot): return journey.stockLots.first { $0.id == lot.id } == lot
        case .received(let receipt, let observation):
            return journey.pickup?.receipts.contains(receipt) == true && journey.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }) == observation
        }
    }
}
struct AwayCarryoverIntent: Codable, Equatable, Identifiable {
    var id: UUID { plan.link.operationID }
    let workspaceID: UUID
    let actorID: String
    let pickupRevision: Int64
    let planningRevisionID: UUID
    let sourceNeed: AllocationNeed
    let supply: AwayCarryoverSupply
    let counted: Quantity
    let plan: DinnerCarryoverPlan
    var recoveryRevision: UUID? = nil
    var canonical: PantryAwayCarryoverBinding? = nil
}
struct AwayCarryoverRecord: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case prepared, reserved, completed, cancelled }
    var id: UUID { intent.id }
    let intent: AwayCarryoverIntent
    var phase: Phase
}
enum AwayCarryoverError: Error { case stale, invalid, overlap, insufficient, authority, pending }

enum AwayCarryoverEngine {
    static func targetID(_ operation: UUID, _ role: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("room-in-the-cart/physical-carryover/v1/\(operation.uuidString)/\(role)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func sourceNeeds(_ meal: MealOccurrence, in journey: PickupJourney) -> [AllocationNeed] {
        if let history = journey.mealRecovery {
            guard let projection = try? MealRecoveryEngine.project(history.domain),
                  let current = projection.meals.first(where: { $0.id == meal.id }) else { return [] }
            let ingredientIDs = Set(current.needs.map(\.id))
            return projection.demands.filter { ingredientIDs.contains($0.id) && $0.priority != .protected }.map {
                AllocationNeed(id: $0.id, orderLineID: $0.foodID, name: $0.name, amount: $0.amount, priority: $0.priority)
            }
        }
        return journey.needs.filter { need in
            need.priority != .protected && need.amount.amount > .zero && (
                meal.ingredientContributionIDs.contains(need.id) ||
                journey.needDetails.first(where: { $0.id == need.id })?.sourceContributionID.map(meal.ingredientContributionIDs.contains) == true)
        }
    }
    static func currentMeal(_ purchased: MealOccurrence, in journey: PickupJourney) throws -> MealOccurrence {
        guard let history = journey.mealRecovery,
              history.domain.events.contains(where: { $0.request.target.id == purchased.id }) else { return purchased }
        guard let current = try history.definition(for: purchased.id),
              let basis = history.ledgerCalendarBasis.first(where: { $0.occurrenceID == purchased.id }),
              purchased.scheduledDay == basis.day,
              var checked = history.source.shop.mealOccurrences.first(where: { $0.id == purchased.id }) else { throw AwayCarryoverError.stale }
        checked.scheduledDay = basis.day
        guard checked == purchased else { throw AwayCarryoverError.stale }
        return purchased.carryoverSource(meal: current.meal, notes: current.notes, sourceURL: current.sourceURL,
            evidence: current.acceptedTemplate?.sourceEvidence, groups: current.groups)
    }

    static func transferRequest(_ intent: AwayCarryoverIntent, base: UUID) -> MealRecoveryContextRequest {
        let need = intent.sourceNeed
        let source = StockNeed(id: need.id, foodID: need.orderLineID, name: need.name, amount: need.amount, priority: need.priority)
        return .init(id: intent.id, shopID: intent.plan.link.sourceShopID, baseRevisionID: base,
            revisionID: targetID(intent.id, "recovery-context"),
            change: .transferCarryover(occurrenceID: intent.plan.source.id, source: source, reservation: targetNeed(intent)),
            reviewedAt: intent.plan.link.observedAt)
    }

    static func supplies(for need: AllocationNeed, in journey: PickupJourney) -> [AwayCarryoverSupply] {
        var result = journey.stockLots.filter { $0.foodID == need.orderLineID && $0.source != .manual && $0.usable.amount > .zero }.map(AwayCarryoverSupply.batch)
        for receipt in journey.pickup?.receipts ?? [] where receipt.key.orderLineID == need.orderLineID {
            if let observation = journey.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }),
               observation.confirmedMatchToOrderLine, observation.usable.amount > .zero {
                result.append(.received(receipt, observation))
            }
        }
        return result
    }
    static func reducedNeed(_ intent: AwayCarryoverIntent) throws -> AllocationNeed {
        let original = intent.sourceNeed
        guard let moved = try intent.plan.link.quantity.converted(to: original.amount.unit) else { throw AwayCarryoverError.invalid }
        let remainder = try original.amount.amount.subtracting(moved)
        return AllocationNeed(id: original.id, orderLineID: original.orderLineID, name: original.name,
            amount: Quantity(amount: remainder, unit: original.amount.unit, originalLiteral: remainder.description,
                confirmedConversion: original.amount.confirmedConversion), priority: original.priority)
    }
    static func targetNeed(_ intent: AwayCarryoverIntent) -> StockNeed {
        StockNeed(id: intent.plan.link.reservationID, foodID: intent.sourceNeed.orderLineID,
            name: intent.plan.source.title, amount: intent.plan.link.quantity, priority: .required)
    }
    static func validate(_ intent: AwayCarryoverIntent) throws {
        try intent.plan.validate()
        try intent.canonical?.validate(for: intent)
        let link = intent.plan.link
        // A canonical recount reviews today's physical head. A qualitative count
        // supplies no numeric ceiling; only the newly checked amount is proposed.
        // The legacy path retains its historical remaining-quantity ceiling.
        let recount = intent.canonical?.recountsPhysicalSource == true
        let countUnit = recount ? intent.canonical!.lot.unit : intent.supply.quantity.unit
        let ceiling: Quantity?
        if recount { ceiling = intent.canonical!.lot.count.quantity }
        else { ceiling = intent.supply.quantity }
        guard !intent.actorID.isEmpty, intent.pickupRevision >= 0, intent.sourceNeed.priority != .protected,
              intent.supply.foodID == intent.sourceNeed.orderLineID, link.sourceNeedID == intent.sourceNeed.id,
              link.sourceSupplyID == intent.supply.id, intent.counted.amount > .zero,
              intent.plan.occurrenceID == targetID(intent.id, "dinner"), intent.plan.revisionID == targetID(intent.id, "ledger-revision"),
              link.reservationID == targetID(intent.id, "reservation"),
              link.observedAt >= intent.supply.observedAt,
              let originalDay = intent.plan.source.scheduledDay,
              intent.plan.day.timeZoneIdentifier == originalDay.timeZoneIdentifier,
              intent.plan.day.iso8601 > originalDay.iso8601,
              intent.plan.day.iso8601 >= (try MealDay(date: link.observedAt, timeZoneIdentifier: intent.plan.day.timeZoneIdentifier)).iso8601,
              let count = try intent.counted.converted(to: countUnit), ceiling.map({ count <= $0.amount }) ?? true,
              let reserved = try link.quantity.converted(to: intent.sourceNeed.amount.unit), reserved > .zero,
              reserved <= intent.sourceNeed.amount.amount else { throw AwayCarryoverError.invalid }
        switch intent.supply {
        case .batch(let lot): guard lot.source != .manual, link.confirmedSupplyID == lot.id else { throw AwayCarryoverError.invalid }
        case .received(let receipt, let observation):
            guard observation.confirmedMatchToOrderLine, observation.receipt == receipt.key,
                  link.confirmedSupplyID == (recount ? observation.id : targetID(intent.id, "physical-observation")) else { throw AwayCarryoverError.invalid }
        }
    }
    /// Reconciles the original sealed result by content, not a global revision.
    /// Unrelated settlement or other-lot writes do not change these identities.
    static func assertTransferred(_ intent: AwayCarryoverIntent, in value: PickupJourney, at instant: Date) throws {
        try validate(intent)
        guard intent.plan.link.observedAt <= instant else { throw AwayCarryoverError.invalid }
        guard value.id == intent.plan.link.sourceShopID,
              value.awayCarryovers.first(where: { $0.id == intent.id }) == AwayCarryoverRecord(intent: intent, phase: .reserved),
              value.stockNeeds.first(where: { $0.id == intent.plan.link.reservationID }) == targetNeed(intent) else { throw AwayCarryoverError.stale }
        if let base = intent.recoveryRevision {
            guard value.mealRecovery?.domain.contextChanges.first(where: { $0.id == intent.id })?.request == transferRequest(intent, base: base) else {
                throw AwayCarryoverError.stale
            }
        } else {
            guard value.needs.first(where: { $0.id == intent.sourceNeed.id }) == (try reducedNeed(intent)) else { throw AwayCarryoverError.stale }
        }
    }
    static func assertReserved(_ intent: AwayCarryoverIntent, in value: PickupJourney, at instant: Date) throws {
        try assertTransferred(intent, in: value, at: instant)
        switch intent.supply {
        case .batch(let lot):
            let expected = ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name, usable: intent.counted,
                confirmedAt: intent.plan.link.observedAt, source: lot.source, useFirst: lot.useFirst == true)
            guard value.stockLots.first(where: { $0.id == lot.id }) == expected else { throw AwayCarryoverError.stale }
        case .received(let receipt, let observation):
            let expected = UsableObservation(id: intent.plan.link.confirmedSupplyID, receipt: receipt.key, usable: intent.counted,
                confirmedAt: intent.plan.link.observedAt, supersedesID: observation.id, confirmedMatchToOrderLine: true)
            guard value.pickup?.receipts.contains(receipt) == true,
                  value.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }) == expected else { throw AwayCarryoverError.stale }
        }
        guard try value.carryoverAllocation(at: instant).demands.first(where: { $0.id == intent.plan.link.reservationID })?.shortfall == .zero else { throw AwayCarryoverError.insufficient }
    }
    /// Recounts an existing identity and transfers one eligible demand quantity.
    /// Original purchase facts and protected demands are never changed.
    static func reserving(_ intent: AwayCarryoverIntent, in original: PickupJourney, at instant: Date) throws -> PickupJourney {
        try reservingSource(intent, in: original, at: instant, checkLegacyAllocation: true)
    }
    /// The canonical adapter must prove the complete resulting graph before save.
    static func reservingCanonicalSource(_ intent: AwayCarryoverIntent, in original: PickupJourney, at instant: Date) throws -> PickupJourney {
        try reservingSource(intent, in: original, at: instant, checkLegacyAllocation: false)
    }
    private static func reservingSource(_ intent: AwayCarryoverIntent, in original: PickupJourney, at instant: Date,
                                        checkLegacyAllocation: Bool) throws -> PickupJourney {
        try validate(intent)
        guard intent.plan.link.observedAt <= instant else { throw AwayCarryoverError.invalid }
        guard original.id == intent.plan.link.sourceShopID, original.pickup != nil,
              sourceNeeds(intent.plan.purchasedSource ?? intent.plan.source, in: original).contains(intent.sourceNeed),
              try currentMeal(intent.plan.purchasedSource ?? intent.plan.source, in: original) == intent.plan.source,
              intent.supply.matches(original),
              !original.stockNeeds.contains(where: { $0.id == intent.plan.link.reservationID }) else { throw AwayCarryoverError.stale }
        var value = original
        switch intent.supply {
        case .batch(let lot):
            guard let index = value.stockLots.firstIndex(where: { $0.id == lot.id }) else { throw AwayCarryoverError.stale }
            value.stockLots[index] = ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name, usable: intent.counted,
                confirmedAt: intent.plan.link.observedAt, source: lot.source, useFirst: lot.useFirst == true)
        case .received(let receipt, let observation):
            // Canonical recounts are independent pantry observations. Keep the
            // original received/usable facts intact, including their quantity cap.
            guard checkLegacyAllocation else { break }
            let corrected = UsableObservation(id: intent.plan.link.confirmedSupplyID, receipt: receipt.key, usable: intent.counted,
                confirmedAt: intent.plan.link.observedAt, supersedesID: observation.id, confirmedMatchToOrderLine: true)
            guard var pickup = value.pickup else { throw AwayCarryoverError.invalid }
            try pickup.confirmUsable(corrected)
            value.pickup = pickup
        }
        if var history = value.mealRecovery {
            guard let base = intent.recoveryRevision else { throw AwayCarryoverError.stale }
            let request = transferRequest(intent, base: base)
            let review = try MealRecoveryEngine.previewContext(request, in: history.domain, at: instant)
            try MealRecoveryEngine.applyContext(review, to: &history.domain, at: instant)
            value.mealRecovery = history
        } else {
            guard intent.recoveryRevision == nil, let index = value.needs.firstIndex(where: { $0.id == intent.sourceNeed.id }) else {
                throw AwayCarryoverError.stale
            }
            value.needs[index] = try reducedNeed(intent)
        }
        value.stockNeeds.append(targetNeed(intent))
        if let record = value.awayCarryovers.firstIndex(where: { $0.id == intent.id }) { value.awayCarryovers[record].phase = .reserved }
        else { value.awayCarryovers.append(AwayCarryoverRecord(intent: intent, phase: .reserved)) }
        guard checkLegacyAllocation else { return value }
        let before = try original.carryoverAllocation(at: instant), after = try value.carryoverAllocation(at: instant)
        guard after.demands.first(where: { $0.id == intent.plan.link.reservationID })?.shortfall == .zero else { throw AwayCarryoverError.insufficient }
        for demand in before.demands where demand.foodID == intent.sourceNeed.orderLineID && demand.id != intent.sourceNeed.id {
            guard let previous = demand.allocated, let next = after.demands.first(where: { $0.id == demand.id })?.allocated,
                  next >= previous else { throw AwayCarryoverError.insufficient }
        }
        return value
    }
}

extension PickupJourney {
    var carryoverStockReservations: [ConfirmedStockReservation] {
        awayCarryovers.filter { $0.phase == .reserved || $0.phase == .completed }.map {
            ConfirmedStockReservation(needID: $0.intent.plan.link.reservationID,
                lotID: $0.intent.supply.currentID(in: self) ?? $0.intent.plan.link.confirmedSupplyID)
        }
    }
    var confirmedPhysicalLots: [ConfirmedStockLot] { physicalLots(at: nil) }
    private func physicalLots(at instant: Date?) -> [ConfirmedStockLot] {
        var lots = instant.map { at in stockLots.filter { $0.confirmedAt <= at } } ?? stockLots
        for receipt in pickup?.receipts ?? [] {
            if let instant, receipt.receivedAt > instant { continue }
            guard let observation = pickup?.usableObservations.last(where: { $0.receipt == receipt.key }),
                  observation.confirmedMatchToOrderLine else { continue }
            // Do not resurrect a superseded usable amount when the latest
            // observation is not yet current. Keep the original history intact.
            if let instant, observation.confirmedAt > instant { continue }
            lots.append(ConfirmedStockLot(id: observation.id, foodID: receipt.key.orderLineID, name: receipt.itemName,
                usable: observation.usable, confirmedAt: observation.confirmedAt))
        }
        return lots
    }
    var physicalStockNeeds: [StockNeed] {
        guard let history = mealRecovery else { return rawPhysicalStockNeeds }
        // Validated persisted histories always project. Invalid transient data must
        // not fall back to superseded original demands and claim their coverage.
        return (try? MealRecoveryEngine.project(history.domain).demands) ?? []
    }
    /// Omit the instant only for structural/history validation. Live projections
    /// and business decisions supply their injected clock.
    func carryoverAllocation(at instant: Date? = nil) throws -> StockAllocationResult {
        if let history = mealRecovery { try history.validate(); try validateRecoveryRawBasis(history) }
        return try ConfirmedCarryoverAllocator.allocate(lots: physicalLots(at: instant), needs: physicalStockNeeds, reservations: carryoverStockReservations)
    }
    func validateAwayCarryovers() throws {
        guard awayCarryovers.count <= 1_000, Set(awayCarryovers.map(\.id)).count == awayCarryovers.count,
              awayCarryovers.filter({ $0.phase == .prepared || $0.phase == .reserved }).count <= 1 else { throw AwayCarryoverError.invalid }
        let originalIDs = Set(mealRecovery?.domain.originalMeals.flatMap { $0.needs.map(\.id) } ?? [])
        var expectedTransfers = Set(legacyRecoveryTransfers(originalIDs: originalIDs).map(\.id))
        for record in awayCarryovers {
            try AwayCarryoverEngine.validate(record.intent)
            guard record.intent.plan.link.sourceShopID == id else { throw AwayCarryoverError.invalid }
            if record.phase == .reserved || record.phase == .completed {
                guard stockNeeds.contains(where: { $0 == AwayCarryoverEngine.targetNeed(record.intent) }) else { throw AwayCarryoverError.invalid }
                if let base = record.intent.recoveryRevision {
                    let request = AwayCarryoverEngine.transferRequest(record.intent, base: base)
                    guard mealRecovery?.domain.contextChanges.first(where: { $0.id == record.id })?.request == request else {
                        throw AwayCarryoverError.invalid
                    }
                    expectedTransfers.insert(record.id)
                }
            }
        }
        let transfers = mealRecovery?.domain.contextChanges.filter { event in
            if case .transferCarryover = event.request.change { return true }
            return false
        } ?? []
        guard Set(transfers.map(\.id)) == expectedTransfers else { throw AwayCarryoverError.invalid }
        _ = try carryoverAllocation()
    }
}

@MainActor final class DinnerAwayCarryoverModel: ObservableObject {
    let dinner: DinnerFeatureModel
    let pickup: PickupModel
    private let clock: () -> Date
    private var observations: [AnyCancellable] = []
    @Published private(set) var review: AwayCarryoverIntent?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    init(dinner: DinnerFeatureModel, pickup: PickupModel, clock: @escaping () -> Date = Date.init) {
        self.dinner = dinner; self.pickup = pickup; self.clock = clock
        observations = [dinner.objectWillChange, pickup.objectWillChange].map { publisher in
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    var records: [AwayCarryoverRecord] { pickup.journeys.first(where: { $0.id == dinner.shop?.id })?.awayCarryovers ?? [] }
    var pending: AwayCarryoverRecord? { records.first { $0.phase == .prepared || $0.phase == .reserved } }
    private func access(_ shopID: UUID, workspaceID: UUID? = nil, actorID: String? = nil,
                        sourceOperationID: UUID? = nil, duringLedgerWrite: Bool = false) throws -> DinnerAccessContext {
        guard dinner.shop?.id == shopID, pickup.journey?.id == shopID,
              dinner.store.ready, duringLedgerWrite || (!dinner.store.saving && !dinner.store.hasPendingSave),
              pickup.ready, sourceOperationID.map(pickup.isValidatingRecoverySave) == true || (!pickup.saving && !pickup.hasPendingSave),
              let access = dinner.accessProvider(shopID), case .local(let id) = access.scope,
              id == dinner.store.sourceWorkspaceID, workspaceID == nil || workspaceID == id,
              actorID == nil || actorID == access.actorID else { throw AwayCarryoverError.authority }
        try access.validate(shopID: shopID, at: clock(), applying: true)
        return access
    }
    @discardableResult func prepare(id: UUID, occurrenceID: UUID, needID: UUID, supply: AwayCarryoverSupply,
                                   counted: Quantity, reserved: Quantity, servings: Rational, day: MealDay, observedAt: Date) -> Bool {
        do {
            guard !busy, pending == nil, let shop = dinner.shop, let journey = pickup.journey,
                  journey.id == shop.id, journey.pickup != nil, journey.closedAt == nil,
                  let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil && $0.carryover == nil }),
                  let need = AwayCarryoverEngine.sourceNeeds(meal, in: journey).first(where: { $0.id == needID }),
                  observedAt <= clock() else { throw AwayCarryoverError.invalid }
            let authority = try access(shop.id)
            guard case .local(let workspaceID) = authority.scope else { throw AwayCarryoverError.authority }
            let confirmedID: UUID
            switch supply {
            case .batch: confirmedID = supply.id
            case .received: confirmedID = pickup.pantryIsActive ? supply.id : AwayCarryoverEngine.targetID(id, "physical-observation")
            }
            let link = DinnerCarryoverLink(operationID: id, sourceShopID: shop.id, sourceOccurrenceID: meal.id,
                sourceNeedID: need.id, sourceSupplyID: supply.id, confirmedSupplyID: confirmedID,
                reservationID: AwayCarryoverEngine.targetID(id, "reservation"), quantity: reserved, observedAt: observedAt)
            let current = try AwayCarryoverEngine.currentMeal(meal, in: journey)
            let plan = DinnerCarryoverPlan(occurrenceID: AwayCarryoverEngine.targetID(id, "dinner"),
                revisionID: AwayCarryoverEngine.targetID(id, "ledger-revision"), baseRevisionID: shop.revisionID,
                source: current, day: day, servings: servings, link: link, purchasedSource: current == meal ? nil : meal,
                ingredientExclusions: journey.recoveryCurrentDetails.first(where: { $0.id == need.id })?.exclusions)
            var intent = AwayCarryoverIntent(workspaceID: workspaceID, actorID: authority.actorID, pickupRevision: journey.revision,
                planningRevisionID: dinner.state.revisionID, sourceNeed: need, supply: supply, counted: counted, plan: plan,
                recoveryRevision: try journey.mealRecovery.map { try MealRecoveryEngine.project($0.domain).revisionID })
            if pickup.pantryIsActive {
                guard let ledger = dinner.store as? LedgerModel, let context = try pickup.pantryReviewContext() else { throw AwayCarryoverError.authority }
                intent = try PantryAwayCarryoverEvidence.bind(intent, context: context)
                try PantryAwayCarryoverEvidence.preview(intent, journey: journey, context: context, ledger: ledger, at: clock())
            } else { _ = try AwayCarryoverEngine.reserving(intent, in: journey, at: clock()) }
            var ledgerPreview = shop; try ledgerPreview.appendConfirmedCarryover(plan, at: clock())
            review = intent; message = nil; return true
        } catch { review = nil; message = pTr("Recount the existing physical food and choose a later real date. The carryover must not take food reserved for another meal."); return false }
    }
    func cancelReview() { review = nil; message = nil }
    @discardableResult func apply() async -> Bool {
        guard let intent = review else { return false }
        return await complete(intent, seal: true)
    }
    @discardableResult func retry(_ record: AwayCarryoverRecord) async -> Bool { await complete(record.intent, seal: false) }
    private func complete(_ intent: AwayCarryoverIntent, seal: Bool) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        if pickup.pantryIsActive { return await completeCanonical(intent, seal: seal) }
        do {
            _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
            if let completed = records.first(where: { $0.id == intent.id }), completed.phase == .completed {
                guard completed.intent == intent, var saved = dinner.shop, saved.mealOccurrences.contains(where: { $0.id == intent.plan.occurrenceID }) else { throw AwayCarryoverError.stale }
                try saved.appendConfirmedCarryover(intent.plan, at: clock())
                review = nil; return true
            }
            if records.first(where: { $0.id == intent.id }) == nil {
                guard seal, pickup.journey?.closedAt == nil, pickup.journey?.revision == intent.pickupRevision,
                      dinner.shop?.revisionID == intent.plan.baseRevisionID, dinner.state.revisionID == intent.planningRevisionID,
                      pending == nil else { throw AwayCarryoverError.stale }
                guard await pickup.change({ value in value.awayCarryovers.append(AwayCarryoverRecord(intent: intent, phase: .prepared)) }) else { throw AwayCarryoverError.pending }
            }
            guard let stored = records.first(where: { $0.id == intent.id }), stored.intent == intent,
                  stored.phase != .cancelled else { throw AwayCarryoverError.stale }
            if stored.phase == .prepared {
                _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
                guard dinner.shop?.revisionID == intent.plan.baseRevisionID, dinner.state.revisionID == intent.planningRevisionID else { throw AwayCarryoverError.stale }
                guard await pickup.change({ value in value = try AwayCarryoverEngine.reserving(intent, in: value, at: self.clock()) }) else { throw AwayCarryoverError.pending }
            }
            _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
            guard let current = pickup.journey else { throw AwayCarryoverError.stale }
            try AwayCarryoverEngine.assertReserved(intent, in: current, at: clock())
            let alreadyCreated = dinner.shop?.mealOccurrences.contains(where: { $0.id == intent.plan.occurrenceID && $0.carryover == intent.plan.link }) == true
            if !alreadyCreated {
                guard dinner.state.revisionID == intent.planningRevisionID else { throw AwayCarryoverError.stale }
                let saved = await dinner.store.change(key: "physical-carryover:v1:\(intent.id)") { workspace in
                    _ = try self.access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
                    guard let index = workspace.shops.firstIndex(where: { $0.id == intent.plan.link.sourceShopID }) else { throw AwayCarryoverError.stale }
                    try workspace.shops[index].appendConfirmedCarryover(intent.plan, at: self.clock())
                }
                guard saved else { throw AwayCarryoverError.pending }
            }
            _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
            guard let settled = pickup.journey, var target = dinner.shop,
                  target.mealOccurrences.contains(where: { $0.id == intent.plan.occurrenceID }) else { throw AwayCarryoverError.stale }
            try AwayCarryoverEngine.assertReserved(intent, in: settled, at: clock())
            try target.appendConfirmedCarryover(intent.plan, at: clock())
            guard await pickup.change({ value in
                try AwayCarryoverEngine.assertReserved(intent, in: value, at: self.clock())
                guard let index = value.awayCarryovers.firstIndex(where: { $0.id == intent.id }) else { throw AwayCarryoverError.stale }
                value.awayCarryovers[index].phase = .completed
            }) else { throw AwayCarryoverError.pending }
            review = nil; message = pTr("The dated carryover and its physical-food reservation are saved. Original purchases and protected lunches are unchanged."); return true
        } catch {
            message = pTr("Carryover is not complete. Its saved operation can be retried after reviewing current access and pending save controls. No second stock lot or dinner will be created.")
            return false
        }
    }

    func supplies(for need: AllocationNeed, in journey: PickupJourney) -> [AwayCarryoverSupply] {
        let old = AwayCarryoverEngine.supplies(for: need, in: journey)
        guard pickup.pantryIsActive else { return old }
        guard let context = try? pickup.pantryReviewContext() else { return [] }
        return old.filter { (try? PantryAwayCarryoverEvidence.selectedLot($0, context: context)) != nil }
    }
    func supplyCount(_ supply: AwayCarryoverSupply) -> String {
        guard pickup.pantryIsActive else { return pQuantity(supply.quantity) }
        guard let context = try? pickup.pantryReviewContext(),
              let row = try? PantryAwayCarryoverEvidence.selectedLot(supply, context: context) else { return pTr("Unresolved") }
        return pantryCount(row.current.count)
    }
    func supplyObservedAt(_ supply: AwayCarryoverSupply) -> Date? {
        guard pickup.pantryIsActive else { return supply.observedAt }
        guard let context = try? pickup.pantryReviewContext(),
              let row = try? PantryAwayCarryoverEvidence.selectedLot(supply, context: context) else { return nil }
        return row.current.confirmedAt
    }
    func prepareSavedReservation(_ record: AwayCarryoverRecord) -> Bool {
        do {
            guard !busy, pickup.pantryIsActive, record.phase == .reserved, record.intent.canonical == nil,
                  let ledger = dinner.store as? LedgerModel, let journey = pickup.journey,
                  let context = try pickup.pantryReviewContext() else { throw AwayCarryoverError.stale }
            _ = try access(journey.id, workspaceID: record.intent.workspaceID, actorID: record.intent.actorID)
            let intent = try PantryAwayCarryoverEvidence.bind(record.intent, context: context, recountsPhysicalSource: false)
            _ = try PantryAwayCarryoverEvidence.adoptReserved(intent, journey: journey, context: context, ledger: ledger, at: clock())
            review = intent; message = nil; return true
        } catch { review = nil; message = pTr("The saved reservation needs a current pantry review. No food or calendar entry changed."); return false }
    }
    @discardableResult func cancelPrepared(_ record: AwayCarryoverRecord) async -> Bool {
        guard !busy, pickup.pantryIsActive, record.phase == .prepared else { return false }
        busy = true; defer { busy = false }
        do {
            guard await pickup.refreshPantryStock() else { throw AwayCarryoverError.stale }
            let saved = try await saveCanonicalPhase(record.intent, phase: .cancelled)
            if saved { review = nil; message = pTr("Preparation cancelled. The physical count and original dinner demand are unchanged.") }
            return saved
        } catch { message = pTr("The saved reservation needs a current pantry review. No food or calendar entry changed."); return false }
    }
    private func canonicalContext(_ intent: AwayCarryoverIntent) throws -> PantryPackStockReview.Context {
        guard let ledger = dinner.store as? LedgerModel, ledger.ready,
              ledger.sourceWorkspaceID == intent.workspaceID, pickup.journey?.id == intent.plan.link.sourceShopID,
              let context = try pickup.pantryReviewContext(forRecoveryOperationID: intent.id) else { throw AwayCarryoverError.authority }
        return context
    }
    private func hasExactTarget(_ intent: AwayCarryoverIntent) throws -> Bool {
        guard var shop = dinner.shop, shop.id == intent.plan.link.sourceShopID else { throw AwayCarryoverError.stale }
        guard shop.mealOccurrences.contains(where: { $0.id == intent.plan.occurrenceID }) else { return false }
        try shop.appendConfirmedCarryover(intent.plan, at: clock())
        return true
    }
    private func phaseReview(_ intent: AwayCarryoverIntent, phase: AwayCarryoverRecord.Phase,
                             at instant: Date) throws -> PantryAwayCarryoverEvidence.Review {
        guard let ledger = dinner.store as? LedgerModel, let journey = pickup.journey else { throw AwayCarryoverError.authority }
        let context = try canonicalContext(intent)
        if phase == .completed {
            guard try hasExactTarget(intent) else { throw AwayCarryoverError.stale }
            return try PantryAwayCarryoverEvidence.complete(intent, journey: journey, context: context, ledger: ledger, at: instant)
        }
        _ = try access(journey.id, workspaceID: intent.workspaceID, actorID: intent.actorID, sourceOperationID: intent.id)
        if phase == .cancelled {
            return try PantryAwayCarryoverEvidence.cancelPrepared(intent, journey: journey, context: context, ledger: ledger, at: instant)
        }
        guard dinner.shop?.revisionID == intent.plan.baseRevisionID, dinner.state.revisionID == intent.planningRevisionID else { throw AwayCarryoverError.stale }
        if phase == .prepared {
            guard journey.closedAt == nil, journey.revision == intent.pickupRevision else { throw AwayCarryoverError.stale }
            return try PantryAwayCarryoverEvidence.prepare(intent, journey: journey, context: context, ledger: ledger, at: instant)
        }
        if let existing = journey.awayCarryovers.first(where: { $0.id == intent.id }), existing.phase == .reserved, existing.intent.canonical == nil {
            return try PantryAwayCarryoverEvidence.adoptReserved(intent, journey: journey, context: context, ledger: ledger, at: instant)
        }
        return try PantryAwayCarryoverEvidence.reserve(intent, journey: journey, context: context, ledger: ledger, at: instant)
    }
    private func authorizesPending(_ intent: AwayCarryoverIntent, candidate: PickupJourney) -> Bool {
        do {
            guard let record = candidate.awayCarryovers.first(where: { $0.id == intent.id }), record.intent == intent else { return false }
            var expected = try phaseReview(intent, phase: record.phase, at: candidate.savedAt).candidate
            guard expected.revision < Int64.max else { return false }
            expected.savedAt = candidate.savedAt; expected.revision += 1
            try expected.synchronizeRecoveryOutside(at: candidate.savedAt)
            return expected == candidate
        } catch { return false }
    }
    private func saveCanonicalPhase(_ intent: AwayCarryoverIntent, phase: AwayCarryoverRecord.Phase) async throws -> Bool {
        let prepared = try phaseReview(intent, phase: phase, at: clock())
        return await pickup.saveRecoveryCandidate(prepared.candidate, operationID: intent.id, reviewedPantry: prepared.writeReview) { [weak self] in
            guard let self else { return false }
            do { _ = try self.phaseReview(intent, phase: phase, at: self.clock()); return true }
            catch { return false }
        }
    }
    private func completeCanonical(_ intent: AwayCarryoverIntent, seal: Bool) async -> Bool {
        do {
            guard let ledger = dinner.store as? LedgerModel, ledger.sourceWorkspaceID == intent.workspaceID else { throw AwayCarryoverError.authority }
            // Recovery of an exact committed source submission precedes action
            // authorization. A restored uncommitted action needs a new runtime grant.
            if let candidate = pickup.pendingRecoveryCandidate(operationID: intent.id) {
                guard candidate.awayCarryovers.first(where: { $0.id == intent.id })?.intent == intent else { throw AwayCarryoverError.stale }
                let recovered = await pickup.retryRecoveryCandidate(operationID: intent.id, authorize: { [weak self] in
                    self?.authorizesPending(intent, candidate: candidate) == true
                }, matches: { $0 == candidate })
                guard recovered else { throw AwayCarryoverError.pending }
            }
            guard !pickup.hasPendingSave, !ledger.hasPendingSave, await pickup.refreshPantryStock() else { throw AwayCarryoverError.pending }
            _ = try canonicalContext(intent)
            if let existing = records.first(where: { $0.id == intent.id }), existing.phase == .completed {
                guard existing.intent == intent, try hasExactTarget(intent) else { throw AwayCarryoverError.stale }
                review = nil; return true
            }
            // Calendar receipt recognition precedes fresh food feasibility. A
            // later recount/consumption cannot undo an already-created target.
            if let existing = records.first(where: { $0.id == intent.id }), existing.phase == .reserved,
               existing.intent == intent, try hasExactTarget(intent) {
                guard try await saveCanonicalPhase(intent, phase: .completed) else { throw AwayCarryoverError.pending }
                review = nil; return true
            }
            _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
            if records.first(where: { $0.id == intent.id }) == nil {
                guard seal, intent.canonical != nil, try await saveCanonicalPhase(intent, phase: .prepared) else { throw AwayCarryoverError.stale }
            }
            guard let stored = records.first(where: { $0.id == intent.id }), stored.phase != .cancelled else { throw AwayCarryoverError.stale }
            if stored.phase == .prepared {
                guard stored.intent == intent, intent.canonical != nil,
                      try await saveCanonicalPhase(intent, phase: .reserved) else { throw AwayCarryoverError.stale }
            } else if stored.phase == .reserved, stored.intent != intent {
                var historical = intent; historical.canonical = nil
                guard seal, stored.intent == historical, stored.intent.canonical == nil,
                      try await saveCanonicalPhase(intent, phase: .reserved) else { throw AwayCarryoverError.stale }
            }
            guard records.first(where: { $0.id == intent.id }) == .init(intent: intent, phase: .reserved), intent.canonical != nil,
                  let current = pickup.journey else { throw AwayCarryoverError.stale }
            let context = try canonicalContext(intent)
            try PantryAwayCarryoverEvidence.assertReserved(intent, journey: current, context: context, at: clock())
            _ = try access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID)
            let basis = PantryAwayCarryoverEvidence.basis(context)
            let saved = await ledger.change(key: "physical-carryover:v1:\(intent.id)", reviewedPantryBasis: basis, authorize: { [weak self] in
                guard let self, let current = self.pickup.journey else { return false }
                do {
                    _ = try self.access(intent.plan.link.sourceShopID, workspaceID: intent.workspaceID, actorID: intent.actorID, duringLedgerWrite: true)
                    let latest = try self.canonicalContext(intent)
                    guard PantryAwayCarryoverEvidence.basis(latest) == basis,
                          self.dinner.state.revisionID == intent.planningRevisionID else { return false }
                    try PantryAwayCarryoverEvidence.assertReserved(intent, journey: current, context: latest, at: self.clock())
                    return true
                } catch { return false }
            }) { workspace in
                guard workspace.dinnerPlanning.revisionID == intent.planningRevisionID,
                      let index = workspace.shops.firstIndex(where: { $0.id == intent.plan.link.sourceShopID }) else { throw AwayCarryoverError.stale }
                try workspace.shops[index].appendConfirmedCarryover(intent.plan, at: self.clock())
            }
            guard saved, await pickup.refreshPantryStock(), try await saveCanonicalPhase(intent, phase: .completed) else { throw AwayCarryoverError.pending }
            review = nil; message = pTr("The dated carryover and its physical-food reservation are saved. Original purchases and protected lunches are unchanged.")
            return true
        } catch {
            message = pTr("Carryover is not complete. Its saved operation can be retried after reviewing current access and pending save controls. No second stock lot or dinner will be created.")
            return false
        }
    }
}
