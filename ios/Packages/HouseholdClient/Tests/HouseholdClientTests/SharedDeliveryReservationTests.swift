import Foundation
import XCTest
@testable import HouseholdClient

private struct ReservationFixture {
    typealias Object = [String: Any]
    let shop = UUID(), occurrence = UUID(), ingredient = UUID(), group = UUID(), source = UUID(), head = UUID()
    let arrival = UUID(), usable = UUID(), line = UUID()

    func quantity(_ n: Int, _ d: Int, _ unit: String) -> Object {
        ["amount": ["numerator": n, "denominator": d], "unit": unit, "originalLiteral": "\(n)/\(d) \(unit)"]
    }
    func fraction(_ n: String, _ d: String = "1") -> Object { ["numerator": n, "denominator": d] }
    var target: Object { ["occurrenceId": occurrence.uuidString, "mealRevision": 1, "ingredientId": ingredient.uuidString] }
    var sealed: Object { ["shopId": shop.uuidString, "shopRevision": 2, "placedRevision": 1, "authorityEpoch": 1, "supplyRevision": 4] }
    var pin: Object {
        target.merging(["groupId": group.uuidString, "reservationId": head.uuidString, "quantity": quantity(1, 2, "kilogram")]) { _, v in v }
    }

    func page(heads: [Object]? = nil, matches: Bool = true, confirmed: Bool = true, capability: Bool? = true,
              unsplit: Bool = false) throws -> SharedDeliveryPage {
        let g: Object = ["id": group.uuidString, "name": "Lunch", "servings": ["numerator": 1, "denominator": 1], "protected": true]
        let second = UUID()
        var groups = [g]
        if unsplit {
            var other = g
            other["id"] = second.uuidString
            groups.append(other)
        }
        let i: Object = ["id": ingredient.uuidString, "name": "Beans", "quantity": quantity(500, 1, "gram"), "exclusions": [], "groupIds": groups.map { $0["id"]! }]
        let meal: Object = ["title": "Beans", "day": "2026-11-07", "kind": "lunch", "portions": 1, "protected": true,
                            "planning": ["groups": groups, "ingredients": [i]]]
        var sourceRow: Object = ["sourceId": source.uuidString, "foodId": source.uuidString, "lineId": line.uuidString,
                                 "segmentKey": source.uuidString, "foodName": "Beans", "exclusionTags": [], "matches": matches ? [target] : []]
        if capability != nil || heads != nil { sourceRow["reservations"] = heads ?? [pin] }
        if confirmed {
            let stock = quantity(500, 1, "gram")
            sourceRow["arrival"] = ["sourceId": source.uuidString, "observationId": arrival.uuidString, "received": stock]
            sourceRow["usable"] = ["sourceId": source.uuidString, "observationId": usable.uuidString, "arrivalObservationId": arrival.uuidString,
                                   "confirmedAt": "2026-11-07T08:00:00Z", "usable": stock]
            sourceRow["confirmed"] = ["sourceId": source.uuidString, "foodId": source.uuidString, "arrivalId": arrival.uuidString,
                                      "usableId": usable.uuidString, "quantity": stock]
        }
        var page = sealed
        page["reservationsAvailable"] = capability
        page["lines"] = [["lineId": line.uuidString, "name": "Beans"]]
        page["meals"] = [["occurrenceId": occurrence.uuidString, "revision": 1, "meal": meal]]
        page["sources"] = [sourceRow]
        return try JSONDecoder().decode(SharedDeliveryPage.self, from: JSONSerialization.data(withJSONObject: page))
    }

    var claim: Object { ["sourceId": source.uuidString, "reservationId": head.uuidString, "requested": fraction("500"), "backed": fraction("500")] }
    func coverage(_ claims: [Object], reviewed page: SharedDeliveryPage, backed: String = "500", issues: [String] = []) throws {
        var need = target
        need["groupIds"] = [group.uuidString]
        need["protected"] = true
        need["required"] = quantity(500, 1, "gram")
        need["covered"] = fraction(backed)
        need["missing"] = fraction(String(500 - Int(backed)!))
        need["allocations"] = backed == "0" ? [] : [["sourceId": source.uuidString, "amount": fraction(backed)]]
        need["reservations"] = claims
        need["issues"] = issues
        var coverage = sealed
        coverage["asOf"] = "2026-11-07T08:00:00Z"
        coverage["unplannedOccurrenceIds"] = []
        coverage["needs"] = [need]
        let result = try JSONDecoder().decode(SharedDeliveryCoverage.self, from: JSONSerialization.data(withJSONObject: coverage))
        try result.validate(reviewed: page)
    }
}

extension HouseholdClientTests {
    func testNamedDeliveryReservationBindsReviewedGroupHeadMatchAndExplicitRelease() throws {
        let f = ReservationFixture(), page = try f.page()
        try page.validateReservations()
        let meal = try XCTUnwrap(page.meals?.first)
        let target = SharedDeliveryPage.IngredientMatch(occurrence: meal, ingredient: try XCTUnwrap(meal.meal.planning?.ingredients.first))
        let value = SharedMealQuantity(amount: .init(numerator: 100), unit: "gram", originalLiteral: "100 g")
        func edit(_ previous: UUID?, _ quantity: SharedMealQuantity?, _ group: UUID? = nil) -> SharedDeliveryEdit {
            .reserve(source: f.source, ingredient: target, group: group ?? f.group, previous: previous, quantity: quantity)
        }
        let empty = try f.page(heads: [])
        let body = try edit(nil, value).body(reviewed: empty)
        XCTAssertEqual(edit(nil, value).kind, "delivery.reserve")
        XCTAssertEqual(Set(body.keys), ["sourceId", "occurrenceId", "mealRevision", "ingredientId", "groupId", "supplyRevision", "predecessorId", "quantity"])
        XCTAssertEqual(body["predecessorId"], .null)
        XCTAssertEqual(body["supplyRevision"], .integer(4))
        XCTAssertThrowsError(try edit(nil, value).body(reviewed: page))
        XCTAssertThrowsError(try edit(f.head, value, UUID()).body(reviewed: page))
        XCTAssertThrowsError(try edit(nil, nil).body(reviewed: empty))
        XCTAssertThrowsError(try edit(nil, value).body(reviewed: f.page(capability: nil)))
        XCTAssertThrowsError(try edit(nil, value).body(reviewed: f.page(heads: [], unsplit: true)))
        XCTAssertThrowsError(try f.page(unsplit: true).validateReservations())
        let unknown = try f.page(confirmed: false)
        XCTAssertNoThrow(try edit(f.head, value).body(reviewed: unknown)) // 100 g reduces the existing 1/2 kg.
        let increase = SharedMealQuantity(amount: .init(numerator: 501), unit: "gram", originalLiteral: "501 g")
        XCTAssertThrowsError(try edit(f.head, increase).body(reviewed: unknown))
        let release = try edit(f.head, nil).body(reviewed: f.page(confirmed: false))
        XCTAssertEqual(release["quantity"], .null)
        XCTAssertEqual(release["predecessorId"], .string(f.head.uuidString.lowercased()))

        var released = f.pin
        released["quantity"] = NSNull()
        try f.page(heads: [released], matches: false).validateReservations()
        XCTAssertThrowsError(try edit(f.head, value).body(reviewed: f.page(heads: [released], matches: false)))
        XCTAssertNoThrow(try edit(f.head, value).body(reviewed: f.page(heads: [released])))
        XCTAssertThrowsError(try f.page(matches: false).validateReservations())
        XCTAssertThrowsError(try f.page(heads: [f.pin, f.pin]).validateReservations())
        for (key, bad): (String, Any) in [("groupId", UUID().uuidString), ("mealRevision", 2), ("quantity", f.quantity(1, 1, "liter"))] {
            var head = f.pin; head[key] = bad
            XCTAssertThrowsError(try f.page(heads: [head]).validateReservations())
        }
        var missing = f.pin
        missing.removeValue(forKey: "quantity")
        XCTAssertThrowsError(try f.page(heads: [missing]))
    }

    func testNamedDeliveryCoverageChecksEveryReservationAndKeepsZeroBackedClaims() throws {
        let f = ReservationFixture(), page = try f.page()
        try f.coverage([f.claim], reviewed: page)
        var zero = f.claim
        zero["backed"] = f.fraction("0")
        try f.coverage([zero], reviewed: f.page(confirmed: false), backed: "0", issues: ["unconfirmed", "reservationShortfall"])
        XCTAssertThrowsError(try f.coverage([], reviewed: page))
        XCTAssertThrowsError(try f.coverage([f.claim, f.claim], reviewed: page))
        XCTAssertThrowsError(try f.coverage([f.claim], reviewed: f.page(heads: [])))
        XCTAssertThrowsError(try f.coverage([zero], reviewed: page))
        XCTAssertThrowsError(try f.coverage([f.claim], reviewed: page, backed: "499"))
        for (key, bad): (String, Any) in [("sourceId", UUID().uuidString), ("reservationId", UUID().uuidString), ("requested", f.fraction("499")),
                                           ("backed", f.fraction("501")), ("backed", f.fraction("1", "0"))] {
            var claim = f.claim; claim[key] = bad
            XCTAssertThrowsError(try f.coverage([claim], reviewed: page))
        }
        // One arbitrarily small excess must remain visible after cross multiplication.
        var excess = f.claim
        excess["backed"] = f.fraction("500" + String(repeating: "0", count: 79) + "1", "1" + String(repeating: "0", count: 80))
        XCTAssertThrowsError(try f.coverage([excess], reviewed: page))
    }
}
