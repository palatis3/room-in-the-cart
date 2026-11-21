import SwiftUI
import CoreDomain

@MainActor enum TonightPlanChoice {
    struct Review {
        fileprivate let selection: TonightDinnerSelection
        fileprivate let identity: CapturePrivateIdentity
        fileprivate let ledgerID: UUID
        fileprivate let pantryGeneration: UUID
        fileprivate let match: PantryMealMatcher.Review
        let estimate: TonightPurchaseEstimate?
        let pantryBasis: LedgerCanonicalPackStockEvidence.Basis
        var plannedDay: MealDay { selection.plannedDay }
        var recipe: MealTemplate { selection.recipe }
        var destinationTitle: String { selection.destinationTitle }
        var createsPickup: Bool { selection.createsPickup }
        var preview: DinnerPreview { selection.preview }
    }

    static func prepare(match: PantryMealMatcher.Review, pantryBasis: LedgerCanonicalPackStockEvidence.Basis,
                        destinationShopID: UUID?, newShopTitle: String, ledger: LedgerModel, pickup: PickupModel,
                        plannedDate: Date? = nil, currentIdentity: () -> CapturePrivateIdentity?) throws -> Review {
        guard let identity = currentIdentity(), ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              let ledgerID = ledger.sourceWorkspaceID, let current = try pickup.pantryReviewContext() else {
            throw DinnerPlanningError.forbidden
        }
        let heads = current.mapping.sourceHeads.map {
            LedgerCanonicalPackStockEvidence.SourceHead(journeyID: $0.id, revision: $0.revision)
        }
        let basis = LedgerCanonicalPackStockEvidence.Basis(originID: current.snapshot.state.workspaceID,
            inventoryRevision: current.snapshot.state.revision, sourceHeads: heads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        guard pantryBasis == basis else { throw DinnerPlanningError.stalePreview }

        let destination: ShoppingLedger
        if let destinationShopID {
            guard let shop = ledger.workspace.shops.first(where: { $0.id == destinationShopID }) else { throw DinnerPlanningError.stalePreview }
            destination = shop
        } else {
            let title = newShopTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw DinnerPlanningError.invalid("shopTitle") }
            destination = ShoppingLedger(title: title)
        }
        let now = Date()
        let context = access(identity, ledgerID: ledgerID, shopID: destination.id, now: now)
        let selection = try TonightDinnerSelection.prepare(match: match, destination: destination, createsPickup: destinationShopID == nil,
            workspace: ledger.workspace, access: context, phase: phase(pickup, shopID: destination.id), now: now, plannedDate: plannedDate)
        let estimate = try? TonightPurchaseEstimate.estimate(match, workspace: ledger.workspace,
            workspaceID: ledgerID, shopID: destinationShopID, at: now)
        return Review(selection: selection, identity: identity, ledgerID: ledgerID,
                      pantryGeneration: pickup.privatePantryGeneration, match: match, estimate: estimate, pantryBasis: basis)
    }

    static func apply(_ review: Review, ledger: LedgerModel, pickup: PickupModel,
                      currentIdentity: @escaping @MainActor () -> CapturePrivateIdentity?) async -> Bool {
        let proposal = review.preview.proposal
        let authorized = {
            currentIdentity() == review.identity && ledger.sourceWorkspaceID == review.ledgerID &&
                pickup.privatePantryGeneration == review.pantryGeneration && pickup.sourceWorkspaceID == review.pantryBasis.originID
        }
        guard authorized() else { return false }
        return await ledger.change(key: "tonight-\(proposal.id)", reviewedPantryBasis: review.pantryBasis, authorize: authorized) { workspace in
            let now = Date()
            if !workspace.dinnerPlanning.applyReceipts.contains(where: { $0.id == proposal.id }) {
                let estimate = try? TonightPurchaseEstimate.estimate(review.match, workspace: workspace, workspaceID: review.ledgerID,
                    shopID: review.createsPickup ? nil : proposal.shopID, at: now)
                guard estimate == review.estimate else { throw DinnerPlanningError.stalePreview }
            }
            try review.selection.apply(to: &workspace,
                access: access(review.identity, ledgerID: review.ledgerID, shopID: proposal.shopID, now: now),
                phase: phase(pickup, shopID: proposal.shopID), now: now)
        }
    }

    private static func access(_ identity: CapturePrivateIdentity, ledgerID: UUID, shopID: UUID, now: Date) -> DinnerAccessContext {
        let actor = identity.actorID.uuidString
        return DinnerAccessContext(scope: .local(workspaceID: ledgerID), actorID: actor, shopID: shopID,
            assignedShopperID: actor, canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(30))
    }

    static func phase(_ pickup: PickupModel, shopID: UUID) -> BasketPhase {
        guard pickup.ready, !pickup.saving, !pickup.hasPendingSave else { return .frozen }
        let journey = pickup.journeys.first { $0.id == shopID }
        guard journey?.closedAt == nil else { return .frozen }
        return journey?.basket?.phase ?? .draft
    }
}

struct SavedDinnerHandoffLink: View {
    let recipe: MealTemplate
    private enum Destination: Int, Identifiable { case plan, groceries; var id: Int { rawValue } }
    @State private var destination: Destination?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(dinnerText("Plan this dinner")) { destination = .plan }
                .buttonStyle(PrimaryAction()).accessibilityIdentifier("dinner.planSaved")
            Button { destination = .groceries } label: {
                Label(dinnerText("Shop for ingredients only"), systemImage: "checklist")
                    .frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless).accessibilityIdentifier("dinner.shopSaved")
        }.sheet(item: $destination) { destination in
            NavigationStack { SavedDinnerHandoffView(recipe: recipe, selectingGroceries: destination == .groceries) }
        }
    }
}

struct SavedDinnerHandoffView: View {
    let recipe: MealTemplate
    @Environment(\.currentDinnerPlanner) private var planner
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var dismiss

    @State private var originalIdentity: CapturePrivateIdentity?
    @State private var ledgerID: UUID?
    @State private var destinationID: UUID?
    @State private var startingPickup = false
    @State private var selectingGroceries = false
    @State private var selected: Set<UUID> = []
    @State private var plannedDate: Date?
    @State private var plannedServings: Rational
    @State private var editingPlan = false
    @State private var review: SavedDinnerReview?
    @State private var error: String?
    @State private var busy = false

    init(recipe: MealTemplate, selectingGroceries: Bool = false) {
        self.recipe = recipe
        _plannedServings = State(initialValue: recipe.servings)
        _selectingGroceries = State(initialValue: selectingGroceries)
    }

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var authorized: Bool {
        originalIdentity != nil && originalIdentity == identity && ledgerID != nil && ledger.sourceWorkspaceID == ledgerID
    }
    private func context(at now: Date) throws -> DinnerAccessContext {
        guard authorized, let ledgerID, let actor = originalIdentity?.actorID.uuidString, let destinationID,
              ledger.ready, ledger.shop?.id == destinationID else { throw DinnerPlanningError.forbidden }
        return .init(scope: .local(workspaceID: ledgerID), actorID: actor, shopID: destinationID,
            assignedShopperID: actor, canPlan: true, canReadBudget: false, hasPaidTools: membership.model?.hasPaidAccess == true,
            roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30))
    }
    var body: some View {
        WorkingForm {
            if !authorized || destinationID != ledger.workspace.selectedShopID {
                Text(dinnerText("The pickup or dinner plan changed. Make a new preview before applying."))
            } else if let review, review.isApplied(in: ledger.workspace) {
                Section {
                    Label(review.plansDinner ? dinnerText(isTonight(review) ? "Dinner planned for tonight" : "Dinner planned") : dinnerText("Groceries added"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.onSelection).font(.headline).accessibilityIdentifier("dinner.handoff.saved")
                    Text(verbatim: recipe.title).font(.system(.title2, design: .serif, weight: .semibold))
                    if let day = review.plannedDay, let count = review.plannedServings {
                        Text(planSummary(day, count))
                    }
                    Text(countLabel(review, saved: true))
                    if let occurrenceID = review.occurrenceID, let planner, planner.store === ledger,
                       planner.shop?.id == review.shopID, planner.accessAvailable {
                        NavigationLink(dinnerText("View planned dinner")) {
                            DinnerOccurrenceView(model: planner, occurrenceID: occurrenceID)
                        }.accessibilityIdentifier("dinner.handoff.openPlan")
                    }
                    NavigationLink(ledgerText("Shopping list")) {
                        LedgerHomeView(model: ledger).navigationTitle(ledgerText("Shopping list")).navigationBarTitleDisplayMode(.inline)
                    }.accessibilityIdentifier("dinner.handoff.openList")
                }
            } else {
                Section {
                    Text(verbatim: recipe.title).font(.system(.title2, design: .serif, weight: .semibold))
                    if selectingGroceries {
                        Text(dinnerFormat("Servings: %@", amountText(recipe.servings)))
                    } else {
                        Button { editingPlan = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(dinnerText("Change day and servings"), systemImage: "calendar")
                                if let day = try? MealDay(date: plannedDate ?? Date(), timeZoneIdentifier: planZone.identifier) {
                                    Text(planSummary(day, plannedServings)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }.accessibilityIdentifier("dinner.handoff.editPlan")
                    }
                    if let minutes = recipe.leadTimeMinutes {
                        Label(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes])), systemImage: "clock")
                    }
                    if let shop = ledger.shop {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(ledgerText("Shopping list"), systemImage: "cart").foregroundStyle(Theme.secondary)
                            Text(verbatim: shop.title).font(.headline)
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("dinner.handoff.destination")
                    }
                    if !ledger.workspace.shops.isEmpty { pickupMenu }
                }
                if !ledger.workspace.mealTemplates.contains(recipe) && !ledger.workspace.dinnerPlanning.acceptedDinners.contains(where: { $0.template == recipe }) {
                    Text(dinnerText("Your saved recipe changed. Open the current version to continue."))
                } else if destinationID == nil {
                    Section {
                        Text(dinnerText(selectingGroceries ? "Name your shopping list, then choose the ingredients to add." : "Give your pickup a name to keep its dinner and grocery list together."))
                        Button(dinnerText(selectingGroceries ? "Name your shopping list" : "Name your pickup")) { startingPickup = true }.buttonStyle(PrimaryAction())
                            .accessibilityIdentifier("dinner.handoff.startPickup")
                    }
                } else if let review {
                    Section(dinnerText(review.plansDinner ? "Ingredients for the whole dinner" : "Selected groceries")) {
                        ForEach(review.ingredients) { ingredientRow($0) }
                    }
                    Section {
                        if let day = review.plannedDay, let count = review.plannedServings {
                            Text(planSummary(day, count)).font(.headline)
                            Text(dinnerFormat("Planning adds all the ingredient amounts shown to %@.", review.destinationTitle))
                        } else {
                            Text(dinnerText("Only the selected groceries go on this list. Your dinner schedule stays as it is."))
                        }
                        Button(review.plansDinner ? dinnerText(isTonight(review) ? "Plan for tonight" : "Plan for this day") : countLabel(review)) {
                            Task { await apply(review) }
                        }.buttonStyle(PrimaryAction()).accessibilityIdentifier("dinner.handoff.confirm")
                        if review.plansDinner { shopInstead }
                        else { Button(tonightText("Keep editing")) { self.review = nil; error = nil } }
                    }.disabled(busy || ledger.saving || ledger.hasPendingSave)
                } else if selectingGroceries {
                    Section {
                        Text(dinnerText("Select the ingredients you need to buy."))
                        ForEach(recipe.ingredients) { ingredient in
                            Toggle(isOn: Binding(get: { selected.contains(ingredient.id) }, set: { included in
                                if included { selected.insert(ingredient.id) } else { selected.remove(ingredient.id) }
                            })) { ingredientRow(ingredient) }
                                .toggleStyle(DinnerRowToggleStyle())
                                .accessibilityIdentifier("dinner.handoff.ingredient." + ingredient.id.uuidString)
                        }
                        Button(dinnerText("Review selected groceries")) { prepare(.groceries(selected)) }
                            .buttonStyle(PrimaryAction()).disabled(selected.isEmpty)
                            .accessibilityIdentifier("dinner.handoff.review")
                    }
                } else if error != nil {
                    Section {
                        Button(dinnerText("Review dinner again")) { prepare(.planTonight) }
                        shopInstead
                    }
                } else {
                    ProgressView()
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning) }
                if ledger.saving || ledger.hasPendingSave || ledger.error != nil {
                    LedgerSaveStatus(model: ledger, showsLastSave: false)
                }
            }
        }.workingSurface().navigationTitle(dinnerText(selectingGroceries ? "Shop for ingredients only" : "Plan this dinner")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(ledgerText("Done")) { dismiss() }.disabled(busy || ledger.saving).accessibilityIdentifier("dinner.handoff.done")
            } }
            .interactiveDismissDisabled(busy || ledger.saving)
            .onAppear {
                guard originalIdentity == nil else { return }
                originalIdentity = identity
                ledgerID = ledger.sourceWorkspaceID
                destinationID = ledger.workspace.selectedShopID
            }
            .task(id: readyPlanDestination) {
                if readyPlanDestination != nil, review == nil { prepare(.planTonight) }
            }
            .sheet(isPresented: $editingPlan) {
                NavigationStack {
                    DinnerPlanFactsEditor(date: plannedDate ?? Date(), servings: plannedServings, zone: planZone) { date, count in
                        plannedDate = date
                        plannedServings = count
                        review = nil
                        if readyPlanDestination != nil { prepare(.planTonight) }
                        editingPlan = false
                    }
                }
            }
            .sheet(isPresented: $startingPickup) {
                NavigationStack {
                    LedgerNewShopView(model: ledger, title: suggestedListName, namingShoppingList: selectingGroceries, authorize: canChangePickup,
                        onShopSelected: didSelectPickup)
                }
            }
    }

    private var planZone: TimeZone {
        ledger.shop.flatMap { TimeZone(identifier: $0.basis.timeZoneIdentifier) } ?? .current
    }
    private func isTonight(_ review: SavedDinnerReview) -> Bool {
        review.plannedDay == (try? MealDay(date: Date(), timeZoneIdentifier: planZone.identifier))
    }
    private func planSummary(_ day: MealDay, _ count: Rational) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: day.timeZoneIdentifier)
        return dinnerFormat("%@ · %@ servings", day.date.map(formatter.string(from:)) ?? day.iso8601, amountText(count))
    }

    private var suggestedListName: String {
        let title = dinnerFormat("Groceries for %@", recipe.title)
        return title.utf8.count <= 512 ? title : ledgerText("Shopping list")
    }

    /// Preparing the exact recipe version is read-only. The confirm button owns the sole write.
    private var readyPlanDestination: UUID? {
        guard !selectingGroceries, authorized, ledger.ready, pickup.ready, !ledger.saving, !ledger.hasPendingSave,
              !pickup.saving, !pickup.hasPendingSave, ledger.workspace.selectedShopID == destinationID else { return nil }
        return destinationID
    }

    private var shopInstead: some View {
        Button {
            selectingGroceries = true
            review = nil
            error = nil
        } label: { Label(dinnerText("Shop for ingredients only"), systemImage: "checklist") }
        .accessibilityIdentifier("dinner.handoff.select")
    }

    private var pickupMenu: some View {
        Menu {
            ForEach(ledger.workspace.shops.filter { $0.id != destinationID && TonightPlanChoice.phase(pickup, shopID: $0.id) == .draft }) { shop in
                Button(shop.title) { Task {
                    await ledger.selectShop(shop.id, authorize: canChangePickup, onSelected: didSelectPickup)
                } }
            }
            Button(selectingGroceries ? dinnerText("Create shopping list") : ledgerText("Start another pickup")) { startingPickup = true }
        } label: {
            Label(dinnerText(ledger.shop == nil ? "Choose a shopping list" : "Change shopping list"),
                  systemImage: "chevron.up.chevron.down")
        }
        .disabled(busy || ledger.saving || ledger.hasPendingSave)
        .accessibilityIdentifier("dinner.handoff.pickup")
    }

    private func canChangePickup() -> Bool {
        authorized && ledger.workspace.selectedShopID == destinationID &&
            (ledger.workspace.mealTemplates.contains(recipe) || ledger.workspace.dinnerPlanning.acceptedDinners.contains { $0.template == recipe })
    }

    private func didSelectPickup(_ id: UUID) {
        if authorized { destinationID = id; review = nil; error = nil }
    }

    private func ingredientRow(_ ingredient: MealIngredient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: ingredient.name).font(.headline)
            Text(ingredient.reviewedAmountLabel).foregroundStyle(Theme.secondary)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
    private func countLabel(_ review: SavedDinnerReview, saved: Bool = false) -> String {
        let count = review.ingredients.count
        if count == 1 {
            return dinnerFormat(saved ? "1 ingredient added to %@" : "Add 1 ingredient to %@", review.destinationTitle)
        }
        return dinnerFormat(saved ? "%lld ingredients added to %@" : "Add %lld ingredients to %@", Int64(count), review.destinationTitle)
    }
    private func prepare(_ action: SavedDinnerReview.Action) {
        do {
            let now = Date(), access = try context(at: now)
            var requested = action
            if case .planTonight = action {
                let day = try MealDay(date: plannedDate ?? now, timeZoneIdentifier: planZone.identifier)
                requested = .plan(day: day, servings: plannedServings)
            }
            review = try SavedDinnerReview(recipe: recipe, action: requested, workspace: ledger.workspace, access: access,
                phase: TonightPlanChoice.phase(pickup, shopID: access.shopID), at: now)
            error = nil
        } catch { self.error = message(error) }
    }
    private func message(_ error: Error) -> String {
        switch error {
        case DinnerPlanningError.paidAccessRequired: dinnerText("This assisted tool requires paid access. Manual dinner editing remains available.")
        case DinnerPlanningError.lockedBasket: dinnerText("This basket is locked. Save a proposal for a purchase amendment.")
        case DinnerPlanningError.reviewRequired("mealPreferences"): dinnerText("Review ingredient and appliance details against your meal preferences.")
        default: dinnerText("The pickup or dinner plan changed. Make a new preview before applying.")
        }
    }
    @MainActor private func apply(_ review: SavedDinnerReview) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        func validate() throws {
            let now = Date()
            try review.validateDestination(in: ledger.workspace, access: context(at: now),
                phase: TonightPlanChoice.phase(pickup, shopID: review.shopID), at: now)
        }
        do {
            try validate()
            let saved = await ledger.change(key: "saved-dinner-\(review.id)", reviewedPantryBasis: nil, authorize: { (try? validate()) != nil }) { workspace in
                let now = Date()
                try review.apply(to: &workspace, access: context(at: now), phase: TonightPlanChoice.phase(pickup, shopID: review.shopID), at: now)
            }
            if !saved && !ledger.hasPendingSave { error = ledger.error ?? message(DinnerPlanningError.stalePreview) }
        } catch {
            self.review = nil
            self.error = message(error)
        }
    }
}

private struct DinnerPlanFactsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var count: String
    let zone: TimeZone
    let apply: (Date, Rational) -> Void

    init(date: Date, servings: Rational, zone: TimeZone, apply: @escaping (Date, Rational) -> Void) {
        _date = State(initialValue: date)
        _count = State(initialValue: ledgerAmountInput(servings))
        self.zone = zone
        self.apply = apply
    }
    var body: some View {
        WorkingForm {
            DinnerPlanDateField(date: $date, zone: zone)
            DinnerServingField(count: $count, identifier: "dinner.plan.servings")
            Text(dinnerText("Changing servings keeps the grocery amounts shown. You can edit individual amounts in the planned dinner."))
            Button(dinnerText("Review dinner plan")) {
                if let value = try? DinnerEntry.positive(count) { apply(date, value) }
            }.buttonStyle(PrimaryAction()).disabled((try? DinnerEntry.positive(count)) == nil)
            .accessibilityIdentifier("dinner.plan.reviewFacts")
        }.navigationTitle(dinnerText("Change day and servings")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }
}

struct DinnerPlanDateField: View {
    @Binding var date: Date
    let zone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dinnerText("Dinner date")).font(.headline)
            DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact).labelsHidden().fixedSize()
                .environment(\.timeZone, zone).accessibilityIdentifier("dinner.plan.date")
            ViewThatFits(in: .horizontal) {
                HStack { shortcuts }
                VStack(alignment: .leading) { shortcuts }
            }
        }
    }
    @ViewBuilder private var shortcuts: some View {
        Button(dinnerText("Today")) { date = Date() }.buttonStyle(.bordered).accessibilityIdentifier("dinner.plan.today")
        Button(dinnerText("Tomorrow")) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) { date = tomorrow }
        }.buttonStyle(.bordered).accessibilityIdentifier("dinner.plan.tomorrow")
    }
}

struct DinnerServingField: View {
    @Binding var count: String
    let identifier: String
    private var value: Rational? { try? DinnerEntry.positive(count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dinnerText("Total servings")).font(.headline)
            TextField(dinnerText("Total servings"), text: $count)
                .keyboardType(.numbersAndPunctuation).textFieldStyle(WorkingInputStyle())
                .accessibilityIdentifier(identifier)
            HStack {
                Button {
                    if let value, let next = try? value.subtracting(.one), next > .zero { count = ledgerAmountInput(next) }
                } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(value.map { $0 <= .one } ?? true)
                    .accessibilityLabel(dinnerText("One fewer serving")).accessibilityIdentifier(identifier + ".less")
                Button {
                    if let value, let next = try? value.adding(.one) { count = ledgerAmountInput(next) }
                } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(value == nil)
                    .accessibilityLabel(dinnerText("One more serving")).accessibilityIdentifier(identifier + ".more")
            }.buttonStyle(.bordered)
        }
    }
}
