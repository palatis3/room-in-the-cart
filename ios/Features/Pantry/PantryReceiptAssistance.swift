import CoreDomain
import HouseholdClient
import PhotosUI
import SwiftUI

/// Accepting a suggestion only edits the existing row. It never selects an acquisition action or confirms usable stock.
extension ReceiptImportDraft.Line {
    mutating func applyAssisted(_ suggestion: ReceiptLineSuggestion, request: ReceiptLineAssistanceRequest,
                                reviewedLine: Self, useReceived: Bool) throws {
        try suggestion.validate(for: request)
        guard self == reviewedLine, request.page == (documentLine?.page ?? 1),
              request.line == (documentLine?.line ?? ordinal + 1) else { throw PantryReceiptError.stale }
        var amount: (String, UnitOfMeasure)?
        if useReceived {
            guard let number = suggestion.quantity, let code = suggestion.unit, let measured = UnitOfMeasure(rawValue: code),
                  let validated = try ComparisonModel.quantity(number, measured), validated.amount > .zero else {
                throw PantryReceiptError.invalid
            }
            amount = (number, measured)
        }
        if let name = suggestion.foodName { clearAlias(); self.name = name }
        if let (number, unit) = amount {
            // A unit applies to both fields. Require the shopper to enter usable stock again when units change.
            if self.unit != unit { usable = "" }
            self.unit = unit
            received = number
        }
    }
}

@MainActor struct AssistedCaptureLineReview: View {
    private let original: String
    private let page: Int
    private let lineNumber: Int
    private let sourceImage: Data?
    private let authorized: () -> Bool
    private let checkSource: () async throws -> Void
    private enum Destination {
        case receipt((ReceiptLineSuggestion, ReceiptLineAssistanceRequest, Bool) throws -> Void)
        case image(ImageAssistancePurpose, (ReviewedImageWording) throws -> Void)
    }
    private let destination: Destination
    private var isReceipt: Bool { if case .receipt = destination { return true }; return false }

    init(line: ReceiptImportDraft.Line, sourceImage: Data?, authorized: @escaping () -> Bool,
         checkSource: @escaping () async throws -> Void,
         apply: @escaping (ReceiptLineSuggestion, ReceiptLineAssistanceRequest, Bool) throws -> Void) {
        original = line.original; page = line.documentLine?.page ?? 1; lineNumber = line.documentLine?.line ?? line.ordinal + 1
        self.sourceImage = sourceImage; self.authorized = authorized; self.checkSource = checkSource; destination = .receipt(apply)
    }
    init(original: String, lineNumber: Int, sourceImage: Data, purpose: ImageAssistancePurpose,
         authorized: @escaping () -> Bool, apply: @escaping (ReviewedImageWording) throws -> Void) {
        self.original = original; self.lineNumber = lineNumber; page = 1; self.sourceImage = sourceImage
        self.authorized = authorized; self.checkSource = {}; destination = .image(purpose, apply)
    }
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var basis: CapturePrivateIdentity?
    @State private var checked = false
    @State private var available = false
    @State private var allowsCrop = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropSource: CGImage?
    @State private var cropEditor = false
    @State private var cropDigest: Data?
    @State private var crop: ReceiptLineCrop?
    @State private var localWording: String?
    @State private var preparingPhoto = false
    @State private var sending = false
    @State private var request: ReceiptLineAssistanceRequest?
    @State private var attempts = 0
    @State private var result: ReceiptLineSuggestion?
    @State private var readLine: ImageWordingSuggestion?
    @State private var received = false
    @State private var feedback: String?
    @State private var task: Task<Void,Never>?
    @State private var operation = UUID()

    private var identity: CapturePrivateIdentity? {
        guard authorized(), !household.guardianChildOnly,
              household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var current: Bool { scene == .active && basis?.subject != nil && identity == basis }
    private var serviceScope: ReceiptAssistanceScope? {
        guard let identified = identity, let subject = identified.subject, let householdID = identified.householdID,
              let memberID = identified.memberID else { return nil }
        return .init(subject: subject, householdID: householdID, memberID: memberID, shopID: household.projection?.shopId)
    }
    var body: some View {
        NavigationStack {
            Form {
                if scene == .active, identity != nil { Section(isReceipt ? pantryText("Original receipt wording") : pantryText("Original source wording")) { Text(verbatim: original) } }
                if !checked { ProgressView() }
                else if !current {
                    Text(isReceipt ? pantryText("For optional online help, open an authorized adult account. You can keep editing the receipt here.") : pantryText("Online image reading requires an authorized adult account. Continue with the local source editor."))
                } else if !available {
                    Text(isReceipt ? pantryText("Online receipt help is unavailable. You can keep editing the receipt on this iPhone.") : pantryText("Online image reading is unavailable. Continue with the local source editor."))
                } else {
                    Section(pantryText("Text to share with OpenAI")) {
                        Text(pantryText("Edit or remove personal details. Your chosen text and its page and line numbers go to OpenAI through Room in the Cart."))
                        TextField(isReceipt ? pantryText("Selected receipt wording") : pantryText("Optional text to share with this crop"), text: $selected, axis: .vertical)
                            .disabled(sending).accessibilityIdentifier("receipt.assistance.text")
                        Text(pantryFormat("Page %lld · line %lld", Int64(page), Int64(lineNumber)))
                        if allowsCrop { cropControls }
                        Button(crop == nil ? pantryText("Send this text for a suggestion") : pantryText("Send this crop and selected text to OpenAI")) { send() }
                            .disabled(!ReceiptLineAssistanceRequest.accepts(selected, crop: crop) || (!isReceipt && crop == nil) || sending || preparingPhoto || result != nil || readLine != nil || attempts >= 2)
                            .accessibilityIdentifier("receipt.assistance.send")
                    }
                    if sending { ProgressView(pantryText("Reading selected wording…")) }
                    if case let .receipt(apply) = destination, let result, let request {
                        Section(pantryText("Review the suggestion")) {
                            if let name = result.foodName { LabeledContent(pantryText("Suggested food"), value: name) }
                            if let quantity = result.quantity, let unit = result.unit.flatMap(UnitOfMeasure.init(rawValue:)) {
                                LabeledContent(pantryText("Printed quantity"), value: quantity + " " + pantryUnit(unit))
                                Toggle(pantryText("I received this quantity and want to use it."), isOn: $received)
                            }
                            if result.foodName == nil && result.quantity == nil { Text(pantryText("No food or quantity could be identified.")) }
                            else {
                                Button(pantryText("Use in my receipt draft")) {
                                    do {
                                        guard current else { throw PantryReceiptError.stale }
                                        try apply(result, request, received)
                                        dismiss()
                                    } catch { feedback = pantryText("The receipt changed. Reopen the line to review it again.") }
                                }.disabled(result.foodName == nil && !received)
                                .accessibilityIdentifier("receipt.assistance.apply")
                            }
                        }
                    }
                }
                if current, case let .image(_, apply) = destination, let readLine {
                    Section(pantryText("Compare this reading with the image")) {
                        if let wording = readLine.wording {
                            Text(verbatim: wording)
                            Button(pantryText("Use this reviewed wording")) {
                                do { guard current else { throw PantryReceiptError.stale }; try apply(reviewedWording(wording, method: .assistedImage)); dismiss() }
                                catch { feedback = pantryText("The source changed. Open the line again.") }
                            }.accessibilityIdentifier("assistance.useWording")
                        } else { Text(pantryText("This line could not be read. You can type the wording in the source editor.")) }
                    }
                }
                if let feedback { Text(feedback).accessibilityIdentifier("receipt.assistance.status") }
            }
            .navigationTitle(pantryText("Help with this line"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close")) { cancel(); dismiss() } } }
            .privacySensitive()
        }
        .task {
            selected = isReceipt ? String(original.prefix(500)) : ""
            basis = identity
            guard current, let scope = serviceScope, let service = household.service else { checked = true; return }
            let active = operation
            let offered = try? await service.receiptAssistanceAvailability(scope: scope)
            if !Task.isCancelled && operation == active && current && serviceScope == scope {
                available = offered?.available == true && (isReceipt || offered?.allowsCrop == true)
                allowsCrop = offered?.allowsCrop == true
            }
            checked = true
        }
        .onChange(of: selected) { _, _ in resetReview() }
        .task(id: pickedPhoto) {
            guard let item = pickedPhoto, current else { return }
            preparingPhoto = true
            defer { if pickedPhoto == item { preparingPhoto = false } }
            do {
                guard let transfer = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                let bytes = try transfer.data
                let normalized = try await Task.detached(priority: .userInitiated) { try ScanImageNormalizer.normalize(bytes) }.value
                guard !Task.isCancelled, current, pickedPhoto == item else { return }
                openCrop(normalized)
            } catch {
                if !Task.isCancelled && current { feedback = pantryText("Could not open this photo. You can send selected text instead.") }
            }
        }
        .sheet(isPresented: $cropEditor, onDismiss: { cropSource = nil; pickedPhoto = nil }) {
            if let cropSource, current {
                ReceiptLineCropEditor(image: cropSource) { value, digest in
                    guard current else { return }
                    crop = value; cropDigest = digest; localWording = nil; resetReview()
                }
            }
        }
        .task(id: crop) {
            guard let crop, let picture = crop.previewImage, let data = UIImage(cgImage: picture).pngData() else { return }
            let read = try? await OnDeviceTextCapture().recognize(data)
            if !Task.isCancelled, current, self.crop == crop { localWording = read?.text.replacingOccurrences(of: "\n", with: " ") }
        }
        .onChange(of: identity) { _, next in if basis != nil && next != basis { cancel(); dismiss() } }
        .onChange(of: scene) { _, phase in if phase == .background { cancel(); dismiss() } }
        .onDisappear { if !cropEditor { cancel() } }
    }
    @ViewBuilder private var cropControls: some View {
        if let crop, let preview = crop.previewImage {
            Image(decorative: preview, scale: 1).resizable().scaledToFit().accessibilityLabel(pantryText("Exact image crop to share"))
            Text(pantryText("This grayscale crop is the image OpenAI will receive. Check that it contains only the line you chose."))
            if let localWording, !localWording.isEmpty {
                Text(verbatim: localWording)
                Button(pantryText("Use this local text instead of sharing the crop")) {
                    if case let .image(_, apply) = destination {
                        do { guard current else { throw PantryReceiptError.stale }; try apply(reviewedWording(localWording, method: .deviceOCR)); dismiss() }
                        catch { feedback = pantryText("The source changed. Open the line again.") }
                    } else { selected = localWording; self.crop = nil; cropDigest = nil; self.localWording = nil; resetReview() }
                }.disabled(sending)
            }
            Button(pantryText("Remove the crop")) { self.crop = nil; cropDigest = nil; localWording = nil; resetReview() }.disabled(sending)
        } else {
            if let sourceImage {
                Button(isReceipt ? pantryText("Crop the reviewed receipt photo") : pantryText("Crop the selected source image")) { openCrop(sourceImage) }.disabled(sending)
            }
            if isReceipt {
                PhotosPicker(selection: $pickedPhoto, matching: .images, preferredItemEncoding: .current) {
                    Text(pantryText("Choose a photo to crop on this iPhone"))
                }.disabled(sending || preparingPhoto)
            }
            if preparingPhoto { ProgressView() }
        }
    }
    private func reviewedWording(_ text: String, method: ReviewedImageWording.Method) throws -> ReviewedImageWording {
        guard crop != nil, let cropDigest else { throw PantryReceiptError.stale }
        return try ReviewedImageWording(text: text, method: method, cropDigest: cropDigest)
    }

    private func openCrop(_ data: Data) {
        guard current, allowsCrop, let image = UIImage(data: data)?.cgImage else {
            feedback = pantryText("Could not open this photo. You can send selected text instead.")
            return
        }
        cropSource = image; cropEditor = true
    }
    private func resetReview() { request = nil; result = nil; readLine = nil; received = false; attempts = 0; feedback = nil }

    private func cancel() {
        operation = UUID(); task?.cancel(); task = nil; sending = false; result = nil; readLine = nil; request = nil
        crop = nil; cropDigest = nil; cropSource = nil; pickedPhoto = nil; localWording = nil
    }
    private func send() {
        guard current, available, !sending, attempts < 2, let scope = serviceScope, let service = household.service,
              let input = try? request ?? ReceiptLineAssistanceRequest(consentingTo: selected,
                    page: page, line: lineNumber, crop: crop) else { return }
        request = input; attempts += 1; sending = true; feedback = nil
        let active = operation
        task = Task {
            defer { if active == operation { sending = false } }
            do {
                try await checkSource()
                guard !Task.isCancelled, active == operation, current, request == input, serviceScope == scope else { return }
                switch destination {
                case .receipt:
                    let proposed = try await service.receiptLineSuggestion(input, scope: scope)
                    guard !Task.isCancelled, active == operation, current, request == input, serviceScope == scope else { return }
                    result = proposed
                case .image(let purpose, _):
                    let proposed = try await service.visibleImageLine(input, purpose: purpose, scope: scope)
                    guard !Task.isCancelled, active == operation, current, request == input, serviceScope == scope else { return }
                    readLine = proposed
                }
            } catch {
                if !Task.isCancelled && active == operation && current {
                    feedback = isReceipt ? pantryText("No suggestion was received. Your local receipt is ready to edit.") : pantryText("Online image reading is unavailable. Continue with the local source editor.")
                }
            }
        }
    }
}
