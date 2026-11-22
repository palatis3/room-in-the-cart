import CoreDomain
import PhotosUI
import SwiftUI

struct PantryProductBatchView: View {
    @ObservedObject var model: PantryModel
    @State private var batch: PantryProductBatch
    @StateObject private var catalogScope = BatchCatalogScope()
    @Environment(\.pantryDigestAccess) private var access
    @ObservedObject private var memory = PantryDigestStore.shared.packMemory
    @State private var atHome = true
    @State private var retailer = ""
    @State private var typedKind = "manual"
    @State private var repeatedScan: CapturedBarcode?
    @State private var savedRows: [UUID: UUID] = [:]
    @State private var merchant = ""
    @State private var purchaseTimeZone = TimeZone.current
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var confirmed = false
    @State private var photoConsent = false
    @State private var editingCount = false
    @State private var repeatedProductID: UUID?
    @State private var editingProduct: PantryProductBatch.Candidate?
    @State private var reviewingLookup = false
    @State private var review: PantryReceiptReview?
    @State private var result: String?
    @State private var inputMessage: String?
    private let didFinishWithLot: (UUID) -> Void
    private let lookupAccess: PantryDigestAccess?
    @State private var savedLotID: UUID?
    @State private var initialAccess: PantryDigestAccess?
    @Environment(\.scenePhase) private var scene
    @State private var restoredRows: [ReviewedPackSave.Row] = []
    @State private var recovery: ReviewedPackSave?
    @State private var recoveryReadFailed = false
    @State private var saved = false
    @State private var working = false
    @State private var code = ""
    @State private var name = ""
    @FocusState private var focus: String?
    @Environment(\.dismiss) private var dismiss

    init(model: PantryModel, workspaceID: UUID, didFinishWithLot: @escaping (UUID) -> Void = { _ in }) {
        lookupAccess = nil
        self.didFinishWithLot = didFinishWithLot
        self.model = model
        _batch = State(initialValue: PantryProductBatch(workspaceID: workspaceID))
    }
    init(model: PantryModel, lookupBatch: PantryProductBatch, access: PantryDigestAccess) {
        self.model = model
        lookupAccess = access
        didFinishWithLot = { _ in }
        _batch = State(initialValue: lookupBatch)
        _initialAccess = State(initialValue: access)
        _reviewingLookup = State(initialValue: true)
    }

    private var confirmationText: String {
        guard atHome else { return pantryText("I received these packages and checked the date and usable quantities.") }
        if batch.candidates.contains(where: { $0.included && $0.onePackageUnknown }) {
            return pantryText("I checked these packages and the amounts shown.")
        }
        return pantryText("I checked these physical packages and usable amounts.")
    }

    private var authorized: Bool {
        scene == .active && model.phase == .ready && model.snapshot?.state.workspaceID == batch.workspaceID &&
            (lookupAccess?.authorized() ?? true) &&
            (initialAccess == nil || (access?.scope == initialAccess?.scope && access?.authorized() == true))
    }
    private var canPresent: Bool {
        if authorized { return true }
        guard model.phase == .ready, model.snapshot?.state.workspaceID == batch.workspaceID,
              let access, access.scope.origin == batch.workspaceID,
              initialAccess == nil || access.scope == initialAccess?.scope else { return false }
        return access.retainsPresentation()
    }

    var body: some View {
        if reviewingLookup, authorized, let row = batch.candidates.first {
            candidateEditor(row, finishEditing: { reviewingLookup = false }, current: { authorized })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() } }
                }
        } else {
            batchForm
        }
    }

    private var batchForm: some View {
        WorkingForm {
            if !canPresent {
                if working, model.busy, model.phase == .ready, scene == .active, let initialAccess,
                   initialAccess.scope.origin == batch.workspaceID, model.snapshot?.state.workspaceID == batch.workspaceID,
                   initialAccess.awaitingSnapshot() {
                    ProgressView(pantryText("Working…")).accessibilityIdentifier("productBatch.refreshing")
                } else {
                    Text(pantryText("Unlock the authorized private workspace to view pantry food."))
                }
            } else if recoveryReadFailed {
                Text(pantryText("The pending pack save could not be opened."))
                Button(pantryText("Retry")) { inspectPending() }
            } else if let recovery, review == nil {
                Section(pantryText("Finish the reviewed pack save")) {
                    ForEach(recovery.rows) { row in
                        VStack(alignment: .leading) { Text(row.name).font(.headline); Text(row.description) }
                    }
                    Button(pantryText("Retry exact save")) { recover(recovery) }.buttonStyle(PrimaryAction())
                    if model.snapshot?.state.revision != recovery.batch.expectedRevision {
                        Button(pantryText("Review current pantry")) { recover(recovery, discardIfStale: true) }
                    }
                }
            } else if saved {
                Text(pantryText("Product batch saved.")).accessibilityIdentifier("productBatch.saved")
                ForEach(batch.candidates.filter(\.included)) { row in
                    if let id = savedRows[row.id], let lot = model.snapshot?.lots.first(where: { $0.id == id }),
                       let access, access.canPresent(), access.scope.origin == batch.workspaceID {
                        Section {
                            PantryBatchHeading(lot: lot)
                            barcodeLookupNote(lot.packageCode)
                            NavigationLink(pantryText("Add a date or reminder")) {
                                PackageDateChoices(model: model, lot: lot, access: access, code: row.barcode, reviewedDateWording: row.reviewedDateWording)
                            }.accessibilityLabel(pantryText("Add a date or reminder") + " · " + lot.packageBatchLabel)
                            .accessibilityIdentifier("pack.date." + String(row.ordinal))
                        }
                    }
                }
                if batch.candidates.isEmpty, let access, access.canPresent() {
                    ForEach(restoredRows) { row in
                        if let lot = model.snapshot?.lots.first(where: { $0.id == row.lotID }) {
                            Section {
                                PantryBatchHeading(lot: lot)
                                barcodeLookupNote(lot.packageCode)
                                NavigationLink(pantryText("Add a date or reminder")) {
                                    PackageDateChoices(model: model, lot: lot, access: access, reviewedDateWording: row.reviewedDateWording)
                                }.accessibilityLabel(pantryText("Add a date or reminder") + " · " + lot.packageBatchLabel)
                            }
                        }
                    }
                }
                Button(pantryText("Done")) {
                    if let savedLotID { didFinishWithLot(savedLotID) }
                    dismiss()
                }
            } else if let review {
                Section(pantryText(atHome ? "Review pantry count" : "Review received products")) {
                    if atHome {
                        ForEach(batch.candidates.filter(\.included)) { row in
                            VStack(alignment: .leading) {
                                Text(row.name).font(.headline)
                                Text(row.reviewEvidenceLine)
                                barcodeLookupNote(row.barcode)
                                if !row.onePackageUnknown {
                                    Text(pantryText("Amount usable") + " · " + pantryPrintedQuantity(row.usable.isEmpty ? row.total?.description ?? "" : row.usable, unit: row.unit))
                                } else if let wording = row.reviewedDateWording {
                                    LabeledContent(pantryText("Printed wording to review"), value: wording)
                                }
                                Text(pantryLocationName(row.location))
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    ForEach(review.facts) { row in
                        let candidate = batch.candidates.first { $0.ordinal == row.ordinal }
                        VStack(alignment: .leading) {
                            Text(row.name).font(.headline)
                            Text(verbatim: candidate?.reviewEvidenceLine ?? row.originalLine)
                            barcodeLookupNote(candidate?.barcode)
                            Text(pantryFormat("Received %@", pantryQuantity(row.received)))
                            Text(pantryFormat("Usable %@", pantryQuantity(row.usable)))
                            switch row.stock {
                            case .added(let location):
                                Text(pantryText("Add a separate physical batch"))
                                Text(pantryLocationName(location))
                            case .linked:
                                Text(pantryText("Link evidence to the delivered batch. Its pantry count stays the same."))
                                if let delivery = candidate?.linkedDelivery {
                                    Text(PantryReceiptDelivery.label(for: delivery.lot, purchase: delivery.purchase))
                                }
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    if !atHome {
                        Text(review.facts.first?.merchant ?? "")
                        Text(date, format: .dateTime.year().month().day())
                    }
                    Button(pantryText(atHome ? "Save pantry count" : "Save received products")) { commit(review) }.buttonStyle(PrimaryAction()).accessibilityIdentifier("productBatch.commit")
                    Button(pantryText("Edit batch")) { self.review = nil; result = nil }
                }.disabled(working)
            } else {
                Section {
                    Picker(pantryText("Package source"), selection: $atHome) {
                        Text(pantryText("Counted at home")).tag(true)
                        Text(pantryText("Received purchase")).tag(false)
                    }.accessibilityIdentifier("pack.source")
                } footer: {
                    Text(pantryText("Choose Counted at home for food you already have."))
                }
                Section(pantryText("Add a product")) {
                    LivePackageButton(workspaceID: batch.workspaceID,
                                      authorized: { authorized && !working && review == nil && !saved }, acceptsTypedLabel: true, receive: scanned)
                    TextField(pantryText("Barcode, if available"), text: $code).focused($focus, equals: "code")
                        .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("productBatch.code")
                    if code.count == 8 && code.allSatisfy(\.isNumber) {
                        Picker(pantryText("Barcode format"), selection: $typedKind) {
                            Text(pantryText("Unknown")).tag("manual")
                            Text(verbatim: "UPC-E").tag("UPC-E")
                            Text(verbatim: "EAN-8").tag("EAN-8")
                        }
                    }
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
                            let kind = code.count == 8 ? typedKind : "manual"
                            let added = try batch.addManual(name: name, code: code, symbology: kind)
                            if added { recognizeNewRows(start: batch.candidates.count - 1) }
                            inputMessage = added ? nil : pantryText("Already in this batch. Change its package count to add another.")
                            if !added {
                                let typed = CapturedBarcode(symbology: kind, value: code.trimmingCharacters(in: .whitespacesAndNewlines))
                                repeatedScan = typed
                                repeatedProductID = batch.candidate(matching: typed)?.id
                            }
                            code = ""; name = ""; focus = nil; confirmed = false
                        } catch { inputMessage = pantryText("Check the product wording and the 12-product batch limit.") }
                    }.disabled(name.isEmpty && code.isEmpty).accessibilityIdentifier("productBatch.add")
                    if let access, access.scope.origin == batch.workspaceID, access.authorized(),
                       let recent = try? memory.recent(access.scope), !recent.isEmpty {
                        DisclosureGroup(pantryText("Recent confirmed packs")) {
                            ForEach(recent.prefix(20), id: \.key) { pack in
                                Button(pack.label) {
                                    let code = pack.barcode.gs1.map { CapturedBarcode(symbology: "manual", value: $0.gtin) } ?? pack.barcode
                                    retailer = pack.retailer
                                    scanned(code)
                                }
                            }
                        }
                    }
                    if let inputMessage {
                        Text(inputMessage).accessibilityIdentifier("productBatch.inputStatus")
                        if let repeatedProductID, let row = batch.candidates.first(where: { $0.id == repeatedProductID }) {
                            Button(pantryText(row.included ? "Edit package count" : "Review skipped product")) {
                                editingCount = row.included
                                editingProduct = row
                            }.accessibilityIdentifier("productBatch.editRepeated")
                            Button(pantryText("Separate batches")) { separate(row, scanned: repeatedScan) }
                        }
                    }
                    PantryProductPhotoInput(workspaceID: batch.workspaceID, consent: $photoConsent,
                        authorized: { authorized && review == nil && !saved }, add: { source in
                        repeatedProductID = nil
                        let start = batch.candidates.count
                        let added = try batch.addPhoto(source)
                        recognizeNewRows(start: start)
                        if added == 0, let code = source.barcodes.first {
                            repeatedProductID = batch.candidate(matching: code)?.id
                            repeatedScan = code
                        }
                        confirmed = false
                        inputMessage = added == 0 ? pantryText("Already in this batch. Change its package count to add another.") : nil
                    }, revoke: { batch.revokePhotos(); confirmed = false })
                }
                if !batch.candidates.isEmpty {
                    Section(pantryText("Products to review")) {
                        ForEach(batch.candidates) { row in
                            productRow(row)
                                .accessibilityIdentifier("productBatch.row." + String(row.ordinal))
                            if row.included && (row.total != nil || row.onePackageUnknown) {
                                Button(pantryText("Separate batches")) { separate(row) }
                                    .accessibilityIdentifier("pack.separate." + String(row.ordinal))
                                    .accessibilityLabel(pantryFormat("Separate batches of %@", row.name))
                            }
                        }
                    }
                    if batch.candidates.allSatisfy({ !$0.included }), let linked = batch.candidates.first(where: { $0.receiptLinkSaved }),
                       let existing = linked.existingReceipt {
                        Button(pantryText("Done")) { didFinishWithLot(existing.lotID); dismiss() }.buttonStyle(PrimaryAction())
                    } else {
                    Section(pantryText("Record these packages")) {
                        if !atHome {
                        TextField(pantryText("Store or branch"), text: $merchant).focused($focus, equals: "merchant")
                            .accessibilityIdentifier("productBatch.merchant")
                        ReceiptDatePicker(title: pantryText("Purchase date"), identifier: "productBatch.purchaseDate", date: $date)
                            .environment(\.timeZone, purchaseTimeZone)
                        }
                        Toggle(confirmationText, isOn: $confirmed)
                            .accessibilityIdentifier("productBatch.received")
                        Button(pantryText(atHome ? "Review pantry count" : "Review received products")) { prepare() }
                            .disabled(!confirmed || working || !model.canEdit || (!atHome && merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            .accessibilityIdentifier("productBatch.review")
                    }
                    }
                }
            }
            if authorized, let result { Text(result).accessibilityIdentifier("productBatch.status") }
        }
        .disabled(working || !authorized)
        .navigationTitle(pantryText("Scan products")).privacySensitive().scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focus != nil, title: pantryText("Done"), identifier: "productBatch.keyboardDone") { focus = nil }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() }.disabled(working) } }
        .interactiveDismissDisabled(working)
        .sheet(item: $editingProduct) { selection in
            NavigationStack {
                if authorized, let row = batch.candidates.first(where: { $0.id == selection.id }) {
                    candidateEditor(row, focusCount: editingCount, finishEditing: { editingProduct = nil }, current: {
                        authorized && editingProduct?.id == selection.id && batch.candidates.contains { $0.id == selection.id }
                    })
                }
            }
        }
        .task(id: access?.scope) { inspectPending() }
        .onChange(of: batch.candidates) { _, _ in confirmed = false }
        .onChange(of: atHome) { _, _ in
            confirmed = false
            for index in batch.candidates.indices {
                batch.candidates[index].stockAction = nil
                batch.candidates[index].onePackageUnknown = false
            }
        }
        .onChange(of: merchant) { _, _ in confirmed = false }
        .onChange(of: date) { old, new in if !Calendar.current.isDate(old, inSameDayAs: new) { confirmed = false } }
        .onChange(of: canPresent) { _, allowed in
            if !allowed {
                editingProduct = nil
                let scope = catalogScope.id
                Task { await PantryProductCatalog.shared.close(scope: scope) }
            }
        }
    }

    @ViewBuilder private func barcodeLookupNote(_ code: CapturedBarcode?) -> some View {
        if code?.lookupScope == .checkDigitsOrFormat {
            Text(pantryText("These digits are kept as entered. Find this batch by food name."))
                .font(.subheadline).accessibilityIdentifier("productBatch.findByName")
        }
    }

    @ViewBuilder private func productRow(_ row: PantryProductBatch.Candidate) -> some View {
        let label = VStack(alignment: .leading) {
            Text(row.name.isEmpty ? (row.barcode?.value ?? pantryText("Product photo")) : row.name)
            if row.existingReceipt != nil { Text(pantryText(row.receiptLinkSaved ? "Linked to a recorded purchase" : "Existing purchase selected · excluded from new stock")).font(.caption) }
            else if !row.included { Text(pantryText("Skipped")).font(.caption) }
            else if row.onePackageUnknown { Text(pantryText("One package, contents unknown")).font(.caption) }
            else if let total = row.total { Text(pantryPrintedQuantity(total.description, unit: row.unit)).font(.caption) }
            else if atHome {
                Text(pantryText("Enter an amount or leave the contents unknown.")).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else { Text(pantryText("Choose a package size and count.")).font(.caption) }
        }
        if #available(iOS 18, *) {
            NavigationLink {
                candidateEditor(row, current: { authorized })
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

    private func candidateEditor(_ row: PantryProductBatch.Candidate, focusCount: Bool = false,
                                 finishEditing: (() -> Void)? = nil, current: @escaping () -> Bool) -> some View {
        PantryProductCandidateEditor(row: captureDraftBinding(row, in: $batch.candidates),
            model: model, access: access, atHome: atHome, deliveries: atHome ? [] : model.productDeliveries,
            scope: catalogScope.id, focusCount: focusCount, finishEditing: finishEditing,
            correctBarcode: correctBarcode, authorized: current)
    }

    private func scanned(_ code: CapturedBarcode) {
        guard authorized else { return }
        do {
            let start = batch.candidates.count
            if try batch.addScan(code) {
                recognizeNewRows(start: start)
                inputMessage = nil; repeatedProductID = nil
            } else {
                repeatedProductID = batch.candidate(matching: code)?.id
                repeatedScan = code
                inputMessage = pantryText("Already in this batch. Change its package count to add another.")
            }
            confirmed = false
        } catch { inputMessage = pantryText("Check the product wording and the 12-product batch limit.") }
    }
    private func recognizeNewRows(start: Int) {
        guard let access, access.authorized(), batch.workspaceID == access.scope.origin else { return }
        for index in start..<batch.candidates.count {
            guard let code = batch.candidates[index].barcode else { continue }
            batch.candidates[index].retailer = retailer
            if let pack = try? memory.match(code, retailer: retailer, scope: access.scope) { batch.candidates[index].use(pack) }
        }
    }
    private func verifyMatches() throws {
        for row in batch.candidates where row.included && row.confirmedPackID != nil {
            guard let access, access.authorized(), access.scope.origin == batch.workspaceID, let code = row.barcode,
                  try memory.match(code, retailer: row.retailer, scope: access.scope) == row.remembered else { throw PantryReceiptError.stale }
        }
    }
    private func separate(_ row: PantryProductBatch.Candidate, scanned: CapturedBarcode? = nil) {
        do {
            try batch.separate(row.id, scanned: scanned)
            editingCount = true; editingProduct = batch.candidates.last
            repeatedProductID = nil; inputMessage = nil
        } catch { inputMessage = pantryText("Check the product wording and the 12-product batch limit.") }
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
                try verifyMatches()
                let proposal = try await atHome ? model.reviewHomePacks(batch) : model.reviewProducts(batch, merchant: store, purchaseDate: purchaseDate, confirmed: confirmed, timeZone: purchaseTimeZone)
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

    private func inspectPending() {
        recoveryReadFailed = false
        guard let access, access.scope.origin == batch.workspaceID, access.authorized(), !working else { return }
        if initialAccess == nil { initialAccess = access }
        guard initialAccess?.scope == access.scope else { return }
        do { recovery = try memory.pending(access.scope) }
        catch { recoveryReadFailed = true }
    }

    private func recover(_ entry: ReviewedPackSave, discardIfStale: Bool = false) {
        guard let access, authorized, access.scope.origin == batch.workspaceID, access.authorized(), !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                guard try memory.pending(access.scope) == entry else { throw PantryReceiptError.stale }
                let applied = try await model.packSaveAlreadyApplied(entry)
                if !applied && discardIfStale {
                    await model.load()
                    guard authorized, let state = model.snapshot?.state, state.revision != entry.batch.expectedRevision,
                          try await !model.packSaveAlreadyApplied(entry) else { throw PantryReceiptError.stale }
                    try memory.clear(entry, scope: access.scope, authorized: access.authorized)
                    recovery = nil; review = nil; confirmed = false; result = nil
                    return
                }
                if !applied { try await model.saveReceipt(entry.review) }
                else { await model.load() }
                guard authorized, access.authorized() else { throw PantryReceiptError.stale }
                try memory.clear(entry, scope: access.scope, authorized: access.authorized)
                restoredRows = entry.rows
                savedLotID = entry.rows.first?.lotID
                savedRows = Dictionary(uniqueKeysWithValues: entry.rows.map { ($0.id, $0.lotID) })
                recovery = nil; saved = true; result = nil
                UIAccessibility.post(notification: .announcement, argument: pantryText("Product batch saved."))
            } catch {
                guard authorized, access.authorized() else { return }
                result = pantryText("The batch could not be saved. Review the current pantry and try again.")
                UIAccessibility.post(notification: .announcement, argument: result)
            }
        }
    }

    private func commit(_ proposal: PantryReceiptReview) {
        guard !working, authorized else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try verifyMatches()
                if let access, access.scope.origin == batch.workspaceID, access.authorized(),
                   let exact = try ReviewedPackSave(review: proposal, intake: batch, scope: access.scope, atHome: atHome) {
                    try memory.stage(exact, scope: access.scope, authorized: access.authorized)
                    recovery = exact
                }
                if atHome { try await model.saveReceipt(proposal) }
                else { try await model.saveProducts(batch, review: proposal) }
                if authorized {
                    if let recovery, let access {
                        try memory.clear(recovery, scope: access.scope, authorized: access.authorized)
                        self.recovery = nil
                    }
                    let physicalIDs = Set(model.snapshot?.lots.map(\.id) ?? [])
                    for row in batch.candidates where row.included {
                        let id = atHome ? row.id : proposal.facts.first(where: { $0.ordinal == row.ordinal })?.lotID
                        if let id, physicalIDs.contains(id) { savedRows[row.id] = id; if savedLotID == nil { savedLotID = id } }
                    }
                    UIAccessibility.post(notification: .announcement, argument: pantryText("Product batch saved."))
                    saved = true; review = nil; result = nil
                }
            } catch {
                await model.load()
                if authorized {
                    if let access, access.authorized() { recovery = try? memory.pending(access.scope) }
                    if recovery != nil { review = nil }
                    result = pantryText("The batch could not be saved. Review the current pantry and try again.")
                    UIAccessibility.post(notification: .announcement, argument: result)
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
    @ObservedObject var model: PantryModel
    let access: PantryDigestAccess?
    let atHome: Bool
    let deliveries: [PantryReceiptDelivery]
    let scope: UUID
    var focusCount = false
    var finishEditing: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
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

    @ViewBuilder private var measuredPackageFields: some View {
        TextField(pantryText("Amount in each package"), text: $row.perPack).focused($field, equals: "size")
            .accessibilityIdentifier("productBatch.packSize")
        Picker(pantryText("Unit"), selection: $row.unit) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
        }
        LabeledContent(pantryText(atHome ? "Packages counted" : "Packages received")) {
            TextField(text: $row.packages, prompt: Text(verbatim: "—")) {
                Text(pantryText(atHome ? "Packages counted" : "Packages received"))
            }
                .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                .focused($field, equals: "count").accessibilityIdentifier("productBatch.packCount")
        }
        if let total = row.total {
            LabeledContent(pantryText("Amount usable")) {
                TextField(row.requiresExplicitUsable ? pantryText("Confirm amount") : total.description, text: $row.usable)
                    .multilineTextAlignment(.trailing).focused($field, equals: "usable")
                    .accessibilityIdentifier("productBatch.usable")
                Text(pantryUnit(row.unit, singular: (try? row.usableQuantity())?.amount == .one))
            }
        }
    }

    var body: some View {
        WorkingForm {
            if authorized() {
                Section {
                    Toggle(pantryText("Include this product"), isOn: $row.included)
                        .disabled(row.existingReceipt != nil).accessibilityIdentifier("productBatch.include")
                    if let code = row.barcode {
                        LabeledContent(pantryText("Barcode"), value: code.displayValue)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pantryText("Barcode")).accessibilityValue(code.displayValue)
                            .accessibilityIdentifier("productBatch.barcodeEvidence")
                        if row.enteredByHand && row.existingReceipt == nil {
                            Button(pantryText("Edit barcode")) {
                                field = nil
                                editingBarcode = true
                            }.accessibilityIdentifier("productBatch.editBarcode")
                        }
                        if code.lookupScope == .checkDigitsOrFormat {
                            Text(pantryText("Check the barcode digits and format. You can still save the food and find it by name."))
                                .font(.subheadline).accessibilityIdentifier("productBatch.codeNeedsReview")
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
                        if atHome && row.allowsOnePackageUnknown {
                            Toggle(pantryText("One package, contents unknown"), isOn: $row.onePackageUnknown)
                                .accessibilityIdentifier("productBatch.oneUnknown")
                        }
                        if row.onePackageUnknown {
                            let title = pantryText("Printed wording to review")
                            VStack(alignment: .leading) {
                                Text(title).font(.caption)
                                TextField(pantryText("Optional"), text: Binding(
                                    get: { row.dateWordingDraft ?? row.reviewedDateWording ?? "" },
                                    set: { row.dateWordingDraft = $0 }
                                ), axis: .vertical)
                                .accessibilityLabel(title).accessibilityIdentifier("productBatch.dateDraft")
                                .focused($field, equals: "dateDraft")
                                Text(pantryText("After saving the food, confirm the package date separately."))
                                    .font(.footnote).foregroundStyle(Theme.secondary)
                            }
                        } else {
                            measuredPackageFields
                        }
                        if row.linkedDelivery == nil {
                            Picker(pantryText("Storage location"), selection: $row.location) {
                                ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                            }
                        }
                    }
                    if row.barcode?.catalogGTIN != nil {
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
                if let access, access.authorized(), access.scope.origin == model.snapshot?.state.workspaceID, row.included || row.existingReceipt != nil {
                    PantryPackMatchEditor(row: $row, model: model, access: access, authorized: authorized)
                }
                if let message { Text(message).accessibilityIdentifier("productBatch.lookupStatus") }
            }
        }
        .navigationTitle(pantryText("Review product")).privacySensitive()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Keep edits")) {
                    if let finishEditing { finishEditing() } else { dismiss() }
                }.accessibilityIdentifier("productBatch.finishEditing")
            }
        }
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

struct PantryProductPhotoInput: View {
    let workspaceID: UUID?
    @Binding var consent: Bool
    let authorized: () -> Bool
    let add: (ScannedSource) throws -> Void
    let revoke: () -> Void
    @Environment(\.pantryDigestPermissionPrompt) private var permissionPrompt
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
                    try await CameraCapturePermission.request(presenting: permissionPrompt?.presenter(for: workspaceID))
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
