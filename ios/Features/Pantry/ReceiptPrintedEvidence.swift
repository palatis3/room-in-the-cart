import CoreDomain
import Foundation
import LocalStore

/// Proposals for one printed row. Physical receipt, usability and payment are always separate decisions.
struct ReceiptPrintedEvidence: Equatable {
    enum Kind { case item, adjustment, date, unclear }
    let kind: Kind
    var name: String?
    var quantity: String?
    var unit: UnitOfMeasure?
    var amount: String?
    var priceWording: String?
    var storage: InventoryLocation?
    var uncertain = false

    // A final amount must be distinct from an explicit unit price. Preserve currency ambiguity for review.
    private static let price = #/(?i)(?:US\$|USD\s*\$?|\$)\s*([0-9]{1,7}[.,][0-9]{2})(?:\s*USD)?\s*$/#
    private static let bareAmount = #/[0-9]{1,7}[.,][0-9]{2}/#
    private static let unmarkedTotal = #/\s+([0-9]{1,7}[.,][0-9]{2})\s*$/#
    private static let unitPrice = #/(?i)(?:\s*@|\s+(at|a)\b)\s*(?:US\$|USD\s*\$?|\$)?\s*[0-9]+(?:[.,][0-9]{1,2})?(?:\s*(?:\/|per|por)\s*([a-z.]+))?\s*$/#
    private static let measure = #/(?i)\b([0-9]{1,5}(?:[.,][0-9]{1,3})?)\s*(fluid\s+ounces?|fl\.?\s*oz|fl\.?\s+ounces?|onzas?\s+l[ií]quidas?|oz\.?\s+l[ií]q(?:uidas)?|kg|kgs|kilogramos?|kilograms?|gramos?|grams?|gr|g|lb[s.]?|pounds?|libras?|ounces?|onzas?|oz|liters?|litros?|ml|l|count|ct|ea|each|unidades|uds)\b\.?/#
    private static let adjustment = #/(?i)^\s*(?:service fee|bottle deposit|sales tax|tax|impuesto|iva|subtotal|sub total|total|change|cambio|cash|efectivo|tender|visa|mastercard|payment|pago|discount|descuento|coupon|cup[oó]n|deposit|dep[oó]sito|fee|cargo|delivery fee|shipping|env[ií]o|tip|propina|refund|reembolso|return|devoluci[oó]n|promotion|promoci[oó]n)\b/#
    private static let mixed = #/(?i)(?:[€£]|\b(?:CAD|EUR|GBP|MXN|AUD|BOGO|gratis|was|ahorra|save|oferta|coupon|cup[oó]n)\b|\b(?:buy|compra)\s+\w+\s+(?:get|recibe)\b|\b[0-9]+\s*(?:for|por)\s*[$0-9]|\d+\s*%|[0-9]\s*[x×]\s*[0-9]|\b(?:pack|pk)\s*(?:of|de)?\s*[0-9]|\d\s*\/\s*\d)/#
    private static let signedValue = #/(?:^|\s)[−–-]\s*[$0-9]|\(\s*\$?\d+[.,]\d{2}\s*\)/#
    private static let otherNumbers = #/(?:[$€£@]|[0-9][.,][0-9]|[0-9]\s*[x×]|\s-\s*\d)/#
    private static let freezer = #/(?i)\b(?:keep frozen|frozen|mantener congelad[oa]s?|congelad[oa]s?)\b/#
    private static let fridge = #/(?i)\b(?:keep refrigerated|refrigerated|mantener refrigerad[oa]s?|refrigerad[oa]s?)\b/#
    private static let storageConflict = #/(?i)\b(?:never|not|do not|previously|thawed|after opening|no congelar|no refrigerar|descongelad[oa]s?|despu[eé]s de abrir)\b/#
    private static let cupboard = #/(?i)\b(?:shelf stable|shelf-stable|store in (?:a )?cool dry place|conservar en lugar fresco y seco)\b/#
    private static let nonItem = #/(?i)\b(?:total|subtotal|balance|saldo|amount due|change due|importe|a pagar|monto|tax|impuestos?|iva|vat|cash|efectivo|credit|cr[eé]dito|debit|d[eé]bito|card|tarjeta|payment|pagos?|visa|mastercard|discount|descuento|coupon|cup[oó]n|deposit|dep[oó]sito|fee|cargo|service charge|env[ií]o|shipping|tip|propina|refund|reembolso|return|devoluci[oó]n|unit price|precio unitario|precio por|ticket|receipt|recibo|invoice|factura)\b/#
    private static let rateByUnit = #/(?i)(?:@|\b(?:per|por)\s+(?:kg|lb|g|unidad|unit|oz|ea)\b|\/\s*(?:kg|lb|g|unidad|unit|oz|ea)\b)/#

    static func isStandaloneAmount(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: price) != nil
    }

    static func canSuggestAmount(for wording: String) -> Bool {
        guard !wording.contains(nonItem), !wording.contains(rateByUnit), !wording.contains(mixed),
              !wording.contains(signedValue), !wording.contains(otherNumbers) else { return false }
        let printed = Self(.init(originalText: wording), knownStorage: [:])
        return printed.kind == .item && printed.name != nil && printed.amount == nil
    }

    init(_ row: ScanReceiptLine, knownStorage: [String:Set<InventoryLocation>]) {
        let text = row.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(Self.adjustment) { kind = .adjustment; return }
        if ReceiptPrintedDate.looksLikeDate(text) { kind = .date; return }
        guard !text.isEmpty, text.count <= 512, text.contains(where: \.isLetter),
              !text.contains("?"), !text.contains("�"), row.uncertainOCR != true else { kind = .unclear; uncertain = true; return }
        kind = .item
        guard !text.contains(Self.mixed), !text.contains(Self.signedValue) else { uncertain = true; return }
        var candidate = text
        Self.removeUnitPrice(from: &candidate)
        if let total = candidate.firstMatch(of: Self.price) {
            let before = candidate[..<total.range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !before.hasSuffix("@"), !before.hasSuffix("/"), !before.hasSuffix("-"), !before.hasSuffix("−"), !before.isEmpty {
                amount = String(total.1).replacingOccurrences(of: ",", with: ".")
                priceWording = String(total.0)
                candidate = before
            }
        } else if let number = candidate.firstMatch(of: Self.unmarkedTotal) {
            let before = candidate[..<number.range.lowerBound].trimmingCharacters(in: .whitespaces)
            if before.contains(Self.measure), !before.hasSuffix("@") {
                amount = String(number.1).replacingOccurrences(of: ",", with: ".")
                priceWording = String(number.1)
                candidate = before
            }
        }
        Self.removeUnitPrice(from: &candidate)
        if candidate.contains(Self.otherNumbers) && candidate.matches(of: Self.measure).isEmpty {
            amount = nil; priceWording = nil; uncertain = true; return
        }
        let measurements = candidate.matches(of: Self.measure)
        if measurements.count == 1, let match = measurements.first {
            if let measured = Self.measurement(String(match.1), unit: String(match.2)) {
                quantity = measured.0; unit = measured.1
                candidate.replaceSubrange(match.range, with: " ")
            }
        }
        if measurements.count > 1 || candidate.contains(Self.otherNumbers) {
            uncertain = true; amount = nil; priceWording = nil; quantity = nil; unit = nil; return
        }
        let cleaned = candidate.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ":-·| "))
        if !cleaned.isEmpty, cleaned.contains(where: \.isLetter) { name = cleaned }
        if row.reviewedText != row.originalText { name = row.reviewedText }
        if !row.quantityNote.isEmpty {
            quantity = nil; unit = nil
            if let note = row.quantityNote.trimmingCharacters(in: .whitespaces).wholeMatch(of: Self.measure),
               let measured = Self.measurement(String(note.1), unit: String(note.2)) {
                quantity = measured.0; unit = measured.1
            }
        }
        if !row.priceNote.isEmpty {
            let note = row.priceNote.trimmingCharacters(in: .whitespaces)
            if let total = note.wholeMatch(of: Self.price) {
                amount = Self.normalizedAmount(total.1)
                priceWording = String(total.0)
            } else if note.wholeMatch(of: Self.bareAmount) == nil
                        || Self.normalizedAmount(note) != amount
                        || priceWording?.wholeMatch(of: Self.price) == nil {
                // Digits alone can repeat an explicit printed amount. They cannot
                // supply a new currency or establish a different amount.
                amount = nil
                priceWording = nil
            }
        }
        let labels: [InventoryLocation] = [(Self.freezer,InventoryLocation.freezer),(Self.fridge,.fridge),(Self.cupboard,.cupboard)].compactMap {
            text.contains($0.0) ? $0.1 : nil
        }
        let history = knownStorage[InventoryReceiptAlias.key(name ?? text)] ?? []
        let places = history.union(labels)
        if places.count == 1, !text.contains(Self.storageConflict) { storage = places.first }
        uncertain = quantity == nil || amount == nil || name == nil
    }

    private static func normalizedAmount(_ text: some StringProtocol) -> String {
        text.replacingOccurrences(of: ",", with: ".")
    }
    private static func removeUnitPrice(from text: inout String) {
        guard let rate = text.firstMatch(of: unitPrice) else { return }
        let prefix = text[..<rate.range.lowerBound]
        // Spanish "a" after a quantity introduces a rate. In a name such as "Grade A",
        // it belongs to the product unless the receipt also gives a price denominator.
        if rate.1?.lowercased() == "a", rate.2 == nil,
           prefix.matches(of: measure).last?.range.upperBound != prefix.endIndex { return }
        text.removeSubrange(rate.range)
    }

    private static func measurement(_ number: String, unit: String) -> (String,UnitOfMeasure)? {
        let token = unit.lowercased(), normalized = number.replacingOccurrences(of: ",", with: ".")
        var tokens = ListQuantityParser.itemTokens(token)
        let parsed: UnitOfMeasure? = ["ea","each","ct","count","unidades","uds"].contains(token) ? .count : ListQuantityParser.takeUnit(from: &tokens)
        let parts = normalized.split(separator: ".")
        if parts.count == 2, parts[1].count == 3, parts[0] != "0", parts[0].count <= 3 { return nil }
        guard let parsed, let value = try? ListQuantityParser.numericAmount(normalized), value > .zero else { return nil }
        return (normalized,parsed)
    }

}

struct ReceiptPrintedDate: Equatable {
    let day: Date
    let wording: String
    private static let pattern = #/(?i)^\s*(?:(?:purchase date|transaction date|sale date|purchased|date|fecha de compra|fecha de venta|fecha)\s*[:#-]?\s*)?([0-9]{4}[-\/]\d{1,2}[-\/]\d{1,2}|\d{1,2}[-\/]\d{1,2}[-\/]\d{4})(?:\s+[0-2]?\d:\d{2}(?::\d{2})?(?:\s*[ap]m)?)?\s*$/#
    static func looksLikeDate(_ text: String) -> Bool { text.wholeMatch(of: pattern) != nil }

    static func unique(in rows: [ScanReceiptLine], now: Date, calendar: Calendar = .current) -> Self? {
        var unique: Self?
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        for row in rows where row.documentLine?.stage != .order {
            guard let match = row.reviewedText.wholeMatch(of: pattern) else { continue }
            guard row.uncertainOCR != true else { return nil }
            let tokens = match.1.split { $0 == "/" || $0 == "-" }
            let numbers = tokens.compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            let y: Int, m: Int, d: Int
            if tokens[0].count == 4 { (y,m,d) = (numbers[0],numbers[1],numbers[2]) }
            else if numbers[0] > 12 { (y,m,d) = (numbers[2],numbers[1],numbers[0]) }
            else if numbers[1] > 12 || numbers[0] == numbers[1] { (y,m,d) = (numbers[2],numbers[0],numbers[1]) }
            else { return nil }
            guard (1900...9999).contains(y), let date = civil.date(from: DateComponents(year: y, month: m, day: d)),
                  civil.component(.year, from: date) == y, civil.component(.month, from: date) == m,
                  civil.component(.day, from: date) == d, date <= civil.startOfDay(for: now),
                  unique == nil || unique?.day == date else { return nil }
            unique = .init(day: date, wording: row.originalText)
        }
        return unique
    }
}
