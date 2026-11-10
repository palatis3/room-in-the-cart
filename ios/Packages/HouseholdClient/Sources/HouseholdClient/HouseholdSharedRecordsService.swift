import Foundation

extension HouseholdService {
    /// Current assigned-shopper scope only; no downgrade to the v1 graph reader.
    /// Call again before export after a session/household/shop change. The result
    /// is a private independent record, never a helper disclosure or live cache.
    public func sharedRecordSnapshot(shopID: UUID) async throws -> SharedRecordSnapshot {
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let result: SharedRecordSnapshot = try await perform("shops/\(shopID.uuidString.lowercased())/records/snapshot/v2", method: "GET", maximumResponseBytes: SharedRecordWire.maximumResponseBytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try demandRequire(result.record.origin.householdId.string == context.householdID.lowercased() && result.record.origin.shopId.uuid == shopID)
        return result
    }
}
