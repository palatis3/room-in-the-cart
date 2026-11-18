#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation

final class RequestPurchaseFixture {
    static let request = "aaaaaaaa-1111-4111-8111-111111111111"
    private static let secondRequest = "bbbbbbbb-1111-4111-8111-111111111111"
    let compare = ProcessInfo.processInfo.arguments.contains("--compare-placed-purchase")
    private let line = "66666666-6666-4666-8666-666666666666"
    private var revision = 2
    private var outcome: String?
    private var secondRevision = 1
    private var matchedOperation: String?
    private var reviewed: [String: String] = [:]

    init() {
        if compare {
            outcome = ProcessInfo.processInfo.environment["PURCHASE_FIXTURE_OUTCOME"]
            if outcome == "unknown" { outcome = nil }
        }
    }
    private var saved: [String: (Data, [String: Any])] = [:]

    func page(shop: String) -> [String: Any] {
        var row: [String: Any] = ["requestId": Self.request, "shopId": shop, "revision": revision,
            "originalItem": "Wraps for lunches", "ownQuantity": "four wraps", "authorAlias": "Sam",
            "authoredAt": "2026-11-07T09:00:00Z", "receivedAt": "2026-11-07T09:01:00Z",
            "route": "current", "status": "added", "ownActionAllowed": false, "linkedLineId": line]
        row["purchaseOutcome"] = outcome
        var unlinked = row
        unlinked["requestId"] = Self.secondRequest
        unlinked["authorAlias"] = "Jo"
        unlinked["linkedLineId"] = nil
        unlinked["purchaseOutcome"] = nil
        if compare {
            unlinked["revision"] = secondRevision
            unlinked["route"] = "next"
            unlinked["ownQuantity"] = "two wraps for dinner"
            unlinked["status"] = matchedOperation == nil ? "pending" : "handled"
            unlinked["ownActionAllowed"] = matchedOperation == nil
            unlinked["sameItemOperationId"] = matchedOperation
        }
        return ["requests": [row, unlinked], "nextCursor": NSNull()]
    }

    func preview(_ input: [String: Any]) throws -> [String: Any] {
        guard compare, input["requestId"] as? String == Self.secondRequest,
              input["base"] as? [String: Int] == ["shopRevision": 2, "authorityEpoch": 1, "requestRevision": secondRevision],
              let decision = input["decision"] as? [String: Any], let choice = decision["choice"] as? String
        else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
        let previewID = UUID().uuidString.lowercased()
        let budget = ModelTrackingReadFixture.budget(500, cap: 1000)
        var reply: [String: Any] = ["previewId": previewID, "expiresAt": "2099-01-01T00:00:00Z",
            "shopRevision": 2, "authorityEpoch": 1, "requestRevision": secondRevision, "choice": choice,
            "before": budget, "after": budget, "changeMinor": 0,
            "requiresOverageAcceptance": false, "requiresUnknownAcceptance": false]
        switch choice {
        case "sameItem":
            guard outcome == "bought", matchedOperation == nil, let target = decision["target"] as? [String: Any],
                  target["kind"] as? String == "purchase", target["sourceRequestId"] as? String == Self.request,
                  target["sourceRequestRevision"] as? Int == revision, target["lineId"] as? String == line,
                  target["placedRevision"] as? Int == 1
            else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
            reply["sameItemEvidence"] = ["item": "Wraps for lunches", "quantity": "four wraps",
                "sourceLabel": "Sam", "exclusions": [], "lineName": "Ordered wraps", "packs": 2] as [String: Any]
        case "undoSameItem":
            guard let matchedOperation, decision["operationId"] as? String == matchedOperation
            else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
        default: throw SharedDeliveryFixtureRecords.CookFailure.invalid
        }
        reviewed[previewID] = choice
        return reply
    }

    func record(shop: String, command: [String: Any], bytes: Data) throws -> [String: Any] {
        guard let key = command["clientKey"] as? String, command["shopId"] as? String == shop else {
            throw SharedDeliveryFixtureRecords.CookFailure.invalid
        }
        if let (original, receipt) = saved[key] {
            guard original == bytes else { throw SharedDeliveryFixtureRecords.CookFailure.replayConflict }
            return receipt
        }
        if compare, command["kind"] as? String == "request.apply" {
            guard let body = command["body"] as? [String: Any], body["requestId"] as? String == Self.secondRequest,
                  command["base"] as? [String: Int] == ["shopRevision": 2, "authorityEpoch": 1, "requestRevision": secondRevision],
                  let preview = body["previewId"] as? String, let choice = reviewed[preview]
            else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
            reviewed.removeAll()
            let operation = UUID().uuidString.lowercased()
            matchedOperation = choice == "sameItem" ? operation : nil
            secondRevision += 1
            let receipt: [String: Any] = ["kind": "request.apply", "operationId": operation, "shopId": shop,
                "shopRevision": 2, "authorityEpoch": 1, "requestId": Self.secondRequest,
                "requestRevision": secondRevision, "disposition": matchedOperation == nil ? "pending" : "handled"]
            saved[key] = (bytes, receipt)
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
