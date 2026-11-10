#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation

extension OperationUndoUIFacts {
    /// Fixed, eligible creation on an already tracked shop; never a generic inverse.
    /// Reuses the synthetic lunch/staple vocabulary, not the skipped-meal action.
    static func creationObject() throws -> [String: Any] {
        var f = try mealObject()
        var candidate = f["candidate"] as! [String: Any], response = f["response"] as! [String: Any]
        var evidence = candidate["mealUndo"] as! [String: Any]
        let occurrence = evidence["occurrenceId"] as! String
        var meal = evidence["restoredMeal"] as! [String: Any]
        meal["title"] = "Added taco dinner"
        let current: [String: Any] = ["revision": 5, "meal": meal]
        evidence["targetBefore"] = ["revision": NSNull(), "meal": NSNull()]
        evidence["targetAfter"] = current; evidence["current"] = current
        evidence["restoredMeal"] = NSNull()

        // Current demand is ten wraps; removing this six-wrap dinner leaves four.
        // Protected lunch, manual breakfast and later apples keep every field.
        var before = candidate["after"] as! [String: Any]
        var after = candidate["before"] as! [String: Any]
        before["revision"] = 3; after["revision"] = 4
        let beforeTotals = candidate["afterTotals"]!, afterTotals = candidate["beforeTotals"]!
        let beforeCheckout = candidate["afterCheckout"]!, afterCheckout = candidate["beforeCheckout"]!
        let active = (before["contributions"] as! [[String: Any]])[2]
        var removed = active; removed["removedAt"] = "2026-11-09T12:10:00Z"
        var sources = after["contributions"] as! [[String: Any]]; sources[2] = removed; after["contributions"] = sources

        var shop = f["shop"] as! [String: Any]
        let finalLines = shop["lines"]!
        let oldAction = candidate["action"] as! [String: Any], oldBody = oldAction["body"] as! [String: Any]
        shop["lines"] = oldBody["lines"]!
        var meals = shop["meals"] as! [[String: Any]]
        meals.append(["occurrenceId": occurrence, "revision": 5, "meal": meal])
        meals.append(["occurrenceId": "00000000-0000-4000-8000-000000000061", "revision": 6,
            "meal": ["title": "Later independent soup", "day": NSNull(), "kind": "dinner", "portions": 2, "protected": false] as [String: Any]])
        shop["meals"] = meals; f["shop"] = shop
        let action: [String: Any] = ["kind": "shop.patch", "body": ["quote": shop["quote"]!, "lines": finalLines,
            "mealEdit": ["occurrenceId": occurrence, "baseMealRevision": 5, "meal": NSNull()]]]
        let values: [String: Any] = ["action": action, "before": before, "after": after,
            "beforeTotals": beforeTotals, "afterTotals": afterTotals, "beforeCheckout": beforeCheckout,
            "afterCheckout": afterCheckout, "mealUndo": evidence]
        for (key, value) in values { candidate[key] = value; response[key] = value }
        var receipt = response["receipt"] as! [String: Any]
        receipt["contributions"] = [["id": active["id"]!, "before": active, "after": removed]]
        response["receipt"] = receipt
        var page = f["page"] as! [String: Any]; page["graph"] = before; page["totals"] = beforeTotals
        f["page"] = page; f["candidate"] = candidate; f["response"] = response
        return f
    }
}
#endif
