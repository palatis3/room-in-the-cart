import XCTest
@testable import HouseholdClient

final class SharedOperationUndoCreationTests: XCTestCase {
    private func fixture() throws -> ([String: Any], SharedOperationUndoCandidate, ShopperShop, SharedDemandMealEdit) {
        let f = try OperationUndoFixture.mealObject()
        let candidate: SharedOperationUndoCandidate = try OperationUndoFixture.decode(f["candidate"]!)
        var raw = (f["candidate"] as! [String: Any])["mealUndo"] as! [String: Any]
        let added = raw["restoredMeal"]!
        raw["targetBefore"] = ["revision": NSNull(), "meal": NSNull()]
        raw["targetAfter"] = ["revision": 5, "meal": added]
        raw["current"] = raw["targetAfter"]
        raw["restoredMeal"] = NSNull()
        var shop = f["shop"] as! [String: Any]
        var meals = shop["meals"] as! [[String: Any]]
        meals.append(["occurrenceId": raw["occurrenceId"]!, "revision": 5, "meal": added]); shop["meals"] = meals
        let edit: SharedDemandMealEdit = try OperationUndoFixture.decode(["occurrenceId": raw["occurrenceId"]!, "baseMealRevision": 5, "meal": NSNull()])
        return (raw, candidate, try OperationUndoFixture.decode(shop), edit)
    }
    func testCreationAbsenceAndRemovalRoundtripAsExplicitNull() throws {
        let (raw, candidate, shop, edit) = try fixture()
        let meal: SharedOperationUndoMeal = try OperationUndoFixture.decode(raw)
        try meal.validate(scope: candidate.scope, base: candidate.base, shop: shop, edit: edit)
        XCTAssertNil(meal.targetBefore.revision); XCTAssertNil(meal.targetBefore.meal); XCTAssertNil(meal.restoredMeal)
        let encoded = try JSONEncoder().encode(meal)
        XCTAssertEqual(try JSONDecoder().decode(SharedOperationUndoMeal.self, from: encoded), meal)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), try OperationUndoFixture.decode(raw, as: JSONValue.self))
        let action = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as! [String: Any]
        XCTAssertTrue(action["meal"] is NSNull); XCTAssertEqual(action["baseMealRevision"] as? Int, 5)
    }
    func testMissingAbsenceOrRemovalKeysNeverMeanNull() throws {
        let (original, _, _, _) = try fixture()
        for key in ["revision", "meal", "restoredMeal"] {
            var raw = original
            if key == "restoredMeal" { raw.removeValue(forKey: key) }
            else { var before = raw["targetBefore"] as! [String: Any]; before.removeValue(forKey: key); raw["targetBefore"] = before }
            XCTAssertThrowsError(try OperationUndoFixture.decode(raw, as: SharedOperationUndoMeal.self))
        }
    }
    func testCompleteCreationCandidateAndCommandActionPreserveExplicitRemoval() throws {
        let (meal, original, _, edit) = try fixture()
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var action = raw["action"] as! [String: Any], body = action["body"] as! [String: Any]
        body["mealEdit"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit))
        action["body"] = body; raw["action"] = action; raw["mealUndo"] = meal
        let candidate: SharedOperationUndoCandidate = try OperationUndoFixture.decode(raw)
        let bytes = try JSONEncoder().encode(candidate)
        XCTAssertEqual(try JSONDecoder().decode(SharedOperationUndoCandidate.self, from: bytes), candidate)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bytes), try OperationUndoFixture.decode(raw, as: JSONValue.self))
        let command = candidate.action.commandAction
        let commandBytes = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(SharedDemandAction.self, from: commandBytes), command)
        let values = try command.bodyValues()
        guard case .object(let removal) = values["mealEdit"] else { return XCTFail("Missing meal removal command") }
        XCTAssertEqual(removal["meal"], .null)
        XCTAssertNotNil(removal["baseMealRevision"])
        XCTAssertEqual(removal["occurrenceId"], .string(edit.occurrenceId.string))
    }
    func testCreationCannotMasqueradeAsTombstoneOrLaterEdit() throws {
        let (original, _, _, _) = try fixture()
        for kind in 0..<4 {
            var raw = original
            if kind == 0 { raw["targetBefore"] = ["revision": 4, "meal": NSNull()] }
            if kind == 1 { var now = raw["current"] as! [String: Any]; now["revision"] = 6; raw["current"] = now }
            if kind == 2 { raw["targetAfter"] = ["revision": NSNull(), "meal": NSNull()] }
            if kind == 3 { raw["touchedFields"] = ["title"] }
            XCTAssertThrowsError(try OperationUndoFixture.decode(raw, as: SharedOperationUndoMeal.self))
        }
    }
    func testCreationRemovalStillRejectsProtectedMeal() throws {
        var (raw, candidate, shop, edit) = try fixture()
        var fact = raw["current"] as! [String: Any], added = fact["meal"] as! [String: Any]
        added["protected"] = true; fact["meal"] = added; raw["current"] = fact; raw["targetAfter"] = fact
        var shopRaw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shop)) as! [String: Any]
        var meals = shopRaw["meals"] as! [[String: Any]]; meals[meals.count - 1]["meal"] = added; shopRaw["meals"] = meals
        shop = try OperationUndoFixture.decode(shopRaw)
        let meal: SharedOperationUndoMeal = try OperationUndoFixture.decode(raw)
        XCTAssertThrowsError(try meal.validate(scope: candidate.scope, base: candidate.base, shop: shop, edit: edit))
    }
}
