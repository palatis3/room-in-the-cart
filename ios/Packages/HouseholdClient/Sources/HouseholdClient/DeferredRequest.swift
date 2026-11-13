import Foundation

public struct DeferredRequest: Decodable, Equatable, Sendable, Identifiable {
    public let requestId, sourceShopId: UUID
    public let sourceAuthorityEpoch, requestRevision: Int
    public let originalItem, authorAlias, authoredAt, receivedAt: String
    public let ownQuantity: String?
    public var id: UUID { requestId }
}

public struct DeferredRequestsPage: Decodable, Sendable {
    public let shopId: UUID
    public let shopRevision, authorityEpoch: Int
    public let requests: [DeferredRequest]
    public let nextCursor: UUID?

    func validate(destination: UUID) throws {
        guard shopId == destination, shopRevision > 0, authorityEpoch > 0, requests.count <= 50,
              Set(requests.map(\.id)).count == requests.count,
              requests.allSatisfy({ $0.sourceShopId != destination && $0.requestRevision > 0 &&
                  $0.sourceAuthorityEpoch > 0 && !$0.originalItem.isEmpty && !$0.authorAlias.isEmpty }),
              nextCursor == nil || nextCursor == requests.last?.id else { throw ClientError.invalidResponse }
    }
}
