import Foundation

public struct ReviewedImageWording: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case deviceOCR, assistedImage }
    public let text: String
    public let method: Method
    public let cropDigest: Data
    public init(text: String, method: Method, cropDigest: Data) throws {
        self.text = text; self.method = method; self.cropDigest = cropDigest
        try validate()
    }
    public func validate() throws {
        guard cropDigest.count == 32, text.utf8.count <= 512, !text.contains("\n") else { throw DomainError.invalidInput("imageReading") }
        try ledgerText(text, nonempty: true, maximum: 500)
    }
}

/// Only the selected source wording and digest persist. The reviewed photo remains device-local.
public struct PriceImageLine: Codable, Equatable, Sendable {
    public let digest: Data
    public let ordinal: Int
    public let wording: String
    public let uncertain: Bool
    public let reviewedReading: ReviewedImageWording?
    public var effectiveWording: String { reviewedReading?.text ?? wording }

    public init(digest: Data, ordinal: Int, wording: String, uncertain: Bool, reviewedReading: ReviewedImageWording? = nil) throws {
        self.digest = digest
        self.ordinal = ordinal
        self.wording = wording
        self.uncertain = uncertain
        self.reviewedReading = reviewedReading
        try validate()
    }

    public func validate() throws {
        guard digest.count == 32, (0..<200).contains(ordinal) else { throw DomainError.invalidInput("imagePriceLine") }
        try ledgerText(wording, nonempty: reviewedReading == nil, maximum: 2048)
        try reviewedReading?.validate()
    }

    public var shelfID: UUID {
        if wording.isEmpty, let reviewedReading {
            return ReceiptAcquisition.identity(["shelf-crop", digest.base64EncodedString(), reviewedReading.cropDigest.base64EncodedString()])
        }
        return ReceiptAcquisition.identity(["shelf-image", digest.base64EncodedString(), String(ordinal)])
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
            if packages != nil || (packageSize != nil && amountMinor != nil) { return .bundle }
            return .unknown
        }
        public let amountMinor: Int64?
        public let conditions: String?
        public let currencyCode: String?
        /// A bare dollar sign can be assigned a currency when the shopper explicitly confirms the offer.
        public let currencyUnspecified: Bool
    }

    /// Package measurements and prices are proposed independently of membership and eligibility.
    public static func propose(_ text: String) -> Proposal {
        let s = text.lowercased()
        let size = PrintedPriceText.packageSize(in: text)
        let prices = PrintedPriceText.markedPrice.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let bundleCounts = prices.compactMap { price -> Int64? in
            guard let range = Range(price.range, in: text) else { return nil }
            let prefix = text[..<range.lowerBound]
            guard let match = prefix.firstMatch(of: #/(?i)(?:^|[^\d.,])([1-9][0-9]{0,3})\s*(?:for|por|/)\s*$/#) else { return nil }
            return Int64(match.1)
        }
        let terms = s.range(of: #"\b(member|members|socio|socios|miembros|club|loyalty|tarjeta|coupon|cup[oó]n|limit|l[ií]mite|with purchase|con la compra)\b"#, options: .regularExpression) != nil ? text : nil
        let currency = shelfCurrency(in: text)
        guard bundleCounts.count == 1, let count = bundleCounts.first else {
            let promotion = s.range(of: #"\b(save|savings|ahorra|ahorro|coupon|cup[oó]n|off)\b"#, options: .regularExpression) != nil
            return .init(packages: nil, packageSize: size, rateQuantity: PrintedPriceText.rateQuantity(in: text), amountMinor: promotion ? nil : PrintedPriceText.singlePriceMinor(in: text),
                         conditions: terms, currencyCode: currency.code, currencyUnspecified: currency.unspecified)
        }
        // A second marked price may belong to a different offer on the same label.
        let amount = PrintedPriceText.singlePriceMinor(in: text)
        return .init(packages: count, packageSize: size, rateQuantity: nil, amountMinor: amount, conditions: terms, currencyCode: currency.code, currencyUnspecified: currency.unspecified)
    }

    public static func priceCurrencies(in wording: String) -> [String] {
        let currency = shelfCurrency(in: wording)
        if let code = currency.code { return [code] }
        return currency.unspecified ? ["USD", "MXN", "CAD"] : []
    }

    private static let isoCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))
    private static let dollarPrefixes = ["US": "USD", "USD": "USD", "MX": "MXN", "MEX": "MXN", "MXN": "MXN", "CA": "CAD", "C": "CAD", "CAD": "CAD"]

    private static func shelfCurrency(in text: String) -> (code: String?, unspecified: Bool) {
        var codes = Set<String>()
        let upper = text.uppercased()
        // Read supported codes case-insensitively; foreign ISO abbreviations printed in capitals
        // are distinct from product wording such as “try” or “all”.
        for token in text.matches(of: #/\b([A-Za-z]{3})(?:\b|(?=\d))/#) {
            let code = token.1.uppercased()
            if PrivatePriceEvidence.supportedCurrencies.contains(code) || (token.1 == code && isoCodes.contains(code)) {
                codes.insert(code)
            }
        }
        // A regional dollar marker is explicit even if that currency is outside the private price list.
        for prefix in upper.matches(of: #/\b([A-Z]{1,3})\$/#) {
            guard let code = dollarPrefixes[String(prefix.1)] else { return (nil, false) }
            codes.insert(code)
        }
        if upper.contains("€") { codes.insert("EUR") }
        if upper.contains("£") { codes.insert("GBP") }
        let receiptCurrency = PrintedCurrencyEvidence(text)
        if let local = receiptCurrency.currency {
            codes.insert(local.rawValue)
        } else if receiptCurrency == .conflicting && codes.isSubset(of: ["USD", "MXN"]) {
            return (nil, false)
        }
        let symbols = upper.unicodeScalars.filter { $0.properties.generalCategory == .currencySymbol }
        guard symbols.allSatisfy({ "$€£".unicodeScalars.contains($0) }),
              !upper.contains("$") || codes.isSubset(of: ["USD", "MXN", "CAD"]) else { return (nil, false) }
        guard let code = codes.first else { return (nil, upper.contains("$")) }
        return (codes.count == 1 && PrivatePriceEvidence.supportedCurrencies.contains(code) ? code : nil, false)
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
        let reviewedCrops = charges.compactMap { $0.line.reviewedReading?.cropDigest }
        guard Set(charges.compactMap { $0.amount?.currency }).count <= 1,
              Set(reviewedCrops).count == reviewedCrops.count, !charges.isEmpty, charges.count <= Field.allCases.count,
              Set(charges.map(\.field)).count == charges.count, Set(charges.map(\.line.ordinal)).count == charges.count,
              Set(charges.map(\.line.digest)).count == 1 else { throw DomainError.invalidInput("checkoutImage") }
        for charge in charges {
            try charge.line.validate()
            guard charge.amount.map({ $0.minorUnits >= 0 && PrintedCurrencyEvidence(charge.line.effectiveWording).permits($0.currency) }) ?? true,
                  charge.field != .total || charge.inclusion == .unknown else { throw DomainError.invalidInput("checkoutImageCharge") }
        }
    }
    public var displayedTotal: Money? { charges.first { $0.field == .total }?.amount }
}
