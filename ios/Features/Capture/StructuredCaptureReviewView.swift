import SwiftUI
import CoreDomain

@MainActor struct StructuredCaptureReviewView: View {
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
    let itemNameFocus: FocusState<UUID?>.Binding
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
                CaptureStructuredRow(line: line, corrections: corrections, itemNameFocus: itemNameFocus, destination: destination, source: source,
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
                    Text(captureText(context == .recipe ? "Spelling memory is unavailable. Your reviewed ingredients are still usable." :
                        "Spelling memory is unavailable. Your reviewed list is still usable."))
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
                Text(captureText("This deletes remembered spellings for this private workspace and selected language. Other languages and previously saved records stay as they are."))
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
                    onContinue(reviewed)
                } catch StructuredCaptureFailure.destinationMismatch {
                    validationMessage = copy.mismatch
                } catch {
                    validationMessage = "Review each item. Use a positive amount or leave it explicitly unknown; pack counts must be whole numbers."
                }
            }.disabled(!authorize() || lines.isEmpty || !lines.contains(where: { !$0.skip }) || !lines.allSatisfy { $0.skip || $0.confirmed })
                .accessibilityIdentifier("capture.continue")
            Button(captureText("Back to captured words"), action: onBack)
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
    let itemNameFocus: FocusState<UUID?>.Binding
    let destination: String
    let source: CaptureSource
    let authorizeSpelling: () -> Bool
    let rememberSpelling: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(line.originalText).font(.footnote).textSelection(.enabled)
            Toggle(captureText("Skip this captured line"), isOn: $line.skip)
            if !line.skip {
                TextField(captureText("Item name"), text: field(\.name))
                    .focused(itemNameFocus, equals: line.id)
                    .submitLabel(.done)
                    .onSubmit { itemNameFocus.wrappedValue = nil }
                if authorizeSpelling(), let suggestion = corrections.suggestion(for: line.originalName), line.name != suggestion.replacement {
                    Text(captureText("Remembered spelling to review") + ": " + suggestion.replacement)
                    Button {
                        guard authorizeSpelling() else { return }
                        line.name = suggestion.replacement
                        line.confirmed = false
                        itemNameFocus.wrappedValue = nil
                    } label: {
                        Text(captureText("Use this spelling")).frame(minHeight: 44)
                    }.buttonStyle(.borderless)
                }
                TextField(captureText("Total amount, unknown if blank"), text: field(\.amount)).keyboardType(.numbersAndPunctuation)
                unitPicker(captureText("Total unit"), value: \.unit)
                TextField(captureText("Number of packs, unknown if blank"), text: field(\.packCount)).keyboardType(.numberPad)
                TextField(captureText("Usable amount in each pack, unknown if blank"), text: field(\.amountPerPack)).keyboardType(.numbersAndPunctuation)
                unitPicker(captureText("Unit in each pack"), value: \.packUnit)
                Text(captureText("A pack count alone is not a usable amount. Unknown fields stay unknown; complete pack amounts are checked by the list planner."))
                    .font(.footnote)
                TextField(captureText("Purpose or meal, unknown if blank"), text: field(\.purpose), axis: .vertical)
                TextField(captureText("Destination wording"), text: field(\.destination), axis: .vertical)
                Button(captureText("Use the displayed destination")) { line.destination = destination; line.confirmed = false }
                TextField(captureText("Exclusions, one per line"), text: field(\.exclusions), axis: .vertical)
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
                        itemNameFocus.wrappedValue = nil
                    } label: {
                        Text(captureText("Remember this corrected product spelling")).frame(minHeight: 44)
                    }.buttonStyle(.borderless)
                }
                Toggle(captureText("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns."), isOn: $line.confirmed)
            }
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
