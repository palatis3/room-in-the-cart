import CoreDomain
import SwiftUI

func shelfText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "InStoreBudget")
}

func shelfFormat(_ key: String, _ args: CVarArg...) -> String {
    String(format: shelfText(key), locale: .current, arguments: args)
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
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingAmount: Bool
    @State private var mode: PickPriceMode
    @State private var amount: String
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
        _mode = State(initialValue: shelf.map { $0.unit == .count ? .pack : .weight } ?? .total)
        _amount = State(initialValue: (shelf?.rate ?? price?.total).map { (Decimal($0.minorUnits) / 100).description } ?? "")
        _measurement = State(initialValue: shelf?.measured?.originalLiteral ?? "")
        _unit = State(initialValue: shelf.flatMap { $0.unit.dimension == .mass ? $0.unit : nil } ?? .pound)
        _membership = State(initialValue: price?.membership ?? false)
        _weighted = State(initialValue: price?.weighted ?? false)
        _confirmed = State(initialValue: price?.conditionsConfirmed ?? false)
    }

    private func entry() throws -> (total: Money?, shelf: PickedShelfPrice?) {
        let separator = Locale.current.decimalSeparator ?? "."
        let value = try ComparisonModel.money(amount.replacingOccurrences(of: separator, with: "."), currency: shop.basis.currency)
        if let value, !(0...1_000_000_000).contains(value.minorUnits) { throw LedgerError.invalid("pickedPrice") }
        guard mode != .total else { return (value, nil) }
        guard let value else { throw LedgerError.invalid("shelfRate") }
        let basis = mode == .pack ? UnitOfMeasure.count : unit
        let literal = measurement.trimmingCharacters(in: .whitespacesAndNewlines)
        let measured = try ComparisonModel.quantity(literal.replacingOccurrences(of: separator, with: "."), basis)
        let shelf = PickedShelfPrice(rate: value, unit: basis,
            measured: measured.map { Quantity(amount: $0.amount, unit: basis, originalLiteral: literal) })
        return try (shelf.lineTotal(), shelf)
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
                        .focused($editingAmount).accessibilityIdentifier("inStoreAmount")
                }
                if mode != .total {
                    let label = mode == .pack ? shelfText("Packs picked") : shelfFormat("Measured weight (%@)", unit.displayName)
                    WorkingField(label) {
                        workingTextField(label, text: $measurement).keyboardType(mode == .pack ? .numberPad : .decimalPad)
                            .focused($editingAmount).accessibilityIdentifier("inStoreMeasuredAmount")
                    }
                    if let total = (try? entry())?.total {
                        Text(shelfFormat("Picked line total · %@", moneyText(total))).monospacedDigit()
                    } else { Text(shelfText("This pick stays unpriced until you enter the measured amount.")).font(.footnote) }
                } else {
                    Toggle(shoppingText("Sold by weight"), isOn: $weighted)
                }
                Toggle(shoppingText("Member price"), isOn: $membership)
                if membership || mode == .total && weighted {
                    Toggle(shoppingText("I confirmed the applicable total"), isOn: $confirmed)
                }
            } header: {
                Text(verbatim: line.name).font(.headline).foregroundStyle(Theme.ink).textCase(nil)
            }
            if (try? entry()) == nil && !amount.isEmpty {
                Text(shelfText("Check the shelf price and picked amount. Use a whole number for packs."))
            }
            if model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: { dismiss() })
            }
            Button(shoppingText("Save price")) {
                guard let value = try? entry() else { return }
                Task {
                    if await model.editShop(key: "picked-price-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                        guard model.workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
                        let isWeighted = mode == .weight || mode == .total && weighted
                        try current.recordPickedPrice(lineID: line.id, expectedRevision: revision, total: value.total,
                            membership: membership, weighted: isWeighted,
                            conditionsConfirmed: confirmed || mode == .weight && !membership && value.total != nil, shelf: value.shelf)
                    }) { dismiss() }
                }
            }.disabled((try? entry()) == nil || model.hasPendingSave || model.saving)
        }
        .navigationTitle(shoppingText("Picked item price")).navigationBarTitleDisplayMode(.inline)
        .keyboardDoneAction(visible: editingAmount, title: ledgerText("Done"), identifier: "inStoreAmountDone") { editingAmount = false }
        .onChange(of: mode) { _, _ in amount = ""; measurement = ""; confirmed = false }
        .onChange(of: membership) { _, _ in confirmed = false }
        .onChange(of: weighted) { _, _ in confirmed = false }
        .onChange(of: amount) { _, _ in confirmed = false }
        .onChange(of: measurement) { _, _ in confirmed = false }
        .onChange(of: unit) { _, _ in amount = ""; measurement = ""; confirmed = false }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }

    private var amountLabel: String {
        switch mode {
        case .total: shoppingFormat("Total for this picked amount (%@)", shop.basis.currency.rawValue)
        case .pack: shelfFormat("Price per pack (%@)", shop.basis.currency.rawValue)
        case .weight: shelfFormat("Price per %@ (%@)", unit.comparisonLabel(for: .one), shop.basis.currency.rawValue)
        }
    }
}
