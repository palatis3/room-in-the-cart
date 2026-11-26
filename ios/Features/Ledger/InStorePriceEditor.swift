import CoreDomain
import SwiftUI

func shelfText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "InStoreBudget")
}

func shelfFormat(_ key: String, _ args: CVarArg...) -> String {
    String(format: shelfText(key), locale: .current, arguments: args)
}

extension PickedShelfPrice {
    /// Price entry asks for a measurement in the rate's unit. An imported record can use a different weight unit.
    func editableMeasurement(locale: Locale) -> String {
        guard let measured, let exact = try? measured.converted(to: unit) else { return "" }
        let original = measured.originalLiteral
        let canonical = original.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        if measured.unit == unit, (try? ComparisonModel.quantity(canonical, unit))?.amount == exact {
            return original
        }
        return exact.description
    }
}

private enum PickPriceMode: String, CaseIterable {
    case total, pack, weight
    var label: String {
        switch self {
        case .total: shelfText("Whole line")
        case .pack: shelfText("Per pack")
        case .weight: shelfText("By weight")
        }
    }
}

struct InStorePriceEditor: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    private let originalShelf: PickedShelfPrice?
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case amount, measurement, discount }
    @FocusState private var field: Field?
    @State private var mode: PickPriceMode
    @State private var amount: String
    @State private var discount: String
    @State private var measurement: String
    @State private var unit: UnitOfMeasure
    @State private var membership: Bool
    @State private var weighted: Bool
    @State private var confirmed: Bool
    @State private var revision: UUID

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.model = model
        self.shop = shop
        self.line = line
        _revision = State(initialValue: shop.revisionID)
        let price = shop.priceForCurrentPick(lineID: line.id)
        let shelf = price?.shelf
        originalShelf = shelf
        _mode = State(initialValue: shelf.map { $0.unit == .count ? .pack : .weight } ?? .total)
        _amount = State(initialValue: (shelf?.rate ?? price?.total).map { (Decimal($0.minorUnits) / 100).description } ?? "")
        _discount = State(initialValue: price?.discount.map { (Decimal($0.minorUnits) / 100).description } ?? "")
        _measurement = State(initialValue: shelf?.editableMeasurement(locale: .current) ?? "")
        _unit = State(initialValue: shelf.flatMap { $0.unit.dimension == .mass ? $0.unit : nil } ?? .pound)
        _membership = State(initialValue: price?.membership ?? false)
        _weighted = State(initialValue: price?.weighted ?? false)
        _confirmed = State(initialValue: price?.conditionsConfirmed ?? false)
    }

    private func entry() throws -> (total: Money?, shelf: PickedShelfPrice?, discount: Money?, net: Money?) {
        let separator = Locale.current.decimalSeparator ?? "."
        let value = try ComparisonModel.money(amount.replacingOccurrences(of: separator, with: "."), currency: shop.basis.currency)
        if let value, !(0...1_000_000_000).contains(value.minorUnits) { throw LedgerError.invalid("pickedPrice") }
        let reduction = try ComparisonModel.money(discount.replacingOccurrences(of: separator, with: "."), currency: shop.basis.currency)
        guard mode != .total else { return try (value, nil, reduction, PickedLinePrice.netPrice(total: value, discount: reduction)) }
        guard let value else { throw LedgerError.invalid("shelfRate") }
        let basis = mode == .pack ? UnitOfMeasure.count : unit
        let literal = measurement.trimmingCharacters(in: .whitespacesAndNewlines)
        let measured: Quantity?
        if let originalShelf, originalShelf.unit == basis, literal == originalShelf.editableMeasurement(locale: .current) {
            measured = originalShelf.measured
        } else {
            let parsed = try ComparisonModel.quantity(literal.replacingOccurrences(of: separator, with: "."), basis)
            measured = parsed.map { Quantity(amount: $0.amount, unit: basis, originalLiteral: literal) }
        }
        let shelf = PickedShelfPrice(rate: value, unit: basis, measured: measured)
        let total = try shelf.lineTotal()
        return try (total, shelf, reduction, PickedLinePrice.netPrice(total: total, discount: reduction))
    }

    var body: some View {
        WorkingForm {
            Section {
                if let summary = shop.packagePickSummary(line) {
                    Text(summary)
                } else if let quantity = try? shop.quantity(forLineID: line.id) {
                    Text(shelfFormat("Requested · %@", ledgerQuantity(quantity)))
                }
                Picker(shelfText("Price basis"), selection: $mode) {
                    ForEach(PickPriceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("inStorePriceBasis")
                if mode == .weight {
                    Picker(shelfText("Price per"), selection: $unit) {
                        ForEach([UnitOfMeasure.pound, .ounce, .kilogram, .gram], id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                WorkingField(amountLabel) {
                    workingTextField(amountLabel, text: $amount).keyboardType(.decimalPad)
                        .focused($field, equals: .amount).accessibilityIdentifier("inStoreAmount")
                }
                if mode != .total {
                    let label = mode == .pack ? shelfText("Packs picked") : shelfFormat("Measured weight (%@)", unit.displayName)
                    WorkingField(label) {
                        workingTextField(label, text: $measurement).keyboardType(mode == .pack ? .numberPad : .decimalPad)
                            .focused($field, equals: .measurement).accessibilityIdentifier("inStoreMeasuredAmount")
                    }
                    if measurement.isEmpty { Text(shelfText("This pick stays unpriced until you enter the measured amount.")).font(.footnote) }
                } else {
                    Toggle(shoppingText("Sold by weight"), isOn: $weighted)
                }
                let discountLabel = shelfFormat("Confirmed discount to subtract (%@, optional)", shop.basis.currency.rawValue)
                WorkingField(discountLabel) {
                    workingTextField(discountLabel, text: $discount).keyboardType(.decimalPad)
                        .focused($field, equals: .discount).accessibilityIdentifier("inStoreDiscount")
                }
                if mode != .total || !discount.isEmpty, let net = (try? entry())?.net {
                    Text(shelfFormat("Picked line total · %@", moneyText(net))).monospacedDigit()
                }
                Toggle(shoppingText("Member price"), isOn: $membership)
                if membership || mode == .total && weighted {
                    Toggle(shoppingText("I confirmed the applicable total"), isOn: $confirmed)
                }
            } header: {
                Text(verbatim: line.name).font(.headline).foregroundStyle(Theme.ink).textCase(nil)
            }
            if (try? entry()) == nil && !discount.isEmpty {
                Text(shelfText("Enter a discount that fits within the picked line price."))
            } else if (try? entry()) == nil && !amount.isEmpty {
                Text(shelfText("Check the shelf price and picked amount. Use a whole number for packs."))
            }
            if model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: { dismiss() })
            }
            Button(shoppingText("Save price"), action: savePrice)
                .disabled((try? entry()) == nil || model.hasPendingSave || model.saving)
        }
        .navigationTitle(shoppingText("Picked item price")).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { keyboardActions }
        .onChange(of: mode) { _, _ in amount = ""; measurement = ""; discount = ""; confirmed = false }
        .onChange(of: discount) { _, _ in confirmed = false }
        .onChange(of: membership) { _, _ in confirmed = false }
        .onChange(of: weighted) { _, _ in confirmed = false }
        .onChange(of: amount) { _, _ in confirmed = false }
        .onChange(of: measurement) { _, _ in confirmed = false }
        .onChange(of: unit) { _, _ in amount = ""; measurement = ""; confirmed = false }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }

    @ViewBuilder private var keyboardActions: some View {
        if field != nil {
            HStack {
                if field == .amount, mode == .total, !membership, !weighted,
                   discount.isEmpty, line.pinnedCoupon == nil, let total = try? entry().total {
                    Button(shelfFormat("Save total %@", moneyText(total)), action: savePrice)
                        .frame(minHeight: 44).disabled(model.hasPendingSave || model.saving)
                        .accessibilityIdentifier("inStoreSaveLineTotal")
                }
                Spacer(minLength: 4)
                Button(ledgerText("Done")) { field = nil }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("inStoreAmountDone")
            }
            .font(.body.weight(.semibold)).padding(.horizontal).background(.bar)
        }
    }

    private func savePrice() {
        guard authorize(), !model.saving, !model.hasPendingSave, let value = try? entry() else { return }
        let isWeighted = mode == .weight || mode == .total && weighted
        let conditionsConfirmed = confirmed || mode == .weight && !membership && value.total != nil
        Task {
            if await model.editShop(key: "picked-price-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                guard model.workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
                try current.recordPickedPrice(lineID: line.id, expectedRevision: revision, total: value.total,
                    membership: membership, weighted: isWeighted, conditionsConfirmed: conditionsConfirmed,
                    shelf: value.shelf, discount: value.discount)
            }) { dismiss() }
        }
    }

    private var amountLabel: String {
        switch mode {
        case .total: shoppingFormat("Total for this picked amount (%@)", shop.basis.currency.rawValue)
        case .pack: shelfFormat("Price per pack (%@)", shop.basis.currency.rawValue)
        case .weight: shelfFormat("Price per %@ (%@)", unit.comparisonLabel(for: .one), shop.basis.currency.rawValue)
        }
    }
}
