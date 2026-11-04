import SwiftUI
import CoreDomain

struct StructuredCaptureField: Hashable {
    enum Control: Hashable { case name, amount, packCount, amountPerPack, purpose, destination, exclusions }
    let lineID: UUID
    let control: Control
}

@MainActor struct StructuredCaptureReviewView: View {
    static let originalAnchor = "capture.structured.original"

    enum Context {
        case list, request, recipe

        var copy: (destination: String, action: String, changed: String, mismatch: String, next: String) {
            switch self {
            case .list:
                return (
                    "Destination wording does not change where this list goes. Choose the displayed list explicitly, or cancel and open the intended list.",
                    "Continue to list review",
                    "This workspace changed. Close capture and review the current list.",
                    "Confirm the displayed destination for every item, or cancel and choose another list.",
                    "The next screen reviews duplicates before adding the reviewed list. Capture does not verify a price, receipt, food safety or arrival."
                )
            case .request:
                return (
                    "Destination wording does not change where this request goes. Confirm the displayed household destination, or cancel and open the intended household.",
                    "Continue to request review",
                    "This household or request changed. Close capture and review the current request.",
                    "Confirm the displayed request destination, or cancel and choose the intended household.",
                    "The next screen previews your own request before sending. Only the shopper can change the basket; capture does not verify price, food safety or arrival."
                )
            case .recipe:
                return (
                    "These ingredients belong to this recipe. Confirm the displayed recipe destination before continuing.",
                    "Review recipe draft",
                    "This workspace changed. Close capture and open the current recipe review.",
                    "Confirm this recipe as the destination for every ingredient before continuing.",
                    "The next screen previews the editable recipe. Saving it leaves this pickup unchanged."
                )
            }
        }
    }

    @Binding var lines: [CaptureLineDraft]
    @ObservedObject var corrections: CaptureCorrectionsModel
    let correctionScope: CaptureCorrectionScope?
    let fieldFocus: FocusState<StructuredCaptureField?>.Binding
    let destination: String
    let source: CaptureSource
    let context: Context
    let originalText: String
    let imageData: Data?
    let authorize: () -> Bool
    let onBack: () -> Void
    let onContinue: ([CaptureImportLine]) -> Void
    @State private var validationMessage: String?
    @State private var spellingWorking = false
    @State private var confirmDisable = false
    @State private var requestedDisableScope: CaptureCorrectionScope?

    private var liveSpellingScope: CaptureCorrectionScope? {
        guard authorize(), let correctionScope, corrections.scope == correctionScope else { return nil }
        return correctionScope
    }

    var body: some View {
        let copy = context.copy
        Section(captureText("Original wording and source")) {
            Text(originalText).textSelection(.enabled)
                .id(Self.originalAnchor)
                .accessibilityIdentifier(Self.originalAnchor)
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                    .accessibilityLabel(captureText("Selected source photo"))
            }
            Text(captureText("Actual destination") + ": " + destination).font(.headline)
            Text(captureText(copy.destination))
        }
        ForEach(lines) { snapshot in
            let placeholder = CaptureLineDraft(id: snapshot.id, proposedLineID: snapshot.proposedLineID,
                originalText: "", originalName: "", name: "")
            let line = captureDraftBinding(placeholder, in: $lines)
            Section {
                CaptureStructuredRow(line: line, corrections: corrections, fieldFocus: fieldFocus, destination: destination, source: source,
                    authorizeSpelling: { liveSpellingScope != nil && !spellingWorking }) { original, replacement in
                    changeSpellings { await corrections.remember(original: original, replacement: replacement) }
                }
            }
        }
        if let scope = liveSpellingScope {
            Section(captureText("Optional spelling memory")) {
                Toggle(captureText("Remember product spellings on this device"), isOn: Binding(get: { corrections.snapshot.enabled }, set: { value in
                    guard liveSpellingScope == scope, !spellingWorking else { return }
                    if value { changeSpellings { await corrections.setEnabled(true) } }
                    else { requestedDisableScope = scope; confirmDisable = true }
                })).disabled(spellingWorking).accessibilityIdentifier("capture.spelling.enabled")
                Text(captureText("Only spellings you explicitly remember are saved for this profile and language. Turning this off deletes them. Previous records never change."))
                    .font(.footnote)
                if corrections.snapshot.enabled {
                    ForEach(corrections.snapshot.entries) { entry in
                        HStack {
                            Text(entry.original + " → " + entry.replacement)
                            Spacer()
                            Button(captureText("Forget spelling"), role: .destructive) {
                                changeSpellings { await corrections.forget(entry.id) }
                            }.frame(minHeight: 44).disabled(spellingWorking)
                                .accessibilityLabel(CorrectionSettingsOutcome.forgetLabel(entry))
                        }
                    }
                }
                if corrections.failed {
                    let message = switch context {
                    case .recipe: captureText("Spelling memory is unavailable. Your reviewed ingredients are still usable.")
                    case .request: captureText("Spelling memory is unavailable. You can still review this request.")
                    case .list: captureText("Spelling memory is unavailable. Your reviewed list is still usable.")
                    }
                    Text(message)
                }
            }
            .alert(captureText("Turn off spelling memory?"), isPresented: $confirmDisable) {
                Button(captureText("Turn off and delete these spellings"), role: .destructive) {
                    guard requestedDisableScope == scope, liveSpellingScope == scope else { return }
                    requestedDisableScope = nil
                    changeSpellings { await corrections.setEnabled(false) }
                }.accessibilityIdentifier("capture.spelling.confirmDisable")
                Button(captureText("Cancel"), role: .cancel) { requestedDisableScope = nil }
                    .accessibilityIdentifier("capture.spelling.cancelDisable")
            } message: {
                Text(captureText(context == .request ? "This deletes remembered spellings for this household profile and language." :
                    "This deletes remembered spellings for this private workspace and selected language. Other languages and previously saved records stay as they are."))
            }
        }
        Section {
            if let validationMessage { Text(captureText(validationMessage)).accessibilityIdentifier("capture.structured.error") }
            Button(captureText(copy.action)) {
                guard authorize() else { validationMessage = copy.changed; return }
                do {
                    let reviewed = try lines.compactMap { try $0.reviewed(expectedDestination: destination) }
                    guard !reviewed.isEmpty else { throw StructuredCaptureFailure.reviewRequired }
                    if context == .request, reviewed.count != 1 {
                        validationMessage = "Keep exactly one reviewed item for this request. Skip other lines or cancel; nothing has been sent."
                        return
                    }
                    fieldFocus.wrappedValue = nil
                    onContinue(reviewed)
                } catch StructuredCaptureFailure.destinationMismatch {
                    validationMessage = copy.mismatch
                } catch {
                    validationMessage = "Review each item. Use a positive amount or leave it explicitly unknown; pack counts must be whole numbers."
                }
            }.disabled(!authorize() || lines.isEmpty || !lines.contains(where: { !$0.skip }) || !lines.allSatisfy { $0.skip || $0.confirmed })
                .accessibilityIdentifier("capture.continue")
            Button(captureText("Back to captured words")) { fieldFocus.wrappedValue = nil; onBack() }
            Text(captureText(copy.next))
                .font(.footnote)
        }
        .onChange(of: liveSpellingScope) { _, _ in
            requestedDisableScope = nil
            confirmDisable = false
        }
    }

    private func changeSpellings(_ change: @escaping @MainActor () async -> Void) {
        guard let scope = liveSpellingScope, !spellingWorking else { return }
        spellingWorking = true
        Task {
            defer { spellingWorking = false }
            guard liveSpellingScope == scope else { return }
            await change()
        }
    }
}

@MainActor private struct CaptureStructuredRow: View {
    @Binding var line: CaptureLineDraft
    @ObservedObject var corrections: CaptureCorrectionsModel
    let fieldFocus: FocusState<StructuredCaptureField?>.Binding
    let destination: String
    let source: CaptureSource
    let authorizeSpelling: () -> Bool
    let rememberSpelling: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(line.originalText).font(.footnote).textSelection(.enabled)
            Toggle(captureText("Skip this captured line"), isOn: $line.skip)
            if !line.skip {
                labeledField(captureText("Item name")) {
                    TextField(captureText("Item name"), text: field(\.name))
                        .focused(fieldFocus, equals: focus(.name))
                        .submitLabel(.done)
                        .onSubmit { fieldFocus.wrappedValue = nil }
                }
                if authorizeSpelling(), let suggestion = corrections.suggestion(for: line.originalName), line.name != suggestion.replacement {
                    Text(captureText("Remembered spelling to review") + ": " + suggestion.replacement)
                    Button {
                        guard authorizeSpelling() else { return }
                        line.name = suggestion.replacement
                        line.confirmed = false
                        fieldFocus.wrappedValue = nil
                    } label: {
                        Text(captureText("Use this spelling")).frame(minHeight: 44)
                    }.buttonStyle(.borderless)
                }
                quantityField(captureText("Total amount"), accessibilityTitle: captureText("Total amount, unknown if blank"),
                    value: \.amount, control: .amount, keyboard: .numbersAndPunctuation)
                unitPicker(captureText("Total unit"), value: \.unit)
                quantityField(captureText("Number of packs"), accessibilityTitle: captureText("Number of packs, unknown if blank"),
                    value: \.packCount, control: .packCount, keyboard: .numberPad)
                quantityField(captureText("Usable amount in each pack"), accessibilityTitle: captureText("Usable amount in each pack, unknown if blank"),
                    value: \.amountPerPack, control: .amountPerPack, keyboard: .numbersAndPunctuation)
                unitPicker(captureText("Unit in each pack"), value: \.packUnit)
                Text(captureText("A pack count alone is not a usable amount. Unknown fields stay unknown; complete pack amounts are checked by the list planner."))
                    .font(.footnote)
                labeledField(captureText("Purpose or meal")) {
                    TextField(captureText("Purpose or meal, unknown if blank"), text: field(\.purpose), axis: .vertical)
                        .accessibilityLabel(captureText("Purpose or meal, unknown if blank"))
                        .accessibilityIdentifier("capture.field.purpose")
                        .focused(fieldFocus, equals: focus(.purpose))
                }
                labeledField(captureText("Destination wording")) {
                    TextField(captureText("Destination wording"), text: field(\.destination), axis: .vertical)
                        .accessibilityLabel(captureText("Destination wording"))
                        .accessibilityIdentifier("capture.field.destination")
                        .focused(fieldFocus, equals: focus(.destination))
                }
                Button(captureText("Use the displayed destination")) { line.destination = destination; line.confirmed = false }
                labeledField(captureText("Exclusions")) {
                    TextField(captureText("Exclusions, one per line"), text: field(\.exclusions), axis: .vertical)
                        .accessibilityLabel(captureText("Exclusions, one per line"))
                        .accessibilityIdentifier("capture.field.exclusions")
                        .focused(fieldFocus, equals: focus(.exclusions))
                }
                if !line.warnings.isEmpty {
                    Label(captureText("Some wording, quantities, packs or destination were ambiguous. Compare every field with the original."), systemImage: "exclamationmark.triangle")
                }
                if line.warnings.contains(.negation) {
                    Text(captureText("Negation may describe the product or exclude it. Nothing is deleted automatically. Correct or skip this line before confirming."))
                }
                if authorizeSpelling(), corrections.snapshot.enabled, source == .speech || source == .photoOCR,
                   CaptureCorrectionStore.validProduct(line.originalName), CaptureCorrectionStore.validProduct(line.name),
                   CaptureCorrectionStore.key(line.originalName) != CaptureCorrectionStore.key(line.name) {
                    Button {
                        rememberSpelling(line.originalName, line.name)
                        fieldFocus.wrappedValue = nil
                    } label: {
                        Text(captureText("Remember this corrected product spelling")).frame(minHeight: 44)
                    }.buttonStyle(.borderless)
                }
                Toggle(captureText("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns."), isOn: $line.confirmed)
            }
        }.onChange(of: line.skip) { _, skip in
            if skip, fieldFocus.wrappedValue?.lineID == line.id { fieldFocus.wrappedValue = nil }
        }
    }
    private func focus(_ control: StructuredCaptureField.Control) -> StructuredCaptureField {
        StructuredCaptureField(lineID: line.id, control: control)
    }
    private func quantityField(_ title: String, accessibilityTitle: String, value: WritableKeyPath<CaptureLineDraft, String>,
                               control: StructuredCaptureField.Control, keyboard: UIKeyboardType) -> some View {
        labeledField(title) {
            TextField(accessibilityTitle, text: field(value), prompt: Text(captureText("Unknown")))
                .accessibilityLabel(accessibilityTitle)
                .keyboardType(keyboard)
                .focused(fieldFocus, equals: focus(control))
        }
    }
    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            content()
        }
    }
    private func field(_ path: WritableKeyPath<CaptureLineDraft, String>) -> Binding<String> {
        Binding(get: { line[keyPath: path] }, set: { line[keyPath: path] = $0; line.confirmed = false })
    }
    private func unitPicker(_ title: String, value: WritableKeyPath<CaptureLineDraft, UnitOfMeasure>) -> some View {
        Picker(title, selection: Binding(get: { line[keyPath: value] }, set: { line[keyPath: value] = $0; line.confirmed = false })) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(captureText(captureUnitKey($0))).tag($0) }
        }
    }
}
func captureUnitKey(_ unit: UnitOfMeasure) -> String {
    switch unit {
    case .count: return "Count"
    case .gram: return "Grams"
    case .kilogram: return "Kilograms"
    case .ounce: return "Ounces (weight)"
    case .pound: return "Pounds"
    case .milliliter: return "Milliliters"
    case .liter: return "Liters"
    case .fluidOunce: return "Fluid ounces"
    case .cup: return "US cups"
    }
}
