import CoreDomain
import LocalStore
import SwiftUI

struct PantryPriceHistoryView: View {
    @ObservedObject var model: PantryModel
    private(set) var dates = ReceiptDateDisplay()
    @Binding var startEntry: Bool
    @State private var page: PantryPricePage?
    @State private var rows: [PrivatePriceEvidence] = []
    @State private var notice: String?
    @State private var editing = false
    @State private var onlyPaid = false
    @State private var loading = false

    var body: some View {
        JournalList {
            if model.phase != .accessDenied {
                if let notice { Text(notice).accessibilityIdentifier("prices.notice") }
                Button(pantryText("Record a price")) { editing = true }
                    .buttonStyle(PrimaryAction())
                    .disabled(page == nil || !model.canEdit).accessibilityIdentifier("prices.add")
                Toggle(pantryText("Show paid prices only"), isOn: $onlyPaid).accessibilityIdentifier("prices.onlyPaid")
                ForEach(rows.filter { !onlyPaid || ($0.isPaidPrice && $0.amountMinor != nil) }) { row in
                    NavigationLink {
                        if let page { PantryPriceDetail(model: model, row: row, state: page.state, history: rows) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: row.name).font(.headline)
                            Text(verbatim: priceAmount(row)).font(.title3.weight(.semibold)).monospacedDigit()
                            Text(verbatim: priceSource(row)).font(.subheadline).foregroundStyle(Theme.secondary)
                            Text(verbatim: row.store + " · " + dates.purchaseDay(row))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }.padding(.vertical, 3)
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
            if startEntry, model.phase == .ready, model.canEdit {
                startEntry = false
                editing = true
            }
            notice = nil
        } catch {
            rows = []; page = nil
            if model.phase != .accessDenied { notice = pantryText("Prices changed. Reopen the price history to review the current records.") }
        }
    }
}

private struct PantryPriceDetail: View {
    @ObservedObject var model: PantryModel
    private(set) var dates = ReceiptDateDisplay()
    @EnvironmentObject private var household: HouseholdModel
    let row: PrivatePriceEvidence
    let state: InventoryState
    let history: [PrivatePriceEvidence]
    @Environment(\.dismiss) private var dismiss
    @State private var adjusting = false
    @State private var correcting = false

    var body: some View {
        JournalList {
            if model.phase != .accessDenied {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: priceSource(row)).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                        Text(verbatim: priceAmount(row)).font(.largeTitle.bold()).monospacedDigit()
                        if let pack = row.pack { Text(verbatim: packageLabel(pack)) }
                    }
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
                    .listRowBackground(Theme.surface)
                    if let image = row.shelfImage {
                        if !image.printed.wording.isEmpty { LabeledContent(pantryText("Printed wording"), value: image.printed.wording) }
                        if let reading = image.printed.reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                        Text(shelfBasisName(image.basis))
                    }
                    if let variant = row.variant { Text(verbatim: variant) }
                    Text(verbatim: [row.store, row.branch].compactMap { $0 }.joined(separator: " · "))
                    if let mode = row.mode { Text(mode.ledgerLabel) }
                    Text(verbatim: dates.purchaseDay(row))
                    if let eligibility = row.eligibility { Text(verbatim: eligibility) }
                    if let tax = row.taxTreatment { Text(shelfTaxLabel(tax)) }
                    if case .paidReceipt(let source) = row.source {
                        LabeledContent(pantryText("Receipt line"), value: source.originalLine)
                        Text(verbatim: source.receiptID.uuidString).font(.caption)
                        if let line = source.documentLine {
                            LabeledContent(pantryText("Page"), value: String(line.page))
                            LabeledContent(pantryText("Line"), value: String(line.line))
                        }
                    } else { Text(verbatim: row.sourceText) }
                }
                if Currency(rawValue: row.currencyCode) != nil, row.shelfCurrencyMatches, row.amountMinor != nil, row.isPaidPrice || row.source == .shelf || row.source == .currentQuote,
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
                if row.source == .paidManual || row.source == .shelf || row.source == .currentQuote {
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
    private(set) var dates = ReceiptDateDisplay()
    let current: PrivatePriceEvidence
    let state: InventoryState
    @State private var revision: Int64 = 1
    @State private var record: PrivatePriceEvidence?
    @State private var failed = false

    var body: some View {
        JournalList {
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
                    Text(verbatim: dates.purchaseDay(record))
                    if let pack = record.pack { Text(verbatim: packageLabel(pack)) }
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
    private(set) var dates = ReceiptDateDisplay()
    let price: PrivatePriceEvidence
    let state: InventoryState
    let unit: UnitOfMeasure
    @State private var rate: Rational?

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: price.store + " · " + dates.purchaseDay(price))
            if let rate {
                Text(verbatim: (Decimal(rate.numerator) / Decimal(rate.denominator) / 100).formatted(
                    .currency(code: price.currencyCode).presentation(.isoCode).precision(.fractionLength(2...4))) + " / " + pantryUnit(unit))
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
        WorkingForm {
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
                        let minor = try Money.minorUnits(decimal: amount.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: "."))
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

private func shelfBasisName(_ basis: ReviewedShelfImage.PriceBasis) -> String {
    switch basis {
    case .bundle: pantryText("Package or multibuy total")
    case .unit: pantryText("Displayed unit price")
    case .unknown: pantryText("Price basis unclear")
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

private func packageLabel(_ pack: PrivatePriceEvidence.Pack) -> String {
    let quantity = pack.perPackage
    // Keep source wording when it already includes a unit. Earlier manual entries
    // appended the plural unit even when the shopper entered a single unit.
    let literal = quantity.originalLiteral.trimmingCharacters(in: .whitespacesAndNewlines)
    let amount: String
    if literal.isEmpty {
        amount = pantryQuantity(quantity)
    } else if quantity.amount == .one, literal.hasSuffix(" " + pantryUnit(quantity.unit)) {
        let number = String(literal.dropLast(pantryUnit(quantity.unit).count + 1))
        amount = (try? ListQuantityParser.numericAmount(number)) == .one
            ? number + " " + pantryUnit(quantity.unit, singular: true) : literal
    } else if literal.contains(where: { $0.isLetter }) {
        amount = literal
    } else {
        amount = literal + " " + pantryUnit(quantity.unit, singular: quantity.amount == .one)
    }
    return pack.count == 1 ? amount : pantryFormat("%@ packages of %@", String(pack.count), amount)
}

private func priceAmount(_ row: PrivatePriceEvidence) -> String {
    guard let minor = row.amountMinor else { return pantryText("Price unknown") }
    return (Decimal(minor) / 100).formatted(.currency(code: row.currencyCode).presentation(.isoCode))
}

private enum PriceEntryKind: CaseIterable {
    case paid, shelf, quote

    var source: PrivatePriceEvidence.Source {
        switch self {
        case .paid: .paidManual
        case .shelf: .shelf
        case .quote: .currentQuote
        }
    }
    var label: String {
        switch self {
        case .paid: pantryText("Manually confirmed paid price")
        case .shelf: pantryText("Shelf observation")
        case .quote: pantryText("Checkout quote")
        }
    }
}

private struct PantryPriceEditor: View {
    @ObservedObject var model: PantryModel
    private(set) var dates = ReceiptDateDisplay()
    let expected: InventoryState
    let original: PrivatePriceEvidence?
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectingImage = false
    @State private var printed: PriceImageLine?
    @State private var priceBasis = ReviewedShelfImage.PriceBasis.unknown
    @FocusState private var focused: String?
    @State private var id = UUID()
    @State private var entryKind: PriceEntryKind?
    @State private var name = ""
    @State private var variant = ""
    @State private var store = ""
    @State private var branch = ""
    @State private var mode: FulfillmentMode?
    @State private var date = Date()
    @State private var currency = Currency.groceryDefault().rawValue
    @State private var amount = ""
    @State private var packages = "1"
    @State private var quantity = ""
    @State private var unit = UnitOfMeasure.count
    @State private var eligibility = ""
    @State private var tax: PrivatePriceEvidence.TaxTreatment?
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
        _printed = State(initialValue: original.shelfImage?.printed)
        _priceBasis = State(initialValue: original.shelfImage?.basis ?? .unknown)
        _entryKind = State(initialValue: PriceEntryKind.allCases.first { $0.source == original.source })
        _name = State(initialValue: original.name)
        _variant = State(initialValue: original.variant ?? "")
        _store = State(initialValue: original.store)
        _branch = State(initialValue: original.branch ?? "")
        _mode = State(initialValue: original.mode)
        _date = State(initialValue: original.date)
        _currency = State(initialValue: original.currencyCode)
        _amount = State(initialValue: original.amountMinor.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? "")
        if let image = original.shelfImage {
            let currencies = ReviewedShelfImage.priceCurrencies(in: image.printed.effectiveWording)
            if !currencies.contains(original.currencyCode) {
                _currency = State(initialValue: currencies.count == 1 ? currencies[0] : "")
                _amount = State(initialValue: "")
            }
        }
        _packages = State(initialValue: String(original.pack?.count ?? 1))
        if let pack = original.pack {
            _quantity = State(initialValue: pack.perPackage.amount.description)
            _unit = State(initialValue: pack.perPackage.unit)
        }
        _eligibility = State(initialValue: original.eligibility ?? "")
        _tax = State(initialValue: original.taxTreatment)
        _source = State(initialValue: original.sourceText)
    }

    var body: some View {
        WorkingForm {
            if let notice { Text(notice) }
            if let review {
                Text(verbatim: review.name).font(.headline)
                Text(verbatim: priceSource(review) + " · " + priceAmount(review))
                Text(verbatim: [review.store, review.branch].compactMap { $0 }.joined(separator: " · "))
                if let mode = review.mode { Text(mode.ledgerLabel) }
                Text(verbatim: dates.purchaseDay(review))
                if let pack = review.pack { Text(verbatim: packageLabel(pack)) }
                if let eligibility = review.eligibility { Text(verbatim: eligibility) }
                if let tax = review.taxTreatment { Text(shelfTaxLabel(tax)) }
                if let shelf = review.shelfImage {
                    Text(shelfBasisName(shelf.basis))
                    if !shelf.printed.wording.isEmpty { Text(verbatim: shelf.printed.wording) }
                    if let reading = shelf.printed.reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                }
                Text(verbatim: review.sourceText)
                Button(pantryText("Save reviewed price")) {
                    guard !saving else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.writePrice(review, expected: expected); didSave() }
                        catch PantryPriceError.imageAlreadySaved { notice = pantryText("This image line already has a saved price. Open that record to review a correction.") }
                        catch { notice = pantryText("Prices changed. Reopen the price history to review the current records.") }
                    }
                }.buttonStyle(PrimaryAction()).disabled(saving).accessibilityIdentifier("prices.confirm")
                Button(pantryText("Edit price")) { self.review = nil }.disabled(saving)
            } else if entryKind == nil {
                Section(pantryText("Price source")) {
                    ForEach(PriceEntryKind.allCases, id: \.self) { kind in
                        Button(kind.label) { entryKind = kind }
                    }
                }
            } else {
                PriceChoice("Price source", value: entryKind?.label ?? "", selection: $entryKind) {
                    ForEach(PriceEntryKind.allCases, id: \.self) { value in Text(value.label).tag(Optional(value)) }
                }.disabled(original != nil).accessibilityIdentifier("prices.source")
                if entryKind == .shelf {
                    if original == nil {
                        Button(pantryText("Read a shelf label")) { selectingImage = true }.accessibilityIdentifier("prices.readShelf")
                    }
                    if let printed {
                        if !printed.wording.isEmpty { Text(verbatim: printed.wording) }
                        if let reading = printed.reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                        if printed.uncertain { Text(pantryText("Uncertain image wording")) }
                        PriceChoice("Printed price basis", value: shelfBasisName(priceBasis), selection: $priceBasis) {
                            Text(pantryText("Package or multibuy total")).tag(ReviewedShelfImage.PriceBasis.bundle)
                            Text(pantryText("Displayed unit price")).tag(ReviewedShelfImage.PriceBasis.unit)
                            Text(pantryText("Price basis unclear")).tag(ReviewedShelfImage.PriceBasis.unknown)
                        }
                    }
                }
                TextField(pantryText("Product"), text: $name).accessibilityIdentifier("prices.name").focused($focused, equals: "name")
                TextField(pantryText("Brand or variant"), text: $variant).accessibilityIdentifier("prices.variant").focused($focused, equals: "variant")
                TextField(pantryText("Store"), text: $store).accessibilityIdentifier("prices.store").focused($focused, equals: "store")
                TextField(pantryText("Branch"), text: $branch).focused($focused, equals: "branch")
                PriceChoice("Shopping mode", value: mode?.ledgerLabel ?? pantryText("Not recorded"), selection: $mode) {
                    Text(pantryText("Not recorded")).tag(nil as FulfillmentMode?)
                    ForEach(FulfillmentMode.allCases, id: \.self) { value in Text(value.ledgerLabel).tag(Optional(value)) }
                }
                ReceiptDatePicker(title: pantryText("Price date"), identifier: "prices.date", date: $date)
                let currencies = printed.map { ReviewedShelfImage.priceCurrencies(in: $0.effectiveWording) } ?? PrivatePriceEvidence.supportedCurrencies
                if currencies.isEmpty {
                    Text(pantryText("This label has no single supported currency. You can save the wording with the price unknown."))
                } else {
                    if let code = currencies.first, currencies.count == 1 {
                        LabeledContent(pantryText("Currency"), value: code)
                    } else {
                        PriceChoice("Currency", value: currency.isEmpty ? pantryText("Choose the printed currency") : currency, selection: $currency) {
                            if printed != nil { Text(pantryText("Choose the printed currency")).tag("") }
                            ForEach(currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                    }
                    TextField(entryKind == .shelf && printed != nil ? pantryText("Printed price amount") : pantryText("Total for all packages"), text: $amount)
                        .keyboardType(.decimalPad).accessibilityIdentifier("prices.total").focused($focused, equals: "amount")
                }
                Section(pantryText("Package basis")) {
                    if entryKind != .shelf || printed == nil || priceBasis != .unit {
                        WorkingField(pantryText("Number of packages")) {
                            TextField(pantryText("Number of packages"), text: $packages).keyboardType(.numberPad)
                                .focused($focused, equals: "packages").accessibilityIdentifier("prices.packages")
                        }
                    }
                    TextField(entryKind == .shelf && printed != nil && priceBasis == .unit ? pantryText("Printed unit-price quantity") : pantryText("Quantity per package"), text: $quantity).keyboardType(.decimalPad).accessibilityIdentifier("prices.quantity").focused($focused, equals: "quantity")
                    PriceChoice("Unit", value: pantryUnit(unit), selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                    }
                }
                TextField(pantryText("Promotion or membership conditions"), text: $eligibility).focused($focused, equals: "eligibility")
                ShelfTaxPicker(tax: $tax)
                if entryKind == .shelf {
                    let entered = try? reviewed()
                    ShelfPaidPriceView(model: model, offer: ShelfPriceOffer(product: name, variant: variant,
                        pack: entered?.pack, amountMinor: entered?.amountMinor, currency: currency, eligibility: eligibility, tax: tax),
                        asOf: date, store: [store, branch].filter { !$0.isEmpty }.joined(separator: " · "),
                        isUnitLabel: printed != nil && priceBasis == .unit)
                }
                TextField(pantryText("Price source wording"), text: $source, axis: .vertical).focused($focused, equals: "source")
                Button(pantryText("Review price")) {
                    do { review = try reviewed(); notice = nil }
                    catch { notice = pantryText("Review the product, store, price and package quantities.") }
                }.buttonStyle(PrimaryAction()).accessibilityIdentifier("prices.review")
            }
        }
        .onChange(of: entryKind) { _, newKind in
            guard newKind != .shelf, printed != nil else { return }
            printed = nil
            priceBasis = .unknown
            currency = Currency.groceryDefault(for: locale).rawValue
            amount = ""
            packages = "1"
            quantity = ""
            eligibility = ""
            source = ""
        }
        .sheet(isPresented: $selectingImage) {
            NavigationStack {
                PriceImageReview(purpose: .shelf, authorized: { model.permitsReceiptSource && model.snapshot?.state == expected }, acceptShelf: { line in
                    guard model.permitsReceiptSource && model.snapshot?.state == expected else { return }
                    printed = line
                    source = line.effectiveWording
                    let suggestion = ReviewedShelfImage.propose(line.effectiveWording)
                    currency = suggestion.currencyCode ?? ""
                    packages = String(suggestion.packages ?? 1)
                    let canPrice = suggestion.currencyCode != nil || suggestion.currencyUnspecified
                    amount = canPrice ? suggestion.amountMinor.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? "" : ""
                    eligibility = suggestion.conditions ?? ""
                    priceBasis = suggestion.priceBasis
                    let measurement = suggestion.rateQuantity ?? suggestion.packageSize
                    quantity = measurement?.amount.description ?? ""
                    unit = measurement?.unit ?? .count
                })
            }
        }
        .navigationTitle(pantryText(original == nil ? "Record a price" : "Correct recorded price"))
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
        guard let entryKind, let name = text(name), let store = text(store), let packages = Int64(packages), packages > 0 else { throw PantryReceiptError.invalid }
        func decimal(_ value: String) -> String {
            guard let separator = locale.decimalSeparator, separator != "." else { return value }
            return value.replacingOccurrences(of: separator, with: ".")
        }
        let pack: PrivatePriceEvidence.Pack?
        if let raw = text(quantity) {
            let reviewedCount = entryKind == .shelf && printed != nil && priceBasis == .unit ? 1 : packages
            pack = try .init(count: reviewedCount, perPackage: .init(amount: ListQuantityParser.numericAmount(decimal(raw)), unit: unit,
                                                               originalLiteral: raw))
        } else { pack = nil }
        guard (original?.revision ?? 0) < Int64.max else { throw PantryReceiptError.invalid }
        let image = entryKind != .shelf ? nil : printed.map { ReviewedShelfImage(printed: $0, basis: priceBasis) }
        let evidence = try PrivatePriceEvidence(id: image?.printed.shelfID ?? id, revision: (original?.revision ?? 0) + 1, source: entryKind.source,
            foodID: original?.foodID, linkedLotID: original?.linkedLotID, name: name,
            variant: text(variant), store: store, branch: text(branch), mode: mode, date: date, currencyCode: currency,
            amountMinor: text(amount).map { try Money.minorUnits(decimal: decimal($0)) }, pack: pack,
            eligibility: text(eligibility), sourceText: text(source) ?? entryKind.label, shelfImage: image, taxTreatment: tax)
        try evidence.validateForRecording()
        return evidence
    }

}

private func shelfTaxLabel(_ value: PrivatePriceEvidence.TaxTreatment?) -> String {
    switch value {
    case .included: pantryText("Tax included")
    case .excluded: pantryText("Tax excluded")
    case nil: pantryText("Tax treatment unrecorded")
    }
}

private struct PriceChoice<Value: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    @ViewBuilder let options: Options
    @Environment(\.dynamicTypeSize) private var size

    init(_ key: String, value: String, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        title = pantryText(key)
        self.value = value
        _selection = selection
        self.options = options()
    }

    var body: some View {
        let picker = Picker(title, selection: $selection) { options }
        if size.isAccessibilitySize {
            Menu {
                picker
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
                    HStack {
                        Text(verbatim: value)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title).accessibilityValue(value)
        } else { picker }
    }
}

struct ShelfTaxPicker: View {
    @Binding var tax: PrivatePriceEvidence.TaxTreatment?
    var body: some View {
        PriceChoice("Tax treatment", value: tax.map { shelfTaxLabel($0) } ?? pantryText("Not recorded"), selection: $tax) {
            Text(pantryText("Not recorded")).tag(nil as PrivatePriceEvidence.TaxTreatment?)
            Text(pantryText("Tax included")).tag(Optional(PrivatePriceEvidence.TaxTreatment.included))
            Text(pantryText("Tax excluded")).tag(Optional(PrivatePriceEvidence.TaxTreatment.excluded))
        }
    }
}

struct ShelfPaidPriceView: View {
    @ObservedObject var model: PantryModel
    let offer: ShelfPriceOffer
    let asOf: Date
    let store: String
    var isUnitLabel = false
    @Environment(\.locale) private var locale
    @State private var records: [PrivatePriceEvidence] = []
    @State private var state: InventoryState?
    @State private var loadedProduct: String?
    @State private var failed = false
    @State private var choice: UUID?
    @State private var confirmed = false
    @State private var adjustments: [PrivatePriceEvidence]?
    @State private var adjustmentPrice: UUID?
    private var product: String { ShelfPriceOffer.normalized(offer.product) }
    private var candidates: [PrivatePriceEvidence] { offer.candidates(in: records, through: asOf) }
    private var purchase: PrivatePriceEvidence? { offer.purchase(in: candidates, chosenID: choice) }
    private var purchaseChoices: [PrivatePriceEvidence] {
        var variants: Set<String> = []
        return candidates.filter { row in
            guard let variant = row.variant else { return true }
            return variants.insert(ShelfPriceOffer.normalized(variant)).inserted
        }
    }

    var body: some View {
        Group {
            if model.phase != .accessDenied && !product.isEmpty {
                if failed {
                    Text(pantryText("Private price history is unavailable."))
                } else if loadedProduct != product {
                    ProgressView(pantryText("Looking up paid prices"))
                } else {
                    priceRows
                }
            }
        }
        .privacySensitive()
        .task(id: product) {
            loadedProduct = nil; choice = nil; confirmed = false; failed = false
            records = []; state = nil
            guard !product.isEmpty, model.phase != .accessDenied else { return }
            do {
                let history = try await model.paidPurchases(named: product)
                try Task.checkCancellation()
                guard model.phase != .accessDenied else { return }
                records = history.prices; state = history.state; loadedProduct = product
            } catch { if !Task.isCancelled { failed = true } }
        }
        .task(id: purchase?.id) {
            adjustmentPrice = nil; adjustments = nil
            guard let paid = purchase, let state else { return }
            let credits = try? await model.paidPurchaseCredits(for: paid, expected: state)
            guard !Task.isCancelled, model.phase != .accessDenied else { return }
            adjustments = credits; adjustmentPrice = paid.id
        }
        .onChange(of: offer) { prior, next in
            if prior.variant != next.variant || prior.tax != next.tax || prior.eligibility != next.eligibility || prior.pack != next.pack { confirmed = false }
            if prior.variant != next.variant { choice = nil }
        }
        .onChange(of: purchase?.id) { _, _ in confirmed = false }
    }

    @ViewBuilder private var priceRows: some View {
        if candidates.isEmpty || offer.amountMinor == nil {
            Text(pantryText("No comparable paid price")).accessibilityIdentifier("prices.noComparable")
        } else {
            if ShelfPriceOffer.normalized(offer.variant).isEmpty || candidates.contains(where: { $0.variant == nil }) || choice != nil {
                Picker(pantryText("Choose the matching purchase"), selection: $choice) {
                    Text(pantryText("Choose a purchase")).tag(nil as UUID?)
                    ForEach(purchaseChoices) { row in
                        Text(verbatim: purchaseLabel(row)).tag(Optional(row.id))
                    }
                }
            }
            if let paid = purchase, let pack = paid.pack, let shelfPack = offer.pack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(pantryText("Last comparable purchase")).font(.headline)
                    Text(verbatim: purchaseLabel(paid))
                    Text(verbatim: packageLabel(pack))
                    if let usable = paid.confirmedUsable {
                        Text(verbatim: pantryText("Confirmed usable amount") + " · " + pantryQuantity(usable))
                    }
                    if let mode = paid.mode { Text(verbatim: mode.ledgerLabel) }
                    Text(verbatim: priceAmount(paid))
                    Text(verbatim: paid.eligibility ?? pantryText("Offer conditions unrecorded"))
                    Text(verbatim: shelfTaxLabel(paid.taxTreatment))
                }.accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pantryText("Current shelf offer")).font(.headline)
                    Text(verbatim: store.isEmpty ? ledgerText("Store not set") : store)
                    Text(asOf, style: .date)
                    Text(verbatim: (isUnitLabel ? pantryText("Printed unit-price quantity") + " · " : "") + packageLabel(shelfPack))
                    if let amount = offer.amountMinor { Text(verbatim: (Decimal(amount) / 100).formatted(.currency(code: offer.currency).presentation(.isoCode).locale(locale))) }
                    Text(verbatim: offer.eligibility.isEmpty ? pantryText("Offer conditions unrecorded") : offer.eligibility)
                    Text(verbatim: shelfTaxLabel(offer.tax))
                }.accessibilityElement(children: .combine)
                let needsReview = offer.needsBasisConfirmation(for: paid)
                if needsReview {
                    Toggle(pantryText("I checked that the variant, usable quantity basis, tax and offer conditions match"),
                           isOn: $confirmed).accessibilityIdentifier("prices.sameBasis")
                }
                if confirmed || !needsReview, adjustmentPrice == paid.id, let adjustments,
                   let rates = try? offer.unitRates(for: paid, adjustments: adjustments, sameBasisConfirmed: confirmed) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pantryText(rates.shelf == rates.paid ? "Same price per unit" :
                                (rates.shelf < rates.paid ? "Shelf price is lower per unit" : "Shelf price is higher per unit")))
                            .font(.headline)
                        Text(verbatim: pantryFormat("Shelf per %@: %@", pantryUnit(shelfPack.perPackage.unit, singular: true), rate(rates.shelf)))
                        Text(verbatim: pantryFormat("Paid per %@ after recorded credits: %@", pantryUnit(shelfPack.perPackage.unit, singular: true), rate(rates.paid)))
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("prices.paidComparison")
                } else if confirmed || !needsReview, adjustmentPrice == paid.id {
                    Text(pantryText("No comparable paid price"))
                }
            } else { Text(pantryText("No comparable paid price")) }
        }

    }

    private func purchaseLabel(_ price: PrivatePriceEvidence) -> String {
        let identity = price.variant ?? price.sourceText
        return [price.name, identity, price.store, price.branch, price.date.formatted(.dateTime.year().month().day().locale(locale))]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private func rate(_ cents: Rational) -> String {
        (Decimal(cents.numerator) / Decimal(cents.denominator) / 100).formatted(
            .currency(code: offer.currency).presentation(.isoCode).precision(.fractionLength(2...6)).locale(locale))
    }
}
