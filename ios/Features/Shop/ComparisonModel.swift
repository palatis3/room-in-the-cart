import Foundation
import CoreDomain
import LocalStore

/// Original editable literals are retained independently of normalized calculations.
struct ComparisonDraft: Codable, Equatable {
    var id: UUID
    var item = ""
    var needed = ""
    var unit: UnitOfMeasure = .count
    var stock = ""
    var protected = ""
    var cap = ""
    var aLabel = ""
    var aQuantity = ""
    var aUnit: UnitOfMeasure = .count
    var aPrice = ""
    var bLabel = ""
    var bQuantity = ""
    var bUnit: UnitOfMeasure = .count
    var bPrice = ""
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

enum EntryError: Error { case invalidNumber, precision, unsupportedVersion }

@MainActor final class ComparisonModel: ObservableObject {
    @Published var draft: ComparisonDraft {
        didSet { if draft != oldValue { result = nil; savedAt = nil } }
    }
    @Published var result: CoreDomain.ComparisonResult?
    @Published var error: String?
    @Published var savedAt: Date?
    @Published var saving = false
    let clock: () -> Date
    init(draft: ComparisonDraft, clock: @escaping () -> Date = Date.init) {
        self.draft = draft
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

    func request() throws -> ComparisonRequest {
        ComparisonRequest(itemName: draft.item,
            needed: try Self.quantity(draft.needed, draft.unit),
            confirmedAtHome: try Self.quantity(draft.stock, draft.unit),
            protectedAmount: try Self.quantity(draft.protected, draft.unit),
            offerA: PackOffer(id: "a", label: draft.aLabel, usableQuantity: try Self.quantity(draft.aQuantity, draft.aUnit), price: try Self.money(draft.aPrice)),
            offerB: PackOffer(id: "b", label: draft.bLabel, usableQuantity: try Self.quantity(draft.bQuantity, draft.bUnit), price: try Self.money(draft.bPrice)),
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
            let saved = try await store.save(id: savedDraft.id, title: savedDraft.item, payload: payload, savedAt: clock())
            if draft == savedDraft { savedAt = saved.savedAt }
            error = nil
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
