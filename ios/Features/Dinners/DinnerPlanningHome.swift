import SwiftUI
import Combine
import CoreDomain

/// Root owns the runtime permission provider and the purchase phase. This feature
/// never reconstructs either from a restored document or an entitlement flag.
struct DinnerPlanningHome: View {
    @ObservedObject private var ledger: LedgerModel
    @StateObject private var model: DinnerFeatureModel
    @State private var startingPickup = false
    init(ledger: LedgerModel, access: @escaping DinnerFeatureModel.AccessProvider,
         phase: @escaping (UUID) -> BasketPhase, ideaCatalog: [MealTemplate] = [], runtimeChanges: AnyPublisher<Void, Never>? = nil) {
        self.ledger = ledger
        let model = DinnerFeatureModel(store: ledger, access: access, phase: phase, ideaCatalog: ideaCatalog)
        model.observe(ledger.objectWillChange)
        if let runtimeChanges { model.observeRuntime(runtimeChanges) }
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        DinnerWorkspaceView(model: model, startPickup: { startingPickup = true }) { LedgerSaveStatus(model: ledger) }
            .sheet(isPresented: $startingPickup) { NavigationStack { LedgerNewShopView(model: ledger) } }
            .environment(\.timeZone, TimeZone(identifier: model.shop?.basis.timeZoneIdentifier ?? "") ?? .current)
            .task { await ledger.open() }
    }
}
extension LedgerModel: DinnerWorkspaceStore {}

struct DinnerWorkspaceView<SaveStatus: View>: View {
    @ObservedObject var model: DinnerFeatureModel
    let startPickup: () -> Void
    @ViewBuilder let saveStatus: () -> SaveStatus
    @State private var weekStart = Date()
    @State private var showWeekGrid = false
    var body: some View {
        List {
            Section {
                Text(dinnerText("Plan dinners, one decision at a time.")).font(.title2.bold())
                if let shop = model.shop { Text(shop.title).font(.headline) }
                Text(dinnerText("Manual dinners and calendar changes stay available on Free. A preview changes nothing until you apply it."))
            }
            if model.shop == nil {
                Section {
                    Text(dinnerText("Name your pickup to save dinner ideas and choose what to make."))
                    Button(ledgerText("Start pickup"), action: startPickup)
                        .accessibilityIdentifier("dinnerStartPickup")
                }
            } else if !model.accessAvailable {
                Section { Text(dinnerText("Planning access changed or expired. Reconnect and review again.")) }
            } else {
                Section {
                    if let shop = model.shop {
                        NavigationLink(dinnerText("This week")) {
                            DinnerWeekView(model: model, shopID: shop.id, weekStart: $weekStart,
                                showWeekGrid: $showWeekGrid, saveStatus: saveStatus)
                        }.accessibilityIdentifier("dinnerWeekEntry")
                    }
                }
                Section(dinnerText("Plan")) {
                    NavigationLink(dinnerText("All chosen dinners, including earlier dates")) { DinnerAllMealsView(model: model) }
                    NavigationLink(dinnerText("Add a manual dinner")) { DinnerTemplateEditor(model: model, purpose: .manual) }
                        .accessibilityIdentifier("dinnerManual")
                    NavigationLink(captureText("Review a recipe from text or photo")) { RecipeCaptureEntry(model: model) }
                        .accessibilityIdentifier("dinner.scanRecipe")
                    NavigationLink(dinnerText("Accepted dinners and Free reusable dinner")) { DinnerLibraryView(model: model) }.accessibilityIdentifier("dinnerLibrary")
                    NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(localShopID: model.shop?.id) }
                    NavigationLink(dinnerText("Review a dinner idea")) { DinnerIdeasView(model: model) }
                    NavigationLink(dinnerText("Dinner rotations")) { DinnerRotationsView(model: model, weekStart: weekStart) }
                    NavigationLink(dinnerText("Protect a lunch or side")) { DinnerReservationView(model: model) }
                    if model.budgetVisible {
                        if let shop = model.shop {
                            DinnerDecisionButton(model: model, title: dinnerText("Pairing and fallback evidence"), identifier: "dinnerPairings") { DinnerScenarioEditor(model: model, shop: shop) }
                        }
                        NavigationLink(dinnerText("Compare two store trips")) { DinnerQuotesView(model: model) }
                    }
                }.disabled(!model.editable)
                if model.preview != nil {
                    Section { DinnerDecisionButton(model: model, title: dinnerText("Review pending dinner changes"), identifier: "dinnerPending", preservePending: false) { DinnerPreviewView(model: model) } }
                }
            }
            DinnerFeedback(model: model)
            Section { saveStatus() }
        }.navigationTitle(dinnerText("Dinners")).listStyle(.insetGrouped)
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
    private enum Destination: Hashable { case meal(UUID), note(MealDay), reservation }
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
                DatePicker(dinnerText("Week starting"), selection: $weekStart, displayedComponents: .date)
                    .accessibilityIdentifier("dinnerWeekStart")
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
        if let error = model.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("dinnerError").accessibilityFocused($errorFocused)
            .onAppear { errorFocused = true }.onChange(of: error) { _, _ in errorFocused = true } } }
        if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("dinnerNotice") } }
    }
}
struct DinnerPreviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDinnerDecision) private var close
    private func finish() { if let close { close() } else { dismiss() } }
    var body: some View {
        List {
            if let preview = model.preview, model.canReviewPreview {
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
                Section(dinnerText("Grocery needs")) {
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
                            Text(dinnerFormat("Store slot: %@",slot.formatted(date: .abbreviated,time: .shortened)))
                                .accessibilityIdentifier("quoteAdoptionSlot")
                        }
                        Text(basis.timeZoneIdentifier)
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
        }.navigationTitle(dinnerText("Dinner preview")).dinnerAccess(model)
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
            Section {
                Text(currentDinnerText("Chosen dinners show their current meal and date. Original purchases and earlier reusable templates remain preserved."))
                NavigationLink(dinnerText("Dinner library")) { DinnerLibraryView(model: model) }
            }
            switch currentMeals {
            case .success(let current):
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
        }.navigationTitle(dinnerText("All chosen dinners")).dinnerAccess(model)
    }
}
