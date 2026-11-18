import Foundation

/// Only the selected source wording and digest persist. The reviewed photo remains device-local.
public struct PriceImageLine: Codable, Equatable, Sendable {
    public let digest: Data
    public let ordinal: Int
    public let wording: String
    public let uncertain: Bool

    public init(digest: Data, ordinal: Int, wording: String, uncertain: Bool) throws {
        self.digest = digest
        self.ordinal = ordinal
        self.wording = wording
        self.uncertain = uncertain
        try validate()
    }

    public func validate() throws {
        guard digest.count == 32, (0..<200).contains(ordinal) else { throw DomainError.invalidInput("imagePriceLine") }
        try ledgerText(wording, nonempty: true, maximum: 2048)
    }

    public var shelfID: UUID {
        ReceiptAcquisition.identity(["shelf-image", digest.base64EncodedString(), String(ordinal)])
    }
}

public struct ReviewedShelfImage: Codable, Equatable, Sendable {
    public enum PriceBasis: String, Codable, CaseIterable, Sendable { case bundle, unit, unknown }
    public let printed: PriceImageLine
    public let basis: PriceBasis
    public init(printed: PriceImageLine, basis: PriceBasis) { self.printed = printed; self.basis = basis }

    public struct Proposal: Equatable, Sendable {
        public let packages: Int64?
        public let packageSize: Quantity?
        public let rateQuantity: Quantity?
        public var priceBasis: PriceBasis {
            if rateQuantity != nil { return .unit }
            if packages != nil || (packageSize != nil && amount != nil) { return .bundle }
            return .unknown
        }
        public let amount: Money?
        public let conditions: String?
        public let currencyCode: String?
    }

    /// Package measurements and prices are proposed independently of membership and eligibility.
    public static func propose(_ text: String) -> Proposal {
        let s = text.lowercased()
        let size = PrintedPriceText.packageSize(in: text)
        let pattern = #"(?<![\d.,])([1-9][0-9]{0,3})\s*(?:for|por|/)\s*([$€£])\s*([0-9]+(?:[.,][0-9]{1,2})?)(?![.,0-9])"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []
        let terms = s.range(of: #"\b(member|members|socio|socios|miembros|club|loyalty|tarjeta|coupon|cup[oó]n|limit|l[ií]mite|with purchase|con la compra)\b"#, options: .regularExpression) != nil ? text : nil
        let codes = PrivatePriceEvidence.supportedCurrencies.filter { code in
            s.range(of: #"\b"# + code.lowercased() + #"\b"#, options: .regularExpression) != nil
        }
        var currencies = Set(codes)
        if s.contains("€") { currencies.insert("EUR") }
        if s.contains("£") { currencies.insert("GBP") }
        if s.contains("$"), !currencies.isSubset(of: ["USD","CAD"]) { currencies.removeAll() }
        let currency = currencies.count == 1 ? currencies.first : nil
        guard matches.count == 1, let match = matches.first, let quantity = Range(match.range(at: 1), in: s),
              let price = Range(match.range(at: 3), in: s), let count = Int64(s[quantity]) else {
            let promotion = s.range(of: #"\b(save|savings|ahorra|ahorro|coupon|cup[oó]n|off)\b"#, options: .regularExpression) != nil
            return .init(packages: nil, packageSize: size, rateQuantity: PrintedPriceText.rateQuantity(in: text), amount: promotion ? nil : PrintedPriceText.singlePrice(in: text),
                         conditions: terms, currencyCode: currency)
        }
        // A second marked price may belong to a different offer on the same label.
        let amount = PrintedPriceText.singlePrice(in: text) == nil ? nil
            : try? Money(decimal: s[price].replacingOccurrences(of: ",", with: "."))
        return .init(packages: count, packageSize: size, rateQuantity: nil, amount: amount, conditions: terms, currencyCode: currency)
    }
}

public struct ReviewedCheckoutImage: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable { case subtotal, discount, tax, tip, fee, total }
    public enum Inclusion: String, Codable, CaseIterable, Sendable { case unknown, included, additional }
    public struct Charge: Codable, Equatable, Sendable {
        public let field: Field
        public let amount: Money?
        public let inclusion: Inclusion
        public let line: PriceImageLine
        public init(field: Field, amount: Money?, inclusion: Inclusion, line: PriceImageLine) {
            self.field = field; self.amount = amount; self.inclusion = inclusion; self.line = line
        }
    }
    public let charges: [Charge]
    public init(charges: [Charge]) throws { self.charges = charges; try validate() }
    public func validate() throws {
        guard !charges.isEmpty, charges.count <= Field.allCases.count,
              Set(charges.map(\.field)).count == charges.count, Set(charges.map(\.line.ordinal)).count == charges.count,
              Set(charges.map(\.line.digest)).count == 1 else { throw DomainError.invalidInput("checkoutImage") }
        for charge in charges {
            try charge.line.validate()
            guard charge.amount.map({ $0.minorUnits >= 0 }) ?? true,
                  charge.field != .total || charge.inclusion == .unknown else { throw DomainError.invalidInput("checkoutImageCharge") }
        }
    }
    public var displayedTotal: Money? { charges.first { $0.field == .total }?.amount }
}
