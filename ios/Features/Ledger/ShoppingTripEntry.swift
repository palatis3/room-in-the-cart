import SwiftUI
import CoreDomain

func tripText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ShoppingTrip")
}

func tripFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: tripText(key), locale: .current, arguments: arguments)
}

/// Use packs only when all of the requested amount is explained by the same
/// reviewed pack size. Keep ambiguous package descriptions in the source view.
struct TripMeasure {
    let need: Quantity
    let perPack: Rational?
    let package: BasketPackage?

    init?(_ shop: ShoppingLedger, line: ShoppingLine, packages: [BasketPackage]) {
        guard let need = try? shop.quantity(forLineID: line.id) else { return nil }
        self.init(need: need, packages: packages)
    }

    init(need: Quantity, packages: [BasketPackage]) {
        self.need = need
        if let first = packages.first, packages.allSatisfy({ $0.amountPerPack == first.amountPerPack && $0.unit == first.unit }),
           let size = try? Quantity(amount: first.amountPerPack, unit: first.unit, originalLiteral: "").converted(to: need.unit),
           size > .zero, let total = try? packages.reduce(Rational.zero, { try $0.adding(Rational($1.count).multiplied(by: size)) }),
           total == need.amount {
            perPack = size
            package = first
        } else { perPack = nil; package = nil }
    }

    var unit: String { perPack == nil ? need.unit.displayName : tripText("packs") }

    func display(_ amount: Rational) -> String {
        if let perPack, let count = try? amount.divided(by: perPack) {
            return tripFormat(count == .one ? "%@ pack" : "%@ packs", amountText(count))
        }
        return "\(amountText(amount)) \(need.unit.comparisonLabel(for: amount))"
    }

    func physicalAmount(_ literal: String) -> Rational? {
        guard let value = try? ListQuantityParser.numericAmount(literal), value > .zero else { return nil }
        guard let perPack else { return value }
        guard value.denominator == 1 else { return nil }
        return try? value.multiplied(by: perPack)
    }

    var packNote: String? {
        package.map { tripFormat("%@ %@ per pack", amountText($0.amountPerPack), $0.unit.comparisonLabel(for: $0.amountPerPack)) }
    }
}

extension ShoppingLedger {
    /// Working rows show the remaining purchase. The detail retains the full pick history.
    func groceryRowAmount(_ line: ShoppingLine, measure: TripMeasure?) -> String? {
        guard let measure else { return shoppingRowQuantity(for: line) }
        func display(_ amount: Rational) -> String {
            measure.perPack == nil && measure.need.unit == .count ? amountText(amount) : measure.display(amount)
        }
        guard line.tripPick != nil && !line.isChecked else { return display(measure.need.amount) }
        guard let remaining = try? outstandingQuantity(forLineID: line.id) else { return ledgerQuantity(nil) }
        return tripFormat("%@ still needed", display(remaining.amount))
    }

    func tripAmountLabel(_ line: ShoppingLine, measure: TripMeasure?) -> String? {
        guard let measure else { return shoppingRowQuantity(for: line) }
        guard let actual = line.tripPick?.amount, !line.isChecked,
              let picked = try? actual.converted(to: measure.need.unit),
              let remaining = try? outstandingQuantity(forLineID: line.id) else { return measure.display(measure.need.amount) }
        return tripFormat("%@ of %@ picked · %@ still needed", measure.display(picked),
                          measure.display(measure.need.amount), measure.display(remaining.amount))
    }
}

struct TripItemDetail: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let lineID: UUID
    let onSaved: (UUID) -> Void
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var amount = ""
    @State private var editingPart = false
    @State private var reviewedRevision: UUID?

    var body: some View {
        WorkingForm {
            if let shop = model.shop, shop.id == shopID,
               let line = shop.lines.first(where: { $0.id == lineID && !$0.isTrashed && !$0.isHandled }) {
                let measure = TripMeasure(shop, line: line, packages: shop.itemPackages[lineID] ?? [])
                Section {
                    Text(verbatim: line.name).font(.headline)
                    if let value = shop.tripAmountLabel(line, measure: measure) { Text(value) }
                    if let note = measure?.packNote { Text(note) }
                    ForEach(affectedDinners(in: shop)) { meal in
                        Text(tripFormat("For %@", meal.title)).foregroundStyle(Theme.secondary)
                    }
                }
                if !line.isChecked && shop.outcomeAtCurrentStop(line) == nil {
                    if let measure {
                        Section {
                            if editingPart {
                                workingTextField(tripFormat("Amount picked (%@)", measure.unit), text: $amount)
                                    .focused($editing).accessibilityIdentifier("tripPartialAmount")
                                let value = measure.physicalAmount(amount)
                                let remaining = try? shop.outstandingQuantity(forLineID: lineID)
                                Button(tripText("Save picked amount")) {
                                    guard let value, let reviewedRevision else { return }
                                    save(shop) { try $0.pickPart(lineID: lineID, amount: value, expectedRevision: reviewedRevision) }
                                }.buttonStyle(PrimaryAction()).accessibilityIdentifier("tripSavePart")
                                .disabled(value.map { $0 <= (remaining?.amount ?? .zero) } != true || reviewedRevision != shop.revisionID)
                            } else {
                                Button(tripText("Pick part")) {
                                    reviewedRevision = shop.revisionID
                                    editingPart = true
                                    editing = true
                                }.frame(minHeight: 44).accessibilityIdentifier("tripPickPart")
                            }
                        }
                    }
                    Button(tripText("Couldn’t find it")) {
                        save(shop) { try $0.markUnavailable(lineID: lineID, expectedRevision: shop.revisionID) }
                    }.frame(minHeight: 44).accessibilityIdentifier("tripUnavailable")
                }
                if let outcome = shop.outcomeAtCurrentStop(line) {
                    Label(tripText(outcome == .unavailable ? "Couldn’t find it at this stop" : "Left for next time"), systemImage: "clock")
                }
                if line.tripUndo != nil {
                    Button(tripFormat("Undo for %@", line.name)) {
                        save(shop) { try $0.undoTripChange(lineID: lineID, expectedRevision: shop.revisionID) }
                    }.frame(minHeight: 44)
                }
                NavigationLink(tripText("Preferred stores")) {
                    TripStorePreferences(model: model, shop: shop, line: line)
                }
                InStoreBudgetItemLink(model: model, shop: shop, line: line)
            }
            if model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: finish)
            }
        }.navigationTitle(tripText("Item details")).navigationBarTitleDisplayMode(.inline)
        .keyboardDoneAction(visible: editing, title: ledgerText("Done"), identifier: "tripPartKeyboardDone") { editing = false }
    }

    private func affectedDinners(in shop: ShoppingLedger) -> [MealOccurrence] {
        let ids = Set(shop.contributions(forLineID: lineID).compactMap { contribution -> UUID? in
            if case let .meal(id) = contribution.source { return id }
            return nil
        })
        return shop.mealOccurrences.filter { ids.contains($0.id) && !$0.isHidden && $0.removedAt == nil }
    }

    private func save(_ shop: ShoppingLedger, _ edit: @escaping (inout ShoppingLedger) throws -> Void) {
        guard !model.hasPendingSave, !model.saving, authorize() else { return }
        Task {
            if await model.editShop(key: "trip-row-\(lineID)", shopID: shopID,
                authorize: { authorize() && model.shop?.id == shopID }, edit) { finish() }
        }
    }

    private func finish() { onSaved(lineID); dismiss() }
}

private struct TripStorePreferences: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @State private var stores: String
    @State private var reviewedRevision: UUID

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.model = model; self.shop = shop; self.line = line
        _reviewedRevision = State(initialValue: shop.revisionID)
        _stores = State(initialValue: (line.preferredStores ?? []).joined(separator: "\n"))
    }

    var body: some View {
        WorkingForm {
            Text(verbatim: line.name).font(.headline)
            TextField(tripText("Store names, one per line"), text: $stores, axis: .vertical).lineLimit(2...10)
            Text(tripText("Leave blank for any store. Add several stores if either one works.")).font(.footnote)
            Button(tripText("Save stores")) {
                let values = stores.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                Task {
                    if await model.editShop(key: "trip-stores-\(line.id)", shopID: shop.id,
                        authorize: { authorize() && model.shop?.id == shop.id }, { current in
                            try current.setPreferredStores(values, lineID: line.id, expectedRevision: reviewedRevision)
                        }) { dismiss() }
                }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            if model.hasPendingSave || model.error != nil { LedgerSaveStatus(model: model, onRetried: { dismiss() }) }
        }.navigationTitle(tripText("Preferred stores"))
    }
}

struct TripFindEntry: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let onSaved: (UUID) -> Void
    @State private var name = ""
    @State private var amount = ""
    @State private var reviewedRevision: UUID
    @State private var unit: UnitOfMeasure = .count
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool

    init(model: LedgerModel, shop: ShoppingLedger, onSaved: @escaping (UUID) -> Void) {
        self.model = model
        self.shop = shop
        self.onSaved = onSaved
        _reviewedRevision = State(initialValue: shop.revisionID)
    }

    var body: some View {
        WorkingForm {
            workingTextField(tripText("Grocery name"), text: $name).focused($editing).accessibilityIdentifier("tripFindName")
            workingTextField(tripText("Amount picked (optional)"), text: $amount).focused($editing)
            Picker(tripText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Button(tripText("Add to picked items")) {
                let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let q = (try? ListQuantityParser.numericAmount(amount)).map { Quantity(amount: $0, unit: unit, originalLiteral: amount) }
                Task {
                    if await model.editShop(key: "trip-find-\(shop.id)", shopID: shop.id,
                        authorize: { authorize() && model.shop?.id == shop.id }, { current in
                            _ = try current.addInStoreFind(name: label, quantity: q, expectedRevision: reviewedRevision)
                        }) { finish() }
                }
            }.buttonStyle(PrimaryAction()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                (!amount.isEmpty && ((try? ListQuantityParser.numericAmount(amount)) ?? .zero) == .zero) || model.saving || model.hasPendingSave)
            if model.hasPendingSave || model.error != nil { LedgerSaveStatus(model: model, onRetried: finish) }
        }.navigationTitle(tripText("Add a find"))
        .keyboardDoneAction(visible: editing, title: ledgerText("Done"), identifier: "tripFindKeyboardDone") { editing = false }
    }

    private func finish() {
        if let added = model.shop?.lines.last { onSaved(added.id) }
        dismiss()
    }
}
