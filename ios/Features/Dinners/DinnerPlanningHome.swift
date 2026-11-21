import SwiftUI
import Combine
import CoreDomain

/// Root owns the runtime permission provider and the purchase phase. This feature
/// never reconstructs either from a restored document or an entitlement flag.
struct DinnerPlanningHome: View {
    @ObservedObject private var ledger: LedgerModel
    @StateObject private var model: DinnerFeatureModel
    @State private var startingPickup = false
    var needsPantrySetup: Bool
    let pickupOpening: DinnerPickupOpeningState
    init(ledger: LedgerModel, access: @escaping DinnerFeatureModel.AccessProvider,
         phase: @escaping (UUID) -> BasketPhase, ideaCatalog: [MealTemplate] = [], runtimeChanges: AnyPublisher<Void, Never>? = nil,
         basketPrepAccess: @escaping () -> Bool = { false }, milestoneAccess: @escaping () -> Bool = { false }, needsPantrySetup: Bool = false,
         pickupOpening: DinnerPickupOpeningState = .ready) {
        self.ledger = ledger
        self.pickupOpening = pickupOpening
        self.needsPantrySetup = needsPantrySetup
        let model = DinnerFeatureModel(store: ledger, access: access, phase: phase, ideaCatalog: ideaCatalog,
            basketPrepAccess: basketPrepAccess, milestoneAccess: milestoneAccess)
        model.observe(ledger.objectWillChange)
        if let runtimeChanges { model.observeRuntime(runtimeChanges) }
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        DinnerWorkspaceView(model: model, needsPantrySetup: needsPantrySetup, pickupOpening: pickupOpening,
                            startPickup: { startingPickup = true }) { LedgerSaveStatus(model: ledger) }
            .sheet(isPresented: $startingPickup) { NavigationStack { LedgerNewShopView(model: ledger) } }
            .environment(\.currentDinnerPlanner, model)
            .environment(\.timeZone, TimeZone(identifier: model.shop?.basis.timeZoneIdentifier ?? "") ?? .current)
            .task { await ledger.open() }
    }
}
extension LedgerModel: DinnerWorkspaceStore {}

private struct CurrentDinnerPlannerKey: EnvironmentKey {
    static let defaultValue: DinnerFeatureModel? = nil
}
extension EnvironmentValues {
    var currentDinnerPlanner: DinnerFeatureModel? {
        get { self[CurrentDinnerPlannerKey.self] }
        set { self[CurrentDinnerPlannerKey.self] = newValue }
    }
}

/// A ready pickup still requires the feature's normal per-shop access checks.
enum DinnerPickupOpeningState: Equatable {
    case ready, opening, denied, pantryRecovery, failed(String)

    @MainActor init(pickup: PickupModel, authorized: Bool, retryAvailable: Bool) {
        if pickup.ready {
            self = .ready
        } else if !authorized {
            self = .denied
        } else if pickup.pantryRouteAvailable || pickup.pantryRestartAvailable {
            self = .pantryRecovery
        } else if let error = pickup.error {
            self = .failed(error)
        } else if retryAvailable {
            self = .failed(pTr("Could not open saved pickups. Retry; existing records have not been replaced."))
        } else {
            self = .opening
        }
    }
}

private struct DinnerPickupOpeningStatus: View {
    let state: DinnerPickupOpeningState
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.privatePantryRetry) private var retryPrivatePantry

    var body: some View {
        switch state {
        case .ready:
            EmptyView()
        case .opening:
            ProgressView(ledgerText("Opening your pickups…"))
                .accessibilityIdentifier("dinner.openingPickup")
        case .denied:
            Text(dinnerText("Planning access changed or expired. Reconnect and review again."))
        case .pantryRecovery:
            NavigationLink(pantryText("My Pantry")) { AdultPantryTab() }
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(Theme.error)
            Button(pTr("Retry opening")) {
                if let retryPrivatePantry { retryPrivatePantry() }
                else { Task { await pickup.load() } }
            }.accessibilityIdentifier("dinner.retryOpeningPickup")
        }
    }
}

struct DinnerWorkspaceView<SaveStatus: View>: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.pickupLedger) private var liveLedger
    @Environment(\.dinnerHousehold) private var household
    var needsPantrySetup = false
    var pickupOpening: DinnerPickupOpeningState = .ready
    let startPickup: () -> Void
    @ViewBuilder let saveStatus: () -> SaveStatus
    @State private var weekStart = Date()
    @State private var showWeekGrid = false
    private struct RecipeEditor: Identifiable {
        let id = UUID()
        let recipe: MealTemplate?
        var pasteEntry = false
    }
    @State private var editingRecipe: RecipeEditor?
    @State private var handoff: MealTemplate?
    var body: some View {
        List {
            Group {
                if !model.store.ready {
                    ProgressView()
                } else if model.shop == nil {
                    if let library = privateRecipeLibrary, let first = library.workspace.mealTemplates.first {
                        Section {
                            VStack(alignment: .leading, spacing: 16) {
                                DinnerTonightHeading(eyebrow: tonightText("Recipe library"), title: nil,
                                    detail: tonightText("Free reusable dinner")) {
                                    Text(verbatim: first.title).font(.system(.title2, design: .serif, weight: .semibold))
                                }
                                Button(dinnerText("Plan this dinner")) { handoff = first }
                                    .buttonStyle(PrimaryAction()).accessibilityIdentifier("dinner.planSaved")
                                recipeEditorButton(library, recipe: first, featured: true)
                            }.padding(.vertical, 6)
                            startPickupButton
                        }
                        Section {
                            ForEach(library.workspace.mealTemplates.dropFirst()) { recipe in
                                recipeEditorButton(library, recipe: recipe)
                            }
                            recipeEditorButton(library)
                            pasteRecipeButton
                        }
                    } else {
                        Section {
                            VStack(alignment: .leading, spacing: 16) {
                                DinnerTonightHeading(title: dinnerText(model.workspace.shops.isEmpty ? "No dinner planned" : "No pickup selected"),
                                    detail: dinnerText("You can save a recipe now and choose it for a pickup later.")) { EmptyView() }
                                if let library = privateRecipeLibrary {
                                    recipeEditorButton(library).buttonStyle(PrimaryAction())
                                    pasteRecipeButton
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                    Section {
                        if privateRecipeLibrary?.workspace.mealTemplates.first == nil { startPickupButton }
                        if let liveLedger, liveLedger.ready, model.store === liveLedger {
                            tonightLink
                            RecordsRecoveryLink(accessibilityID: "dinner.recipeFiles", dinnerModel: model)
                        }
                    } header: {
                        Text(dinnerText("Plan"))
                    } footer: {
                        Text(dinnerText("Start a pickup to plan dinners and review the groceries you’ll need."))
                    }
                } else if pickupOpening != .ready {
                    DinnerPickupOpeningStatus(state: pickupOpening)
                } else if !model.accessAvailable {
                    Section { Text(dinnerText("Planning access changed or expired. Reconnect and review again.")) }
                } else if let shop = model.shop {
                    Section {
                        DinnerTonightPlan(model: model, shop: shop)
                        if let recipe = privateRecipeLibrary?.workspace.mealTemplates.first {
                            Button { handoff = recipe } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(dinnerText("Plan a saved dinner")).font(.headline)
                                    Text(verbatim: recipe.title)
                                }
                            }.accessibilityIdentifier("dinner.planSaved")
                        }
                        NavigationLink {
                            DinnerWeekView(model: model, shopID: shop.id, weekStart: $weekStart,
                                showWeekGrid: $showWeekGrid, saveStatus: saveStatus)
                        } label: { Label(dinnerText("This week"), systemImage: "calendar") }
                            .accessibilityIdentifier("dinnerWeekEntry")
                        NavigationLink {
                            DinnerLibraryView(model: model)
                        } label: { Label(dinnerText("Dinner library"), systemImage: "books.vertical") }
                            .accessibilityIdentifier("dinnerLibrary")
                        if let liveLedger, liveLedger.ready, model.store === liveLedger { tonightLink }
                    }
                    if model.basketPrepAccess(), model.localIdeaWorkspaceID != nil {
                        DinnerPrepAgenda(model: model)
                    }
                    Section(dinnerText("Plan")) {
                        if privateRecipeLibrary != nil { pasteRecipeButton }
                        NavigationLink(dinnerText("All chosen dinners, including earlier dates")) { DinnerAllMealsView(model: model) }
                        NavigationLink(captureText("Review a recipe from text or photo")) { RecipeCaptureEntry(model: model) }
                            .accessibilityIdentifier("dinner.scanRecipe")
                        DinnerDecisionButton(model: model, title: dinnerText("Repeat last week"),
                                             identifier: "dinner.repeatWeek") {
                            DinnerRepeatWeekView(model: model, initialDate: weekStart)
                        }
                        NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(localShopID: model.shop?.id) }
                        NavigationLink(dinnerText("Review a dinner idea")) { DinnerIdeasView(model: model) }
                        NavigationLink(dinnerText("Dinner rotations")) { DinnerRotationsView(model: model, weekStart: weekStart) }
                        NavigationLink(dinnerText("Protect a lunch or side")) { DinnerReservationView(model: model) }
                        if model.budgetVisible {
                            if model.basketPrepAccess(), model.localIdeaWorkspaceID != nil, model.phaseProvider(shop.id) == .draft {
                                DinnerDecisionButton(model: model, title: dinnerPlanText("Three dinners, one basket"), identifier: "dinner.threeNightBasket") {
                                    ThreeDinnerBasketView(model: model, shop: shop)
                                }
                            }
                            DinnerDecisionButton(model: model, title: dinnerText("Price a dinner plan or compare pairings"), identifier: "dinnerPairings") { DinnerScenarioEditor(model: model, shop: shop) }
                            NavigationLink(dinnerText("Compare two store trips")) { DinnerQuotesView(model: model) }
                        }
                    }.disabled(!model.editable)
                    if model.preview != nil {
                        Section { DinnerDecisionButton(model: model, title: dinnerText("Review pending dinner changes"), identifier: "dinnerPending", preservePending: false) { DinnerPreviewView(model: model) } }
                    }
                }
                if let household { HouseholdTonightLink(household: household) }
                if let liveLedger, liveLedger.ready, model.store === liveLedger, model.basketPrepAccess() {
                    Section {
                        NavigationLink(dinnerText("Private meal preferences")) { PrivateMealPreferencesEntry(ledger: liveLedger) }
                            .accessibilityIdentifier("dinner.mealPreferences")
                    }
                }
                DinnerFeedback(model: model)
                Section { saveStatus() }
            }.listRowBackground(Theme.surface)
        }.workingSurface().navigationTitle(dinnerText("Dinners")).listStyle(.insetGrouped)
        .sheet(item: $editingRecipe) { editor in
            if let library = privateRecipeLibrary {
                NavigationStack { DinnerPrivateRecipeEditor(ledger: library, recipe: editor.recipe, pasteEntry: editor.pasteEntry) }
            }
        }
        .sheet(item: $handoff) { recipe in NavigationStack { SavedDinnerHandoffView(recipe: recipe) } }
    }

    private var pasteRecipeButton: some View {
        Button { editingRecipe = RecipeEditor(recipe: nil, pasteEntry: true) } label: {
            Label(dinnerText("Paste a recipe"), systemImage: "doc.on.clipboard")
        }.accessibilityIdentifier("dinner.pasteRecipe")
    }

    private func recipeEditorButton(_ ledger: LedgerModel, recipe: MealTemplate? = nil, featured: Bool = false) -> some View {
        Button { editingRecipe = RecipeEditor(recipe: recipe) } label: {
            if let recipe, featured {
                Label(dinnerText("Edit saved recipe"), systemImage: "pencil")
                    .accessibilityLabel(dinnerFormat("Edit saved recipe, %@", recipe.title))
            } else if let recipe {
                Text(verbatim: recipe.title).font(.system(.title3, design: .serif, weight: .semibold))
            } else {
                Label(dinnerText(ledger.workspace.mealTemplates.isEmpty ? "Save a familiar dinner" : "Replace Free reusable dinner"), systemImage: "book")
            }
        }.accessibilityIdentifier(recipe.map { "dinner.savedRecipe." + $0.id.uuidString } ?? "dinner.saveFirstRecipe")
    }

    private var privateRecipeLibrary: LedgerModel? {
        guard let liveLedger, model.store === liveLedger, model.basketPrepAccess() else { return nil }
        return liveLedger
    }

    private var startPickupButton: some View {
        Button(ledgerText("Start pickup"), action: startPickup)
            .frame(minHeight: 44)
            .accessibilityIdentifier("dinnerStartPickup")
    }

    private var tonightLink: some View {
        NavigationLink { TonightEntry() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(dinnerText("Find a dinner from the pantry"), systemImage: "carrot")
                if needsPantrySetup { Text(dinnerText("Set up My Pantry to use food you have at home.")).font(.footnote).foregroundStyle(Theme.secondary) }
            }
        }.accessibilityIdentifier("dinner.tonight")
    }
}

/// The Dinners root owns the selected week and presentation, so popping this
/// destination or switching tabs keeps the same local calendar context.
struct DinnerWeekView<SaveStatus: View>: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @State private var shopID: UUID
    @Binding var weekStart: Date
    @Binding var showWeekGrid: Bool
    @ViewBuilder let saveStatus: () -> SaveStatus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Destination: Hashable { case meal(UUID), cooked(UUID), note(MealDay), reservation }
    @State private var destination: Destination?

    init(model: DinnerFeatureModel, shopID: UUID, weekStart: Binding<Date>,
         showWeekGrid: Binding<Bool>, @ViewBuilder saveStatus: @escaping () -> SaveStatus) {
        self.model = model; _shopID = State(initialValue: shopID)
        _weekStart = weekStart; _showWeekGrid = showWeekGrid; self.saveStatus = saveStatus
    }

    var body: some View {
        Group {
            if model.shop?.id == shopID {
                VStack(spacing: 0) {
                    weekList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    Theme.canvas.frame(height: 8)
                        .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
                        .accessibilityHidden(true)
                }
            } else {
                pickupChanged
            }
        }
        .navigationTitle(dinnerText("This week"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .dinnerAccess(model)
            .navigationDestination(item: $destination) { selection in
                if model.shop?.id == shopID {
                    switch selection {
                    case .meal(let id): DinnerOccurrenceView(model: model, occurrenceID: id)
                    case .cooked(let id): DinnerCookedPortionsView(model: model, id: id)
                    case .note(let day): DinnerNoteView(model: model, day: day)
                    case .reservation: DinnerReservationView(model: model)
                    }
                } else { pickupChanged }
            }
    }

    private var weekList: some View {
        List {
            Section {
                if let shop = model.shop { Text(shop.title).font(.headline) }
                Button(dinnerText("Protect a lunch or side")) { destination = .reservation }
                    .disabled(!model.editable)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dinnerText("Week starting")).font(.headline)
                    DatePicker(dinnerText("Week starting"), selection: $weekStart, displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden().fixedSize().accessibilityIdentifier("dinnerWeekStart")
                }
                Picker(dinnerText("Week display"), selection: $showWeekGrid) {
                    Text(dinnerText("List")).tag(false)
                    Text(dinnerText("Grid")).tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("dinnerWeekDisplay")
                if let shop = model.shop, let start = try? MealDay(date: weekStart, timeZoneIdentifier: shop.basis.timeZoneIdentifier),
                   let week = try? model.week(start: start),
                   case .success(let current) = currentMeals {
                    if showWeekGrid {
                        weekGrid(week.days, in: shop, current: current)
                    } else {
                        ForEach(week.days, id: \.day) { day in
                            dayContent(day, in: shop, current: current).padding(.vertical, 6).buttonStyle(.borderless)
                        }
                    }
                    if !current.unscheduled.isEmpty {
                        Text(dinnerText("Unscheduled")).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(current.unscheduled) { meal in mealLink(meal) }
                    }
                } else { Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes."))
                    .accessibilityIdentifier("dinner.currentMealsUnavailable") }
            } header: {
                Text(dinnerText("Week")).font(.headline).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if model.preview != nil {
                Section { DinnerDecisionButton(model: model, title: dinnerText("Review pending dinner changes"), identifier: "dinnerPending", preservePending: false) { DinnerPreviewView(model: model) } }
            }
            DinnerFeedback(model: model)
            Section { saveStatus() }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.canvas)
    }

    private var currentMeals: Result<DinnerCurrentMeals, Error> { Result { try model.currentMeals(pickup: pickup) } }
    private func weekGrid(_ days: [DinnerMealWeek.Day], in shop: ShoppingLedger, current: DinnerCurrentMeals) -> some View {
        let rowLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        // List rows keep each pair's accessibility elements stable as text size changes.
        return ForEach(days.indices.filter { $0.isMultiple(of: 2) }, id: \.self) { start in
            rowLayout {
                ForEach(days[start..<min(start + 2, days.count)], id: \.day) { day in
                    dayContent(day, in: shop, current: current)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
                }
            }.buttonStyle(.borderless)
        }
    }
    private var pickupChanged: some View {
        ContentUnavailableView(dinnerText("Pickup selection changed"), systemImage: "arrow.triangle.2.circlepath",
            description: Text(dinnerText("Return to the original pickup to review this week.")))
    }
    private func dayContent(_ day: DinnerMealWeek.Day, in shop: ShoppingLedger, current: DinnerCurrentMeals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dinnerDay(day.day)).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(current.on(day.day)) { meal in mealLink(meal, calendarZone: day.day.timeZoneIdentifier) }
            ForEach(current.cooked(on: day.day)) { claim in
                Button { destination = .cooked(claim.id) } label: { DinnerCookedPortionsLabel(claim: claim) }
                    .buttonStyle(.borderless).accessibilityIdentifier("dinner.leftover.\(claim.id)")
            }
            ForEach(day.notes) { note in
                VStack(alignment: .leading) {
                    Text(dinnerNoteKind(note.kind)).font(.subheadline.bold())
                    if !note.text.isEmpty { Text(note.text) }
                    if note.day.timeZoneIdentifier != day.day.timeZoneIdentifier {
                        Text(note.day.timeZoneIdentifier).font(.caption)
                    }
                }.accessibilityElement(children: .combine)
            }
            ForEach(day.protectedContributionIDs, id: \.self) { id in
                if let source = shop.contributions.first(where: { $0.id == id && $0.removedAt == nil }),
                   case .protectedNeed(let purpose) = source.source {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dinnerFormat("Protected: %@ · %@", source.productName, dinnerQuantity(source.quantity)))
                        Text(dinnerFormat("Purpose: %@", purpose)).font(.subheadline)
                        if let savedDay = model.state.protectedDays.first(where: { $0.shopID == shop.id && $0.contributionID == id })?.day,
                           savedDay.timeZoneIdentifier != day.day.timeZoneIdentifier {
                            Text(savedDay.timeZoneIdentifier).font(.caption)
                        }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("dinnerProtected-\(id)")
                }
            }
            Button { destination = .note(day.day) } label: {
                Text(dinnerText("Add or edit a day note")).frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless)
                .accessibilityIdentifier("dinnerDayNote-\(day.day.year)-\(day.day.month)-\(day.day.day)")
        }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
    }
    private func mealLink(_ meal: DinnerCurrentMeal, calendarZone: String? = nil) -> some View {
        // Several calendar actions share one List row in Grid. Explicit selection
        // avoids the row-wide NavigationLink activation choosing a different day.
        Button { destination = .meal(meal.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.title).font(.headline)
                Text(dinnerFormat("Servings: %@", meal.servings.description))
                if let calendarZone, let savedDay = meal.scheduledDay, savedDay.timeZoneIdentifier != calendarZone {
                    Text(savedDay.timeZoneIdentifier).font(.caption)
                }
                if meal.isHidden { Text(dinnerText("Hidden dinner")) }
            }.frame(minHeight: 44, alignment: .leading)
        }.buttonStyle(.borderless).accessibilityIdentifier("dinnerOccurrence-\(meal.id)")
    }
}

struct DinnerFeedback: View {
    @ObservedObject var model: DinnerFeatureModel
    @AccessibilityFocusState private var errorFocused: Bool
    var body: some View {
        if let error = model.error { Section { Text(error).foregroundStyle(Theme.error).accessibilityIdentifier("dinnerError").accessibilityFocused($errorFocused)
            .onAppear { errorFocused = true }.onChange(of: error) { _, _ in errorFocused = true } } }
        if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("dinnerNotice") } }
    }
}
struct DinnerPreviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDinnerDecision) private var close
    @State private var detailedReviewID: UUID?
    @State private var saved: SavedSchedule?
    @AccessibilityFocusState private var savedFocused: Bool

    private struct SavedSchedule {
        let identity: DinnerFeatureModel.EditorIdentity
        let reviewID: UUID
        let mealID: UUID
    }

    private var savedMeal: MealOccurrence? {
        guard let saved, model.accessAvailable, model.editorIdentity == saved.identity,
              model.state.applyReceipts.contains(where: { $0.id == saved.reviewID }),
              let meal = model.shop?.mealOccurrences.first(where: { $0.id == saved.mealID && $0.removedAt == nil }) else { return nil }
        return meal
    }

    @ViewBuilder private func scheduleFacts(_ meal: MealOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: meal.title).font(.headline)
            if let day = meal.scheduledDay, let date = day.date {
                Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current)))
            }
            Text(dinnerFormat("Servings: %@", meal.servings.description))
        }.accessibilityElement(children: .combine).accessibilityIdentifier("dinnerPreviewMeal-" + meal.id.uuidString)
    }

    private func finish() { if let close { close() } else { dismiss() } }
    var body: some View {
        List {
            Group {
                if let meal = savedMeal {
                    Section {
                        Label(dinnerText("Dinner changes saved."), systemImage: "checkmark.circle.fill")
                            .font(.headline).accessibilityFocused($savedFocused).accessibilityIdentifier("dinner.schedule.saved")
                            .onAppear { savedFocused = true }
                        scheduleFacts(meal)
                        Button(ledgerText("Done")) { finish() }.accessibilityIdentifier("dinner.schedule.done")
                    }
                } else if let preview = model.preview, model.canReviewPreview,
                          detailedReviewID != preview.proposal.id, model.canApply, let workspaceID = model.localIdeaWorkspaceID,
                          let meal = preview.unchangedGroceriesForScheduleEdit(in: model.workspace, workspaceID: workspaceID) {
                    Section {
                        scheduleFacts(meal)
                        let ingredientIDs = Set(meal.ingredientContributionIDs)
                        let names = preview.projectedContributions.filter { ingredientIDs.contains($0.id) && $0.removedAt == nil }.map(\.productName)
                        Text(names.count <= 2 && !names.isEmpty
                            ? dinnerFormat("The grocery amounts for %@ stay the same.", ListFormatter.localizedString(byJoining: names))
                            : dinnerFormat("Grocery amounts stay the same for %lld ingredients.", Int64(names.count)))
                            .accessibilityIdentifier("dinner.schedule.groceries")
                        Button(dinnerText("Save dinner plan")) {
                            guard let identity = model.editorIdentity else { return }
                            Task {
                                if await model.applyPreview() {
                                    saved = SavedSchedule(identity: identity, reviewID: preview.proposal.id, mealID: meal.id)
                                }
                            }
                        }.buttonStyle(PrimaryAction()).disabled(!model.canApply)
                            .accessibilityIdentifier("dinnerApply")
                    }
                    Section {
                        Button(dinnerText("Show full review")) { detailedReviewID = preview.proposal.id }
                            .accessibilityIdentifier("dinner.schedule.showFull")
                        Button(dinnerText("Cancel preview"), role: .cancel) { model.cancelPreview(); finish() }
                            .accessibilityIdentifier("dinnerCancelPreview")
                    }
                } else if let preview = model.preview, model.canReviewPreview {
                    if let detail = model.currentSwapReview {
                        DinnerSwapEvidenceView(review: detail, showPrices: model.budgetVisible)
                    }
                    Section {
                        Text(dinnerText("Review before applying")).font(.title2.bold())
                        Text(dinnerText("Only the changes listed here will be applied. Cancel keeps your saved pickup unchanged."))
                        if preview.proposal.isIsolatedPreview { Text(dinnerText("Exploration only. This preview cannot be applied.")) }
                        if preview.needsPurchaseAmendment { Text(dinnerText("This basket is locked. Save a proposal for a purchase amendment.")) }
                        if model.sharedPreview { Text(dinnerText("Shared changes need an authorized server commit. You can save this proposal on this device.")) }
                    }
                    Section(dinnerText("Dinners")) {
                        ForEach(preview.projectedMeals.filter { preview.changedOccurrenceIDs.contains($0.id) }) { meal in
                            let movesDate = preview.proposal.changes.contains {
                                if case .move(let id, _) = $0 { return id == meal.id }
                                return false
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(meal.title).font(.headline)
                                Text(meal.removedAt == nil ? dinnerFormat("Servings: %@", meal.servings.description) : dinnerText("Remove chosen dinner"))
                                if movesDate, let original = model.shop?.mealOccurrences.first(where: { $0.id == meal.id }) {
                                    Text(dinnerFormat("Before: %@", original.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled")))
                                    Text(dinnerFormat("After: %@", meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled")))
                                    Text(dinnerText("The dinner and its serving groups move together. Grocery quantities and separate protected reservations stay as saved. Review any cook instructions already shared for this dinner."))
                                } else {
                                    Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
                                }
                                ForEach(meal.servingGroups.filter(\.isProtected)) { group in
                                    Text(dinnerFormat("Protected: %@ · %@", group.name, group.servings.description))
                                }
                            }.accessibilityElement(children: .combine).accessibilityIdentifier("dinnerPreviewMeal-\(meal.id)")
                        }
                    }
                    let allocations = preview.proposal.changes.compactMap { change -> DinnerAdjustment? in
                        if case .adjust(let adjustment) = change, adjustment.portionBindings != nil { return adjustment }
                        return nil
                    }
                    if !allocations.isEmpty {
                        Section(dinnerText("Resulting ingredient portions")) {
                            ForEach(allocations, id: \.occurrenceID) { adjustment in
                                ForEach(adjustment.portionBindings ?? []) { binding in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(preview.projectedContributions.first { $0.id == binding.contributionID }?.productName ?? "")
                                            .font(.headline)
                                        if let group = adjustment.groups.first(where: { $0.id == binding.groupID }) {
                                            Text(group.name)
                                            if group.isProtected { Text(dinnerText("Protected group")) }
                                        }
                                        if let old = model.state.portionBindings.first(where: { $0.id == binding.id }) {
                                            Text(dinnerFormat("Before: %@", dinnerQuantity(old.quantity)))
                                        }
                                        Text(dinnerFormat("After: %@", dinnerQuantity(binding.quantity)))
                                    }.accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("dinnerManualReviewBinding.\(binding.id)")
                                }
                            }
                        }
                    }
                    Section(dinnerText("Grocery needs")) {
                        if preview.changedContributionIDs.isEmpty, preview.proposal.changes.contains(where: { change in
                            if case .adjust = change { return true }
                            return false
                        }) {
                            Text(dinnerText("The grocery amounts on this list stay the same."))
                        }
                        ForEach(preview.projectedContributions.filter { preview.changedContributionIDs.contains($0.id) }) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.productName).font(.headline)
                                if let old = model.shop?.contributions.first(where: { $0.id == source.id }) {
                                    Text(dinnerFormat("Before: %@", dinnerQuantity(old.quantity)))
                                } else { Text(dinnerText("New need")) }
                                Text(source.removedAt == nil ? dinnerFormat("After: %@", dinnerQuantity(source.quantity)) : dinnerText("Remove this dinner need"))
                                if case .protectedNeed(let purpose) = source.source {
                                    Text(dinnerText("Protected need"))
                                    Text(dinnerFormat("Purpose: %@", purpose))
                                    if let reservation = preview.proposal.changes.compactMap({ change -> DinnerReservation? in
                                        if case .reserve(let value) = change, value.contributionID == source.id { return value }
                                        return nil
                                    }).first {
                                        Text(reservation.day.map(dinnerDay) ?? dinnerText("Unscheduled"))
                                    }
                                }
                            }.accessibilityElement(children: .combine).accessibilityIdentifier("dinnerPreviewNeed-\(source.id)")
                        }
                    }
                    if preview.reviewsGuestPurchases {
                        DinnerGuestPurchaseReview(model: model, preview: preview)
                    }
                    if model.budgetVisible, let basis = preview.budgetBasis,
                       preview.proposal.changes.contains(where: { if case .adoptBasis = $0 { return true }; return false }) {
                        Section(dinnerText("Reviewed store basis")) {
                            Text(basis.branch)
                            if let slot = basis.slot {
                                Text(dinnerFormat("Store slot: %@",dinnerStoreSlot(slot, zoneID: basis.timeZoneIdentifier)))
                                    .accessibilityIdentifier("quoteAdoptionSlot")
                            } else {
                                Text(basis.timeZoneIdentifier)
                            }
                            Text(dinnerText("Changing store facts invalidates the current quote. The reviewed comparison remains in history."))
                        }
                    }
                    DinnerSharedProposalEntry(model: model, preview: preview)
                    Section {
                        Button(dinnerText("Apply once")) { Task { if await model.applyPreview() { finish() } } }
                            .disabled(!model.canApply).accessibilityIdentifier("dinnerApply")
                        Button(dinnerText("Save proposal on this device")) { Task { _ = await model.savePreviewAsProposal() } }
                            .disabled(!model.editable || preview.proposal.isIsolatedPreview)
                        Button(dinnerText("Cancel preview"), role: .cancel) { model.cancelPreview(); finish() }.accessibilityIdentifier("dinnerCancelPreview")
                    }
                } else { Section { Text(dinnerText("No dinner changes are waiting for review.")) } }
                DinnerFeedback(model: model)
            }.listRowBackground(Theme.surface)
        }.workingSurface().navigationTitle(dinnerText("Dinner preview")).dinnerAccess(model)
    }
}
func dinnerNoteKind(_ kind: DinnerWeekNote.Kind) -> String {
    switch kind {
    case .away: return dinnerText("Away night")
    case .guests: return dinnerText("Guests")
    case .side: return dinnerText("Side")
    case .carryoverReview: return dinnerText("Carryover to review")
    }
}

struct DinnerAllMealsView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    private var currentMeals: Result<DinnerCurrentMeals, Error> { Result { try model.currentMeals(pickup: pickup) } }
    var body: some View {
        List {
            Group {
                Section {
                    Text(currentDinnerText("Chosen dinners show their current meal and date. Original purchases and earlier reusable templates remain preserved."))
                    NavigationLink(dinnerText("Dinner library")) { DinnerLibraryView(model: model) }
                }
                switch currentMeals {
                case .success(let current):
                ForEach(current.cooked) { claim in
                    NavigationLink { DinnerCookedPortionsView(model: model, id: claim.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            DinnerCookedPortionsLabel(claim: claim)
                            if let day = claim.cookedDinner?.day { Text(dinnerDay(day)) }
                        }
                    }
                }
                ForEach(current.all) { meal in
                    NavigationLink { DinnerOccurrenceView(model: model, occurrenceID: meal.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meal.title).font(.headline)
                            Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
                            if meal.isHidden { Text(dinnerText("Hidden dinner")) }
                        }
                    }.accessibilityIdentifier("dinnerOccurrence-\(meal.id)")
                }
                case .failure:
                    Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes."))
                        .accessibilityIdentifier("dinner.currentMealsUnavailable")
                }
            }.listRowBackground(Theme.surface)
        }.workingSurface().navigationTitle(dinnerText("All chosen dinners")).dinnerAccess(model)
    }
}

private struct DinnerTonightPlan: View {
    @ObservedObject var model: DinnerFeatureModel
    let shop: ShoppingLedger
    @EnvironmentObject private var pickup: PickupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineView(.everyMinute) { timeline in
                if let day = try? MealDay(date: timeline.date, timeZoneIdentifier: shop.basis.timeZoneIdentifier),
                   let current = try? model.currentMeals(pickup: pickup) {
                    let away = model.state.weekNotes.contains { $0.shopID == shop.id && $0.kind == .away && $0.day.hasSameCivilDate(as: day) }
                    let meals = current.on(day).filter { meal in
                        guard !meal.isHidden else { return false }
                        if case .original(let original) = meal { return original.carryover == nil }
                        return true
                    }
                    let cooked = current.cooked(on: day)
                    DinnerTonightHeading(title: away ? dinnerText("Night away") :
                        meals.isEmpty && cooked.isEmpty ? dinnerText("No dinner planned") : nil, detail: shop.title) {
                        if !away {
                            ForEach(cooked) { claim in
                                NavigationLink { DinnerCookedPortionsView(model: model, id: claim.id) } label: {
                                    DinnerCookedPortionsLabel(claim: claim)
                                }.buttonStyle(.borderless)
                            }
                            ForEach(meals) { meal in
                                NavigationLink { DinnerOccurrenceView(model: model, occurrenceID: meal.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: meal.title).font(.system(.title2, design: .serif, weight: .semibold))
                                        Text(dinnerFormat("Servings: %@", meal.servings.description))
                                            .font(.body).foregroundStyle(Theme.secondary)
                                    }.frame(minHeight: 44, alignment: .leading)
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                } else {
                    Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes."))
                }
            }
            NavigationLink { DinnerTemplateEditor(model: model, purpose: .manual) } label: {
                Label(dinnerText("Add a manual dinner"), systemImage: "plus")
            }.buttonStyle(PrimaryAction()).disabled(!model.editable).accessibilityIdentifier("dinnerManual")
        }.padding(.vertical, 6)
    }
}

private struct DinnerTonightHeading<Meals: View>: View {
    var eyebrow: String = tonightText("Tonight")
    let title: String?
    let detail: String
    @ViewBuilder var meals: () -> Meals
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: eyebrow).font(.headline).foregroundStyle(Theme.action)
                    .accessibilityAddTraits(.isHeader)
                if let title { Text(title).font(.title2.weight(.semibold)) }
                meals()
                Text(verbatim: detail).font(.body).foregroundStyle(Theme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                DinnerTableSetting().frame(width: 70, height: 62).accessibilityHidden(true)
            }
        }
    }
}

/// An overhead place setting on folded linen.
private struct DinnerTableSetting: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 70, y: size.height / 62)
            let napkin = Path { p in
                p.move(to: CGPoint(x: 22, y: 4))
                p.addLine(to: CGPoint(x: 64, y: 10))
                p.addLine(to: CGPoint(x: 57, y: 59))
                p.addLine(to: CGPoint(x: 15, y: 53))
                p.closeSubpath()
            }
            context.fill(napkin, with: .color(Theme.selection))
            let plate = Path(ellipseIn: CGRect(x: 17, y: 10, width: 46, height: 46))
            context.fill(plate, with: .color(Theme.surface))
            context.stroke(plate, with: .color(Theme.action), lineWidth: 1.5)
            context.stroke(Path(ellipseIn: CGRect(x: 22, y: 15, width: 36, height: 36)), with: .color(Theme.controlEdge), lineWidth: 0.8)
            let fork = Path { p in
                p.move(to: CGPoint(x: 4, y: 13))
                p.addLine(to: CGPoint(x: 4, y: 23))
                p.addQuadCurve(to: CGPoint(x: 11, y: 23), control: CGPoint(x: 7.5, y: 30))
                p.addLine(to: CGPoint(x: 11, y: 13))
                p.move(to: CGPoint(x: 7.5, y: 13))
                p.addLine(to: CGPoint(x: 7.5, y: 51))
            }
            context.stroke(fork, with: .color(Theme.action), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }
}

/// A recipe can occupy the Free slot before the first pickup exists.
struct DinnerPasteRecipeButton: View {
    @ObservedObject var ledger: LedgerModel
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label(dinnerText("Paste a recipe"), systemImage: "doc.on.clipboard") }
            .accessibilityIdentifier("dinner.pasteRecipe")
            .sheet(isPresented: $presented) {
                NavigationStack { DinnerPrivateRecipeEditor(ledger: ledger, recipe: nil, pasteEntry: true) }
            }
    }
}

private struct DinnerPrivateRecipeEditor: View {
    @ObservedObject var ledger: LedgerModel
    let recipe: MealTemplate?
    var pasteEntry = false
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene

    var body: some View {
        TonightRecipeReview(ledger: ledger, source: nil, template: recipe, pasteEntry: pasteEntry, currentIdentity: {
            guard scene == .active, UIApplication.shared.isProtectedDataAvailable,
                  child?.presented != true, household.projection?.grantId == nil else { return nil }
            return CapturePrivateIdentity.current(access: access, household: household)
        })
    }
}
