import Foundation
import CoreDomain
import LocalStore

/// An ingredient-specific equality reviewed for one offer, before normalization.
struct ComparisonConversion: Codable, Equatable {
    var sourceLiteral: String
    var targetLiteral: String
    var sourceUnit: UnitOfMeasure
    var targetUnit: UnitOfMeasure
    var sourceNote: String = ""

    func unitBasis() throws -> UnitBasis {
        guard sourceUnit.dimension != targetUnit.dimension,
              sourceLiteral.utf8.count <= StagedListImport.maximumOriginalLineBytes,
              targetLiteral.utf8.count <= StagedListImport.maximumOriginalLineBytes,
              sourceNote.utf8.count <= 2_048,
              let source = try ComparisonModel.quantity(sourceLiteral, sourceUnit), source.amount > .zero,
              let target = try ComparisonModel.quantity(targetLiteral, targetUnit), target.amount > .zero else {
            throw DomainError.invalidInput("conversionBasis")
        }
        return UnitBasis(sourceUnit: sourceUnit, targetUnit: targetUnit,
                         targetAmountPerSourceUnit: try target.amount.divided(by: source.amount), sourceNote: sourceNote,
                         sourceLiteral: sourceLiteral, targetLiteral: targetLiteral)
    }

    @MainActor func readableText() -> String {
        let language = recordsInterfaceLocale.language.languageCode?.identifier
        func original(_ literal: String, unit: UnitOfMeasure) -> String {
            let quantity = try? ComparisonModel.quantity(literal, unit)
            return pQuantity(literal, unit: unit, singular: quantity?.amount == .one, language: language)
        }
        var text = message("Confirmed ingredient conversion: %@ = %@",
                           original(sourceLiteral, unit: sourceUnit), original(targetLiteral, unit: targetUnit))
        if !sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n" + message("Conversion evidence: %@", sourceNote)
        }
        return text
    }

    @MainActor static func readableText(for basis: UnitBasis) -> String {
        let original = basis.sourceLiteral.flatMap { source in basis.targetLiteral.map { (source, $0) } }
        return ComparisonConversion(sourceLiteral: original?.0 ?? "1",
                                    targetLiteral: original?.1 ?? basis.targetAmountPerSourceUnit.description,
                                    sourceUnit: basis.sourceUnit, targetUnit: basis.targetUnit,
                                    sourceNote: basis.sourceNote).readableText()
    }
}

/// Original editable literals are retained independently of normalized calculations.
struct ComparisonDraft: Codable, Equatable {
    var id: UUID
    var item = "" { didSet { if item != oldValue { aConversion = nil; bConversion = nil } } }
    var needed = ""
    var unit: UnitOfMeasure = .count { didSet { if unit != oldValue { aConversion = nil; bConversion = nil } } }
    var stock = ""
    var protected = ""
    var cap = ""
    var aLabel = "" { didSet { if aLabel != oldValue { aConversion = nil } } }
    var aQuantity = ""
    var aUnit: UnitOfMeasure = .count { didSet { if aUnit != oldValue { aConversion = nil } } }
    var aPrice = ""
    var bLabel = "" { didSet { if bLabel != oldValue { bConversion = nil } } }
    var bQuantity = ""
    var bUnit: UnitOfMeasure = .count { didSet { if bUnit != oldValue { bConversion = nil } } }
    var bPrice = ""
    // Missing in early v1 drafts; each basis belongs only to its current offer.
    var aConversion: ComparisonConversion?
    var bConversion: ComparisonConversion?
    init(id: UUID = UUID()) { self.id = id }
}

struct SavedPayload: Codable {
    var formatVersion = 1
    var draft: ComparisonDraft
    // Optional to retain compatibility with early draft-only v1 local saves.
    var calculationVersion: String? = nil
    var normalizedRequest: ComparisonRequest? = nil
    var answer: CoreDomain.ComparisonResult? = nil
    var roundingPolicy: String? = nil
    static let currentCalculationVersion = "pack-v1/" + UnitOfMeasure.conversionTableVersion
    static let currentRoundingPolicy = "whole-packs-ceiling; USD-cents-exact; per-pack-ceiling-floor"
}

extension SavedPayload {
    /// Render the entered literals and the answer that was stored at save time.
    @MainActor func readableText() throws -> String {
        let inputs = try normalizedRequest ?? ComparisonModel(draft: draft).request()
        let language = recordsInterfaceLocale.language.languageCode?.identifier
        let missing = recordsText("Not entered")
        func original(_ quantity: Quantity?) -> String {
            guard let quantity else { return missing }
            return pQuantity(quantity.originalLiteral, unit: quantity.unit, singular: quantity.amount == .one, language: language)
        }
        var lines = [tr("Item-only comparison"),
                     tr("Other groceries, fees and taxes are not included. This does not establish whether the whole pickup fits your budget."),
                     tr("Total amount needed") + ": " + original(inputs.needed),
                     tr("Confirmed usable amount at home") + ": " + original(inputs.confirmedAtHome),
                     tr("Protected portions within the total") + ": " + original(inputs.protectedAmount)]
        if inputs.itemCap != nil { lines.append(tr("Item spending limit (USD, optional)") + ": " + draft.cap) }
        for (heading, offer, price, conversion, result) in [(tr("Pack A"), inputs.offerA, draft.aPrice, draft.aConversion, answer?.offerA),
                                                            (tr("Pack B"), inputs.offerB, draft.bPrice, draft.bConversion, answer?.offerB)] {
            lines += ["", offer.label.isEmpty ? heading : heading + " · " + offer.label,
                      tr("Usable amount in one pack") + ": " + original(offer.usableQuantity),
                      tr("Price for one pack (USD)") + ": " + (offer.price == nil ? missing : price)]
            if offer.confirmedConversion != nil, let conversion { lines.append(conversion.readableText()) }
            guard let result else { continue }
            lines.append(result.totalCost.map { message("Item cost to buy enough: %@", moneyText($0)) } ?? tr("Cost unresolved"))
            lines += [result.wholePacksText, result.purchasedText(in: draft.unit), result.shortageText(in: draft.unit),
                      result.leftoverText(in: draft.unit), result.itemLimitText, result.unitCeilingText].compactMap { $0 }
            lines += result.issues.map(\.explanation)
            if answer?.preferredOfferID == offer.id { lines.append(tr("Lower cost to buy enough for this item")) }
        }
        if let answer {
            if let summary = answer.purchaseSummary { lines.append(summary) }
        } else {
            lines.append(recordsText("No result was saved with this draft."))
        }
        lines.append(tr("Source: prices and usable amounts you entered. Estimates for this item only."))
        return lines.joined(separator: "\n")
    }
}

extension CoreDomain.ComparisonResult {
    var purchaseSummary: String? {
        guard offerA.isResolved, offerB.isResolved, preferredOfferID == nil else { return nil }
        if offerA.packsToBuy == 0 && offerB.packsToBuy == 0 {
            return tr("No packs needed for this item.")
        }
        return tr("Both options cost the same for this need.")
    }
}

extension OfferResult {
    var wholePacksText: String? {
        packsToBuy.map { message("Whole packs to buy: %@", $0.formatted()) }
    }
    func purchasedText(in unit: UnitOfMeasure) -> String? {
        purchasedAmount.map { message("Usable amount to buy: %@ %@", amountText($0), unit.displayName) }
    }
    func shortageText(in unit: UnitOfMeasure) -> String? {
        guard let remainingNeed, remainingNeed > .zero else { return nil }
        return message("Still needed: %@ %@", amountText(remainingNeed), unit.displayName)
    }
    func leftoverText(in unit: UnitOfMeasure) -> String? {
        leftover.map { message("Left after the total need: %@ %@", amountText($0), unit.displayName) }
    }
    var unitCeilingText: String? {
        unitCeiling.map { message("Maximum per pack for this item limit: %@", moneyText($0)) }
    }
    var itemLimitText: String? {
        guard let headroom = itemHeadroom else { return nil }
        if headroom.minorUnits < 0 {
            return message("Over the item limit: %@", moneyText(Money(minorUnits: -headroom.minorUnits)))
        }
        return message("Room within the item limit: %@", moneyText(headroom))
    }
}

enum EntryError: Error { case invalidNumber, precision, unsupportedVersion }

@MainActor final class ComparisonModel: ObservableObject {
    @Published var draft: ComparisonDraft {
        didSet { if draft != oldValue { result = nil; savedAt = nil } }
    }
    @Published var result: CoreDomain.ComparisonResult?
    @Published var error: String?
    @Published var savedAt: Date?
    @Published var saving = false
    private var savedRevision: Int64
    let clock: () -> Date
    init(draft: ComparisonDraft, savedRevision: Int64 = 0, clock: @escaping () -> Date = Date.init) {
        self.draft = draft
        self.savedRevision = savedRevision
        self.clock = clock
    }

    nonisolated static func rational(_ literal: String) throws -> Rational? {
        let cleaned = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        // US English and US Spanish use a period decimal separator. No grouping guesses.
        guard cleaned.count <= 24, cleaned.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil else { throw EntryError.invalidNumber }
        return try Rational(decimal: cleaned)
    }

    nonisolated static func quantity(_ literal: String, _ unit: UnitOfMeasure) throws -> Quantity? {
        let text = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFraction = text.contains("/") || text.contains { $0.isNumber && !$0.isASCII }
        if hasFraction {
            guard text.utf8.count <= 64, text.allSatisfy({ $0.isNumber || $0 == "/" || ($0.isWhitespace && !$0.isNewline) }) else {
                throw EntryError.invalidNumber
            }
            var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
            let amount = try ListQuantityParser.takeAmount(from: &tokens)
            guard tokens.isEmpty else { throw EntryError.invalidNumber }
            return Quantity(amount: amount, unit: unit, originalLiteral: literal)
        }
        guard let amount = try rational(literal) else { return nil }
        return Quantity(amount: amount, unit: unit, originalLiteral: literal)
    }

    nonisolated static func money(_ literal: String) throws -> Money? {
        let cleaned = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = cleaned.firstIndex(of: "."), cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) > 2 { throw EntryError.precision }
        guard let value = try rational(literal) else { return nil }
        let (scaled, overflow) = value.numerator.multipliedReportingOverflow(by: 100)
        guard !overflow, scaled % value.denominator == 0 else { throw EntryError.precision }
        return Money(minorUnits: scaled / value.denominator, currency: .usd)
    }

    var confirmedStock: Quantity? { try? Self.quantity(draft.stock, draft.unit) }

    func request() throws -> ComparisonRequest {
        func confirmedBasis(_ conversion: ComparisonConversion?, sourceUnit: UnitOfMeasure) throws -> UnitBasis? {
            guard let conversion else { return nil }
            guard conversion.sourceUnit == sourceUnit, conversion.targetUnit == draft.unit else {
                throw DomainError.invalidInput("conversionBasis")
            }
            return try conversion.unitBasis()
        }
        return ComparisonRequest(itemName: draft.item,
            needed: try Self.quantity(draft.needed, draft.unit),
            confirmedAtHome: try Self.quantity(draft.stock, draft.unit),
            protectedAmount: try Self.quantity(draft.protected, draft.unit),
            offerA: PackOffer(id: "a", label: draft.aLabel, usableQuantity: try Self.quantity(draft.aQuantity, draft.aUnit), price: try Self.money(draft.aPrice),
                              confirmedConversion: try confirmedBasis(draft.aConversion, sourceUnit: draft.aUnit)),
            offerB: PackOffer(id: "b", label: draft.bLabel, usableQuantity: try Self.quantity(draft.bQuantity, draft.bUnit), price: try Self.money(draft.bPrice),
                              confirmedConversion: try confirmedBasis(draft.bConversion, sourceUnit: draft.bUnit)),
            itemCap: try Self.money(draft.cap))
    }

    func compare() {
        result = nil
        error = nil
        do { result = try PackComparison.evaluate(request()) }
        catch { self.error = tr("Enter quantities as nonnegative decimals or fractions, such as 1/3. Use up to six decimal places for quantities and two for prices. Protected portions cannot exceed the total need.") }
    }

    func save(in store: ComparisonStore?) async {
        guard !saving else { return }
        guard let store else { error = tr("Could not save on this iPhone. Your entries are still here. Try again."); return }
        saving = true
        defer { saving = false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let savedDraft = draft
            let normalized = try request()
            let answer = try PackComparison.evaluate(normalized)
            let payload = try encoder.encode(SavedPayload(draft: savedDraft,
                calculationVersion: SavedPayload.currentCalculationVersion,
                normalizedRequest: normalized, answer: answer,
                roundingPolicy: SavedPayload.currentRoundingPolicy))
            let saved = try await store.save(id: savedDraft.id, title: savedDraft.item, payload: payload, savedAt: clock(),
                                             requiring: [savedDraft.id: savedRevision])
            savedRevision = saved.revision
            if draft == savedDraft {
                savedAt = saved.savedAt
                error = nil
            }
        } catch ComparisonStoreError.staleRevision {
            error = tr("This saved comparison changed. Reopen it to review the latest prices before saving your edits.")
        } catch { Diagnostics.record(.localSaveFailed); self.error = tr("Could not save on this iPhone. Your entries are still here. Try again.") }
    }
}

extension UnitOfMeasure {
    var displayName: String {
        switch self {
        case .count: return tr("items")
        case .gram: return tr("grams")
        case .kilogram: return tr("kilograms")
        case .ounce: return tr("ounces (weight)")
        case .pound: return tr("pounds")
        case .milliliter: return tr("milliliters")
        case .liter: return tr("liters")
        case .fluidOunce: return tr("US fluid ounces")
        case .cup: return tr("US cups")
        }
    }
}

func amountText(_ value: Rational) -> String {
    if value.denominator == 1 { return value.numerator.formatted() }
    // Exact fractions prevent rounded display from overstating available food.
    return "\(value.numerator)/\(value.denominator)"
}
func moneyText(_ value: Money) -> String {
    let amount = Decimal(value.minorUnits) / Decimal(100)
    return amount.formatted(.currency(code: "USD"))
}
