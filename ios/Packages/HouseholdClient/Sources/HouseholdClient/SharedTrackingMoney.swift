import Foundation

/// Authoritative checkout results. This client validates the shape and preserves
/// the server's bounds and scope; it never recalculates checkout or food totals.
public struct SharedTrackingMoneyDisclosure: Decodable, Equatable, Sendable {
    public let before: ShopperBudget
    public let after: ShopperBudget
    private enum K: String, CodingKey { case before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["before", "after"])
        let c = try decoder.container(keyedBy: K.self)
        before = try trackingDecode(ShopperBudget.self, from: c.superDecoder(forKey: .before), shape: requestUndoBudgetShape)
        after = try trackingDecode(ShopperBudget.self, from: c.superDecoder(forKey: .after), shape: requestUndoBudgetShape)
        try requestUndoBudget(before); try requestUndoBudget(after)
    }
}
public struct SharedTrackingMoneyAcknowledgments: Codable, Equatable, Sendable {
    public let acceptOverage: Bool
    public let acceptUnknown: Bool
    public init(acceptOverage: Bool, acceptUnknown: Bool) {
        self.acceptOverage = acceptOverage; self.acceptUnknown = acceptUnknown
    }
    private enum K: String, CodingKey { case acceptOverage, acceptUnknown }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["acceptOverage", "acceptUnknown"])
        let c = try decoder.container(keyedBy: K.self)
        acceptOverage = try c.decode(Bool.self, forKey: .acceptOverage)
        acceptUnknown = try c.decode(Bool.self, forKey: .acceptUnknown)
    }
    public func validate(money: ShopperBudget) throws {
        try requestUndoBudget(money)
        try demandRequire(money.status != "overCap" || acceptOverage)
        try demandRequire((!["unresolved", "scopeMismatch"].contains(money.status) && money.scope == "wholeCheckout") || acceptUnknown)
    }
}
