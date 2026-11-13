import SwiftUI
import CoreDomain

/// Returns an explicitly reviewed total to the existing dinner planner. Never applies a dinner change.
@MainActor struct GuestCaptureReviewView: View {
    let meals: [CaptureGuestMealChoice]
    let dismissAfterPreview: Bool
    let cancelDecision: (() -> Void)?
    let authorize: () -> Bool
    let onPreview: (ReviewedGuestCapture) -> Void
    @StateObject private var capture: CaptureModel
    @State private var mealID: UUID?
    @State private var groupID: UUID?
    @State private var total = ""
    private enum Field { case wording, total }
    @FocusState private var focusedField: Field?
    @State private var usedSuggestion = false
    @State private var confirmed = false
    @State private var delivered = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(meals: [CaptureGuestMealChoice], localeIdentifier: String = CaptureCorrectionScope.appLanguage(),
         dismissAfterPreview: Bool = true, cancelDecision: (() -> Void)? = nil,
         authorize: @escaping () -> Bool, onPreview: @escaping (ReviewedGuestCapture) -> Void) {
        self.dismissAfterPreview = dismissAfterPreview; self.cancelDecision = cancelDecision
        self.meals = meals; self.authorize = authorize; self.onPreview = onPreview
        _capture = StateObject(wrappedValue: CaptureModel(localeIdentifier: localeIdentifier, speech: OnDeviceSpeechCapture(), ocr: OnDeviceTextCapture()))
    }
    private var meal: CaptureGuestMealChoice? { meals.first { $0.id == mealID } }
    private var group: CaptureGuestGroupChoice? { meal?.groups.first { $0.id == groupID && !$0.isProtected } }
    private var reviewedTotal: Rational? { try? CaptureLineDraft.quantity(total, unit: .count)?.amount }
    private var proposedTotal: Rational? {
        guard let group, let proposal = CaptureGuestParser.proposal(capture.text) else { return nil }
        return try? proposal.proposedTotal(current: group.currentServings)
    }
    var body: some View {
        Form {
            Section(captureText("Guest wording to review")) {
                TextEditor(text: $capture.text).frame(minHeight: 120).accessibilityLabel(captureText("Guest wording to review"))
                    .focused($focusedField, equals: .wording)
                    .disabled(capture.busy)
                PasteButton(payloadType: String.self) { capture.stagePaste($0) }.disabled(capture.busy)
                if capture.busy {
                    Button(captureText("Stop recording and review")) { capture.stopSpeech() }
                } else {
                    Button(captureText("Dictate on this iPhone")) { capture.startSpeech() }.disabled(!authorize())
                }
                if let candidate = capture.candidate {
                    Text(candidate.text).textSelection(.enabled)
                    Button(captureText("Use captured text")) { capture.acceptCandidate() }.disabled(capture.busy)
                    Button(captureText("Keep my typed draft")) { capture.discardCandidate() }.disabled(capture.busy)
                }
                if capture.failure != nil { Text(captureText("Speech is unavailable or uncertain. Type and review the guest wording instead.")) }
                Text(captureText("Capture alone changes no servings. Choose a meal and group, then review a new total."))
            }
            Section(captureText("Meal, group and new total")) {
                Picker(captureText("Choose the meal"), selection: $mealID) {
                    Text(captureText("Choose explicitly")).tag(nil as UUID?)
                    ForEach(meals) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker(captureText("Choose the serving group"), selection: $groupID) {
                    Text(captureText("Choose explicitly")).tag(nil as UUID?)
                    ForEach(meal?.groups.filter { !$0.isProtected } ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                if let group { Text(captureText("Current servings") + ": " + group.currentServings.description) }
                if let proposedTotal {
                    Text(captureText("Possible new total to review") + ": " + proposedTotal.description)
                    Button(captureText("Use this proposed total")) {
                        total = proposedTotal.description
                        usedSuggestion = true
                        confirmed = false
                    }
                }
                TextField(captureText("Reviewed new total servings"), text: Binding(
                    get: { total },
                    set: { value in total = value; usedSuggestion = false }
                )).keyboardType(.numbersAndPunctuation)
                    .focused($focusedField, equals: .total)
                Text(captureText("Protected groups stay unchanged. Ambiguous wording needs a typed total. The dinner planner will show pack, lunch and checkout effects before any Apply."))
                Toggle(captureText("I checked the original wording, chosen meal, group and new total."), isOn: $confirmed)
            }
            Section {
                Button(captureText("Preview guest changes")) {
                    guard authorize(), !delivered, confirmed, let meal, let group, let total = reviewedTotal else { return }
                    capture.confirmed = true
                    guard let words = capture.reviewed() else { return }
                    delivered = true
                    onPreview(.init(id: words.id, originalText: words.originalText, occurrenceID: meal.id,
                        groupID: group.id, baselineServings: group.currentServings, total: total))
                    if dismissAfterPreview { dismiss() }
                }.disabled(!authorize() || delivered || !confirmed || capture.busy || capture.candidate != nil || capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group == nil || reviewedTotal == nil)
                    .accessibilityIdentifier("capture.guests.preview")
            }
        }
        .keyboardDoneAction(visible: focusedField != nil, title: captureText("Done"), identifier: "capture.guests.keyboardDone") {
            focusedField = nil
        }
        .navigationTitle(captureText("Review guest change"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { capture.close(); if let cancelDecision { cancelDecision() } else { dismiss() } } } }
        .onChange(of: capture.text) { _, _ in
            if usedSuggestion { total = ""; usedSuggestion = false }
            confirmed = false
        }
        .onChange(of: total) { _, _ in confirmed = false }
        .onChange(of: mealID) { _, _ in groupID = nil; total = ""; usedSuggestion = false; confirmed = false }
        .onChange(of: groupID) { _, _ in total = ""; usedSuggestion = false; confirmed = false }
        .onChange(of: meals) { _, _ in capture.close(); dismiss() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { capture.close(); dismiss() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !authorize() { capture.close(); dismiss(); return }
            }
        }
        .onDisappear { capture.close() }
    }
}
