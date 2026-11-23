import Foundation

/// What an adult reviewed about one product and its price. A price has no stock or settlement effect.
public struct PrivatePriceEvidence: Codable, Equatable, Identifiable, Sendable {
    public struct ReceiptSource: Codable, Equatable, Sendable {
        public let receiptID: UUID
        public let acquisitionID: UUID
        public let purchaseDay: MealDay?
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

    public enum TaxTreatment: String, Codable, CaseIterable, Sendable { case included, excluded }

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

    public static let supportedCurrencies = ["USD", "MXN", "CAD", "EUR", "GBP"]

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
    /// The usable portion of a receipt line can be smaller than the purchased amount.
    public let confirmedUsable: Quantity?
    public let eligibility: String?
    public let taxTreatment: TaxTreatment?
    public let shelfImage: ReviewedShelfImage?
    public let sourceText: String

    public init(id: UUID, revision: Int64 = 1, source: Source, foodID: UUID? = nil, linkedLotID: UUID? = nil, name: String,
                variant: String? = nil, store: String, branch: String? = nil, mode: FulfillmentMode? = nil,
                date: Date, currencyCode: String, amountMinor: Int64?, pack: Pack?, eligibility: String? = nil,
                sourceText: String, shelfImage: ReviewedShelfImage? = nil, taxTreatment: TaxTreatment? = nil, confirmedUsable: Quantity? = nil) {
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
        self.confirmedUsable = confirmedUsable
        self.eligibility = eligibility
        self.shelfImage = shelfImage
        self.taxTreatment = taxTreatment
        self.sourceText = sourceText
    }

    public init(receipt: ReceiptAcquisition) throws {
        try receipt.validate()
        let source = ReceiptSource(receiptID: receipt.receiptID, acquisitionID: receipt.id, purchaseDay: receipt.purchaseDay,
                                   lotID: receipt.lotID, originalLine: receipt.originalLine,
                                   documentLine: receipt.documentLine, imageDigest: receipt.imageDigest)
        self.init(id: receipt.lineID, revision: receipt.revision, source: .paidReceipt(source),
                  foodID: receipt.foodID, linkedLotID: receipt.lotID, name: receipt.name, store: receipt.merchant, date: receipt.purchaseDate,
                  currencyCode: receipt.currency.rawValue,
                  amountMinor: receipt.paidLineTotal?.minorUnits, pack: Pack(perPackage: receipt.received),
                  sourceText: receipt.originalLine, confirmedUsable: receipt.usable)
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
              Self.supportedCurrencies.contains(currencyCode) || (shelfImage != nil && amountMinor == nil && currencyCode.isEmpty),
              amountMinor.map({ $0 >= 0 }) ?? true else { throw DomainError.invalidInput("priceEvidence") }
        for text in [name, store, variant, branch, eligibility].compactMap({ $0 }) {
            try ledgerText(text, nonempty: true, maximum: 512)
        }
        try ledgerText(sourceText, nonempty: true, maximum: 8192)
        try pack?.validate()
        if let confirmedUsable {
            guard case .paidReceipt = source, let pack, pack.count == 1, confirmedUsable.unit == pack.perPackage.unit,
                  confirmedUsable.amount <= pack.perPackage.amount else { throw DomainError.invalidInput("receiptPriceUsable") }
            try confirmedUsable.validate()
        }
        if let shelfImage {
            try shelfImage.printed.validate()
            guard source == .shelf, shelfImage.printed.shelfID == id,
                  shelfImage.basis != .unknown || pack == nil,
                  shelfImage.basis != .unit || pack == nil || pack?.count == 1 else { throw DomainError.invalidInput("shelfImageBasis") }
        }
        switch source {
        case .adjustment(let target, let targetRevision, _):
            guard target != id, targetRevision > 0, amountMinor != nil, pack == nil else { throw DomainError.invalidInput("priceAdjustment") }
        case .paidReceipt(let value):
            if let day = value.purchaseDay, day != (try MealDay(date: date, timeZoneIdentifier: day.timeZoneIdentifier)) {
                throw DomainError.invalidInput("receiptPriceDay")
            }
            guard foodID != nil, linkedLotID == value.lotID, value.originalLine == sourceText else { throw DomainError.invalidInput("receiptPriceSource") }
        case .paidManual:
            guard amountMinor != nil else { throw DomainError.invalidInput("manualPaidPrice") }
        case .shelf, .currentQuote: break
        }
    }

    /// Older shelf records preserve the denomination the shopper entered. A new price revision or
    /// publication must also agree with the currency visible in the reviewed image wording.
    public var shelfCurrencyMatches: Bool {
        guard let shelfImage, amountMinor != nil else { return true }
        return ReviewedShelfImage.priceCurrencies(in: shelfImage.printed.effectiveWording).contains(currencyCode)
    }

    public func validateForRecording() throws {
        try validate()
        guard shelfCurrencyMatches else { throw DomainError.invalidInput("shelfImageCurrency") }
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

/// The quantity and amount describe the same shelf bundle or printed unit-price basis.
public struct ShelfPriceOffer: Equatable, Sendable {
    public enum QuantityBasis: Sendable { case purchased, usable }
    public let basis: QuantityBasis
    public let product: String
    public let variant: String
    public let pack: PrivatePriceEvidence.Pack?
    public let amountMinor: Int64?
    public let currency: String
    public let eligibility: String
    public let tax: PrivatePriceEvidence.TaxTreatment?

    public init(product: String, variant: String, pack: PrivatePriceEvidence.Pack?, amountMinor: Int64?,
                currency: String, eligibility: String, tax: PrivatePriceEvidence.TaxTreatment?,
                basis: QuantityBasis = .purchased) {
        self.basis = basis
        self.product = product
        self.variant = variant
        self.pack = pack
        self.amountMinor = amountMinor
        self.currency = currency
        self.eligibility = eligibility
        self.tax = tax
    }

    public static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func candidates(in records: [PrivatePriceEvidence], through date: Date) -> [PrivatePriceEvidence] {
        guard let pack, pack.count > 0, pack.perPackage.amount > .zero, !Self.normalized(product).isEmpty else { return [] }
        return records.filter { row in
            let paidVariant = Self.normalized(row.variant)
            return row.isPaidPrice && row.amountMinor != nil && row.date <= date && row.currencyCode == currency
                && Self.normalized(row.name) == Self.normalized(product)
                && (Self.normalized(variant).isEmpty || paidVariant.isEmpty || paidVariant == Self.normalized(variant))
                && Self.normalized(row.eligibility) == Self.normalized(eligibility)
                && (row.taxTreatment == nil || tax == nil || row.taxTreatment == tax)
                && row.pack?.perPackage.unit.dimension == pack.perPackage.unit.dimension
                && (basis != .usable || row.confirmedUsable?.amount != .zero)
        }.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }

    /// A named variant matches automatically. Unlabelled evidence requires the shopper to choose the actual purchase.
    public func purchase(in candidates: [PrivatePriceEvidence], chosenID: UUID?) -> PrivatePriceEvidence? {
        if let chosenID, let selected = candidates.first(where: { $0.id == chosenID }) {
            if let selectedVariant = selected.variant {
                return candidates.first { Self.normalized($0.variant) == Self.normalized(selectedVariant) }
            }
            return selected
        }
        guard !Self.normalized(variant).isEmpty else { return nil }
        return candidates.first { Self.normalized($0.variant) == Self.normalized(variant) }
    }

    public func needsBasisConfirmation(for paid: PrivatePriceEvidence) -> Bool {
        tax == nil || paid.taxTreatment == nil || Self.normalized(eligibility).isEmpty
            || (basis == .usable && paid.confirmedUsable == nil)
    }

    public func unitRates(for paid: PrivatePriceEvidence, adjustments: [PrivatePriceEvidence],
                          sameBasisConfirmed: Bool) throws -> (shelf: Rational, paid: Rational)? {
        guard sameBasisConfirmed || !needsBasisConfirmation(for: paid), let pack, let amountMinor, amountMinor >= 0,
              !candidates(in: [paid], through: paid.date).isEmpty else { return nil }
        try pack.validate()
        let historical: Rational
        if basis == .usable, let usable = paid.confirmedUsable {
            guard let net = try paid.netAmount(adjustments: adjustments),
                  let quantity = try usable.converted(to: pack.perPackage.unit), quantity > .zero else { return nil }
            historical = try Rational(net).divided(by: quantity)
        } else {
            guard let rate = try paid.unitPrice(in: pack.perPackage.unit, adjustments: adjustments) else { return nil }
            historical = rate
        }
        let totalQuantity = try pack.perPackage.amount.multiplied(by: Rational(pack.count))
        return (try Rational(amountMinor).divided(by: totalQuantity), historical)
    }
}
