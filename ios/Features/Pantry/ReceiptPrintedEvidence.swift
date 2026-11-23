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
    private(set) var acceptsFieldNotes = false
    var hasConflictingCurrency: Bool { currencyEvidence == .conflicting }
    private(set) var currencyEvidence = PrintedCurrencyEvidence.unspecified

    func permitsPayment(in currency: Currency) -> Bool {
        currencyEvidence.permits(currency)
    }

    // A final amount must be distinct from an explicit unit price. Preserve currency ambiguity for review.
    private static let price = #/(?i)(?=(?:US\$|M(?:EX|X)\$|USD|MXN|\$|[0-9]{1,7}[.,][0-9]{2}\s*(?:USD\b|MXN\b|M\.N\.|pesos\s+mexicanos\b)))(?:(?:US\$|M(?:EX|X)\$|(?:USD|MXN)\s*\$?|\$)\s*)?([0-9]{1,7}[.,][0-9]{2})(?:\s*(?:USD|MXN|M\.N\.|pesos\s+mexicanos))?\s*$/#
    private static let bareAmount = #/[0-9]{1,7}[.,][0-9]{2}/#
    private static let unmarkedTotal = #/\s+([0-9]{1,7}[.,][0-9]{2})\s*$/#
    private static let unitPrice = #/(?i)(?:\s*@|\s+(at|a)\b)\s*(?:US\$|M(?:EX|X)\$|(?:USD|MXN)\s*\$?|\$)?\s*[0-9]+(?:[.,][0-9]{1,2})?(?:\s*(?:\/|per|por)\s*([a-z.]+))?\s*$/#
    private static let measure = #/(?i)\b([0-9]{1,5}(?:[.,][0-9]{1,3})?)\s*(fluid\s+ounces?|fl\.?\s*oz|fl\.?\s+ounces?|onzas?\s+l[ií]quidas?|oz\.?\s+l[ií]q(?:uidas)?|kg|kgs|kilogramos?|kilograms?|gramos?|grams?|gr|g|lb[s.]?|pounds?|libras?|ounces?|onzas?|oz|liters?|litros?|ml|l|count|ct|ea|each|units?|unidad(?:es)?|uds?)\b\.?/#
    private static let precedingBasis = #/(?i)\b(?:per|por)\s+(?:(?:each|cada)\s+)?[\p{L}]+\s*[:=]?\s*$/#
    private static let followingBasis = #/(?i)^\s*(?:/|per\b|por\b)/#
    private static let adjustment = #/(?i)^\s*(?:service fee|bottle deposit|sales tax|tax|impuesto|iva|subtotal|sub total|total|change|cambio|cash|efectivo|tender|visa|mastercard|payment|pago|discount|descuento|coupon|cup[oó]n|deposit|dep[oó]sito|fee|cargo|delivery fee|shipping|env[ií]o|tip|propina|refund|reembolso|return|devoluci[oó]n|promotion|promoci[oó]n)\b/#
    private static let mixed = #/(?i)(?:[€£]|\b(?:CAD|EUR|GBP|AUD|BOGO|gratis|was|ahorra|save|oferta|coupon|cup[oó]n)\b|\b(?:buy|compra)\s+\w+\s+(?:get|recibe)\b|\b[0-9]+\s*(?:for|por)\s*[$0-9]|\d+\s*%|[0-9]\s*[x×]\s*[0-9]|\b(?:pack|pk)\s*(?:of|de)?\s*[0-9]|\d\s*\/\s*\d)/#
    private static let signedValue = #/(?:^|\s)[−–-]\s*[$0-9]|\(\s*\$?\d+[.,]\d{2}\s*\)/#
    private static let otherNumbers = #/(?:[$€£@]|[0-9][.,][0-9]|[0-9]\s*[x×]|\s-\s*\d)/#
    // A leading multiplier or a trailing bare number can surround a plain product name.
    // Neither supplies a physical quantity or a currency.
    private static let itemWithUnresolvedNumbers = #/(?i)(?:[1-9][0-9]{0,4}\s*[x×]\s+)?([\p{L}][\p{L}\p{M} '’-]*?)(?:\s+([0-9]{1,7}[.,][0-9]{2}))?/#
    private static let packageBasis = #/(?i)\b(?:per|por|each|cada)\b/#
    private static let freezer = #/(?i)\b(?:keep frozen|frozen|mantener congelad[oa]s?|congelad[oa]s?)\b/#
    private static let fridge = #/(?i)\b(?:keep refrigerated|refrigerated|mantener refrigerad[oa]s?|refrigerad[oa]s?)\b/#
    private static let storageConflict = #/(?i)\b(?:never|not|do not|previously|thawed|after opening|no congelar|no refrigerar|descongelad[oa]s?|despu[eé]s de abrir)\b/#
    private static let cupboard = #/(?i)\b(?:shelf stable|shelf-stable|store in (?:a )?cool dry place|conservar en lugar fresco y seco)\b/#
    private static let nonItem = #/(?i)\b(?:total|subtotal|balance|saldo|amount due|change due|importe|a pagar|monto|tax|impuestos?|iva|vat|cash|efectivo|credit|cr[eé]dito|debit|d[eé]bito|card|tarjeta|payment|pagos?|visa|mastercard|discount|descuento|coupon|cup[oó]n|deposit|dep[oó]sito|fee|cargo|service charge|env[ií]o|shipping|tip|propina|refund|reembolso|return|devoluci[oó]n|unit price|precio unitario|precio por|ticket|receipt|recibo|invoice|factura)\b/#
    private static let rateByUnit = #/(?i)(?:@|\b(?:per|por)\s+(?:kg|lb|g|unidad|unit|oz|ea)\b|\/\s*(?:kg|lb|g|unidad|unit|oz|ea)\b)/#

    // Currency codes and local symbols can sit outside the amount matched by price
    // (for example, “NZD $3.20”). Only the letters next to a price are qualifiers.
    private static let currencyBeforePrice = #/(?i)([\p{L}]+)[./]?\s*(US\$|USD\s*\$?|\$)?\s*[0-9]+(?:[.,][0-9]+)?\b/#
    private static let currencyAfterPrice = #/(?i)\b[0-9]+(?:[.,][0-9]+)?\s*([\p{L}]+)\b/#
    // The currency symbol table supplies prefixes such as NZ in NZ$. Country
    // codes by themselves are not price notation (“at $1.60” introduces a rate).
    private static let dollarPrefixes: Set<String> = {
        let locale = NSLocale(localeIdentifier: "en_US")
        return Set(Locale.Currency.isoCurrencies.compactMap { currency in
            guard !["USD","MXN"].contains(currency.identifier),
                  let symbol = locale.displayName(forKey: .currencySymbol, value: currency.identifier),
                  symbol.count > 1, symbol.hasSuffix("$") else { return nil }
            return String(symbol.dropLast()).uppercased()
        })
    }()
    private static let foreignCurrencyMarkers: Set<String> = {
        var markers = Set(Locale.Currency.isoCurrencies.map(\.identifier))
        for id in Locale.availableIdentifiers {
            let locale = Locale(identifier: id)
            guard let code = locale.currency?.identifier, !["USD","MXN"].contains(code), let symbol = locale.currencySymbol else { continue }
            // Punctuation is already excluded from the accepted product name, but a
            // separately edited name must still respect local forms such as R$ and S/.
            let letters = symbol.trimmingCharacters(in: CharacterSet.letters.inverted).uppercased()
            if !letters.isEmpty { markers.insert(letters) }
        }
        markers.formUnion(["PESO", "PESOS", "EURO", "EUROS"])
        return markers.subtracting(["US", "USD", "MX", "MEX", "MXN"])
    }()

    static func hasForeignCurrency(_ text: String) -> Bool {
        guard text.contains(where: \.isNumber) else { return false }
        // Measurement units such as g and L can also be local currency abbreviations.
        let wording = text.replacing(#/(?i)\b(?:pesos\s+mexicanos\b|M\.N\.)/#, with: "MXN").replacing(measure, with: "|").replacing(#/[():\[\]]/#, with: " ")
        if wording.unicodeScalars.contains(where: { $0.properties.generalCategory == .currencySymbol && $0 != "$" }) { return true }
        for match in wording.matches(of: currencyBeforePrice) {
            let token = match.1.uppercased()
            if token.count == 1 {
                // C$ and S/ are currency markers. The D in “Vitamin D $3.20” is a product letter.
                let next = wording[match.1.endIndex...].first
                if next == "$" || next == "/" && foreignCurrencyMarkers.contains(token) { return true }
                continue
            }
            if foreignCurrencyMarkers.contains(token) || (match.2 == "$" && dollarPrefixes.contains(token)) { return true }
        }
        return wording.matches(of: currencyAfterPrice).contains { $0.1.count > 1 && foreignCurrencyMarkers.contains($0.1.uppercased()) }
    }

    static func isStandaloneAmount(_ text: String) -> Bool {
        standaloneAmount(text) != nil
    }

    static func standaloneAmount(_ text: String) -> String? {
        guard PrintedCurrencyEvidence(text) != .conflicting else { return nil }
        return text.trimmingCharacters(in: .whitespaces).wholeMatch(of: price).map { normalizedAmount($0.1) }
    }

    static func isVoidedOrUnreceived(_ wording: String) -> Bool {
        let cancellation = #/(?i)\b(?:void(?:ed)?|cancel(?:led|ed|lation)?|anulad[oa]s?|cancelad[oa]s?|anulaci[oó]n|cancelaci[oó]n|unreceived|undelivered)\b/#
        let english = #/(?i)\b(?:(?:not|never)\s+(?:received|delivered)|(?:did\s+not|didn['’]t)\s+(?:receive|deliver)|no\s+(?!added\b|[\p{L}-]+\s+added\b)(?:[\p{L}\p{N}’'-]+\s+)+(?:received|delivered))\b/#
        let spanish = #/(?i)\b(?:sin\s+(?:recibir|entregar)|no\s+(?:se\s+)?(?:entreg(?:[oó]|aron|ad[oa]s?)|recib(?:[ií]|i[oó]|imos|ieron|id[oa]s?)|lleg(?:[oó]|aron)))\b/#
        return wording.contains(cancellation) || wording.contains(english) || wording.contains(spanish)
    }

    static func permitsPutawayWording(_ wording: String) -> Bool {
        !wording.contains(nonItem) && !wording.contains(mixed) && !wording.contains(signedValue)
            && !wording.contains(#/(?i)\b(?:unusable|inservibles?|falt[oó]|no lleg[oó]|sin recibir|prepared|preparad[oa]s?|hot lunch|almuerzo caliente|a medio comer)\b/#)
    }

    static func canSuggestAmount(for wording: String) -> Bool {
        guard !wording.contains(nonItem), !wording.contains(rateByUnit), !wording.contains(mixed),
              !wording.contains(signedValue), !wording.contains(otherNumbers) else { return false }
        let printed = Self(.init(originalText: wording), knownStorage: [:])
        return printed.kind == .item && printed.name != nil && printed.amount == nil
    }

    init(_ row: ScanReceiptLine, knownStorage: [String:Set<InventoryLocation>]) {
        let text = row.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let readings = Set([text, row.originalText, row.priceNote].filter { !$0.isEmpty })
        let evidence = readings.map(PrintedCurrencyEvidence.init)
        let explicit = Set(evidence.compactMap(\.currency))
        if explicit.count > 1 || evidence.contains(.conflicting) || readings.contains(where: Self.hasForeignCurrency) {
            currencyEvidence = .conflicting
        } else if let currency = explicit.first {
            currencyEvidence = .explicit(currency)
        }
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
            // Check all the original wording before the total. Rate stripping above can
            // hide a second numeric basis that this simple merchandise form cannot resolve.
            let beforeTotal = text.dropLast(priceWording?.count ?? 0)
            guard !hasConflictingCurrency, beforeTotal.trimmingCharacters(in: .whitespaces) == candidate,
                  priceWording == nil || beforeTotal.last?.isWhitespace == true,
                  let item = candidate.wholeMatch(of: Self.itemWithUnresolvedNumbers),
                  item.2 == nil || priceWording == nil,
                  !text.contains(Self.nonItem), !text.contains(Self.rateByUnit),
                  !text.contains(Self.unitPrice), !text.contains(Self.packageBasis) else {
                amount = nil; priceWording = nil; uncertain = true; return
            }
            candidate = String(item.1)
        }
        let measurements = candidate.matches(of: Self.measure)
        if measurements.count == 1, let match = measurements.first,
           !candidate[..<match.range.lowerBound].contains(Self.precedingBasis),
           !candidate[match.range.upperBound...].contains(Self.followingBasis) {
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
        acceptsFieldNotes = true
        if !row.quantityNote.isEmpty {
            quantity = nil; unit = nil
            if let note = row.quantityNote.trimmingCharacters(in: .whitespaces).wholeMatch(of: Self.measure),
               let measured = Self.measurement(String(note.1), unit: String(note.2)) {
                quantity = measured.0; unit = measured.1
            }
        }
        if hasConflictingCurrency {
            amount = nil
            priceWording = nil
        } else if !row.priceNote.isEmpty {
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
        let parsed: UnitOfMeasure? = ["ea","each","ct","count","unit","units","unidad","unidades","ud","uds"].contains(token) ? .count : ListQuantityParser.takeUnit(from: &tokens)
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
