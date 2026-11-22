import CoreDomain
import SwiftUI

struct PantryPackMatchEditor: View {
    @Binding var row: PantryProductBatch.Candidate
    @ObservedObject var model: PantryModel
    let access: PantryDigestAccess
    let authorized: () -> Bool
    @ObservedObject private var memory = PantryDigestStore.shared.packMemory
    @State private var savedMatch: ConfirmedPantryPack?
    @State private var status: String?
    private var source: ReceiptAcquisition? { row.existingReceipt }
    @State private var showingReceipts = false
    @State private var loading = false
    private(set) var dates = ReceiptDateDisplay()
    private var size: Quantity? { try? ComparisonModel.quantity(row.perPack, row.unit) }

    var body: some View {
        if let code = row.barcode {
            Section {
                if code.catalogGTIN == nil {
                    TextField(pantryText("Retailer for this code"), text: $row.retailer)
                        .accessibilityIdentifier("pack.retailer")
                }
                if let savedMatch {
                    Text(savedMatch.label)
                    if row.confirmedPackID != savedMatch.id && source == nil {
                        Button(pantryText("Use this confirmed pack")) { row.use(savedMatch); status = nil }
                    }
                }
                if let source {
                    Text(verbatim: source.originalLine)
                    Text(source.merchant + " · " + dates.purchaseDay(source, style: .abbreviated))
                    if row.receiptLinkSaved {
                        Text(pantryText("Linked to the saved receipt line. Stock stays the same."))
                    } else {
                        Button(pantryText("Confirm link to this receipt line")) { Task { await linkReceipt(source, code: code) } }
                            .buttonStyle(PrimaryAction()).disabled(loading)
                        Button(pantryText("Return to adding new stock")) {
                            row.existingReceipt = nil; row.included = true
                        }
                    }
                } else {
                    Button(pantryText("This purchase is already recorded")) { showingReceipts = true }
                }
                if code.associationKey(retailer: row.retailer) != nil {
                    if source != nil {
                        TextField(pantryText("Amount in each package"), text: $row.perPack)
                        Picker(pantryText("Unit"), selection: $row.unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                        }
                    }
                    Button(pantryText(savedMatch == nil ? "Remember this exact pack" : "Correct remembered pack")) {
                        Task { await remember(code) }
                    }
                    .disabled(loading || (size?.amount ?? .zero) <= .zero || row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (row.confirmedPackID == savedMatch?.id && savedMatch != nil && source == nil && row.linkedDelivery == nil))
                    .accessibilityIdentifier("pack.remember")
                    if let savedMatch {
                        Button(pantryText("Forget this barcode match"), role: .destructive) {
                            do {
                                try memory.replace(savedMatch, with: nil, scope: access.scope, authorized: current)
                                row.remembered = nil; self.savedMatch = nil
                                status = pantryText("Barcode match forgotten.")
                            } catch { changed() }
                        }
                    }
                }
                if let status { Text(status) }
            } header: {
                Text(pantryText("Recognize this pack next time"))
            } footer: {
                Text(pantryText("Remembering saves the barcode, name and pack size. Review the pantry count separately to add food."))
            }
            .sheet(isPresented: $showingReceipts) {
                NavigationStack {
                    PackReceiptPicker(model: model, authorized: current) { selected in
                        row.selectExistingReceipt(selected)
                        row.name = selected.name
                        showingReceipts = false
                    }
                }
            }
            .task(id: code.id + "/" + row.retailer + memory.generation.uuidString) {
                guard current() else { savedMatch = nil; return }
                do { savedMatch = try memory.match(code, retailer: row.retailer, scope: access.scope) } catch { changed() }
            }
        }
    }
    private func current() -> Bool {
        access.authorized() && authorized() && model.canEdit && model.snapshot?.state.workspaceID == access.scope.origin
    }
    private func changed() { status = pantryText("The match changed. Reopen this pack to review it.") }
    private func linkReceipt(_ source: ReceiptAcquisition, code: CapturedBarcode) async {
        guard current(), row.existingReceipt == source else { return }
        loading = true; defer { loading = false }
        do {
            let latest = try await model.latestReceiptRevision(source)
            guard latest == source, let lot = model.snapshot?.lots.first(where: { $0.id == source.lotID }) else { throw PantryReceiptError.stale }
            try await model.verifyDigestLot(lot, origin: access.scope.origin)
            guard current(), row.existingReceipt == source, row.barcode == code else { throw PantryReceiptError.stale }
            if let known = lot.packageCode, let gtin = known.canonicalGTIN, let read = code.canonicalGTIN, gtin != read { throw ProductBatchError.invalid }
            if let known = lot.packageCode?.gs1?.lot, let read = code.gs1?.lot, known != read { throw ProductBatchError.invalid }
            let link = RecordedPackReceiptLink(id: row.id, receiptID: source.receiptID, lineID: source.lineID, lotID: source.lotID, code: code)
            try memory.link(link, scope: access.scope, authorized: current)
            row.receiptLinkSaved = true
            status = nil
        } catch { changed() }
    }
    private func remember(_ code: CapturedBarcode) async {
        guard current(), !loading, let size, size.amount > .zero else { return }
        loading = true; defer { loading = false }
        do {
            var foodID = UUID()
            var lotID: UUID?
            if let source {
                let latest = try await model.latestReceiptRevision(source)
                guard latest == source, let lot = model.snapshot?.lots.first(where: { $0.id == source.lotID }) else { throw ProductBatchError.invalid }
                try await model.verifyDigestLot(lot, origin: access.scope.origin)
                foodID = lot.foodID; lotID = lot.id
            } else if let delivery = row.linkedDelivery {
                guard model.productDeliveries.contains(delivery) else { throw ProductBatchError.changedDelivery }
                try await model.verifyDigestLot(delivery.lot, origin: access.scope.origin)
                foodID = delivery.lot.foodID; lotID = delivery.lot.id
            }
            let next = ConfirmedPantryPack(id: foodID, barcode: code, retailer: code.catalogGTIN == nil ? row.retailer : "",
                name: row.name.trimmingCharacters(in: .whitespacesAndNewlines), size: size, attribution: row.appliedCatalog?.attribution,
                confirmedAt: Date(), evidenceLotID: lotID, evidenceLineID: source?.lineID)
            try memory.replace(savedMatch, with: next, scope: access.scope, authorized: current)
            savedMatch = next; row.use(next)
            status = pantryText("Exact pack remembered.")
        } catch { changed() }
    }
}

private struct PackReceiptPicker: View {
    @ObservedObject var model: PantryModel
    let authorized: () -> Bool
    let select: (ReceiptAcquisition) -> Void
    @State private var lines: [ReceiptAcquisition] = []
    @State private var cursor: UUID?
    @State private var loaded = false
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss
    private(set) var dates = ReceiptDateDisplay()
    var body: some View {
        JournalList {
            if authorized() {
                ForEach(lines) { line in
                    Button {
                        if authorized() { select(line) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(line.name).font(.headline)
                            Text(verbatim: line.originalLine)
                            Text(line.merchant + " · " + dates.purchaseDay(line, style: .abbreviated))
                            Text(pantryQuantity(line.received))
                        }
                    }
                }
                if cursor != nil { Button(pantryText("More receipt lines")) { Task { await load() } } }
                if loaded && lines.isEmpty { Text(pantryText("No saved receipt lines.")) }
                if let status { Text(status) }
            }
        }
        .navigationTitle(pantryText("Choose the exact receipt line"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() } } }
        .task { if !loaded { await load() } }
    }
    private func load() async {
        guard authorized() else { return }
        do {
            let page = try await model.receiptHistory(after: cursor)
            guard authorized() else { return }
            cursor = page.count == 30 ? page.last?.id : nil
            let known = Set(lines.map(\.id))
            lines += page.filter { line in !known.contains(line.id) && model.snapshot?.lots.contains(where: { lot in lot.id == line.lotID }) == true }
            loaded = true
        } catch { status = pantryText("Reopen the receipt to review its current lines.") }
    }
}
