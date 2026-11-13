import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testJointFoodCoverageEnforcesPhysicalTotalCategoryAndSealedRequirements() throws {
        let shop = UUID(), meal = UUID(), ingredient = UUID(), batch = UUID(), observation = UUID()
        let groups = [UUID(), UUID()]
        let date = "2026-11-07T08:00:00Z"
        func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
        }
        func q(_ n: Int) -> [String: Any] { ["unit":"count","originalLiteral":String(n),"amount":["numerator":n,"denominator":1]] }
        func fraction(_ n: Int) -> [String: String] { ["numerator":String(n),"denominator":"1"] }
        let target: [String: Any] = ["occurrenceId":meal.uuidString, "mealRevision":1, "ingredientId":ingredient.uuidString]
        let plan: [String: Any] = [
            "groups":groups.map { ["id":$0.uuidString, "name":"Lunch", "protected":true, "servings":["numerator":1,"denominator":1]] },
            "ingredients":[["id":ingredient.uuidString,"name":"Beans","quantity":q(4),"groupIds":groups.map(\.uuidString),"exclusions":[]] as [String:Any]],
            "bindings":groups.map { ["id":UUID().uuidString, "ingredientId":ingredient.uuidString, "groupId":$0.uuidString, "quantity":q(2)] }]
        var scope: [String: Any] = ["shopId":shop.uuidString,"shopRevision":3,"placedRevision":2,"authorityEpoch":1,"supplyRevision":0]
        var deliveryJSON = scope
        deliveryJSON["meals"] = [["occurrenceId":meal.uuidString,"revision":1,
            "meal":["title":"Lunch","kind":"lunch","day":"2026-11-07","protected":false,"portions":4,"planning":plan]]]
        deliveryJSON["sources"] = []; deliveryJSON["lines"] = []
        let delivery = try decode(SharedDeliveryPage.self, deliveryJSON)
        scope["pantryRevision"] = 4; scope["asOf"] = date
        var lot: [String: Any] = ["lotId":batch.uuidString,"origin":"manual","location":"freezer","storedAt":NSNull(),"useFirstAt":NSNull(),
            "foodName":"Beans","exclusionTags":[],"selected":true,"matches":[target],"reservations":[],
            "observation":["observationId":observation.uuidString,"confirmedAt":date,"quantity":q(3)]]
        func pantry() throws -> SharedPantryPage {
            var page = scope; page["lots"] = [lot]; page["nextCursor"] = NSNull()
            return try decode(SharedPantryPage.self, page)
        }
        func row(_ group: UUID, _ n: Int, kind: String = "freezer") -> [String: Any] {
            var value = target
            value["groupIds"] = [group.uuidString]; value["required"] = q(2); value["protected"] = true
            value["allocations"] = [["sourceId":batch.uuidString,"amount":fraction(n),"kind":kind]]
            value["covered"] = fraction(n); value["missing"] = fraction(2-n)
            value["delivered"] = fraction(0); value["pantry"] = fraction(0); value["freezer"] = fraction(n)
            value["reservations"] = []; value["issues"] = []
            return value
        }
        func coverage(_ rows: [[String: Any]]) throws -> SharedFoodCoverage {
            var report = scope
            report["unplannedOccurrenceIds"] = []; report["needs"] = rows
            return try decode(SharedFoodCoverage.self, report)
        }
        func validate(_ rows: [[String: Any]]) throws {
            try coverage(rows).validate(reviewed: pantry(), delivery: delivery)
        }
        let first = row(groups[0], 2), second = row(groups[1], 1)
        try validate([first, second])
        XCTAssertThrowsError(try validate([first, row(groups[1], 2)]), "Allocated four from the same lot of three")
        XCTAssertThrowsError(try validate([first, row(groups[1], 1, kind:"delivery")]))
        XCTAssertThrowsError(try validate([first]))
        var wrong = second; wrong["pantry"] = fraction(1)
        XCTAssertThrowsError(try validate([first, wrong]))
        wrong = second; wrong["missing"] = fraction(0)
        XCTAssertThrowsError(try validate([first, wrong]))
        let before = try coverage([first, second]), reviewedLot = try XCTUnwrap(pantry().lots.first)
        func impact(for row: [String: Any]) -> [String: Any] {
            var fields = target
            for key in ["groupIds", "required"] { fields[key] = row[key] }
            fields["beforeCovered"] = row["covered"]; fields["beforeMissing"] = row["missing"]
            fields["afterCovered"] = fraction(0); fields["afterMissing"] = fraction(2)
            fields["beforeReservations"] = []; fields["afterReservations"] = []
            return fields
        }
        var preview = scope
        preview["lotId"] = batch.uuidString; preview["previewDigest"] = String(repeating: "0", count: 64)
        preview["otherShopsAffected"] = false; preview["otherShopsCommitted"] = true
        func validatePreview(_ rows: [[String: Any]]) throws {
            preview["needs"] = rows
            try decode(SharedPantryObservationPreview.self, preview).validate(lot: reviewedLot, coverage: before)
        }
        let changes = [impact(for: first), impact(for: second)]
        try validatePreview(changes)
        XCTAssertThrowsError(try validatePreview([changes[0]]), "Preview omitted a matched group")
        var altered = changes; altered[0]["beforeCovered"] = fraction(0)
        XCTAssertThrowsError(try validatePreview(altered))
        preview["pantryRevision"] = 5
        XCTAssertThrowsError(try validatePreview(changes))
        lot["selected"] = false
        XCTAssertThrowsError(try validate([first, second]))
        lot["selected"] = true
        lot["observation"] = ["observationId":observation.uuidString, "confirmedAt":"2030-01-01T00:00:00Z", "quantity":q(3)] as [String:Any]
        XCTAssertThrowsError(try validate([first, second]), "A later confirmation cannot supply today's reviewed page")
        lot["observation"] = ["observationId":observation.uuidString, "confirmedAt":date, "quantity":NSNull()] as [String:Any]
        XCTAssertThrowsError(try validate([first, second]))
    }

    func testPantryReceiptRequiresSameLotOriginalShopAndBothCounters() throws {
        let shop = UUID().uuidString.lowercased(), lot = UUID().uuidString.lowercased()
        let op = UUID().uuidString.lowercased(), base = CommandBase(shopRevision: 3, authorityEpoch: 1)
        func command(_ kind: String, _ extras: [String: JSONValue]) -> CommandEnvelope {
            .init(replayWindow: "saved", shopId: shop, kind: kind, base: base,
                  body: extras.merging(["pantryRevision":.integer(7),"supplyRevision":.integer(2)]) { $1 })
        }
        var receipt: [String: Any] = ["shopId":shop,"kind":"pantry.observe","operationId":op,"lotId":lot,
            "shopRevision":3,"authorityEpoch":1,"pantryRevision":8,"supplyRevision":2,"disposition":"recorded"]
        func check(_ command: CommandEnvelope, _ values: [String:Any]) throws {
            try JSONDecoder().decode(ShopperReceipt.self, from: JSONSerialization.data(withJSONObject: values)).validatePantry(command)
        }
        let observe = command("pantry.observe", ["lotId":.string(lot),"predecessorId":.null])
        try check(observe, receipt)
        for (key, value): (String, Any) in [("pantryRevision", 9), ("supplyRevision",3), ("authorityEpoch",2), ("shopId",UUID().uuidString),
                                            ("lotId",UUID().uuidString), ("disposition","recordedElsewhere")] {
            var tampered = receipt; tampered[key] = value
            XCTAssertThrowsError(try check(observe, tampered))
        }
        receipt["kind"] = "pantry.create"
        XCTAssertThrowsError(try check(command("pantry.create", [:]), receipt))
        receipt["lotId"] = op
        try check(command("pantry.create", [:]), receipt)
        receipt["kind"] = "pantry.storeDelivery"; receipt["lotId"] = lot
        try check(command("pantry.storeDelivery", ["sourceId":.string(lot)]), receipt)
    }

    func testFoodFractionsRetainArbitraryPrecisionThroughAdditionAndConversion() throws {
        typealias Fraction = SharedDeliveryCoverage.Fraction
        let n = "10000000000000000000000000000000000000000000000000000000000001"
        let scale = Fraction(numerator:"3",denominator:"7")
        let thirds = Fraction(numerator:n,denominator:"3")
        let sixths = Fraction(numerator:n,denominator:"6")
        XCTAssertEqual(thirds.adding(sixths).compare(.init(numerator:n,denominator:"2")), .orderedSame)
        XCTAssertEqual(thirds.multiplied(by:scale).compare(.init(numerator:n,denominator:"7")), .orderedSame)
        XCTAssertEqual(thirds.adding(.zero).compare(thirds), .orderedSame)
    }
}
