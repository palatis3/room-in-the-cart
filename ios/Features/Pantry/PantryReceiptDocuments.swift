import CoreDomain
import PhotosUI
import SwiftUI

func receiptProvenance(_ place: ReceiptAcquisition.DocumentLine) -> String {
    let method: String
    switch place.method {
    case .textFile: method = pantryText("Plain text")
    case .pdfText: method = pantryText("PDF text")
    case .pdfOCR: method = pantryText("Scanned PDF page")
    case .imageOCR: method = pantryText("Receipt photo")
    }
    return receiptStage(place.stage) + " · " + pantryFormat("%@ · page %@, line %@", method, place.page.formatted(), place.line.formatted())
}

private func receiptStage(_ stage: ReceiptAcquisition.DocumentLine.Stage) -> String {
    switch stage {
    case .order: return pantryText("Order confirmation")
    case .receipt: return pantryText("Purchase receipt")
    case .finalInvoice: return pantryText("Final invoice")
    }
}

struct PantryReceiptDocuments: View {
    let target: CaptureTarget
    let authorize: @MainActor () -> Bool
    var initialInput: ReceiptDocumentBytes? = nil
    let onReview: (SourceMediaRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var merchantFocused: Bool
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var document: ExtractedReceiptDocument?
    @State private var selection = Set<ExtractedReceiptDocument.Selection>()
    @State private var stage: ReceiptAcquisition.DocumentLine.Stage = .receipt
    @State private var merchant = ""
    @State private var confirmed = false
    @State private var error: String?
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        Form {
            if let error { Text(error).accessibilityFocused($statusFocused).accessibilityIdentifier("receipt.document.status") }
            if job != nil {
                ProgressView(pantryText("Reading receipt on this device"))
                Button(pantryText("Cancel reading")) { cancel() }
            } else if let document {
                Section(pantryText("Receipt source")) {
                    TextField(pantryText("Store or branch"), text: $merchant).focused($merchantFocused)
                    Picker(pantryText("Document type"), selection: $stage) {
                        ForEach(ReceiptAcquisition.DocumentLine.Stage.allCases, id: \.self) { Text(receiptStage($0)).tag($0) }
                    }
                    Text(pantryText("Select food lines and the printed purchase date to review. You will confirm received and usable quantities separately."))
                }
                ForEach(document.pages) { page in
                    Section(pantryFormat("Page %@", page.id.formatted())) {
                        if page.skipped == .pixels { Text(pantryText("This page exceeds 25 megapixels. Choose a smaller image to review it.")) }
                        else if page.skipped == .lineLimit { Text(pantryText("This page exceeds the line limit. You can type the food lines instead.")) }
                        else if page.lines.isEmpty { Text(pantryText("No readable lines on this page. You can type them in the receipt scanner.")) }
                        ForEach(page.lines) { line in
                            let position = ExtractedReceiptDocument.Selection(page: page.id, line: line.id)
                            Toggle(isOn: Binding(get: { selection.contains(position) }, set: { include in
                                if include { selection.insert(position) } else { selection.remove(position) }
                                confirmed = false
                            })) { Text(line.text) }
                            .disabled(!selection.contains(position) && selection.count >= 200)
                            .accessibilityIdentifier("receipt.document.line.\(page.id).\(line.id)")
                        }
                    }
                }
                Section {
                    Toggle(pantryText("I checked these printed lines and physically received food from this purchase."), isOn: $confirmed)
                    Button(pantryText("Review received food")) {
                        guard authorize(), confirmed else { return }
                        do {
                            let source = try document.source(target: target, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                stage: stage, selection: selection, at: Date())
                            onReview(source)
                            dismiss()
                        } catch { show(error) }
                    }.disabled(!authorize() || !confirmed || selection.isEmpty || merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("receipt.document.accept")
                    Button(pantryText("Choose another document")) { cancel() }
                }
            } else {
                Button(pantryText("Choose a receipt from Files")) { picking = true }
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Text(pantryText("Choose a receipt from Photos"))
                }
                Text(pantryText("Use a PDF, JPEG, PNG, HEIC photo or UTF-8 text file up to 10 MB. PDFs can have up to 20 pages."))
            }
        }
        .privacySensitive()
        .navigationTitle(pantryText("Read a receipt file"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Close")) { cancel(); dismiss() }
                    .accessibilityIdentifier("receipt.document.close")
            }
        }
        .keyboardDoneAction(visible: merchantFocused, title: pantryText("Done"), identifier: "receipt.document.keyboardDone") { merchantFocused = false }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf, .jpeg, .png, .heic, .heif, .plainText]) { result in
            switch result {
            case .success(let url): start { try await ReceiptDocumentBytes.picked(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { show(error) }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            start {
                guard let input = try await item.loadTransferable(type: ReceiptPhotoSelection.self) else { throw ReceiptDocumentFailure.unavailable }
                return try input.bytes
            }
        }
        .onChange(of: merchant) { _, _ in confirmed = false }
        .onChange(of: stage) { _, _ in confirmed = false }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onDisappear { cancel() }
        .task { if let initialInput, document == nil, job == nil { start { initialInput } } }
    }

    private func start(_ read: @escaping () async throws -> ReceiptDocumentBytes) {
        cancel()
        guard authorize() else { return }
        let token = generation
        job = Task {
            defer { if generation == token { job = nil } }
            do {
                let bytes = try await read()
                try Task.checkCancellation()
                guard token == generation, authorize() else { return }
                let extracted = try await ReceiptDocumentReader().extract(bytes)
                guard !Task.isCancelled, token == generation, authorize() else { return }
                document = extracted
            } catch { if !Task.isCancelled, token == generation, authorize() { show(error) } }
        }
    }

    private func cancel() {
        generation = UUID()
        job?.cancel(); job = nil
        selection = []; document = nil; photo = nil; merchant = ""; confirmed = false; error = nil; stage = .receipt
    }

    private func show(_ failure: Error) {
        switch failure as? ReceiptDocumentFailure {
        case .size: error = pantryText("Choose a file up to 10 MB.")
        case .pages: error = pantryText("Choose a PDF with 1 to 20 pages, or export a smaller page range.")
        case .pixels: error = pantryText("Choose a photo or scanned page up to 25 megapixels.")
        case .characters: error = pantryText("Choose fewer pages with up to 100,000 extracted characters.")
        case .lineLimit: error = pantryText("Choose a smaller page with up to 200 lines, or type the food lines.")
        case .selection: error = pantryText("Choose fewer or shorter lines for this review.")
        case .locked: error = pantryText("This PDF is locked. Choose an unlocked copy or type the lines in the receipt scanner.")
        case .timeout: error = pantryText("Reading took more than 30 seconds. Choose fewer pages or type the lines.")
        default: error = pantryText("This document could not be read. Try another file or type the lines in the receipt scanner.")
        }
        statusFocused = true
    }
}
