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
                Section(dinnerText("Week")) {
                    DatePicker(dinnerText("Week starting"), selection: $weekStart, displayedComponents: .date)
                    if let shop = model.shop, let start = try? MealDay(date: weekStart, timeZoneIdentifier: shop.basis.timeZoneIdentifier),
                       let week = try? model.week(start: start) {
                        ForEach(week.days, id: \.day) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(dinnerDay(day.day)).font(.headline).accessibilityAddTraits(.isHeader)
                                ForEach(day.meals) { meal in mealLink(meal) }
                                ForEach(day.notes) { note in
                                    VStack(alignment: .leading) {
                                        Text(dinnerNoteKind(note.kind)).font(.subheadline.bold())
                                        if !note.text.isEmpty { Text(note.text) }
                                    }.accessibilityElement(children: .combine)
                                }
                                ForEach(day.protectedContributionIDs, id: \.self) { id in
                                    if let source = shop.contributions.first(where: { $0.id == id && $0.removedAt == nil }) {
                                        Text(dinnerFormat("Protected: %@ · %@", source.productName, dinnerQuantity(source.quantity)))
                                    }
                                }
                                NavigationLink(dinnerText("Add or edit a day note")) { DinnerNoteView(model: model, day: day.day) }
                            }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
                        }
                        if !week.unscheduled.isEmpty {
                            Text(dinnerText("Unscheduled")).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(week.unscheduled) { meal in mealLink(meal) }
                        }
                    } else { Text(dinnerText("The week could not be read. Check access and the pickup time zone.")) }
                }
                if model.preview != nil {
                    Section { DinnerDecisionButton(model: model, title: dinnerText("Review pending dinner changes"), identifier: "dinnerPending", preservePending: false) { DinnerPreviewView(model: model) } }
                }
            }
            DinnerFeedback(model: model)
            Section { saveStatus() }
        }.navigationTitle(dinnerText("Dinners")).listStyle(.insetGrouped)
    }
    private func mealLink(_ meal: MealOccurrence) -> some View {
        NavigationLink { DinnerOccurrenceView(model: model, occurrenceID: meal.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.title).font(.headline)
                Text(dinnerFormat("Servings: %@", meal.servings.description))
                if meal.isHidden { Text(dinnerText("Hidden dinner")) }
            }
        }.accessibilityIdentifier("dinnerOccurrence-\(meal.id)")
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
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meal.title).font(.headline)
                            Text(meal.removedAt == nil ? dinnerFormat("Servings: %@", meal.servings.description) : dinnerText("Remove chosen dinner"))
                            Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
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
                            if source.source.isProtected { Text(dinnerText("Protected need")) }
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
    var body: some View {
        List {
            Section {
                Text(dinnerText("Chosen dinners keep their original identities and grocery needs. Earlier reusable templates are available in the dinner library for review."))
                NavigationLink(dinnerText("Dinner library")) { DinnerLibraryView(model: model) }
            }
            ForEach((model.shop?.mealOccurrences ?? []).filter { $0.removedAt == nil }) { meal in
                NavigationLink { DinnerOccurrenceView(model: model, occurrenceID: meal.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(meal.title).font(.headline)
                        Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
                        if meal.isHidden { Text(dinnerText("Hidden dinner")) }
                    }
                }.accessibilityIdentifier("dinnerOccurrence-\(meal.id)")
            }
        }.navigationTitle(dinnerText("All chosen dinners")).dinnerAccess(model)
    }
}
