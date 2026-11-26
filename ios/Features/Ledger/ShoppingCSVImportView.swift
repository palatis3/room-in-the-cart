import SwiftUI
import UniformTypeIdentifiers
import CoreDomain

struct ShoppingCSVImportView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var table: GroceryCSVTable?
    @State private var mapping: [ShoppingCSVColumn: Int] = [:]
    @State private var review: ShoppingCSVReview?
    @State private var selected: Set<Int> = []
    @State private var showAll = false
    @State private var message: String?

    init(model: LedgerModel, shopID: UUID) {
        self.model = model
        self.shopID = shopID
    }

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID {
                Section {
                    Text(verbatim: shop.title).font(.headline)
                    Button(ledgerText("Choose a shopping CSV")) { choosingFile = true }
                }
                if let table {
                    Section(ledgerText("Match spreadsheet columns")) {
                        ForEach(ShoppingCSVColumn.allCases, id: \.self) { field in
                            Picker(label(field), selection: Binding(get: { mapping[field] ?? -1 }, set: { index in
                                mapping[field] = index < 0 ? nil : index
                                review = nil; selected = []; message = nil
                            })) {
                                Text(ledgerText("Unmapped")).tag(-1)
                                ForEach(table.headers.indices, id: \.self) { index in
                                    Text(verbatim: "\(index + 1) · \(table.headers[index])").tag(index)
                                }
                            }
                        }
                        let valid = mapping[.item] != nil && Set(mapping.values).count == mapping.count
                        if !valid {
                            Text(ledgerText("Choose a distinct column for each field, including the item name.")).font(.footnote)
                        }
                        Button(ledgerText("Preview CSV rows")) { prepare(table, shop: shop) }.disabled(!valid)
                    }
                }
                if let review, review.baseRevision == shop.revision {
                    Section(ledgerText("Review CSV rows")) {
                        Text(ledgerFormat("%lld selected of %lld rows", Int64(selected.count), Int64(review.rows.count)))
                        let flagged = review.rows.filter { $0.status != .ready }.count
                        if flagged > 0 {
                            Text(ledgerFormat("%lld rows need review or were already imported", Int64(flagged)))
                                .foregroundStyle(Theme.secondary)
                        }
                        Text(ledgerText("Matching names start unchecked. Select one only to add a separate item. A quantity without a unit counts as individual items."))
                            .font(.footnote)
                        ForEach(Array(review.rows.prefix(showAll ? review.rows.count : 5))) { row in
                            Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { checked in
                                if checked { selected.insert(row.id) } else { selected.remove(row.id) }
                            })) { rowLabel(row) }
                            .disabled(row.status != .ready && row.status != .matchingName)
                        }
                        if review.rows.count > 5 {
                            Button(ledgerText(showAll ? "Show first five rows" : "Show all CSV rows")) { showAll.toggle() }
                        }
                        Button(ledgerText("Add selected CSV rows")) { save(review) }
                            .disabled(selected.isEmpty || model.saving || model.hasPendingSave)
                    }
                    LedgerSaveStatus(model: model, onRetried: { dismiss() })
                }
                if let message { Text(message).foregroundStyle(Theme.warning) }
            }
        }
        .disabled(model.saving)
        .navigationTitle(ledgerText("Import shopping CSV"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Close")) { dismiss() } } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            guard authorize(), model.shop?.id == shopID else { return }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: GroceryCSVTable.maximumBytes + 1) ?? Data()
                let parsed = try GroceryCSVTable(data: bytes)
                guard parsed.rows.count <= StagedListImport.maximumLines else { throw GroceryCSVTable.ReadError.tooLarge }
                table = parsed; mapping = ShoppingCSVColumn.suggestedMapping(parsed.headers)
                review = nil; selected = []; message = nil; showAll = false
            } catch let error as CocoaError where error.code == .userCancelled {
                return
            } catch {
                table = nil; review = nil; selected = []
                message = ledgerText("Choose a UTF-8 CSV with one header row, up to 1,000 items and 2 MB. Check its separators and quotes.")
            }
        }
        .onChange(of: model.shop?.revisionID) { _, _ in
            if let review, model.shop?.importBatches.contains(where: { $0.id == review.id && $0.undoneAt == nil }) == true {
                dismiss()
            } else if review != nil {
                review = nil; selected = []
                message = ledgerText("The list changed. Preview the CSV again.")
            }
        }
    }

    private func prepare(_ table: GroceryCSVTable, shop: ShoppingLedger) {
        do {
            let result = try ShoppingCSVReview(table: table, mapping: mapping, shop: shop)
            review = result
            selected = Set(result.rows.filter { $0.status == .ready }.map(\.id))
            showAll = false; message = nil
        } catch {
            review = nil; selected = []
            message = ledgerText("Choose a distinct column for each field, including the item name.")
        }
    }

    private func save(_ review: ShoppingCSVReview) {
        let selection = selected
        Task {
            let saved = await model.editShop(key: "shopping-csv-\(review.id)", shopID: shopID,
                authorize: { authorize() && model.shop?.id == shopID }) { current in
                _ = try review.apply(selected: selection, to: &current)
            }
            if saved { dismiss() }
        }
    }

    private func rowLabel(_ row: ShoppingCSVReview.Row) -> some View {
        let record = row.record
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(row.id). \(record.item)").font(.headline)
            if !record.quantityText.isEmpty || !record.unitText.isEmpty {
                LabeledContent(label(.quantity), value: [record.quantityText, record.unitText].filter { !$0.isEmpty }.joined(separator: " "))
            }
            if !record.category.isEmpty { LabeledContent(label(.category), value: record.category) }
            if !record.note.isEmpty { LabeledContent(label(.note), value: record.note) }
            if !record.barcode.isEmpty { LabeledContent(label(.barcode), value: record.barcode) }
            switch row.status {
            case .ready: EmptyView()
            case .matchingName: Text(ledgerText("Matching name on this list or in this file"))
            case .previouslyImported: Text(ledgerText("Already imported on this list"))
            case .wrongColumnCount: Text(ledgerText("Column count differs from the header"))
            case .invalidFields: Text(ledgerText("Missing item name or field exceeds its limit"))
            case .invalidQuantity: Text(ledgerText("Check the quantity and unit in the source file"))
            }
        }
    }

    private func label(_ field: ShoppingCSVColumn) -> String {
        switch field {
        case .item: return ledgerText("Item name")
        case .category: return ledgerText("Department")
        case .note: return ledgerText("Notes")
        case .quantity: return ledgerText("Quantity")
        case .unit: return ledgerText("Unit")
        case .barcode: return ledgerText("Barcode")
        }
    }
}
