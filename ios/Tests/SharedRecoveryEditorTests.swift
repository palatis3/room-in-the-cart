import HouseholdClient
import XCTest
@testable import RoomInTheCart

final class SharedRecoveryEditorTests: XCTestCase {
    typealias Object = [String: Any]
    let dinner = UUID(), lunch = UUID(), group = UUID(), donorGroup = UUID(), source = UUID(), shop = UUID()
    let time = "2026-11-10T17:00:00.000Z"
    func decode<T: Decodable>(_ type: T.Type, _ object: Object) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func q(_ numerator: Int, _ denominator: Int = 1) -> Object {
        ["amount":["numerator":numerator,"denominator":denominator], "unit":"cup","originalLiteral":"\(numerator)/\(denominator)"]
    }
    func need(_ name: String, _ group: UUID, protected: Bool, amount: Object) -> Object {
        ["id":UUID().uuidString,"ingredientId":UUID().uuidString,"foodId":NSNull(),"groupId":group.uuidString,"matchedSourceIds":[source.uuidString],
         "name":name,"notes":"Ingredient notes","quantity":amount,"priority":protected ? "protected" : "required","due":NSNull(),"exclusions":["no sesame"]]
    }
    func meal(_ title: String, _ group: UUID, ingredient: String) -> Object {
        ["occurrenceId":UUID().uuidString,"revisionId":UUID().uuidString,"sourceMealRevision":2,"portions":4,"title":title,"notes":"Cooking notes",
         "day":"2026-11-11","due":NSNull(),"zone":NSNull(),"sourceURL":"https://example.org/recipe","exclusions":["no sesame"],"template":NSNull(),
         "groups":[["id":group.uuidString,"name":"Dinner plates","servings":["numerator":4,"denominator":1],"protected":false,"exclusions":["no sesame"]] as Object],
         "needs":[need(ingredient,group,protected:false,amount:q(7,3))],"remainingElapsedMinutes":15,"requiredLeadMinutes":90,"advanceStepsCompleted":true]
    }
    var base: Object { ["shopRevision":5,"placedRevision":3,"supplyRevision":8,"pantryRevision":9,"authorityEpoch":2,"recoveryRevision":1,"contextRevision":1] }
    func record(rows: [Object], originalHeads: Bool = false) throws -> SharedRecoveryPage {
        let decoded = try rows.map { try decode(SharedRecoveryMeal.self,$0) }
        let digests = try decoded.map { ["occurrenceId":$0.id.uuidString,"digest":try $0.targetDigest()] }
        let sources: [Object] = decoded.map { meal in
            ["occurrenceId":meal.id.uuidString,"sourceMealRevision":meal.sourceMealRevision,
             "sealedRevisionId":originalHeads ? meal.revisionId.uuidString : UUID().uuidString,
             "completedSteps":["Original prep completed"],"sourceOccurrenceId":NSNull(),"approvedIdea":NSNull()]
        }
        let option: Object = ["sourceId":source.uuidString,"name":"Beans from freezer","exclusionTags":["stored separately"],"kind":"freezer","quantity":q(5)]
        return try decode(SharedRecoveryPage.self,["shopId":shop.uuidString,"placedRevision":3,"asOf":time,"base":base,"meals":rows,
            "targetDigests":digests,"sourceOptions":[option],"mealSources":sources,"unplannedOccurrenceIds":[],"commitmentInventoryComplete":true])
    }

    func testManualReplacementPreservesTargetAndProtectedNeedWhileFreshMatchesAndAgreementsStayExplicit() throws {
        var original = meal("Original Wednesday",group,ingredient:"Wraps")
        var groups = try XCTUnwrap(original["groups"] as? [Object])
        groups.append(["id":lunch.uuidString,"name":"Tuesday lunch","servings":["numerator":2,"denominator":1],"protected":true,"exclusions":[]])
        original["groups"] = groups
        var needs = try XCTUnwrap(original["needs"] as? [Object])
        needs.append(need("Lunch set aside",lunch,protected:true,amount:q(2)));original["needs"] = needs
        let page = try record(rows:[original]);let target = try XCTUnwrap(page.meals.first)
        var draft = SharedRecoveryDraft(target:target)
        draft.title = "Sopa para Sofía";draft.extraTrip = true
        draft.ingredients[0].name = "Caldo";draft.ingredients[0].literal = "7/3";draft.ingredients[0].unit = .cup
        draft.ingredients[0].matched = [source]
        let intent = try draft.intent(page:page,target:target)
        let changed = intent.replacement
        XCTAssertEqual(changed.id,target.id);XCTAssertNotEqual(changed.revisionId,target.revisionId)
        XCTAssertEqual(changed.day,target.day);XCTAssertNil(changed.zone);XCTAssertNil(changed.due)
        XCTAssertEqual(changed.groups,target.groups);XCTAssertEqual(changed.needs.first,target.needs.last)
        let new = try XCTUnwrap(changed.needs.last)
        XCTAssertEqual(new.name,"Caldo");XCTAssertEqual(new.quantity?.amount, .init(numerator:7,denominator:3))
        XCTAssertNotEqual(new.id,target.needs[0].id);XCTAssertEqual(new.matchedSourceIds,[source]);XCTAssertEqual(new.exclusions,["no sesame"])
        XCTAssertTrue(intent.proposesExtraTrip);XCTAssertFalse(intent.agreesToExtraTrip);XCTAssertFalse(intent.acceptsUnresolved);XCTAssertFalse(intent.agreesToRepeat)
        draft.ingredients[0].matched = [UUID()];XCTAssertThrowsError(try draft.intent(page:page,target:target))
        draft.ingredients[0].matched = [];draft.ingredients[0].literal = ""
        XCTAssertNil(try draft.intent(page:page,target:target).replacement.needs.last?.quantity)
    }

    func testRepeatBindsActualDinnerAndMappedServingsButRequiresFreshSourceAndTimingReview() throws {
        let page = try record(rows:[meal("Wednesday",group,ingredient:"Wraps"),meal("Tuesday beans",donorGroup,ingredient:"Black beans")])
        let target=page.meals[0], donor=page.meals[1]
        let draft=try XCTUnwrap(SharedRecoveryDraft.repeated(donor,for:target))
        let intent=try draft.intent(page:page,target:target)
        XCTAssertEqual(intent.repeatOfOccurrenceId,donor.id);XCTAssertFalse(intent.agreesToRepeat)
        let replacement=intent.replacement
        XCTAssertEqual(replacement.title,donor.title);XCTAssertEqual(replacement.sourceURL,donor.sourceURL)
        XCTAssertEqual(replacement.requiredLeadMinutes,90);XCTAssertNil(replacement.remainingElapsedMinutes)
        XCTAssertFalse(replacement.advanceStepsCompleted);XCTAssertNil(replacement.template)
        XCTAssertEqual(replacement.needs.first?.groupId,group);XCTAssertEqual(replacement.needs.first?.quantity,donor.needs.first?.quantity)
        XCTAssertEqual(replacement.needs.first?.matchedSourceIds,[]);XCTAssertEqual(replacement.needs.first?.notes,donor.needs.first?.notes)
        var incompatible=donor;incompatible.portions=3;XCTAssertNil(SharedRecoveryDraft.repeated(incompatible,for:target))
        incompatible=donor;incompatible.groups[0].servings = .init(numerator:9);XCTAssertNil(SharedRecoveryDraft.repeated(incompatible,for:target))
    }

    func testEffectiveCookTextUsesRecoveredIngredientAndBothRealRevisionsInEachLanguage() throws {
        let deadline = SharedMealDeadline(at: "2026-11-01T06:30:00Z", zone: "America/New_York")
        var raw = meal("Sopa revisada",group,ingredient:"Black beans")
        raw["day"] = "2026-11-01"; raw["due"] = deadline.at; raw["zone"] = deadline.zone
        var needs = try XCTUnwrap(raw["needs"] as? [Object])
        needs[0]["due"] = deadline.at
        raw["needs"] = needs
        let page=try record(rows:[raw]);let meal=page.meals[0],need=meal.needs[0]
        func f(_ n:String,_ d:String="1")->Object { ["numerator":n,"denominator":d] }
        let row:Object=["occurrenceId":meal.id.uuidString,"mealRevision":2,"needId":need.id.uuidString,"ingredientId":need.ingredientId.uuidString,
                        "groupIds":[group.uuidString],"protected":false,"required":q(7,3),"covered":f("2"),"missing":f("1","3"),
                        "delivered":f("0"),"pantry":f("0"),"freezer":f("2"),"reservations":[],"issues":[],
                        "allocations":[["sourceId":source.uuidString,"amount":f("2"),"kind":"freezer"] as Object]]
        let snapshot=try decode(SharedRecoveryCoverage.self,base.merging(["shopId":shop.uuidString,"placedRevision":3,"asOf":time,"needs":[row],"unplannedOccurrenceIds":[]]) { _,new in new })
        let sealedMeal:Object=["title":"Original wraps","kind":"dinner","day":meal.day.map { $0 as Any } ?? NSNull(),"portions":4,"protected":false,
                               "planning":["groups":[],"ingredients":[],"deadline":["at":deadline.at,"zone":deadline.zone]] as Object]
        let delivery=try decode(SharedDeliveryPage.self,base.merging(["shopId":shop.uuidString,"coverageAvailable":true,"reservationsAvailable":true,
            "lines":[],"sources":[],"meals":[["occurrenceId":meal.id.uuidString,"revision":2,"meal":sealedMeal] as Object]]) { _,new in new })
        let sealed=try XCTUnwrap(delivery.meals?.first)
        let current=SharedCookCoverage.recovered(page,snapshot,meal)
        for lang in ["en-US","es-US"] {
            let text=try XCTUnwrap(SharedDeliveryCookDraft.make(page:delivery, report:current, occurrence:sealed, language:lang))
            for value in ["Sopa revisada","Dinner plates","Black beans","no sesame","Beans from freezer","1/3",meal.revisionId.uuidString,"UTC"] { XCTAssertTrue(text.contains(value),value) }
            XCTAssertTrue(text.contains(lang == "en-US" ? "Covered by freezer stock: 2 cups" : "Cubierto por el congelador: 2 tazas"))
            let line = try XCTUnwrap(text.split(separator: "\n").first(where: { $0.contains("America/New_York") }))
            XCTAssertTrue(line.contains("1:30") && line.contains("UTC−05:00"), String(line))
            let date = try XCTUnwrap(line.range(of: "1:30").map { String(line[..<$0.lowerBound]) })
            XCTAssertTrue(date.contains(lang == "en-US" ? "November" : "noviembre"), date)
            XCTAssertNotNil(date.range(of: #"\b1\b"#, options: .regularExpression), date)
            XCTAssertTrue(date.contains("2026"), date)
            XCTAssertFalse(text.contains("Original wraps"))
            XCTAssertFalse(text.contains("Original prep completed"))

        }
        let unchanged=try record(rows:[raw],originalHeads:true)
        let untouched=try XCTUnwrap(SharedDeliveryCookDraft.make(page:delivery,report:.recovered(unchanged,snapshot,meal),occurrence:sealed,language:"en-US"))
        XCTAssertTrue(untouched.contains("Original prep completed"))
        var wrong=meal;wrong.revisionId=UUID()
        XCTAssertNil(SharedDeliveryCookDraft.make(page:delivery,report:.recovered(page,snapshot,wrong),occurrence:sealed,language:"en-US"))
    }
}
