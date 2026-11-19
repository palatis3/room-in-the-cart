import CoreDomain
import PhotosUI
import SwiftUI

struct PantryProductBatchView: View {
    @ObservedObject var model: PantryModel
    @State private var batch: PantryProductBatch
    @StateObject private var catalogScope = BatchCatalogScope()
    @State private var merchant = ""
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var confirmed = false
    @State private var photoConsent = false
    @State private var editingCount = false
    @State private var repeatedProductID: UUID?
    @State private var editingProduct: PantryProductBatch.Candidate?
    @State private var review: PantryReceiptReview?
    @State private var result: String?
    @State private var inputMessage: String?
    private let didFinishWithLot: (UUID) -> Void
    @State private var savedLotID: UUID?
    @State private var saved = false
    @State private var working = false
    @State private var code = ""
    @State private var name = ""
    @FocusState private var focus: String?
    @Environment(\.dismiss) private var dismiss

    init(model: PantryModel, workspaceID: UUID, didFinishWithLot: @escaping (UUID) -> Void = { _ in }) {
        self.didFinishWithLot = didFinishWithLot
        self.model = model
        _batch = State(initialValue: PantryProductBatch(workspaceID: workspaceID))
    }
    private var authorized: Bool { model.phase == .ready && model.snapshot?.state.workspaceID == batch.workspaceID }

    var body: some View {
        WorkingForm {
            if !authorized {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if saved {
                Text(pantryText("Product batch saved.")).accessibilityIdentifier("productBatch.saved")
                Button(pantryText("Done")) {
                    if let savedLotID { didFinishWithLot(savedLotID) }
                    dismiss()
                }
            } else if let review {
                Section(pantryText("Review received products")) {
                    ForEach(review.facts) { row in
                        VStack(alignment: .leading) {
                            Text(row.name).font(.headline)
                            Text(row.originalLine)
                            Text(pantryFormat("Received %@", pantryQuantity(row.received)))
                            Text(pantryFormat("Usable %@", pantryQuantity(row.usable)))
                            switch row.stock {
                            case .added(let location):
                                Text(pantryText("Add a separate physical batch"))
                                Text(pantryLocationName(location))
                            case .linked:
                                Text(pantryText("Link evidence to the delivered batch. Its pantry count stays the same."))
                                if let delivery = batch.candidates.first(where: { $0.ordinal == row.ordinal })?.linkedDelivery {
                                    Text(PantryReceiptDelivery.label(for: delivery.lot, purchase: delivery.purchase))
                                }
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    Text(review.facts.first?.merchant ?? "")
                    Text(date, format: .dateTime.year().month().day())
                    Button(pantryText("Save received products")) { commit(review) }.accessibilityIdentifier("productBatch.commit")
                    Button(pantryText("Edit batch")) { self.review = nil; result = nil }
                }.disabled(working)
            } else {
                Section(pantryText("Add a product")) {
                    TextField(pantryText("Barcode, if available"), text: $code).focused($focus, equals: "code")
                        .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("productBatch.code")
                    VStack(alignment: .leading) {
                        let title = pantryText("Product name or label text")
                        Text(title).font(.caption)
                        TextEditor(text: $name)
                            .frame(minHeight: 58)
                            .focused($focus, equals: "name")
                            .accessibilityLabel(title)
                            .accessibilityIdentifier("productBatch.label")
                    }
                    Button(pantryText("Add typed product")) {
                        do {
                            repeatedProductID = nil
                            let added = try batch.addManual(name: name, code: code)
                            inputMessage = added ? nil : pantryText("Already in this batch. Change its package count to add another.")
                            if !added {
                                let typed = CapturedBarcode(symbology: "manual", value: code.trimmingCharacters(in: .whitespacesAndNewlines))
                                repeatedProductID = batch.candidate(matching: typed)?.id
                            }
                            code = ""; name = ""; focus = nil; confirmed = false
                        } catch { inputMessage = pantryText("Check the product wording and the 12-product batch limit.") }
                    }.disabled(name.isEmpty && code.isEmpty).accessibilityIdentifier("productBatch.add")
                    if let inputMessage {
                        Text(inputMessage).accessibilityIdentifier("productBatch.inputStatus")
                        if let repeatedProductID, let row = batch.candidates.first(where: { $0.id == repeatedProductID }) {
                            Button(pantryText(row.included ? "Edit package count" : "Review skipped product")) {
                                editingCount = row.included
                                editingProduct = row
                            }.accessibilityIdentifier("productBatch.editRepeated")
                        }
                    }
                    PantryProductPhotoInput(consent: $photoConsent, authorized: { authorized && review == nil && !saved }, add: { source in
                        repeatedProductID = nil
                        let added = try batch.addPhoto(source)
                        confirmed = false
                        inputMessage = added == 0 ? pantryText("Already in this batch. Change its package count to add another.") : nil
                    }, revoke: { batch.revokePhotos(); confirmed = false })
                }
                if !batch.candidates.isEmpty {
                    Section(pantryText("Products to review")) {
                        ForEach(batch.candidates) { row in
                            productRow(row)
                                .accessibilityIdentifier("productBatch.row." + String(row.ordinal))
                        }
                    }
                    Section(pantryText("Confirm receipt")) {
                        TextField(pantryText("Store or branch"), text: $merchant).focused($focus, equals: "merchant")
                            .accessibilityIdentifier("productBatch.merchant")
                        DatePicker(pantryText("Purchase date"), selection: $date, in: ...Date(), displayedComponents: .date)
                        Toggle(pantryText("I received these packages and checked the date and usable quantities."), isOn: $confirmed)
                            .accessibilityIdentifier("productBatch.received")
                        Button(pantryText("Review received products")) { prepare() }
                            .disabled(!confirmed || working || !model.canEdit || merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("productBatch.review")
                    }
                }
            }
            if authorized, let result { Text(result).accessibilityIdentifier("productBatch.status") }
        }
        .disabled(working)
        .navigationTitle(pantryText("Scan products")).privacySensitive().scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focus != nil, title: pantryText("Done"), identifier: "productBatch.keyboardDone") { focus = nil }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() }.disabled(working) } }
        .interactiveDismissDisabled(working)
        .sheet(item: $editingProduct) { selection in
            NavigationStack {
                if authorized, let row = batch.candidates.first(where: { $0.id == selection.id }) {
                    PantryProductCandidateEditor(row: captureDraftBinding(row, in: $batch.candidates),
                        deliveries: model.productDeliveries, scope: catalogScope.id, focusCount: editingCount,
                        correctBarcode: correctBarcode, authorized: {
                            authorized && editingProduct?.id == selection.id && batch.candidates.contains { $0.id == selection.id }
                        })
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(pantryText("Close")) { editingProduct = nil }
                                    .accessibilityIdentifier("productBatch.finishEditing")
                            }
                        }
                }
            }
        }
        .onChange(of: batch.candidates) { _, _ in confirmed = false }
        .onChange(of: merchant) { _, _ in confirmed = false }
        .onChange(of: date) { old, new in if !Calendar.current.isDate(old, inSameDayAs: new) { confirmed = false } }
        .onChange(of: authorized) { _, allowed in
            if !allowed {
                editingProduct = nil
                let scope = catalogScope.id
                Task { await PantryProductCatalog.shared.close(scope: scope) }
            }
        }
    }

    @ViewBuilder
    private func productRow(_ row: PantryProductBatch.Candidate) -> some View {
        let label = VStack(alignment: .leading) {
            Text(row.name.isEmpty ? (row.barcode?.value ?? pantryText("Product photo")) : row.name)
            if !row.included { Text(pantryText("Skipped")).font(.caption) }
            else if let total = row.total { Text(total.description + " " + pantryUnit(row.unit)).font(.caption) }
            else { Text(pantryText("Choose a package size and count.")).font(.caption) }
        }
        if #available(iOS 18, *) {
            NavigationLink {
                PantryProductCandidateEditor(row: captureDraftBinding(row, in: $batch.candidates),
                    deliveries: model.productDeliveries, scope: catalogScope.id, correctBarcode: correctBarcode, authorized: { authorized })
            } label: { label }
        } else {
            // A link attached to this mutable form row can stall the iOS 17 navigation stack.
            Button {
                focus = nil
                editingCount = false
                editingProduct = row
            } label: {
                label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func correctBarcode(_ value: String, for id: UUID) throws {
        guard authorized, !working, !saved, review == nil else { throw ProductBatchError.invalid }
        try batch.correctManualBarcode(value, for: id)
        inputMessage = nil
        repeatedProductID = nil
    }

    private func prepare() {
        guard !working, authorized else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let rows = batch.candidates
                let store = merchant, purchaseDate = date
                let proposal = try await model.reviewProducts(batch, merchant: store, purchaseDate: purchaseDate, confirmed: confirmed)
                guard authorized, confirmed, batch.candidates == rows, merchant == store, date == purchaseDate else { return }
                review = proposal; result = nil
            } catch ProductBatchError.chooseStockAction {
                result = pantryText("Open each included product and choose a delivery or a separate physical batch.")
            } catch ProductBatchError.changedDelivery, PantryReceiptError.stale {
                await model.load()
                confirmed = false
                result = pantryText("Review the delivery and package unit again before saving.")
            } catch {
                result = pantryText("Check the name, amount per package and whole package count for every included product.")
            }
        }
    }

    private func commit(_ proposal: PantryReceiptReview) {
        guard !working, authorized else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.saveProducts(batch, review: proposal)
                if authorized {
                    let physicalIDs = Set(model.snapshot?.lots.map(\.id) ?? [])
                    savedLotID = proposal.facts.first(where: { physicalIDs.contains($0.lotID) })?.lotID
                    saved = true; review = nil; result = nil
                }
            } catch {
                await model.load()
                if authorized {
                    review = nil; confirmed = false
                    result = pantryText("The batch could not be saved. Review the current pantry and try again.")
                }
            }
        }
    }
}

private final class BatchCatalogScope: ObservableObject {
    let id = UUID()
    deinit {
        let scope = id
        Task { await PantryProductCatalog.shared.close(scope: scope) }
    }
}

private struct PantryProductCandidateEditor: View {
    @Binding var row: PantryProductBatch.Candidate
    let deliveries: [PantryReceiptDelivery]
    let scope: UUID
    var focusCount = false
    let correctBarcode: (String, UUID) throws -> Void
    let authorized: () -> Bool
    @Environment(\.locale) private var locale
    @State private var editingBarcode = false
    @State private var lookupRequest: UUID?
    @State private var message: String?
    @FocusState private var field: String?

    private var stockChoice: Binding<ReceiptImportDraft.Treatment?> {
        Binding(get: {
            switch row.stockAction {
            case .separate: return .add
            case .link(let saved) where deliveries.contains(saved): return .link(saved.id)
            default: return nil
            }
        }, set: { action in
            switch action {
            case .add: row.stockAction = .separate
            case .link(let id):
                if let chosen = deliveries.first(where: { $0.id == id }) { row.stockAction = .link(chosen) }
            default: row.stockAction = nil
            }
        })
    }

    var body: some View {
        WorkingForm {
            if authorized() {
                Section {
                    Toggle(pantryText("Include this product"), isOn: $row.included).accessibilityIdentifier("productBatch.include")
                    if let code = row.barcode {
                        LabeledContent(pantryText("Barcode"), value: code.value)
                        if row.photoID == nil && code.symbology == "manual" {
                            Button(pantryText("Edit barcode")) {
                                field = nil
                                editingBarcode = true
                            }.accessibilityIdentifier("productBatch.editBarcode")
                        }
                    }
                    if !row.original.isEmpty { Text(verbatim: row.original) }
                }
                if row.included {
                    if !deliveries.isEmpty || row.stockAction != nil {
                        Picker(pantryText("Stock action"), selection: stockChoice) {
                            Text(pantryText("Choose a stock action")).tag(nil as ReceiptImportDraft.Treatment?)
                            Text(pantryText("Add a separate physical batch")).tag(Optional(ReceiptImportDraft.Treatment.add))
                            ForEach(deliveries) { delivery in
                                Text(PantryReceiptDelivery.label(for: delivery.lot, purchase: delivery.purchase))
                                    .tag(Optional(ReceiptImportDraft.Treatment.link(delivery.id)))
                            }
                        }.accessibilityIdentifier("productBatch.stockAction")
                        if let selected = row.linkedDelivery {
                            if deliveries.contains(selected), selected.lot.unit == row.unit {
                                Text(pantryText("Link evidence to the delivered batch. Its pantry count stays the same."))
                            } else { Text(pantryText("Review the delivery and package unit again before saving.")) }
                        }
                    }
                    Section(pantryText("Check the package")) {
                        TextField(pantryText("Food name"), text: $row.name).focused($field, equals: "name")
                            .accessibilityIdentifier("productBatch.productName")
                        TextField(pantryText("Amount in each package"), text: $row.perPack).focused($field, equals: "size")
                            .accessibilityIdentifier("productBatch.packSize")
                        Picker(pantryText("Unit"), selection: $row.unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                        }
                        LabeledContent(pantryText("Packages received")) {
                            TextField(text: $row.packages, prompt: Text(verbatim: "—")) {
                                Text(pantryText("Packages received"))
                            }
                                .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                .focused($field, equals: "count").accessibilityIdentifier("productBatch.packCount")
                        }
                        if let total = row.total {
                            LabeledContent(pantryText("Amount usable")) {
                                TextField(total.description, text: $row.usable)
                                    .multilineTextAlignment(.trailing).focused($field, equals: "usable")
                                    .accessibilityIdentifier("productBatch.usable")
                                Text(pantryUnit(row.unit))
                            }
                        }
                        if row.linkedDelivery == nil {
                            Picker(pantryText("Storage location"), selection: $row.location) {
                                ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                            }
                        }
                    }
                    if row.barcode?.validGTIN == true {
                        Section(pantryText("Public product lookup")) {
                            Text(pantryText("Open Food Facts receives the barcode, the app version and your IP address. You can also enter the package details yourself."))
                            if lookupRequest == nil {
                                Button(pantryText("Look up this barcode")) { message = nil; lookupRequest = UUID() }
                                    .accessibilityIdentifier("productBatch.lookup")
                            } else {
                                Button(pantryText("Cancel lookup")) { lookupRequest = nil }
                                    .accessibilityIdentifier("productBatch.cancelLookup")
                            }
                            if let proposal = row.catalog {
                                if let name = proposal.name { Text(verbatim: name) }
                                if let quantity = proposal.quantity {
                                    Text(verbatim: quantity)
                                    if PantryProductBatch.Candidate.pack(quantity) == nil {
                                        Text(pantryText("Enter the size from the package for this wording."))
                                    }
                                }
                                LabeledContent(pantryText("Retrieved"), value: proposal.fetched.formatted(date: .abbreviated, time: .shortened))
                                if let modified = proposal.modified {
                                    LabeledContent(pantryText("Source updated"), value: modified.formatted(date: .abbreviated, time: .omitted))
                                }
                                Link("Open Food Facts", destination: proposal.source)
                                Button(pantryText("Use proposed details")) { row.use(proposal); message = nil }
                            }
                            Link(pantryText("Open Food Facts data and reuse terms"), destination: URL(string: "https://world.openfoodfacts.org/terms-of-use")!)
                            Text(pantryText("The Open Food Facts database uses ODbL and its individual contents use DbCL. Check the package before using a proposal."))
                        }
                    }
                }
                if let message { Text(message).accessibilityIdentifier("productBatch.lookupStatus") }
            }
        }
        .navigationTitle(pantryText("Review product")).privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: field != nil, title: pantryText("Done"), identifier: "productBatch.editorDone") { field = nil }
        .onAppear { if focusCount && row.included { field = "count" } }
        .sheet(isPresented: $editingBarcode) {
            if authorized(), let code = row.barcode {
                ManualBarcodeCorrectionView(code: code.value) { corrected in
                    guard authorized() else { throw ProductBatchError.invalid }
                    try correctBarcode(corrected, row.id)
                    lookupRequest = nil
                    message = nil
                }
            }
        }
        .task(id: lookupRequest) { [request = lookupRequest] in
            if let request, let code = row.barcode { await lookup(code, request: request) }
        }
        .onChange(of: row.included) { _, included in if !included { lookupRequest = nil } }
        .onChange(of: authorized()) { _, allowed in if !allowed { lookupRequest = nil } }
        .onDisappear { lookupRequest = nil }
    }

    private func lookup(_ code: CapturedBarcode, request: UUID) async {
        let id = row.id
        func current() -> Bool {
            !Task.isCancelled && lookupRequest == request && authorized() && row.included && row.id == id && row.barcode == code
        }
        guard current() else { return }
        defer { if lookupRequest == request { lookupRequest = nil } }
        do {
            let value = try await PantryProductCatalog.shared.lookup(code, scope: scope, spanish: locale.language.languageCode?.identifier == "es")
            guard current() else { return }
            row.catalog = value
            message = value == nil ? pantryText("No catalog match. Enter the details from your package.") : nil
        } catch {
            if current() { message = pantryText("The catalog is unavailable. Enter the details from your package.") }
        }
    }
}

private struct ManualBarcodeCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var validationMessage: String?
    let save: (String) throws -> Void

    init(code: String, save: @escaping (String) throws -> Void) {
        _code = State(initialValue: code)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            WorkingForm {
                Section(pantryText("Barcode")) {
                    TextField(pantryText("Barcode"), text: $code)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("productBatch.correctedBarcode")
                    if let validationMessage { Text(validationMessage).accessibilityIdentifier("productBatch.correctionError") }
                }
            }
            .navigationTitle(pantryText("Edit barcode")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pantryText("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pantryText("Save barcode")) {
                        do {
                            try save(code)
                            dismiss()
                        } catch ProductBatchError.duplicateBarcode {
                            validationMessage = pantryText("Another product in this batch already has that barcode. Check the code on the package.")
                        } catch {
                            validationMessage = pantryText("Enter a barcode from the package.")
                        }
                    }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("productBatch.saveBarcode")
                }
            }
        }
    }
}

private struct PantryProductPhotoInput: View {
    @Binding var consent: Bool
    let authorized: () -> Bool
    let add: (ScannedSource) throws -> Void
    let revoke: () -> Void
    @State private var selection: PhotosPickerItem?
    @State private var camera = false
    @State private var busy = false
    @State private var message: String?
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        Toggle(pantryText("Read product photos on this device"), isOn: $consent)
            .accessibilityIdentifier("productBatch.photoConsent")
            .onChange(of: consent) { _, enabled in
                if !enabled { invalidate(); camera = false; selection = nil; revoke() }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                run {
                    guard let photo = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                    return try await OnDeviceScanService().scan(photo.data)
                } then: { source in if let source { try add(source) } }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraCaptureView(authorize: { consent && authorized() }) { outcome in
                    camera = false
                    guard consent, authorized(), let outcome else { return }
                    run { try await OnDeviceScanService().scan(outcome.get()) } then: { if let source = $0 { try add(source) } }
                }.ignoresSafeArea()
            }
            .onDisappear { if !camera { invalidate() } }
        if consent {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Text(pantryText("Choose a product photo"))
            }.disabled(busy).accessibilityIdentifier("productBatch.photo")
            Button(pantryText("Photograph a package")) {
                run {
                    try await CameraCapturePermission.request()
                    return nil
                } then: { _ in camera = true }
            }.disabled(busy)
            if busy { ProgressView(pantryText("Reading product photo…")) }
        }
        if let message { Text(message) }
    }
    private func invalidate() { generation = UUID(); request?.cancel(); request = nil; busy = false }
    private func run(_ prepare: @escaping () async throws -> ScannedSource?, then finish: @escaping (ScannedSource?) throws -> Void) {
        guard consent, authorized(), !busy else { return }
        let token = UUID()
        generation = token; busy = true; message = nil
        request = Task { @MainActor in
            defer { if generation == token { busy = false; selection = nil } }
            do {
                let source = try await prepare()
                guard generation == token, consent, authorized(), !Task.isCancelled else { return }
                try finish(source)
            } catch {
                if generation == token, consent, authorized(), !Task.isCancelled {
                    message = pantryText("The photo could not be added. Try a smaller image or type the product.")
                }
            }
        }
    }
}
