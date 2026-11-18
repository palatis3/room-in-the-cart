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
        public let amount: Money?
        public let conditions: String?
    }

    /// Suggests only explicit bundle wording. A bare unit price cannot imply package size.
    public static func propose(_ text: String) -> Proposal {
        let s = text.lowercased()
        let pattern = #"(?<![\d.,])([1-9][0-9]{0,3})\s*(?:for|por|/)\s*([$€£])\s*([0-9]+(?:[.,][0-9]{1,2})?)(?![.,0-9])"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []
        let terms = s.range(of: #"\b(member|members|socio|socios|miembros|club|loyalty|tarjeta)\b"#, options: .regularExpression) != nil ? text : nil
        guard matches.count == 1, let match = matches.first, let quantity = Range(match.range(at: 1), in: s),
              let price = Range(match.range(at: 3), in: s), let count = Int64(s[quantity]) else {
            return .init(packages: nil, amount: nil, conditions: terms)
        }
        let amount = try? Money(decimal: s[price].replacingOccurrences(of: ",", with: "."))
        return .init(packages: count, amount: amount, conditions: terms)
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
