import SwiftUI
import PhotosUI
import CoreDomain

func captureText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Capture") }

/// Returns a reviewed draft to the staged ledger import; never commits a list or sends its content to a service.
@MainActor struct CaptureReviewView: View {
    @StateObject private var model: CaptureModel
    @StateObject private var corrections = CaptureCorrectionsModel()
    @State private var structuredLines: [CaptureLineDraft] = []
    @State private var reviewingFields = false
    @State private var guestDetected = false
    @State private var structuredFailure = false
    let destination: String
    let requestMode: Bool
    let dismissOnReview: Bool
    let correctionScope: CaptureCorrectionScope?
    let authorize: () -> Bool
    let onReviewed: (ReviewedCapture) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @AccessibilityFocusState private var reviewFocused: Bool
    @AccessibilityFocusState private var capturedTextFocused: Bool
    @FocusState private var sourceTextFocused: Bool
    @FocusState private var structuredFieldFocus: StructuredCaptureField?

    init(initialText: String = "", initialSource: CaptureSource = .typed, localeIdentifier: String = CaptureCorrectionScope.appLanguage(),
         destination: String = captureText("This pickup"), requestMode: Bool = false, dismissOnReview: Bool = true, existingCapture: ReviewedCapture? = nil, correctionScope: CaptureCorrectionScope? = nil,
         authorize: @escaping () -> Bool, onReviewed: @escaping (ReviewedCapture) -> Void) {
        let evidence = existingCapture.map { CaptureEvidence(text: $0.originalText, source: $0.source,
            uncertainLines: [], sourceImageData: $0.sourceImageData, previewImageData: $0.previewImageData) }
            ?? (initialSource == .paste && !initialText.isEmpty ? CaptureEvidence(text: initialText, source: .paste,
                uncertainLines: [], sourceImageData: nil, previewImageData: nil) : nil)
        let model = CaptureModel(initialText: existingCapture?.text ?? initialText, localeIdentifier: localeIdentifier,
            id: existingCapture?.id ?? UUID(), speech: OnDeviceSpeechCapture(), ocr: OnDeviceTextCapture(), initialEvidence: evidence)
        if existingCapture != nil { model.confirmed = true }
        _model = StateObject(wrappedValue: model)
        _structuredLines = State(initialValue: existingCapture?.fieldDrafts ?? [])
        _reviewingFields = State(initialValue: existingCapture?.fieldDrafts != nil)
        self.onReviewed = onReviewed
        self.destination = destination; self.requestMode = requestMode; self.dismissOnReview = dismissOnReview; self.correctionScope = correctionScope; self.authorize = authorize
    }

    var body: some View {
        ScrollViewReader { scroll in
            captureForm(scroll)
                .task(id: reviewingFields) {
                    guard reviewingFields else { return }
                    await Task.yield()
                    guard !Task.isCancelled, reviewingFields, authorize() else { return }
                    scroll.scrollTo(StructuredCaptureReviewView.originalAnchor, anchor: .top)
                }
                .onChange(of: model.candidate != nil && !model.busy) { _, ready in
                    guard ready else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard authorize(), model.candidate != nil, !model.busy, !reviewingFields else { return }
                        scroll.scrollTo("capture.useText", anchor: .center)
                        capturedTextFocused = true
                    }
                }
        }
    }

    private func captureForm(_ scroll: ScrollViewProxy) -> some View {
        Form {
            if reviewingFields {
                StructuredCaptureReviewView(lines: $structuredLines, corrections: corrections, correctionScope: correctionScope,
                    fieldFocus: $structuredFieldFocus, destination: destination,
                    source: model.acceptedEvidence?.source ?? .typed, context: requestMode ? .request : .list, originalText: model.acceptedEvidence?.text ?? model.text,
                    imageData: model.acceptedEvidence?.previewImageData ?? model.acceptedEvidence?.sourceImageData,
                    authorize: authorize, onBack: { reviewingFields = false }) { lines in
                        guard authorize(), let capture = model.reviewed(lines: lines, fieldDrafts: structuredLines) else { return }
                        onReviewed(capture); if dismissOnReview { dismiss() }
                    }
            } else {
            Section {
                Text(captureText(requestMode ? "Capture is optional. You can always type your request." : "Capture is optional. You can always type your list."))
                Text(captureText(requestMode ? "Speech and photo text recognition run on this iPhone. Review the request before sending." :
                    "Speech and photo text recognition run on this iPhone. Nothing is added until you review the list."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(captureText("Actual destination") + ": " + destination)
            }
            if let candidate = model.candidate {
                Section(captureText("Captured wording — check before using")) {
                    evidence(candidate)
                    if !model.busy {
                        Button(captureText("Use captured text")) { model.acceptCandidate(); reviewFocused = true }
                            .accessibilityIdentifier("capture.useText")
                            .id("capture.useText").accessibilityFocused($capturedTextFocused)
                        Button(captureText("Keep my typed draft")) { model.discardCandidate() }
                    }
                }
            }
            Section(captureText(requestMode ? "Your editable request" : "Your editable list")) {
                Text(captureText(requestMode ? "Review one request at a time. Check the item, amount, packs, purpose and exclusions; skip any other captured lines." : "One item per line. Check item names, amounts, units and any exclusions."))
                TextEditor(text: $model.text).frame(minHeight: 180)
                    .focused($sourceTextFocused)
                    .accessibilityLabel(captureText(requestMode ? "Request text to review" : "List text to review"))
                    .id("capture.editor")
                    .accessibilityIdentifier("capture.editor")
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
                PasteButton(payloadType: String.self) { values in
                    Task { @MainActor in
                        if authorize() && !loadingPhoto { model.stagePaste(values) }
                    }
                }
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
                Section {
                    Text(failureText(failure)).accessibilityIdentifier("capture.error")
                    if failure == .permissionDenied || failure == .onDeviceUnavailable || failure == .audioUnavailable || failure == .notConfigured {
                        Button(captureText("Type item")) {
                            scroll.scrollTo("capture.editor", anchor: .center)
                            sourceTextFocused = true
                            reviewFocused = true
                        }.accessibilityIdentifier("capture.typeItem")
                    }
                }
            }
            Section {
                Toggle(captureText("I checked the wording, amounts, units and exclusions."), isOn: $model.confirmed)
                    .disabled(model.busy || loadingPhoto || model.candidate != nil || model.closed)
                Button(captureText("Review captured fields")) { stageFields() }
                    .disabled(!model.canContinue || loadingPhoto || !authorize()).accessibilityIdentifier("capture.reviewFields")
                if guestDetected {
                    Text(captureText("This may be a guest change. Open Guests and protected portions to choose the meal, group and new total before previewing."))
                    Button(captureText("This is grocery wording — review it as items")) { stageFields(explicitlyTreatAsItems: true) }
                }
                if structuredFailure { Text(captureText("The draft could not be parsed. Keep typing or shorten the list, then review again.")) }
                Text(captureText("The next screen reviews parsed quantities and duplicates. Captured text does not verify a price, a safe ingredient, a paid receipt or what arrived."))
                    .font(.footnote)
            }
            }
        }
        .navigationTitle(captureText(requestMode ? "Capture a request" : "Capture a list"))
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: sourceTextFocused || structuredFieldFocus != nil, title: captureText("Done"),
                            identifier: sourceTextFocused ? "capture.sourceDone" : "capture.itemNameDone") {
            sourceTextFocused = false
            structuredFieldFocus = nil
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(captureText("Cancel")) { close(); dismiss() }
        } }
        .task(id: correctionScope) { await corrections.bind(correctionScope) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !authorize() { close(); dismiss(); return }
            }
        }
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
        guard let item, !model.closed else { loadingPhoto = false; return }
        loadingPhoto = true
        photoTask = Task { @MainActor in
            defer {
                if photo == item {
                    loadingPhoto = false
                    // Let the shopper choose this asset again after reviewing or retrying it.
                    photo = nil
                }
            }
            do {
                guard let selected = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw CaptureFailure.imageUnavailable }
                guard !Task.isCancelled, photo == item, !model.closed, authorize() else { return }
                model.stageImage(try selected.data)
            } catch {
                guard !Task.isCancelled, photo == item, !model.closed, authorize() else { return }
                model.photoLoadFailed(error as? ScanFailure == .tooLarge ? .inputTooLarge : .imageUnavailable)
            }
        }
    }
    private func stageFields(explicitlyTreatAsItems: Bool = false) {
        guard model.canContinue, authorize() else { return }
        do {
            structuredLines = try StructuredCaptureParser.lines(model.text, destination: destination, explicitlyTreatAsItems: explicitlyTreatAsItems)
            reviewingFields = true; guestDetected = false; structuredFailure = false
        } catch StructuredCaptureFailure.guestReviewRequired { guestDetected = true }
        catch { structuredFailure = true }
    }
    private func close() { photoTask?.cancel(); photoTask = nil; model.close(); corrections.invalidate(); structuredLines = [] }
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
