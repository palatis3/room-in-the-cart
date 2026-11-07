#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import CryptoKit
import Foundation
import HouseholdClient

/// Two placed meals with known requirements and no confirmed food. The shopper
/// can commit only the exact unresolved dinner they reviewed on this device.
final class SharedMealRecoveryFixture {
    typealias Row = [String: Any]
    typealias Failure = SharedDeliveryFixtureRecords.CookFailure
    private let null = NSNull()
    private(set) var revision = 0
    private var replacement: Row?
    private var previews: [String: (Data, String)] = [:]

    private func uuid(_ value: Int) -> String { String(format: "eeeeeeee-eeee-4eee-8eee-%012d", value) }
    private func date(_ value: Date = Date()) -> String {
        value.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }
    private func quantity(_ count: Int) -> Row {
        ["amount": ["numerator": count, "denominator": 1], "unit": "count", "originalLiteral": String(count)]
    }
    private func original(_ index: Int) -> Row {
        let tuesday = index == 1, count = tuesday ? 2 : 4
        let due = tuesday ? "2026-11-10T20:15:00Z" : "2026-11-11T23:30:00Z"
        let zone = tuesday ? "America/Los_Angeles" : "America/New_York"
        let group: Row = ["id": uuid(10 + index), "name": tuesday ? "Protected lunch" : "Dinner plates",
                          "servings": ["numerator": count, "denominator": 1], "protected": tuesday, "exclusions": []]
        let need: Row = ["id": uuid(20 + index), "foodId": null, "matchedSourceIds": [], "ingredientId": uuid(30 + index),
                         "groupId": uuid(10 + index), "name": tuesday ? "Tuesday tortillas" : "Wednesday beans", "notes": "",
                         "quantity": quantity(count), "priority": tuesday ? "protected" : "required", "due": due, "exclusions": ["No sesame"]]
        return ["occurrenceId": uuid(index), "revisionId": uuid(40 + index), "sourceMealRevision": 1,
                "title": tuesday ? "Tuesday lunch" : "Wednesday dinner", "notes": "", "sourceURL": null,
                "portions": count, "day": tuesday ? "2026-11-10" : "2026-11-11", "zone": zone, "due": due,
                "exclusions": ["No sesame"], "template": null, "groups": [group], "needs": [need],
                "remainingElapsedMinutes": null, "requiredLeadMinutes": null, "advanceStepsCompleted": false]
    }
    var sealedMeals: [Row] {
        (1...2).map { index in
            let source = original(index), tuesday = index == 1
            var group = (source["groups"] as! [Row])[0]
            group.removeValue(forKey: "exclusions")
            let ingredient: Row = ["id": uuid(30 + index), "name": tuesday ? "Tuesday tortillas" : "Wednesday beans",
                                   "quantity": quantity(tuesday ? 2 : 4), "groupIds": [uuid(10 + index)], "exclusions": ["No sesame"]]
            let plan: Row = ["groups": [group], "ingredients": [ingredient], "exclusions": ["No sesame"],
                             "deadline": ["at": source["due"]!, "zone": source["zone"]!]]
            return ["occurrenceId": uuid(index), "revision": 1, "meal": ["title": source["title"]!, "day": source["day"]!,
                    "kind": tuesday ? "lunch" : "dinner", "portions": source["portions"]!, "protected": tuesday, "planning": plan]]
        }
    }
    private var meals: [Row] { [original(1), replacement ?? original(2)] }
    func version(of occurrence: String) -> String? {
        let meal = meals.first { ($0["occurrenceId"] as? String)?.lowercased() == occurrence }
        return (meal?["revisionId"] as? String)?.lowercased()
    }

    var replacedOccurrence: String? { (replacement?["occurrenceId"] as? String)?.lowercased() }

    private var base: [String: Int] {
        ["shopRevision": 2, "authorityEpoch": 1, "recoveryRevision": revision, "supplyRevision": revision,
         "pantryRevision": revision, "contextRevision": revision]
    }
    private func bytes(_ row: Row) throws -> Data { try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) }
    private func digest(_ meal: Row) throws -> String {
        try JSONDecoder().decode(SharedRecoveryMeal.self, from: bytes(meal)).targetDigest()
    }

    func desk(shop: String) throws -> Row {
        let targets: [Row] = try meals.map { ["occurrenceId": $0["occurrenceId"]!, "digest": try digest($0)] }
        let sources: [Row] = (1...2).map { ["occurrenceId": uuid($0), "sourceMealRevision": 1, "sealedRevisionId": uuid(40 + $0),
                                              "completedSteps": [], "sourceOccurrenceId": null, "approvedIdea": null] }
        return ["shopId": shop, "placedRevision": 1, "asOf": date(), "base": base, "meals": meals, "targetDigests": targets,
                "sourceOptions": [], "mealSources": sources, "unplannedOccurrenceIds": [], "commitmentInventoryComplete": true]
    }
    private let zero = ["numerator": "0", "denominator": "1"]
    private func demands(_ meals: [Row]) throws -> [Row] {
        try meals.flatMap { try ($0["needs"] as? [Row] ?? []).map { need -> Row in
            guard let q = need["quantity"] as? Row, let amount = q["amount"] as? [String: Int], let unit = q["unit"],
                  let n = amount["numerator"], let d = amount["denominator"], let id = need["id"],
                  let due = need["due"] as? String, let deadline = ISO8601DateFormatter().date(from: due) else { throw Failure.invalid }
            return ["needId": id, "due": due, "deadlineStatus": deadline < Date() ? "pastDue" : "notPastDue", "allocated": zero, "shortfall": ["numerator": String(n), "denominator": String(d)],
                    "unit": unit, "issues": ["unknown_food"], "sourceIssues": [], "reservations": []]
        }}
    }
    func coverage(shop: String) throws -> Row {
        var rows: [Row] = []
        for meal in meals {
            for (need, demand) in zip(meal["needs"] as? [Row] ?? [], try demands([meal])) {
                rows.append(["needId": need["id"]!, "occurrenceId": meal["occurrenceId"]!, "ingredientId": need["ingredientId"]!,
                             "mealRevision": 1, "groupIds": [need["groupId"]!], "required": need["quantity"]!,
                             "protected": need["priority"] as? String == "protected", "covered": zero, "missing": demand["shortfall"]!,
                             "delivered": zero, "pantry": zero, "freezer": zero, "allocations": [], "reservations": [], "issues": ["noMatch"]])
            }
        }
        return (base as Row).merging(["shopId": shop, "placedRevision": 1, "asOf": date(), "needs": rows, "unplannedOccurrenceIds": []]) { _, next in next }
    }
    func preview(shop: String, input: Row) throws -> Row {
        guard input["base"] as? [String: Int] == base, let intent = input["intent"] as? Row,
              (intent["occurrenceId"] as? String)?.lowercased() == uuid(2), let next = intent["replacement"] as? Row,
              try intent["targetDigest"] as? String == digest(meals[1]) else { throw Failure.staleSupply }
        let before: Row = ["meals": meals, "demands": try demands(meals), "allocations": []]
        let prospective = [meals[0], next]
        let after: Row = ["meals": prospective, "demands": try demands(prospective), "allocations": []]
        let id = UUID().uuidString.lowercased(), data = try bytes(input)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let accepted = intent["acceptsUnresolved"] as? Bool == true &&
            (intent["proposesExtraTrip"] as? Bool != true || intent["agreesToExtraTrip"] as? Bool == true)
        if accepted { previews[id] = (data, digest) }
        return ["shopId": shop, "placedRevision": 1, "asOf": date(), "base": base, "previewId": id,
                "expiresAt": date(Date().addingTimeInterval(600)), "previewDigest": digest,
                "before": before, "after": after, "foodConfirmed": false, "timingConfirmed": false,
                "repeatRequired": false, "feasible": false, "consentSatisfied": accepted]
    }
    func apply(shop: String, body: Row) throws -> Row {
        var request = body
        guard let id = (request.removeValue(forKey: "previewId") as? String)?.lowercased(),
              let digest = request.removeValue(forKey: "previewDigest") as? String, let approved = previews[id],
              approved.1 == digest, try approved.0 == bytes(request), request["base"] as? [String: Int] == base,
              let intent = request["intent"] as? Row, let next = intent["replacement"] as? Row else { throw Failure.staleSupply }
        replacement = next
        revision += 1
        previews.removeAll()
        return ["kind": "mealRecovery.apply", "operationId": UUID().uuidString.lowercased(), "shopId": shop, "shopRevision": 2,
                "authorityEpoch": 1, "disposition": "recorded", "recoveryRevision": revision,
                "occurrenceId": next["occurrenceId"]!, "revisionId": next["revisionId"]!]
    }
}
#endif
