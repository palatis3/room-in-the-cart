import Foundation

/// Draft values from selected image text. Original wording remains the source of a reviewed price.
enum PrintedPriceText {
    static let number = #"[0-9]{1,9}(?:[.,][0-9]{1,2})?"#
    static let markedPrice = try! NSRegularExpression(
        pattern: #"(?<![\p{L}0-9.,-])(?:(?:US\$|USD|CAD|EUR|GBP|[$€£])\s*("# + number
            + #")(?![0-9]|[.,][0-9])(?:\s+(?:USD|CAD|EUR|GBP)\b)?|("# + number + #")\s+(?:USD|CAD|EUR|GBP)\b)"#,
        options: [.caseInsensitive])
    static let measureNumber = try! NSRegularExpression(
        pattern: #"(?<![\p{L}0-9$€£.,/–-])([0-9]{1,6}(?:[.,][0-9]{1,2})?)(?![0-9.,])"#)

    static func packageSize(in wording: String) -> Quantity? {
        var found: Quantity?
        for match in measureNumber.matches(in: wording, range: NSRange(wording.startIndex..., in: wording)) {
            guard let range = Range(match.range(at: 1), in: wording) else { continue }
            let prefix = wording[..<range.lowerBound].lowercased()
            // A unit-price denominator or a size range does not describe the purchased package.
            guard prefix.range(of: #"(?:/|\bper|\bpor|\bto|\ba|[-–×]|\d\s*x)\s*$"#, options: .regularExpression) == nil else { continue }
            let suffix = wording[range.upperBound...]
            var units = suffix.split(whereSeparator: \.isWhitespace).prefix(2).map(String.init)[...]
            guard let unit = ListQuantityParser.takeUnit(from: &units),
                  let amount = try? ListQuantityParser.numericAmount(String(wording[range]).replacingOccurrences(of: ",", with: ".")),
                  amount > .zero else { continue }
            guard found == nil else { return nil }
            found = Quantity(amount: amount, unit: unit, originalLiteral: wording)
        }
        return found
    }

    private static let rateMarker = try! NSRegularExpression(
        pattern: #"(?:/|\bper\s+|\bpor\s+|\bcada\s+)\s*(?:([0-9]{1,6}(?:[.,][0-9]{1,2})?)\s*)?(?=\p{L})"#,
        options: [.caseInsensitive])

    static func rateQuantity(in wording: String) -> Quantity? {
        var found: Quantity?
        for match in rateMarker.matches(in: wording, range: NSRange(wording.startIndex..., in: wording)) {
            guard let marker = Range(match.range, in: wording) else { continue }
            var units = wording[marker.upperBound...].split(whereSeparator: \.isWhitespace).prefix(2).map(String.init)[...]
            guard let unit = ListQuantityParser.takeUnit(from: &units) else { continue }
            let literal = Range(match.range(at: 1), in: wording).map { String(wording[$0]) } ?? "1"
            guard found == nil, let amount = try? ListQuantityParser.numericAmount(literal.replacingOccurrences(of: ",", with: ".")),
                  amount > .zero else { return nil }
            found = Quantity(amount: amount, unit: unit, originalLiteral: wording)
        }
        return found
    }

    static func singlePrice(in wording: String) -> Money? {
        let matches = markedPrice.matches(in: wording, range: NSRange(wording.startIndex..., in: wording))
        guard matches.count == 1, let match = matches.first,
              let range = Range(match.range(at: 1), in: wording) ?? Range(match.range(at: 2), in: wording) else { return nil }
        return try? Money(decimal: wording[range].replacingOccurrences(of: ",", with: "."))
    }
}

extension ReviewedCheckoutImage {
    private static let labels: [String: Field] = [
        "subtotal": .subtotal, "sub total": .subtotal, "items subtotal": .subtotal,
        "discount": .discount, "discounts": .discount, "descuento": .discount, "descuentos": .discount,
        "tax": .tax, "sales tax": .tax, "impuesto": .tax, "impuestos": .tax, "iva": .tax,
        "tip": .tip, "driver tip": .tip, "propina": .tip,
        "fee": .fee, "service fee": .fee, "delivery fee": .fee, "fees": .fee,
        "cargo por servicio": .fee, "gastos de envio": .fee, "tarifa de entrega": .fee,
        "total": .total, "grand total": .total, "order total": .total, "total del pedido": .total,
        "total a pagar": .total
    ]
    private static let priceAtEnd = try! NSRegularExpression(
        pattern: #"(?:^|[\s:])(-?)\s*(USD\s*|US\$|\$)?\s*(-?)("# + PrintedPriceText.number + #")(\s*USD)?$"#,
        options: [.caseInsensitive])

    private static func reading(_ wording: String, selectedField: Field? = nil) -> (field: Field, amount: Money?)? {
        let text = wording.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let boundary = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":"))
        guard let match = priceAtEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let entire = Range(match.range, in: text), let number = Range(match.range(at: 4), in: text) else {
            return labels[text.trimmingCharacters(in: boundary)].map { ($0, nil) }
        }
        let label = String(text[..<entire.lowerBound]).trimmingCharacters(in: boundary)
        guard let field = label.isEmpty ? selectedField : labels[label] else { return nil }
        let negative = match.range(at: 1).length + match.range(at: 3).length
        let literal = String(text[number])
        guard negative == 0 || (field == .discount && negative == 1),
              match.range(at: 2).location != NSNotFound || match.range(at: 5).location != NSNotFound
                || literal.contains(".") || literal.contains(",") else { return (field, nil) }
        return (field, try? Money(decimal: literal.replacingOccurrences(of: ",", with: ".")))
    }

    /// Selecting a field can use a confirmed crop reading even when the original OCR was uncertain.
    public static func proposedAmount(for field: Field, from line: PriceImageLine) -> Money? {
        guard !line.uncertain || line.reviewedReading != nil,
              let suggestion = reading(line.effectiveWording, selectedField: field), suggestion.field == field else { return nil }
        return suggestion.amount
    }

    /// One clearly labelled amount per field. Multiple fees or totals require the adult to choose.
    public static func proposals(from lines: [PriceImageLine]) -> [Field: Charge] {
        var proposals: [Field: Charge] = [:]
        var seen: Set<Field> = []
        for line in lines {
            guard let reading = reading(line.effectiveWording) else { continue }
            if !seen.insert(reading.field).inserted {
                proposals.removeValue(forKey: reading.field)
            } else if line.reviewedReading == nil, !line.uncertain, let amount = reading.amount {
                proposals[reading.field] = Charge(field: reading.field, amount: amount, inclusion: .unknown, line: line)
            }
        }
        return proposals
    }
}
