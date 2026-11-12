import SwiftUI
import CoreDomain

private enum MealsSheet: Identifiable {
    case newShop, manual, newTemplate, editTemplate(UUID)
    var id: String {
        switch self {
        case .newShop: return "shop"
        case .manual: return "manual"
        case .newTemplate: return "template"
        case .editTemplate(let id): return "template-\(id)"
        }
    }
}

struct LedgerMealsView: View {
    @ObservedObject var model: LedgerModel
    @State private var sheet: MealsSheet?
    @State private var showHidden = false
    private var occurrences: [MealOccurrence] {
        (model.shop?.mealOccurrences ?? []).filter { $0.removedAt == nil && (showHidden || !$0.isHidden) }
    }
    var body: some View {
        List {
            Section {
                Text(ledgerText("Choose dinner now. Pick a night when you're ready."))
                    .font(.title2.bold())
                if let shop = model.shop {
                    Text(ledgerFormat("For pickup: %@", shop.title)).foregroundStyle(Theme.secondary)
                    Button(ledgerText("Add a dinner for this pickup")) { sheet = .manual }
                        .buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerAddDinner")
                } else {
                    Text(ledgerText("Start a pickup to choose dinners and keep their grocery needs together."))
                    Button(ledgerText("Start pickup")) { sheet = .newShop }.buttonStyle(PrimaryAction())
                }
            }.disabled(!model.ready || model.saving || model.hasPendingSave)
            Section(ledgerText("Your reusable dinner")) {
                if let template = model.workspace.mealTemplates.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(template.title).font(.headline)
                        Text(ledgerFormat("Servings: %@", amountText(template.servings)))
                        if !template.notes.isEmpty { Text(template.notes) }
                        Button(ledgerText("Choose for this pickup")) { choose(template) }
                            .disabled(model.shop == nil || model.saving || model.hasPendingSave)
                            .accessibilityIdentifier("ledgerChooseTemplate")
                        Button(ledgerText("Edit usual dinner")) { sheet = .editTemplate(template.id) }
                            .disabled(model.saving || model.hasPendingSave)
                    }.padding(.vertical, 5)
                } else {
                    Text(ledgerText("Save one familiar dinner to use again. Each chosen dinner is a separate copy."))
                    Button(ledgerText("Save a familiar dinner")) { sheet = .newTemplate }
                        .disabled(!model.ready || model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerNewTemplate")
                }
            }
            if let shop = model.shop {
                Section(ledgerText("Unscheduled")) {
                    let undated = occurrences.filter { $0.scheduledDay == nil }
                    if undated.isEmpty { Text(ledgerText("Chosen dinners without a date appear here.")) }
                    ForEach(undated) { meal in mealLink(meal, shopID: shop.id) }
                }
                let days = Array(Set(occurrences.compactMap(\.scheduledDay))).sorted { $0.iso8601 < $1.iso8601 }
                ForEach(days, id: \.self) { day in
                    Section(ledgerMealDay(day)) {
                        ForEach(occurrences.filter { $0.scheduledDay == day }) { meal in mealLink(meal, shopID: shop.id) }
                    }
                }
                Section { Toggle(ledgerText("Show hidden dinners"), isOn: $showHidden) }
            }
            Section { LedgerSaveStatus(model: model) }
        }.listStyle(.insetGrouped).workingSurface()
            .task { await model.open() }
            .sheet(item: $sheet) { destination in
                NavigationStack {
                    switch destination {
                    case .newShop: LedgerNewShopView(model: model)
                    case .manual: LedgerMealEditor(model: model, template: nil, chooseNow: true)
                    case .newTemplate: LedgerMealEditor(model: model, template: nil, chooseNow: false)
                    case .editTemplate(let id):
                        if let template = model.workspace.mealTemplates.first(where: { $0.id == id }) {
                            LedgerMealEditor(model: model, template: template, chooseNow: false)
                        }
                    }
                }
            }
    }
    private func mealLink(_ meal: MealOccurrence, shopID: UUID) -> some View {
        NavigationLink {
            LedgerOccurrenceView(model: model, shopID: shopID, occurrenceID: meal.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(meal.title).font(.headline)
                Text(ledgerFormat("Servings: %@", amountText(meal.servings)))
                if meal.isHidden { Text(ledgerText("Hidden from the ordinary view")) }
                if !meal.notes.isEmpty { Text(meal.notes) }
            }.padding(.vertical, 4).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("ledgerMeal-\(meal.id)")
    }
    private func choose(_ template: MealTemplate) {
        guard let shop = model.shop else { return }
        Task { _ = await model.editShop(key: "choose-\(template.id)", shopID: shop.id) { _ = try $0.chooseMeal(template) } }
    }
}

private struct IngredientDraft: Identifiable {
    var id = UUID()
    var name = ""
    var amount = ""
    var unit: UnitOfMeasure = .count
    var notes = ""
    var exclusions = ""
    init() {}
    init(_ ingredient: MealIngredient) {
        id = ingredient.id; name = ingredient.name; amount = ingredient.quantity.map { ledgerAmountInput($0.amount) } ?? ""
        unit = ingredient.quantity?.unit ?? .count; notes = ingredient.notes
        exclusions = ingredient.exclusions.joined(separator: ", ")
    }
}

private struct PortionDraft: Identifiable {
    var id = UUID()
    var name = ""
    var amount = ""
    var protected = false
    init() {}
    init(_ value: ServingGroup) {
        id = value.id; name = value.name; amount = ledgerAmountInput(value.servings); protected = value.isProtected
    }
}

struct LedgerMealEditor: View {
    @ObservedObject var model: LedgerModel
    @State private var context: LedgerMealEditContext
    private var chooseNow: Bool { context.chooseNow }
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var servings: String
    @State private var notes: String
    @State private var source: String
    @State private var exclusions: String
    @State private var leadTime: String
    @State private var completed: String
    @State private var ingredients: [IngredientDraft]
    @State private var portions: [PortionDraft]
    @State private var validation: String?
    @State private var reviewToSave: LedgerMealSaveReview?
    @FocusState private var inputFocus: String?
    init(model: LedgerModel, template: MealTemplate?, chooseNow: Bool, servingsUnknown: Bool = false) {
        self.model = model
        _context = State(initialValue: model.mealEditContext(template: template, chooseNow: chooseNow))
        _title = State(initialValue: template?.title ?? "")
        _servings = State(initialValue: servingsUnknown ? "" : template.map { ledgerAmountInput($0.servings) } ?? "")
        _notes = State(initialValue: template?.notes ?? "")
        _source = State(initialValue: template?.sourceURL ?? "")
        _exclusions = State(initialValue: template?.exclusions.joined(separator: ", ") ?? "")
        _leadTime = State(initialValue: template?.leadTimeMinutes.map(String.init) ?? "")
        _completed = State(initialValue: template?.completedSteps.joined(separator: "\n") ?? "")
        _ingredients = State(initialValue: template?.ingredients.map(IngredientDraft.init) ?? [IngredientDraft()])
        _portions = State(initialValue: template?.servingGroups.map(PortionDraft.init) ?? [])
    }
    var body: some View {
        Form {
            if let reviewToSave {
                let reviewed = reviewToSave.candidate
                Section(ledgerText("Review dinner")) {
                    Text(reviewed.title).font(.headline)
                    Text(ledgerFormat("Servings: %@", amountText(reviewed.servings)))
                    ForEach(reviewed.ingredients) { ingredient in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ingredient.name)
                            Text(ledgerQuantity(ingredient.quantity))
                        }
                    }
                    Text(ledgerText(chooseNow ? "Choosing creates one undated dinner and its grocery needs. You can link them within existing list quantities afterward." : "Saving a usual dinner does not add groceries. Choosing it for a pickup creates a separate copy."))
                    Button(ledgerText(chooseNow ? "Choose for this pickup" : "Save usual dinner")) {
                        Task { if await model.saveReviewedMeal(reviewToSave) { dismiss() } }
                    }
                        .buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerSaveDinner")
                    Button(ledgerText("Keep editing")) { self.reviewToSave = nil }.disabled(model.saving || model.hasPendingSave)
                }
            } else {
                Section(ledgerText("Dinner")) {
                    TextField(ledgerText("Dinner title"), text: $title, axis: .vertical).focused($inputFocus, equals: "title")
                        .accessibilityIdentifier("ledgerDinnerTitle")
                    TextField(ledgerText("Servings"), text: $servings).keyboardType(.numbersAndPunctuation).focused($inputFocus, equals: "servings")
                        .accessibilityIdentifier("ledgerDinnerServings")
                    TextField(ledgerText("Source URL, optional"), text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($inputFocus, equals: "source")
                    TextField(ledgerText("Dinner notes"), text: $notes, axis: .vertical).focused($inputFocus, equals: "notes")
                    TextField(ledgerText("Hard exclusions, separated by commas"), text: $exclusions, axis: .vertical).focused($inputFocus, equals: "exclusions")
                }.disabled(model.saving || model.hasPendingSave)
                Section(ledgerText("Ingredients")) {
                    ForEach(ingredients) { ingredient in
                        let fields = dinnerDraftBinding(ingredient, in: $ingredients)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(ledgerText("Ingredient name"), text: fields.name, axis: .vertical)
                                .focused($inputFocus, equals: "ingredient.\(ingredient.id).name")
                            LedgerQuantityFields(amount: fields.amount, unit: fields.unit,
                                                 amountFocus: ($inputFocus, "ingredient.\(ingredient.id).amount"))
                            TextField(ledgerText("Ingredient notes"), text: fields.notes, axis: .vertical)
                                .focused($inputFocus, equals: "ingredient.\(ingredient.id).notes")
                            TextField(ledgerText("Ingredient exclusions, separated by commas"), text: fields.exclusions, axis: .vertical)
                                .focused($inputFocus, equals: "ingredient.\(ingredient.id).exclusions")
                            Button(ledgerText("Remove ingredient"), role: .destructive) { ingredients.removeAll { $0.id == ingredient.id } }
                        }.padding(.vertical, 6)
                    }
                    Button(ledgerText("Add ingredient")) { ingredients.append(IngredientDraft()) }
                }.disabled(model.saving || model.hasPendingSave)
                Section(ledgerText("Named portions")) {
                    ForEach(portions) { portion in
                        let fields = dinnerDraftBinding(portion, in: $portions)
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(ledgerText("Who or what this is for"), text: fields.name, axis: .vertical)
                                .focused($inputFocus, equals: "portion.\(portion.id).name")
                            TextField(ledgerText("Portions"), text: fields.amount).keyboardType(.numbersAndPunctuation)
                                .focused($inputFocus, equals: "portion.\(portion.id).amount")
                            Toggle(ledgerText("Protect these portions"), isOn: fields.protected)
                            Button(ledgerText("Remove named portion"), role: .destructive) { portions.removeAll { $0.id == portion.id } }
                        }
                    }
                    Button(ledgerText("Add named portion")) { portions.append(PortionDraft()) }
                }.disabled(model.saving || model.hasPendingSave)
                Section(ledgerText("Optional preparation details")) {
                    TextField(ledgerText("Known elapsed lead time, minutes"), text: $leadTime).keyboardType(.numberPad)
                        .focused($inputFocus, equals: "leadTime")
                    TextField(ledgerText("Already completed steps, one per line"), text: $completed, axis: .vertical)
                        .focused($inputFocus, equals: "completed")
                }.disabled(model.saving || model.hasPendingSave)
                Button(ledgerText("Review dinner")) { review() }.buttonStyle(PrimaryAction())
                    .disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("ledgerReviewDinner")
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText(chooseNow ? "Dinner for this pickup" : "Usual dinner"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) }
            }.interactiveDismissDisabled(model.saving)
            .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done"), identifier: "ledgerMealKeyboardDone") { inputFocus = nil }
    }
    private func separated(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func review() {
        do {
            guard let count = try LedgerEntry.rational(servings), count > .zero else {
                validation = ledgerText("Enter a title, positive servings, and valid ingredient amounts."); return
            }
            let enteredIngredients = ingredients.filter { !$0.name.isEmpty || !$0.amount.isEmpty || !$0.notes.isEmpty || !$0.exclusions.isEmpty }
            let needs = try enteredIngredients.map { draft in
                MealIngredient(id: draft.id, name: draft.name, quantity: try LedgerEntry.quantity(draft.amount, draft.unit), notes: draft.notes, exclusions: separated(draft.exclusions))
            }
            let groups = try portions.map { portion -> ServingGroup in
                guard let number = try LedgerEntry.rational(portion.amount), number > .zero else { throw EntryError.invalidNumber }
                return ServingGroup(id: portion.id, name: portion.name, servings: number, isProtected: portion.protected)
            }
            let minutes = leadTime.isEmpty ? nil : Int(leadTime)
            if !leadTime.isEmpty && minutes == nil { throw EntryError.invalidNumber }
            let template = context.template
            let candidate = MealTemplate(id: template?.id ?? UUID(), title: title, servings: count, ingredients: needs, notes: notes,
                                         sourceURL: source.isEmpty ? nil : source, exclusions: separated(exclusions),
                                         revision: (template?.revision ?? -1) + 1, servingGroups: groups, leadTimeMinutes: minutes,
                                         completedSteps: completed.split(separator: "\n").map(String.init))
            try candidate.validate()
            reviewToSave = LedgerMealSaveReview(context: context, candidate: candidate)
            validation = nil
            inputFocus = nil
        } catch { validation = ledgerText("Enter a title, positive servings, and valid ingredient amounts. Check that ingredients respect your exclusions.") }
    }
}

private struct LedgerOccurrenceView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let occurrenceID: UUID
    @State private var editingDate = false
    @State private var editingDetails = false
    @State private var confirmRemoval = false
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }
    private var meal: MealOccurrence? { shop?.mealOccurrences.first { $0.id == occurrenceID } }
    var body: some View {
        List {
            if let shop, let meal {
                Section {
                    Text(meal.title).font(.title2.bold())
                    Text(ledgerFormat("Servings: %@", amountText(meal.servings)))
                    Text(meal.scheduledDay.map(ledgerMealDay) ?? ledgerText("Unscheduled"))
                    if !meal.notes.isEmpty { Text(meal.notes) }
                    if let source = meal.sourceURL { Text(source).textSelection(.enabled) }
                    if !meal.exclusions.isEmpty { Text(ledgerFormat("Exclusions: %@", meal.exclusions.joined(separator: ", "))) }
                    Button(ledgerText("Assign or change the date")) { editingDate = true }.accessibilityIdentifier("ledgerScheduleMeal")
                    Button(ledgerText("Edit this pickup's dinner")) { editingDetails = true }
                }.disabled(model.saving || model.hasPendingSave || meal.removedAt != nil)
                Section(ledgerText("This dinner's grocery needs")) {
                    ForEach(shop.contributions.filter { meal.ingredientContributionIDs.contains($0.id) && $0.removedAt == nil }, id: \.id) { contribution in
                        NavigationLink {
                            LedgerIngredientView(model: model, shopID: shopID, lineID: contribution.lineID)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(contribution.productName)
                                Text(ledgerQuantity(contribution.quantity))
                                if !contribution.notes.isEmpty { Text(ledgerContributionNote(contribution.notes)) }
                            }
                        }
                    }
                }
                Section(ledgerText("Named portions")) {
                    ForEach(meal.servingGroups) { group in
                        Text("\(group.name) · \(amountText(group.servings))\(group.isProtected ? " · " + ledgerText("Protected") : "")")
                    }
                }
                Section {
                    Text(ledgerText("Edits here affect this pickup's copy. Your usual dinner stays unchanged."))
                    Button(ledgerText(meal.isHidden ? "Show dinner" : "Hide dinner from this view")) {
                        Task { _ = await model.editShop(key: "hide-\(meal.id)", shopID: shopID) { try $0.setMealHidden(occurrenceID: meal.id, hidden: !meal.isHidden) } }
                    }
                    Text(ledgerText("Hiding a dinner keeps all its grocery needs and protected portions."))
                    Button(ledgerText("Remove dinner from this pickup"), role: .destructive) { confirmRemoval = true }
                }.disabled(model.saving || model.hasPendingSave || meal.removedAt != nil)
                if meal.removedAt != nil { Text(ledgerText("This dinner was removed. Other dinners and protected needs remain saved.")) }
            }
            LedgerSaveStatus(model: model)
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Dinner details"))
            .sheet(isPresented: $editingDate) {
                if let shop, let meal { NavigationStack { LedgerMealDateView(model: model, shop: shop, meal: meal) } }
            }
            .sheet(isPresented: $editingDetails) {
                if let meal { NavigationStack { LedgerOccurrenceEditor(model: model, shopID: shopID, meal: meal) } }
            }
            .confirmationDialog(ledgerText("Remove only this dinner's needs?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button(ledgerText("Remove dinner"), role: .destructive) {
                    Task { _ = await model.editShop(key: "remove-meal-\(occurrenceID)", shopID: shopID) { try $0.removeMeal(occurrenceID: occurrenceID) } }
                }
            } message: { Text(ledgerText("Other meals, manually added groceries and protected lunch needs will remain.")) }
    }
}

private struct LedgerOccurrenceEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let meal: MealOccurrence
    @State private var title: String
    @State private var notes: String
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerModel, shopID: UUID, meal: MealOccurrence) {
        self.model = model; self.shopID = shopID; self.meal = meal
        _title = State(initialValue: meal.title); _notes = State(initialValue: meal.notes)
    }
    var body: some View {
        Form {
            Section {
                TextField(ledgerText("Dinner title"), text: $title, axis: .vertical)
                TextField(ledgerText("Dinner notes"), text: $notes, axis: .vertical)
                Text(ledgerText("Edit ingredient amounts from each grocery need in Dinner details."))
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save this pickup's dinner")) {
                Task { if await model.editShop(key: "edit-meal-\(meal.id)", shopID: shopID, { try $0.updateMeal(occurrenceID: meal.id, title: title, notes: notes) }) { dismiss() } }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Edit dinner"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct LedgerMealDateView: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let meal: MealOccurrence
    @Environment(\.dismiss) private var dismiss
    @State private var dated: Bool
    @State private var date: Date
    init(model: LedgerModel, shop: ShoppingLedger, meal: MealOccurrence) {
        self.model = model; self.shop = shop; self.meal = meal
        _dated = State(initialValue: meal.scheduledDay != nil)
        _date = State(initialValue: meal.scheduledDay?.date ?? Date())
    }
    var body: some View {
        Form {
            Section {
                Text(meal.title).font(.headline)
                Toggle(ledgerText("Assign a night"), isOn: $dated)
                if dated {
                    DatePicker(ledgerText("Dinner date"), selection: $date, displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: shop.basis.timeZoneIdentifier) ?? .current)
                }
                Text(shop.basis.timeZoneIdentifier)
                Text(ledgerText("This moves the same dinner. Its grocery needs are not added again."))
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save dinner date")) {
                Task { if await model.editShop(key: "schedule-\(meal.id)", shopID: shop.id, { try $0.scheduleMeal(occurrenceID: meal.id, on: dated ? date : nil) }) { dismiss() } }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("ledgerSaveMealDate")
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Dinner date"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}
