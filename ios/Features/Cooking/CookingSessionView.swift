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
    let finishTitle: String?
    let finish: () -> Finish
    @StateObject private var model: CookingSessionModel
    @State private var minutes = ""
    @State private var alerts = false
    @State private var confirmEnd = false
    @State private var readback: CookReadbackInstruction?
    @FocusState private var editingMinutes: Bool
    @AccessibilityFocusState private var instructionFocused: Bool

    init(title: String, steps: [RecipeStep], ingredients: [String], legacyNotes: String,
         context: CookingSessionContext, finishTitle: String? = nil, @ViewBuilder finish: @escaping () -> Finish) {
        self.title = title; self.steps = steps; self.ingredients = ingredients; self.legacyNotes = legacyNotes
        self.finishTitle = finishTitle; self.finish = finish
        _model = StateObject(wrappedValue: CookingSessionModel(context: context, count: max(1, steps.count)))
    }
    private var index: Int { model.session?.step ?? 0 }
    private var step: RecipeStep? { steps.indices.contains(index) ? steps[index] : nil }
    private var linked: [Int] { step?.ingredientIndices ?? [] }

    var body: some View {
        Group {
            if model.ready && model.context.authorize() {
                Form {
                    Section {
                        Text(verbatim: title).font(.title2.bold())
                        if let step {
                            Text(String(format: recordsText("Step %lld of %lld"), Int64(index + 1), Int64(steps.count))).font(.headline)
                            Text(verbatim: step.instruction).font(.title3).textSelection(.enabled)
                                .accessibilityFocused($instructionFocused)
                        } else if !legacyNotes.isEmpty {
                            Text(recordsText("Original recipe notes")).font(.headline)
                            Text(verbatim: legacyNotes).font(.title3).textSelection(.enabled)
                        } else {
                            Text(recordsText("This recipe has no written instructions."))
                        }
                        if index > 0 { Button(recordsText("Previous step")) { select(index - 1) } }
                        if index + 1 < steps.count { Button(recordsText("Next step")) { select(index + 1) } }
                    }
                    Section(linked.isEmpty ? recordsText("All recipe ingredients") : recordsText("Ingredients for this step")) {
                        if linked.isEmpty {
                            Text(recordsText("This step has no reviewed ingredient links. Use the original wording below.")).font(.footnote)
                        }
                        ForEach(linked.isEmpty ? Array(ingredients.indices) : linked, id: \.self) { position in
                            if ingredients.indices.contains(position) { Text(verbatim: ingredients[position]) }
                        }
                    }
                    if let step, !step.instruction.isEmpty {
                        Section {
                            Button(recordsText("Prepare read-aloud for this step")) { prepareReadback(step) }
                                .accessibilityIdentifier("cooking.prepareReadback")
                            if let readback {
                                CookReadbackView(instruction: readback) { candidate, _ in
                                    self.readback == candidate && model.context.authorize() && Int64(index) == candidate.sourceRevision
                                }
                            }
                        }
                    }
                    timers
                    if let message = model.message { Text(message).accessibilityAddTraits(.updatesFrequently) }
                    if let finishTitle {
                        NavigationLink { finish() } label: { Text(verbatim: finishTitle) }
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
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: editingMinutes, title: ledgerText("Done"), identifier: "cooking.timerDone") { editingMinutes = false }
        .task {
            model.load(); suggestedMinutes()
            await model.reconcileAlerts()
        }
        .onChange(of: scenePhase) { _, phase in
            readback = nil
            if phase == .active { model.load(); Task { await model.reconcileAlerts() } }
            else { model.retire() }
        }
        .onDisappear { readback = nil }
        .confirmationDialog(recordsText("End this cooking session?"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(recordsText("End session and remove its timers"), role: .destructive) { if model.end() { dismiss() } }
                .accessibilityIdentifier("cooking.confirmEnd")
            Button(recordsText("Cancel"), role: .cancel) {}
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
                            let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                            Text(verbatim: duration).monospacedDigit()
                            if timer.pausedSeconds != nil {
                                Text(recordsText("Paused")).accessibilityIdentifier("cooking.paused.\(position)")
                                Button(recordsText("Resume timer")) { Task { await model.resume(timer) } }
                            } else { Button(recordsText("Pause timer")) { model.pause(timer) }.accessibilityIdentifier("cooking.pause.\(position)") }
                        }
                    }
                    Button(recordsText("Remove timer"), role: .destructive) { model.cancel(timer) }
                }.buttonStyle(.borderless).accessibilityElement(children: .contain)
            }
            TextField(recordsText("Timer minutes"), text: $minutes)
                .keyboardType(.numberPad).focused($editingMinutes)
            Toggle(recordsText("Alert me when this timer finishes"), isOn: $alerts)
            Button(recordsText("Start timer")) {
                guard let duration = Int(minutes) else { return }
                editingMinutes = false
                Task { await model.start(minutes: duration, alert: alerts) }
            }.disabled(Int(minutes).map { !(1...1440).contains($0) } ?? true)
                .accessibilityIdentifier("cooking.start")
        }
    }
    private func select(_ next: Int) {
        readback = nil; editingMinutes = false
        model.choose(next); suggestedMinutes()
        instructionFocused = true
    }
    private func suggestedMinutes() { minutes = String(step?.suggestedTimerMinutes ?? 5) }
    private func prepareReadback(_ step: RecipeStep) {
        guard model.context.authorize() else { model.retire(); return }
        let now = Date()
        readback = CookReadbackInstruction(authorityBindingID: UUID(), sourceID: model.context.key.source,
            sourceRevision: Int64(index), createdAt: now, startBefore: now.addingTimeInterval(120),
            text: step.instruction, localeIdentifier: locale.identifier, excludesPrivateBudget: true)
    }
}
