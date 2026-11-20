import SwiftUI
import PhotosUI
import CoreDomain

/// Retain the scoped source editor beneath the privacy cover while iOS asks about the camera.
@MainActor private struct SourceCameraPermission: DynamicProperty {
    let recipeScope: RecipeCameraPromptScope?
    @Environment(\.pantryDigestPermissionPrompt) private var pantryPrompt
    @Environment(\.pantryVoicePrompt) private var pantryWindow
    @Environment(\.recipeCameraPermissionPrompt) private var recipePrompt

    init(recipeScope: RecipeCameraPromptScope? = nil) { self.recipeScope = recipeScope }

    func retains(_ target: CaptureTarget) -> Bool {
        if let recipeScope, let recipePrompt, recipePrompt.scope == recipeScope {
            return recipePrompt.holdsPresentation()
        }
        return target.kind == .receiptEvidence && pantryPrompt?.scope.origin == target.workspaceID && pantryWindow?.holdsPresentation() == true
    }

    func request(for target: CaptureTarget) async throws {
        if let recipeScope {
            guard let recipePrompt, recipePrompt.scope == recipeScope else { throw ScanFailure.stale }
            try await CameraCapturePermission.request(presenting: recipePrompt.present)
            return
        }
        let pantryOrigin = target.kind == .receiptEvidence ? target.workspaceID : nil
        try await CameraCapturePermission.request(presenting: pantryPrompt?.presenter(for: pantryOrigin))
    }
}

@MainActor struct ScanReviewView: View {
    private enum InputField: Hashable {
        case sourceText, manualCode, sourceLabel
        case recipeTitle, servings, sourceURL, instructions, ingredients
        case receiptWording(UUID), receiptQuantity(UUID), receiptPrice(UUID)
    }

    let kind: ScanKind
    let target: CaptureTarget
    let authorize: () -> Bool
    let onReviewed: (ReviewedScan) -> Void
    let correctionScope: CaptureCorrectionScope?
    private let focusReceiptText: Bool
    private var cameraPermission: SourceCameraPermission
    @StateObject private var model = ScanModel()
    @StateObject private var corrections = CaptureCorrectionsModel()
    @State private var label: String
    @State private var photo: PhotosPickerItem?
    @State private var photoTask: Task<Void, Never>?
    @State private var loadingPhoto = false
    @State private var showCamera = false
    @State private var localPhotoConsent = false
    @State private var requestingCamera = false
    @State private var permissionGeneration = UUID()
    @State private var barcodeID: String?
    @State private var manualCode = ""
    @State private var matchedProduct = false
    @State private var inspectedLineID: UUID?
    @State private var receiptLines: [ScanReceiptLine]?
    @State private var recipe: RecipeCaptureDraft?
    @State private var ingredients: [CaptureLineDraft] = []
    @State private var reviewingIngredients = false
    @State private var error: String?
    @State private var storeFocusRequest: UUID?
    @FocusState private var focusedField: InputField?
    @AccessibilityFocusState private var capturedWordingFocused: Bool
    @FocusState private var structuredFieldFocus: StructuredCaptureField?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(kind: ScanKind, target: CaptureTarget, initialLabel: String = "",
         correctionScope: CaptureCorrectionScope? = nil, recipeCameraScope: RecipeCameraPromptScope? = nil,
         focusReceiptText: Bool = false,
         authorize: @escaping () -> Bool,
         onReviewed: @escaping (ReviewedScan) -> Void) {
        self.kind = kind; self.target = target; self.authorize = authorize; self.onReviewed = onReviewed
        self.correctionScope = correctionScope; _label = State(initialValue: initialLabel)
        self.focusReceiptText = focusReceiptText
        cameraPermission = SourceCameraPermission(recipeScope: recipeCameraScope)
    }
    var body: some View {
        ScrollViewReader { scroll in
            scanForm(scroll)
                .task {
                    guard focusReceiptText, kind == .receipt, authorize() else { return }
                    await Task.yield()
                    guard !Task.isCancelled, authorize() else { return }
                    focusSourceText(scroll)
                }
                .task(id: model.candidate != nil && !model.busy) {
                    guard model.candidate != nil, !model.busy else { return }
                    await Task.yield()
                    guard !Task.isCancelled, authorize(), model.candidate != nil else { return }
                    scroll.scrollTo("scan.capturedWording", anchor: .top)
                    capturedWordingFocused = true
                }
        }
    }

    private func scanForm(_ scroll: ScrollViewProxy) -> some View {
        WorkingForm {
            if reviewingIngredients {
                StructuredCaptureReviewView(lines: $ingredients, corrections: corrections, correctionScope: correctionScope,
                    fieldFocus: $structuredFieldFocus,
                    destination: captureText("This recipe"), source: model.source, context: .recipe, originalText: model.originalText,
                    imageData: model.accepted?.originalImageData, authorize: authorize,
                    onBack: { reviewingIngredients = false }, onContinue: finishRecipe)
            } else if recipe != nil {
                recipeFields
            } else {
                if kind != .receipt { captureControls }
                if let failure = model.failure {
                    Section {
                        Text(failureText(failure))
                        if failure == .permissionDenied || failure == .unavailable {
                            if kind == .receipt {
                                receiptPhotoPicker("Choose photo or screenshot")
                                Button(captureText("Type receipt lines")) { focusSourceText(scroll) }
                                    .accessibilityIdentifier("scan.receipt.recoveryType")
                            } else {
                                Button(captureText("Type item")) { focusSourceText(scroll) }
                                    .accessibilityIdentifier("scan.typeItem")
                            }
                        }
                    }
                }
                if let candidate = model.candidate {
                    Section(captureText("Captured source — review before using")) {
                        sourceImage(candidate.originalImageData)
                        Text(candidate.originalText.isEmpty ? captureText("No readable text. You can type it below.") : candidate.originalText)
                            .textSelection(.enabled)
                            .id("scan.capturedWording")
                            .accessibilityFocused($capturedWordingFocused)
                        if !candidate.barcodes.isEmpty {
                            Text(captureText("A readable barcode is only a code. Match the product yourself."))
                            ForEach(candidate.barcodes) { code in Text(code.value).textSelection(.enabled) }
                        }
                        Button(captureText("Use this source for review")) { model.acceptCandidate(); resetDerived() }
                        Button(captureText("Keep my current draft")) { model.discardCandidate() }
                    }
                }
                let sourceLabel = kind == .receipt ? captureText("Type or paste receipt lines") : captureText("Editable source text")
                Section(sourceLabel) {
                    TextEditor(text: $model.text).frame(minHeight: 150)
                        .overlay(alignment: .topLeading) {
                            if kind == .receipt, model.text.isEmpty {
                                Text(captureText("Enter one printed line per row."))
                                    .foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(sourceLabel)
                        .id("scan.sourceEditor")
                        .accessibilityIdentifier("scan.sourceEditor")
                        .focused($focusedField, equals: .sourceText)
                        .disabled(model.busy || loadingPhoto)
                    if kind == .receipt { pasteSourceButton }
                    if let source = model.accepted {
                        DisclosureGroup(captureText("Compare with the original")) {
                            sourceImage(source.originalImageData)
                            Text(source.originalText).textSelection(.enabled)
                            if !source.uncertainLines.isEmpty { Text(captureText("Some wording was uncertain. Compare it with the source and correct it.")) }
                        }
                    }
                }
                if kind == .recipe {
                    if let photo = model.accepted, localPhotoConsent {
                        let source = model.text
                        let lines = source.components(separatedBy: "\n")
                        AssistedImageLines(wording: lines, image: photo.referenceJPEG, purpose: .recipe, authorized: {
                            authorize() && localPhotoConsent && model.accepted == photo && model.text == source
                        }) { index, reading in
                            try model.applyRecipeImageReading(reading, line: index, reviewedText: source, source: photo)
                        }
                    }
                    Button(captureText("Review recipe fields")) {
                        do { recipe = try RecipeOCRParser.draft(model.text); error = nil }
                        catch { self.error = captureText("Shorten the text or type the source again, then review.") }
                    }.disabled(!canReview || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if kind == .receipt {
                    receiptFields(scroll)
                    captureControls
                } else {
                    packageFields
                }
            }
            if let error { Section { Text(error).accessibilityIdentifier("scan.error") } }
            if (reviewingIngredients || recipe != nil), let failure = model.failure {
                Section { Text(failureText(failure)) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focusedField != nil || structuredFieldFocus != nil, title: captureText("Done"), identifier: "scan.sourceDone") {
            focusedField = nil
            structuredFieldFocus = nil
        }
        .navigationTitle(captureText(kind == .receipt ? "Review printed lines" : "Photo and scan review"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { close(); dismiss() } } }
        .sheet(isPresented: Binding(get: { inspectedLineID != nil }, set: { if !$0 { inspectedLineID = nil } })) {
            if authorize(), !model.closed, let rows = receiptLines,
               let index = rows.firstIndex(where: { $0.id == inspectedLineID }) {
                NavigationStack {
                    ReceiptPrintedLineInspector(lines: rows.enumerated().map { offset, row in
                        ReceiptDocumentPage.Line(id: offset + 1, text: row.originalText, uncertain: row.uncertainOCR == true)
                    }, pageNumber: nil, index: index, originalPage: {
                        authorize() ? model.accepted?.originalImageData : nil
                    })
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(authorize: authorize) { result in
                showCamera = false
                guard localPhotoConsent, authorize(), !model.closed else { return }
                switch result {
                case .success(let data): model.stage(data)
                case .failure(let failure): model.inputFailed(failure)
                case nil: break
                }
            }.ignoresSafeArea()
        }
        .onChange(of: photo) { _, value in loadPhoto(value) }
        .onChange(of: localPhotoConsent) { _, allowed in
            if !allowed {
                permissionGeneration = UUID(); requestingCamera = false; showCamera = false
                photoTask?.cancel(); photoTask = nil; photo = nil; loadingPhoto = false
                let acceptedPhoto = model.accepted != nil
                model.revokePhotoConsent()
                if acceptedPhoto { resetDerived() }
            }
        }
        .onChange(of: model.text) { _, _ in inspectedLineID = nil; receiptLines = nil; matchedProduct = false }
        .onChange(of: label) { _, _ in model.confirmed = false; matchedProduct = false }
        .onChange(of: barcodeID) { _, selection in
            if selection != nil { manualCode = "" }
            model.confirmed = false; matchedProduct = false
        }
        .onChange(of: manualCode) { _, _ in
            if !trimmedManualCode.isEmpty { barcodeID = nil }
            model.confirmed = false; matchedProduct = false
        }
        .onChange(of: receiptLines) { _, _ in model.confirmed = false }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close(); dismiss() } }
        .task(id: correctionScope) { await corrections.bind(correctionScope) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !authorize() && !cameraPermission.retains(target) { close(); dismiss(); return }
            }
        }
        .onDisappear { if !showCamera { close() } }
    }
    private var canReview: Bool { authorize() && !model.closed && !model.busy && !loadingPhoto && !requestingCamera && model.candidate == nil }
    private func focusSourceText(_ scroll: ScrollViewProxy) {
        scroll.scrollTo("scan.sourceEditor", anchor: .center)
        focusedField = .sourceText
    }
    private func receiptPhotoPicker(_ title: String) -> some View {
        PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
            Text(captureText(title))
        }.disabled(!canReview || !localPhotoConsent)
    }
    private var pasteSourceButton: some View {
        PasteButton(payloadType: String.self) { values in
            Task { @MainActor in
                guard canReview else { return }
                if model.paste(values) { resetDerived() }
            }
        }.disabled(!canReview)
            .accessibilityLabel(captureText("Paste source text"))
    }
    private var captureControls: some View {
        Section(captureText("Optional camera or selected photo")) {
            Text(captureText("You can always type. A photo or scan never confirms a price, payment, arrival or safe ingredient."))
            Toggle(captureText("Allow on-device photo processing for this review"), isOn: $localPhotoConsent)
                .accessibilityIdentifier("scan.localConsent")
            Text(captureText("Turning off photo processing discards text from the photo and edits to it. Your earlier typed or pasted text returns."))
                .font(.footnote)
            Text(captureText("This iPhone reads the photo. Choosing an iCloud photo may download it through Apple. If you use online help, you choose which text or image crop to send."))
                .font(.footnote)
            Button(captureText("Take a photo for review")) { requestCamera() }.disabled(!canReview || !localPhotoConsent)
                .accessibilityIdentifier("scan.camera")
            receiptPhotoPicker("Choose one photo for review")
            if kind != .receipt { pasteSourceButton }
            if model.busy || loadingPhoto || requestingCamera { ProgressView(captureText("Preparing source for review…")) }
            Text(captureText("Saved photo references are smaller copies without location metadata. The app keeps them separate from your photo library."))
                .font(.footnote)
        }
    }
    private var packageFields: some View {
        Section(captureText("Manual product match")) {
            TextField(captureText("Product label you checked"), text: $label)
                .focused($focusedField, equals: .sourceLabel)
            if let codes = model.accepted?.barcodes, !codes.isEmpty {
                Picker(captureText("Choose a code to inspect"), selection: $barcodeID) {
                    Text(captureText("Choose explicitly")).tag(nil as String?)
                    ForEach(codes) { Text($0.value).tag(Optional($0.id)) }
                }
            }
            TextField(captureText("Code typed from the package, optional"), text: $manualCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("scan.manualCode")
                .focused($focusedField, equals: .manualCode)
            if kind == .barcode {
                Text(captureText("Choose a detected code or type the code from the package before saving."))
            }
            Text(captureText("No product catalog is queried. Unknown codes need your manual match. A matching name or code does not verify ingredients, allergens or a price."))
            Toggle(captureText("I matched this source to the displayed product myself."), isOn: $matchedProduct)
            Toggle(captureText("I reviewed the source and want to keep this reference."), isOn: $model.confirmed)
            Button(captureText("Continue with reviewed reference")) { finishEvidence() }
                .disabled(!canReview || !matchedProduct || !model.confirmed ||
                    (kind == .barcode && reviewedBarcode == nil) || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("scan.reference.review")
        }
    }
    private func receiptFields(_ scroll: ScrollViewProxy) -> some View {
        let storeIssue = receiptStoreIssue(label)
        let storeLabel = captureText("Store or receipt name (required)")
        return Section(captureText("Receipt lines are evidence only")) {
            Text(captureText("Keep unreadable quantities or printed amounts unknown. These lines do not mark anything paid, received or usable."))
            WorkingField(storeLabel) {
                TextField(storeLabel, text: $label, prompt: Text(""))
                    .focused($focusedField, equals: .sourceLabel)
                    .accessibilityIdentifier("scan.receipt.store")
            }
            .id("scan.receipt.store")
            .task(id: storeFocusRequest) {
                guard let request = storeFocusRequest else { return }
                await Task.yield()
                guard !Task.isCancelled, storeFocusRequest == request, canReview else { return }
                focusedField = .sourceLabel
                storeFocusRequest = nil
            }
            if receiptLines == nil {
                Button(captureText("Review printed lines")) {
                    do { receiptLines = try ScanLimits.receiptLines(model.text, uncertain: Set(model.accepted?.uncertainLines ?? [])); error = nil }
                    catch { self.error = captureText("Shorten the text or type the source again, then review.") }
                }.disabled(!canReview || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                ForEach(receiptLines ?? []) { snapshot in
                    let row = captureDraftBinding(ScanReceiptLine(id: snapshot.id, originalText: ""), in: receiptBinding)
                    VStack(alignment: .leading) {
                        Text(row.wrappedValue.originalText)
                            .font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                        Button {
                            focusedField = nil
                            inspectedLineID = snapshot.id
                        } label: { Label(pantryText("Original lines"), systemImage: "text.magnifyingglass").frame(minHeight: 44) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("scan.receipt.inspect.\(snapshot.id)")
                        TextField(captureText("Reviewed line wording"), text: row.reviewedText, axis: .vertical)
                            .focused($focusedField, equals: .receiptWording(snapshot.id))
                        let quantityLabel = captureText("Printed quantity (optional)")
                        WorkingField(quantityLabel) {
                            TextField(quantityLabel, text: row.quantityNote, prompt: Text(""))
                                .focused($focusedField, equals: .receiptQuantity(snapshot.id))
                        }
                        let priceLabel = captureText("Printed amount (optional)")
                        WorkingField(priceLabel) {
                            TextField(priceLabel, text: row.priceNote, prompt: Text(""))
                                .focused($focusedField, equals: .receiptPrice(snapshot.id))
                        }
                    }
                }
                Toggle(captureText("I reviewed these lines as source evidence only."), isOn: $model.confirmed)
                if let storeIssue {
                    Button {
                        storeFocusRequest = UUID()
                        scroll.scrollTo("scan.receipt.store", anchor: .center)
                    } label: {
                        Label(storeIssue, systemImage: "exclamationmark.circle")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("scan.receipt.storeIssue")
                    .disabled(!canReview)
                } else if !model.confirmed {
                    Text(captureText("Check that you reviewed the printed lines to continue."))
                        .foregroundStyle(Theme.secondary)
                }
                Button(captureText("Continue with reviewed reference")) { finishEvidence() }
                    .buttonStyle(PrimaryAction())
                    .disabled(!canReview || !model.confirmed || receiptLines?.isEmpty != false || storeIssue != nil)
                    .accessibilityIdentifier("scan.receipt.review")
            }
        }
    }
    private var recipeFields: some View {
        Section(captureText("Editable recipe review")) {
            Text(captureText("Review the title, servings and ingredients. Accepting this draft does not choose a dinner or add groceries."))
            TextField(captureText("Recipe title"), text: recipeField(\.title))
                .focused($focusedField, equals: .recipeTitle)
            TextField(captureText("Reviewed servings"), text: recipeField(\.servings)).keyboardType(.numbersAndPunctuation)
                .focused($focusedField, equals: .servings)
            TextField(captureText("Source URL, attribution only"), text: recipeField(\.sourceURL)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: .sourceURL)
            Text(captureText("The source URL is saved as attribution. It is never fetched, and the recipe stays editable if the page disappears."))
            TextField(captureText("Recipe notes and instructions"), text: recipeField(\.notes), axis: .vertical)
                .focused($focusedField, equals: .instructions)
            Text(captureText("Ingredient wording, one per line"))
            TextEditor(text: recipeField(\.ingredientText)).frame(minHeight: 140).accessibilityLabel(captureText("Ingredient wording, one per line"))
                .focused($focusedField, equals: .ingredients)
            if recipe?.notes.isEmpty == false {
                Toggle(captureText("Use each instruction line as a cooking step"), isOn: Binding(
                    get: { recipe?.useInstructionLines ?? false }, set: { recipe?.useInstructionLines = $0 }
                ))
            }
            if let current = recipe, !current.instructionLines.isEmpty {
                NavigationLink(recordsText("Review ingredients and timers by step")) {
                    RecipeStepReviewView(steps: current.stepEdits.current(instructions: current.instructionLines, ingredients: current.ingredientLines),
                                         ingredients: current.ingredientLines) { index, step in
                        recipe?.stepEdits.apply(step, at: index, instructions: current.instructionLines, ingredients: current.ingredientLines)
                    }
                }
            }
            if let text = recipe?.unclassifiedText, !text.isEmpty {
                Text(captureText("Unclassified source wording — copy only what belongs in the recipe"))
                Text(text).textSelection(.enabled)
            }
            Toggle(captureText("I reviewed the recipe title, servings, source, notes and ingredient wording."), isOn: Binding(get: { recipe?.confirmed ?? false }, set: { recipe?.confirmed = $0 }))
            Button(captureText("Review ingredient quantities and exclusions")) {
                do {
                    ingredients = try StructuredCaptureParser.lines(recipe?.ingredientText ?? "", destination: captureText("This recipe"), explicitlyTreatAsItems: true)
                    guard !ingredients.isEmpty else { throw ScanFailure.needsReview }
                    reviewingIngredients = true; error = nil
                } catch { self.error = captureText("Review every ingredient or type a shorter list. No dinner has been saved.") }
            }.disabled(recipe?.confirmed != true || !canReview)
            Button(captureText("Back to source wording")) { recipe = nil; ingredients = [] }
        }
    }
    private func finishRecipe(_ lines: [CaptureImportLine]) {
        guard authorize(), let recipe else { return }
        do {
            let original = model.originalText.isEmpty ? model.text : model.originalText
            let source: RecipeSourceKind = model.source == .photoOCR && !model.originalText.isEmpty ? .photoOCR : model.source == .paste ? .pasted : .typed
            let template = try recipe.template(captureID: model.id, target: target, originalText: original, kind: source,
                hasImage: model.accepted != nil, reviewedIngredients: lines)
            model.confirmed = true
            let record = try model.reviewed(target: target, label: recipe.title, barcode: nil)
            onReviewed(.recipe(template, record)); dismiss()
        } catch { self.error = captureText("Check the title, positive servings, source URL and every ingredient. No dinner has been saved.") }
    }
    private func finishEvidence() {
        guard authorize() else { return }
        if kind == .receipt, receiptStoreIssue(label) != nil { return }
        do {
            guard (kind == .receipt && target.kind == .receiptEvidence) || ((kind == .packageReference || kind == .barcode) && target.kind == .packageReference) else { throw ScanFailure.stale }
            let barcode = reviewedBarcode
            if kind == .barcode, barcode == nil { throw ScanFailure.needsReview }
            let record = try model.reviewed(target: target, label: label, barcode: barcode, receiptLines: receiptLines ?? [])
            onReviewed(.evidence(record)); dismiss()
        } catch {
            self.error = kind == .receipt
                ? captureText("Check the store name and the printed lines, then try again.")
                : captureText("Check the source, choose or type a code when scanning, and confirm the manual match. Nothing has been saved.")
        }
    }
    private var trimmedManualCode: String { manualCode.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var reviewedBarcode: CapturedBarcode? {
        if !trimmedManualCode.isEmpty { return CapturedBarcode(symbology: "manual", value: trimmedManualCode) }
        return model.accepted?.barcodes.first { $0.id == barcodeID }
    }
    private func recipeField(_ path: WritableKeyPath<RecipeCaptureDraft, String>) -> Binding<String> {
        Binding(get: { recipe?[keyPath: path] ?? "" }, set: { recipe?[keyPath: path] = $0 })
    }
    private var receiptBinding: Binding<[ScanReceiptLine]> {
        Binding(get: { receiptLines ?? [] }, set: { value in
            guard receiptLines != nil else { return }; receiptLines = value
        })
    }
    @ViewBuilder private func sourceImage(_ data: Data) -> some View {
        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).accessibilityLabel(captureText("Selected source photo")) }
    }
    private func requestCamera() {
        guard localPhotoConsent, canReview else { return }; requestingCamera = true; let attempt = UUID(); permissionGeneration = attempt
        Task { @MainActor in
            defer { if permissionGeneration == attempt { requestingCamera = false } }
            do {
                try await cameraPermission.request(for: target)
                guard localPhotoConsent, permissionGeneration == attempt, authorize(), !model.closed else { return }
                showCamera = true
            }
            catch { guard permissionGeneration == attempt, !model.closed else { return }; model.inputFailed(error as? ScanFailure ?? .unavailable) }
        }
    }
    private func loadPhoto(_ item: PhotosPickerItem?) {
        photoTask?.cancel(); guard localPhotoConsent, let item, !model.closed else { return }; loadingPhoto = true
        photoTask = Task { @MainActor in
            defer {
                if photo == item {
                    loadingPhoto = false
                    // Let the shopper choose this asset again after reviewing or retrying it.
                    photo = nil
                }
            }
            do {
                guard let selected = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                guard localPhotoConsent, !Task.isCancelled, photo == item, authorize(), !model.closed else { return }
                model.stage(try selected.data)
            } catch { if !Task.isCancelled, !model.closed { model.inputFailed(error as? ScanFailure ?? .invalidImage) } }
        }
    }
    private func resetDerived() { barcodeID = nil; manualCode = ""; receiptLines = nil; recipe = nil; ingredients = []; matchedProduct = false; model.confirmed = false }
    private func close() {
        permissionGeneration = UUID(); showCamera = false; storeFocusRequest = nil
        photoTask?.cancel(); photoTask = nil; model.close(); corrections.invalidate(); resetDerived()
    }
    private func failureText(_ value: ScanFailure) -> String {
        switch value {
        case .permissionDenied: return captureText("Camera permission was not granted. Type, paste or choose a photo instead.")
        case .tooLarge: return captureText("Choose a photo under 12 MB and 30 megapixels, and keep the text under 20,000 bytes and 200 lines.")
        default: return captureText("This capture is unavailable. Your typed draft is still usable; nothing has been added automatically.")
        }
    }
}

func receiptStoreIssue(_ value: String) -> String? {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return captureText("Enter the store or receipt name to continue.") }
    if name.utf8.count > 256 || name.contains("\0") { return captureText("Enter a shorter store or receipt name.") }
    return nil
}

/// The system picker grants access to the single chosen image. No library scan is needed.
struct ReceiptPhotoShortcuts: View {
    enum Start: String, Identifiable { case camera, screenshot, sections; var id: Self { self } }
    let target: CaptureTarget
    let authorize: @MainActor () -> Bool
    var reviewsPrivateReceipt = false
    let reviewed: (SourceMediaRecord) -> Void
    @State private var pickingScreenshot = false
    @State private var screenshot: PhotosPickerItem?
    @State private var start: Start?
    @State private var result: SourceMediaRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            imageButtons
            Button { start = .sections } label: {
                Label(captureText("Scan a long receipt in sections"), systemImage: "rectangle.stack")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("receipt.sections")
            Text(captureText("Only the photo you take or choose is read on this iPhone. Choosing an iCloud photo may download it through Apple."))
                .font(.footnote).foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!authorize())
        .photosPicker(isPresented: $pickingScreenshot, selection: $screenshot, matching: .images, preferredItemEncoding: .current)
        .onChange(of: screenshot) { _, _ in openPickedScreenshot() }
        .onChange(of: pickingScreenshot) { _, _ in openPickedScreenshot() }
        .sheet(item: $start, onDismiss: {
            if let result, authorize(), result.target == target { reviewed(result) }
            result = nil; screenshot = nil
        }) { choice in
            NavigationStack {
                ReceiptSectionCapture(start: choice, target: target, authorize: authorize, reviewsPrivateReceipt: reviewsPrivateReceipt, initialPhoto: screenshot) { source in
                    guard authorize(), source.target == target else { return }
                    // The document review dismisses this sheet after handing back its source.
                    result = source
                }
            }
        }
    }
    private func openPickedScreenshot() {
        guard !pickingScreenshot, screenshot != nil, start == nil, authorize() else { return }
        start = .screenshot
    }

    @ViewBuilder private var imageButtons: some View {
        Button { start = .camera } label: { sourceButton("Take a photo", symbol: "camera") }
            .accessibilityIdentifier("receipt.takePhoto")
        Button { pickingScreenshot = true } label: { sourceButton("Choose photo or screenshot", symbol: "photo") }
            .accessibilityIdentifier("receipt.chooseScreenshot")
    }

    private func sourceButton(_ title: String, symbol: String) -> some View {
        Label(captureText(title), systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .foregroundStyle(Theme.action)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.controlEdge) }
            .contentShape(Rectangle())
    }
}

private struct ReceiptSectionCapture: View {
    let start: ReceiptPhotoShortcuts.Start
    let target: CaptureTarget
    let authorize: @MainActor () -> Bool
    var reviewsPrivateReceipt = false
    var initialPhoto: PhotosPickerItem?
    let reviewed: (SourceMediaRecord) -> Void
    var cameraPermission = SourceCameraPermission()
    @State private var didStart = false
    @State private var draft = ReceiptSectionDraft()
    @State private var review: ExtractedReceiptDocument?
    @State private var omitted = Set<ExtractedReceiptDocument.Selection>()
    @State private var index = 0
    @State private var picker = false
    @State private var item: PhotosPickerItem?
    @State private var camera = false
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error: String?
    @State private var cameraNeedsAlternative = false
    @State private var typing = false
    @State private var typedSource: SourceMediaRecord?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene

    var body: some View {
        captureContent
            .privacySensitive()
            .photosPicker(isPresented: $picker, selection: $item, matching: .images, preferredItemEncoding: .current)
            .onChange(of: item) { _, selected in
                guard let selected else { return }
                read { guard let photo = try await selected.loadTransferable(type: ReceiptPhotoSelection.self) else { throw ReceiptDocumentFailure.unavailable }; return try photo.bytes }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraCaptureView(authorize: authorize, previousReceiptEdge: previousEdge) { result in
                    camera = false
                    switch result {
                    case .success(let data): read { ReceiptDocumentBytes(data: data, kind: .image) }
                    case .failure: showCameraRecovery()
                    case nil: break
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $typing, onDismiss: finishTypedSource) {
                NavigationStack {
                    ScanReviewView(kind: .receipt, target: target, focusReceiptText: true, authorize: authorize) { result in
                        if case .evidence(let source) = result, authorize(), source.target == target { typedSource = source }
                    }
                }
            }
            .onChange(of: scene) { _, phase in if phase == .background { clear(); dismiss() } }
            .onDisappear { if !camera && !picker && !typing { clear() } }
            .task {
                if !didStart, authorize() {
                    didStart = true
                    if start == .camera { openCamera(at: 0) }
                    else if start == .screenshot, let initialPhoto { item = initialPhoto }
                }
                while !Task.isCancelled {
                    guard authorize() || cameraPermission.retains(target) else { clear(); dismiss(); return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }

    private var captureContent: some View {
        VStack(spacing: 0) {
            if let review {
                PantryReceiptDocuments(target: target, authorize: authorize, reviewsPrivateReceipt: reviewsPrivateReceipt, initialDocument: review,
                    sectionPreviews: draft.sections.map(\.preview), omittedLines: omitted,
                    backToSections: start == .sections ? { self.review = nil; self.omitted = [] } : nil) { source, _ in
                    if authorize() { reviewed(source) }
                }
            } else {
                captureForm
            }
        }
    }

    private var captureForm: some View {
        WorkingForm {
            Text(captureText("Only the photo you take or choose is read on this iPhone. Choosing an iCloud photo may download it through Apple."))
            if start == .sections {
                Text(captureText("Capture from top to bottom. Include the last printed line again at the top of the next photo. Up to six sections, 10 MB per photo and 30 MB total."))
                ForEach(draft.sections.indices, id: \.self) { position in
                    photoSection(at: position)
                }
            }
            nextPhotoControls
            if !draft.sections.isEmpty {
                Button(captureText("Review receipt lines")) { beginReview() }
                    .disabled(draft.hasUnresolvedOverlap).accessibilityIdentifier("receipt.sections.review")
            }
            if let error { Text(error).accessibilityIdentifier("receipt.sections.error") }
            if cameraNeedsAlternative {
                Button(captureText("Choose photo or screenshot")) { picker = true }
                    .accessibilityIdentifier("receipt.cameraRecovery.photo")
                Button(captureText("Type receipt lines")) { typing = true }
                    .accessibilityIdentifier("receipt.cameraRecovery.type")
            }
            if job != nil { ProgressView(captureText("Preparing source for review…")) }
        }
        .disabled(job != nil || !authorize())
        .navigationTitle(captureText(start == .sections ? "Scan receipt sections" : "Receipt photo"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { clear(); dismiss() } } }
    }

    private func photoSection(at position: Int) -> some View {
        let section = draft.sections[position]
        return Section(captureText("Section") + " " + String(position + 1)) {
            if let preview = section.preview, let image = UIImage(data: preview) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                    .accessibilityLabel(captureText("Selected source photo"))
            }
            Text(section.page.lines.suffix(3).map(\.text).joined(separator: "\n")).textSelection(.enabled)
            Button(captureText("Retake this section")) { openCamera(at: position) }
            Button(captureText("Replace with a selected photo")) { index = position; picker = true }
            overlapPicker(at: position, section: section)
        }
    }

    @ViewBuilder private func overlapPicker(at position: Int, section: ReceiptSectionDraft.Section) -> some View {
        let overlaps = draft.likelyOverlaps(at: position)
        if !overlaps.isEmpty {
            Text(captureText("These lines may repeat the previous photo. Keep both if they were separate printed purchases."))
            Picker(captureText("Lines repeated from the previous section"), selection: Binding(
                get: { draft.omittedPrefixes[position] ?? -1 },
                set: { draft.resolve(at: position, omitting: $0) })) {
                Text(captureText("Choose explicitly")).tag(-1)
                Text(captureText("Keep all printed lines")).tag(0)
                ForEach(overlaps, id: \.self) { count in
                    Text(captureText("Omit repeated lines") + " (" + String(count) + "): " +
                         String(section.page.lines[count - 1].text.prefix(70))).tag(count)
                }
            }
        }
    }

    @ViewBuilder private var nextPhotoControls: some View {
        if draft.sections.count < ReceiptSectionDraft.maximumSections {
            if start != .screenshot {
                Button(captureText(start == .sections ? "Photograph next section" : "Take a photo")) {
                    openCamera(at: draft.sections.count)
                }
            }
            if start != .camera && !cameraNeedsAlternative {
                Button(captureText(start == .sections ? "Choose next section from Photos" : "Choose photo or screenshot")) {
                    index = draft.sections.count; picker = true
                }.accessibilityIdentifier("receipt.openSelectedPhoto")
            }
        }
    }

    private var previousEdge: CameraCaptureView.PreviousReceiptEdge? {
        guard start == .sections, index > 0, draft.sections.indices.contains(index - 1) else { return nil }
        let previous = draft.sections[index - 1]
        return .init(image: previous.preview, wording: previous.page.lines.last?.text ?? "")
    }

    private func openCamera(at position: Int) {
        guard authorize(), job == nil else { return }
        index = position
        let token = generation
        job = Task { @MainActor in
            defer { if token == generation { job = nil } }
            do {
                try await cameraPermission.request(for: target)
                guard !Task.isCancelled, token == generation, authorize() else { return }
                error = nil
                cameraNeedsAlternative = false
                camera = true
            } catch { if !Task.isCancelled, token == generation { showCameraRecovery() } }
        }
    }

    private func read(_ load: @escaping () async throws -> ReceiptDocumentBytes) {
        guard job == nil, authorize() else { return }
        let token = generation, position = index
        job = Task { @MainActor in
            defer { if token == generation { job = nil; item = nil } }
            do {
                let bytes = try await load()
                guard !Task.isCancelled, token == generation, authorize() else { return }
                let document = try await ReceiptDocumentReader().extract(bytes)
                guard !Task.isCancelled, token == generation, authorize() else { return }
                try draft.put(document, bytes: bytes.data.count, preview: ReceiptSectionDraft.preview(bytes.data), at: position)
                error = nil
                cameraNeedsAlternative = false
                if start != .sections { beginReview() }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = (error as? ReceiptDocumentFailure) == .duplicateSection
                    ? captureText("This photo is already in the receipt. Choose a different section or retake the original one.")
                    : captureText("No section was changed. Choose a readable photo under 10 MB and 25 megapixels, or type the lines.")
            }
        }
    }

    private func beginReview() {
        guard authorize(), let prepared = try? draft.review() else { return }
        omitted = prepared.omitted
        review = prepared.document
    }
    private func showCameraRecovery() {
        error = captureText("The camera is unavailable. Choose a photo or type the lines instead.")
        cameraNeedsAlternative = true
    }
    private func finishTypedSource() {
        guard authorize(), let typedSource, typedSource.target == target else { return }
        self.typedSource = nil
        reviewed(typedSource)
        dismiss()
    }
    private func clear() {
        generation = UUID(); job?.cancel(); job = nil
        draft = ReceiptSectionDraft(); item = nil; omitted = []; review = nil; error = nil; camera = false
        cameraNeedsAlternative = false; typing = false; typedSource = nil
    }
}
