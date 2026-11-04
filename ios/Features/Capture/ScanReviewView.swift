import SwiftUI
import PhotosUI
import CoreDomain

@MainActor struct ScanReviewView: View {
    private enum InputField: Hashable { case sourceText, manualCode }

    let kind: ScanKind
    let target: CaptureTarget
    let authorize: () -> Bool
    let onReviewed: (ReviewedScan) -> Void
    let correctionScope: CaptureCorrectionScope?
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
    @State private var receiptLines: [ScanReceiptLine]?
    @State private var recipe: RecipeCaptureDraft?
    @State private var ingredients: [CaptureLineDraft] = []
    @State private var reviewingIngredients = false
    @State private var error: String?
    @FocusState private var focusedField: InputField?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(kind: ScanKind, target: CaptureTarget, initialLabel: String = "",
         correctionScope: CaptureCorrectionScope? = nil, authorize: @escaping () -> Bool,
         onReviewed: @escaping (ReviewedScan) -> Void) {
        self.kind = kind; self.target = target; self.authorize = authorize; self.onReviewed = onReviewed
        self.correctionScope = correctionScope; _label = State(initialValue: initialLabel)
    }
    var body: some View {
        Form {
            if reviewingIngredients {
                StructuredCaptureReviewView(lines: $ingredients, corrections: corrections,
                    destination: captureText("This recipe"), source: model.source, context: .recipe, originalText: model.originalText,
                    imageData: model.accepted?.originalImageData, authorize: authorize,
                    onBack: { reviewingIngredients = false }, onContinue: finishRecipe)
            } else if recipe != nil {
                recipeFields
            } else {
                captureControls
                if let candidate = model.candidate {
                    Section(captureText("Captured source — review before using")) {
                        sourceImage(candidate.originalImageData)
                        Text(candidate.originalText.isEmpty ? captureText("No readable text. You can type it below.") : candidate.originalText).textSelection(.enabled)
                        Text(captureText("A readable barcode is only a code. Match the product yourself."))
                        ForEach(candidate.barcodes) { code in Text(code.value).textSelection(.enabled) }
                        Button(captureText("Use this source for review")) { model.acceptCandidate(); resetDerived() }
                        Button(captureText("Keep my current draft")) { model.discardCandidate() }
                    }
                }
                Section(captureText("Editable source text")) {
                    TextEditor(text: $model.text).frame(minHeight: 150).accessibilityLabel(captureText("Editable source text"))
                        .accessibilityIdentifier("scan.sourceEditor")
                        .focused($focusedField, equals: .sourceText)
                        .disabled(model.busy || loadingPhoto)
                    if let source = model.accepted {
                        DisclosureGroup(captureText("Compare with the original")) {
                            sourceImage(source.originalImageData)
                            Text(source.originalText).textSelection(.enabled)
                            if !source.uncertainLines.isEmpty { Text(captureText("Some wording was uncertain. Compare it with the source and correct it.")) }
                        }
                    }
                }
                if kind == .recipe {
                    Button(captureText("Review recipe fields")) {
                        do { recipe = try RecipeOCRParser.draft(model.text); error = nil }
                        catch { self.error = captureText("Shorten the text or type the source again, then review.") }
                    }.disabled(!canReview || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if kind == .receipt {
                    receiptFields
                } else {
                    packageFields
                }
            }
            if let error { Section { Text(error).accessibilityIdentifier("scan.error") } }
            if let failure = model.failure { Section { Text(failureText(failure)) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focusedField != nil, title: captureText("Done"), identifier: "scan.sourceDone") {
            focusedField = nil
        }
        .navigationTitle(captureText("Photo and scan review"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { close(); dismiss() } } }
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
        .onChange(of: model.text) { _, _ in receiptLines = nil; matchedProduct = false }
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
                if !authorize() { close(); dismiss(); return }
            }
        }
        .onDisappear { if !showCamera { close() } }
    }
    private var canReview: Bool { authorize() && !model.closed && !model.busy && !loadingPhoto && !requestingCamera && model.candidate == nil }
    private var captureControls: some View {
        Section(captureText("Optional camera or selected photo")) {
            Text(captureText("You can always type. A photo or scan never confirms a price, payment, arrival or safe ingredient."))
            Toggle(captureText("Allow on-device photo processing for this review"), isOn: $localPhotoConsent)
                .accessibilityIdentifier("scan.localConsent")
            Text(captureText("Turning off photo processing discards text from the photo and edits to it. Your earlier typed or pasted text returns."))
                .font(.footnote)
            Text(captureText("The app does not upload photos or source text. Choosing an iCloud photo may download it through Apple. You can continue by typing without enabling photos."))
                .font(.footnote)
            Button(captureText("Take a photo for review")) { requestCamera() }.disabled(!canReview || !localPhotoConsent)
                .accessibilityIdentifier("scan.camera")
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Text(captureText("Choose one photo for review"))
            }.disabled(!canReview || !localPhotoConsent)
            PasteButton(payloadType: String.self) { model.paste($0); resetDerived() }.disabled(!canReview)
                .accessibilityLabel(captureText("Paste source text"))
            if model.busy || loadingPhoto || requestingCamera { ProgressView(captureText("Preparing source for review…")) }
            Text(captureText("Recognition stays on this device. Saved photo references are reduced in size and omit location metadata; the app does not save them to your photo library."))
                .font(.footnote)
        }
    }
    private var packageFields: some View {
        Section(captureText("Manual product match")) {
            TextField(captureText("Product label you checked"), text: $label)
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
    private var receiptFields: some View {
        Section(captureText("Receipt lines are evidence only")) {
            Text(captureText("Keep unreadable quantities or printed amounts unknown. These lines do not mark anything paid, received or usable."))
            TextField(captureText("Source reference label"), text: $label)
            if receiptLines == nil {
                Button(captureText("Review printed lines")) {
                    do { receiptLines = try ScanLimits.receiptLines(model.text); error = nil }
                    catch { self.error = captureText("Shorten the text or type the source again, then review.") }
                }.disabled(!canReview || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                ForEach(receiptLines ?? []) { snapshot in
                    let row = captureDraftBinding(ScanReceiptLine(id: snapshot.id, originalText: ""), in: receiptBinding)
                    VStack(alignment: .leading) {
                        Text(row.wrappedValue.originalText).font(.footnote).textSelection(.enabled)
                        TextField(captureText("Reviewed line wording"), text: row.reviewedText, axis: .vertical)
                        TextField(captureText("Quantity wording, unknown if blank"), text: row.quantityNote)
                        TextField(captureText("Printed amount wording, unknown if blank"), text: row.priceNote)
                    }
                }
                Toggle(captureText("I reviewed these lines as source evidence only."), isOn: $model.confirmed)
                Button(captureText("Continue with reviewed reference")) { finishEvidence() }
                    .disabled(!canReview || !model.confirmed || receiptLines?.isEmpty != false || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("scan.receipt.review")
            }
        }
    }
    private var recipeFields: some View {
        Section(captureText("Editable recipe review")) {
            Text(captureText("Review the title, servings and ingredients. Accepting this draft does not choose a dinner or add groceries."))
            TextField(captureText("Recipe title"), text: recipeField(\.title))
            TextField(captureText("Reviewed servings"), text: recipeField(\.servings)).keyboardType(.numbersAndPunctuation)
            TextField(captureText("Source URL, attribution only"), text: recipeField(\.sourceURL)).textInputAutocapitalization(.never).autocorrectionDisabled()
            Text(captureText("The source URL is saved as attribution. It is never fetched, and the recipe stays editable if the page disappears."))
            TextField(captureText("Recipe notes and instructions"), text: recipeField(\.notes), axis: .vertical)
            Text(captureText("Ingredient wording, one per line"))
            TextEditor(text: recipeField(\.ingredientText)).frame(minHeight: 140).accessibilityLabel(captureText("Ingredient wording, one per line"))
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
        do {
            guard (kind == .receipt && target.kind == .receiptEvidence) || ((kind == .packageReference || kind == .barcode) && target.kind == .packageReference) else { throw ScanFailure.stale }
            let barcode = reviewedBarcode
            if kind == .barcode, barcode == nil { throw ScanFailure.needsReview }
            let record = try model.reviewed(target: target, label: label, barcode: barcode, receiptLines: receiptLines ?? [])
            onReviewed(.evidence(record)); dismiss()
        } catch { self.error = captureText("Check the source, choose or type a code when scanning, and confirm the manual match. Nothing has been saved.") }
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
            do { try await CameraCapturePermission.request(); guard localPhotoConsent, permissionGeneration == attempt, authorize(), !model.closed else { return }; showCamera = true }
            catch { guard permissionGeneration == attempt, !model.closed else { return }; model.inputFailed(error as? ScanFailure ?? .unavailable) }
        }
    }
    private func loadPhoto(_ item: PhotosPickerItem?) {
        photoTask?.cancel(); guard localPhotoConsent, let item, !model.closed else { return }; loadingPhoto = true
        photoTask = Task { @MainActor in
            defer { if photo == item { loadingPhoto = false } }
            do {
                guard let selected = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                guard localPhotoConsent, !Task.isCancelled, photo == item, authorize(), !model.closed else { return }
                model.stage(selected.data)
            } catch { if !Task.isCancelled, !model.closed { model.inputFailed(error as? ScanFailure ?? .invalidImage) } }
        }
    }
    private func resetDerived() { barcodeID = nil; manualCode = ""; receiptLines = nil; recipe = nil; ingredients = []; matchedProduct = false; model.confirmed = false }
    private func close() { permissionGeneration = UUID(); showCamera = false; photoTask?.cancel(); photoTask = nil; model.close(); corrections.invalidate(); resetDerived() }
    private func failureText(_ value: ScanFailure) -> String {
        switch value {
        case .permissionDenied: return captureText("Camera permission was not granted. Type, paste or choose a photo instead.")
        case .tooLarge: return captureText("Choose a photo under 12 MB and 30 megapixels, and keep the text under 20,000 bytes and 200 lines.")
        default: return captureText("This capture is unavailable. Your typed draft is still usable; nothing has been added automatically.")
        }
    }
}
