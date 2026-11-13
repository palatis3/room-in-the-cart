#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation

final class RequestPurchaseFixture {
    static let request = "aaaaaaaa-1111-4111-8111-111111111111"
    private let line = "66666666-6666-4666-8666-666666666666"
    private var revision = 2
    private var outcome: String?
    private var saved: [String: (Data, [String: Any])] = [:]

    func page(shop: String) -> [String: Any] {
        var row: [String: Any] = ["requestId": Self.request, "shopId": shop, "revision": revision,
            "originalItem": "Wraps for lunches", "ownQuantity": "four wraps", "authorAlias": "Sam",
            "authoredAt": "2026-11-07T09:00:00Z", "receivedAt": "2026-11-07T09:01:00Z",
            "route": "current", "status": "added", "ownActionAllowed": false, "linkedLineId": line]
        row["purchaseOutcome"] = outcome
        var unlinked = row
        unlinked["requestId"] = "bbbbbbbb-1111-4111-8111-111111111111"
        unlinked["authorAlias"] = "Jo"
        unlinked["linkedLineId"] = nil
        unlinked["purchaseOutcome"] = nil
        return ["requests": [row, unlinked], "nextCursor": NSNull()]
    }

    func record(shop: String, command: [String: Any], bytes: Data) throws -> [String: Any] {
        guard let key = command["clientKey"] as? String, command["shopId"] as? String == shop else {
            throw SharedDeliveryFixtureRecords.CookFailure.invalid
        }
        if let (original, receipt) = saved[key] {
            guard original == bytes else { throw SharedDeliveryFixtureRecords.CookFailure.replayConflict }
            return receipt
        }
        guard let base = command["base"] as? [String: Int],
              base == ["shopRevision": 2, "authorityEpoch": 1, "requestRevision": revision],
              let body = command["body"] as? [String: Any], body["requestId"] as? String == Self.request,
              body["lineId"] as? String == line, body["placedRevision"] as? Int == 1,
              let choice = body["outcome"] as? String, ["bought", "notBought", "unknown"].contains(choice)
        else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
        revision += 1
        outcome = choice == "unknown" ? nil : choice
        let receipt: [String: Any] = ["requestId": Self.request, "requestRevision": revision, "shopId": shop,
            "shopRevision": 2, "authorityEpoch": 1, "purchaseOutcome": choice, "disposition": "recorded",
            "kind": "request.confirmPurchase", "operationId": UUID().uuidString.lowercased()]
        saved[key] = (bytes, receipt)
        return receipt
    }
}
#endif
