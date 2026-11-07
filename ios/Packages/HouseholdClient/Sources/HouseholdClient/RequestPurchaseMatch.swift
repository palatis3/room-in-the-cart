import Foundation

/// A request's service-provided link must resolve in this exact placed snapshot.
public struct RequestPurchaseMatch: Equatable, Identifiable, Sendable {
    public var id: String { request.id }
    public let request: OwnRequest
    public let line: SharedDeliveryPage.Line
    public let placedRevision: Int
    public let base: CommandBase

    public init?(request: OwnRequest, shop: ShopperShop, placed: SharedDeliveryPage) {
        guard request.status == "added", request.revision > 0, UUID(uuidString: request.id) != nil,
              request.shopId == shop.shopId, UUID(uuidString: shop.shopId) == placed.shopId,
              ["placed", "closed"].contains(shop.phase), shop.placedRevision == placed.placedRevision,
              shop.shopRevision == placed.shopRevision, shop.authorityEpoch == placed.authorityEpoch,
              let id = request.linkedLineId, let line = placed.lines.first(where: { $0.id == id }) else { return nil }
        self.request = request
        self.line = line
        placedRevision = placed.placedRevision
        base = CommandBase(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch, requestRevision: request.revision)
    }

    public func body(outcome: ConfirmedRequestPurchase?) -> [String: JSONValue] {
        ["requestId": .string(request.id), "lineId": .string(line.id.uuidString.lowercased()),
         "placedRevision": .integer(placedRevision), "outcome": .string(outcome?.rawValue ?? "unknown")]
    }
}
