#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI

struct SharedDeliveryFixtureRoot: View {
    @State private var shopper: HouseholdModel?
    @State private var failed = false
    var body: some View {
        Group {
            if let shopper { NavigationStack { HouseholdShopView(model: shopper) } }
            else if failed { Text(verbatim: "Fixture sign-in failed") }
            else { ProgressView() }
        }.task {
            do { shopper = try await S17FixtureState.recoveryShopper() }
            catch { failed = true }
        }
    }
}

/// Deterministic HTTP responses for the iPhone controls. The pinned HTTPS suite
/// exercises these same Swift commands against the real service and PostgreSQL.
final class SharedDeliveryFixtureRecords {
    private var revision = 0
    private var source: [String:Any]?
    private var receipts: [String:[String:Any]] = [:]
    private let line = "66666666-6666-4666-8666-666666666666"

    private let occurrence = "aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let ingredient = "aaaaaaa2-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let group = "aaaaaaa3-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private var matches: [[String:Any]] = []

    func page(shop: String) -> [String:Any] {
        let quantity: [String:Any] = ["amount":["numerator":2,"denominator":1], "unit":"count","originalLiteral":"2"]
        let plan: [String:Any] = ["groups":[["id":group,"name":"School lunch","servings":["numerator":2,"denominator":1],"protected":true]],
            "ingredients":[["id":ingredient,"name":"Tortillas","quantity":quantity,"groupIds":[group],"exclusions":["sesame"]]]]
        let meal: [String:Any] = ["title":"Lunch wraps","day":"2026-11-08","kind":"lunch","portions":2,"protected":true,"planning":plan]
        return ["shopId":shop, "meals":[["occurrenceId":occurrence,"revision":1,"meal":meal]], "placedRevision":1, "shopRevision":2, "authorityEpoch":1, "supplyRevision":revision,
         "lines":[["lineId":line,"name":"Ordered wraps"]], "sources":source.map { [$0] } ?? [], "nextCursor":NSNull()]
    }
    func record(shop: String, command: [String:Any]) throws -> [String:Any] {
        guard let key = command["clientKey"] as? String, let kind = command["kind"] as? String,
              let body = command["body"] as? [String:Any] else { throw URLError(.badServerResponse) }
        if let receipt = receipts[key] { return receipt }
        guard body["supplyRevision"] as? Int == revision else { throw URLError(.badServerResponse) }
        let op = UUID().uuidString.lowercased()
        switch kind {
        case "delivery.register":
            guard source == nil, body["lineId"] as? String == line, let food = body["foodName"] as? String,
                  let tags = body["exclusionTags"] as? [String], let segment = body["segmentKey"] as? String else { throw URLError(.badServerResponse) }
            source = ["sourceId":op,"foodId":op,"lineId":line,"segmentKey":segment,"foodName":food,"exclusionTags":tags,
                      "matches":matches,"arrival":NSNull(),"usable":NSNull(),"confirmed":NSNull()]
        case "delivery.match":
            guard body["occurrenceId"] as? String == occurrence, body["mealRevision"] as? Int == 1,
                  body["ingredientId"] as? String == ingredient, let matched = body["matched"] as? Bool,
                  source?["sourceId"] as? String == body["sourceId"] as? String else { throw URLError(.badServerResponse) }
            matches = matched ? [["occurrenceId":occurrence,"mealRevision":1,"ingredientId":ingredient]] : []
            source?["matches"] = matches
        case "delivery.arrival":
            source?["arrival"] = body; source?["confirmed"] = NSNull()
        case "delivery.usable":
            guard let arrival = source?["arrival"] as? [String:Any], let a = arrival["observationId"] as? String,
                  a == body["arrivalObservationId"] as? String, let u = body["observationId"] as? String,
                  let id = source?["sourceId"] as? String else { throw URLError(.badServerResponse) }
            source?["usable"] = body
            if let q = body["usable"] as? [String:Any] {
                source?["confirmed"] = ["sourceId":id,"foodId":id,"quantity":q,"arrivalId":a,"usableId":u]
            } else { source?["confirmed"] = NSNull() }
        default: throw URLError(.badServerResponse)
        }
        guard let id = source?["sourceId"] as? String else { throw URLError(.badServerResponse) }
        revision += 1
        let receipt: [String:Any] = ["kind":kind,"operationId":op,"shopId":shop,"shopRevision":2,"authorityEpoch":1,
            "disposition":"recorded","sourceId":id,"supplyRevision":revision]
        receipts[key] = receipt
        return receipt
    }
}
#endif
