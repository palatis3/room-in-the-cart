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
    }
    public let currency: String; public let scope: String; public let complete: Bool; public let capMinor: Int?
    public let capScope: String; public let fee: Fee; public let taxesMinor: Int?
    public let depositsMinor: Int?; public let discountsMinor: Int?; public let observedAt: String; public let expiresAt: String
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
