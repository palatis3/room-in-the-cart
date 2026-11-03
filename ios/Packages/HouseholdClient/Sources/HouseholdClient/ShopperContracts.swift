import Foundation

/// Private shopper projections are separate from contributor request responses.
public struct ShopperBasketLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { lineId }
    public let lineId: String; public let originalItem: String; public let packs: Int
    public let unitPriceMinor: Int?; public let feeEligible: Bool
    public init(lineId: UUID = UUID(), originalItem: String, packs: Int, unitPriceMinor: Int?, feeEligible: Bool) {
        self.lineId = lineId.uuidString.lowercased(); self.originalItem = originalItem; self.packs = packs
        self.unitPriceMinor = unitPriceMinor; self.feeEligible = feeEligible
    }
    private enum CodingKeys: String, CodingKey { case lineId, originalItem, packs, unitPriceMinor, feeEligible }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(lineId, forKey: .lineId); try values.encode(originalItem, forKey: .originalItem)
        try values.encode(packs, forKey: .packs); try values.encode(unitPriceMinor, forKey: .unitPriceMinor)
        try values.encode(feeEligible, forKey: .feeEligible)
    }
}
public struct ShopperQuote: Codable, Equatable, Sendable {
    public struct Fee: Codable, Equatable, Sendable {
        public let kind: String; public let amountMinor: Int?; public let thresholdMinor: Int?
        public let belowMinor: Int?; public let aboveMinor: Int?
        public static func fixed(_ amount: Int?) -> Self { .init(kind: "fixed", amountMinor: amount, thresholdMinor: nil, belowMinor: nil, aboveMinor: nil) }
        public static func threshold(_ threshold: Int, below: Int?, above: Int?) -> Self { .init(kind: "threshold", amountMinor: nil, thresholdMinor: threshold, belowMinor: below, aboveMinor: above) }
        private enum CodingKeys: String, CodingKey { case kind, amountMinor, thresholdMinor, belowMinor, aboveMinor }
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(kind, forKey: .kind)
            switch kind {
            case "fixed": try values.encode(amountMinor, forKey: .amountMinor)
            case "threshold":
                guard let thresholdMinor else { throw ClientError.configuration }
                try values.encode(thresholdMinor, forKey: .thresholdMinor)
                try values.encode(belowMinor, forKey: .belowMinor); try values.encode(aboveMinor, forKey: .aboveMinor)
            default: throw ClientError.configuration
            }
        }
    }
    public let currency: String; public let scope: String; public let complete: Bool; public let capMinor: Int?
    public let capScope: String; public let fee: Fee; public let taxesMinor: Int?
    public let depositsMinor: Int?; public let discountsMinor: Int?; public let observedAt: String; public let expiresAt: String
    public init(scope: String, complete: Bool, capMinor: Int?, capScope: String, fee: Fee,
                taxesMinor: Int?, depositsMinor: Int?, discountsMinor: Int?, observedAt: Date, expiresAt: Date) throws {
        let amounts = [capMinor, fee.amountMinor, fee.thresholdMinor, fee.belowMinor, fee.aboveMinor, taxesMinor, depositsMinor, discountsMinor].compactMap { $0 }
        guard ["wholeCheckout", "item", "dinner"].contains(scope), ["wholeCheckout", "item", "dinner", "unknown"].contains(capScope),
              ["fixed", "threshold"].contains(fee.kind), amounts.allSatisfy({ (0...1_000_000_000).contains($0) }),
              observedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite, expiresAt > observedAt else { throw ClientError.configuration }
        currency = "USD"; self.scope = scope; self.complete = complete; self.capMinor = capMinor; self.capScope = capScope; self.fee = fee
        self.taxesMinor = taxesMinor; self.depositsMinor = depositsMinor; self.discountsMinor = discountsMinor
        let formatter = ISO8601DateFormatter(); self.observedAt = formatter.string(from: observedAt); self.expiresAt = formatter.string(from: expiresAt)
    }
    private enum CodingKeys: String, CodingKey { case currency, scope, complete, capMinor, capScope, fee, taxesMinor, depositsMinor, discountsMinor, observedAt, expiresAt }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(currency, forKey: .currency); try values.encode(scope, forKey: .scope); try values.encode(complete, forKey: .complete)
        try values.encode(capMinor, forKey: .capMinor); try values.encode(capScope, forKey: .capScope); try values.encode(fee, forKey: .fee)
        try values.encode(taxesMinor, forKey: .taxesMinor); try values.encode(depositsMinor, forKey: .depositsMinor)
        try values.encode(discountsMinor, forKey: .discountsMinor); try values.encode(observedAt, forKey: .observedAt); try values.encode(expiresAt, forKey: .expiresAt)
    }
}
public struct ShopperShopCandidate: Codable, Equatable, Sendable {
    public let quote: ShopperQuote; public let lines: [ShopperBasketLine]
    public init(quote: ShopperQuote, lines: [ShopperBasketLine]) throws {
        guard lines.count <= 200, Set(lines.map(\.lineId)).count == lines.count,
              lines.allSatisfy({ UUID(uuidString: $0.lineId) != nil && !$0.originalItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.originalItem.count <= 240 && (1...10_000).contains($0.packs) && ($0.unitPriceMinor.map { (0...1_000_000_000).contains($0) } ?? true) }) else { throw ClientError.configuration }
        self.quote = quote; self.lines = lines
    }
    public func commandBody() throws -> [String: JSONValue] { try JSONDecoder().decode([String: JSONValue].self, from: encoded(self)) }
}
public struct ShopperShop: Codable, Equatable, Sendable {
    public let shopId: String; public let shopRevision: Int; public let authorityEpoch: Int; public let phase: String
    public let quote: ShopperQuote; public let lines: [ShopperBasketLine]; public let frozenRevision: Int?; public let placedRevision: Int?
}
public enum ShopperDecision: Equatable, Sendable, Encodable {
    case add(line: ShopperBasketLine, promote: Bool)
    case link(lineID: String, promote: Bool)
    case deferRequest, dismiss, handled
    public var choice: String {
        switch self { case .add: return "add"; case .link: return "link"; case .deferRequest: return "defer"
        case .dismiss: return "dismiss"; case .handled: return "handled" }
    }
    private enum CodingKeys: String, CodingKey { case choice, line, lineId, promote }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(choice, forKey: .choice)
        switch self {
        case .add(let line, let promote): try values.encode(line, forKey: .line); try values.encode(promote, forKey: .promote)
        case .link(let id, let promote): try values.encode(id, forKey: .lineId); try values.encode(promote, forKey: .promote)
        default: break
        }
    }
}
public struct ShopperBudget: Codable, Equatable, Sendable {
    public let currency: String; public let totalMinor: Int?; public let overCapMinor: Int?; public let headroomMinor: Int?
    public let status: String; public let scope: String; public let missing: [String]
    public let lowerBoundMinor: Int; public let upperBoundMinor: Int?; public let wholeCheckoutWithinCap: Bool
}
public struct ShopperPreview: Codable, Equatable, Sendable {
    public let previewId: String; public let expiresAt: String; public let shopRevision: Int; public let authorityEpoch: Int
    public let requestRevision: Int; public let choice: String; public let before: ShopperBudget; public let after: ShopperBudget
    public let changeMinor: Int?; public let requiresOverageAcceptance: Bool; public let requiresUnknownAcceptance: Bool
    public var base: CommandBase { .init(shopRevision: shopRevision, authorityEpoch: authorityEpoch, requestRevision: requestRevision) }
}
public struct ShopperReceipt: Codable, Equatable, Sendable {
    public let operationId: String; public let kind: String; public let shopId: String; public let shopRevision: Int
    public let authorityEpoch: Int; public let disposition: String; public let requestId: String?; public let requestRevision: Int?
}

public struct ShopperFinancialEntry: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case postedCharge, postedTopUp, pendingCredit, postedCredit, includedCredit, paymentHold, holdRelease
    }
    public let id: UUID
    public let kind: Kind
    public let amountMinor: Int
    public let currency: String
    public let occurredAt: String
    public let sourceText: String
}

struct ShopperFinancialPage: Decodable, Sendable {
    struct Version: Decodable, Equatable, Sendable {
        let shopRevision: Int
        let authorityEpoch: Int
        let financialRevision: Int
    }
    let shopId: UUID
    let sourceVersion: Version
    let evidenceSource: String
    let entries: [ShopperFinancialEntry]
    let nextCursor: UUID?
}
