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

extension SharedDeliveryCookDraftTests {
    /// Six cups were promised across two meals. The corrected freezer count is five.
    /// A separate delivery contributes the last cup to dinner.
    private func jointRecord() throws -> (delivery: Object, pantry: Object, report: Object) {
        let evening = UUID().uuidString, dinnerGroup = UUID().uuidString, freezer = UUID().uuidString
        let dinnerTarget = target.merging(["occurrenceId":evening]) { _, new in new }
        func occurrenceRow(_ id: String, _ name: String, _ kind: String, _ groupID: String,
                           _ groupName: String, _ cups: Int, protected: Bool) throws -> Object {
            var entry = meal
            var plan = try XCTUnwrap(entry["planning"] as? Object)
            let beans: Object = ["id":ingredient.uuidString, "name":"Beans", "quantity":q(cups),
                                 "groupIds":[groupID], "exclusions":["no sesame"]]
            var ingredients = [beans]
            if kind == "dinner" { ingredients.append(try XCTUnwrap((plan["ingredients"] as? [Object])?.last)) }
            plan["ingredients"] = ingredients
            plan["groups"] = [["id":groupID, "name":groupName, "servings":["numerator":2, "denominator":1],
                               "protected":protected] as Object]
            entry["title"] = name; entry["kind"] = kind; entry["planning"] = plan
            return ["occurrenceId":id, "revision":4, "meal":entry]
        }
        var delivery = page
        var sourceRows = try XCTUnwrap(delivery["sources"] as? [Object])
        sourceRows[0]["matches"] = [dinnerTarget]; sourceRows[0]["reservations"] = []
        delivery["sources"] = sourceRows
        delivery["meals"] = try [occurrenceRow(occurrence.uuidString, "School lunch", "lunch", group.uuidString, groupName, 2, protected: true),
                             occurrenceRow(evening, "Frijoles familiares", "dinner", dinnerGroup, "Familia", 4, protected: false)]
        let lunchClaim = UUID().uuidString, dinnerClaim = UUID().uuidString
        func head(_ target: Object, groupID: String, claim: String, cups: Int) -> Object {
            target.merging(["groupId":groupID, "reservationId":claim, "quantity":q(cups)]) { _, new in new }
        }
        let time = "2026-11-01T04:05:06.000Z"
        let lot: Object = ["lotId":freezer, "location":"freezer", "origin":"manual", "foodName":"Frozen black beans",
                           "selected":true, "storedAt":time, "useFirstAt":NSNull(), "exclusionTags":["stored separately"],
                           "matches":[target,dinnerTarget], "reservations":[head(target, groupID:group.uuidString, claim:lunchClaim, cups:2),
                                                                         head(dinnerTarget, groupID:dinnerGroup, claim:dinnerClaim, cups:4)],
                           "observation":["observationId":UUID().uuidString,"confirmedAt":time,"quantity":q(5)] as Object]
        let unused: Object = ["lotId":UUID().uuidString, "location":"pantry", "origin":"manual", "foodName":"Unselected other shop's stock",
                              "selected":false, "storedAt":time, "useFirstAt":NSNull(), "observation":NSNull(), "exclusionTags":[], "matches":[], "reservations":[]]
        let pantry = seal.merging(["pantryRevision":12,"asOf":time,"lots":[lot,unused],"nextCursor":NSNull()]) { _, new in new }
        func need(_ target: Object, groupID: String, claim: String, cups: Int, frozen: Int, delivered: Int) -> Object {
            var allocations: [Object] = [["sourceId":freezer, "kind":"freezer", "amount":f(String(frozen))]]
            if delivered > 0 { allocations.append(["sourceId":source.uuidString, "kind":"delivery", "amount":f(String(delivered))]) }
            let reservation: Object = ["sourceId":freezer, "reservationId":claim, "requested":f(String(cups)), "backed":f(String(frozen))]
            return target.merging(["groupIds":[groupID], "protected":groupID == group.uuidString, "required":q(cups),
                                   "covered":f(String(frozen+delivered)), "missing":f("0"), "freezer":f(String(frozen)),
                                   "pantry":f("0"), "delivered":f(String(delivered)), "allocations":allocations, "reservations":[reservation],
                                   "issues":frozen < cups ? ["reservationShortfall"] : []]) { _, new in new }
        }
        var unknown = try XCTUnwrap((coverage["needs"] as? [Object])?.last)
        unknown["occurrenceId"] = evening
        for key in ["delivered", "pantry", "freezer"] { unknown[key] = NSNull() }
        let needs = [need(target, groupID:group.uuidString, claim:lunchClaim, cups:2, frozen:2, delivered:0),
                     need(dinnerTarget, groupID:dinnerGroup, claim:dinnerClaim, cups:4, frozen:3, delivered:1), unknown]
        let report = seal.merging(["asOf":time, "pantryRevision":12, "unplannedOccurrenceIds":[], "needs":needs]) { _, new in new }
        return (delivery, pantry, report)
    }

    private func foodDraft(_ delivery: Object, _ pantry: Object, _ report: Object, dinner: Bool = true, language: String = "en-US") throws -> String? {
        let page = try decode(SharedDeliveryPage.self, delivery)
        let copy = SharedCookCoverage.food(try decode(SharedPantryPage.self, pantry), try decode(SharedFoodCoverage.self, report))
        let meals = try XCTUnwrap(page.meals)
        return SharedDeliveryCookDraft.make(page: page, report: copy, occurrence: meals[dinner ? 1 : 0], language: language)
    }

    func testCorrectedFreezerPromisesAndIndependentDeliveryAppearOnceOnNamedJointCookDrafts() throws {
        let fixture = try jointRecord()
        let dinner = try XCTUnwrap(foodDraft(fixture.delivery, fixture.pantry, fixture.report))
        let lunch = try XCTUnwrap(foodDraft(fixture.delivery, fixture.pantry, fixture.report, dinner:false))
        let spanish = try XCTUnwrap(foodDraft(fixture.delivery, fixture.pantry, fixture.report, language:"es-US"))
        for fact in ["Frijoles familiares", "Serving group: Familia", "Covered by deliveries: 1 cup", "Covered by pantry stock: 0 cups",
                     "Covered by freezer stock: 3 cups", "Still needed: 0 cups", "Amount set aside: 4 cups", "Still backed by this source: 3 cups",
                     "Latest confirmed usable count: 5 cups", "A source no longer covers the full amount set aside.", "Source exclusions: stored separately",
                     "Pantry revision: 12", "Covered by freezer stock: Unknown", "Still needed: Unknown", "UTC"] {
            XCTAssertTrue(dinner.contains(fact), fact)
        }
        XCTAssertTrue(lunch.contains("Serving group: " + groupName))
        XCTAssertTrue(lunch.contains("Covered by deliveries: 0 cups"))
        XCTAssertTrue(lunch.contains("Still backed by this source: 2 cups"))
        XCTAssertFalse(lunch.contains(sourceName))
        XCTAssertFalse(dinner.contains(groupName))
        XCTAssertFalse(dinner.contains("Uncovered by deliveries"))
        for note in [lunch, dinner, spanish] { XCTAssertFalse(note.contains("Unselected other shop's stock")) }
        for fact in ["Cubierto por el congelador: 3 tazas", "Aún falta: 0 tazas", "Cantidad apartada: 4 tazas",
                     "Cantidad que aún cubre esta fuente: 3 tazas", "Versión de la despensa: 12", "Frozen black beans", sourceName] {
            XCTAssertTrue(spanish.contains(fact), fact)
        }
    }

    func testUnknownPhysicalCountKeepsBothFreezerPromisesAndShowsExactRemainingNeed() throws {
        var record = try jointRecord()
        var lots = try XCTUnwrap(record.pantry["lots"] as? [Object])
        var observation = try XCTUnwrap(lots[0]["observation"] as? Object)
        observation["quantity"] = NSNull()
        lots[0]["observation"] = observation
        record.pantry["lots"] = lots
        var needs = try XCTUnwrap(record.report["needs"] as? [Object])
        for index in 0...1 {
            var reservations = try XCTUnwrap(needs[index]["reservations"] as? [Object])
            reservations[0]["backed"] = f("0")
            needs[index]["reservations"] = reservations
            let allocations = try XCTUnwrap(needs[index]["allocations"] as? [Object])
            needs[index]["allocations"] = allocations.filter { ($0["kind"] as? String) == "delivery" }
            needs[index]["covered"] = f(index == 0 ? "0" : "1")
            needs[index]["freezer"] = f("0")
            needs[index]["missing"] = f(index == 0 ? "2" : "3")
            needs[index]["issues"] = ["unconfirmed", "reservationShortfall"]
        }
        record.report["needs"] = needs
        let dinner = try XCTUnwrap(foodDraft(record.delivery, record.pantry, record.report))
        let lunch = try XCTUnwrap(foodDraft(record.delivery, record.pantry, record.report, dinner:false))
        for note in [lunch,dinner] {
            XCTAssertTrue(note.contains("Latest confirmed usable count: Unknown"))
            XCTAssertTrue(note.contains("Still backed by this source: 0 cups"))
            XCTAssertTrue(note.contains("A matched source is waiting for a usable count."))
        }
        XCTAssertTrue(lunch.contains("Amount set aside: 2 cups"))
        XCTAssertTrue(lunch.contains("Still needed: 2 cups"))
        XCTAssertTrue(dinner.contains("Amount set aside: 4 cups"))
        XCTAssertTrue(dinner.contains("Covered by deliveries: 1 cup"))
        XCTAssertTrue(dinner.contains("Still needed: 3 cups"))
    }

    func testJointCookDraftRejectsWrongShopStaleEpochAndPantryRevisionAndUnmatchedPhysicalSource() throws {
        let record = try jointRecord()
        for (field, bad): (String, Any) in [("shopId",UUID().uuidString), ("pantryRevision",13), ("authorityEpoch",3), ("supplyRevision",8)] {
            var report = record.report; report[field] = bad
            XCTAssertNil(try foodDraft(record.delivery, record.pantry, report), field)
            var pantry = record.pantry; pantry[field] = bad
            XCTAssertNil(try foodDraft(record.delivery, pantry, record.report), field)
        }
        var report = record.report
        var needs = try XCTUnwrap(report["needs"] as? [Object])
        needs[1]["allocations"] = [["sourceId":UUID().uuidString, "kind":"freezer", "amount":f("4")] as Object]
        report["needs"] = needs
        XCTAssertNil(try foodDraft(record.delivery, record.pantry, report))
    }
}

extension SharedDeliveryCookDraftTests {
    func testSealedCookCopyReportsDeadlineWithItsOwnZoneAndShowsUnknownWhenAbsent() throws {
        var p=page, edited=meal
        var plan=try XCTUnwrap(edited["planning"] as? Object)
        plan["deadline"]=["at":"2026-11-01T06:30:00Z","zone":"America/New_York"]
        edited["planning"]=plan
        p["meals"]=[["occurrenceId":occurrence.uuidString,"revision":4,"meal":edited] as Object]
        for language in ["en-US","es-US"] {
            let note=try XCTUnwrap(draft(p,coverage,language:language))
            XCTAssertTrue(note.contains("America/New_York (UTC−05:00)"))
            XCTAssertTrue(note.contains(language=="en-US" ? "Meal deadline:" : "Hora límite de la comida:"))
        }
        XCTAssertTrue(try XCTUnwrap(draft(page,coverage)).contains("Meal deadline: Unknown"))
    }
}
