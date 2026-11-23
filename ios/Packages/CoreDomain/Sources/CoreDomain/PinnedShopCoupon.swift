import Foundation

public struct ShopCouponTerms: Codable, Equatable, Sendable {
    public let qualifyingSize: String
    public let minimumPacks: Int
    public let validThrough: MealDay
    public let retailerURL: URL?

    public init(qualifyingSize: String, minimumPacks: Int, validThrough: MealDay, retailerURL: URL? = nil) {
        self.qualifyingSize = qualifyingSize
        self.minimumPacks = minimumPacks
        self.validThrough = validThrough
        self.retailerURL = retailerURL
    }

    public func validate() throws {
        try ledgerText(qualifyingSize, maximum: 512)
        guard (1...10_000).contains(minimumPacks) else { throw LedgerError.invalid("couponPackCount") }
        try validThrough.validate()
        if let url = retailerURL {
            guard ["https", "http"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 2048 else {
                throw LedgerError.invalid("couponRetailerURL")
            }
        }
    }

    public func qualification(on day: MealDay, check: CouponPackCheck?) -> CouponQualification {
        if day.iso8601 > validThrough.iso8601 { return .expired }
        guard let check else { return .uncertain }
        if let count = check.packCount, count < minimumPacks { return .wrongSizeOrCount }
        if !qualifyingSize.isEmpty && check.size == .different { return .wrongSizeOrCount }
        guard check.packCount != nil, qualifyingSize.isEmpty || check.size == .matches else { return .uncertain }
        return .qualifies
    }
}

public enum CouponQualification: String, Codable, Sendable { case uncertain, wrongSizeOrCount, expired, qualifies }
public struct CouponPackCheck: Codable, Equatable, Sendable {
    public enum Size: String, Codable, Sendable, CaseIterable { case unknown, matches, different }
    public let packCount: Int?
    public let size: Size
    public init(packCount: Int?, size: Size) { self.packCount = packCount; self.size = size }
    func validate() throws {
        if let packCount, !(0...10_000).contains(packCount) { throw LedgerError.invalid("couponPackCount") }
    }
}

public struct CouponReceiptEvidence: Codable, Equatable, Sendable {
    public enum Discount: Codable, Equatable, Sendable {
        case unverified, absent
        case printed(lineID: UUID, wording: String, amount: Money)
    }
    public let receiptID: UUID
    public let itemLineID: UUID
    public let itemWording: String
    public let day: MealDay
    public let check: CouponPackCheck
    public let discount: Discount

    public init(receiptID: UUID, itemLineID: UUID, itemWording: String, day: MealDay, check: CouponPackCheck,
                discount: Discount) {
        self.receiptID = receiptID
        self.itemLineID = itemLineID
        self.itemWording = itemWording
        self.day = day
        self.check = check
        self.discount = discount
    }

    /// Accept one printed adjustment. An item price, tax, promotion for a future trip,
    /// or a combined "total savings" line cannot substantiate this individual coupon.
    private static func adjustmentMinorUnits(in wording: String, currency: Currency?) -> Int64? {
        guard wording.utf8.count <= 2048 else { return nil }
        let printed = PrintedCurrencyEvidence(wording)
        guard printed != .conflicting, currency.map(printed.permits) != false else { return nil }
        let text = wording.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard text.contains(#/\b(?:coupon|cupon|cpn|mfrcpn|discount|descuento|descto|ahorro|savings|markdown)\b/#),
              !text.contains(#/[€£¥%]|\b(?:tax|impuesto|iva|total|subtotal|refund|return|devolucion|cambio|eligible|eligibility|valid|expires|next|proxima|proximo|valido|vence|minimum|minimo)\b/#)
        else { return nil }
        let numbers = text.split { !$0.isNumber && $0 != "." && $0 != "," }
        let amounts = numbers.compactMap { number -> Int64? in
            let decimal = number.replacingOccurrences(of: ",", with: ".")
            let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 2 else { return nil }
            return Int64(parts.joined())
        }
        guard amounts.count == 1, let amount = amounts.first,
              (1...1_000_000_000).contains(amount) else { return nil }
        return amount
    }

    public static func isDiscountLine(_ wording: String, currency: Currency? = nil) -> Bool {
        adjustmentMinorUnits(in: wording, currency: currency) != nil
    }

    public static func shows(amount: Money, in wording: String) -> Bool {
        adjustmentMinorUnits(in: wording, currency: amount.currency) == amount.minorUnits
    }

    /// Every printed adjustment can fund a reviewed saving only once across the private workspace.
    var discountLine: UUID? {
        if case .printed(let id, _, _) = discount { return id }
        return nil
    }

    public var savings: Money? {
        if case .printed(let id, let wording, let amount) = discount,
           id != itemLineID, Self.shows(amount: amount, in: wording) { return amount }
        return nil
    }

    func validate() throws {
        try day.validate()
        try check.validate()
        try ledgerText(itemWording, nonempty: true, maximum: 2048)
        if case .printed(_, let wording, let amount) = discount {
            try ledgerText(wording, nonempty: true, maximum: 2048)
            guard (1...1_000_000_000).contains(amount.minorUnits) else { throw LedgerError.invalid("couponDiscount") }
        }
    }
}

public struct PinnedShopCoupon: Codable, Equatable, Sendable {
    public let terms: ShopCouponTerms
    public let clipped: Bool
    public let pickCheck: CouponPackCheck?
    public let checkedAt: Date?
    public internal(set) var receipt: CouponReceiptEvidence?
    public var missingQualifyingDiscount: Bool {
        guard clipped, let receipt, receipt.discount == .absent else { return false }
        return terms.qualification(on: receipt.day, check: receipt.check) == .qualifies
    }

    func validate(currency: Currency) throws {
        if case .printed(_, _, let amount) = receipt?.discount, amount.currency != currency { throw LedgerError.invalid("couponCurrency") }
        try terms.validate()
        try pickCheck?.validate()
        try receipt?.validate()
        guard (pickCheck == nil) == (checkedAt == nil),
              checkedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw LedgerError.invalid("couponCheck") }
    }
}

extension ShoppingLedger {
    public mutating func pinCoupon(lineID: UUID, expectedRevision: UUID, terms: ShopCouponTerms?,
                                   clipped: Bool, pickCheck: CouponPackCheck? = nil) throws {
        let currency = basis.currency
        try updateBudgetLine(lineID, revision: expectedRevision, operation: "pinnedCoupon") { line in
            guard line.pinnedCoupon?.receipt == nil else { throw LedgerError.stalePreview }
            guard let terms else { line.pinnedCoupon = nil; return }
            let pin = PinnedShopCoupon(terms: terms, clipped: clipped, pickCheck: pickCheck,
                checkedAt: pickCheck == nil ? nil : line.inStorePickedAt, receipt: nil)
            try pin.validate(currency: currency)
            line.pinnedCoupon = pin
        }
    }

    public mutating func clearCouponReceipt(lineID: UUID, expectedRevision: UUID) throws {
        try updateBudgetLine(lineID, revision: expectedRevision, operation: "clearCouponReceipt") { line in
            guard var coupon = line.pinnedCoupon, coupon.receipt != nil else { throw LedgerError.stalePreview }
            coupon.receipt = nil
            line.pinnedCoupon = coupon
        }
    }

    public mutating func reviewCouponReceipt(lineID: UUID, expectedRevision: UUID, evidence: CouponReceiptEvidence) throws {
        try evidence.validate()
        if case .printed(let printedID, _, _) = evidence.discount {
            guard evidence.savings?.currency == basis.currency else { throw LedgerError.invalid("couponDiscount") }
            guard !lines.contains(where: { line in
                guard line.id != lineID, let other = line.pinnedCoupon?.receipt, other.receiptID == evidence.receiptID,
                      case .printed(let used, _, _) = other.discount else { return false }
                return used == printedID
            }) else { throw LedgerError.invalid("couponDiscountAlreadyReviewed") }
        }
        try updateBudgetLine(lineID, revision: expectedRevision, operation: "couponReceipt") { line in
            guard var pin = line.pinnedCoupon,
                  pin.receipt == nil || pin.receipt?.receiptID == evidence.receiptID else { throw LedgerError.stalePreview }
            pin.receipt = evidence
            line.pinnedCoupon = pin
        }
    }
}

extension LedgerWorkspace {
    func validateCouponDiscounts() throws {
        var used: [UUID: Set<UUID>] = [:]
        for shop in shops {
            for line in shop.lines {
                guard let evidence = line.pinnedCoupon?.receipt, let discount = evidence.discountLine else { continue }
                guard used[evidence.receiptID, default: []].insert(discount).inserted else {
                    throw LedgerError.invalid("couponDiscountAlreadyReviewed")
                }
            }
        }
    }
}
