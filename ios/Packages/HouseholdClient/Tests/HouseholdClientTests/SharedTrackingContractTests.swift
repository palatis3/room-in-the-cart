import Foundation
import XCTest
@testable import HouseholdClient

final class SharedTrackingContractTests: XCTestCase {
    private let null = NSNull()
    private func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
    private func quantity(_ n: Int) -> [String: Any] {
        ["amount": ["numerator": String(n), "denominator": "1"], "unit": "count", "originalLiteral": "\(n) wraps", "confirmedConversion": null]
    }
    private func line(_ n: Int, _ name: String, trashed: Bool = false) -> [String: Any] {
        ["id": id(n), "name": name, "unit": "count", "originalOrder": n, "trashedAt": trashed ? "2026-11-10T12:00:00Z" : null]
    }
    private func basket(_ n: Int, _ name: String) -> [String: Any] {
        ["id": id(n), "name": name, "packs": 1, "priceMinor": null, "feeEligible": true]
    }
    private func fixture() -> [String: Any] {
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
            "basisDigest": String(repeating: "b", count: 64), "checkout": TrackingWriteFixture.checkout, "coverage": coverage, "freezeReview": ["previewId": id(60), "previewDigest": String(repeating: "c", count: 64), "trackingVersion": 2]]
    }
    private func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func page(_ object: Any) throws -> SharedTrackingPage { try SharedTrackingWire.page(from: bytes(object)) }
    private func edit(_ object: Any, _ path: String, _ value: Any?) -> Any {
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
    private func rejects(_ path: String, _ value: Any?, fixture object: Any? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try page(edit(object ?? fixture(), path, value)), "Accepted mutation at \(path)", file: file, line: line)
    }
    private func boundFixture(known: Bool) -> Any {
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
    private func projectionFixture() -> Any {
        var state = fixture()["state"] as! [String: Any]
        state.removeValue(forKey: "packReviews"); state["privacyRevision"] = 6
        var object: Any = fixture()
        object = edit(object, "status", "reviewRequired")
        for key in ["state", "coverage", "freezeReview"] { object = edit(object, key, null) }
        return edit(object, "projection", ["schemaVersion": 1, "status": "reviewRequired", "invalidatedStateDigest": String(repeating: "d", count: 64), "previousPrivacyRevision": 5, "state": state])
    }
    func testPartialRetainsProtectedUnknownTransferAndOpaqueDistinctDigests() throws {
        let p = try page(fixture()), state = try XCTUnwrap(p.state)
        XCTAssertEqual(p.coverage?.status, .partial)
        XCTAssertFalse(try XCTUnwrap(p.coverage).completeFoodCoverage)
        XCTAssertTrue(try XCTUnwrap(p.coverage).allocatableUnboundFactIds.isEmpty)
        XCTAssertNil(state.catalog[0].quantity)
        XCTAssertNil(state.unbound[0].transferred?.quantity)
        XCTAssertEqual(state.unbound[0].transferred?.originalText, "Keep lunch wraps")
        XCTAssertEqual(state.catalog[0].sourceExclusions[0].label, "Keep family's original wording")
        XCTAssertTrue(state.graph.usedIds.contains(try XCTUnwrap(state.unbound[0].transferred?.id)))
        XCTAssertEqual(state.quoteDigest.value, String(repeating: "a", count: 64))
        XCTAssertEqual(p.basisDigest.value, String(repeating: "b", count: 64))
        XCTAssertEqual(p.freezeReview?.trackingVersion, 2)
    }
    func testLegacyReadKeepsBasketAndCatalogWithoutInventingTrackedSupply() throws {
        var object: Any = fixture()
        object = edit(object, "status", "legacy")
        object = edit(object, "state.graph.revision", 0)
        for key in ["lines", "contributions", "edges", "usedIds"] { object = edit(object, "state.graph.\(key)", []) }
        object = edit(object, "state.unbound.0.transferred", null)
        object = edit(object, "state.legacyLineIds", [id(10), id(11)])
        object = edit(object, "state.packReviews", [])
        object = edit(object, "coverage.trackedSubtotals", [])
        object = edit(object, "coverage.untrackedBasketIds", [id(10), id(11)])
        object = edit(object, "freezeReview", null)
        let legacy = try page(object)
        XCTAssertEqual(legacy.status, .legacy)
        XCTAssertEqual(legacy.coverage?.status, .partial)
        XCTAssertEqual(legacy.state?.basket.count, 2)
        XCTAssertEqual(legacy.state?.catalog.count, 1)
        XCTAssertEqual(legacy.state?.unbound.count, 1)
        XCTAssertEqual(legacy.coverage?.trackedSubtotals.count, 0)
        // V1 must not flatten or reinterpret a v2 partial read.
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandPage.self, from: bytes(object)))
        try rejects("status", "enabled", fixture: object)
        try rejects("coverage.status", "tracked", fixture: object)
    }
    func testBoundUnknownAndTrackedNumericAreStillNotCompleteCoverage() throws {
        let unknown = try page(boundFixture(known: false)), tracked = try page(boundFixture(known: true))
        XCTAssertEqual(unknown.coverage?.status, .unknown)
        XCTAssertEqual(tracked.coverage?.status, .tracked)
        // Unresolved source restriction survives even when a subtotal is numeric.
        XCTAssertEqual(tracked.state?.catalog[0].sourceExclusions[0].resolution, .unresolved)
        XCTAssertEqual(tracked.coverage?.completeFoodCoverage, false)
        try rejects("coverage.status", "tracked", fixture: boundFixture(known: false))
        try rejects("coverage.status", "unknown", fixture: boundFixture(known: true))
        try rejects("coverage.trackedSubtotals.1.quantity", ["numerator": "2", "denominator": "1"], fixture: boundFixture(known: false))
        try rejects("coverage.completeFoodCoverage", true, fixture: boundFixture(known: true))
    }
    func testRequiredNullIsNotOmissionAtEveryBoundary() throws {
        for path in ["projection", "state", "coverage", "freezeReview", "state.catalog.0.quantity", "state.catalog.0.originalQuantityText", "state.catalog.0.requiredLineId", "state.unbound.0.transferred", "state.basket.0.priceMinor", "state.graph.lines.0.trashedAt", "state.graph.contributions.0.quantity.confirmedConversion", "state.graph.contributions.0.productKey"] {
            try rejects(path, nil)
        }
        let legacyTransfer = try page(edit(fixture(), "state.unbound.0.transferred", null))
        XCTAssertNil(legacyTransfer.state?.unbound[0].transferred)
        for path in ["state", "coverage", "freezeReview"] { try rejects(path, nil, fixture: projectionFixture()) }
    }
    func testRejectUnknownKeysAtNewAndReusedNestedShapes() throws {
        for path in ["extra", "state.extra", "state.catalog.0.extra", "state.catalog.0.source.extra", "state.catalog.0.sourceExclusions.0.extra", "state.unbound.0.extra", "state.unbound.0.transferred.extra", "state.graph.extra", "state.graph.lines.0.extra", "state.graph.contributions.0.extra", "state.graph.contributions.0.quantity.extra", "state.graph.contributions.0.quantity.amount.extra", "state.packReviews.0.extra", "coverage.extra", "coverage.trackedSubtotals.0.extra", "freezeReview.extra"] {
            try rejects(path, "unexpected")
        }
        try rejects("state.graph.contributions.0.sourceExclusions", null)
    }
    func testExactIdentityAndPartitionRejectMissingDuplicateAndRelabelledFacts() throws {
        try rejects("state.catalog", [])
        try rejects("state.unbound", [])
        try rejects("state.unbound.0.factId", id(99))
        try rejects("state.bindings", [["factId": id(22), "contributionId": id(20)]])
        let unbound = (fixture()["state"] as! [String: Any])["unbound"] as! [Any]
        try rejects("state.unbound", unbound + unbound)
        try rejects("state.legacyLineIds", [id(10), id(11)])
        try rejects("state.basket.0.name", "Changed tracked name")
        try rejects("state.packReviews", [])
        try rejects("state.catalog.0.requiredLineId", id(99))
        try rejects("state.unbound.0.transferred.originalText", "Relabelled")
        try rejects("state.unbound.0.transferred.source.purpose", "Unprotected supply")
        try rejects("state.bindings.0.contributionId", id(20), fixture: boundFixture(known: true))
        try rejects("state.graph.contributions.1.source.reservationId", id(99), fixture: boundFixture(known: true))
    }
    func testTransferRequiresRetainedIdentityAndCannotBeRetiredOrAllocated() throws {
        try rejects("state.graph.usedIds", [id(10), id(11), id(20)])
        try rejects("state.unbound.0.transferred.removedAt", "2026-11-10T12:00:00Z")
        try rejects("state.unbound.0.transferred.id", id(20))
        try rejects("state.unbound.0.transferred.id", id(10))
        let edge: [String: Any] = ["id": id(70), "kind": "withinExisting", "demandId": id(22), "supplyId": id(20), "quantity": quantity(1), "confirmation": ["productMatchConfirmed": true, "confirmedAt": "2026-11-10T12:00:00Z", "evidence": "Invalid detached allocation"]]
        var object = edit(fixture(), "state.graph.usedIds", [id(10), id(11), id(20), id(22), id(70)])
        object = edit(object, "state.graph.edges", [edge])
        XCTAssertThrowsError(try page(object))
    }
    func testProtectedQuantityAndRestrictionOriginsCannotDrift() throws {
        try rejects("state.unbound.0.transferred.quantity", quantity(2))
        try rejects("state.catalog.0.quantity", quantity(2))
        try rejects("state.unbound.0.transferred.sourceExclusions.0.label", "Different restriction")
        try rejects("state.catalog.0.sourceExclusions.0.occurrenceId", id(99))
        try rejects("state.catalog.0.sourceExclusions.0.ingredientId", id(99))
        try rejects("state.graph.contributions.1.quantity", quantity(1), fixture: boundFixture(known: true))
        try rejects("state.catalog.0.source", ["kind": "manual"])
    }
    func testCoverageExactlyNamesPartitionAndNeverOffersUnboundSupply() throws {
        for (path, value) in [("coverage.unboundFactIds", []), ("coverage.untrackedBasketIds", []), ("coverage.protectedUnboundFactIds", []), ("coverage.allocatableUnboundFactIds", [id(22)])] { try rejects(path, value) }
        try rejects("coverage.status", "tracked")
        try rejects("coverage.status", "complete")
        try rejects("coverage.completeFoodCoverage", true)
        try rejects("coverage.trackedSubtotals", [])
        try rejects("coverage.trackedSubtotals.0.activeContributionIds", [id(22)])
        try rejects("coverage.trackedSubtotals.0.lineId", id(11))
        try rejects("coverage.trackedSubtotals.0.unit", "gram")
    }
    func testPrivacyProjectionHasNoPacksCoverageOrReviewTokenAndAdvancesPrivacy() throws {
        let projection = try page(projectionFixture())
        XCTAssertEqual(projection.status, .reviewRequired)
        XCTAssertEqual(projection.privacyRevision, 6)
        XCTAssertNil(projection.state); XCTAssertNil(projection.coverage); XCTAssertNil(projection.freezeReview)
        try rejects("projection.state.packReviews", [], fixture: projectionFixture())
        try rejects("projection.previousPrivacyRevision", 6, fixture: projectionFixture())
        try rejects("coverage", fixture()["coverage"], fixture: projectionFixture())
        try rejects("freezeReview", fixture()["freezeReview"], fixture: projectionFixture())
        try rejects("state", fixture()["state"], fixture: projectionFixture())
        try rejects("projection.state.authorityEpoch", 4, fixture: projectionFixture())
    }
    func testVersionScopeAndNumericValidation() throws {
        for (path, value) in [("schemaVersion", 1), ("state.schemaVersion", 1), ("freezeReview.trackingVersion", 1), ("shopRevision", 0), ("state.privacyRevision", -1), ("state.catalog.0.revision", Int(Int32.max) + 1), ("state.basket.0.packs", 0)] { try rejects(path, value) }
        try rejects("state.graph.shopId", id(99))
        try rejects("state.authorityEpoch", 4)
        try rejects("state.quoteDigest", String(repeating: "A", count: 64))
        try rejects("basisDigest", "invalid")
        try rejects("state.graph.contributions.0.quantity.amount.numerator", "04")
        try rejects("state.graph.contributions.0.quantity.amount.denominator", "2")
        let p = try page(fixture())
        try p.validate(householdID: id(1), shopID: UUID(uuidString: id(2))!, shopRevision: 8, authorityEpoch: 3)
        XCTAssertThrowsError(try p.validate(householdID: id(99), shopID: UUID(uuidString: id(2))!, shopRevision: 8, authorityEpoch: 3))
        XCTAssertThrowsError(try p.validate(householdID: id(1), shopID: UUID(uuidString: id(2))!, shopRevision: 9, authorityEpoch: 3))
    }
    func testReadBindingRejectsStalePrivacyRevisionAuthorityDigestAndSession() throws {
        let p = try page(fixture()), context = SharedDemandContext(subject: "a", householdID: id(1), memberID: id(80), deviceID: id(81))
        let binding = try SharedTrackingReadBinding(page: p, context: context)
        try binding.validate(page: p, context: context)
        for (path, value) in [("shopRevision", 9), ("state.graph.revision", 4), ("state.privacyRevision", 6)] {
            XCTAssertThrowsError(try binding.validate(page: page(edit(fixture(), path, value)), context: context))
        }
        XCTAssertThrowsError(try binding.validate(page: page(edit(fixture(), "basisDigest", String(repeating: "e", count: 64))), context: context))
        var epoch = edit(fixture(), "authorityEpoch", 4); epoch = edit(epoch, "state.authorityEpoch", 4)
        XCTAssertThrowsError(try binding.validate(page: page(epoch), context: context))
        XCTAssertThrowsError(try binding.validate(page: page(projectionFixture()), context: context))
        for changed in [SharedDemandContext(subject: "b", householdID: id(1), memberID: id(80), deviceID: id(81)), SharedDemandContext(subject: "a", householdID: id(1), memberID: id(99), deviceID: id(81)), SharedDemandContext(subject: "a", householdID: id(1), memberID: id(80), deviceID: id(99))] { XCTAssertThrowsError(try binding.validate(page: p, context: changed)) }
    }
    func testNormalRefreshMustRetainUsedIDsAndCannotRevivePrivacyHistory() throws {
        let old = try XCTUnwrap(page(fixture()).state)
        try old.validateRetainedIdentities(from: old)
        let lost = try XCTUnwrap(page(edit(edit(fixture(), "state.unbound.0.transferred", null), "state.graph.usedIds", [id(10), id(11), id(20)])).state)
        XCTAssertThrowsError(try lost.validateRetainedIdentities(from: old))
        let privacy = try XCTUnwrap(page(edit(fixture(), "state.privacyRevision", 6)).state)
        XCTAssertThrowsError(try privacy.validateRetainedIdentities(from: old))
    }
    func testHistoryIsContentFreeOrderedAndRequiresFreshPreview() throws {
        let fixture: [String: Any] = ["schemaVersion": 2, "shopId": id(2), "shopRevision": 8, "items": [["operationId": id(90), "shopRevision": 7, "committedAt": "2026-11-10T12:00:00Z", "status": "current_preview_required"], ["operationId": id(91), "shopRevision": 6, "committedAt": "2026-11-10T11:00:00Z", "status": "unavailable"]]]
        let h = try SharedTrackingWire.history(from: bytes(fixture))
        try h.validate(page: page(self.fixture()))
        XCTAssertEqual(h.items[0].status, .current_preview_required)
        for (path, value) in [("items.0.sourceText", "Private content"), ("items.0.status", "eligible"), ("items.0.committedAt", "yesterday"), ("items.1.operationId", id(90))] {
            XCTAssertThrowsError(try SharedTrackingWire.history(from: bytes(edit(fixture, path, value))))
        }
        XCTAssertThrowsError(try SharedTrackingWire.history(from: bytes(edit(fixture, "items.1.shopRevision", 7))))
        XCTAssertThrowsError(try h.validate(page: page(edit(self.fixture(), "shopRevision", 9))))
    }
    func testBoundedResponseReaderRejectsOversizedInput() throws {
        XCTAssertThrowsError(try SharedTrackingWire.page(from: Data(repeating: 32, count: SharedTrackingWire.maximumResponseBytes + 1)))
    }
}
