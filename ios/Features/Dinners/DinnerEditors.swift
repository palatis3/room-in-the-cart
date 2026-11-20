import SwiftUI
import CoreDomain

/// SwiftUI may retain a row binding while a collection is removed/reordered or
/// its editor is torn down. Resolve identity on every access, never a saved index.
/// The outgoing row can finish reading its snapshot; late writes cannot resurrect
/// it, change its identity, or accidentally edit the row now at its former index.
func dinnerDraftBinding<Element: Identifiable>(_ snapshot: Element, in collection: Binding<[Element]>) -> Binding<Element> {
    let id = snapshot.id
    return Binding(get: {
        collection.wrappedValue.first { $0.id == id } ?? snapshot
    }, set: { updated, transaction in
        guard updated.id == id else { return }
        var current = collection.wrappedValue
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index] = updated
        collection.transaction(transaction).wrappedValue = current
    })
}

// Own the full Form row hit area while keeping the semantic label colors.
private struct DinnerIdeaAcceptanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionLabel(label: configuration.label, isPressed: configuration.isPressed)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
    }
}

enum DinnerEditorPurpose { case manual, reusable, idea }
struct DinnerTemplateEditor: View {
    @ObservedObject var model: DinnerFeatureModel
    let purpose: DinnerEditorPurpose
    @State private var originalIdea: DinnerIdeaDraft?
    @State private var draft: DinnerTemplateDraft
    @State private var scheduled = false
    @State private var date = Date()
    @State private var fallback = false
    @State private var yieldConfirmed = false
    @State private var availabilityConfirmed = false
    @State private var assumptions = ""
    @State private var reviewed: MealTemplate?
    @State private var originalIdentity: DinnerFeatureModel.EditorIdentity?
    @State private var supplyEvidence: [DinnerIdeaFoodEvidence]
    @State private var reviewedIdea: DinnerIdeaDraft?
    @State private var acceptedID = UUID()
    @State private var showPreview = false
    @State private var completed = false
    @State private var savedAsDraft = false
    @State private var accepting = false
    @State private var activeAttempt: UUID?
    @State private var firstSaveCue: BrandCartMotion.Cue?
    @State private var presentInEditor = false
    @AccessibilityFocusState private var savedResultFocused: Bool
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var inputFocus: String?
    @Environment(\.dismiss) private var dismiss
    init(model: DinnerFeatureModel, purpose: DinnerEditorPurpose, initial: MealTemplate? = nil, idea: DinnerIdeaDraft? = nil, servingsUnknown: Bool = false, planForDay: Bool = false) {
        self.model = model; self.purpose = purpose
        _scheduled = State(initialValue: planForDay)
        _originalIdea = State(initialValue: idea)
        _originalIdentity = State(initialValue: model.editorIdentity)
        _supplyEvidence = State(initialValue: idea?.supplyEvidence ?? [])
        var draft = DinnerTemplateDraft(idea?.template ?? initial)
        if servingsUnknown { draft.servings = "" }
        _draft = State(initialValue: draft)
        _acceptedID = State(initialValue: model.state.acceptedDinners.first(where: { $0.sourceIdeaID == idea?.id && idea != nil })?.id ?? UUID())
        _yieldConfirmed = State(initialValue: idea?.yieldConfirmed ?? false)
        _availabilityConfirmed = State(initialValue: idea?.availabilityConfirmed ?? false)
        _assumptions = State(initialValue: idea?.assumptions.joined(separator: "\n") ?? "")
    }
    var body: some View {
        if let originalIdentity, model.editorIdentity == originalIdentity {
            editor
        } else {
            Text(dinnerText("Planning access changed or expired. Reconnect and review again.")).padding()
        }
    }
    private var editor: some View {
        VStack(spacing: 0) {
            if inputFocus != nil {
                DinnerFocusedDoneBar(identifier: purpose == .idea ? "dinnerFocusedKeyboardDone" : dinnerText("Done")) {
                    inputFocus = nil
                }
            }
            editorForm
        }
        .navigationTitle(purpose == .manual ? dinnerText("Manual dinner") : purpose == .idea ? dinnerText("Dinner idea") : dinnerText("Reusable dinner"))
        .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
        .toolbar {
            if purpose == .idea, reviewed != nil, reviewedIdea != nil, !completed, inputFocus == nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(dinnerText("Edit"), action: continueEditing)
                        .disabled(accepting).accessibilityIdentifier("dinnerReviewEdit")
                }
            }
        }
        .onAppear { presentInEditor = true }
        .onDisappear {
            presentInEditor = false
            activeAttempt = nil
            firstSaveCue = nil
        }
        .onChange(of: scene) { _, phase in
            if phase != .active { activeAttempt = nil; firstSaveCue = nil }
        }
        .dinnerAccess(model)
        .dinnerApplyPresentation(model, presented: $showPreview)
    }
    private var editorForm: some View {
        WorkingForm {
            if completed {
                let showsFirstSaveMark = firstSaveCue != nil && model.milestoneAccess() && !typeSize.isAccessibilitySize
                Section {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let reviewed { Text(verbatim: reviewed.title).font(.system(.title2, design: .serif, weight: .semibold)) }
                            Text(dinnerText(savedAsDraft ? "Idea draft saved. You can edit it again in Dinner ideas." :
                                "Dinner saved. Choose it separately to add grocery needs."))
                                .accessibilityFocused($savedResultFocused)
                                .accessibilityIdentifier(showsFirstSaveMark ? "dinner.firstSaveConfirmation" : "dinner.savedConfirmation")
                        }
                        if showsFirstSaveMark {
                            BrandCartMotion(cue: firstSaveCue, kind: .firstDinner)
                                .frame(width: 48, height: 48)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .onAppear { savedResultFocused = true }
                    Button(dinnerText("Done")) { dismiss() }.buttonStyle(PrimaryAction())
                }
            } else if let reviewed {
                Section(dinnerText("Review dinner")) {
                    Text(reviewed.title).font(.system(.title2, design: .serif, weight: .semibold))
                    Text(dinnerFormat("Servings: %@", reviewed.servings.description))
                    if let minutes = reviewed.leadTimeMinutes {
                        Text(tonightText("Preparation time") + " · " + Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes])))
                    }
                    MealPreferenceIssues(result: MealEligibilityPolicy.evaluate(profile: model.mealPreferences, template: reviewed))
                    ForEach(reviewed.ingredients) { ingredient in
                        VStack(alignment: .leading) { Text(ingredient.name); Text(ingredient.reviewedAmountLabel) }
                            .accessibilityElement(children: .combine)
                    }
                    ForEach(reviewed.servingGroups) { group in
                        Text(dinnerFormat("%@ · %@ servings", group.name, group.servings.description))
                        if group.isProtected { Text(dinnerText("Protected group")) }
                    }
                    if let idea = reviewedIdea {
                        let review = DinnerIdeaEngine.review(idea)
                        ForEach(review.issues, id: \.self) { Text(dinnerIssue($0)) }
                        Text(review.canClaimCoverage ? dinnerText("Yield and availability were marked reviewed. Pack prices still need separate evidence.") : dinnerText("Acceptance does not confirm food coverage, stock or checkout cost."))
                        DinnerIdeaSupplyViews(model: model, idea: idea) { value, ingredientID in
                            supplyEvidence.removeAll { $0.id == ingredientID }
                            if let value { supplyEvidence.append(value) }
                            reviewedIdea?.supplyEvidence = supplyEvidence
                        }
                        .disabled(accepting)
                        Button(dinnerText("Accept idea")) {
                            saveAccepted { feedback in
                                await model.acceptIdea(idea, acceptedID: acceptedID, onFirstSave: feedback)
                            }
                        }
                        .buttonStyle(DinnerIdeaAcceptanceButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .disabled(!review.canAccept || !model.editable)
                        .accessibilityIdentifier("dinnerAcceptIdea")
                        Button(dinnerText("Save editable draft")) {
                            Task {
                                guard await model.saveIdea(idea) else { return }
                                originalIdea = idea
                                if reviewedIdea == idea {
                                    savedAsDraft = true
                                    completed = true
                                }
                            }
                        }
                            .foregroundStyle(Theme.action).disabled(!model.editable)
                    } else {
                        Button(dinnerText("Save accepted dinner")) {
                            saveAccepted { feedback in
                                await model.accept(reviewed, id: acceptedID, fallback: fallback, onFirstSave: feedback)
                            }
                        }
                            .buttonStyle(PrimaryAction()).disabled(!model.editable).accessibilityIdentifier("ledgerSaveDinner")
                    }
                    Button(dinnerText("Continue editing"), action: continueEditing)
                        .foregroundStyle(Theme.action).disabled(accepting)
                }
            } else {
                DinnerTemplateFields(draft: $draft, focus: $inputFocus)
                if purpose == .manual {
                    Section(dinnerText("Night")) {
                        Toggle(dinnerText("Assign a date"), isOn: $scheduled)
                        if scheduled { DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date) }
                        Text(model.shop?.basis.timeZoneIdentifier ?? "")
                        Text(dinnerText("Choosing without a date keeps the same dinner and grocery needs when you schedule it later."))
                    }
                }
                if purpose == .reusable {
                    Section {
                        Toggle(dinnerText("Accept as a fallback dinner"), isOn: $fallback)
                        Text(dinnerText("Saving a reusable dinner does not choose it for this pickup."))
                    }
                }
                if purpose == .idea {
                    Section(dinnerText("Review assumptions")) {
                        if originalIdea?.catalogVersion == "reviewed-catalog-v1" {
                            Text(dinnerText("Suggested by Room in the Cart"))
                        }
                        workingTextField(dinnerText("Assumptions, one per line"), text: $assumptions, axis: .vertical)
                            .focused($inputFocus, equals: "assumptions")
                            .accessibilityLabel(dinnerText("Assumptions, one per line"))
                        Toggle(dinnerText("Usable yield reviewed"), isOn: $yieldConfirmed)
                        Toggle(dinnerText("Availability reviewed"), isOn: $availabilityConfirmed)
                        if let originalIdea, !originalIdea.hardExclusions.isEmpty {
                            Text(dinnerFormat("Required exclusions: %@", originalIdea.hardExclusions.joined(separator: ", ")))
                        }
                        Text(dinnerText("Review every ingredient and quantity. Accepted ideas remain separate from chosen dinners."))
                    }
                }
                if !draft.title.isEmpty {
                    NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(initialDish: draft.title) }
                        .foregroundStyle(Theme.action)
                }
                Section { Button(dinnerText("Review"), action: review).buttonStyle(PrimaryAction()).disabled(!model.editable).accessibilityIdentifier("ledgerReviewDinner") }
            }
            if !completed { DinnerFeedback(model: model) }
        }
    }

    private func saveAccepted(_ save: @escaping (@escaping (DinnerFeatureModel.FirstDinnerSave) -> Void) async -> Bool) {
        guard !accepting, let originalIdentity, model.editorIdentity == originalIdentity else { return }
        let attempt = UUID()
        activeAttempt = attempt
        accepting = true
        Task {
            let saved = await save { receipt in
                guard activeAttempt == attempt, presentInEditor, scene == .active,
                      model.milestoneAccess(), originalIdentity == receipt.editor, model.editorIdentity == receipt.editor,
                      acceptedID == receipt.acceptedID else { return }
                firstSaveCue = .init()
            }
            accepting = false
            activeAttempt = nil
            if saved, presentInEditor, model.editorIdentity == originalIdentity { completed = true }
        }
    }

    private func continueEditing() {
        reviewed = nil
        reviewedIdea = nil
    }

    private func review() {
        do {
            let template = try draft.template(validate: purpose != .idea)
            inputFocus = nil
            if purpose == .manual {
                guard let shop = model.shop else { return }
                let day = try DinnerEntry.date(date, zone: shop.basis.timeZoneIdentifier, scheduled: scheduled)
                showPreview = model.prepare([.choose(PlannedDinner(template: template, day: day))])
            } else if purpose == .idea {
                var idea = try originalIdea ?? model.newIdea(seed: 0, exclusions: DinnerEntry.list(draft.exclusions), manual: template)
                idea.preferenceRevision = model.mealPreferences?.revision
                idea.template = template; idea.yieldConfirmed = yieldConfirmed; idea.availabilityConfirmed = availabilityConfirmed
                supplyEvidence = supplyEvidence.filter { row in
                    row.workspaceID == model.localIdeaWorkspaceID && row.shopID == model.shop?.id &&
                    template.ingredients.contains { $0.id == row.id && $0.name == row.ingredientName }
                }
                idea.supplyEvidence = supplyEvidence.isEmpty ? nil : supplyEvidence
                idea.assumptions = DinnerEntry.list(assumptions); reviewedIdea = idea; reviewed = template
                model.clearErrorAfterSuccessfulReview()
            } else {
                reviewed = template
                model.clearErrorAfterSuccessfulReview()
            }
        } catch { model.report(error) }
    }
}
struct DinnerTemplateFields: View {
    @Binding var draft: DinnerTemplateDraft
    let focus: FocusState<String?>.Binding
    @State private var showRecipeDetails = false
    @State private var showPreferences = false

    var body: some View {
        Section(dinnerText("Dinner")) {
            WorkingField(dinnerText("Dinner name")) {
                TextField(dinnerText("Dinner name"), text: $draft.title, prompt: Text(verbatim: "—"))
                    .focused(focus, equals: "title")
                    .submitLabel(.next)
                    .onSubmit { focus.wrappedValue = "servings" }
                    .accessibilityIdentifier("ledgerDinnerTitle")
            }
            WorkingField(dinnerText("Total servings")) {
                TextField(dinnerText("Total servings"), text: $draft.servings, prompt: Text(verbatim: "—"))
                    .focused(focus, equals: "servings")
                    .accessibilityIdentifier("ledgerDinnerServings")
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            DisclosureGroup(isExpanded: $showRecipeDetails) {
                draftField(dinnerText("Notes"), value: $draft.notes, key: "notes")
                draftField(dinnerText("Source URL, optional"), value: $draft.source, key: "source", axis: .horizontal)
                draftField(tonightText("Ingredients to avoid, one per line"), value: $draft.exclusions, key: "exclusions")
                draftField(tonightText("Minutes of prep remaining (optional)"), value: $draft.lead, key: "leadTime", axis: .horizontal)
                    .keyboardType(.numberPad)
                draftField(dinnerText("Completed steps, one per line"), value: $draft.completed, key: "completed")
            } label: { Text(tonightText("Optional recipe details")) }
            .disclosureGroupStyle(LabeledFormDisclosureStyle(label: tonightText("Optional recipe details"), identifier: "dinner.recipeDetails"))
        }
        Section(dinnerText("Ingredients")) {
            Text(dinnerText("Enter exact amounts or leave them unresolved. Count means individual units, not packs."))
            ForEach(draft.ingredients) { ingredient in
                let row = dinnerDraftBinding(ingredient, in: $draft.ingredients)
                let prefix = "ingredient.\(ingredient.id)."
                VStack(alignment: .leading, spacing: 8) {
                    if let source = ingredient.originalWording { Text(verbatim: source).font(.subheadline).foregroundStyle(Theme.secondary) }
                    draftField(dinnerText("Ingredient name"), value: row.name, key: prefix + "name")
                    Toggle(tonightText("Use without a measured amount"), isOn: row.checkedWithoutAmount)
                        .accessibilityLabel(ingredient.name.isEmpty ? tonightText("Use without a measured amount") :
                            ingredient.name + ", " + tonightText("Use without a measured amount"))
                    if !ingredient.checkedWithoutAmount {
                        draftField(dinnerText("Amount, optional"), value: row.amount, key: prefix + "amount", axis: .horizontal)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        DinnerUnitPicker(unit: row.unit)
                    }
                    draftField(dinnerText("Ingredient notes"), value: row.notes, key: prefix + "notes")
                    draftField(dinnerText("Ingredient exclusions, one per line"), value: row.exclusions, key: prefix + "exclusions")
                    Button(role: .destructive) { draft.ingredients.removeAll { $0.id == ingredient.id } } label: {
                        Text(dinnerText("Remove ingredient"))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.error)
                }.padding(.vertical, 6)
            }
            Button(dinnerText("Add ingredient")) { draft.ingredients.append(DinnerIngredientDraft()) }.foregroundStyle(Theme.action).disabled(draft.ingredients.count >= 200)
        }
        Section {
            DisclosureGroup(isExpanded: $showPreferences) {
                MealEvidenceFields(draft: $draft.evidence, focus: focus)
            } label: { Text(tonightText("Ingredients, brands and equipment (optional)")) }
            .disclosureGroupStyle(LabeledFormDisclosureStyle(label: tonightText("Ingredients, brands and equipment (optional)"), identifier: "dinner.mealEvidence"))
        }
        Section(dinnerText("Serving groups")) {
            Text(dinnerText("Name each group explicitly. Protected groups keep their reviewed portions when guests change."))
            ForEach(draft.groups) { group in
                let row = dinnerDraftBinding(group, in: $draft.groups)
                VStack(alignment: .leading, spacing: 8) {
                    WorkingField(dinnerText("Group name")) {
                        TextField(dinnerText("Group name"), text: row.name, prompt: Text(verbatim: "—"))
                            .focused(focus, equals: "group.\(group.id).name")
                    }
                    WorkingField(dinnerText("Group servings")) {
                        TextField(dinnerText("Group servings"), text: row.servings, prompt: Text(verbatim: "—"))
                            .focused(focus, equals: "group.\(group.id).servings")
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle(dinnerText("Protected group"), isOn: row.isProtected)
                    Button(dinnerText("Remove group"), role: .destructive) { draft.groups.removeAll { $0.id == group.id } }
                        .buttonStyle(.borderless).foregroundStyle(Theme.error)
                }.padding(.vertical, 6)
            }
            Button(dinnerText("Add serving group")) { draft.groups.append(DinnerGroupDraft()) }.foregroundStyle(Theme.action).disabled(draft.groups.count >= 100)
        }
    }

    private func draftField(_ title: String, value: Binding<String>, key: String, axis: Axis = .vertical) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Keep the purpose visible when a value replaces the native prompt.
            // The editable field already exposes this same accessible name.
            Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            TextField(title, text: value, prompt: Text(""), axis: axis)
                .fixedSize(horizontal: false, vertical: true)
                .focused(focus, equals: key)
                .accessibilityLabel(title).accessibilityIdentifier(key)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = key })
    }
}
struct DinnerUnitPicker: View {
    @Binding var unit: UnitOfMeasure
    var body: some View {
        Picker(dinnerText("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) } }
    }
}
struct DinnerLibraryView: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.pickupLedger) private var liveLedger
    @EnvironmentObject private var workspaceAccess: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var query = ""
    @State private var pinnedOnly = false
    @State private var sources: [TonightMealModel.Source] = []
    @State private var sourceOwner: String?
    @State private var reviewingSource: TonightMealModel.Source?
    @State private var planning: AcceptedDinner?
    @State private var date = Date()
    private var identity: CapturePrivateIdentity? {
        guard let liveLedger, model.store === liveLedger, model.basketPrepAccess(), model.localIdeaWorkspaceID != nil,
              scene == .active, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: workspaceAccess, household: household)
    }

    private func visible(_ key: CookSoonPin.Recipe) -> Bool {
        guard pinnedOnly else { return true }
        guard let owner = identity?.mealFeedbackOwner else { return false }
        return model.workspace.cookSoonPins.contains(.init(owner: owner, recipe: key))
    }
    @ViewBuilder private func pin(_ key: CookSoonPin.Recipe) -> some View {
        if let liveLedger, let original = identity {
            RecipePinButton(ledger: liveLedger, recipe: key, owner: original.mealFeedbackOwner,
                            authorize: { identity == original })
        }
    }
    private func loadSources() async {
        reviewingSource = nil
        guard let original = identity, let origin = liveLedger?.sourceWorkspaceID else { sources = []; sourceOwner = nil; return }
        let authorized = { identity == original && liveLedger?.sourceWorkspaceID == origin && !Task.isCancelled }
        let current = try? await TonightRecipeLibrary.read(authorize: authorized)
        guard authorized() else { return }
        sources = current ?? []; sourceOwner = original.mealFeedbackOwner
    }

    private var filtering: Bool { pinnedOnly || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var accepted: [AcceptedDinner] {
        model.state.acceptedDinners.filter { $0.template.matchesRecipeSearch(query) && visible(.reviewed($0.template.id)) }
    }
    private var earlier: [MealTemplate] {
        model.workspace.mealTemplates.filter { $0.matchesRecipeSearch(query) && visible(.reviewed($0.id)) }
    }
    private var imported: [TonightMealModel.Source] {
        guard let sourceOwner, sourceOwner == identity?.mealFeedbackOwner else { return [] }
        return sources.filter {
            visible(.imported($0.id)) && PrivateRecipeSearch.matches(query, title: $0.recipe.title, ingredients: $0.recipe.ingredients)
        }
    }
    @ViewBuilder private var libraryTools: some View {
        Section {
            Text(dinnerText("One accepted dinner can be your Free reusable dinner. Changing this selection does not change dinners already chosen."))
            NavigationLink(dinnerText("Save a familiar dinner")) { DinnerTemplateEditor(model: model, purpose: .reusable) }.accessibilityIdentifier("ledgerNewTemplate")
        }
        if let liveLedger, model.store === liveLedger {
            Section { RecordsRecoveryLink(accessibilityID: "dinner.recipeFiles", dinnerModel: model) }
        }
    }

    @State private var showPreview = false
    var body: some View {
        List {
            Group {
                Section {
                    PrivateRecipeSearchField(query: $query)
                    if identity != nil { Toggle(tonightText("Show Cook soon only"), isOn: $pinnedOnly) }
                }
                if !earlier.isEmpty, identity != nil {
                    Section(dinnerText("Saved recipes")) {
                        ForEach(earlier) { template in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: template.title).font(.system(.title2, design: .serif, weight: .semibold))
                                DinnerServingNote(template: template)
                                SavedDinnerHandoffLink(recipe: template)
                                    .disabled(!model.paid && template.id != model.workspace.mealTemplates.first?.id)
                            }
                            pin(.reviewed(template.id))
                        }
                    }
                }
                if !filtering { libraryTools }
                if filtering, accepted.isEmpty, earlier.isEmpty, imported.isEmpty,
                   identity == nil || sourceOwner == identity?.mealFeedbackOwner {
                    Text(tonightText("No matching recipes")).accessibilityIdentifier("dinner.recipeNoMatch")
                }
                if !accepted.isEmpty || (!filtering && earlier.isEmpty) {
                    Section(dinnerText("Accepted dinners")) {
                        if model.state.acceptedDinners.isEmpty { Text(dinnerText("No accepted dinners yet.")) }
                        ForEach(accepted) { dinner in
                            let isFreeReusable = model.state.freeReusableDinnerID == dinner.id
                            VStack(alignment: .leading, spacing: 8) {
                                Text(dinner.template.title).font(.system(.title2, design: .serif, weight: .semibold))
                                DinnerServingNote(template: dinner.template)
                                if dinner.acceptedFallback { Text(dinnerText("Accepted fallback")) }
                                if isFreeReusable {
                                    Label(dinnerText("Your Free reusable dinner"), systemImage: "checkmark.circle.fill")
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onSelection)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(Theme.selection, in: RoundedRectangle(cornerRadius: 9))
                                }
                            }.padding(.vertical, 6)
                            pin(.reviewed(dinner.template.id))
                            if let evidence = dinner.template.sourceEvidence {
                                NavigationLink(captureText("Original recipe source")) {
                                    RecipeSourceReview(model: model, templateID: dinner.template.id, evidence: evidence)
                                }
                            }
                            if !isFreeReusable {
                                Button(dinnerText("Use as Free reusable dinner")) { Task { _ = await model.selectFree(dinner.id) } }
                            }
                            if identity != nil {
                                SavedDinnerHandoffLink(recipe: dinner.template)
                                    .disabled(!model.paid && !isFreeReusable)
                            }
                            Button(dinnerText("Choose for this pickup")) { showPreview = model.choose(dinner, day: nil) }
                                .disabled(!model.paid && !isFreeReusable).accessibilityIdentifier("ledgerChooseTemplate")
                            if planning?.id == dinner.id, let zone = model.shop?.basis.timeZoneIdentifier {
                                DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date)
                                    .environment(\.timeZone, TimeZone(identifier: zone) ?? .current)
                                Button(tonightText("Preview dinner choice")) {
                                    do {
                                        let day = try MealDay(date: date, timeZoneIdentifier: zone)
                                        showPreview = model.choose(dinner, day: day)
                                    } catch { model.report(error) }
                                }
                            } else {
                                Button(tonightText("Plan for a day")) { planning = dinner; date = Date() }
                                    .disabled(!model.paid && !isFreeReusable)
                            }
                            NavigationLink(dinnerText("Review as a new dinner version")) {
                                DinnerTemplateEditor(model: model, purpose: .reusable, initial: dinner.template)
                            }
                        }
                    }
                }
                if !earlier.isEmpty {
                    Section(dinnerText("More recipe options")) {
                        Text(dinnerText("Review a saved recipe to create another dinner version."))
                        ForEach(earlier) { template in
                            NavigationLink(template.title) { DinnerTemplateEditor(model: model, purpose: .reusable, initial: template) }
                            pin(.reviewed(template.id))
                            NavigationLink(tonightText("Plan for a day")) {
                                DinnerTemplateEditor(model: model, purpose: .manual, initial: template, planForDay: true)
                            }
                        }
                    }
                }
                if !imported.isEmpty {
                    Section(tonightText("Saved sources to review")) {
                        ForEach(imported) { source in
                            Button { reviewingSource = source } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: source.recipe.title)
                                    Text(tonightText("Saved source — review servings and ingredient amounts")).font(.footnote)
                                }
                            }
                            pin(.imported(source.id))
                        }
                    }
                }
                if filtering { libraryTools }
                DinnerFeedback(model: model)
            }.listRowBackground(Theme.surface)
        }.workingSurface().navigationTitle(dinnerText("Dinner library")).dinnerAccess(model).disabled(!model.editable)
            .task(id: identity?.mealFeedbackOwner) {
                query = ""; pinnedOnly = false; planning = nil
                await loadSources()
            }
            .sheet(item: $reviewingSource) { source in
                if let liveLedger, let original = identity, original.mealFeedbackOwner == sourceOwner {
                    NavigationStack {
                        TonightRecipeReview(ledger: liveLedger, source: source, currentIdentity: { identity == original ? original : nil })
                    }
                }
            }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
private struct DinnerServingNote: View {
    let template: MealTemplate
    @State private var expanded = false
    @State private var reveal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dinnerFormat("Servings: %@", template.servings.description)).monospacedDigit()
            if !template.servingGroups.isEmpty {
                Button {
                    reveal = false
                    expanded.toggle()
                } label: {
                    Label(dinnerText("Serving details"), systemImage: expanded ? "chevron.down" : "chevron.forward")
                        .frame(minHeight: 44)
                }.buttonStyle(.borderless)
                    .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
                if expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(template.servingGroups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dinnerFormat("%@ · %@ servings", group.name, group.servings.description))
                                if group.isProtected { Text(dinnerText("Protected group")).foregroundStyle(Theme.secondary) }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    .opacity(reduceMotion || reveal ? 1 : 0.8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: reveal)
                    .onAppear { reveal = true }
                }
            }
        }
    }
}

struct DinnerIdeasView: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var patternIndex = 0
    @State private var exclusions = ""
    @State private var generated: DinnerIdeaDraft?
    var body: some View {
        List {
            Group {
                Section {
                    Text(dinnerText("Start with a manual idea or a supplied pattern. Review and accept it before choosing it for your pickup."))
                    NavigationLink(dinnerText("Write a dinner idea")) { DinnerTemplateEditor(model: model, purpose: .idea) }
                }
                if !model.ideaCatalog.isEmpty {
                    Section(dinnerText("Room in the Cart meal patterns")) {
                        let patterns = model.ideaPatterns
                        Picker(dinnerText("Starting meal"), selection: $patternIndex) {
                            ForEach(Array(patterns.enumerated()), id: \.element.id) { index, pattern in
                                Text(pattern.title).tag(index)
                            }
                        }
                        workingTextField(dinnerText("Hard exclusions, one per line"), text: $exclusions, axis: .vertical)
                        Button(dinnerText("Prepare editable idea")) {
                            do {
                                generated = try model.newIdea(seed: UInt64(patternIndex), exclusions: DinnerEntry.list(exclusions))
                            } catch { model.report(error) }
                        }
                        .disabled(!patterns.indices.contains(patternIndex))
                        if patterns.indices.contains(patternIndex) {
                            MealPreferenceIssues(result: MealEligibilityPolicy.evaluate(profile: model.mealPreferences, template: patterns[patternIndex]))
                        } else { Text(dinnerText("No meal patterns match the current constraints.")) }
                        if let generated {
                            Text(generated.template.title)
                            NavigationLink(dinnerText("Review prepared idea")) { DinnerTemplateEditor(model: model, purpose: .idea, idea: generated) }
                        }
                    }
                }
                Section(dinnerText("Saved idea drafts")) {
                    if model.state.ideas.isEmpty { Text(dinnerText("No saved idea drafts.")) }
                    ForEach(model.state.ideas) { idea in
                        NavigationLink(idea.template.title) { DinnerTemplateEditor(model: model, purpose: .idea, idea: idea) }
                    }
                }
                DinnerFeedback(model: model)
            }.listRowBackground(Theme.surface)
        }.workingSurface().navigationTitle(dinnerText("Dinner ideas"))
            .onChange(of: patternIndex) { _,_ in generated = nil }
            .onChange(of: exclusions) { _,_ in generated = nil }
            .dinnerAccess(model).disabled(!model.editable)
    }
}

/// A form sibling gives Done its own rectangular target, clear of navigation and keyboard chrome.
struct DinnerFocusedDoneBar: View {
    var identifier = "dinnerFocusedKeyboardDone"
    let dismissKeyboard: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: dismissKeyboard) {
                Text(dinnerText("Done"))
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.action)
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.canvas, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dinnerFocusedKeyboardDoneBar")
    }
}

/// Each cue starts at the originating user or commit event. Recreating its view
/// later can only show the remaining interval, never restart a completed event.
struct BrandCartMotion: View {
    struct Cue: Equatable {
        let id = UUID()
        let began = ContinuousClock.now
    }
    enum Kind { case firstDinner, aboutReplay }
    let cue: Cue?
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @State private var cancelled: UUID?

    var body: some View {
        Group {
            if let cue, !reduceMotion, scene == .active, cancelled != cue.id {
                TimelineView(.animation) { _ in
                    let pose = pose(at: elapsed(since: cue))
                    BrandCartMark(pearOffset: pose.offset, pearAngle: pose.angle)
                }
                .task(id: cue.id) {
                    try? await ContinuousClock().sleep(until: cue.began.advanced(by: .milliseconds(duration)))
                    if !Task.isCancelled { cancelled = cue.id }
                }
            } else { BrandCartMark() }
        }
        .onChange(of: cue, initial: true) { _, incoming in
            if scene != .active || reduceMotion { cancelled = incoming?.id }
        }
        .onDisappear { cancelled = cue?.id }
        .onChange(of: scene) { _, phase in if phase != .active { cancelled = cue?.id } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { cancelled = cue?.id } }
        .accessibilityHidden(true)
    }

    private var duration: Int { kind == .firstDinner ? 120 : 480 }

    private func elapsed(since cue: Cue) -> Double {
        let delta = cue.began.duration(to: .now).components
        return Double(delta.seconds) * 1_000 + Double(delta.attoseconds) / 1e15
    }

    private func pose(at milliseconds: Double) -> (offset: CGSize, angle: Double) {
        let tip: Double = kind == .firstDinner ? 35 : 125
        let tuck: Double = kind == .firstDinner ? 80 : 300
        func progress(_ start: Double, _ end: Double) -> Double {
            let x = min(1, max(0, (milliseconds - start) / (end - start)))
            return x * x * (3 - 2 * x)
        }
        if milliseconds < tip {
            return (CGSize(width: 2, height: -3), 5 * progress(0, tip))
        }
        if milliseconds < tuck {
            let p = progress(tip, tuck)
            return (CGSize(width: 2 - 2 * p, height: -3 + 2 * p), 5 - 3 * p)
        }
        let p = progress(tuck, Double(duration))
        return (CGSize(width: 0, height: -1 + p), 2 - 2 * p)
    }
}
