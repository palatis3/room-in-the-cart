import Foundation
import XCTest
@testable import HouseholdClient

enum TrackingWriteFixture {
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

extension TrackingWriteFixture {
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(T.self, from: bytes(value)) }
    static var context: SharedDemandContext { .init(subject: "account", householdID: id(1), memberID: id(2), deviceID: "device") }
    static var expiry: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)) }
    static func quote() -> [String: Any] {
        ["currency": "USD", "scope": "wholeCheckout", "complete": false, "capMinor": 1000, "capScope": "wholeCheckout", "fee": ["kind": "fixed", "amountMinor": null], "taxesMinor": null, "depositsMinor": null, "discountsMinor": null, "observedAt": "2026-11-10T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"]
    }
    static func action(_ state: [String: Any]) -> [String: Any] {
        let lines = (state["basket"] as! [[String: Any]]).map { ["lineId": $0["id"]!, "originalItem": $0["name"]!, "packs": $0["packs"]!, "unitPriceMinor": $0["priceMinor"]!, "feeEligible": $0["feeEligible"]!] }
        return ["kind": "shop.patch", "body": ["quote": quote(), "lines": lines]]
    }
    static func pickup(_ page: [String: Any]) -> [String: Any] {
        let state = page["state"] as! [String: Any], catalog = state["catalog"] as! [[String: Any]], unbound = state["unbound"] as! [[String: Any]], basket = state["basket"] as! [[String: Any]]
        let coverage = page["coverage"] as! [String: Any], totals = coverage["trackedSubtotals"] as! [[String: Any]], graph = state["graph"] as! [String: Any], rows = graph["contributions"] as! [[String: Any]], packs = state["packReviews"] as! [[String: Any]]
        let unresolved = packs.filter { pack in
            let id = pack["lineId"] as! String
            return pack["usablePerPack"] is NSNull || totals.first { $0["lineId"] as? String == id }?["quantity"] is NSNull || rows.contains { row in
                row["lineId"] as? String == id && row["removedAt"] is NSNull && (row["sourceExclusions"] as? [[String: Any]] ?? []).contains { ($0["resolution"] as? [String: Any])?["kind"] as? String == "unresolved" }
            }
        }.map { $0["lineId"]! }
        return ["stateDigest": String(repeating: "d", count: 64), "catalogDigest": String(repeating: "e", count: 64), "priceBasisDigest": String(repeating: "f", count: 64), "coverageStatement": "tracked_subtotals_only_no_complete_coverage_or_free_unbound_supply", "coverage": coverage,
            "unbound": unbound.map { entry in ["fact": catalog.first { $0["id"] as? String == entry["factId"] as? String }!, "transferred": entry["transferred"]!] },
            "unpricedBasketIds": basket.filter { $0["priceMinor"] is NSNull }.map { $0["id"]! }, "unresolvedPackIds": unresolved, "basket": basket, "packReviews": packs]
    }
    static func scenario(_ mode: String = "review") throws -> [String: Any] {
        var before = fixture(), after: Any = fixture(), changes: Any = null
        var requestPreview: Any = null
        switch mode {
        case "recover":
            before = projectionFixture() as! [String: Any]
            changes = ["invalidatedStateDigest": String(repeating: "d", count: 64), "survivingCatalog": (fixture()["state"] as! [String: Any])["catalog"]!, "unbound": (fixture()["state"] as! [String: Any])["unbound"]!, "freshPackReviews": (fixture()["state"] as! [String: Any])["packReviews"]!, "coverage": fixture()["coverage"]!]
            after = edit(after, "state.privacyRevision", 6)
        case "rebind":
            after = boundFixture(known: false)
            let old = ((fixture()["state"] as! [String: Any])["unbound"] as! [[String: Any]])[0]
            let row = (((after as! [String: Any])["state"] as! [String: Any])["graph"] as! [String: Any])["contributions"] as! [[String: Any]]
            changes = ["restored": [["factId": id(22), "before": old, "after": row[1]]], "allocationsRestored": [], "before": fixture()["coverage"]!, "after": (after as! [String: Any])["coverage"]!]
        case "firstAdoptionUndo":
            before = boundFixture(known: true) as! [String: Any]
            let state = before["state"] as! [String: Any], graph = state["graph"] as! [String: Any], rows = graph["contributions"] as! [[String: Any]]
            after = edit(before, "state.graph.lines.0.trashedAt", "2026-11-10T01:00:00Z")
            after = edit(after, "state.graph.lines.1.trashedAt", "2026-11-10T01:00:00Z")
            after = edit(after, "state.graph.contributions", [edit(rows[0], "removedAt", "2026-11-10T01:00:00Z")])
            after = edit(after, "state.bindings", [])
            after = edit(after, "state.unbound", [["factId": id(22), "transferred": rows[1]]])
            after = edit(after, "state.legacyLineIds", [id(10), id(11)])
            after = edit(after, "state.packReviews", [])
            after = edit(after, "coverage.trackedSubtotals", [])
            after = edit(after, "coverage.unboundFactIds", [id(22)])
            after = edit(after, "coverage.protectedUnboundFactIds", [id(22)])
            after = edit(after, "coverage.untrackedBasketIds", [id(10), id(11)])
            after = edit(after, "coverage.status", "partial")
            changes = ["targetOperationId": id(90), "reversedAssertions": ["lines": graph["lines"]!, "contributions": rows, "edges": graph["edges"]!, "packReviews": state["packReviews"]!], "basketChanges": [], "transferredFactIds": [id(22)], "retainedLaterContributionIds": [], "beforeCoverage": before["coverage"]!, "afterCoverage": (after as! [String: Any])["coverage"]!]
        case "adopt":
            var empty: Any = fixture()
            empty = edit(empty, "status", "legacy"); empty = edit(empty, "state.graph.revision", 0)
            for key in ["lines", "contributions", "edges", "usedIds"] { empty = edit(empty, "state.graph.\(key)", []) }
            for key in ["catalog", "bindings", "unbound", "packReviews"] { empty = edit(empty, "state.\(key)", []) }
            empty = edit(empty, "state.basket", [basket(10, "Apples")]); empty = edit(empty, "state.legacyLineIds", [id(10)])
            for key in ["trackedSubtotals", "unboundFactIds", "protectedUnboundFactIds"] { empty = edit(empty, "coverage.\(key)", []) }
            empty = edit(empty, "coverage.untrackedBasketIds", [id(10)]); before = empty as! [String: Any]
            for key in ["catalog", "bindings", "unbound", "legacyLineIds"] { after = edit(after, "state.\(key)", []) }
            after = edit(after, "state.graph.lines", [line(10, "Apples")]); after = edit(after, "state.graph.usedIds", [id(10), id(20)])
            after = edit(after, "state.basket", [basket(10, "Apples")])
            for key in ["unboundFactIds", "protectedUnboundFactIds", "untrackedBasketIds"] { after = edit(after, "coverage.\(key)", []) }
            after = edit(after, "coverage.status", "tracked")
        case "request":
            let state = fixture()["state"] as! [String: Any], graph = state["graph"] as! [String: Any]
            let source: [String: Any] = ["kind": "request", "requestId": id(90), "appliedRequestRevision": 6]
            let fact: [String: Any] = ["id": id(23), "revision": 6, "source": source, "sourceLabel": "Request", "originalText": "2 apples request", "originalQuantityText": "2 apples", "quantity": quantity(2), "sourceExclusions": [], "requiredLineId": id(10)]
            let row: [String: Any] = ["id": id(23), "lineId": id(10), "source": source, "productKey": null, "productName": "Apples", "originalText": "2 apples request", "quantity": quantity(2), "exclusions": [], "contains": [], "removedAt": null]
            after = edit(after, "state.graph.contributions", (graph["contributions"] as! [Any]) + [row]); after = edit(after, "state.graph.usedIds", (graph["usedIds"] as! [String]) + [id(23)])
            after = edit(after, "state.catalog", (state["catalog"] as! [Any]) + [fact]); after = edit(after, "state.bindings", [["factId": id(23), "contributionId": id(23)]])
            after = edit(after, "coverage.trackedSubtotals.0.quantity", ["numerator": "6", "denominator": "1"]); after = edit(after, "coverage.trackedSubtotals.0.activeContributionIds", [id(20), id(23)])
            let budget: [String: Any] = ["currency": "USD", "totalMinor": null, "overCapMinor": null, "headroomMinor": null, "status": "unresolved", "scope": "wholeCheckout", "missing": ["fee"], "lowerBoundMinor": 0, "upperBoundMinor": null, "wholeCheckoutWithinCap": false]
            requestPreview = ["previewId": id(91), "expiresAt": expiry, "shopRevision": 8, "authorityEpoch": 3, "requestRevision": 6, "choice": "link", "before": budget, "after": budget, "changeMinor": null, "requiresOverageAcceptance": false, "requiresUnknownAcceptance": true]
        default: break
        }
        let graphRevision = ((before["state"] as? [String: Any])?["graph"] as? [String: Any])?["revision"] as? Int ?? 3
        after = edit(after, "state.graph.revision", graphRevision + 1)
        let afterPage = after as! [String: Any], afterState = afterPage["state"] as! [String: Any]
        let command: [String: Any] = mode == "request" ? ["kind": "request.apply", "body": ["requestId": id(90), "previewId": id(91), "acceptOverage": false, "acceptUnknown": true]] : action(afterState)
        let disclosure: [String: Any] = ["changes": changes, "pickup": pickup(afterPage), "money": ["before": before["checkout"]!, "after": checkout]]
        let candidate: [String: Any] = ["schemaVersion": 2, "candidateId": id(61), "candidateDigest": String(repeating: "a", count: 64), "expiresAt": expiry, "action": command, "after": afterState, "disclosure": disclosure]
        let preview: [String: Any] = ["schemaVersion": 2, "previewId": id(61), "previewDigest": String(repeating: "c", count: 64), "trackingVersion": 2, "expiresAt": candidate["expiresAt"]!, "action": command, "disclosure": disclosure, "moneyAcknowledgments": ["acceptOverage": false, "acceptUnknown": true]]
        return ["page": before, "candidate": candidate, "preview": preview, "requestPreview": requestPreview, "mode": mode]
    }
    static func intent(_ f: [String: Any], context: SharedDemandContext = context) throws -> SharedTrackingIntent {
        let p: SharedTrackingPage = try decode(f["page"]!), c: SharedTrackingCandidate = try decode(f["candidate"]!)
        let mode = f["mode"] as! String
        let kind: SharedTrackingIntentKind
        switch mode {
        case "adopt": kind = .adopt(action: c.action.command, change: .init(lines: c.after.graph.lines, contributions: c.after.graph.contributions), packs: c.after.packReviews)
        case "change", "request":
            let additions = c.after.graph.contributions.filter { row in !p.graph.contributions.contains { $0.id == row.id } }
            kind = .change(action: c.action.command, change: .init(contributions: additions), packs: c.after.packReviews, unboundFactIds: c.after.unbound.map(\.factId))
        case "rebind":
            kind = .rebind(bindings: [.init(factId: .init(UUID(uuidString: id(22))!), line: c.after.graph.lines[1], basket: c.after.basket[1], packReview: c.after.packReviews[1])])
        case "recover": kind = .recover(packs: c.after.packReviews)
        case "firstAdoptionUndo": kind = .firstAdoptionUndo(targetOperationId: .init(UUID(uuidString: id(90))!), packs: c.after.packReviews)
        default: kind = .review(action: c.action.command, packs: c.after.packReviews)
        }
        return try .init(page: p, context: context, kind: kind, requestPreview: f["requestPreview"] is NSNull ? nil : decode(f["requestPreview"]!))
    }
    static func candidateReview(_ f: [String: Any]) throws -> SharedTrackingCandidateReview {
        try .init(page: decode(f["page"]!), intent: intent(f), candidate: decode(f["candidate"]!))
    }
    static func accepted(_ f: [String: Any]) throws -> SharedTrackingAcceptedReview {
        try .init(candidateReview: candidateReview(f), preview: decode(f["preview"]!))
    }
}
