import Foundation

public struct PackOffer: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// Confirmed usable quantity of ONE package. Nil is unknown yield.
    public let usableQuantity: Quantity?
    /// Cost of ONE package. Nil is unknown, distinct from a free package.
    public let price: Money?
    public let confirmedConversion: UnitBasis?

    public init(id: String, label: String, usableQuantity: Quantity?, price: Money?,
                confirmedConversion: UnitBasis? = nil) {
        self.id = id
        self.label = label
        self.usableQuantity = usableQuantity
        self.price = price
        self.confirmedConversion = confirmedConversion
    }
}

public struct ComparisonRequest: Codable, Hashable, Sendable {
    public let itemName: String
    public let needed: Quantity?
    /// Only confirmed usable stock matched to this item and available for THIS
    /// demand. Reservations for other demands must already have been removed.
    /// Nil contributes no confirmed stock; it does not assert pantry is empty.
    public let confirmedAtHome: Quantity?
    /// A protected partition INSIDE needed, never an additional demand.
    public let protectedAmount: Quantity?
    public let offerA: PackOffer
    public let offerB: PackOffer
    public let itemCap: Money?

    public init(itemName: String, needed: Quantity?, confirmedAtHome: Quantity? = nil,
                protectedAmount: Quantity? = nil, offerA: PackOffer, offerB: PackOffer, itemCap: Money? = nil) {
        self.itemName = itemName
        self.needed = needed
        self.confirmedAtHome = confirmedAtHome
        self.protectedAmount = protectedAmount
        self.offerA = offerA
        self.offerB = offerB
        self.itemCap = itemCap
    }
}

public enum ComparisonScope: String, Codable, Sendable { case itemOnly }
public enum ComparisonIssue: String, Codable, Sendable {
    case neededQuantityUnknown
    case atHomeConversionUnknown
    case protectedConversionUnknown
    case usableQuantityUnknown
    case usableConversionUnknown
    case noUsableYield
    case priceUnknown
}

public struct OfferResult: Codable, Equatable, Sendable {
    public let offerID: String
    public let packsToBuy: Int64?
    public let totalCost: Money?
    /// All rational result quantities use ComparisonResult.unit.
    public let amountToBuy: Rational?
    public let purchasedAmount: Rational?
    public let leftover: Rational?
    public let remainingNeed: Rational?
    public let protectedAmount: Rational?
    /// Signed, ITEM-only cap less purchase cost. Never whole-pickup headroom.
    public let itemHeadroom: Money?
    /// Maximum cents per whole package under this ITEM cap, rounded DOWN.
    /// Nil when no package is needed or required package count is unresolved.
    public let unitCeiling: Money?
    public let issues: [ComparisonIssue]
    public var isResolved: Bool { issues.isEmpty }
}

public struct ComparisonResult: Codable, Equatable, Sendable {
    public let scope: ComparisonScope
    public let unit: UnitOfMeasure?
    public let offerA: OfferResult
    public let offerB: OfferResult
    /// Cheapest resolved offer for the same need, nil for ties or any uncertainty.
    /// This does not imply the item cap or the household budget is satisfied.
    public let preferredOfferID: String?
}

public enum PackComparison {
    public static func evaluate(_ request: ComparisonRequest) throws -> ComparisonResult {
        try validate(request)
        let a = try evaluate(request.offerA, request: request)
        let b = try evaluate(request.offerB, request: request)
        var preferred: String?
        if a.isResolved, b.isResolved, let ac = a.totalCost, let bc = b.totalCost, ac != bc {
            preferred = ac < bc ? a.offerID : b.offerID
        }
        return ComparisonResult(scope: .itemOnly, unit: request.needed?.unit,
                                offerA: a, offerB: b, preferredOfferID: preferred)
    }

    private static func validate(_ request: ComparisonRequest) throws {
        guard request.itemName.utf8.count <= 512 else { throw DomainError.invalidInput("itemNameTooLong") }
        guard request.offerA.id != request.offerB.id,
              request.itemCap.map({ $0.minorUnits >= 0 }) ?? true else {
            throw DomainError.invalidInput("comparison")
        }
        for quantity in [request.needed, request.confirmedAtHome, request.protectedAmount] {
            try quantity?.validate()
        }
        for offer in [request.offerA, request.offerB] {
            guard offer.label.utf8.count <= 512 else {
                throw DomainError.invalidInput(offer.id == request.offerA.id ? "offerANameTooLong" : "offerBNameTooLong")
            }
            guard !offer.id.isEmpty, offer.id.utf8.count <= 128,
                  offer.price.map({ $0.minorUnits >= 0 }) ?? true else {
                throw DomainError.invalidInput("offer")
            }
            try offer.usableQuantity?.validate()
            try offer.confirmedConversion?.validate()
        }
    }

    private static func evaluate(_ offer: PackOffer, request: ComparisonRequest) throws -> OfferResult {
        var issues: [ComparisonIssue] = []
        var amountToBuy: Rational?, protected: Rational?, packs: Int64?
        var purchased: Rational?, leftover: Rational?, remaining: Rational?, cost: Money?
        if let need = request.needed {
            let stock = try request.confirmedAtHome?.converted(to: need.unit) ?? (request.confirmedAtHome == nil ? Rational.zero : nil)
            protected = try request.protectedAmount?.converted(to: need.unit) ?? (request.protectedAmount == nil ? Rational.zero : nil)
            if stock == nil { issues.append(.atHomeConversionUnknown) }
            if protected == nil { issues.append(.protectedConversionUnknown) }
            if let protected, protected > need.amount { throw DomainError.invalidInput("protectedExceedsNeed") }
            if let stock, protected != nil {
                let buy = try need.amount > stock ? need.amount.subtracting(stock) : .zero
                amountToBuy = buy
                if buy == .zero {
                    packs = 0
                    purchased = .zero
                    leftover = try stock.subtracting(need.amount)
                    remaining = .zero
                    cost = .zero // No purchase; never substitutes zero for an unknown pack price.
                } else if let usable = offer.usableQuantity {
                    if let yield = try usable.converted(to: need.unit, using: offer.confirmedConversion) {
                        if yield == .zero {
                            issues.append(.noUsableYield)
                            remaining = buy
                        } else {
                            let count = try buy.divided(by: yield).roundedUp()
                            packs = count
                            let bought = try yield.multiplied(by: Rational(count))
                            purchased = bought
                            leftover = try bought.subtracting(buy)
                            remaining = .zero
                        }
                    } else { issues.append(.usableConversionUnknown) }
                } else { issues.append(.usableQuantityUnknown) }
            }
        } else { issues.append(.neededQuantityUnknown) }
        if let packs, packs > 0, let price = offer.price { cost = try price.multiplied(by: packs) }
        if offer.price == nil && packs != 0 { issues.append(.priceUnknown) }
        let headroom = try request.itemCap.flatMap { cap in try cost.map { try cap.subtracting($0) } }
        let ceiling: Money?
        if let cap = request.itemCap, let packs, packs > 0 {
            ceiling = Money(minorUnits: cap.minorUnits / packs)
        } else { ceiling = nil }
        return OfferResult(offerID: offer.id, packsToBuy: packs, totalCost: cost,
                           amountToBuy: amountToBuy, purchasedAmount: purchased, leftover: leftover,
                           remainingNeed: remaining, protectedAmount: protected, itemHeadroom: headroom,
                           unitCeiling: ceiling, issues: issues)
    }
}
