import Foundation
import CoreDomain

func ledgerText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "Ledger")
}

func ledgerFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: ledgerText(key), locale: Locale.current, arguments: arguments)
}

func ledgerImportLimitMessage(_ limit: ImportTextLimit) -> String {
    switch limit {
    case .totalBytes:
        ledgerFormat("Split this list into parts of up to %lld UTF-8 bytes each.", Int64(StagedListImport.maximumTextBytes))
    case .nonblankLines(let maximum):
        ledgerFormat("Split this list into parts of up to %lld nonblank items each.", Int64(maximum))
    case .originalLineBytes(let item):
        ledgerFormat("Shorten item %lld to %lld UTF-8 bytes or less.", Int64(item), Int64(StagedListImport.maximumOriginalLineBytes))
    }
}

func ledgerQuantity(_ quantity: Quantity?) -> String {
    guard let quantity else { return ledgerText("Quantity unresolved") }
    return "\(amountText(quantity.amount)) \(quantity.unit.comparisonLabel(for: quantity.amount))"
}

/// The outer count is a shopping instruction, never a measured ingredient total.
func shoppingPackageCount(_ count: Int, original: String) -> String {
    var tokens = ListQuantityParser.itemTokens(original)
    _ = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true)
    let key: String
    switch tokens.first?.lowercased() {
    case "can", "cans", "lata", "latas": key = count == 1 ? "%lld can" : "%lld cans"
    case "box", "boxes", "caja", "cajas": key = count == 1 ? "%lld box" : "%lld boxes"
    default: key = count == 1 ? "%lld pack" : "%lld packs"
    }
    return ledgerFormat(key, Int64(count))
}

extension ShoppingLedger {
    /// A single plain grocery can stand on its name. Reviewed quantities, source
    /// conflicts, and demand from meals or portions still need a visible amount.
    func shoppingRowQuantity(for line: ShoppingLine) -> String? {
        do {
            if let quantity = try quantity(forLineID: line.id) { return ledgerQuantity(quantity) }
        } catch { return ledgerQuantity(nil) }
        return Self.shoppingLabelWithoutTotal(for: line, sources: contributions(forLineID: line.id))
    }

    static func shoppingLabelWithoutTotal(for line: ShoppingLine, sources: [LedgerContribution]) -> String? {
        if !sources.isEmpty, sources.allSatisfy(\.isHandCheckedUnmeasuredIngredient) {
            return tonightText("Checked by hand · unmeasured")
        }
        guard sources.count == 1, let source = sources.first, source.source.canSupplyExistingQuantity,
              source.quantity == nil else { return ledgerQuantity(nil) }
        if let count = source.originalPack?.count {
            return shoppingPackageCount(count, original: source.originalText)
        }
        return source.hasOptionalShoppingAmount && source.productName == line.name ? nil : ledgerQuantity(nil)
    }

    var listExclusions: [UUID: String] {
        itemExclusions.mapValues { ledgerFormat("Exclusions: %@", $0.joined(separator: ", ")) }
    }
}

// A meal and its ingredient may retain the same rule independently.
// Keep original wording and source order while showing each exact rule once.
func ledgerExclusionsText(_ values: [String]) -> String {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }.joined(separator: ", ")
}

func ledgerAmountInput(_ value: Rational) -> String {
    value.denominator == 1 ? "\(value.numerator)" : "\(value.numerator)/\(value.denominator)"
}

@MainActor enum LedgerEntry {
    static func rational(_ literal: String) throws -> Rational? {
        let value = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let numerator = Int64(parts[0]), let denominator = Int64(parts[1]) {
            guard value.count <= 40, numerator >= 0, denominator > 0 else { throw EntryError.invalidNumber }
            return try Rational(numerator, denominator)
        }
        return try ComparisonModel.quantity(value, .count)?.amount
    }
    static func quantity(_ literal: String, _ unit: UnitOfMeasure) throws -> Quantity? {
        guard let amount = try rational(literal) else { return nil }
        return Quantity(amount: amount, unit: unit, originalLiteral: literal)
    }
}

extension LedgerContribution {
    var hasOptionalShoppingAmount: Bool {
        source.canSupplyExistingQuantity && quantity == nil && capture == nil && originalPack == nil &&
            exclusions.isEmpty && QuickGrocery.plainName(originalText) != nil && QuickGrocery.plainName(productName) != nil
    }

    var sourceQuantityLabel: String {
        if hasOptionalShoppingAmount { return ledgerText("Quantity optional") }
        if isHandCheckedUnmeasuredIngredient { return tonightText("Checked by hand · unmeasured") }
        if quantity == nil, let count = originalPack?.count { return shoppingPackageCount(count, original: originalText) }
        return ledgerQuantity(quantity)
    }
}

func ledgerEditableNote(_ contribution: LedgerContribution) -> String {
    guard case .imported = contribution.source else { return contribution.notes }
    if contribution.hasOptionalShoppingAmount,
       contribution.notes == "Review the quantity and unit." || contribution.notes == "quantityUnknown" { return "" }
    return ledgerContributionNote(contribution.notes)
}

func ledgerContributionNote(_ note: String) -> String {
    switch note {
    case "Review the quantity and unit.": return ledgerText("Review the quantity and unit.")
    case "Review the pack count and usable amount in each pack.": return ledgerText("Review the pack count and usable amount in each pack.")
    case "Review the unsupported or approximate unit.": return ledgerText("Review the unsupported or approximate unit.")
    case "Add the item name.": return ledgerText("Add the item name.")
    case "quantityUnknown": return ledgerText("Quantity unresolved")
    default: return note
    }
}

func ledgerDate(_ date: Date, zone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = TimeZone(identifier: zone) ?? .current
    formatter.dateStyle = .full
    formatter.timeStyle = .short
    return "\(formatter.string(from: date)) · \(zone)"
}

func ledgerMealDay(_ day: MealDay) -> String {
    guard let date = day.date else { return day.iso8601 }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = TimeZone(identifier: day.timeZoneIdentifier)
    formatter.dateStyle = .full
    formatter.timeStyle = .none
    return "\(formatter.string(from: date)) · \(day.timeZoneIdentifier)"
}

extension FulfillmentMode {
    var ledgerLabel: String {
        switch self {
        case .pickup: return ledgerText("Pickup")
        case .delivery: return ledgerText("Delivery")
        case .inStore: return ledgerText("In store")
        }
    }
}

extension BudgetScope {
    var ledgerLabel: String {
        switch self {
        case .wholeShop: return ledgerText("Whole pickup")
        case .dinnersOnly: return ledgerText("Dinners only")
        case .selectedItems: return ledgerText("Selected items only")
        }
    }
}

extension ShoppingLedger {
    var typedItemBatchIDs: Set<UUID> {
        Set(importBatches.lazy.filter { batch in
            batch.source == .typed && batch.preview.lines.count == 1 && batch.preview.lines[0].capture == nil
        }.map(\.id))
    }
}

func ledgerBatchSourceLabel(_ id: UUID, typedItemBatches: Set<UUID>) -> String {
    typedItemBatches.contains(id) ? quickGroceryText("Typed item") : ledgerText("Imported list")
}

func ledgerSourceLabel(_ contribution: LedgerContribution, shop: ShoppingLedger, typedItemBatches: Set<UUID>? = nil) -> String {
    switch contribution.source {
    case .manual: return ledgerText("Manually added")
    case .imported(let id): return ledgerBatchSourceLabel(id, typedItemBatches: typedItemBatches ?? shop.typedItemBatchIDs)
    case .meal(let id): return shop.mealOccurrences.first { $0.id == id }?.title ?? ledgerText("Dinner")
    case .protectedNeed(let purpose): return ledgerFormat("Protected: %@", purpose)
    }
}
