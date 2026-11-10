import Foundation
@testable import HouseholdClient

enum RequestUndoFlowFixture {
    typealias F = TrackingFlowReviewFixture
    static func id(_ n: Int) -> String { F.id(n) }
    static func bytes(_ value: Any) throws -> Data { try F.bytes(value) }
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T { try F.decode(value, as: type) }
    static func budget(_ total: Int) -> [String: Any] {
        ["currency": "USD", "totalMinor": total, "overCapMinor": 0, "headroomMinor": 1000-total, "status": "withinCap", "scope": "wholeCheckout",
         "missing": [], "lowerBoundMinor": total, "upperBoundMinor": total, "wholeCheckoutWithinCap": true]
    }
    static func quote() -> [String: Any] {
        ["currency": "USD", "scope": "wholeCheckout", "complete": true, "capMinor": 1000, "capScope": "wholeCheckout",
         "fee": ["kind": "fixed", "amountMinor": 0], "taxesMinor": 0, "depositsMinor": 0, "discountsMinor": 0,
         "observedAt": "2026-11-10T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"]
    }
    static func lines() -> [[String: Any]] {
        [["lineId": id(10), "originalItem": "Apples", "packs": 1, "unitPriceMinor": 100, "feeEligible": true],
         ["lineId": id(11), "originalItem": "Cereal", "packs": 1, "unitPriceMinor": 300, "feeEligible": true]]
    }
    static func state(_ revision: Int, _ status: String) -> [String: Any] { ["revision": revision, "status": status, "route": "current"] }
    static func requestFact() -> [String: Any] {
        ["id": id(31), "revision": 3, "source": ["kind": "request", "requestId": id(20), "appliedRequestRevision": 3], "sourceLabel": "Requested item", "originalText": "Cereal", "originalQuantityText": "one large box", "quantity": NSNull(), "sourceExclusions": [], "requiredLineId": id(11)]
    }
    static func candidate(_ variant: String = "legacy") -> [String: Any] {
        let link: [String: Any] = ["requestId": id(20), "shopId": id(2), "lineId": id(11), "reviewedRevision": 3, "operationId": id(90)]
        var value: [String: Any] = ["schemaVersion": 1, "kind": "requestAcceptanceUndo", "shopId": id(2), "targetOperationId": id(90), "effectDigest": String(repeating: "e", count: 64),
            "base": ["shopRevision": 8, "authorityEpoch": 3, "requestRevision": 4, "food": ["kind": "legacy", "catalogDigest": String(repeating: "a", count: 64)]],
            "action": ["kind": "request.undoAcceptance", "body": ["targetOperationId": id(90), "requestId": id(20), "baseRequestRevision": 4, "lines": [lines()[0]], "quote": quote()]],
            "requestUndo": ["requestId": id(20), "choice": "add", "originalItem": "Cereal", "originalQuantityText": "one large box", "targetBefore": state(3, "pending"), "targetAfter": state(4, "added"),
                "current": state(4, "added"), "restored": state(5, "pending"), "beforeLink": link, "afterLink": NSNull(), "carry": []],
            "scope": ["requestsChanged": true, "mealsChanged": false, "quoteChanged": false, "touchedLines": [["lineId": id(11), "fields": ["membership"]]], "graphRows": 0],
            "foodBefore": ["kind": "legacy", "catalog": [requestFact()]], "foodAfter": ["kind": "legacy", "catalog": []],
            "beforeCheckout": budget(400), "afterCheckout": budget(100), "packReviewLineIds": [id(10)], "storeBasis": NSNull()]
        if variant == "tracked" || variant == "partition" {
            let rows: [[String: Any]] = [
                ["id": id(30), "lineId": id(10), "source": ["kind": "manual"], "productKey": "apples", "productName": "Apples", "originalText": "4 apples", "quantity": F.quantity(4), "exclusions": [], "contains": [], "removedAt": NSNull()],
                ["id": id(31), "lineId": id(11), "source": ["kind": "request", "requestId": id(20), "appliedRequestRevision": 3], "productKey": "cereal", "productName": "Cereal", "originalText": "Cereal", "quantity": NSNull(), "exclusions": [], "contains": [], "removedAt": NSNull()]]
            let before: [String: Any] = ["schemaVersion": 1, "conversionTableVersion": "us-customary-metric-v1", "householdId": id(1), "shopId": id(2), "revision": 2,
                "lines": [F.line(10, "Apples"), F.line(11, "Cereal")], "contributions": rows, "edges": [], "usedIds": [id(10), id(11), id(30), id(31)]]
            var after: Any = F.edit(before, "revision", 3)
            after = F.edit(after, "lines.1.trashedAt", "2026-11-10T12:00:00Z"); after = F.edit(after, "contributions.1.removedAt", "2026-11-10T12:00:00Z")
            value["base"] = ["shopRevision": 8, "authorityEpoch": 3, "requestRevision": 4, "food": ["kind": "tracked", "graphRevision": 2, "graphDigest": String(repeating: "a", count: 64)]]
            value["foodBefore"] = ["kind": "tracked", "graph": before]; value["foodAfter"] = ["kind": "tracked", "graph": after]
            value = F.edit(value, "scope.graphRows", 2) as! [String: Any]
            if variant == "partition" {
                func partition(_ graph: Any, after: Bool) -> [String: Any] {
                    let basket = (after ? [lines()[0]] : lines()).map { line in ["id": line["lineId"]!, "name": line["originalItem"]!, "packs": line["packs"]!, "priceMinor": line["unitPriceMinor"]!, "feeEligible": line["feeEligible"]!] }
                    let packs: [[String: Any]] = [["lineId": id(10), "usablePerPack": F.quantity(4), "acceptUnresolved": false]] + (after ? [] : [["lineId": id(11), "usablePerPack": NSNull(), "acceptUnresolved": true]])
                    return ["schemaVersion": 2, "authorityEpoch": 3, "privacyRevision": 5, "quoteDigest": String(repeating: "a", count: 64), "graph": graph,
                        "basket": basket, "catalog": after ? [] : [requestFact()], "bindings": after ? [] : [["factId": id(31), "contributionId": id(31)]],
                        "unbound": [], "legacyLineIds": [], "packReviews": packs]
                }
                value["base"] = ["shopRevision": 8, "authorityEpoch": 3, "requestRevision": 4, "food": ["kind": "partition", "graphRevision": 2, "graphDigest": String(repeating: "a", count: 64), "stateDigest": String(repeating: "b", count: 64), "privacyRevision": 5]]
                value["foodBefore"] = ["kind": "partition", "state": partition(before, after: false)]
                value["foodAfter"] = ["kind": "partition", "state": partition(after, after: true)]
            }

        }
        return value
    }
    static func shop() throws -> ShopperShop {
        try decode(["shopId": id(2), "shopRevision": 8, "authorityEpoch": 3, "phase": "draft", "lines": lines(), "quote": quote(), "meals": [], "frozenRevision": NSNull(), "placedRevision": NSNull()])
    }
    static func packs() throws -> [SharedDemandPackReview] { [.init(lineId: .init(UUID(uuidString: id(10))!), usablePerPack: try decode(F.quantity(4)), acceptUnresolved: false)] }
    static func preview(_ candidate: [String: Any], at: String = "2026-11-10T12:01:00Z") throws -> [String: Any] {
        var candidate = candidate
        let decoded: SharedRequestUndoCandidate = try decode(candidate)
        var receipt: [String: Any] = ["kind": "legacy", "receipt": NSNull()]
        if let before = decoded.foodBefore.graph, decoded.foodAfter.graph != nil {
            let path: String
            if case .partition = decoded.foodAfter {
                path = "foodAfter.state.graph"
                candidate = F.edit(candidate, "foodAfter.state.packReviews", try JSONSerialization.jsonObject(with: encoded(packs()))) as! [String: Any]
            } else { path = "foodAfter.graph" }
            candidate = F.edit(candidate, "\(path).lines.1.trashedAt", at) as! [String: Any]
            candidate = F.edit(candidate, "\(path).contributions.1.removedAt", at) as! [String: Any]
            let changed: SharedRequestUndoCandidate = try decode(candidate), after = changed.foodAfter.graph!
            let graphReceipt = SharedDemandReceipt(schemaVersion: 1, operationId: .init(UUID(uuidString: id(95))!), householdId: before.householdId, shopId: before.shopId,
                baseRevision: before.revision, resultRevision: after.revision,
                lines: demandDiff(before.lines, after.lines, { $0.id }), contributions: demandDiff(before.contributions, after.contributions, { $0.id }), edges: [])
            receipt = ["kind": "tracked", "receipt": try JSONSerialization.jsonObject(with: encoded(graphReceipt))]
        }
        return ["schemaVersion": 1, "kind": "requestAcceptanceUndoPreview", "candidate": candidate, "previewId": id(96), "previewDigest": String(repeating: "f", count: 64),
            "expiresAt": F.expiry, "operationId": id(95), "packs": try JSONSerialization.jsonObject(with: encoded(packs())), "foodReceipt": receipt]
    }
    static func review(_ variant: String = "legacy") throws -> SharedRequestUndoReview {
        let candidate = candidate(variant), decoded: SharedRequestUndoCandidate = try decode(candidate)
        return try .init(context: F.context, shop: shop(), candidate: decoded,
            input: .init(candidate: decoded, packs: packs(), acceptOverage: false, acceptUnknown: false), response: decode(preview(candidate)))
    }
}
