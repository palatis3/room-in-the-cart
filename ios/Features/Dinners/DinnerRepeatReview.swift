import Foundation
import CoreDomain

struct DinnerRepeatChoice: Identifiable {
    let candidate: RepeatWeek.Candidate
    var day: MealDay
    var servings: Rational
    var ingredientEdits: [DinnerQuantityEdit] = []
    var id: RepeatWeek.Source { candidate.source }
    var title: String { candidate.template.title }
    var sourceDay: MealDay { candidate.sourceDay }

    init(_ candidate: RepeatWeek.Candidate) {
        self.candidate = candidate
        day = candidate.targetDay
        servings = candidate.template.servings
    }

    var selection: RepeatWeek.Selection {
        var result = RepeatWeek.Selection(candidate)
        result.day = day
        result.servings = servings
        result.ingredientEdits = ingredientEdits
        return result
    }
}

struct DinnerRepeatReview {
    let start: MealDay
    let identity: DinnerFeatureModel.EditorIdentity
    let sourceShopIDs: Set<UUID>
    let hasPaidEvidence: Bool
    let targetRevision: UUID
    let planningRevision: UUID
    let pantryBasis: DinnerPantrySupply.Basis?
    let meals: [DinnerRepeatChoice]
    let staples: [ReviewedStaple]
    let evidence: DinnerRepeatEvidence

    var stock: [DinnerRepeatStockRow] { evidence.stock }
    var notes: [DinnerWeekNote] { evidence.notes }
    var priceChecks: [String] { evidence.priceChecks }
}

extension DinnerFeatureModel {
    /// Keep civil day labels across changes to daylight saving time.
    private func repeatDays(start: MealDay, offsets: Range<Int>) throws -> [MealDay] {
        try start.validate()
        guard let date = start.date, let zone = TimeZone(identifier: start.timeZoneIdentifier) else {
            throw DinnerPlanningError.invalid("week")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return try offsets.map { offset in
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: date) else {
                throw DinnerPlanningError.invalid("week")
            }
            return try MealDay(date: shifted, timeZoneIdentifier: zone.identifier)
        }
    }

    func canReadRepeatSources(_ ids: Set<UUID>, identity: EditorIdentity) -> Bool {
        guard editorIdentity == identity else { return false }
        return ids.allSatisfy { id in
            guard let current = try? access(for: id) else { return false }
            return current.scope == identity.scope && current.actorID == identity.actorID
        }
    }

    private func repeatSources(in workspace: LedgerWorkspace, access: DinnerAccessContext) -> Set<UUID> {
        Set(workspace.shops.compactMap { shop in
            guard let current = try? self.access(for: shop.id), current.scope == access.scope,
                  current.actorID == access.actorID, current.canPlan else { return nil }
            return shop.id
        })
    }

    /// A recovered recipe belongs to the pickup that recorded it. Never use the
    /// globally selected pickup when projecting dinners from an earlier shop.
    private func recoveredDinners(in workspace: LedgerWorkspace, sourceDays: [MealDay], shopIDs: Set<UUID>,
                                  pickup: PickupModel) throws -> [UUID: RepeatWeek.Recovery] {
        guard pickup.ready, !pickup.hasPendingSave, !pickup.saving, pickup.recoveryLedger === store else {
            throw DinnerPlanningError.forbidden
        }
        let shops = Dictionary(uniqueKeysWithValues: workspace.shops.filter { shopIDs.contains($0.id) }.map { ($0.id, $0) })
        let labels = Set(sourceDays.map(\.iso8601))
        var result: [UUID: RepeatWeek.Recovery] = [:]
        for journey in pickup.journeys {
            guard let shop = shops[journey.id], let history = journey.mealRecovery else { continue }
            guard history.source.ledgerWorkspaceID == store.sourceWorkspaceID,
                  history.source.shop.id == shop.id else { throw DinnerPlanningError.stalePreview }
            let changed = Set(history.domain.events.map { $0.request.target.id })
            guard !changed.isEmpty else { continue }
            let projected = try MealRecoveryEngine.project(history.domain)
            for meal in projected.meals where changed.contains(meal.id) {
                guard var original = shop.mealOccurrences.first(where: { $0.id == meal.id && $0.removedAt == nil && !$0.isHidden }) else { continue }
                // Include meals moved out of the source week so that the engine
                // cannot propose their superseded original arrangement.
                guard [meal.scheduledDay, original.scheduledDay].contains(where: { $0.map { labels.contains($0.iso8601) } == true }) else { continue }
                guard let calendar = history.ledgerCalendarBasis.first(where: { $0.occurrenceID == meal.id }),
                      original.scheduledDay == calendar.day,
                      let sealed = history.source.shop.mealOccurrences.first(where: { $0.id == meal.id }),
                      let event = history.domain.events.last(where: { $0.request.target.id == meal.id }),
                      let definition = history.definitions.first(where: { $0.operationID == event.id })?.definition.withMeal(meal)
                else { throw DinnerPlanningError.stalePreview }
                original.scheduledDay = sealed.scheduledDay
                guard original == sealed, result[meal.id] == nil else { throw DinnerPlanningError.stalePreview }
                result[meal.id] = try definition.repeatSource()
            }
        }
        return result
    }

    func repeatWeekReview(start: MealDay, pickup: PickupModel) throws -> DinnerRepeatReview {
        guard editable, let shop, let identity = editorIdentity, let workspaceID = localIdeaWorkspaceID else {
            throw DinnerPlanningError.forbidden
        }
        let access = try access(for: shop.id)
        let sourceDays = try repeatDays(start: start, offsets: -7..<0)
        let targetDays = try repeatDays(start: start, offsets: 0..<7)
        let allowed = repeatSources(in: workspace, access: access)
        var visible = workspace
        visible.shops.removeAll { !allowed.contains($0.id) }
        let recovered = try recoveredDinners(in: visible, sourceDays: sourceDays, shopIDs: allowed, pickup: pickup)
        let now = clock()
        let candidates = try RepeatWeekEngine.candidates(targetStart: start, workspace: visible, recoveredMeals: recovered, access: access, at: now)
        let mealShops = Set(candidates.map { $0.source.shopID })
        let dates = Set(sourceDays)
        func sourceBelongsToWeek(_ row: ReviewedStaple) -> Bool {
            if mealShops.contains(row.source.shopID) { return true }
            let events = [row.line.handledAt, row.line.checkedAt, row.approval.approvedAt].compactMap { $0 }
            return events.contains { instant in
                (try? MealDay(date: instant, timeZoneIdentifier: start.timeZoneIdentifier)).map(dates.contains) == true
            }
        }
        let staples = access.hasPaidTools ? visible.priorStaples(for: shop.id).filter(sourceBelongsToWeek) : []
        let settled = access.hasPaidTools ? visible.reviewedStapleHistory(for: shop.id).filter(sourceBelongsToWeek) : []
        let context = try pickup.pantryReviewContext()
        let canonical = try context.map { try DinnerPantrySupply.build(context: $0, shopID: shop.id) }
        let unknownFoods = Set(context?.snapshot.lots.filter { $0.count.quantity == nil }.map(\.foodID) ?? [])
        let evidence = try DinnerRepeatEvidence.build(candidates: candidates, workspace: visible, workspaceID: workspaceID,
            authorizedShopIDs: allowed, targetShopID: shop.id, sourceDays: sourceDays, targetDays: targetDays,
            staples: staples + settled, recoveredMeals: recovered, canonical: canonical, unknownFoodIDs: unknownFoods, asOf: now)
        let sourceShopIDs = mealShops.union((staples + settled).map { $0.source.shopID })
        return DinnerRepeatReview(start: start, identity: identity, sourceShopIDs: sourceShopIDs, hasPaidEvidence: access.hasPaidTools, targetRevision: shop.revisionID,
            planningRevision: state.revisionID, pantryBasis: canonical?.basis, meals: candidates.map(DinnerRepeatChoice.init),
            staples: staples, evidence: evidence)
    }

    @discardableResult
    func prepareRepeatWeek(_ review: DinnerRepeatReview, choices: [DinnerRepeatChoice],
                           staples: [StapleSource: StapleChoice], stapleQuantities: [StapleSource: Quantity] = [:],
                           pickup: PickupModel) -> Bool {
        do {
            let current = try repeatWeekReview(start: review.start, pickup: pickup)
            guard current.identity == review.identity, current.targetRevision == review.targetRevision,
                  current.planningRevision == review.planningRevision, current.pantryBasis == review.pantryBasis,
                  choices.allSatisfy({ choice in current.meals.contains { $0.candidate == choice.candidate } }),
                  stapleQuantities.keys.allSatisfy({ staples[$0] == .needed }),
                  Set(staples.keys).isSubset(of: Set(review.staples.map(\.source))) else { throw DinnerPlanningError.stalePreview }
            let selectedStaples = try review.staples.compactMap { row -> RepeatWeek.StapleSelection? in
                guard let choice = staples[row.source] else { return nil }
                guard current.staples.contains(row) else { throw DinnerPlanningError.stalePreview }
                return .init(review: row, choice: choice, quantity: stapleQuantities[row.source])
            }
            let access = try access(for: review.identity.shopID)
            let recovered = try recoveredDinners(in: workspace, sourceDays: repeatDays(start: review.start, offsets: -7..<0),
                shopIDs: Set(choices.map { $0.candidate.source.shopID }), pickup: pickup)
            let preview = try RepeatWeekEngine.preview(targetStart: review.start, meals: choices.map(\.selection),
                staples: selectedStaples, workspace: workspace, recoveredMeals: recovered,
                access: access, phase: phaseProvider(review.identity.shopID), at: clock())
            installRepeatWeek(preview, pantryBasis: current.pantryBasis, pickup: pickup)
            return true
        } catch {
            cancelPreview()
            report(error)
            return false
        }
    }

    func repeatWeekAuthorization(for proposal: DinnerProposal) -> (@MainActor () -> Bool)? {
        guard let plan = proposal.repeatWeek else { return nil }
        let identity = editorIdentity
        let requiredShops = plan.sourceShopIDs.union([proposal.shopID])
        let accessProvider = accessProvider
        let clock = clock
        let usesCanonicalStock = reviewedPantryBasis != nil
        let legacyHeads = usesCanonicalStock ? [:] : repeatWeekPickup?.sourceHeads(for: requiredShops) ?? [:]
        return { [weak pickup = repeatWeekPickup, weak ledger = store as? LedgerModel] in
            guard let identity, let pickup, let ledger, pickup.recoveryLedger === ledger,
                  ledger.workspace.selectedShopID == identity.shopID, pickup.ready, !pickup.saving, !pickup.hasPendingSave,
                  pickup.pantryIsActive == usesCanonicalStock,
                  usesCanonicalStock ? pickup.pantryReadIsCurrent : pickup.sourceHeads(for: requiredShops) == legacyHeads
            else { return false }
            return requiredShops.allSatisfy { id in
                guard let access = accessProvider(id), access.scope == identity.scope,
                      access.actorID == identity.actorID, plan.staples.isEmpty || id != proposal.shopID || access.hasPaidTools,
                      (try? access.validate(shopID: id, at: clock(), applying: id == proposal.shopID)) != nil
                else { return false }
                return true
            }
        }
    }

    func applyRepeatWeek(_ proposal: DinnerProposal, workspace: inout LedgerWorkspace, access: DinnerAccessContext, at now: Date) throws {
        guard let repeatWeek = proposal.repeatWeek, let pickup = repeatWeekPickup else { throw DinnerPlanningError.stalePreview }
        if workspace.dinnerPlanning.applyReceipts.contains(where: { $0.id == proposal.id }) {
            _ = try RepeatWeekEngine.apply(proposal, workspace: &workspace, access: access, phase: phaseProvider(proposal.shopID), at: now)
            return
        }
        let allowed = repeatSources(in: workspace, access: access)
        let recovered = try recoveredDinners(in: workspace, sourceDays: repeatDays(start: repeatWeek.targetStart, offsets: -7..<0),
            shopIDs: allowed, pickup: pickup)
        // Check each historical shop against its own live authorization; a route
        // scoped to a single shop cannot reuse another shop's private history.
        guard repeatWeek.sourceShopIDs.isSubset(of: allowed), let workspaceID = localIdeaWorkspaceID else {
            throw DinnerPlanningError.forbidden
        }
        let canonical = try DinnerPantrySupply.read(pickup: pickup, workspaceID: workspaceID,
            linkedWorkspaceID: pickup.recoveryLedger?.sourceWorkspaceID, shopID: proposal.shopID)
        guard reviewedPantryBasis == canonical?.basis else { throw DinnerPlanningError.stalePreview }
        _ = try RepeatWeekEngine.apply(proposal, workspace: &workspace, recoveredMeals: recovered,
            access: access, phase: phaseProvider(proposal.shopID), at: now)
    }
}

private extension PickupRecoveryMealDefinition {
    func repeatSource() throws -> RepeatWeek.Recovery {
        let rules = Dictionary(grouping: ingredientRules, by: \.needID)
        let ingredients = try meal.ingredients.map { item in
            guard let matching = rules[item.need.id], matching.count == 1, let rule = matching.first else {
                throw DinnerPlanningError.stalePreview
            }
            return MealIngredient(id: item.need.id, name: item.foodName, quantity: item.need.amount,
                                  notes: rule.notes, exclusions: rule.exclusions)
        }
        var template = MealTemplate(id: meal.templateID ?? meal.id, title: meal.title, servings: meal.servings,
            ingredients: ingredients, notes: notes, sourceURL: sourceURL, exclusions: meal.exclusions,
            revision: meal.templateVersion ?? 0, servingGroups: groups, leadTimeMinutes: meal.requiredLeadMinutes,
            sourceEvidence: acceptedTemplate?.sourceEvidence)
        template.eligibilityEvidence = acceptedTemplate?.eligibilityEvidence
        try template.validate()
        return .init(meal: meal, template: template)
    }
}
