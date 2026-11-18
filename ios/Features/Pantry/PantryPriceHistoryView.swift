import CoreDomain
import LocalStore
import SwiftUI

struct PantryPriceHistoryView: View {
    @ObservedObject var model: PantryModel
    @State private var page: PantryPricePage?
    @State private var rows: [PrivatePriceEvidence] = []
    @State private var notice: String?
    @State private var editing = false
    @State private var onlyPaid = false
    @State private var loading = false

    var body: some View {
        List {
            if model.phase != .accessDenied {
                if let notice { Text(notice).accessibilityIdentifier("prices.notice") }
                Button(pantryText("Record a price")) { editing = true }
                    .disabled(page == nil || !model.canEdit).accessibilityIdentifier("prices.add")
                Toggle(pantryText("Show paid prices only"), isOn: $onlyPaid).accessibilityIdentifier("prices.onlyPaid")
                ForEach(rows.filter { !onlyPaid || ($0.isPaidPrice && $0.amountMinor != nil) }) { row in
                    NavigationLink {
                        if let page { PantryPriceDetail(model: model, row: row, state: page.state, history: rows) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: row.name).font(.headline)
                            Text(verbatim: priceSource(row) + " · " + priceAmount(row))
                            Text(verbatim: row.store + " · " + row.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                        }
                    }

                }
                if let page, page.nextReceipt != nil || page.nextStandalone != nil {
                    Button(pantryText("Load more prices")) { Task { await load(more: true) } }.disabled(loading)
                }
            }
        }
        .navigationTitle(pantryText("Private price history"))
        .privacySensitive()
        .task {
            if model.phase == .idle { await model.load() }
            await load()
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .accessDenied { page = nil; rows = []; editing = false; notice = nil }
        }
        .sheet(isPresented: $editing) {
            if let page, model.phase == .ready {
                NavigationStack {
                    PantryPriceEditor(model: model, expected: page.state) {
                        editing = false
                        Task { await load() }
                    }
                }
            }
        }

    }

    @MainActor private func load(more: Bool = false) async {
        guard !loading, model.phase != .accessDenied else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await model.priceHistory(after: more ? page : nil)
            guard !Task.isCancelled, model.phase != .accessDenied else { return }
            rows = ((more ? rows : []) + next.standalone + next.receipts).sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
            }
            page = next
            notice = nil
        } catch {
            rows = []; page = nil
            if model.phase != .accessDenied { notice = pantryText("Prices changed. Reopen the price history to review the current records.") }
        }
    }
}

private struct PantryPriceDetail: View {
    @ObservedObject var model: PantryModel
    @EnvironmentObject private var household: HouseholdModel
    let row: PrivatePriceEvidence
    let state: InventoryState
    let history: [PrivatePriceEvidence]
    @Environment(\.dismiss) private var dismiss
    @State private var adjusting = false
    @State private var correcting = false

    var body: some View {
        List {
            if model.phase != .accessDenied {
                Section {
                    Text(verbatim: priceSource(row))
                    Text(verbatim: priceAmount(row)).font(.title2)
                    if let variant = row.variant { Text(verbatim: variant) }
                    Text(verbatim: [row.store, row.branch].compactMap { $0 }.joined(separator: " · "))
                    if let mode = row.mode { Text(mode.ledgerLabel) }
                    Text(row.date, style: .date)
                    if let pack = row.pack { Text(verbatim: String(pack.count) + " × " + pack.perPackage.originalLiteral) }
                    if let eligibility = row.eligibility { Text(verbatim: eligibility) }
                    if case .paidReceipt(let source) = row.source {
                        LabeledContent(pantryText("Receipt line"), value: source.originalLine)
                        Text(verbatim: source.receiptID.uuidString).font(.caption)
                        if let line = source.documentLine {
                            LabeledContent(pantryText("Page"), value: String(line.page))
                            LabeledContent(pantryText("Line"), value: String(line.line))
                        }
                    } else { Text(verbatim: row.sourceText) }
                }
                if row.currencyCode == "USD", row.amountMinor != nil, row.isPaidPrice || row.source == .shelf || row.source == .currentQuote,
                   let scope = household.projection, scope.enrolled, scope.grantId == nil, !household.locked, household.identity != nil {
                    NavigationLink(HistoryCopy.text("Review for a shared shop")) {
                        PrivatePricePublicationView(pantry: model, household: household, price: row, state: state)
                    }
                }
                if row.revision > 1 {
                    NavigationLink(pantryText("Recorded price revisions")) {
                        PantryPriceRevisionView(model: model, current: row, state: state)
                    }
                }
                if row.isPaidPrice, row.amountMinor != nil {
                    Button(pantryText("Review a credit or refund")) { adjusting = true }
                }
                if row.source == .paidManual || row.source == .shelf {
                    Button(pantryText("Correct recorded price")) { correcting = true }
                }
                if row.isPaidPrice, let unit = row.pack?.perPackage.unit {
                    Section(pantryText("Comparable paid prices")) {
                        ForEach(history.filter { (try? row.comparablePaidPrice(to: $0, in: unit)) == true || $0.id == row.id }) { price in
                            PantryComparablePrice(model: model, price: price, state: state, unit: unit)
                        }
                    }
                }
            }
        }
        .navigationTitle(model.phase == .accessDenied ? "" : row.name).privacySensitive()
        .sheet(isPresented: $adjusting) {
            if model.phase == .ready {
                NavigationStack {
                    PantryPriceCreditEditor(model: model, price: row, state: state) { adjusting = false; dismiss() }
                }
            }
        }
        .sheet(isPresented: $correcting) {
            if model.phase == .ready {
                NavigationStack {
                    PantryPriceEditor(model: model, expected: state, original: row) { correcting = false; dismiss() }
                }
            }
        }
    }
}

private struct PantryPriceRevisionView: View {
    @ObservedObject var model: PantryModel
    let current: PrivatePriceEvidence
    let state: InventoryState
    @State private var revision: Int64 = 1
    @State private var record: PrivatePriceEvidence?
    @State private var failed = false

    var body: some View {
        List {
            if model.phase != .accessDenied {
                Section {
                    Stepper(value: $revision, in: 1...current.revision) {
                        LabeledContent(pantryText("Revision"), value: String(revision))
                    }
                }
                if let record, record.revision == revision {
                    Text(verbatim: record.name)
                    if let variant = record.variant { Text(verbatim: variant) }
                    Text(verbatim: priceSource(record) + " · " + priceAmount(record))
                    Text(verbatim: [record.store, record.branch].compactMap { $0 }.joined(separator: " · "))
                    if let mode = record.mode { Text(mode.ledgerLabel) }
                    Text(record.date, style: .date)
                    if let pack = record.pack { Text(verbatim: String(pack.count) + " × " + pack.perPackage.originalLiteral) }
                    if let terms = record.eligibility { Text(verbatim: terms) }
                    Text(verbatim: record.sourceText)
                } else if failed { Text(pantryText("Prices changed. Reopen the price history.")) }
                else { ProgressView() }
            }
        }
        .navigationTitle(pantryText("Recorded price revisions")).privacySensitive()
        .task(id: revision) {
            failed = false
            do {
                let value = try await model.recordedPriceRevision(current, revision: revision, expected: state)
                guard !Task.isCancelled else { return }
                record = value
            } catch {
                guard !Task.isCancelled else { return }
                record = nil
                failed = true
            }
        }
    }
}

private struct PantryComparablePrice: View {
    @ObservedObject var model: PantryModel
    let price: PrivatePriceEvidence
    let state: InventoryState
    let unit: UnitOfMeasure
    @State private var rate: Rational?

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: price.store + " · " + price.date.formatted(date: .abbreviated, time: .omitted))
            if let rate {
                Text(verbatim: (Decimal(rate.numerator) / Decimal(rate.denominator) / 100).formatted(
                    .currency(code: price.currencyCode).precision(.fractionLength(2...4))) + " / " + pantryUnit(unit))
            } else { Text(pantryText("Unit price unavailable")) }
        }
        .task(id: state.revision) {
            do {
                let adjustments = try await model.priceAdjustments(for: price.id, expected: state)
                guard !Task.isCancelled else { return }
                rate = try price.unitPrice(in: unit, adjustments: adjustments)
            } catch { rate = nil }
        }
    }
}

private struct PantryPriceCreditEditor: View {
    @ObservedObject var model: PantryModel
    let price: PrivatePriceEvidence
    let state: InventoryState
    let didSave: () -> Void
    @Environment(\.locale) private var locale
    @State private var kind = PrivatePriceEvidence.AdjustmentKind.refund
    @State private var amount = ""
    @State private var wording = ""
    @State private var review: PrivatePriceEvidence?
    @State private var notice: String?
    @State private var saving = false

    var body: some View {
        Form {
            if let notice { Text(verbatim: notice) }
            Text(verbatim: price.name + " · " + priceAmount(price))
            if let review {
                Text(verbatim: priceAmount(review) + " · " + priceCreditKind(kind))
                Text(verbatim: review.sourceText)
                Button(pantryText("Save reviewed price")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.writePrice(review, expected: state); didSave() }
                        catch { notice = pantryText("Prices changed. Reopen the price history to review the current records.") }
                    }
                }.disabled(saving)
                Button(pantryText("Edit price")) { self.review = nil }.disabled(saving)
            } else {
                Picker(pantryText("Adjustment type"), selection: $kind) {
                    ForEach(PrivatePriceEvidence.AdjustmentKind.allCases, id: \.self) { Text(priceCreditKind($0)).tag($0) }
                }
                TextField(pantryText("Credit amount"), text: $amount).keyboardType(.decimalPad)
                TextField(pantryText("Price source wording"), text: $wording, axis: .vertical)
                Button(pantryText("Review price")) {
                    do {
                        let minor = try Money(decimal: amount.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")).minorUnits
                        let candidate = PrivatePriceEvidence(id: UUID(), source: .adjustment(target: price.id, revision: price.revision, kind: kind),
                            foodID: price.foodID, linkedLotID: price.linkedLotID, name: price.name, variant: price.variant, store: price.store,
                            branch: price.branch, mode: price.mode, date: Date(), currencyCode: price.currencyCode,
                            amountMinor: minor, pack: nil, sourceText: wording)
                        try candidate.validate()
                        review = candidate
                        notice = nil
                    } catch { notice = pantryText("Review the amount and source wording.") }
                }
            }
        }
        .navigationTitle(pantryText("Review a credit or refund"))
        .interactiveDismissDisabled(saving)
        .privacySensitive()
    }

    private func priceCreditKind(_ kind: PrivatePriceEvidence.AdjustmentKind) -> String {
        switch kind {
        case .refund: pantryText("Refund for this item")
        case .discount: pantryText("Discount for this item")
        case .unallocatedCredit: pantryText("Unallocated credit")
        }
    }
}

private func priceSource(_ row: PrivatePriceEvidence) -> String {
    switch row.source {
    case .paidReceipt: pantryText("Paid on receipt")
    case .paidManual: pantryText("Manually confirmed paid price")
    case .shelf: pantryText("Shelf observation")
    case .currentQuote: pantryText("Checkout quote")
    case .adjustment: pantryText("Price adjustment")
    }
}

private func priceAmount(_ row: PrivatePriceEvidence) -> String {
    guard let minor = row.amountMinor else { return pantryText("Price unknown") }
    return (Decimal(minor) / 100).formatted(.currency(code: row.currencyCode))
}

private struct PantryPriceEditor: View {
    @ObservedObject var model: PantryModel
    let expected: InventoryState
    let original: PrivatePriceEvidence?
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var focused: String?
    @State private var id = UUID()
    @State private var paid = true
    @State private var name = ""
    @State private var variant = ""
    @State private var store = ""
    @State private var branch = ""
    @State private var mode: FulfillmentMode?
    @State private var date = Date()
    @State private var currency = "USD"
    @State private var amount = ""
    @State private var packages = "1"
    @State private var quantity = ""
    @State private var unit = UnitOfMeasure.count
    @State private var eligibility = ""
    @State private var source = ""
    @State private var review: PrivatePriceEvidence?
    @State private var notice: String?
    @State private var saving = false

    init(model: PantryModel, expected: InventoryState, original: PrivatePriceEvidence? = nil, didSave: @escaping () -> Void) {
        self.model = model
        self.expected = expected
        self.original = original
        self.didSave = didSave
        guard let original else { return }
        _id = State(initialValue: original.id)
        _paid = State(initialValue: original.isPaidPrice)
        _name = State(initialValue: original.name)
        _variant = State(initialValue: original.variant ?? "")
        _store = State(initialValue: original.store)
        _branch = State(initialValue: original.branch ?? "")
        _mode = State(initialValue: original.mode)
        _date = State(initialValue: original.date)
        _currency = State(initialValue: original.currencyCode)
        _amount = State(initialValue: original.amountMinor.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? "")
        _packages = State(initialValue: String(original.pack?.count ?? 1))
        if let pack = original.pack {
            _quantity = State(initialValue: pack.perPackage.amount.description)
            _unit = State(initialValue: pack.perPackage.unit)
        }
        _eligibility = State(initialValue: original.eligibility ?? "")
        _source = State(initialValue: original.sourceText)
    }

    var body: some View {
        Form {
            if let notice { Text(notice) }
            if let review {
                Text(verbatim: review.name).font(.headline)
                Text(verbatim: priceSource(review) + " · " + priceAmount(review))
                Text(verbatim: [review.store, review.branch].compactMap { $0 }.joined(separator: " · "))
                if let mode = review.mode { Text(mode.ledgerLabel) }
                Text(review.date, style: .date)
                if let pack = review.pack { Text(verbatim: String(pack.count) + " × " + pack.perPackage.originalLiteral) }
                if let eligibility = review.eligibility { Text(verbatim: eligibility) }
                Text(verbatim: review.sourceText)
                Button(pantryText("Save reviewed price")) {
                    guard !saving else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.writePrice(review, expected: expected); didSave() }
                        catch { notice = pantryText("Prices changed. Reopen the price history to review the current records.") }
                    }
                }.disabled(saving).accessibilityIdentifier("prices.confirm")
                Button(pantryText("Edit price")) { self.review = nil }.disabled(saving)
            } else {
                Picker(pantryText("Price source"), selection: $paid) {
                    Text(pantryText("Manually confirmed paid price")).tag(true)
                    Text(pantryText("Shelf observation")).tag(false)
                }.disabled(original != nil).accessibilityIdentifier("prices.source")
                TextField(pantryText("Product"), text: $name).accessibilityIdentifier("prices.name").focused($focused, equals: "name")
                TextField(pantryText("Brand or variant"), text: $variant).accessibilityIdentifier("prices.variant").focused($focused, equals: "variant")
                TextField(pantryText("Store"), text: $store).accessibilityIdentifier("prices.store").focused($focused, equals: "store")
                TextField(pantryText("Branch"), text: $branch).focused($focused, equals: "branch")
                Picker(pantryText("Shopping mode"), selection: $mode) {
                    Text(pantryText("Not recorded")).tag(nil as FulfillmentMode?)
                    ForEach(FulfillmentMode.allCases, id: \.self) { value in Text(value.ledgerLabel).tag(Optional(value)) }
                }
                DatePicker(pantryText("Price date"), selection: $date, in: ...Date(), displayedComponents: .date)
                Picker(pantryText("Currency"), selection: $currency) {
                    ForEach(PrivatePriceEvidence.supportedCurrencies, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                TextField(pantryText("Total for all packages"), text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("prices.total").focused($focused, equals: "amount")
                Section(pantryText("Package basis")) {
                    TextField(pantryText("Number of packages"), text: $packages).keyboardType(.numberPad).focused($focused, equals: "packages")
                    TextField(pantryText("Quantity per package"), text: $quantity).keyboardType(.decimalPad).accessibilityIdentifier("prices.quantity").focused($focused, equals: "quantity")
                    Picker(pantryText("Unit"), selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                    }
                }
                TextField(pantryText("Promotion or membership conditions"), text: $eligibility).focused($focused, equals: "eligibility")
                TextField(pantryText("Price source wording"), text: $source, axis: .vertical).focused($focused, equals: "source")
                Button(pantryText("Review price")) {
                    do { review = try reviewed(); notice = nil }
                    catch { notice = pantryText("Review the product, store, price and package quantities.") }
                }.accessibilityIdentifier("prices.review")
            }
        }
        .navigationTitle(pantryText("Record a price"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() }.disabled(saving) }

        }
        .keyboardDoneAction(visible: focused != nil, title: pantryText("Done"), identifier: "prices.done") { focused = nil }
        .interactiveDismissDisabled(saving)
        .privacySensitive()
    }

    private func reviewed() throws -> PrivatePriceEvidence {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let name = text(name), let store = text(store), let packages = Int64(packages), packages > 0 else { throw PantryReceiptError.invalid }
        func decimal(_ value: String) -> String {
            guard let separator = locale.decimalSeparator, separator != "." else { return value }
            return value.replacingOccurrences(of: separator, with: ".")
        }
        let pack: PrivatePriceEvidence.Pack?
        if let raw = text(quantity) {
            pack = try .init(count: packages, perPackage: .init(amount: ListQuantityParser.numericAmount(decimal(raw)), unit: unit,
                                                               originalLiteral: raw + " " + pantryUnit(unit)))
        } else { pack = nil }
        guard (original?.revision ?? 0) < Int64.max else { throw PantryReceiptError.invalid }
        let evidence = try PrivatePriceEvidence(id: id, revision: (original?.revision ?? 0) + 1, source: paid ? .paidManual : .shelf,
            foodID: original?.foodID, linkedLotID: original?.linkedLotID, name: name,
            variant: text(variant), store: store, branch: text(branch), mode: mode, date: date, currencyCode: currency,
            amountMinor: text(amount).map { try Money(decimal: decimal($0)).minorUnits }, pack: pack,
            eligibility: text(eligibility), sourceText: text(source) ?? priceSourceWording)
        try evidence.validate()
        return evidence
    }

    private var priceSourceWording: String { paid ? pantryText("Manually confirmed paid price") : pantryText("Shelf observation") }
}
