import CoreDomain
import HouseholdClient
import SwiftUI

func sharedRecoveryText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "Recovery")
}

@MainActor
func showsReviewedRecovery(_ page: SharedRecoveryPage, model: HouseholdShopModel, household: HouseholdModel) -> Bool {
    !household.locked && household.sharedShop === model && model.canReadMealRecovery && model.recoveryRecord == page &&
        model.scope.shopId.flatMap(UUID.init(uuidString:)) == page.shopId && model.shop?.shopRevision == page.base.shopRevision &&
        model.shop?.placedRevision == page.placedRevision && model.shop?.authorityEpoch == page.base.authorityEpoch
}

func recoveryGroupNames(_ ids: [UUID], meal: SharedRecoveryMeal) -> String {
    let names = meal.groups.filter { ids.contains($0.id) }.map(\.name)
    return names.isEmpty ? sharedRecoveryText("Whole meal") : names.joined(separator: ", ")
}

struct SharedRecoveryDeskView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let shopID: UUID
    private struct Selection: Identifiable {
        let id = UUID()
        let meal: SharedRecoveryMeal
        let page: SharedRecoveryPage
    }
    private struct FallbackSession: Identifiable {
        let id = UUID()
        let page: SharedRecoveryPage
    }
    @State private var fallbackSession: FallbackSession?
    @State private var selection: Selection?
    @State private var applied = false

    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadMealRecovery &&
        model.scope.shopId.flatMap(UUID.init(uuidString:)) == shopID && model.shop?.phase == "placed"
    }

    var body: some View {
        List {
            if allowed, let page = model.recoveryRecord, page.shopId == shopID, showsReviewedRecovery(page, model: model, household: household) {
                if model.pendingMealRecovery {
                    Section(sharedRecoveryText("Pending meal replacement")) {
                        Button(sharedRecoveryText("Retry reviewed replacement")) { Task { await model.retry() } }
                            .disabled(model.busy).accessibilityIdentifier("recovery.retry")
                    }
                }
                if applied { Text(sharedRecoveryText("Meal replacement saved")).accessibilityIdentifier("recovery.saved") }
                if let delivery = model.deliveryRecord, delivery.recoveryRevision == page.base.recoveryRevision {
                    NavigationLink(sharedRecoveryText("Current meals and cook instructions")) {
                        SharedRecoveryCoverageView(model: model, household: household, delivery: delivery)
                    }.accessibilityIdentifier("recovery.currentCoverage")
                }
                if model.scope.capabilities.contains("accepted_fallbacks") {
                    Button(fallbackText("Household fallback recipes")) {
                        applied = false
                        fallbackSession = FallbackSession(page: page)
                    }.accessibilityIdentifier("recovery.fallbackLibrary")
                }
                ForEach(page.meals) { meal in
                    Button { selection = Selection(meal: meal, page: page); applied = false } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: meal.title).font(.headline)
                            Text(verbatim: sharedMealScheduleText(meal.day, locale: .current))
                        }
                    }
                    .disabled(!meal.needs.contains { $0.priority == "required" } || model.pending != nil)
                    .accessibilityIdentifier("recovery.meal." + meal.id.uuidString)
                }
                if page.meals.isEmpty { Text(sharedRecoveryText("No scheduled meals are available.")) }
            } else if allowed && model.busy { ProgressView() }
            else { Text(sharedRecoveryText("Refresh the current meal record.")) }
            if allowed {
                Button(ht("Refresh")) { Task { await model.loadMealRecovery() } }
                    .disabled(model.busy).accessibilityIdentifier("recovery.refresh")
                if let notice = model.notice { Text(verbatim: notice) }
            }
        }
        .navigationTitle(sharedRecoveryText("Repair a scheduled meal"))
        .task(id: shopID) { if allowed { await model.loadMealRecovery() } }
        .onChange(of: allowed) { _, current in
            if !current { selection = nil; fallbackSession = nil }
        }
        .onChange(of: model.recoveryRecord?.base) { _, current in
            if let current, let fallbackSession, current != fallbackSession.page.base {
                self.fallbackSession = nil
            }
        }
        .fullScreenCover(item: $fallbackSession) { session in
            NavigationStack {
                SharedFallbackRoot(shop: model, household: household, page: session.page) { saved in
                    applied = saved
                    fallbackSession = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ht("Close")) { fallbackSession = nil }
                    }
                }
            }
        }
        .sheet(item: $selection) { selected in
            if allowed {
                NavigationStack {
                    SharedRecoveryEditor(model: model, household: household, page: selected.page, target: selected.meal) { saved in
                        applied = saved
                        selection = nil
                    }
                }
            } else {
                Text(sharedRecoveryText("Refresh the current meal record."))
                    .onAppear { selection = nil }
            }
        }
    }
}

private struct RecoveryDecision: Identifiable {
    let id = UUID()
    let intent: SharedRecoveryIntent
    let preview: SharedRecoveryPreview
}

private struct SharedRecoveryEditor: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedRecoveryPage
    let target: SharedRecoveryMeal
    let finish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    private enum Input: Hashable {
        case title, notes, remaining, lead
        case ingredient(UUID), quantity(UUID)
    }
    @FocusState private var input: Input?
    @State private var draft: SharedRecoveryDraft
    @State private var decision: RecoveryDecision?
    @State private var checking = false
    @State private var message: String?
    @State private var generation = UUID()

    init(model: HouseholdShopModel, household: HouseholdModel, page: SharedRecoveryPage, target: SharedRecoveryMeal, finish: @escaping (Bool) -> Void) {
        self.model = model; self.household = household; self.page = page; self.target = target; self.finish = finish
        _draft = State(initialValue: .init(target: target))
    }

    private var allowed: Bool {
        showsReviewedRecovery(page, model: model, household: household) && model.shop?.phase == "placed"
    }

    private var donors: [SharedRecoveryMeal] {
        let dinners = model.deliveryRecord?.meals?.filter { $0.meal.kind == "dinner" } ?? []
        return page.meals.filter { candidate in
            dinners.contains { $0.id == candidate.id && $0.revision == candidate.sourceMealRevision } &&
                SharedRecoveryDraft.repeated(candidate, for: target) != nil
        }
    }

    var body: some View {
        Form {
            if allowed {
                Section {
                    Text(verbatim: target.title).font(.headline)
                    LabeledContent(sharedRecoveryText("Scheduled day"), value: sharedMealScheduleText(target.day, locale: .current))
                    LabeledContent(sharedRecoveryText("Scheduled time zone"), value: target.zone ?? ht("Unknown"))
                    LabeledContent(sharedRecoveryText("Meal deadline"), value: target.due.flatMap { SharedMealDeadline(at: $0, zone: target.zone ?? "UTC").display(locale: .current) } ?? ht("Unknown"))
                    LabeledContent(ht("Portions"), value: String(target.portions))
                    ForEach(target.groups, id: \.id) { group in
                        let servings = group.servings.denominator == 1 ? String(group.servings.numerator) : "\(group.servings.numerator)/\(group.servings.denominator)"
                        LabeledContent(group.name, value: servings + (group.protected ? " · " + ht("Protected portions") : ""))
                    }
                    ForEach(target.needs.filter { $0.priority == "protected" }) { need in
                        LabeledContent(need.name + " · " + ht("Protected portions"), value: deliveryQuantityText(need.quantity))
                    }
                    if !target.exclusions.isEmpty { LabeledContent(ht("Meal exclusions"), value: target.exclusions.joined(separator: ", ")) }
                }
                Section {
                    Picker(sharedRecoveryText("Replacement"), selection: Binding(get: { draft.repeatID }, set: choose)) {
                        Text(sharedRecoveryText("Enter a replacement")).tag(UUID?.none)
                        ForEach(donors) { donor in
                            Text(verbatim: sharedRecoveryText("Repeat") + " · " + donor.title + " · " + (sharedMealScheduleText(donor.day, locale: .current))).tag(Optional(donor.id))
                        }
                    }.accessibilityIdentifier("recovery.method")
                    if draft.repeatID == nil {
                        TextField(sharedRecoveryText("Replacement meal"), text: $draft.title)
                            .focused($input, equals: .title).accessibilityIdentifier("recovery.title")
                        TextField(sharedRecoveryText("Preparation notes"), text: $draft.notes, axis: .vertical)
                            .focused($input, equals: .notes)
                    } else { Text(verbatim: draft.title).font(.headline) }
                }
                ForEach(draft.ingredients) { row in
                    ingredient(dinnerDraftBinding(row, in: $draft.ingredients))
                }
                if draft.repeatID == nil {
                    Button(sharedRecoveryText("Add an ingredient")) {
                        guard let first = SharedRecoveryDraft.scopes(target).first else { return }
                        draft.ingredients.append(.init(groups: first))
                    }.accessibilityIdentifier("recovery.addIngredient")
                }
                Section {
                    TextField(sharedRecoveryText("Remaining preparation minutes"), text: $draft.remaining).keyboardType(.numberPad)
                        .focused($input, equals: .remaining)
                        .accessibilityIdentifier("recovery.remaining")
                    if draft.repeatID == nil {
                        TextField(sharedRecoveryText("Required lead time in minutes"), text: $draft.lead).keyboardType(.numberPad)
                        .focused($input, equals: .lead)
                    } else {
                        LabeledContent(sharedRecoveryText("Required lead time in minutes"), value: draft.lead.isEmpty ? ht("Unknown") : draft.lead)
                    }
                    Toggle(sharedRecoveryText("Advance steps are complete for this meal"), isOn: $draft.completed)
                    Toggle(sharedRecoveryText("This replacement requires another trip"), isOn: $draft.extraTrip)
                        .accessibilityIdentifier("recovery.extraTrip")
                } footer: { Text(sharedRecoveryText("Leave an unknown time blank.")) }
                if let message { Text(verbatim: message) }
                Button(sharedRecoveryText("Preview meal replacement")) { Task { await preview() } }
                    .disabled(checking || model.busy || model.pending != nil)
                    .accessibilityIdentifier("recovery.preview")
                if checking { ProgressView() }
            } else { Text(sharedRecoveryText("Refresh the current meal record.")) }
        }
        .keyboardDoneAction(visible: input != nil, title: ht("Done"), identifier: "recovery.finishEditing") {
            input = nil
        }
        .navigationTitle(sharedRecoveryText("Replace meal"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { generation = UUID(); dismiss() } } }
        .onChange(of: draft) { _, _ in generation = UUID(); decision = nil; message = nil }
        .onChange(of: allowed) { _, current in if !current { generation = UUID(); decision = nil } }
        .onChange(of: scene) { _, current in if current != .active { generation = UUID(); decision = nil } }
        .sheet(item: $decision) { reviewed in
            NavigationStack {
                SharedRecoveryReview(model: model, household: household, page: page,
                    initial: reviewed.preview, originalIntent: reviewed.intent, finish: finish)
            }
        }
    }

    private func choose(_ donorID: UUID?) {
        if let donor = donors.first(where: { $0.id == donorID }), let repeated = SharedRecoveryDraft.repeated(donor, for: target) {
            draft = repeated
        } else { draft = SharedRecoveryDraft(target: target) }
    }

    @ViewBuilder private func ingredient(_ row: Binding<RecoveryIngredientDraft>) -> some View {
        let value = row.wrappedValue
        Section {
            if draft.repeatID == nil {
                TextField(ht("Ingredient"), text: row.name)
                    .focused($input, equals: .ingredient(value.id)).accessibilityIdentifier("recovery.ingredient")
                TextField(ht("Ingredient quantity"), text: row.literal)
                    .focused($input, equals: .quantity(value.id)).accessibilityIdentifier("recovery.quantity")
                Picker(sharedRecoveryText("Unit"), selection: row.unit) {
                    ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(dinnerUnit(unit)).tag(unit) }
                }
                Picker(ht("Serving group"), selection: row.groups) {
                    ForEach(SharedRecoveryDraft.scopes(target), id: \.self) { ids in Text(recoveryGroupNames(ids, meal: target)).tag(ids) }
                }
            } else {
                LabeledContent(value.name, value: deliveryQuantityText(value.repeatQuantity))
                LabeledContent(ht("Serving group"), value: recoveryGroupNames(value.groups, meal: target))
            }
            let linked = Set(value.groups)
            let restrictions = target.needs.filter {
                let group = Set(SharedRecoveryDraft.groups($0))
                return $0.priority == "required" && (group.isEmpty ? linked.isEmpty : !group.isDisjoint(with: linked))
            }.flatMap(\.exclusions) + value.exclusions
            if !restrictions.isEmpty {
                LabeledContent(ht("Ingredient exclusions"), value: Array(Set(restrictions)).sorted().joined(separator: ", "))
            }
            ForEach(page.sourceOptions, id: \.sourceId) { source in
                Toggle(isOn: Binding(get: { row.wrappedValue.matched.contains(source.sourceId) }, set: { selected in
                    if selected { row.wrappedValue.matched.insert(source.sourceId) }
                    else { row.wrappedValue.matched.remove(source.sourceId) }
                })) {
                    VStack(alignment: .leading) {
                        Text(verbatim: source.name)
                        Text(verbatim: recoverySourceKind(source.kind) + " · " + deliveryQuantityText(source.quantity)).font(.footnote)
                        if !source.exclusionTags.isEmpty { Text(verbatim: source.exclusionTags.joined(separator: ", ")).font(.footnote) }
                    }
                }.accessibilityIdentifier("recovery.source." + source.sourceId.uuidString)
            }
            if draft.repeatID == nil && draft.ingredients.count > 1 {
                Button(sharedRecoveryText("Remove ingredient"), role: .destructive) { draft.ingredients.removeAll { $0.id == value.id } }
            }
        } header: { Text(ht("Ingredient")) }
    }

    private func preview() async {
        guard allowed, scene == .active, !checking else { return }
        checking = true
        defer { checking = false }
        let request = generation
        do {
            let intent = try draft.intent(page: page, target: target)
            let preview = try await model.previewMealRecovery(intent, reviewed: page)
            guard request == generation, allowed, scene == .active else { return }
            decision = .init(intent: intent, preview: preview)
        } catch {
            if request == generation { message = model.notice ?? sharedRecoveryText("Check the meal, ingredient quantities and current record, then preview again.") }
        }
    }
}

func recoverySourceKind(_ kind: String) -> String {
    switch kind {
    case "pantry": pantryLocation("pantry")
    case "freezer": pantryLocation("freezer")
    case "delivery": sharedRecoveryText("Delivery")
    default: ht("Unknown")
    }
}
