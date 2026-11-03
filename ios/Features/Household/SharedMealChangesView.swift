import SwiftUI
import CoreDomain
import HouseholdClient

struct SharedMealChangesView: View {
    @ObservedObject var household: HouseholdModel
    var seed: SharedMealChangeSeed? = nil
    var onReviewOpened: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SharedMealChangeModel?
    private var scope: SharedMealChangeScope? { household.sharedMealChangeScope }
    var body: some View {
        Group {
            if let model, model.scope == scope {
                SharedMealChangeContent(model: model, household: household, seed: seed, onReviewOpened: onReviewOpened)
            } else { ContentUnavailableView(ht("Shared meal changes"), systemImage: "person.2", description: Text(ht("Refresh the household and check meal planning access."))) }
        }
        .navigationTitle(ht("Shared meal changes"))
        .task(id: scope) { await open() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.invalidate() }
            else { Task { await open() } }
        }
        .onDisappear { model?.invalidate() }
    }
    @MainActor private func open() async {
        model?.invalidate(); model = nil
        guard let scope, let service = household.service else { return }
        let next = SharedMealChangeModel(scope: scope, service: service, store: household.decisionStore, runtime: { self.scope })
        model = next; await next.load()
    }
}

struct SharedMealPlanningFacts: View {
    let planning: SharedMealPlanning
    var body: some View {
        if let id = planning.sourceOccurrenceId { LabeledContent(ht("Mapped local occurrence"), value: id.uuidString) }
        ForEach(planning.groups) { group in
            LabeledContent(group.name, value: "\(group.servings.numerator)/\(group.servings.denominator)")
            if group.protected { Label(ht("Protected portions"), systemImage: "lock") }
        }
        ForEach(planning.ingredients) { ingredient in
            VStack(alignment: .leading) {
                Text(verbatim: ingredient.name).font(.headline)
                if let q = ingredient.quantity, let amount = try? Rational(Int64(q.amount.numerator), Int64(q.amount.denominator)), let unit = UnitOfMeasure(rawValue: q.unit) {
                    LabeledContent(ht("Ingredient quantity"), value: pQuantity(amount, unit: unit))
                    LabeledContent(ht("Original quantity evidence"), value: q.originalLiteral)
                } else { Text(ht("Ingredient quantity is unknown.")) }
                ForEach(ingredient.groupIds, id: \.self) { id in
                    if let group = planning.groups.first(where: { $0.id == id }) { LabeledContent(ht("Reserved for group"), value: group.name) }
                }
                ForEach((planning.bindings ?? []).filter { $0.ingredientId == ingredient.id }) { binding in
                    if let amount = try? Rational(Int64(binding.quantity.amount.numerator), Int64(binding.quantity.amount.denominator)), let unit = UnitOfMeasure(rawValue: binding.quantity.unit), let group = planning.groups.first(where: { $0.id == binding.groupId }) {
                        LabeledContent(group.name, value: pQuantity(amount, unit: unit))
                    }
                }
                ForEach(ingredient.exclusions, id: \.self) { Text(verbatim: $0) }
            }
        }
    }
}

private struct SharedMealChangeContent: View {
    @ObservedObject var model: SharedMealChangeModel
    @ObservedObject var household: HouseholdModel
    let seed: SharedMealChangeSeed?
    let onReviewOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var candidate: SharedMeal?
    @State private var reason = ""
    @State private var clearing = false
    @State private var dismissing: SharedMealChangePage.Proposal?
    @State private var notice: String?
    var body: some View {
        Form {
            if let page = model.page {
                if (!page.shopper || seed != nil) && model.review == nil && !model.hasPending { editor(page) }
                if let review = model.review {
                    Section(ht("Review exact proposal")) {
                        if let original = page.meals.first(where: { $0.id == review.request.occurrenceId }) { Text(ht("Current shared meal")); SharedMealFacts(meal: original.meal) }
                        Text(ht("Proposed meal")); SharedMealFacts(meal: review.request.meal)
                        LabeledContent(ht("Reason for change"), value: review.request.reason)
                        Text(ht("Sending a proposal does not change shared packs, spending, reservations, or retailer instructions."))
                        Button(ht("Send reviewed proposal")) { Task { await model.sendReviewed() } }.accessibilityIdentifier("meal-change-send")
                        Button(ht("Cancel proposal review")) { model.cancelReview() }
                    }
                }
                Section(ht("Shared proposals")) {
                    if page.proposals.isEmpty { Text(ht("No shared meal changes yet.")) }
                    ForEach(page.proposals) { proposal in
                        DisclosureGroup {
                            if let original = proposal.original { Text(ht("Original reviewed meal")); SharedMealFacts(meal: original) }
                            else { Text(ht("New meal from an explicitly approved household idea")) }
                            Text(ht("Proposed meal")); SharedMealFacts(meal: proposal.request.meal)
                            LabeledContent(ht("Reason for change"), value: proposal.request.reason)
                            Text(status(proposal, page))
                            if page.shopper && proposal.state == "pending" {
                                Button(ht("Review change with shared packs")) { Task { await review(proposal) } }
                                    .disabled(!proposal.isCurrent(in: page)).accessibilityIdentifier("meal-change-shopper-review")
                                Button(ht("Dismiss shared proposal"), role: .destructive) { dismissing = proposal }
                            }
                        } label: { Text(verbatim: proposal.request.meal.title) }
                    }
                }
            }
            if let pending = model.pending {
                Section(ht("Exact saved proposal retry")) {
                    SharedMealFacts(meal: pending.request.meal)
                    LabeledContent(ht("Reason for change"), value: pending.request.reason)
                    Text(ht("Retry keeps the original proposal, occurrence, and reviewed revision. It never updates them silently."))
                    Button(ht("Retry saved proposal")) { Task { await model.retry() } }
                    Button(ht("Check status and clear local retry"), role: .destructive) { clearing = true }
                }
            } else if model.hasPending {
                Text(ht("A private pending proposal needs current planning access before it can be shown."))
                Button(ht("Check status and clear local retry"), role: .destructive) { clearing = true }
            }
            if let notice = model.notice ?? notice { Text(notice).accessibilityIdentifier("meal-change-notice") }
            if model.busy { ProgressView() }
            Button(ht("Refresh shared changes")) { Task { candidate = nil; selected = nil; await model.load() } }
        }
        .disabled(model.busy || !model.live)
        .confirmationDialog(ht("Clear local proposal retry?"), isPresented: $clearing, titleVisibility: .visible) {
            Button(ht("Check status and clear local retry"), role: .destructive) { Task { await model.clearPendingAfterStatusReview() } }
        } message: { Text(ht("This does not withdraw or undo a proposal. The shopper may already have applied it. Exact retry remains the way to confirm the original submission.")) }
        .confirmationDialog(ht("Dismiss shared proposal"), isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }), presenting: dismissing) { value in
            Button(ht("Dismiss shared proposal"), role: .destructive) { Task { await model.dismiss(value) } }
        }
    }
    @ViewBuilder private func editor(_ page: SharedMealChangePage) -> some View {
        Section(ht("Choose the exact shared occurrence")) {
            Text(ht("Select the shared occurrence explicitly. Similar names are not a match."))
            if let seed { LabeledContent(ht("Local source meal"), value: seed.title); LabeledContent(ht("Mapped local occurrence"), value: seed.localOccurrenceID.uuidString) }
            Picker(ht("Shared occurrence"), selection: $selected) {
                Text(ht("Choose a meal")).tag(nil as UUID?)
                ForEach(page.meals) { Text(verbatim: "\($0.meal.title) · \($0.meal.day) · \($0.id.uuidString.prefix(8))").tag(Optional($0.id)) }
            }.accessibilityIdentifier("meal-change-occurrence")
            .onChange(of: selected) { _, id in
                candidate = page.meals.first(where: { $0.id == id })?.meal
                if let seed, candidate != nil { candidate?.title = seed.title; candidate?.portions = seed.portions; candidate?.planning = seed.planning }
                reason = ""; model.cancelReview()
            }
            if page.phase != "draft" { Text(ht("The order is frozen or placed. This remains an amendment proposal; it cannot change the placed basket.")) }
        }
        if let candidate, let selected {
            Section(ht("Proposed meal")) {
                TextField(ht("Meal name"), text: field(\.title))
                Stepper(value: field(\.portions), in: 1...1000) { LabeledContent(ht("Portions"), value: candidate.portions.formatted()) }
                Text(ht("The shared date stays unchanged. Use the separate date proposal for a calendar move."))
                SharedMealPlanningEditor(planning: Binding(get: { self.candidate?.planning ?? .init(groups: [], ingredients: []) }, set: { self.candidate?.planning = $0 }))
                TextField(ht("Reason for change"), text: $reason, axis: .vertical).accessibilityIdentifier("meal-change-reason")
                Text(ht("Changing portions does not scale ingredient quantities or calculate packs here. Review each entered amount."))
                if page.shopper {
                    Text(ht("As the assigned shopper, review this mapped meal with the actual shared packs and checkout quote before applying."))
                    Button(ht("Review mapped meal with shared packs")) { Task {
                        if let edit = await model.reviewedShopperSeed(occurrenceID: selected, meal: candidate) { openDraft(edit) }
                    } }.disabled(model.busy || page.phase != "draft").accessibilityIdentifier("meal-change-shopper-seed")
                } else {
                    Button(ht("Review shared proposal")) { Task { await model.prepare(occurrenceID: selected, meal: candidate, reason: reason) } }
                        .disabled(!model.canPropose).accessibilityIdentifier("meal-change-prepare")
                }
            }
        }
    }
    private func field<T>(_ key: WritableKeyPath<SharedMeal,T>) -> Binding<T> {
        Binding(get: { candidate![keyPath: key] }, set: { candidate?[keyPath: key] = $0; model.cancelReview() })
    }
    private func status(_ proposal: SharedMealChangePage.Proposal, _ page: SharedMealChangePage) -> String {
        switch proposal.state {
        case "applied": return ht("Applied once by the shopper.")
        case "dismissed": return ht("Dismissed by the shopper.")
        default: return proposal.isCurrent(in: page) ? ht("Pending shopper review.") : ht("The source revision or order phase changed. Review a fresh proposal; this one will not be rebased.")
        }
    }
    @MainActor private func review(_ proposal: SharedMealChangePage.Proposal) async {
        if let edit = await model.reviewedEdit(proposal) { openDraft(edit) }
    }
    @MainActor private func openDraft(_ edit: SharedMealEdit) {
        guard let page = model.page, model.live,
              let shared = household.sharedShop, shared.canManage, shared.pending == nil, !shared.editing,
              let shop = shared.shop, UUID(uuidString: shop.shopId) == page.shopId, shop.shopRevision == page.shopRevision,
              shop.authorityEpoch == page.authorityEpoch else { notice = ht("Return to the shared shop and refresh or finish the current edit first."); return }
        shared.beginEditing(); guard shared.editing else { return }
        shared.draft.mealEdit = edit
        dismiss(); onReviewOpened()
    }

}

private struct SharedMealPlanningEditor: View {
    @Binding var planning: SharedMealPlanning
    var body: some View {
        ForEach($planning.groups) { $group in
            DisclosureGroup(group.name.isEmpty ? ht("Serving group") : group.name) {
                TextField(ht("Group name"), text: $group.name)
                LabeledContent(ht("Serving numerator")) { TextField(ht("Serving numerator"), value: $group.servings.numerator, format: .number).keyboardType(.numberPad) }
                LabeledContent(ht("Serving denominator")) { TextField(ht("Serving denominator"), value: $group.servings.denominator, format: .number).keyboardType(.numberPad) }
                Toggle(ht("Protected portions"), isOn: $group.protected)
            }
        }
        Button(ht("Add serving group")) { planning.groups.append(.init(name: "", servings: .init(numerator: 1), protected: false)) }.disabled(planning.groups.count >= 30)
        ForEach($planning.ingredients) { $ingredient in
            DisclosureGroup(ingredient.name.isEmpty ? ht("Ingredient") : ingredient.name) {
                TextField(ht("Ingredient name"), text: $ingredient.name)
                Toggle(ht("Known ingredient quantity"), isOn: Binding(get: { ingredient.quantity != nil }, set: { ingredient.quantity = $0 ? .init(amount: .init(numerator: 1), unit: "count", originalLiteral: "") : nil }))
                if ingredient.quantity != nil {
                    LabeledContent(ht("Quantity numerator")) { TextField(ht("Quantity numerator"), value: Binding(get: { ingredient.quantity?.amount.numerator ?? 1 }, set: { ingredient.quantity?.amount.numerator = $0 }), format: .number).keyboardType(.numberPad) }
                    LabeledContent(ht("Quantity denominator")) { TextField(ht("Quantity denominator"), value: Binding(get: { ingredient.quantity?.amount.denominator ?? 1 }, set: { ingredient.quantity?.amount.denominator = $0 }), format: .number).keyboardType(.numberPad) }
                    Picker(ht("Ingredient unit"), selection: Binding(get: { ingredient.quantity?.unit ?? "count" }, set: { ingredient.quantity?.unit = $0 })) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }
                    TextField(ht("Original quantity evidence"), text: Binding(get: { ingredient.quantity?.originalLiteral ?? "" }, set: { ingredient.quantity?.originalLiteral = $0 }))
                }
                ForEach(planning.groups) { group in
                    Toggle(group.name, isOn: Binding(get: { ingredient.groupIds.contains(group.id) }, set: { included in
                        ingredient.groupIds.removeAll { $0 == group.id }; if included { ingredient.groupIds.append(group.id) }
                    }))
                }
                ForEach(ingredient.exclusions, id: \.self) { Text(verbatim: $0) }
                Button(ht("Remove proposed ingredient"), role: .destructive) { planning.ingredients.removeAll { $0.id == ingredient.id } }
            }
        }
        Button(ht("Add proposed ingredient")) { planning.ingredients.append(.init(name: "", quantity: nil, groupIds: [], exclusions: [])) }.disabled(planning.ingredients.count >= 60)
    }
}
