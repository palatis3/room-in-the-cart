import Foundation
import XCTest
@testable import HouseholdClient

enum TrackingFlowFixture {
    static let null = NSNull()
    static let checkout: [String: Any] = ["currency": "USD", "totalMinor": NSNull(), "overCapMinor": NSNull(), "headroomMinor": NSNull(), "status": "unresolved", "scope": "wholeCheckout", "missing": ["remaining_original_items", "line_price", "fee", "tax", "deposit", "discount"], "lowerBoundMinor": 0, "upperBoundMinor": NSNull(), "wholeCheckoutWithinCap": false]
    static func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
    static func quantity(_ n: Int) -> [String: Any] {
        ["amount": ["numerator": String(n), "denominator": "1"], "unit": "count", "originalLiteral": "\(n) wraps", "confirmedConversion": null]
    }
    static func line(_ n: Int, _ name: String, trashed: Bool = false) -> [String: Any] {
        ["id": id(n), "name": name, "unit": "count", "originalOrder": n, "trashedAt": trashed ? "2026-11-10T12:00:00Z" : null]
    }
    static func basket(_ n: Int, _ name: String) -> [String: Any] {
        ["id": id(n), "name": name, "packs": 1, "priceMinor": null, "feeEligible": true]
    }
    static func fixture() -> [String: Any] {
        let source: [String: Any] = ["kind": "reservation", "reservationId": id(42), "purpose": "Protected lunch", "originOccurrenceId": id(40), "ingredientId": id(43), "groupId": null, "bindingId": null]
        let restrictions: [[String: Any]] = [["occurrenceId": id(40), "ingredientId": id(43), "label": "Keep family's original wording", "resolution": ["kind": "unresolved"]]]
        let fact: [String: Any] = ["id": id(22), "revision": 7, "source": source, "sourceLabel": "Protected lunch", "originalText": "Keep lunch wraps", "originalQuantityText": null, "quantity": null, "sourceExclusions": restrictions, "requiredLineId": id(11)]
        let transfer: [String: Any] = ["id": id(22), "lineId": id(11), "source": source, "productKey": null, "productName": "Wraps", "originalText": "Keep lunch wraps", "quantity": null, "sourceExclusions": restrictions, "exclusions": [], "contains": [], "removedAt": null]
        let manual: [String: Any] = ["id": id(20), "lineId": id(10), "source": ["kind": "manual"], "productKey": null, "productName": "Apples", "originalText": "4 apples", "quantity": quantity(4), "exclusions": [], "contains": [], "removedAt": null]
        let graph: [String: Any] = ["schemaVersion": 1, "conversionTableVersion": "us-customary-metric-v1", "householdId": id(1), "shopId": id(2), "revision": 3,
            "lines": [line(10, "Apples"), line(11, "Wraps", trashed: true)], "contributions": [manual], "edges": [], "usedIds": [id(10), id(11), id(20), id(22)]]
        let state: [String: Any] = ["schemaVersion": 2, "authorityEpoch": 3, "privacyRevision": 5, "quoteDigest": String(repeating: "a", count: 64), "graph": graph,
            "basket": [basket(10, "Apples"), basket(11, "Wraps")], "catalog": [fact], "bindings": [], "unbound": [["factId": id(22), "transferred": transfer]], "legacyLineIds": [id(11)],
            "packReviews": [["lineId": id(10), "usablePerPack": quantity(4), "acceptUnresolved": false]]]
        let coverage: [String: Any] = ["status": "partial", "trackedSubtotals": [["lineId": id(10), "unit": "count", "quantity": ["numerator": "4", "denominator": "1"], "activeContributionIds": [id(20)]]],
            "completeFoodCoverage": false, "unboundFactIds": [id(22)], "untrackedBasketIds": [id(11)], "protectedUnboundFactIds": [id(22)], "allocatableUnboundFactIds": []]
        return ["schemaVersion": 2, "shopId": id(2), "shopRevision": 8, "authorityEpoch": 3, "status": "enabled", "state": state, "projection": null,
            "basisDigest": String(repeating: "b", count: 64), "checkout": checkout, "coverage": coverage, "freezeReview": ["previewId": id(60), "previewDigest": String(repeating: "c", count: 64), "trackingVersion": 2]]
    }
    static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func page(_ object: Any) throws -> SharedTrackingPage { try SharedTrackingWire.page(from: bytes(object)) }
    static func edit(_ object: Any, _ path: String, _ value: Any?) -> Any {
        func replace(_ object: Any, _ parts: ArraySlice<String>) -> Any {
            guard let key = parts.first else { return value ?? NSNull() }
            if var array = object as? [Any], let index = Int(key) {
                if parts.count == 1 && value == nil { array.remove(at: index) }
                else { array[index] = replace(array[index], parts.dropFirst()) }
                return array
            }
            var dict = object as! [String: Any]
            if parts.count == 1 { dict[key] = value }
            else { dict[key] = replace(dict[key]!, parts.dropFirst()) }
            return dict
        }
        return replace(object, path.split(separator: ".").map(String.init)[...])
    }
    static func rejects(_ path: String, _ value: Any?, fixture object: Any? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try page(edit(object ?? fixture(), path, value)), "Accepted mutation at \(path)", file: file, line: line)
    }
    static func boundFixture(known: Bool) -> Any {
        var object: Any = fixture()
        let state = fixture()["state"] as! [String: Any]
        let transfer = (state["unbound"] as! [[String: Any]])[0]["transferred"] as! [String: Any]
        object = edit(object, "state.graph.contributions", ((state["graph"] as! [String: Any])["contributions"] as! [Any]) + [transfer])
        object = edit(object, "state.graph.lines.1.trashedAt", null)
        object = edit(object, "state.bindings", [["factId": id(22), "contributionId": id(22)]])
        object = edit(object, "state.unbound", [])
        object = edit(object, "state.legacyLineIds", [])
        object = edit(object, "state.packReviews", (state["packReviews"] as! [Any]) + [["lineId": id(11), "usablePerPack": null, "acceptUnresolved": true]])
        let totals = (fixture()["coverage"] as! [String: Any])["trackedSubtotals"] as! [Any]
        object = edit(object, "coverage.trackedSubtotals", totals + [["lineId": id(11), "unit": "count", "quantity": known ? ["numerator": "2", "denominator": "1"] : null, "activeContributionIds": [id(22)]]])
        for key in ["unboundFactIds", "untrackedBasketIds", "protectedUnboundFactIds"] { object = edit(object, "coverage.\(key)", []) }
        object = edit(object, "coverage.status", known ? "tracked" : "unknown")
        if known {
            object = edit(object, "state.catalog.0.quantity", quantity(2))
            object = edit(object, "state.graph.contributions.1.quantity", quantity(2))
        }
        return object
    }
    static func projectionFixture() -> Any {
        var state = fixture()["state"] as! [String: Any]
        state.removeValue(forKey: "packReviews"); state["privacyRevision"] = 6
        var object: Any = fixture()
        object = edit(object, "status", "reviewRequired")
        for key in ["state", "coverage", "freezeReview"] { object = edit(object, key, null) }
        return edit(object, "projection", ["schemaVersion": 1, "status": "reviewRequired", "invalidatedStateDigest": String(repeating: "d", count: 64), "previousPrivacyRevision": 5, "state": state])
    }
}
