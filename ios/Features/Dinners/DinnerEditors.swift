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

enum DinnerEditorPurpose { case manual, reusable, idea }
struct DinnerTemplateEditor: View {
    @ObservedObject var model: DinnerFeatureModel
    let purpose: DinnerEditorPurpose
    let originalIdea: DinnerIdeaDraft?
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
    @FocusState private var inputFocus: String?
    @Environment(\.dismiss) private var dismiss
    init(model: DinnerFeatureModel, purpose: DinnerEditorPurpose, initial: MealTemplate? = nil, idea: DinnerIdeaDraft? = nil) {
        self.model = model; self.purpose = purpose; originalIdea = idea
        _originalIdentity = State(initialValue: model.editorIdentity)
        _supplyEvidence = State(initialValue: idea?.supplyEvidence ?? [])
        _draft = State(initialValue: DinnerTemplateDraft(idea?.template ?? initial))
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
        Form {
            if completed {
                Section {
                    Text(dinnerText("Dinner saved. Choose it separately to add grocery needs."))
                    Button(dinnerText("Done")) { dismiss() }
                }
            } else if let reviewed {
                Section(dinnerText("Review dinner")) {
                    Text(reviewed.title).font(.headline)
                    Text(dinnerFormat("Servings: %@", reviewed.servings.description))
                    ForEach(reviewed.ingredients) { ingredient in
                        VStack(alignment: .leading) { Text(ingredient.name); Text(dinnerQuantity(ingredient.quantity)) }
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
                        Button(dinnerText("Accept idea")) { Task { completed = await model.acceptIdea(idea, acceptedID: acceptedID) } }
                            .disabled(!review.canAccept || !model.editable).accessibilityIdentifier("dinnerAcceptIdea")
                        Button(dinnerText("Save editable draft")) { Task { completed = await model.saveIdea(idea) } }.disabled(!model.editable)
                    } else {
                        Button(dinnerText("Save accepted dinner")) { Task { completed = await model.accept(reviewed, id: acceptedID, fallback: fallback) } }
                            .disabled(!model.editable).accessibilityIdentifier("ledgerSaveDinner")
                    }
                    Button(dinnerText("Continue editing")) { self.reviewed = nil; reviewedIdea = nil }
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
                        TextField(dinnerText("Assumptions, one per line"), text: $assumptions, axis: .vertical)
                            .focused($inputFocus, equals: "assumptions")
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
                }
                Section { Button(dinnerText("Review"), action: review).disabled(!model.editable).accessibilityIdentifier("ledgerReviewDinner") }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(purpose == .manual ? dinnerText("Manual dinner") : purpose == .idea ? dinnerText("Dinner idea") : dinnerText("Reusable dinner")).dinnerAccess(model)
            .keyboardDoneAction(visible: inputFocus != nil, title: dinnerText("Done")) { inputFocus = nil }
            .dinnerApplyPresentation(model, presented: $showPreview)
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
                idea.template = template; idea.yieldConfirmed = yieldConfirmed; idea.availabilityConfirmed = availabilityConfirmed
                supplyEvidence = supplyEvidence.filter { row in
                    row.workspaceID == model.localIdeaWorkspaceID && row.shopID == model.shop?.id &&
                    template.ingredients.contains { $0.id == row.id && $0.name == row.ingredientName }
                }
                idea.supplyEvidence = supplyEvidence.isEmpty ? nil : supplyEvidence
                idea.assumptions = DinnerEntry.list(assumptions); reviewedIdea = idea; reviewed = template
            } else { reviewed = template }
        } catch { model.report(error) }
    }
}
struct DinnerTemplateFields: View {
    @Binding var draft: DinnerTemplateDraft
    let focus: FocusState<String?>.Binding
    var body: some View {
        Section(dinnerText("Dinner")) {
            TextField(dinnerText("Dinner name"), text: $draft.title).focused(focus, equals: "title").accessibilityIdentifier("ledgerDinnerTitle")
            TextField(dinnerText("Total servings"), text: $draft.servings).focused(focus, equals: "servings").accessibilityIdentifier("ledgerDinnerServings")
            TextField(dinnerText("Notes"), text: $draft.notes, axis: .vertical).focused(focus, equals: "notes")
            TextField(dinnerText("Source URL, optional"), text: $draft.source).focused(focus, equals: "source")
            TextField(dinnerText("Hard exclusions, one per line"), text: $draft.exclusions, axis: .vertical).focused(focus, equals: "exclusions")
            TextField(dinnerText("Remaining lead time in minutes, optional"), text: $draft.lead).focused(focus, equals: "leadTime")
            TextField(dinnerText("Completed steps, one per line"), text: $draft.completed, axis: .vertical).focused(focus, equals: "completed")
        }
        Section(dinnerText("Ingredients")) {
            Text(dinnerText("Enter exact amounts or leave them unresolved. Count means individual units, not packs."))
            ForEach(draft.ingredients) { ingredient in
                let row = dinnerDraftBinding(ingredient, in: $draft.ingredients)
                let prefix = "ingredient.\(ingredient.id)."
                VStack(alignment: .leading, spacing: 8) {
                    TextField(dinnerText("Ingredient name"), text: row.name).focused(focus, equals: prefix + "name")
                    TextField(dinnerText("Amount, optional"), text: row.amount).focused(focus, equals: prefix + "amount")
                    DinnerUnitPicker(unit: row.unit)
                    TextField(dinnerText("Ingredient notes"), text: row.notes, axis: .vertical).focused(focus, equals: prefix + "notes")
                    TextField(dinnerText("Ingredient exclusions, one per line"), text: row.exclusions, axis: .vertical)
                        .focused(focus, equals: prefix + "exclusions")
                        .accessibilityLabel(dinnerText("Ingredient exclusions, one per line"))
                    Button(dinnerText("Remove ingredient"), role: .destructive) { draft.ingredients.removeAll { $0.id == ingredient.id } }
                        .buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
            Button(dinnerText("Add ingredient")) { draft.ingredients.append(DinnerIngredientDraft()) }.disabled(draft.ingredients.count >= 200)
        }
        Section(dinnerText("Serving groups")) {
            Text(dinnerText("Name each group explicitly. Protected groups keep their reviewed portions when guests change."))
            ForEach(draft.groups) { group in
                let row = dinnerDraftBinding(group, in: $draft.groups)
                VStack(alignment: .leading, spacing: 8) {
                    TextField(dinnerText("Group name"), text: row.name).focused(focus, equals: "group.\(group.id).name")
                    TextField(dinnerText("Group servings"), text: row.servings).focused(focus, equals: "group.\(group.id).servings")
                    Toggle(dinnerText("Protected group"), isOn: row.isProtected)
                    Button(dinnerText("Remove group"), role: .destructive) { draft.groups.removeAll { $0.id == group.id } }
                        .buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
            Button(dinnerText("Add serving group")) { draft.groups.append(DinnerGroupDraft()) }.disabled(draft.groups.count >= 100)
        }
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
    @State private var showPreview = false
    var body: some View {
        List {
            Section {
                Text(dinnerText("One accepted dinner can be your Free reusable dinner. Changing this selection does not change dinners already chosen."))
                NavigationLink(dinnerText("Save a familiar dinner")) { DinnerTemplateEditor(model: model, purpose: .reusable) }.accessibilityIdentifier("ledgerNewTemplate")
            }
            Section(dinnerText("Accepted dinners")) {
                if model.state.acceptedDinners.isEmpty { Text(dinnerText("No accepted dinners yet.")) }
                ForEach(model.state.acceptedDinners) { dinner in
                    let isFreeReusable = model.state.freeReusableDinnerID == dinner.id
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dinner.template.title).font(.headline)
                        Text(dinnerFormat("Servings: %@", dinner.template.servings.description))
                        if dinner.acceptedFallback { Text(dinnerText("Accepted fallback")) }
                        if isFreeReusable { Text(dinnerText("Your Free reusable dinner")) }
                    }.padding(.vertical, 6)
                    if let evidence = dinner.template.sourceEvidence {
                        NavigationLink(captureText("Original recipe source")) {
                            RecipeSourceReview(model: model, templateID: dinner.template.id, evidence: evidence)
                        }
                    }
                    if !isFreeReusable {
                        Button(dinnerText("Use as Free reusable dinner")) { Task { _ = await model.selectFree(dinner.id) } }
                    }
                    Button(dinnerText("Choose for this pickup")) { showPreview = model.choose(dinner, day: nil) }
                        .disabled(!model.paid && !isFreeReusable).accessibilityIdentifier("ledgerChooseTemplate")
                    NavigationLink(dinnerText("Review as a new dinner version")) {
                        DinnerTemplateEditor(model: model, purpose: .reusable, initial: dinner.template)
                    }
                }
            }
            if !model.workspace.mealTemplates.isEmpty {
                Section(dinnerText("Earlier reusable dinners")) {
                    Text(dinnerText("Review an earlier template before adding it to the accepted library."))
                    ForEach(model.workspace.mealTemplates) { template in
                        NavigationLink(template.title) { DinnerTemplateEditor(model: model, purpose: .reusable, initial: template) }
                    }
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Dinner library")).dinnerAccess(model).disabled(!model.editable)
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
struct DinnerIdeasView: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var patternIndex = 0
    @State private var exclusions = ""
    @State private var generated: DinnerIdeaDraft?
    var body: some View {
        List {
            Section {
                Text(dinnerText("Start with a manual idea or a supplied pattern. Review and accept it before choosing it for your pickup."))
                NavigationLink(dinnerText("Write a dinner idea")) { DinnerTemplateEditor(model: model, purpose: .idea) }
            }
            if !model.ideaCatalog.isEmpty {
                Section(dinnerText("Room in the Cart meal patterns")) {
                    let patterns = model.ideaCatalog.sorted { $0.id.uuidString < $1.id.uuidString }
                    Picker(dinnerText("Starting meal"), selection: $patternIndex) {
                        ForEach(Array(patterns.enumerated()), id: \.element.id) { index, pattern in
                            Text(pattern.title).tag(index)
                        }
                    }
                    TextField(dinnerText("Hard exclusions, one per line"), text: $exclusions, axis: .vertical)
                    Button(dinnerText("Prepare editable idea")) {
                        do {
                            generated = try model.newIdea(seed: UInt64(patternIndex), exclusions: DinnerEntry.list(exclusions))
                        } catch { model.report(error) }
                    }
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
        }.navigationTitle(dinnerText("Dinner ideas"))
            .onChange(of: patternIndex) { _,_ in generated = nil }
            .onChange(of: exclusions) { _,_ in generated = nil }
            .dinnerAccess(model).disabled(!model.editable)
    }
}
