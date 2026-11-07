import Foundation
import CoreDomain

func recoveryText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "PickupRecovery") }

/// An ephemeral live presentation fingerprint. This is deliberately not Codable.
struct PickupRecoveryAuthority: Equatable {
    let presentation: PickupStockReviewPresentation
    let ledgerWorkspaceID: UUID
    let ledgerRevisionID: UUID
    let selectedPickupID: UUID
    let leaseID: UUID
    var scope: PickupStockReviewScope? { presentation.scope(presentationID: leaseID) }
}

struct PickupMealRecoveryReview {
    var domain: MealRecoveryReview
    let definition: PickupRecoveryMealDefinition
    let authority: PickupRecoveryAuthority
    let journeyRevision: Int64
    let candidateHistory: PickupMealRecoveryHistory
    var id: UUID { domain.request.id }
}
struct PickupMealContextReview {
    let domain: MealRecoveryContextReview
    let authority: PickupRecoveryAuthority
    let journeyRevision: Int64
    let candidateHistory: PickupMealRecoveryHistory
}

extension PickupJourney {
    var rawPhysicalStockNeeds: [StockNeed] {
        (pickup == nil ? plannedNeeds : needs).map {
            StockNeed(id: $0.id, foodID: $0.orderLineID, name: $0.name, amount: $0.amount, priority: $0.priority)
        } + stockNeeds
    }
    var recoveryStockEvidence: [RecoveryStockEvidence] {
        var evidence = stockLots.map { RecoveryStockEvidence(lot: $0, availableAt: $0.confirmedAt) }
        for receipt in pickup?.receipts ?? [] {
            guard let usable = pickup?.usableObservations.last(where: { $0.receipt == receipt.key }),
                  usable.confirmedMatchToOrderLine else { continue }
            evidence.append(.init(lot: .init(id: usable.id, foodID: receipt.key.orderLineID, name: receipt.itemName,
                usable: usable.usable, confirmedAt: usable.confirmedAt), availableAt: max(receipt.receivedAt, usable.confirmedAt)))
        }
        return evidence
    }
    func initialMealRecoveryHistory() throws -> PickupMealRecoveryHistory {
        if let mealRecovery { try mealRecovery.validate(); return mealRecovery }
        guard pickup != nil, basket?.phase == .reportedPlaced, let source = mealSource else { throw PickupMealRecoveryError.unavailable }
        try source.validate()
        let definitions = try source.definitions()
        guard !definitions.isEmpty else { throw PickupMealRecoveryError.unavailable }
        let ids = Set(definitions.flatMap { $0.meal.needs.map(\.id) })
        let state = try MealRecoveryState(shopID: id, originalRevisionID: source.shop.revisionID,
            originalMeals: definitions.map(\.meal), outsideDemands: rawPhysicalStockNeeds.filter { !ids.contains($0.id) })
        let result = PickupMealRecoveryHistory(source: source, domain: state, definitions: [],
            ledgerCalendarBasis: definitions.map { .init(occurrenceID: $0.meal.id, day: $0.meal.scheduledDay) })
        try validateRecoveryRawBasis(result)
        return result
    }
    func validateRecoveryRawBasis(_ history: PickupMealRecoveryHistory) throws {
        guard history.source == mealSource, history.domain.shopID == id,
              history.source.details.filter({ $0.sourceOccurrenceID != nil }).allSatisfy({ needDetails.contains($0) }) else { throw PickupMealRecoveryError.sourceChanged }
        let original = history.domain.originalMeals.flatMap(\.needs)
        for need in original {
            guard rawPhysicalStockNeeds.first(where: { $0.id == need.id }) == need else { throw PickupMealRecoveryError.sourceChanged }
        }
        let originalIDs = Set(original.map(\.id))
        let rawOutside = rawPhysicalStockNeeds.filter { !originalIDs.contains($0.id) }
        let projected = try MealRecoveryEngine.project(history.domain).outsideDemands
        guard rawOutside.count == projected.count, rawOutside.allSatisfy({ projected.contains($0) }) else {
            throw PickupMealRecoveryError.sourceChanged
        }
    }
    /// Existing source writes may append new independent demands. Record that fact
    /// explicitly; never edit the immutable recovery baseline or ignore the new need.
    mutating func synchronizeRecoveryOutside(at instant: Date) throws {
        guard var history = mealRecovery else { return }
        try history.validate()
        let original = history.domain.originalMeals.flatMap(\.needs), ids = Set(original.map(\.id))
        guard original.allSatisfy({ rawPhysicalStockNeeds.contains($0) }) else { throw PickupMealRecoveryError.sourceChanged }
        let current = try MealRecoveryEngine.project(history.domain)
        let outside = rawPhysicalStockNeeds.filter { !ids.contains($0.id) }
        guard current.outsideDemands.allSatisfy({ outside.contains($0) }) else { throw PickupMealRecoveryError.sourceChanged }
        let known = Set(current.outsideDemands.map(\.id))
        let additions = outside.filter { !known.contains($0.id) }
        if !additions.isEmpty {
            let operation = PickupCheckoutMealSource.identity("outside-needs", [id, current.revisionID] + additions.map(\.id))
            let request = MealRecoveryContextRequest(id: operation, shopID: id, baseRevisionID: current.revisionID,
                revisionID: PickupCheckoutMealSource.identity("outside-revision", [operation]),
                change: .appendOutside(additions), reviewedAt: instant)
            let review = try MealRecoveryEngine.previewContext(request, in: history.domain, at: instant)
            try MealRecoveryEngine.applyContext(review, to: &history.domain, at: instant)
        }
        try validateRecoveryRawBasis(history)
        mealRecovery = history
    }
    var recoveryCurrentDetails: [PickupNeedDetail] {
        guard let history = mealRecovery, let projected = try? MealRecoveryEngine.project(history.domain) else { return needDetails }
        let originals = Set(history.domain.originalMeals.flatMap(\.needs).map(\.id))
        var result = needDetails.filter { !originals.contains($0.id) }
        for meal in projected.meals {
            guard let definition = try? history.definition(for: meal.id) else { continue }
            for item in meal.ingredients {
                if !history.domain.events.contains(where: { $0.request.target.id == meal.id }),
                   let original = needDetails.first(where: { $0.id == item.need.id }) {
                    result.append(original)
                    continue
                }
                let rule = definition.ingredientRules.first { $0.needID == item.need.id }
                result.append(.init(id: item.need.id, mealName: meal.title,
                    exclusions: Array(Set(meal.exclusions + (rule?.exclusions ?? []))).sorted(),
                    scheduledDay: history.domain.events.contains(where: { $0.request.target.id == meal.id })
                        ? meal.scheduledDay : (needDetails.first(where: { $0.id == item.need.id })?.scheduledDay ?? meal.scheduledDay),
                    leadTimeMinutes: meal.remainingElapsedMinutes,
                    completedSteps: history.domain.events.contains(where: { $0.request.target.id == meal.id })
                        ? [] : (history.source.details.first(where: { $0.id == item.need.id })?.completedSteps ?? []),
                    sourceContributionID: item.ingredientID, sourceOccurrenceID: meal.id, sourceGroupID: item.groupID,
                    sourceLedgerRevisionID: history.source.shop.revisionID, due: meal.due,
                    preparationNotes: [definition.notes, rule?.notes ?? ""].filter { !$0.isEmpty }, sourceURL: definition.sourceURL))
            }
        }
        return result
    }
    var recoveryCurrentUrgent: [UrgentMealNeed] {
        guard let history = mealRecovery, let projected = try? MealRecoveryEngine.project(history.domain) else { return urgent }
        let active = Set(projected.demands.map(\.id))
        return urgent.filter { active.contains($0.id) }
    }
    func savedMealDeadline(for needID: UUID?) -> Date? {
        guard let needID else { return nil }
        return recoveryCurrentUrgent.first { $0.id == needID }?.due
            ?? recoveryCurrentDetails.first { $0.id == needID }?.due
    }

    var currentRepairNeeds: [AllocationNeed] {
        guard mealRecovery != nil else { return needs }
        let urgentIDs = Set(recoveryCurrentUrgent.map(\.id))
        return recoveryCurrentAllocationNeeds.filter { !urgentIDs.contains($0.id) }
    }

    var currentRepairInstructions: [PickupRepair] {
        guard mealRecovery != nil else { return repairs }
        let current = Set(physicalStockNeeds.map(\.id))
        return repairs.filter { current.contains($0.needID) }
    }

    mutating func recordRepair(_ instruction: PickupRepair) throws {
        if let saved = repairs.first(where: { $0.id == instruction.id }) {
            guard saved == instruction else { throw MealRecoveryError.operationConflict }
            return
        }
        guard currentRepairNeeds.contains(where: { $0.id == instruction.needID }) ||
                recoveryCurrentUrgent.contains(where: { $0.id == instruction.needID }) else {
            throw MealRecoveryError.stale
        }
        repairs.append(instruction)
    }

    var recoveryCurrentAllocationNeeds: [AllocationNeed] {
        physicalStockNeeds.map { .init(id: $0.id, orderLineID: $0.foodID, name: $0.name, amount: $0.amount, priority: $0.priority) }
    }
}

extension PickupModel {
    private func recoverySourceState(at contextInstant: Date? = nil) throws -> (PickupJourney, PickupMealRecoveryHistory, UUID, ShoppingLedger) {
        guard ready, let current = journey,
              let ledger = recoveryLedger, ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              let workspaceID = ledger.sourceWorkspaceID,
              let shop = ledger.workspace.shops.first(where: { $0.id == current.id }) else { throw PickupMealRecoveryError.unavailable }
        let instant = contextInstant ?? stockReviewDate
        var history = try current.initialMealRecoveryHistory()
        guard history.source.ledgerWorkspaceID == workspaceID else { throw PickupMealRecoveryError.sourceChanged }
        let recovered = Set(history.domain.events.map { $0.request.target.id })
        for sourceMeal in history.source.shop.mealOccurrences where history.domain.originalMeals.contains(where: { $0.id == sourceMeal.id }) {
            guard let live = shop.mealOccurrences.first(where: { $0.id == sourceMeal.id }) else { throw PickupMealRecoveryError.sourceChanged }
            var compared = live; compared.scheduledDay = sourceMeal.scheduledDay
            guard compared == sourceMeal else { throw PickupMealRecoveryError.sourceChanged }
            let basis = history.ledgerCalendarBasis.first { $0.occurrenceID == live.id }
            if recovered.contains(live.id) {
                // Recovered calendars belong to the pickup context operation. A raw
                // ledger edit cannot silently rewrite an already reviewed recovery.
                guard basis?.day == live.scheduledDay else { throw PickupMealRecoveryError.sourceChanged }
            } else if let meal = try MealRecoveryEngine.project(history.domain).meals.first(where: { $0.id == live.id }), meal.scheduledDay != live.scheduledDay {
                let operation = PickupCheckoutMealSource.identity("source-calendar", [shop.revisionID, live.id])
                let request = MealRecoveryContextRequest(id: operation, shopID: current.id,
                    baseRevisionID: try MealRecoveryEngine.project(history.domain).revisionID,
                    revisionID: PickupCheckoutMealSource.identity("source-calendar-revision", [operation]),
                    change: .moveMeal(occurrenceID: live.id, from: meal.scheduledDay, to: live.scheduledDay), reviewedAt: instant)
                let reviewed = try MealRecoveryEngine.previewContext(request, in: history.domain, at: instant)
                try MealRecoveryEngine.applyContext(reviewed, to: &history.domain, at: instant)
                history.ledgerCalendarBasis.removeAll { $0.occurrenceID == live.id }
                history.ledgerCalendarBasis.append(.init(occurrenceID: live.id, day: live.scheduledDay))
            }
        }
        try current.validateRecoveryRawBasis(history)
        return (current, history, workspaceID, shop)
    }
    func recoveryDefinitions() throws -> [PickupRecoveryMealDefinition] {
        let (_, history, _, _) = try recoverySourceState()
        return try MealRecoveryEngine.project(history.domain).meals.compactMap { try history.definition(for: $0.id) }
    }
    func recoveryMeals() throws -> [RecoveryMeal] { try recoveryDefinitions().map(\.meal) }
    var recoveryStockMatches: [PickupStockMatch] {
        guard let current = journey else { return [] }
        var result = current.reviewedStockMatches, seen = Set(result.map(\.id))
        for evidence in current.recoveryStockEvidence where seen.insert(evidence.lot.foodID).inserted {
            result.append(.init(id: evidence.lot.foodID, name: evidence.lot.name))
        }
        return result
    }

    private func permitsRecovery(_ authority: PickupRecoveryAuthority, allowPending: Bool = false) -> Bool {
        guard ready, !saving, allowPending || !hasPendingSave, let scope = authority.scope, scope.permitsReview,
              scope.workspaceID == sourceWorkspaceID, authority.selectedPickupID == selectedID,
              let current = journey, current.id == authority.selectedPickupID, current.closedAt == nil,
              let ledger = recoveryLedger, ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              ledger.sourceWorkspaceID == authority.ledgerWorkspaceID,
              ledger.workspace.shops.first(where: { $0.id == current.id })?.revisionID == authority.ledgerRevisionID else { return false }
        return true
    }
    func prepareMealRecovery(definition: PickupRecoveryMealDefinition, operationID: UUID,
                             confirmedUnknownDeadline: Date? = nil, agreesToRepeat: Bool,
                             proposesExtraTrip: Bool, agreesToExtraTrip: Bool, acceptsUnresolved: Bool,
                             authority: PickupRecoveryAuthority) throws -> PickupMealRecoveryReview {
        guard permitsRecovery(authority) else { throw PickupMealRecoveryError.forbidden }
        let instant = stockReviewDate
        let (current, initial, _, _) = try recoverySourceState(at: instant)
        var history = initial
        if let due = confirmedUnknownDeadline {
            let operation = PickupCheckoutMealSource.identity("confirmed-deadline", [operationID])
            let context = MealRecoveryContextRequest(id: operation, shopID: current.id,
                baseRevisionID: try MealRecoveryEngine.project(history.domain).revisionID,
                revisionID: PickupCheckoutMealSource.identity("deadline-revision", [operation]),
                change: .confirmDeadline(occurrenceID: definition.meal.id, due: due), reviewedAt: instant)
            let reviewed = try MealRecoveryEngine.previewContext(context, in: history.domain, at: instant)
            try MealRecoveryEngine.applyContext(reviewed, to: &history.domain, at: instant)
        }
        guard let previous = try history.definition(for: definition.meal.id) else { throw PickupMealRecoveryError.invalid }
        try definition.validate(replacing: previous)
        try validateCurrentAcceptedTemplate(definition)
        try validateMatchedIngredientRules(definition, evidence: current.recoveryStockEvidence, at: instant)
        let request = MealRecoveryRequest(id: operationID, shopID: current.id,
            baseRevisionID: try MealRecoveryEngine.project(history.domain).revisionID,
            target: previous.meal, replacement: definition.meal, reviewedAt: instant,
            agreesToRepeat: agreesToRepeat, proposesExtraTrip: proposesExtraTrip, agreesToExtraTrip: agreesToExtraTrip,
            acceptsUnresolved: acceptsUnresolved)
        let review = try MealRecoveryEngine.preview(request, in: history.domain, stockEvidence: current.recoveryStockEvidence,
            reservations: current.carryoverStockReservations, at: instant)
        return .init(domain: review, definition: definition, authority: authority, journeyRevision: current.revision, candidateHistory: history)
    }
    func applyMealRecovery(_ review: PickupMealRecoveryReview,
                           currentAuthority: @escaping @MainActor () -> PickupRecoveryAuthority?) async -> Bool {
        guard let authority = currentAuthority(), authority == review.authority, permitsRecovery(authority, allowPending: true) else {
            error = recoveryText("The meal or your access changed. Review the replacement again."); return false
        }
        if hasPendingSave {
            return await retryRecoveryCandidate(operationID: review.id) { pending in
                guard let history = pending.mealRecovery, let event = history.domain.events.first(where: { $0.id == review.id }) else { return false }
                return event.request == review.domain.request && event.stockEvidence == review.domain.stockEvidence &&
                    event.reservations == review.domain.reservations && history.definitions.first(where: { $0.operationID == review.id })?.definition == review.definition
            }
        }
        do {
            guard var candidate = journey else { throw PickupMealRecoveryError.unavailable }
            if let history = candidate.mealRecovery, let saved = history.domain.events.first(where: { $0.id == review.id }) {
                guard saved.request == review.domain.request, saved.stockEvidence == review.domain.stockEvidence,
                      saved.reservations == review.domain.reservations,
                      history.definitions.first(where: { $0.operationID == review.id })?.definition == review.definition else {
                    throw MealRecoveryError.operationConflict
                }
                return true
            }
            guard candidate.revision == review.journeyRevision else { throw PickupMealRecoveryError.stale }
            let (_, freshSource, _, _) = try recoverySourceState(at: review.domain.request.reviewedAt)
            // Fresh initial calendar/source context must match what was displayed;
            // an optional staged deadline is the only additional preview context.
            let deadlineContexts = review.candidateHistory.domain.contextChanges.filter {
                if case .confirmDeadline = $0.request.change { return !freshSource.domain.contextChanges.contains($0) }
                return false
            }
            var fresh = freshSource
            for event in deadlineContexts {
                let preview = try MealRecoveryEngine.previewContext(event.request, in: fresh.domain, at: event.appliedAt)
                try MealRecoveryEngine.applyContext(preview, to: &fresh.domain, at: event.appliedAt)
            }
            guard fresh == review.candidateHistory else { throw PickupMealRecoveryError.stale }
            try validateCurrentAcceptedTemplate(review.definition)
            let instant = stockReviewDate
            try validateMatchedIngredientRules(review.definition, evidence: candidate.recoveryStockEvidence, at: instant)
            try MealRecoveryEngine.apply(review.domain, to: &fresh.domain, stockEvidence: candidate.recoveryStockEvidence,
                reservations: candidate.carryoverStockReservations, at: instant)
            fresh.definitions.append(.init(operationID: review.id, definition: review.definition,
                localActorID: authority.presentation.localActorID))
            try fresh.validate()
            candidate.mealRecovery = fresh
            return await saveRecoveryCandidate(candidate, operationID: review.id) { [weak self] in
                guard let self, let latest = currentAuthority() else { return false }
                guard latest == authority, self.permitsRecovery(latest, allowPending: true),
                      let live = self.journey, live.revision == review.journeyRevision else { return false }
                do {
                    let instant = self.stockReviewDate
                    try self.validateCurrentAcceptedTemplate(review.definition)
                    try self.validateMatchedIngredientRules(review.definition, evidence: live.recoveryStockEvidence, at: instant)
                    var checked = review.domain.source
                    try MealRecoveryEngine.apply(review.domain, to: &checked, stockEvidence: live.recoveryStockEvidence,
                        reservations: live.carryoverStockReservations, at: instant)
                    return true
                } catch { return false }
            }
        } catch {
            self.error = recoveryText("The meal or food changed. Review the replacement again before saving.")
            return false
        }
    }
    func prepareRecoveryMove(occurrenceID: UUID, to day: MealDay?, operationID: UUID,
                             authority: PickupRecoveryAuthority) throws -> PickupMealContextReview {
        guard permitsRecovery(authority) else { throw PickupMealRecoveryError.forbidden }
        let instant = stockReviewDate
        let (current, history, _, _) = try recoverySourceState(at: instant)
        let projection = try MealRecoveryEngine.project(history.domain)
        guard history.domain.events.contains(where: { $0.request.target.id == occurrenceID }),
              let meal = projection.meals.first(where: { $0.id == occurrenceID }) else { throw PickupMealRecoveryError.invalid }
        let request = MealRecoveryContextRequest(id: operationID, shopID: current.id, baseRevisionID: projection.revisionID,
            revisionID: PickupCheckoutMealSource.identity("move-revision", [operationID]),
            change: .moveMeal(occurrenceID: occurrenceID, from: meal.scheduledDay, to: day), reviewedAt: instant)
        return .init(domain: try MealRecoveryEngine.previewContext(request, in: history.domain, at: instant),
            authority: authority, journeyRevision: current.revision, candidateHistory: history)
    }
    func applyRecoveryMove(_ review: PickupMealContextReview,
                           currentAuthority: @escaping @MainActor () -> PickupRecoveryAuthority?) async -> Bool {
        guard let authority = currentAuthority(), authority == review.authority, permitsRecovery(authority, allowPending: true) else { return false }
        if hasPendingSave {
            return await retryRecoveryCandidate(operationID: review.domain.request.id) { pending in
                pending.mealRecovery?.domain.contextChanges.first(where: { $0.id == review.domain.request.id })?.request == review.domain.request
            }
        }
        do {
            guard var candidate = journey else { return false }
            if let existing = candidate.mealRecovery?.domain.contextChanges.first(where: { $0.id == review.domain.request.id }) {
                return existing.request == review.domain.request
            }
            guard candidate.revision == review.journeyRevision else { throw PickupMealRecoveryError.stale }
            let (_, current, _, _) = try recoverySourceState(at: review.domain.request.reviewedAt)
            guard current == review.candidateHistory else { throw PickupMealRecoveryError.stale }
            var history = current
            try MealRecoveryEngine.applyContext(review.domain, to: &history.domain, at: stockReviewDate)
            candidate.mealRecovery = history
            return await saveRecoveryCandidate(candidate, operationID: review.domain.request.id) { [weak self] in
                guard let self, let latest = currentAuthority() else { return false }
                return latest == authority && self.permitsRecovery(latest, allowPending: true)
            }
        } catch { self.error = recoveryText("The meal changed. Review its date again."); return false }
    }
    private func validateCurrentAcceptedTemplate(_ definition: PickupRecoveryMealDefinition) throws {
        guard let template = definition.acceptedTemplate else { return }
        guard recoveryLedger?.workspace.dinnerPlanning.acceptedDinners.contains(where: {
            $0.acceptedFallback && $0.template == template
        }) == true else { throw PickupMealRecoveryError.sourceChanged }
    }
    private func validateMatchedIngredientRules(_ definition: PickupRecoveryMealDefinition,
                                                evidence: [RecoveryStockEvidence], at instant: Date) throws {
        for ingredient in definition.meal.ingredients {
            guard let rule = definition.ingredientRules.first(where: { $0.needID == ingredient.need.id }) else { throw PickupMealRecoveryError.invalid }
            // Food identity/rules apply to retained future evidence too; availability
            // alone is time-filtered by the allocation engine.
            for lot in evidence where lot.lot.foodID == ingredient.need.foodID {
                try MealTemplate(id: ingredient.need.id, title: definition.meal.title,
                    ingredients: [.init(id: ingredient.need.id, name: lot.lot.name, quantity: ingredient.need.amount,
                        exclusions: rule.exclusions)], exclusions: definition.meal.exclusions).validate()
            }
        }
    }
}
