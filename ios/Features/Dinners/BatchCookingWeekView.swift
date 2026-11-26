import CoreDomain
import SwiftUI

private struct BatchWeekEvidence {
    let basis: DinnerPantrySupply.Basis?
    let covered: [Int]
}

private struct BatchWeekReview {
    let preview: DinnerPreview
    let week: BatchCookingWeek
    let editor: DinnerFeatureModel.EditorIdentity
    let evidence: BatchWeekEvidence
}

struct BatchCookingWeekView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    let editor: DinnerFeatureModel.EditorIdentity
    @State private var start: Date
    @State private var offsets = [0, 3]
    @State private var recipes: [UUID?] = [nil, nil]
    @State private var diners = Array(repeating: 3, count: 7)
    @State private var lunches = Array(repeating: 0, count: 7)
    @State private var review: BatchWeekReview?
    @State private var saving = false
    @State private var inputIssue: String?

    init(model: DinnerFeatureModel, editor: DinnerFeatureModel.EditorIdentity, start: Date) {
        self.model = model; self.editor = editor; _start = State(initialValue: start)
    }

    private var authorized: Bool {
        model.editorIdentity == editor && model.basketPrepAccess() && model.paid && model.localIdeaWorkspaceID != nil
    }

    private var firstDay: MealDay? {
        guard let zone = model.shop?.basis.timeZoneIdentifier else { return nil }
        return try? MealDay(date: start, timeZoneIdentifier: zone)
    }

    /// Dates are local civil days in this shop; avoid UTC shifts across DST.
    private var dates: [MealDay] {
        guard let start = firstDay, let date = start.date, let zone = TimeZone(identifier: start.timeZoneIdentifier) else { return [] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: date).flatMap { try? MealDay(date: $0, timeZoneIdentifier: zone.identifier) }
        }
    }

    private var saved: DinnerApplyReceipt? {
        guard let firstDay else { return nil }
        guard let local = model.localIdeaWorkspaceID else { return nil }
        return model.state.applyReceipts.last {
            $0.proposal.shopID == editor.shopID && $0.proposal.namespace == "local:\(local.uuidString)" &&
                $0.appliedBy == editor.actorID && $0.proposal.batchWeek?.start == firstDay
        }
    }

    var body: some View {
        WorkingForm {
            if authorized {
                if review == nil {
                    DatePicker(dinnerText("Week starting"), selection: $start, displayedComponents: .date)
                        .environment(\.timeZone, model.shop.flatMap { TimeZone(identifier: $0.basis.timeZoneIdentifier) } ?? .current)
                }
                if let saved, let week = saved.proposal.batchWeek {
                    BatchWeekResult(model: model, pickup: pickup, proposal: saved.proposal, week: week, saved: true,
                                    currentCovered: try? evidence(days: dates, excluding: cookIDs(for: saved.proposal)).covered)
                } else if let review {
                    BatchWeekResult(model: model, pickup: pickup, proposal: review.preview.proposal, week: review.week,
                                    saved: false, currentCovered: review.evidence.covered)
                    Button(dinnerText("Confirm cooking sessions and groceries")) { Task { await apply(review) } }
                        .disabled(saving || !model.editable || review.preview.needsPurchaseAmendment)
                    Button(dinnerText("Edit week")) { self.review = nil }.disabled(saving)
                } else {
                    inputs
                    if let inputIssue { Text(inputIssue).foregroundStyle(Theme.error) }
                }
                DinnerFeedback(model: model)
            } else {
                Text(dinnerText("Planning access changed or expired. Reconnect and review again."))
            }
        }
        .navigationTitle(dinnerText("Two cooking sessions"))
        .dinnerAccess(model)
    }

    @ViewBuilder private var inputs: some View {
        let weekDays = dates
        if weekDays.count == 7 {
            ForEach(0..<2, id: \.self) { index in
                Section(dinnerFormat("Cooking session %d", index + 1)) {
                    Picker(dinnerText("Cook on"), selection: $offsets[index]) {
                        ForEach(weekDays.indices, id: \.self) { Text(dinnerDay(weekDays[$0])).tag($0) }
                    }
                    Picker(dinnerText("Accepted dinner"), selection: $recipes[index]) {
                        Text(dinnerText("Select dinner")).tag(UUID?.none)
                        ForEach(model.state.acceptedDinners) { Text(verbatim: $0.template.title).tag(Optional($0.id)) }
                    }
                }
            }
            if offsets[0] >= offsets[1] { Text(dinnerText("Choose the second cooking day after the first.")) }
            if model.state.acceptedDinners.isEmpty {
                Text(dinnerText("Save a reusable dinner with measured ingredients before planning cooking sessions."))
            }
            ForEach(weekDays.indices, id: \.self) { i in
                Section(dinnerDay(weekDays[i])) {
                    Stepper(dinnerFormat("Dinner portions: %d", diners[i]), value: $diners[i], in: 0...100)
                    Stepper(dinnerFormat("Promised lunch portions: %d", lunches[i]), value: $lunches[i], in: 0...100)
                }
            }
            Button(dinnerText("Review portions and groceries")) { prepare() }
                .disabled(recipes.contains(nil) || offsets[0] >= offsets[1] || !model.editable)
        }
    }

    private func cookIDs(for proposal: DinnerProposal) -> Set<UUID> {
        let occurrences = Set(proposal.changes.compactMap { change -> UUID? in
            if case .choose(let meal) = change { return meal.occurrenceID }
            return nil
        })
        let records = pickup.journeys.first { $0.id == editor.shopID }?.cookedMeals ?? []
        return Set(records.filter { $0.draft.ledgerID == model.localIdeaWorkspaceID && occurrences.contains($0.draft.meal.id) }.map { $0.draft.id })
    }

    private func evidence(days: [MealDay], excluding cookIDs: Set<UUID> = []) throws -> BatchWeekEvidence {
        guard authorized, days.count == 7, model.store === pickup.recoveryLedger, pickup.ready,
              !pickup.hasPendingSave, !pickup.saving else { throw DinnerPlanningError.forbidden }
        guard let context = try pickup.pantryReviewContext() else { return .init(basis: nil, covered: Array(repeating: 0, count: 7)) }
        let snapshot = context.snapshot
        let covered = Dictionary(uniqueKeysWithValues: snapshot.availability.reservations.map { ($0.id, $0) })
        var byDay = Array(repeating: 0, count: 7)
        for claim in snapshot.reservations {
            guard claim.state == .active, let dinner = claim.cookedDinner, dinner.servedAt == nil,
                  dinner.ledgerID == model.localIdeaWorkspaceID, dinner.shopID == editor.shopID, !cookIDs.contains(dinner.cookID),
                  let i = days.firstIndex(where: { $0.hasSameCivilDate(as: dinner.day) }),
                  let coverage = covered[claim.id], !coverage.unresolved, coverage.shortfall?.amount == .zero,
                  let amount = coverage.backed, amount.unit == .count else { continue }
            // Only whole portions of this fully backed, date-specific dinner can displace diners.
            byDay[i] = min(100, byDay[i] + Int(min(100, amount.amount.numerator / amount.amount.denominator)))
        }
        let canonical = try DinnerPantrySupply.build(context: context, shopID: editor.shopID)
        return .init(basis: canonical.basis, covered: byDay)
    }

    private func prepare() {
        inputIssue = nil
        do {
            guard authorized, let shop = model.shop, let firstDay, let first = recipes[0], let second = recipes[1] else {
                throw DinnerPlanningError.forbidden
            }
            let evidence = try evidence(days: dates)
            let week = try BatchCookingWeek(start: firstDay, days: diners.indices.map {
                .init(diners: diners[$0], lunches: lunches[$0], covered: min(diners[$0], evidence.covered[$0]))
            }, sessions: [.init(offset: offsets[0], acceptedID: first), .init(offset: offsets[1], acceptedID: second)],
            lunchLabel: dinnerText("Promised lunches"))
            let preview = try week.preview(ledger: shop, state: model.state, access: model.access(for: shop.id),
                                          phase: model.phaseProvider(shop.id), at: model.clock())
            review = .init(preview: preview, week: week, editor: editor, evidence: evidence)
            model.clearErrorAfterSuccessfulReview()
        } catch DinnerPlanningError.reviewRequired("batchRecipe") {
            inputIssue = dinnerText("Each cooking session needs at least one portion and a saved recipe with reviewed quantities and no existing serving groups.")
        } catch DinnerPlanningError.reviewRequired("openNights") {
            inputIssue = dinnerText("A dinner or an away note already covers one of these dates. Review the eating days before adding groceries.")
        } catch { model.report(error) }
    }

    private func apply(_ reviewed: BatchWeekReview) async {
        guard !saving, let ledger = model.store as? LedgerModel, let day = firstDay, reviewed.week.start == day else { return }
        let proposal = reviewed.preview.proposal
        let valid = { @MainActor in
            authorized && model.editorIdentity == reviewed.editor && pickup.recoveryLedger === ledger && pickup.ready &&
                pickup.pantryIsActive == (reviewed.evidence.basis != nil) && (!pickup.pantryIsActive || pickup.pantryReadIsCurrent) &&
                model.phaseProvider(editor.shopID) == .draft && model.shop?.id == proposal.shopID
        }
        do {
            let current = try evidence(days: dates)
            guard valid(), current.basis == reviewed.evidence.basis, current.covered == reviewed.evidence.covered else {
                throw DinnerPlanningError.stalePreview
            }
            saving = true; defer { saving = false }
            var failure: Error?
            let success = await ledger.change(key: "batch-week-\(proposal.id)", reviewedPantryBasis: current.basis, authorize: valid) { workspace in
                do {
                    guard valid(), workspace.selectedShopID == proposal.shopID,
                          let i = workspace.shops.firstIndex(where: { $0.id == proposal.shopID }) else { throw DinnerPlanningError.forbidden }
                    _ = try DinnerPlanningEngine.apply(proposal, ledger: &workspace.shops[i], state: &workspace.dinnerPlanning,
                        access: model.access(for: proposal.shopID), phase: model.phaseProvider(proposal.shopID), at: model.clock())
                } catch { failure = error; throw error }
            }
            if success { review = nil } else { model.report(failure ?? DinnerPlanningError.stalePreview) }
        } catch { model.report(error) }
    }
}

private struct BatchWeekResult: View {
    @ObservedObject var model: DinnerFeatureModel
    @ObservedObject var pickup: PickupModel
    let proposal: DinnerProposal
    let week: BatchCookingWeek
    let saved: Bool
    let currentCovered: [Int]?

    private func unchanged(_ plan: PlannedDinner) -> Bool {
        guard saved else { return true }
        guard let shop = model.shop, let meal = shop.mealOccurrences.first(where: { $0.id == plan.occurrenceID }),
              meal.removedAt == nil, !meal.isHidden, meal.scheduledDay == plan.day, meal.servings == plan.template.servings,
              meal.title == plan.template.title, meal.servingGroups == plan.template.servingGroups,
              meal.ingredientContributionIDs == plan.contributionIDs else { return false }
        for (i, id) in plan.contributionIDs.enumerated() {
            guard let source = shop.contributions.first(where: { $0.id == id }), source.removedAt == nil,
                  source.quantity == plan.template.ingredients[i].quantity, source.productName == plan.template.ingredients[i].name else { return false }
        }
        return true
    }

    private func cook(for meal: PlannedDinner) -> CookCompletionDraft? {
        guard saved, pickup.ready, pickup.pantryRouteAvailable, pickup.pantryReadIsCurrent,
              let records = pickup.journeys.first(where: { $0.id == proposal.shopID })?.cookedMeals else { return nil }
        return records.last { $0.isActive && $0.draft.ledgerID == model.localIdeaWorkspaceID && $0.draft.meal.id == meal.occurrenceID }?.draft
    }

    /// Deduct confirmed physical holds from the session that produced them before
    /// projecting freely assignable yield. Only a dated, backed hold covers an eating day.
    private func reconciliation(_ cooks: [CookCompletionDraft?]) -> BatchCookingWeek.Coverage? {
        guard let currentCovered else { return nil }
        var yields: [BatchCookingWeek.MeasuredYield?] = [nil, nil]
        for (session, cook) in cooks.enumerated() {
            guard let cook else { continue }
            guard let snapshot = pickup.pantrySnapshot, pickup.pantryReadIsCurrent,
                  snapshot.state.workspaceID == cook.inventoryID else { return nil }
            let lots = Set(cook.leftovers.map(\.id))
            guard let originalHolds = try? cook.leftovers.flatMap({ try cook.outputReservations(for: $0) }) else { return nil }
            let lunchIDs = Set(originalHolds.filter { $0.personal != nil }.map(\.id))
            var holds: [BatchCookingWeek.MeasuredYield.Hold] = []
            for hold in snapshot.reservations where hold.lotID.map(lots.contains) == true {
                let served = hold.cookedDinner?.servedAt != nil
                guard hold.state != .released || served else { continue }
                guard let amount = hold.amount, amount.unit == .count else { return nil }
                if !served {
                    guard hold.state == .active, let basis = snapshot.availability.reservations.first(where: { $0.id == hold.id }),
                          !basis.unresolved, basis.backed?.amount == amount.amount, basis.shortfall?.amount == .zero else { return nil }
                }
                if let dinner = hold.cookedDinner, dinner.ledgerID == cook.ledgerID, dinner.shopID == cook.shopID {
                    let day = week.days.indices.first { (try? week.date($0).hasSameCivilDate(as: dinner.day)) == true }
                    holds.append(.dinner(amount.amount, offset: day))
                } else if lunchIDs.contains(hold.id) {
                    holds.append(.lunch(amount.amount))
                } else {
                    holds.append(.other(amount.amount))
                }
            }
            yields[session] = .init(made: cook.servingsMade, holds: holds)
        }
        return try? week.reconcile(yields: yields, otherDinnerCoverage: currentCovered)
    }

    var body: some View {
        let meals = proposal.changes.compactMap { change -> PlannedDinner? in
            if case .choose(let planned) = change { return planned }; return nil
        }
        if meals.count == 2 {
            let cooks = meals.map { cook(for: $0) }
            let unchanged = meals.map { self.unchanged($0) }
            let status = unchanged.contains(false) ? nil : reconciliation(cooks)
            ForEach(meals.indices, id: \.self) { i in
                Section(dinnerFormat("Cooking session %d", i + 1)) {
                    Text(verbatim: meals[i].template.title).font(.headline)
                    if let day = meals[i].day { Text(dinnerDay(day)) }
                    Text(dinnerFormat("Plan to cook %d portions", week.target(for: i)))
                    if meals[i].template.recipeSteps?.isEmpty == false {
                        Text(dinnerText("Shopping amounts use the batch size. Check amounts written in the original cooking steps."))
                    }
                    if !unchanged[i] {
                        Text(dinnerText("This session changed after the groceries were approved. Review the current dinner before using the portion plan."))
                    }
                    if let made = cooks[i]?.servingsMade { Text(dinnerFormat("Recorded yield: %@ portions", made.description)) }
                    ForEach(meals[i].template.ingredients) { ingredient in
                        LabeledContent(ingredient.name, value: dinnerQuantity(ingredient.quantity))
                    }
                    if let cooked = cooks[i], let claims = try? model.cookedDinners(pickup: pickup) {
                        ForEach(claims.filter { $0.cookedDinner?.cookID == cooked.id && $0.state == .active }) { claim in
                            NavigationLink {
                                DinnerCookedPortionsView(model: model, id: claim.id)
                            } label: {
                                DinnerCookedPortionsLabel(claim: claim)
                            }
                        }
                    }
                    if saved, unchanged[i], let ledger = model.store as? LedgerModel, pickup.pantryIsActive {
                        NavigationLink(dinnerText("Review actual cooking and portions")) {
                            CookCompletionEntry(ledger: ledger, pickup: pickup, shopID: proposal.shopID, mealID: meals[i].occurrenceID)
                        }
                    }
                }
            }
            Section(dinnerText("Eating days")) {
                ForEach(week.days.indices, id: \.self) { i in
                    if let day = try? week.date(i) {
                        VStack(alignment: .leading) {
                            Text(dinnerDay(day)).font(.headline)
                            if let j = week.sessionIndex(on: i) {
                                Text(dinnerFormat(week.sessions[j].offset == i ? "Cook: %@" : "Reheat: %@", meals[j].template.title))
                            }
                            Text(dinnerFormat("Dinner portions: %d", week.days[i].diners))
                            Text(dinnerFormat("Promised lunch portions: %d", week.days[i].lunches))
                            if let coverage = status?.covered, coverage[i] > 0 {
                                Text(dinnerFormat("Already covered by reserved dinner portions: %d", min(week.days[i].diners, coverage[i])))
                            }
                            if let gaps = status?.gaps, gaps[i].diners + gaps[i].lunches > 0 {
                                Text(dinnerFormat("Uncovered: %d dinner, %d lunch", gaps[i].diners, gaps[i].lunches)).bold()
                            }
                        }
                    }
                }
                Text(dinnerText("Lunch portions take priority when a batch yields less. Review any physical changes in the cooked batch."))
                Text(dinnerText("The schedule compares yields with the portions you planned. Check remaining food in Pantry before serving."))
                if status == nil && !unchanged.contains(false) { Text(dinnerText("Refresh the pantry to check current portion coverage.")) }
            }
        }
    }
}
