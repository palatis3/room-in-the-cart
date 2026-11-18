import Foundation

/// What an adult reviewed about one product and its price. A price has no stock or settlement effect.
public struct PrivatePriceEvidence: Codable, Equatable, Identifiable, Sendable {
    public struct ReceiptSource: Codable, Equatable, Sendable {
        public let receiptID: UUID
        public let acquisitionID: UUID
        public let lotID: UUID
        public let originalLine: String
        public let documentLine: ReceiptAcquisition.DocumentLine?
        public let imageDigest: Data?
    }

    public enum Source: Codable, Equatable, Sendable {
        case paidReceipt(ReceiptSource)
        case paidManual
        case shelf
        case currentQuote
        case adjustment(target: UUID, revision: Int64, kind: AdjustmentKind)
    }

    public enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
        case refund, discount, unallocatedCredit
    }

    /// The amount applies to the entire reviewed bundle, including all packages in an offer.
    public struct Pack: Codable, Equatable, Sendable {
        public let count: Int64
        public let perPackage: Quantity

        public init(count: Int64 = 1, perPackage: Quantity) {
            self.count = count
            self.perPackage = perPackage
        }

        func validate() throws {
            guard (1...100_000).contains(count), perPackage.amount > .zero else { throw DomainError.invalidInput("pricePack") }
            try perPackage.validate()
        }
    }

    public static let supportedCurrencies = ["USD", "CAD", "EUR", "GBP"]

    public let id: UUID
    public let revision: Int64
    public let source: Source
    public let linkedLotID: UUID?
    public let foodID: UUID?
    public let name: String
    /// An explicitly reviewed variety, brand, or other distinguishing product description.
    public let variant: String?
    public let store: String
    public let branch: String?
    public let mode: FulfillmentMode?
    public let date: Date
    public let currencyCode: String
    public let amountMinor: Int64?
    public let pack: Pack?
    public let eligibility: String?
    public let shelfImage: ReviewedShelfImage?
    public let sourceText: String

    public init(id: UUID, revision: Int64 = 1, source: Source, foodID: UUID? = nil, linkedLotID: UUID? = nil, name: String,
                variant: String? = nil, store: String, branch: String? = nil, mode: FulfillmentMode? = nil,
                date: Date, currencyCode: String, amountMinor: Int64?, pack: Pack?, eligibility: String? = nil,
                sourceText: String, shelfImage: ReviewedShelfImage? = nil) {
        self.id = id
        self.revision = revision
        self.source = source
        self.linkedLotID = linkedLotID
        self.foodID = foodID
        self.name = name
        self.variant = variant
        self.store = store
        self.branch = branch
        self.mode = mode
        self.date = date
        self.currencyCode = currencyCode
        self.amountMinor = amountMinor
        self.pack = pack
        self.eligibility = eligibility
        self.shelfImage = shelfImage
        self.sourceText = sourceText
    }

    public init(receipt: ReceiptAcquisition) throws {
        try receipt.validate()
        let source = ReceiptSource(receiptID: receipt.receiptID, acquisitionID: receipt.id,
                                   lotID: receipt.lotID, originalLine: receipt.originalLine,
                                   documentLine: receipt.documentLine, imageDigest: receipt.imageDigest)
        self.init(id: receipt.lineID, revision: receipt.revision, source: .paidReceipt(source),
                  foodID: receipt.foodID, linkedLotID: receipt.lotID, name: receipt.name, store: receipt.merchant, date: receipt.purchaseDate,
                  currencyCode: receipt.paidLineTotal?.currency.rawValue ?? Currency.usd.rawValue,
                  amountMinor: receipt.paidLineTotal?.minorUnits, pack: Pack(perPackage: receipt.received),
                  sourceText: receipt.originalLine)
        try validate()
    }

    public var isPaidPrice: Bool {
        switch source {
        case .paidReceipt, .paidManual: return true
        case .shelf, .currentQuote, .adjustment: return false
        }
    }

    public func validate() throws {
        guard revision > 0, date.timeIntervalSinceReferenceDate.isFinite,
              Self.supportedCurrencies.contains(currencyCode),
              amountMinor.map({ $0 >= 0 }) ?? true else { throw DomainError.invalidInput("priceEvidence") }
        for text in [name, store, variant, branch, eligibility].compactMap({ $0 }) {
            try ledgerText(text, nonempty: true, maximum: 512)
        }
        try ledgerText(sourceText, nonempty: true, maximum: 8192)
        try pack?.validate()
        if let shelfImage {
            try shelfImage.printed.validate()
            guard source == .shelf, shelfImage.printed.shelfID == id,
                  shelfImage.basis != .unknown || pack == nil else { throw DomainError.invalidInput("shelfImageBasis") }
        }
        switch source {
        case .adjustment(let target, let targetRevision, _):
            guard target != id, targetRevision > 0, amountMinor != nil, pack == nil else { throw DomainError.invalidInput("priceAdjustment") }
        case .paidReceipt(let value):
            guard foodID != nil, linkedLotID == value.lotID, value.originalLine == sourceText else { throw DomainError.invalidInput("receiptPriceSource") }
        case .paidManual:
            guard amountMinor != nil else { throw DomainError.invalidInput("manualPaidPrice") }
        case .shelf, .currentQuote: break
        }
    }

    public func validateAdjustmentTarget(_ paid: Self) throws {
        guard case .adjustment(let target, let targetRevision, _) = source,
              paid.isPaidPrice, paid.id == target, paid.revision == targetRevision,
              paid.currencyCode == currencyCode, paid.foodID == foodID, paid.linkedLotID == linkedLotID,
              paid.amountMinor != nil else { throw DomainError.invalidInput("priceAdjustmentTarget") }
    }

    public func netAmount(adjustments: [Self]) throws -> Int64? {
        try validate()
        guard let amountMinor else { return nil }
        var net = amountMinor
        var seen = Set<UUID>()
        for adjustment in adjustments {
            try adjustment.validate()
            guard case .adjustment(let target, let sourceRevision, let kind) = adjustment.source,
                  target == id, sourceRevision == revision, kind != .unallocatedCredit else { continue }
            guard seen.insert(adjustment.id).inserted, adjustment.currencyCode == currencyCode,
                  let credit = adjustment.amountMinor, credit <= net else { throw DomainError.invalidInput("priceAdjustment") }
            net -= credit
        }
        return net
    }

    /// Exact minor units per requested unit, using only the reviewed package denominator.
    public func unitPrice(in unit: UnitOfMeasure, adjustments: [Self] = []) throws -> Rational? {
        guard let net = try netAmount(adjustments: adjustments), let pack,
              let quantity = try pack.perPackage.converted(to: unit) else { return nil }
        return try Rational(net).divided(by: quantity.multiplied(by: Rational(pack.count)))
    }

    /// Anonymous product names alone cannot establish equivalence for purchases with different variants.
    public func comparablePaidPrice(to other: Self, in unit: UnitOfMeasure) throws -> Bool {
        guard isPaidPrice, other.isPaidPrice, currencyCode == other.currencyCode else { return false }
        let sharedFood = foodID != nil && foodID == other.foodID
        let sharedVariant = variant != nil && variant == other.variant && name == other.name
        guard (sharedFood || sharedVariant), variant == other.variant else { return false }
        return try unitPrice(in: unit) != nil && other.unitPrice(in: unit) != nil
    }
}
