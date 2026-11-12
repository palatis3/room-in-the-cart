import SwiftUI
import HouseholdClient

struct SharedMealIdeasView: View {
    @ObservedObject var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SharedMealIdeaModel?
    @State private var selectedProposal: ProposalSelection?
    @State private var showingProposal = false
    private struct ProposalSelection {
        let idea: SharedMealIdeaPage.Idea
        let scope: SharedMealChangeScope
    }
    private var scope: SharedMealChangeScope? { household.sharedMealChangeScope }
    var body: some View {
        VStack(spacing: 0) {
            if let model, model.scope == scope {
                SharedMealIdeaEditor(model: model, household: household, onPropose: { idea, reviewedScope in
                    guard idea.state == "approved", reviewedScope == scope else { return }
                    selectedProposal = .init(idea: idea, scope: reviewedScope)
                    showingProposal = true
                })
            } else {
                ContentUnavailableView(ht("Household dinner ideas"), systemImage: "person.2", description: Text(ht("Refresh the household and check meal planning access.")))
            }
        }.navigationTitle(ht("Household dinner ideas"))
        // Keep the destination outside the editor Form's disabled environment.
        // Its approved value stays stable when the parent model is invalidated.
        .navigationDestination(isPresented: $showingProposal) {
            if let selectedProposal, selectedProposal.scope == scope {
                SharedMealIdeaProposalView(household: household, idea: selectedProposal.idea, scope: selectedProposal.scope)
            } else { Text(ht("Refresh the household and check meal planning access.")) }
        }
        .task(id: scope) {
            if selectedProposal?.scope != scope { showingProposal = false; selectedProposal = nil }
            await open()
        }
        .onChange(of: showingProposal) { _, presented in if !presented { selectedProposal = nil } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model?.invalidate(); showingProposal = false; selectedProposal = nil
            } else { Task { await open() } }
        }.onDisappear { model?.invalidate() }
    }
    @MainActor private func open() async {
        model?.invalidate(); model = nil
        guard let scope, let service = household.service else { return }
        let next = SharedMealIdeaModel(scope: scope, service: service, runtime: { self.scope })
        model = next; await next.load()
    }
}

private struct SharedMealIdeaEditor: View {
    @ObservedObject var model: SharedMealIdeaModel
    @ObservedObject var household: HouseholdModel
    let onPropose: (SharedMealIdeaPage.Idea, SharedMealChangeScope) -> Void
    @State private var ideaID = UUID()
    @State private var draft = SharedMealIdeaDraft()
    @State private var reviewed = false
    @State private var reviewApproval = false
    @FocusState private var inputFocus: String?
    private var saved: SharedMealIdeaPage.Idea? { model.page?.ideas.first { $0.id == ideaID } }
    private var own: Bool { saved == nil || saved?.actorId.uuidString.lowercased() == model.scope.memberID.lowercased() }
    var body: some View {
        Form {
            Section(ht("Household scope")) {
                Text(verbatim: household.projection?.household.label ?? "")
                Text(ht("Enter only food evidence this household may share. Private device stock, prices, and decision history are not imported."))
            }
            if let page = model.page {
                Section(ht("Saved household ideas")) {
                    ForEach(page.ideas) { idea in
                        Button { ideaID = idea.id; draft = idea.draft; reviewed = false } label: {
                            VStack(alignment: .leading) { Text(verbatim: idea.draft.title); Text(idea.state == "approved" ? ht("Adult approved") : ht("Draft only")) }
                        }.disabled(model.pending != nil)
                    }
                    Button(ht("New manual household idea")) { ideaID = UUID(); draft = .init(); reviewed = false }
                        .disabled(model.pending != nil)
                    Button(ht("Use editable household idea template")) { template() }.disabled(model.pending != nil)
                }
            }
            Section(ht("Editable household idea")) {
                TextField(ht("Meal name"), text: $draft.title).focused($inputFocus, equals: "title")
                Text(draft.source == "app_template" ? ht("Source: app-owned editable template") : ht("Source: household manual entry"))
                Stepper(value: $draft.servings, in: 1...1000) { LabeledContent(ht("Suggested servings"), value: draft.servings.formatted()) }
                number(ht("Preparation minutes, if known"), value: $draft.minutes).focused($inputFocus, equals: "minutes")
                multilineField(ht("Assumed extras, one per line"), values: $draft.assumedExtras, focus: "extras")
                multilineField(ht("Shared household exclusions, one per line"), values: $draft.exclusions, focus: "exclusions")
                Text(ht("Review exclusions with the household. This does not read private decision history."))
            }.disabled(!own || model.pending != nil)
            ForEach(draft.ingredients) { snapshot in
                let ingredient = dinnerDraftBinding(snapshot, in: $draft.ingredients)
                let id = snapshot.id
                let prefix = "ingredient.\(id)."
                Section {
                    TextField(ht("Ingredient name"), text: ingredient.name).focused($inputFocus, equals: prefix + "name")
                    Picker(ht("Ingredient unit"), selection: ingredient.unit) {
                        Text(ht("Count")).tag("count"); Text(ht("Grams")).tag("gram"); Text(ht("Kilograms")).tag("kilogram")
                        Text(ht("Ounces")).tag("ounce"); Text(ht("Pounds")).tag("pound")
                        Text(ht("Milliliters")).tag("milliliter"); Text(ht("Liters")).tag("liter")
                        Text(ht("Fluid ounces")).tag("fluidOunce"); Text(ht("Cups")).tag("cup")
                    }
                    SharedIdeaAmountField(title: ht("Required quantity"), value: ingredient.required, focus: $inputFocus, fieldID: prefix + "required")
                    SharedIdeaAmountField(title: ht("Household stock in this unit"), value: ingredient.stock, focus: $inputFocus, fieldID: prefix + "stock")
                    ForEach(ingredient.wrappedValue.reservations) { snapshot in
                        let reservation = dinnerDraftBinding(snapshot, in: ingredient.reservations)
                        let reservationID = snapshot.id
                        let field = prefix + "reservation.\(reservationID)."
                        TextField(ht("Named reservation"), text: reservation.name)
                            .focused($inputFocus, equals: field + "name")
                        SharedIdeaAmountField(title: ht("Reserved quantity"), value: Binding(get: { reservation.wrappedValue.amount }, set: { reservation.wrappedValue.amount = $0 ?? 0 }),
                                             focus: $inputFocus, fieldID: field + "amount")
                        Button(ht("Remove reservation"), role: .destructive) {
                            inputFocus = nil
                            ingredient.wrappedValue.reservations.removeAll { $0.id == reservationID }
                        }
                    }
                    Button(ht("Add named reservation")) { ingredient.wrappedValue.reservations.append(.init(name: "", amount: 1)) }.disabled(ingredient.wrappedValue.reservations.count >= 20)
                    SharedIdeaAmountField(title: ht("Whole package quantity"), value: ingredient.pack, focus: $inputFocus, fieldID: prefix + "pack")
                    number(ht("Usable yield numerator"), value: ingredient.usableNumerator).focused($inputFocus, equals: prefix + "numerator")
                    number(ht("Usable yield denominator"), value: ingredient.usableDenominator).focused($inputFocus, equals: prefix + "denominator")
                    Text(ht("Use the same unit throughout. Enter 1 / 1 only when the whole pack is usable. Blank evidence remains unknown."))
                    TextField(ht("Household stock and package evidence"), text: ingredient.evidence, axis: .vertical)
                        .focused($inputFocus, equals: prefix + "evidence")
                        .accessibilityLabel(ht("Household stock and package evidence"))
                        .accessibilityIdentifier("household-idea-evidence")
                    Button(ht("Remove ingredient"), role: .destructive) { draft.ingredients.removeAll { $0.id == id } }.disabled(draft.ingredients.count == 1)
                }.disabled(!own || model.pending != nil)
            }
            if own {
                Button(ht("Add ingredient")) { draft.ingredients.append(.init()) }.disabled(draft.ingredients.count >= 60 || model.pending != nil)
                Button(ht("Save household draft for review")) {
                    let reviewedDraft = draft.normalizedForSave(), selectedID = ideaID
                    draft = reviewedDraft
                    Task { await model.write(ideaID: selectedID, draft: reviewedDraft, approve: false, reviewed: false) }
                }
                    .disabled(model.pending != nil || saved?.draft == draft).accessibilityIdentifier("household-idea-save")
            }
            if let saved, saved.draft == draft {
                SharedMealIdeaPreviewView(idea: saved)
                if saved.state == "approved" {
                    Text(ht("Approved idea only. It is not scheduled and has changed no shared shopping lines."))
                    Button(ht("Separately propose this approved meal")) { onPropose(saved, model.scope) }
                        .disabled(!own).accessibilityIdentifier("household-idea-propose")
                } else if own {
                    Toggle(ht("I reviewed these household quantities, exclusions, reservations, and usable packs"), isOn: $reviewed)
                    Button(ht("Review adult approval")) { reviewApproval = true }
                        .disabled(!reviewed || !saved.preview.canApprove || model.pending != nil).accessibilityIdentifier("household-idea-approve")
                }
            } else { Text(ht("Save corrections to receive a fresh household preview. Saving edits replaces any earlier approval of this draft.")) }
            if model.pending != nil {
                Section(ht("Unconfirmed household idea")) {
                    Button(ht("Retry exact saved idea")) { Task { await model.retry() } }
                    Button(ht("Reconcile household idea status")) { Task { await model.reconcile() } }
                }
            }
            if let notice = model.notice { Text(notice) }
            Button(ht("Refresh household ideas")) { Task { await model.load() } }
        }.disabled(model.busy || !model.live)
        .keyboardDoneAction(visible: inputFocus != nil, title: ht("Done"), identifier: "household-idea-keyboard-done") { inputFocus = nil }
        .onChange(of: draft) { _, _ in reviewed = false }
        .confirmationDialog(ht("Approve this household idea?"), isPresented: $reviewApproval, titleVisibility: .visible) {
            Button(ht("Approve meal and quantities")) { Task { await model.write(ideaID: ideaID, draft: draft, approve: true, reviewed: reviewed) } }
            Button(ht("Cancel")) { reviewApproval = false }
                .accessibilityIdentifier("household-idea-cancel-approval")
        } message: { Text(ht("This saves adult approval only. Linking a meal and changing shared packs require separate reviews.")) }
    }
    private func multilineField(_ title: String, values: Binding<[String]>, focus: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).accessibilityHidden(true)
            TextField("", text: lines(values), axis: .vertical)
                .focused($inputFocus, equals: focus)
                .accessibilityLabel(title)
                .frame(minHeight: 44)
        }
    }
    private func lines(_ value: Binding<[String]>) -> Binding<String> {
        Binding(get: { value.wrappedValue.joined(separator: "\n") },
                set: { value.wrappedValue = $0.components(separatedBy: "\n") })
    }
    private func number(_ title: String, value: Binding<Int?>) -> some View { TextField(title, value: value, format: .number).keyboardType(.numberPad) }
    private func template() {
        ideaID = UUID(); reviewed = false
        draft = .init(title: ht("Bean and rice bowls"), source: "app_template", servings: 2, minutes: 25,
            assumedExtras: [ht("Water and cooking equipment; review any seasoning separately")],
            ingredients: [.init(name: ht("Rice"), required: 150, evidence: ht("Template quantity; household stock and package evidence still needed")),
                          .init(name: ht("Beans"), required: 250, evidence: ht("Template quantity; household stock and package evidence still needed"))])
    }
}

struct SharedMealIdeaPreviewView: View {
    let idea: SharedMealIdeaPage.Idea
    var body: some View {
        Section(ht("Reviewed household supply")) {
            ForEach(idea.preview.ingredients) { p in
                if let ingredient = idea.draft.ingredients.first(where: { $0.id == p.id }) {
                    Text(verbatim: ingredient.name).font(.headline)
                    Text(sharedIdeaUnitLabel(ingredient.unit))
                    LabeledContent(ht("Named reserved quantity"), value: p.reserved?.text ?? ht("Unknown"))
                    LabeledContent(ht("Remaining household stock"), value: p.remaining?.text ?? ht("Unknown"))
                    LabeledContent(ht("Uncovered quantity"), value: p.shortage?.text ?? ht("Unknown"))
                    LabeledContent(ht("Whole packs needed"), value: p.wholePacks.map(String.init) ?? ht("Unknown"))
                    if p.arithmeticUnavailable == true { Text(ht("This fraction exceeds the supported exact calculation range. Review smaller equivalent quantities.")) }
                    if p.excluded { Text(ht("This ingredient conflicts with a reviewed household exclusion. Replace or remove it.")) }
                    Text(ht("Price unresolved. The shopper must separately review shared packs and budget."))
                }
            }
            if !idea.preview.canApprove { Text(ht("Resolve exclusions and unknown stock, quantity, pack, or usable yield before approval.")) }
        }
    }
}

private func sharedIdeaUnitLabel(_ unit: String) -> String {
    switch unit {
    case "count": return ht("Count")
    case "gram": return ht("Grams")
    case "kilogram": return ht("Kilograms")
    case "ounce": return ht("Ounces")
    case "pound": return ht("Pounds")
    case "milliliter": return ht("Milliliters")
    case "liter": return ht("Liters")
    case "fluidOunce": return ht("Fluid ounces")
    case "cup": return ht("Cups")
    default: return unit
    }
}
private struct SharedIdeaAmountField: View {
    let title: String
    @Binding var value: SharedMealIdeaAmount?
    let focus: FocusState<String?>.Binding
    let fieldID: String
    @State private var entered = ""
    var body: some View {
        TextField(title, text: $entered).keyboardType(.numbersAndPunctuation).focused(focus, equals: fieldID)
            .onAppear { entered = value?.text ?? "" }
            .onChange(of: entered) { _, text in value = SharedMealIdeaAmount.parse(text) }
            .onChange(of: value) { _, amount in if focus.wrappedValue != fieldID { entered = amount?.text ?? "" } }
            .accessibilityHint(ht("Enter a whole number or an exact fraction, such as 1/2. Blank means unknown."))
    }
}
