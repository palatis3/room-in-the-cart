import SwiftUI
import PhotosUI

func captureText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Capture") }

/// Returns a reviewed draft to the existing staged ledger import. It has no ledger/store/network dependency.
@MainActor struct CaptureReviewView: View {
    @StateObject private var model: CaptureModel
    let onReviewed: (ReviewedCapture) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @AccessibilityFocusState private var reviewFocused: Bool

    init(initialText: String = "", localeIdentifier: String = Locale.current.identifier, onReviewed: @escaping (ReviewedCapture) -> Void) {
        _model = StateObject(wrappedValue: CaptureModel(initialText: initialText, localeIdentifier: localeIdentifier,
            speech: OnDeviceSpeechCapture(), ocr: OnDeviceTextCapture()))
        self.onReviewed = onReviewed
    }

    var body: some View {
        Form {
            Section {
                Text(captureText("Capture is optional. You can always type your list."))
                Text(captureText("Speech and photo text recognition run on this iPhone. Nothing is added until you review the list."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(captureText("Destination: this pickup’s list review"))
            }
            if let candidate = model.candidate {
                Section(captureText("Captured wording — check before using")) {
                    evidence(candidate)
                    if !model.busy {
                        Button(captureText("Use captured text")) { model.acceptCandidate(); reviewFocused = true }
                            .accessibilityIdentifier("capture.useText")
                        Button(captureText("Keep my typed draft")) { model.discardCandidate() }
                    }
                }
            }
            Section(captureText("Your editable list")) {
                Text(captureText("One item per line. Check item names, amounts, units and any exclusions."))
                TextEditor(text: $model.text).frame(minHeight: 180)
                    .accessibilityLabel(captureText("List text to review")).accessibilityIdentifier("capture.editor")
                    .accessibilityFocused($reviewFocused)
                    .disabled(model.busy || loadingPhoto || model.closed)
                if let evidence = model.acceptedEvidence {
                    DisclosureGroup(captureText("Compare with the original")) { self.evidence(evidence) }
                }
                if model.containsExclusion {
                    Label(captureText("This wording may exclude an item. Check the exclusion before continuing."), systemImage: "exclamationmark.triangle")
                }
            }
            Section(captureText("Optional capture")) {
                PasteButton(payloadType: String.self) { model.stagePaste($0) }
                    .accessibilityLabel(captureText("Paste selected text for review"))
                    .disabled(model.busy || loadingPhoto || model.closed)
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Label(captureText("Read text from a selected photo"), systemImage: "photo")
                }.disabled(model.busy || loadingPhoto || model.closed)
                if model.listening {
                    Button(captureText("Stop recording and review")) { model.stopSpeech() }
                        .accessibilityIdentifier("capture.stopSpeech")
                } else if model.busy {
                    Button(captureText("Cancel capture")) { model.stopSpeech() }
                } else {
                    Button { model.startSpeech() } label: {
                        Label(captureText("Dictate on this iPhone"), systemImage: "mic")
                    }.disabled(loadingPhoto || model.closed).accessibilityIdentifier("capture.startSpeech")
                }
                if model.busy || loadingPhoto {
                    ProgressView(captureText(model.listening ? "Listening — tap Stop when finished" : "Preparing text for review…"))
                }
                Text(captureText("Recording stops after 45 seconds. Raw audio is not saved. Unsupported speech languages keep the typed path available."))
                    .font(.footnote)
            }
            if let failure = model.failure {
                Section { Text(failureText(failure)).accessibilityIdentifier("capture.error") }
            }
            Section {
                Toggle(captureText("I checked the wording, amounts, units and exclusions."), isOn: $model.confirmed)
                    .disabled(model.busy || loadingPhoto || model.candidate != nil || model.closed)
                Button(captureText("Continue to list review")) {
                    guard let capture = model.reviewed() else { return }
                    onReviewed(capture)
                    dismiss()
                }.disabled(!model.canContinue || loadingPhoto).accessibilityIdentifier("capture.continue")
                Text(captureText("The next screen reviews parsed quantities and duplicates. Captured text does not verify a price, a safe ingredient, a paid receipt or what arrived."))
                    .font(.footnote)
            }
        }
        .navigationTitle(captureText("Capture a list"))
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(captureText("Cancel")) { close(); dismiss() }
        } }
        .onChange(of: photo) { _, item in load(item) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close(); dismiss() } }
        .onDisappear { close() }
    }

    @ViewBuilder private func evidence(_ value: CaptureEvidence) -> some View {
        if let data = value.previewImageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 250)
                .accessibilityLabel(captureText("Selected source photo. Recognized wording is shown below."))
        }
        Text(value.text.isEmpty ? captureText("No words recognized yet") : value.text).textSelection(.enabled)
        if !value.uncertainLines.isEmpty {
            Label(captureText("Some wording was uncertain. Compare it with the source and correct it."), systemImage: "questionmark.circle")
            ForEach(Array(value.uncertainLines.enumerated()), id: \.offset) { _, line in Text(line).font(.footnote) }
        }
    }
    private func load(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        guard let item, !model.closed else { return }
        loadingPhoto = true
        photoTask = Task { @MainActor in
            defer { if photo == item { loadingPhoto = false } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CaptureFailure.imageUnavailable }
                guard !Task.isCancelled, photo == item, !model.closed else { return }
                model.stageImage(data)
            } catch {
                if !Task.isCancelled, !model.closed { model.photoLoadFailed() }
            }
        }
    }
    private func close() { photoTask?.cancel(); photoTask = nil; model.close() }
    private func failureText(_ failure: CaptureFailure) -> String {
        switch failure {
        case .notConfigured: return captureText("Speech is not available in this build. Type or paste your list instead.")
        case .permissionDenied: return captureText("Microphone or speech permission was not granted. Your typed draft is unchanged; typing, paste and photo review remain available.")
        case .onDeviceUnavailable: return captureText("On-device recognition is unavailable for this language or device. Type or paste instead; there is no online speech fallback.")
        case .audioUnavailable: return captureText("The microphone is unavailable. Stop another recording or type your list.")
        case .recognitionFailed: return captureText("Recognition could not finish. Review any captured wording or keep typing. Your saved pickup is unchanged.")
        case .imageUnavailable: return captureText("This photo could not be read. Choose another image or type the text.")
        case .inputTooLarge: return captureText("Use at most 200 lines and 20,000 characters, or choose a photo under 12 MB and 30 megapixels.")
        case .noText: return captureText("No readable text was found. Choose a clearer photo or type the text.")
        }
    }
}
