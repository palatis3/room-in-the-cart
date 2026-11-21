import DeviceSurfaces
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
    var model: PantryModel? = nil
    let target: CaptureTarget
    let authorize: @MainActor () -> Bool
    var reviewsPrivateReceipt = false
    var initialInput: ReceiptDocumentBytes? = nil
    var initialDocument: ExtractedReceiptDocument? = nil
    var sectionPreviews: [Data?] = []
    var omittedLines: Set<ExtractedReceiptDocument.Selection> = []
    var backToSections: (() -> Void)? = nil
    struct PhotoChange {
        let busy: Bool
        let status: String?
        let retake: () -> Void
        let choose: () -> Void
    }
    var changePhoto: PhotoChange? = nil
    let onReview: (SourceMediaRecord, SharedReceiptItem?, ExtractedReceiptDocument.PrintedPaidTotal?) -> Void
    @State private var inbox: [SharedReceiptItem] = []
    @State private var inboxUnavailable = false
    @State private var openedShare: SharedReceiptItem?
    @State private var discard: SharedReceiptItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var merchantFocused: Bool
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var document: ExtractedReceiptDocument?
    @State private var documentDateWording: String?
    @State private var inspectedLine: ExtractedReceiptDocument.Selection?
    @State private var fileBytes: ReceiptDocumentBytes?
    @State private var selection = Set<ExtractedReceiptDocument.Selection>()
    @State private var linkedAmountItems = Set<ExtractedReceiptDocument.Selection>()
    @State private var storeFocusRequest: UUID?
    @State private var stage: ReceiptAcquisition.DocumentLine.Stage = .receipt
    @State private var merchant = ""
    @State private var confirmed = false
    @State private var error: String?
    @AccessibilityFocusState private var statusFocused: Bool

    private var reviewsEvidenceOnly: Bool { reviewsPrivateReceipt && stage != .order }

    var body: some View {
        ScrollViewReader { scroll in form(scroll) }
    }

    private func form(_ scroll: ScrollViewProxy) -> some View {
        WorkingForm {
            if let error { Text(error).accessibilityFocused($statusFocused).accessibilityIdentifier("receipt.document.status") }
            if job != nil {
                ProgressView(pantryText("Reading receipt on this device"))
                Button(pantryText("Cancel reading")) { cancel() }
            } else if let document {
                let suggested = document.amountAssociations
                let pairs = availableAmounts(suggested)
                let splitAmounts = availableAmounts(document.splitAmountAssociations(excluding: suggested))
                let splitItems = Dictionary(uniqueKeysWithValues: splitAmounts.map { ($0.value, $0.key) })
                let suggestedAmountLines = Set(pairs.values)
                let linkedAmounts = Set(linkedAmountItems.compactMap { pairs[$0] ?? splitAmounts[$0] })
                let included = selection.union(linkedAmounts)
                let storeIssue = receiptStoreIssue(merchant)
                Section(pantryText("Receipt source")) {
                    let name = captureText("Store or receipt name (required)")
                    WorkingField(name) {
                        TextField(name, text: $merchant, prompt: Text(""))
                            .receiptInputChrome()
                            .focused($merchantFocused)
                            .accessibilityIdentifier("receipt.document.store")
                    }
                    .id("receipt.document.store")
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { merchantFocused = true })
                    .task(id: storeFocusRequest) {
                        guard let request = storeFocusRequest else { return }
                        await Task.yield()
                        guard !Task.isCancelled, storeFocusRequest == request, authorize() else { return }
                        merchantFocused = true
                        storeFocusRequest = nil
                    }
                    if merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let candidate = printedReceiptName(document) {
                        Button(String(format: captureText("Use %@ as the receipt name"), candidate)) {
                            guard authorize() else { return }
                            merchantFocused = false
                            merchant = candidate
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("receipt.document.usePrintedName")
                    }
                    if let dateWording = documentDateWording, stage != .order {
                        LabeledContent(pantryText("Date wording on the receipt")) {
                            Text(verbatim: dateWording).font(.system(.subheadline, design: .monospaced))
                        }
                    }
                    if let changePhoto {
                        Menu {
                            Button(putawayText("Retake receipt photo"), action: changePhoto.retake)
                            Button(captureText("Choose photo or screenshot"), action: changePhoto.choose)
                        } label: { Label(putawayText("Change receipt photo"), systemImage: "camera.rotate") }
                        .disabled(changePhoto.busy)
                        .accessibilityIdentifier("receipt.document.changePhoto")
                        if changePhoto.busy { ProgressView(pantryText("Reading receipt on this device")) }
                        if let status = changePhoto.status { Text(status).foregroundStyle(Theme.warning) }
                    }
                    Picker(pantryText("Document type"), selection: $stage) {
                        ForEach(ReceiptAcquisition.DocumentLine.Stage.allCases, id: \.self) { Text(receiptStage($0)).tag($0) }
                    }
                    Text(reviewsEvidenceOnly ? putawayText("Choose the printed lines to keep as evidence. Next you’ll decide what happened to each item.")
                         : pantryText("Select food lines and the printed purchase date to review. You will confirm received and usable quantities separately."))
                }
                ForEach(document.pages) { page in
                    Section(pantryFormat("Page %@", page.id.formatted())) {
                        if page.skipped == .pixels { Text(pantryText("This page exceeds 25 megapixels. Choose a smaller image to review it.")) }
                        else if page.skipped == .lineLimit { Text(putawayText("This page exceeds the line limit. You can type the receipt lines instead.")) }
                        else if page.lines.isEmpty { Text(pantryText("No readable lines on this page. You can type them in the receipt scanner.")) }
                        ForEach(page.lines.filter { !omittedLines.contains(.init(page: page.id, line: $0.id)) }) { line in
                            let position = ExtractedReceiptDocument.Selection(page: page.id, line: line.id)
                            let price = pairs[position] ?? (linkedAmountItems.contains(position) ? splitAmounts[position] : nil)
                            let priceLine = price.flatMap { price in page.lines.first { $0.id == price.line } }
                            let splitItem = splitItems[position].flatMap { item in
                                selection.contains(item) ? page.lines.first { $0.id == item.line } : nil
                            }
                            documentLine(line, at: position, attached: linkedAmounts.contains(position),
                                         canInclude: included.contains(position) || included.count < 200,
                                         canSelectAmountSeparately: suggestedAmountLines.contains(position),
                                         suggestedAmount: priceLine,
                                         canLink: price.map { included.union([position, $0]).count <= 200 } == true,
                                         splitItem: splitItem)
                        }
                    }
                }
                Section {
                    if openedShare != nil {
                        Text(reviewsEvidenceOnly ? putawayText("Saving the reviewed receipt removes this staged file. Keep the original for any other lines.")
                             : pantryText("Saving selected food removes this staged file. Keep the original for any other lines."))
                    }
                    if !reviewsEvidenceOnly {
                        Toggle(pantryText("I checked these printed lines and physically received food from this purchase."), isOn: $confirmed)
                    }
                    if let storeIssue {
                        Button {
                            storeFocusRequest = UUID()
                            scroll.scrollTo("receipt.document.store", anchor: .center)
                        } label: {
                            Label(storeIssue, systemImage: "arrow.up.circle").frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(!authorize())
                        .accessibilityIdentifier("receipt.document.storeIssue")
                    } else if selection.isEmpty {
                        Text(captureText("Select at least one printed line to continue.")).foregroundStyle(Theme.secondary)
                    } else if !reviewsEvidenceOnly && !confirmed {
                        Text(captureText("Confirm which printed lines you physically received to continue.")).foregroundStyle(Theme.secondary)
                    }
                    Button(reviewsEvidenceOnly ? putawayText("Use selected receipt lines") : pantryText("Review received food")) {
                        guard authorize(), storeIssue == nil, reviewsEvidenceOnly || confirmed else { return }
                        do {
                            let source = try document.source(target: target, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                stage: stage, selection: selection, linkedAmountItems: linkedAmountItems, at: Date())
                            let printedTotal = reviewsEvidenceOnly && stage == .receipt
                                ? document.printedPaidTotal(selected: selection) : nil
                            onReview(source, openedShare, printedTotal)
                            dismiss()
                        } catch { show(error) }
                    }.buttonStyle(PrimaryAction()).disabled(!authorize() || changePhoto?.busy == true || (!reviewsEvidenceOnly && !confirmed) || selection.isEmpty || storeIssue != nil)
                        .accessibilityIdentifier("receipt.document.accept")
                    if let backToSections { Button(captureText("Back to receipt sections"), action: backToSections) }
                    if initialDocument == nil { Button(pantryText("Choose another document")) { cancel() } }
                }
            } else {
                if let model, !inbox.isEmpty {
                    Section(pantryText("Shared receipt files")) {
                        ForEach(inbox) { item in
                            VStack(alignment: .leading) {
                                Text(item.receipt.createdAt, format: .dateTime.year().month().day().hour().minute())
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.descriptor.size), countStyle: .file))
                                Button(pantryText("Open shared receipt")) {
                                    start(shared: item) { try await model.openSharedReceipt(item) }
                                }.buttonStyle(.borderless)
                                Button(pantryText("Discard shared receipt"), role: .destructive) { discard = item }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Button(pantryText("Choose a receipt from Files")) { picking = true }
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Text(pantryText("Choose a receipt from Photos"))
                }
                if inboxUnavailable {
                    Text(pantryText("Shared files are unavailable. You can still choose a receipt from Files or Photos."))
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Text(pantryText("Use a PDF, JPEG, PNG, HEIC photo or UTF-8 or UTF-16 text file up to 10 MB. PDFs can have up to 20 pages."))
            }
        }
        .privacySensitive()
        .navigationTitle(document == nil ? pantryText("Read a receipt file") : pantryText("Select receipt lines"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Close")) { cancel(); dismiss() }
                    .accessibilityIdentifier("receipt.document.close")
            }
        }
        .keyboardDoneAction(visible: merchantFocused, title: pantryText("Done"), identifier: "receipt.document.keyboardDone") { merchantFocused = false }
        .sheet(item: $inspectedLine) { position in
            if authorize(), scenePhase != .background,
               let page = document?.pages.first(where: { $0.id == position.page }),
               let index = page.lines.firstIndex(where: { $0.id == position.line }) {
                NavigationStack {
                    ReceiptPrintedLineInspector(lines: page.lines, pageNumber: page.id, index: index, originalPage: {
                        guard authorize(), inspectedLine == position else { return nil }
                        if sectionPreviews.indices.contains(page.id - 1) { return sectionPreviews[page.id - 1] }
                        guard let fileBytes else { return nil }
                        let image = await ReceiptDocumentReader.originalPage(fileBytes, pageNumber: page.id)
                        return authorize() && inspectedLine == position ? image : nil
                    })
                }
            }
        }
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
        .onChange(of: document?.digest) { _, _ in
            let dates = (document?.pages ?? []).flatMap(\.lines)
                .filter { !$0.uncertain && ReceiptPrintedDate.looksLikeDate($0.text) }
            documentDateWording = Set(dates.map(\.text)).count == 1 ? dates.first?.text : nil
        }
        .onChange(of: merchant) { _, _ in confirmed = false }
        .onChange(of: stage) { _, _ in confirmed = false; linkedAmountItems = [] }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .alert(item: $discard) { item in
            Alert(title: Text(pantryText("Discard this shared receipt?")),
                  message: Text(pantryText("This removes the staged file from this device.")),
                  primaryButton: .destructive(Text(pantryText("Discard"))) {
                    Task {
                        do { guard let model else { return }; try await model.finishSharedReceipt(item, committed: false); await loadInbox() }
                        catch { show(error) }
                    }
                  }, secondaryButton: .cancel(Text(pantryText("Cancel"))))
        }
        .onDisappear {
            // A replacement camera can cover the review. Keep the current selections
            // until a different image is successfully read, or the capture is closed.
            if changePhoto == nil { cancel() }
            inbox = []
        }
        .task { if let initialDocument { document = initialDocument } else { await loadInbox() } }
        .task { if let initialInput, document == nil, job == nil { start { initialInput } } }
    }

    private func availableAmounts(_ pairs: [ExtractedReceiptDocument.Selection: ExtractedReceiptDocument.Selection])
        -> [ExtractedReceiptDocument.Selection: ExtractedReceiptDocument.Selection] {
        guard stage != .order else { return [:] }
        return pairs.filter { !omittedLines.contains($0.key) && !omittedLines.contains($0.value) }
    }

    private func printedReceiptName(_ document: ExtractedReceiptDocument) -> String? {
        guard let first = document.pages.first, first.method == .imageOCR || first.method == .pdfOCR,
              let line = first.lines.first, !line.uncertain else { return nil }
        let wording = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard receiptStoreIssue(wording) == nil, wording.contains(where: \.isLetter),
              !wording.contains(where: \.isNumber), wording.split(whereSeparator: \.isWhitespace).count >= 2,
              ReceiptPrintedEvidence.canSuggestAmount(for: wording) else { return nil }
        return wording
    }

    private func documentLine(_ line: ReceiptDocumentPage.Line, at position: ExtractedReceiptDocument.Selection,
                              attached: Bool, canInclude: Bool, canSelectAmountSeparately: Bool,
                              suggestedAmount: ReceiptDocumentPage.Line?, canLink: Bool,
                              splitItem: ReceiptDocumentPage.Line?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    merchantFocused = false
                    inspectedLine = position
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: line.text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "text.magnifyingglass").accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(pantryFormat("Inspect printed line %@", line.id.formatted()) + ", " + line.text)
                .accessibilityIdentifier("receipt.document.inspect.\(position.page).\(line.id)")
                if !attached {
                    Toggle(line.text, isOn: Binding(get: { selection.contains(position) }, set: { include in
                        if include { selection.insert(position) }
                        else { selection.remove(position); linkedAmountItems.remove(position) }
                        confirmed = false
                    }))
                    .labelsHidden()
                    .fixedSize()
                    .frame(minHeight: 44)
                    .accessibilityLabel(putawayText("Include printed line") + ", " + line.text)
                    .accessibilityIdentifier("receipt.document.line.\(position.page).\(line.id)")
                    .accessibilityHint(canSelectAmountSeparately
                        ? captureText("Select to keep this amount separate, or link it from the item.") : "")
                    .disabled(!canInclude)
                }
            }
            if attached {
                Text(captureText("Linked as printed amount")).font(.subheadline).foregroundStyle(Theme.secondary)
            }
            if canSelectAmountSeparately, !attached {
                Text(captureText("Select to keep this amount separate, or link it from the item."))
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
            }
            if let suggestedAmount {
                let linked = linkedAmountItems.contains(position)
                let included = selection.contains(position)
                let title = linked ? captureText("Undo amount link") : String(
                    format: captureText(included ? "Link %@ to this item" : "Select item and link %@"), suggestedAmount.text)
                if linked {
                    Text(String(format: captureText("Possible line total linked to %@: %@"), line.text, suggestedAmount.text))
                        .font(.subheadline)
                }
                Button {
                    guard authorize() else { return }
                    if linked { linkedAmountItems.remove(position) }
                    else if canLink {
                        selection.insert(position)
                        linkedAmountItems.insert(position)
                    }
                    confirmed = false
                } label: {
                    Label(title, systemImage: linked ? "arrow.uturn.backward" : "link")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(!authorize() || (!canLink && !linked))
                .accessibilityIdentifier("receipt.document.amountLink.\(position.page).\(line.id)")
            }
            if let splitItem, !attached {
                Button {
                    let item = ExtractedReceiptDocument.Selection(page: position.page, line: splitItem.id)
                    guard authorize(), selection.contains(item), canInclude else { return }
                    linkedAmountItems.insert(item)
                    confirmed = false
                } label: {
                    Label(String(format: captureText("Link %@ to %@"), line.text, splitItem.text), systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(!authorize() || !canInclude)
                .accessibilityIdentifier("receipt.document.splitAmountLink.\(position.page).\(line.id)")
            }
        }
    }

    private func loadInbox() async {
        guard let model, model.supportsReceiptAliases, authorize() else { inbox = []; inboxUnavailable = false; return }
        do {
            let rows = try await model.pendingSharedReceipts()
            guard !Task.isCancelled, authorize() else { return }
            inbox = rows
            inboxUnavailable = false
        } catch {
            if !Task.isCancelled, authorize() { inboxUnavailable = true }
        }
    }

    private func start(shared: SharedReceiptItem? = nil, _ read: @escaping () async throws -> ReceiptDocumentBytes) {
        cancel()
        guard authorize() else { return }
        let token = generation
        openedShare = shared
        job = Task {
            defer { if generation == token { job = nil } }
            do {
                let bytes = try await read()
                try Task.checkCancellation()
                guard token == generation, authorize() else { return }
                let extracted = try await ReceiptDocumentReader().extract(bytes)
                guard !Task.isCancelled, token == generation, authorize() else { return }
                fileBytes = bytes
                document = extracted
            } catch { if !Task.isCancelled, token == generation, authorize() { show(error) } }
        }
    }

    private func cancel() {
        generation = UUID()
        job?.cancel(); job = nil
        storeFocusRequest = nil
        inspectedLine = nil; fileBytes = nil
        openedShare = nil; selection = []; linkedAmountItems = []; document = nil; photo = nil; merchant = ""; confirmed = false; error = nil; stage = .receipt
    }

    private func show(_ failure: Error) {
        switch failure as? ReceiptDocumentFailure {
        case .size: error = pantryText("Choose a file up to 10 MB.")
        case .pages: error = pantryText("Choose a PDF with 1 to 20 pages, or export a smaller page range.")
        case .pixels: error = pantryText("Choose a photo or scanned page up to 25 megapixels.")
        case .characters: error = pantryText("Choose fewer pages with up to 100,000 extracted characters.")
        case .lineLimit: error = putawayText("Choose a smaller page with up to 200 lines, or type the receipt lines.")
        case .selection: error = pantryText("Choose fewer or shorter lines for this review.")
        case .locked: error = pantryText("This PDF is locked. Choose an unlocked copy or type the lines in the receipt scanner.")
        case .timeout: error = pantryText("Reading took more than 30 seconds. Choose fewer pages or type the lines.")
        default: error = pantryText("This document could not be read. Try another file or type the lines in the receipt scanner.")
        }
        statusFocused = true
    }
}


/// The inspector is read-only. Including a line in the receipt is a separate choice.
struct ReceiptPrintedLineInspector: View {
    let lines: [ReceiptDocumentPage.Line]
    let pageNumber: Int?
    let index: Int
    let originalPage: () async -> Data?
    @Environment(\.dismiss) private var dismiss
    @State private var pageImage: UIImage?
    @State private var showSource = false

    private var selected: ReceiptDocumentPage.Line { lines[index] }
    private var coordinates: String {
        if let pageNumber {
            return String(format: putawayText("Page %@, line %@"), pageNumber.formatted(), selected.id.formatted())
        }
        return String(format: putawayText("Line %@"), selected.id.formatted())
    }

    private var neighbors: ArraySlice<ReceiptDocumentPage.Line> {
        lines[max(0, index - 1)...min(lines.count - 1, index + 1)]
    }

    var body: some View {
        Group {
            if showSource, let pageImage {
                ReceiptPageViewer(image: pageImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lineDetails
            }
        }
        .navigationTitle(showSource ? pantryText("Original page") : pantryText("Printed line"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Done")) {
                    if showSource { showSource = false } else { dismiss() }
                }
            }
        }
        .privacySensitive()
        .task {
            let bytes = await originalPage()
            if !Task.isCancelled { pageImage = bytes.flatMap { UIImage(data: $0) } }
        }
    }

    private var lineDetails: some View {
        WorkingForm {
            Section {
                ReceiptPaperLine(wording: selected.text, provenance: coordinates, title: pantryText("Selected printed line"))
                if selected.uncertain {
                    Label(pantryText("Unclear printed line. Check the original wording before using it."), systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                }
            }
            Section(pantryText("Original lines")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(neighbors) { line in
                        let isSelected = line.id == selected.id
                        Text(line.text)
                            .font(.system(.body, design: .monospaced, weight: isSelected ? .bold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .overlay {
                                if isSelected { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.action, lineWidth: 2) }
                            }
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            if pageImage != nil {
                Button { showSource = true } label: {
                    Label(pantryText("Original page"), systemImage: "photo")
                }
                .accessibilityIdentifier("receipt.original.open")
            }
        }
    }
}

private struct ReceiptPageViewer: UIViewRepresentable {
    let image: UIImage
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeUIView(context: Context) -> UIStackView {
        let canvas = ReceiptPageCanvas(image: image)
        let zoomIn = UIButton(configuration: .tinted(), primaryAction: UIAction(title: pantryText("Zoom in"),
            image: UIImage(systemName: "plus.magnifyingglass")) { [weak canvas] _ in
            guard let canvas else { return }
            canvas.setZoomScale(min(canvas.zoomScale * 2, canvas.maximumZoomScale), animated: !UIAccessibility.isReduceMotionEnabled)
        })
        let fit = UIButton(configuration: .tinted(), primaryAction: UIAction(title: pantryText("Fit page"),
            image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak canvas] _ in
            guard let canvas else { return }
            canvas.setZoomScale(canvas.minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        })
        zoomIn.accessibilityIdentifier = "receipt.original.zoomIn"
        fit.accessibilityIdentifier = "receipt.original.fit"
        for button in [zoomIn, fit] {
            button.configuration?.imagePadding = 6
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        canvas.zoomChanged = { [weak zoomIn, weak fit] scale, maximum in
            zoomIn?.isEnabled = scale < maximum - 0.01
            fit?.isEnabled = scale > 1.01
        }
        let controls = UIStackView(arrangedSubviews: [zoomIn, fit])
        controls.distribution = .fillEqually
        controls.spacing = 8
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        controls.setContentHuggingPriority(.required, for: .vertical)

        let stack = UIStackView(arrangedSubviews: [canvas, controls])
        stack.axis = .vertical
        return stack
    }

    func updateUIView(_ stack: UIStackView, context: Context) {
        (stack.arrangedSubviews.last as? UIStackView)?.axis = typeSize.isAccessibilitySize ? .vertical : .horizontal
    }
}

private final class ReceiptPageCanvas: UIScrollView, UIScrollViewDelegate {
    private let page: UIImageView
    private var viewport = CGSize.zero
    var zoomChanged: ((CGFloat, CGFloat) -> Void)?

    init(image: UIImage) {
        page = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        contentSize = image.size
        addSubview(page)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = pantryText("Original page")
        accessibilityIdentifier = "receipt.original.canvas"
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = page.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        if viewport != bounds.size {
            let magnification = viewport == .zero ? 1 : zoomScale / minimumZoomScale
            viewport = bounds.size
            let fit = min(viewport.width / size.width, viewport.height / size.height)
            maximumZoomScale = fit * 8
            minimumZoomScale = fit
            setZoomScale(min(maximumZoomScale, fit * magnification), animated: false)
        }
        centerPage()
        reportZoom()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPage()
        reportZoom()
    }

    private func centerPage() {
        page.center = CGPoint(x: max(bounds.width, contentSize.width) / 2,
                              y: max(bounds.height, contentSize.height) / 2)
    }

    private func reportZoom() {
        let magnification = zoomScale / minimumZoomScale
        accessibilityValue = Double(magnification).formatted(.percent.precision(.fractionLength(0)))
        zoomChanged?(magnification, maximumZoomScale / minimumZoomScale)
    }
}
