import HouseholdClient
import XCTest
@testable import RoomInTheCart

final class SharedDeliveryCookDraftTests: XCTestCase {
    typealias Object = [String: Any]
    let shop = UUID(), occurrence = UUID(), ingredient = UUID(), unknownIngredient = UUID(), group = UUID()
    let source = UUID(), line = UUID(), segment = UUID(), arrival = UUID(), usable = UUID(), reservation = UUID()
    let mealName = String(repeating: "Frijoles 🌶 ", count: 17) + "para Sol"
    let sourceName = "Ana’s black beans · lote %2$@"
    let groupName = "Almuerzo de Sofía"
    var seal: Object { ["shopId":shop.uuidString, "shopRevision":9, "placedRevision":6, "authorityEpoch":2, "supplyRevision":7] }
    var target: Object { ["occurrenceId":occurrence.uuidString, "mealRevision":4, "ingredientId":ingredient.uuidString] }
    func q(_ n: Int) -> Object { ["amount":["numerator":n,"denominator":1], "unit":"cup", "originalLiteral":"\(n) cups"] }
    func f(_ n: String, _ d: String = "1") -> Object { ["numerator":n,"denominator":d] }

    var meal: Object {
        let beans: Object = ["id":ingredient.uuidString, "name":"Beans", "quantity":q(3), "groupIds":[group.uuidString], "exclusions":["no sesame"]]
        let herbs: Object = ["id":unknownIngredient.uuidString, "name":"Fresh herbs", "quantity":NSNull(), "groupIds":[], "exclusions":[]]
        let protected: Object = ["id":group.uuidString, "name":groupName, "servings":["numerator":3,"denominator":2], "protected":true]
        let plan: Object = ["groups":[protected],"ingredients":[beans, herbs],"exclusions":["no peanuts"],"leadTimeMinutes":75,
                            "completedSteps":["Beans soaked overnight","Ya se lavaron las hierbas"]]
        return ["title":mealName,"day":"2026-11-01","kind":"lunch","portions":2,"protected":false,"planning":plan]
    }
    var page: Object {
        var row: Object = ["sourceId":source.uuidString, "foodId":source.uuidString, "lineId":line.uuidString,
                           "segmentKey":segment.uuidString, "foodName":sourceName, "exclusionTags":["packed separately"],
                           "matches":[target]]
        row["reservations"] = [target.merging(["groupId":group.uuidString, "reservationId":reservation.uuidString,"quantity":q(2)]) { _, new in new }]
        row["arrival"] = ["sourceId":source.uuidString,"observationId":arrival.uuidString,"arrivedAt":"2026-11-01T02:00:00Z","received":q(2)] as Object
        row["usable"] = ["sourceId":source.uuidString,"observationId":usable.uuidString,"arrivalObservationId":arrival.uuidString,
                         "confirmedAt":"2026-11-01T03:00:00Z","usable":q(1)] as Object
        row["confirmed"] = ["sourceId":source.uuidString,"foodId":source.uuidString,"arrivalId":arrival.uuidString,"usableId":usable.uuidString,"quantity":q(1)] as Object
        return seal.merging(["coverageAvailable":true, "reservationsAvailable":true, "lines":[["lineId":line.uuidString,"name":"Ordered beans"]],
                             "sources":[row],"meals":[["occurrenceId":occurrence.uuidString,"revision":4,"meal":meal] as Object]]) { _, new in new }
    }
    var coverage: Object {
        var beans = target
        beans["protected"] = true; beans["groupIds"] = [group.uuidString]; beans["required"] = q(3)
        beans["covered"] = f("1"); beans["missing"] = f("2"); beans["issues"] = ["reservationShortfall"]
        beans["reservations"] = [["sourceId":source.uuidString,"reservationId":reservation.uuidString,"requested":f("2"),"backed":f("1")] as Object]
        beans["allocations"] = [["sourceId":source.uuidString,"amount":f("1")] as Object]
        var herbs = target
        herbs["ingredientId"] = unknownIngredient.uuidString; herbs["protected"] = false; herbs["groupIds"] = []
        herbs["required"] = NSNull(); herbs["covered"] = NSNull(); herbs["missing"] = NSNull()
        herbs["issues"] = ["unknownQuantity","noMatch"]; herbs["allocations"] = []; herbs["reservations"] = []
        return seal.merging(["asOf":"2026-11-01T04:05:06.000Z", "needs":[beans, herbs], "unplannedOccurrenceIds":[]]) { _, new in new }
    }
    func decode<T: Decodable>(_ type: T.Type, _ body: Object) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: body))
    }
    func draft(_ p: Object, _ c: Object, language: String = "en-US", selected: SharedMealOccurrence? = nil) throws -> String? {
        let record = try decode(SharedDeliveryPage.self, p)
        let meal = try XCTUnwrap(selected ?? record.meals?.first)
        return try SharedDeliveryCookDraft.make(page: record, coverage: decode(SharedDeliveryCoverage.self, c), occurrence: meal, language: language)
    }

    func testDatedCookCopyShowsOnlyThisMealWithExactCoverageSourcesAndPreparationInBothLanguages() throws {
        // Extra wire fields cannot enter a recipient's plain text.
        var wire = page
        wire["accountSubject"] = "private-subject"
        wire["quote"] = ["capMinor":76123]
        let en = try XCTUnwrap(draft(wire, coverage))
        let es = try XCTUnwrap(draft(wire, coverage, language:"es-US"))
        for text in [en, es] {
            for literal in [mealName, groupName, sourceName, "3/2", "no sesame", "no peanuts", "packed separately",
                            "Beans soaked overnight", "Ya se lavaron las hierbas", "Fresh herbs", "UTC"] {
                XCTAssertTrue(text.contains(literal), literal)
            }
            for secret in [shop, occurrence, ingredient, group, reservation, source].map(\.uuidString) + ["private-subject","76123"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(secret), secret)
            }
        }
        for label in ["November 1, 2026", "Portions: 2", "Portions: 3/2", "Protected portions", "Ingredient quantity: 3 cups",
                      "Covered by deliveries: 1 cup", "Uncovered by deliveries: 2 cups", "Amount set aside: 2 cups",
                      "Still backed by this delivery: 1 cup", "Allocated from this delivery: 1 cup",
                      "Preparation time in minutes: 75", "Ingredient quantity: Unknown", "Covered by deliveries: Unknown",
                      "Uncovered by deliveries: Unknown", "No delivery has been matched", "Delivery revision: 7", "Meal revision: 4",
                      "These counts use confirmed deliveries for this order"] {
            XCTAssertTrue(en.contains(label), label)
        }
        for label in ["1 de noviembre de 2026", "Porciones protegidas", "Cantidad apartada: 2 tazas",
                      "Cantidad que aún cubre esta entrega: 1 taza", "Cubierto por las entregas: 1 taza",
                      "Sin cubrir por las entregas: 2 tazas", "Versión de las entregas: 7"] {
            XCTAssertTrue(es.contains(label), label)
        }
    }

    func testCoverageFractionsSurviveBeyondIntegerAndDecimalPrecision() throws {
        var result = coverage
        var rows = try XCTUnwrap(result["needs"] as? [Object])
        // 1 - 10^-60 cups allocated, leaving exactly 2 + 10^-60 cups missing.
        let d = "1" + String(repeating:"0",count:60)
        let n = String(repeating:"9",count:60)
        let short = "2" + String(repeating:"0",count:59) + "1"
        rows[0]["covered"] = f(n,d); rows[0]["missing"] = f(short,d)
        rows[0]["reservations"] = [["sourceId":source.uuidString,"reservationId":reservation.uuidString,"requested":f("2"),"backed":f(n,d)] as Object]
        rows[0]["allocations"] = [["sourceId":source.uuidString,"amount":f(n,d)] as Object]
        result["needs"] = rows
        let text = try XCTUnwrap(draft(page, result, language:"es-US"))
        XCTAssertTrue(text.contains("Cantidad que aún cubre esta entrega: \(n)/\(d) tazas"))
        XCTAssertTrue(text.contains("Sin cubrir por las entregas: \(short)/\(d) tazas"))
    }

    func testSplitRequirementsKeepTheProtectedSourceClaimWithTheNamedGroup() throws {
        var p = page, c = coverage, selected = meal
        var plan = try XCTUnwrap(selected["planning"] as? Object)
        var groups = try XCTUnwrap(plan["groups"] as? [Object])
        let second = UUID().uuidString
        groups.append(["id":second, "name":"Evening portion", "servings":["numerator":1,"denominator":2], "protected":false])
        var ingredients = try XCTUnwrap(plan["ingredients"] as? [Object])
        ingredients[0]["groupIds"] = [group.uuidString, second]
        ingredients[0]["quantity"] = q(5)
        plan["ingredients"] = ingredients; plan["groups"] = groups
        plan["bindings"] = [(group.uuidString,3), (second,2)].map { id, n -> Object in
            ["id":UUID().uuidString,"groupId":id,"ingredientId":ingredient.uuidString,"quantity":q(n)]
        }
        selected["planning"] = plan
        p["meals"] = [["occurrenceId":occurrence.uuidString,"revision":4,"meal":selected] as Object]
        var rows = try XCTUnwrap(c["needs"] as? [Object])
        var evening = target
        evening["groupIds"] = [second]; evening["protected"] = false; evening["required"] = q(2)
        evening["covered"] = f("0"); evening["missing"] = f("2")
        evening["reservations"] = []; evening["allocations"] = []; evening["issues"] = []
        rows.append(evening); c["needs"] = rows
        let text = try XCTUnwrap(draft(p,c))
        let rowsText = try XCTUnwrap(text.components(separatedBy: "Ingredient: Beans").last)
        let byGroup = rowsText.components(separatedBy: "Serving group: Evening portion")
        XCTAssertEqual(byGroup.count, 2)
        XCTAssertTrue(byGroup[0].contains("Serving group: " + groupName))
        XCTAssertTrue(byGroup[0].contains("Amount set aside: 2 cups"))
        let next = try XCTUnwrap(byGroup.last)
        XCTAssertTrue(next.contains("Ingredient quantity: 2 cups"))
        XCTAssertTrue(next.contains("Covered by deliveries: 0 cups"))
        XCTAssertTrue(next.contains("Amount set aside: None recorded"))
        XCTAssertFalse(next.contains("Still backed by this delivery: 1 cup"))
    }

    func testUnplannedMealHasExplicitUnknownsAndCannotInheritTheOtherOccurrencesFood() throws {
        var p = page, c = coverage
        var meals = try XCTUnwrap(p["meals"] as? [Object])
        let other = UUID()
        let plain: Object = ["title":"Second meal","portions":1,"day":"2026-11-02","kind":"dinner","protected":false]
        meals.insert(["occurrenceId":other.uuidString,"revision":1,"meal":plain], at:0)
        p["meals"] = meals; c["unplannedOccurrenceIds"] = [other.uuidString]
        let text = try XCTUnwrap(draft(p,c))
        for literal in ["Second meal","Serving group: None recorded","Meal exclusions: None recorded",
                        "Preparation time in minutes: Unknown","Completed preparation steps: None recorded",
                        "This meal has no recorded ingredient requirements."] {
            XCTAssertTrue(text.contains(literal))
        }
        XCTAssertFalse(text.contains(sourceName))
        XCTAssertFalse(text.contains(groupName))
        XCTAssertFalse(text.contains("no peanuts"))
    }

    func testRejectsOtherShopStaleRevisionsAlteredOccurrenceAndIncompleteCoverage() throws {
        for (field, bad): (String, Any) in [("shopId",UUID().uuidString),("supplyRevision",8),("placedRevision",5),
                                            ("authorityEpoch",3),("shopRevision",10),("asOf","invalid"),("needs",[])] {
            var stale = coverage; stale[field] = bad
            XCTAssertNil(try draft(page,stale), field)
        }
        for (field, bad): (String, Any) in [("coverageAvailable",false),("nextCursor",UUID().uuidString)] {
            var invalid = page; invalid[field] = bad
            XCTAssertNil(try draft(invalid,coverage), field)
        }
        var changedMeal = meal; changedMeal["title"] = "Different meal with the same keys"
        let altered = try decode(SharedMealOccurrence.self, ["occurrenceId":occurrence.uuidString,"revision":4,"meal":changedMeal])
        XCTAssertNil(try draft(page,coverage,selected:altered))
        XCTAssertNil(try draft(page,coverage,language:"fr-FR"))
    }
}
