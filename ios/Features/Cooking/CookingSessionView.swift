import CoreDomain
import LocalStore
import SwiftUI

@MainActor struct CookingSessionView<Finish: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    let title: String
    let steps: [RecipeStep]
    let ingredients: [String]
    let legacyNotes: String
    let yieldText: String
    let finishTitle: String?
    let finish: () -> Finish
    @StateObject private var model: CookingSessionModel
    @State private var minutes = ""
    @State private var alerts = false
    @State private var confirmEnd = false
    @State private var readback: CookReadbackInstruction?
    @State private var noteExcerpt: String?
    private enum Input { case minutes, noteExcerpt }
    @FocusState private var focusedInput: Input?
    @FocusState private var editingStepNote: Bool
    @AccessibilityFocusState private var instructionFocused: Bool

    init(title: String, steps: [RecipeStep], ingredients: [String], legacyNotes: String, yieldText: String = "",
         context: CookingSessionContext, finishTitle: String? = nil, @ViewBuilder finish: @escaping () -> Finish) {
        self.title = title; self.steps = steps; self.ingredients = ingredients; self.legacyNotes = legacyNotes; self.yieldText = yieldText
        self.finishTitle = finishTitle; self.finish = finish
        _model = StateObject(wrappedValue: CookingSessionModel(context: context, count: max(1, steps.count)))
    }
    private var index: Int { model.session?.step ?? 0 }
    private var step: RecipeStep? { steps.indices.contains(index) ? steps[index] : nil }
    private var linked: [Int] { step?.ingredientIndices ?? [] }

    var body: some View {
        Group {
            if model.ready && model.context.authorize() {
                WorkingForm {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: title).marketJournalTitle()
                                .fixedSize(horizontal: false, vertical: true)
                            if !yieldText.isEmpty { Text(verbatim: yieldText).foregroundStyle(Theme.secondary) }
                            Divider().accessibilityHidden(true)
                            if let step {
                                Text(String(format: recordsText("Step %lld of %lld"), Int64(index + 1), Int64(steps.count)))
                                    .font(.headline).monospacedDigit()
                                    .foregroundStyle(Theme.onSelection)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Theme.selection, in: RoundedRectangle(cornerRadius: 7))
                                    .accessibilityAddTraits(.isHeader)
                                ProgressView(value: Double(index + 1), total: Double(steps.count))
                                    .tint(Theme.action).accessibilityHidden(true)
                                Text(verbatim: step.instruction).font(.title3).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityFocused($instructionFocused)
                            } else if !legacyNotes.isEmpty {
                                Text(recordsText("Original recipe notes")).font(.headline)
                                Text(verbatim: legacyNotes).font(.title3).textSelection(.enabled)
                            } else {
                                Text(recordsText("This recipe has no written instructions."))
                            }
                        }.padding(.vertical, 6)
                        if index + 1 < steps.count {
                            Button { select(index + 1) } label: {
                                Label(recordsText("Next step"), systemImage: "arrow.forward")
                            }.buttonStyle(PrimaryAction())
                        }
                        if index > 0 {
                            Button { select(index - 1) } label: {
                                Label(recordsText("Previous step"), systemImage: "arrow.backward")
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    CookingStepNoteView(model: model, steps: steps, index: index, noteFocus: $editingStepNote)
                        .id(index)
                    if let amounts = model.session?.stepAmounts {
                        let rows = amounts.allocations.filter { $0.byStep[index] != nil && ingredients.indices.contains($0.ingredient) }
                        if !rows.isEmpty {
                            Section(recordsText("Reviewed amounts for this step")) {
                                Text(String(format: recordsText("Cooking for %@ servings"), cookingAmount(amounts.cookingServings)))
                                ForEach(rows, id: \.ingredient) { row in
                                    if let base = row.byStep[index], let scaled = try? amounts.scaled(base) {
                                        LabeledContent(ingredients[row.ingredient], value: cookingAmount(scaled) + " " + cookingUnit(row.unit, singular: scaled <= .one))
                                            .accessibilityIdentifier("cooking.scaledAmount." + String(row.ingredient))
                                    }
                                }
                            }
                        }
                    }
                    if !steps.isEmpty, !ingredients.isEmpty {
                        NavigationLink(recordsText("Review amounts by step")) {
                            CookingAmountReview(model: model, steps: steps, ingredients: ingredients, yieldText: yieldText)
                        }.accessibilityIdentifier("cooking.reviewAmounts")
                    }
                    Section(linked.isEmpty ? recordsText("All recipe ingredients") : recordsText("Ingredients for this step")) {
                        if linked.isEmpty {
                            Text(recordsText("This step has no reviewed ingredient links. Use the original wording below."))
                                .font(.body).foregroundStyle(Theme.secondary)
                        }
                        ForEach(linked.isEmpty ? Array(ingredients.indices) : linked, id: \.self) { position in
                            if ingredients.indices.contains(position) { Text(verbatim: ingredients[position]) }
                        }
                    }
                    if let step, !step.instruction.isEmpty {
                        Section {
                            Button(recordsText("Prepare read-aloud for this step")) { prepareReadback(step.instruction) }
                                .accessibilityIdentifier("cooking.prepareReadback")
                            readbackControls
                        }
                    } else if step == nil, !legacyNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let noteLines = legacyNotes.split(whereSeparator: \.isNewline)
                        Section {
                            Menu(recordsText("Choose cooking instructions from notes")) {
                                ForEach(noteLines.indices, id: \.self) { index in
                                    let line = String(noteLines[index])
                                    Button(line) { noteExcerpt = line; readback = nil }
                                }
                            }.accessibilityIdentifier("cooking.chooseNotes")
                            if noteExcerpt != nil {
                                TextField(recordsText("Words to read aloud"), text: Binding(get: { noteExcerpt ?? "" },
                                    set: { noteExcerpt = $0; readback = nil }), axis: .vertical)
                                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                                    .focused($focusedInput, equals: .noteExcerpt)
                                    .accessibilityIdentifier("cooking.noteExcerpt")
                                Button(recordsText("Prepare selected words for read-aloud")) {
                                    if let noteExcerpt, isVisibleExcerpt(noteExcerpt) { prepareReadback(noteExcerpt) }
                                }.disabled(!isVisibleExcerpt(noteExcerpt ?? ""))
                            }
                            readbackControls
                        } footer: {
                            Text(recordsText("Choose a line, then keep only the cooking instructions you want to hear."))
                        }
                    }
                    timers
                    if let message = model.message { Text(message).accessibilityAddTraits(.updatesFrequently) }
                    if let finishTitle {
                        NavigationLink { finish() } label: { Text(verbatim: finishTitle) }
                            .accessibilityIdentifier("cooking.finish")
                    }
                    Button(recordsText("End session and remove its timers"), role: .destructive) { confirmEnd = true }
                        .accessibilityIdentifier("cooking.end")
                }
            } else {
                VStack {
                    Text(model.message ?? recordsText("Open this recipe from your current private workspace."))
                    Button(recordsText("Try again")) { model.load() }
                }.padding()
            }
        }
        .navigationTitle(recordsText("Cooking mode"))
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focusedInput != nil || editingStepNote, title: ledgerText("Done"),
                            identifier: editingStepNote ? "cooking.stepNote.done" : focusedInput == .minutes ? "cooking.timerDone" : "cooking.noteDone") {
            focusedInput = nil
            editingStepNote = false
        }
        .task {
            model.load(); suggestedMinutes()
            await model.reconcileAlerts()
        }
        .onChange(of: scenePhase) { _, phase in
            readback = nil; noteExcerpt = nil
            if phase == .active { model.load(); Task { await model.reconcileAlerts() } }
            else { model.retire() }
        }
        .onDisappear { readback = nil; noteExcerpt = nil }
        .confirmationDialog(recordsText("End this cooking session?"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(recordsText("End session"), role: .destructive) { if model.end() { dismiss() } }
                .accessibilityIdentifier("cooking.confirmEnd")
            Button(recordsText("Cancel"), role: .cancel) {}
        } message: {
            Text(recordsText("Ending this session removes its timers."))
        }
    }

    private var timers: some View {
        Section(recordsText("Cooking timers")) {
            ForEach(Array((model.session?.timers ?? []).enumerated()), id: \.element.id) { position, timer in
                let label = String(format: recordsText("Timer %lld"), Int64(position + 1))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: label).font(.headline).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("cooking.timer.\(position)")
                    if steps.indices.contains(timer.step) {
                        Text(String(format: recordsText("Step %lld"), Int64(timer.step + 1))).font(.headline)
                        Text(verbatim: steps[timer.step].instruction)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { time in
                        let seconds = timer.remaining(at: time.date)
                        if seconds == 0 { Text(recordsText("Timer finished")).font(.headline) }
                        else {
                            VStack(alignment: .leading, spacing: 6) {
                                let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                                Text(verbatim: duration).font(.title2.weight(.medium)).monospacedDigit()
                                if timer.pausedSeconds != nil {
                                    Text(recordsText("Paused")).accessibilityIdentifier("cooking.paused.\(position)")
                                    Button(recordsText("Resume timer")) { Task { await model.resume(timer) } }
                                        .buttonStyle(PrimaryAction())
                                        .accessibilityLabel(label + ", " + recordsText("Resume timer"))
                                        .accessibilityIdentifier("cooking.resume.\(position)")
                                } else {
                                    Button(recordsText("Pause timer")) { model.pause(timer) }
                                        .buttonStyle(PrimaryAction())
                                        .accessibilityLabel(label + ", " + recordsText("Pause timer"))
                                        .accessibilityIdentifier("cooking.pause.\(position)")
                                }
                            }
                        }
                    }
                    Divider().accessibilityHidden(true)
                    Button(role: .destructive) { model.cancel(timer) } label: {
                        Text(recordsText("Remove timer"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel(label + ", " + recordsText("Remove timer"))
                    .accessibilityIdentifier("cooking.remove.\(position)")
                }
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .buttonStyle(.borderless)
                .accessibilityElement(children: .contain)
            }
            TextField(recordsText("Timer minutes"), text: $minutes)
                .keyboardType(.numberPad).focused($focusedInput, equals: .minutes)
            Toggle(recordsText("Alert me when this timer finishes"), isOn: $alerts)
            Button(recordsText("Start timer")) {
                guard let duration = Int(minutes) else { return }
                focusedInput = nil
                Task { await model.start(minutes: duration, alert: alerts) }
            }.disabled(Int(minutes).map { !(1...1440).contains($0) } ?? true)
                .accessibilityIdentifier("cooking.start")
        }
    }
    private func select(_ next: Int) {
        readback = nil; focusedInput = nil
        model.choose(next); suggestedMinutes()
        instructionFocused = true
    }
    private func suggestedMinutes() { minutes = String(step?.suggestedTimerMinutes ?? 5) }
    private func isVisibleExcerpt(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (try? CaptureLimits.validate(text)) != nil && legacyNotes.range(of: text, options: .literal) != nil
    }
    @ViewBuilder private var readbackControls: some View {
        if let readback {
            CookReadbackView(instruction: readback) { candidate, _ in
                self.readback == candidate && model.context.authorize() && Int64(index) == candidate.sourceRevision
            }
        }
    }
    private func prepareReadback(_ text: String) {
        guard model.context.authorize() else { model.retire(); return }
        let now = Date()
        readback = CookReadbackInstruction(authorityBindingID: UUID(), sourceID: model.context.key.source,
            sourceRevision: Int64(index), createdAt: now, startBefore: now.addingTimeInterval(120),
            text: text, localeIdentifier: locale.identifier, excludesPrivateBudget: true)
    }
}

private func cookingUnit(_ unit: CookingStepAmounts.Unit, singular: Bool = false) -> String {
    switch unit {
    case .tablespoons: recordsText("tbsp")
    case .teaspoons: recordsText("tsp")
    case .cups: dinnerUnit(.cup, singular: singular)
    case .milliliters: dinnerUnit(.milliliter, singular: singular)
    case .liters: dinnerUnit(.liter, singular: singular)
    case .grams: dinnerUnit(.gram, singular: singular)
    case .kilograms: dinnerUnit(.kilogram, singular: singular)
    case .ounces: dinnerUnit(.ounce, singular: singular)
    case .pounds: dinnerUnit(.pound, singular: singular)
    case .pieces: dinnerText(singular ? "unit" : "units")
    }
}

private func cookingAmount(_ value: Rational) -> String {
    let whole = value.numerator / value.denominator
    let rem = value.numerator % value.denominator
    if rem == 0 { return whole.formatted() }
    let fraction: String
    switch (rem, value.denominator) {
    case (1, 2): fraction = "½"
    case (1, 4): fraction = "¼"
    case (3, 4): fraction = "¾"
    default: return value.description
    }
    return (whole == 0 ? "" : whole.formatted()) + fraction
}

private struct CookingAmountReview: View {
    @ObservedObject var model: CookingSessionModel
    let steps: [RecipeStep]
    let ingredients: [String]
    let yieldText: String
    @State private var target = ""

    var body: some View {
        WorkingForm {
            if model.ready && model.context.authorize() {
                if !yieldText.isEmpty { Text(verbatim: yieldText) }
                if let prior = model.session?.stepAmounts {
                    Section(recordsText("Servings")) {
                        LabeledContent(recordsText("Source servings"), value: cookingAmount(prior.recipeServings))
                        TextField(recordsText("Cooking servings"), text: $target)
                        Button(recordsText("Update servings")) {
                            if let next = resized(prior) { _ = model.saveAmounts(next, replacing: prior, ingredientCount: ingredients.count) }
                        }.disabled(resized(prior) == nil)
                    }.onAppear { target = ledgerAmountInput(prior.cookingServings) }
                }
                Section(recordsText("Choose a measured ingredient")) {
                    ForEach(ingredients.indices, id: \.self) { i in
                        NavigationLink {
                            CookAllocationEditor(model: model, ingredient: i, ingredients: ingredients, steps: steps,
                                yieldText: yieldText, prior: model.session?.stepAmounts)
                        } label: {
                            Text(verbatim: ingredients[i])
                        }.accessibilityIdentifier("cooking.reviewIngredient." + String(i))
                    }
                }
                if let message = model.message { Text(message) }
            }
        }.navigationTitle(recordsText("Review amounts by step"))
    }

    private func resized(_ prior: CookingStepAmounts) -> CookingStepAmounts? {
        guard let servings = try? ListQuantityParser.numericAmount(target), servings != prior.cookingServings else { return nil }
        var next = prior
        next.cookingServings = servings
        guard (try? next.validate(stepCount: steps.count, ingredientCount: ingredients.count)) != nil else { return nil }
        return next
    }
}

private struct CookAllocationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CookingSessionModel
    let ingredient: Int
    let ingredients: [String]
    let steps: [RecipeStep]
    let yieldText: String
    @State private var prior: CookingStepAmounts?
    @State private var sourceServings: String
    @State private var targetServings: String
    @State private var total: String
    @State private var unit: CookingStepAmounts.Unit?
    @State private var shares: [Int: String]

    init(model: CookingSessionModel, ingredient: Int, ingredients: [String], steps: [RecipeStep],
         yieldText: String, prior: CookingStepAmounts?) {
        self.model = model
        self.ingredient = ingredient
        self.ingredients = ingredients
        self.steps = steps
        self.yieldText = yieldText
        let row = prior?.allocations.first { $0.ingredient == ingredient }
        _prior = State(initialValue: prior)
        _sourceServings = State(initialValue: prior.map { ledgerAmountInput($0.recipeServings) } ?? "")
        _targetServings = State(initialValue: prior.map { ledgerAmountInput($0.cookingServings) } ?? "")
        _total = State(initialValue: row.map { ledgerAmountInput($0.originalAmount) } ?? "")
        _unit = State(initialValue: row?.unit)
        _shares = State(initialValue: row?.byStep.mapValues { ledgerAmountInput($0) } ?? [:])
    }

    var body: some View {
        WorkingForm {
            if model.ready && model.context.authorize() {
                Section(recordsText("Original ingredient")) {
                    Text(verbatim: ingredients[ingredient])
                    if !yieldText.isEmpty { Text(verbatim: yieldText) }
                    if prior == nil {
                        TextField(recordsText("Source servings"), text: $sourceServings)
                        TextField(recordsText("Cooking servings"), text: $targetServings)
                    }
                    TextField(recordsText("Total in the original recipe"), text: $total)
                    Picker(recordsText("Recipe unit"), selection: $unit) {
                        Text(recordsText("Choose a unit")).tag(CookingStepAmounts.Unit?.none)
                        ForEach(CookingStepAmounts.Unit.allCases, id: \.self) { u in
                            Text(cookingUnit(u)).tag(Optional(u))
                        }
                    }
                }
                Section {
                    ForEach(steps.indices, id: \.self) { i in
                        VStack(alignment: .leading) {
                            Text(verbatim: steps[i].instruction)
                            TextField(String(format: recordsText("Amount for step %lld"), Int64(i + 1)),
                                text: Binding(get: { shares[i] ?? "" }, set: { shares[i] = $0 }))
                        }
                    }
                } footer: {
                    Text(recordsText("Enter original step amounts that add up to the recipe total. Leave unmeasured instructions as written."))
                }
                Button(recordsText("Save reviewed amounts")) {
                    if let next = reviewed, model.saveAmounts(next, replacing: prior, ingredientCount: ingredients.count) { dismiss() }
                }.buttonStyle(PrimaryAction()).disabled(reviewed == nil).accessibilityIdentifier("cooking.saveReviewedAmounts")
                if let prior, prior.allocations.contains(where: { $0.ingredient == ingredient }) {
                    Button(recordsText("Remove this amount review"), role: .destructive) {
                        var next = prior
                        next.allocations.removeAll { $0.ingredient == ingredient }
                        if model.saveAmounts(next.allocations.isEmpty ? nil : next, replacing: prior, ingredientCount: ingredients.count) { dismiss() }
                    }
                }
                if let message = model.message { Text(message) }
            }
        }.navigationTitle(recordsText("Step amounts"))
    }

    private var reviewed: CookingStepAmounts? {
        guard let unit, let source = try? ListQuantityParser.numericAmount(sourceServings),
              let target = try? ListQuantityParser.numericAmount(targetServings),
              let amount = try? ListQuantityParser.numericAmount(total) else { return nil }
        var values: [Int: Rational] = [:]
        for (i, literal) in shares where !literal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let value = try? ListQuantityParser.numericAmount(literal) else { return nil }
            values[i] = value
        }
        var rows = prior?.allocations.filter { $0.ingredient != ingredient } ?? []
        rows.append(.init(ingredient: ingredient, originalAmount: amount, unit: unit, byStep: values))
        let next = CookingStepAmounts(recipeServings: source, cookingServings: target, allocations: rows)
        guard (try? next.validate(stepCount: steps.count, ingredientCount: ingredients.count)) != nil else { return nil }
        return next
    }
}
