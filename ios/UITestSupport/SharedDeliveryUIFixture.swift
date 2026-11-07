#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import CoreDomain
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
    let supportsCookCopies = ProcessInfo.processInfo.arguments.contains("--shared-cook-copies-fixture")
    private var copies: [[String:Any]] = [] // Newest first for the fixture's single placed meal.
    // PostgreSQL keys recipient labels by their exact UTF-8 spelling.
    private var recipientHeads: [Data:[String:Any]] = [:]
    private var recordedCommands: [String:Data] = [:]
    private var revision = 0
    private var source: [String:Any]?
    private var receipts: [String:[String:Any]] = [:]
    private let line = "66666666-6666-4666-8666-666666666666"

    private let occurrence = "aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let ingredient = "aaaaaaa2-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let group = "aaaaaaa3-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private var reservation: [String:Any]?
    private var matches: [[String:Any]] = []

    func page(shop: String) -> [String:Any] {
        let quantity: [String:Any] = ["amount":["numerator":2,"denominator":1], "unit":"count","originalLiteral":"2"]
        let plan: [String:Any] = ["exclusions":["peanuts"], "leadTimeMinutes":120, "completedSteps":["Beans soaked"],
            "groups":[["id":group,"name":"School lunch","servings":["numerator":2,"denominator":1],"protected":true]],
            "ingredients":[["id":ingredient,"name":"Tortillas","quantity":quantity,"groupIds":[group],"exclusions":["sesame"]]]]
        let meal: [String:Any] = ["title":"Lunch wraps","day":"2026-11-08","kind":"lunch","portions":2,"protected":true,"planning":plan]
        return ["shopId":shop, "coverageAvailable":true,"reservationsAvailable":true,"meals":[["occurrenceId":occurrence,"revision":1,"meal":meal]], "placedRevision":1, "shopRevision":2, "authorityEpoch":1, "supplyRevision":revision,
         "lines":[["lineId":line,"name":"Ordered wraps"]], "sources":source.map { [$0] } ?? [], "nextCursor":NSNull()]
    }
    func coverage(shop: String) throws -> [String:Any] {
        let required: [String:Any] = ["amount":["numerator":2,"denominator":1],"unit":"count","originalLiteral":"2"]
        let confirmed = source?["confirmed"] as? [String:Any]
        let q = confirmed?["quantity"] as? [String:Any]
        let amount = q?["amount"] as? [String:Int]
        let target = try Rational(2)
        var covered = Rational.zero
        var allocations = [[String:Any]]()
        func fraction(_ value: Rational) -> [String:String] {
            ["numerator":String(value.numerator),"denominator":String(value.denominator)]
        }
        if !matches.isEmpty, q?["unit"] as? String == "count", let amount,
           let numerator = amount["numerator"], let denominator = amount["denominator"], let id = source?["sourceId"] {
            covered = min(target, try Rational(Int64(numerator), Int64(denominator)))
            if covered > .zero { allocations = [["sourceId":id, "amount":fraction(covered)]] }
        }
        var issues = matches.isEmpty ? ["noMatch"] : []
        var reservations: [[String:Any]] = []
        if let reservation, let id = source?["sourceId"], let head = reservation["reservationId"],
           let q = reservation["quantity"] as? [String:Any], let amount = q["amount"] as? [String:Int],
           let n = amount["numerator"], let d = amount["denominator"] {
            let requested = try Rational(Int64(n), Int64(d))
            let backed = min(requested, covered)
            reservations = [["sourceId":id, "reservationId":head, "requested":fraction(requested), "backed":fraction(backed)]]
            if backed < requested { issues.append("reservationShortfall") }
        }
        let need: [String:Any] = ["occurrenceId":occurrence,"mealRevision":1,"ingredientId":ingredient,"groupIds":[group],
            "protected":true,"required":required,"covered":fraction(covered),"missing":fraction(try target.subtracting(covered)),"allocations":allocations,
            "issues":issues, "reservations":reservations]
        return ["shopId":shop,"shopRevision":2,"placedRevision":1,"authorityEpoch":1,"supplyRevision":revision,
                "asOf":"2026-11-07T12:00:00Z","unplannedOccurrenceIds":[],"needs":[need]]
    }
    enum CookFailure: Error { case invalid, staleBase, staleSupply, replayConflict }

    func cookCopies(occurrenceID: String?, cursor: String?) throws -> [String:Any] {
        guard supportsCookCopies, occurrenceID?.lowercased() == occurrence else { throw CookFailure.invalid }
        let start: Int
        if let cursor {
            guard let index = copies.firstIndex(where: { $0["copyId"] as? String == cursor.lowercased() }) else { throw CookFailure.invalid }
            start = index + 1
        } else { start = 0 }
        let page = Array(copies.dropFirst(start).prefix(20))
        let next = start + page.count < copies.count ? page.last?["copyId"] : nil
        return ["copies":page,"nextCursor":next ?? NSNull()]
    }

    private func recipient(_ body: [String:Any]) throws -> String {
        guard let raw = body["recipient"] as? String else { throw CookFailure.invalid }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CookFailure.invalid }
        return name
    }

    func cookBaseline(_ body: [String:Any]) throws -> [String:Any] {
        guard supportsCookCopies, (body["occurrenceId"] as? String)?.lowercased() == occurrence else { throw CookFailure.invalid }
        let name = try recipient(body)
        guard let send = recipientHeads[Data(name.utf8)], let id = send["copyId"] as? String,
              let copy = copies.first(where: { $0["copyId"] as? String == id }) else { return ["baseline":NSNull()] }
        return ["baseline":["copy": copy, "send": send]]
    }

    private func recordCook(shop: String, kind: String, base: [String:Any]?, body: [String:Any]) throws -> [String:Any] {
        guard supportsCookCopies, base?["shopRevision"] as? Int == 2, base?["authorityEpoch"] as? Int == 1 else {
            throw CookFailure.staleBase
        }
        let copyID: String, operation = UUID().uuidString.lowercased(), at = ISO8601DateFormatter().string(from: Date())
        switch kind {
        case "cookCopy.save":
            guard body["placedRevision"] as? Int == 1, body["supplyRevision"] as? Int == revision else { throw CookFailure.staleSupply }
            guard (body["occurrenceId"] as? String)?.lowercased() == occurrence, body["mealRevision"] as? Int == 1,
                  let language = body["language"] as? String, ["en","es"].contains(language),
                  let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CookFailure.invalid }
            copyID = operation
            let copy: [String:Any] = ["copyId":copyID,"occurrenceId":occurrence,"mealRevision":1,"shopId":shop,"shopRevision":2,
                                      "placedRevision":1,"authorityEpoch":1,"supplyRevision":revision,"language":language,
                                      "text":text,"version":copies.count + 1,"createdAt":at]
            copies.insert(copy, at: 0)
        case "cookCopy.markSent":
            guard let id = (body["copyId"] as? String)?.lowercased(), copies.contains(where: { $0["copyId"] as? String == id }),
                  let previous = body["previousSendId"], previous is NSNull || previous is String else { throw CookFailure.invalid }
            let name = try recipient(body)
            guard (previous as? String)?.lowercased() == recipientHeads[Data(name.utf8)]?["sendId"] as? String else { throw CookFailure.staleBase }
            copyID = id
            recipientHeads[Data(name.utf8)] = ["sendId":operation,"copyId":copyID,"recipient":name,"sentAt":at]
        default: throw CookFailure.invalid
        }
        return ["kind":kind,"operationId":operation,"shopId":shop,"shopRevision":2,"authorityEpoch":1,
                "disposition":"recorded","copyId":copyID]
    }

    func record(shop: String, command: [String:Any]) throws -> [String:Any] {
        guard let key = command["clientKey"] as? String, let kind = command["kind"] as? String,
              let body = command["body"] as? [String:Any] else { throw URLError(.badServerResponse) }
        let bytes = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        if let receipt = receipts[key] {
            guard recordedCommands[key] == bytes else { throw CookFailure.replayConflict }
            return receipt
        }
        if kind.hasPrefix("cookCopy.") {
            guard command["v"] as? Int == 1, command["shopId"] as? String == shop,
                  command["replayWindow"] as? String == "77777777-7777-4777-8777-777777777777" else { throw CookFailure.invalid }
            let receipt = try recordCook(shop: shop, kind: kind, base: command["base"] as? [String:Any], body: body)
            recordedCommands[key] = bytes
            receipts[key] = receipt
            return receipt
        }
        guard body["supplyRevision"] as? Int == revision else { throw URLError(.badServerResponse) }
        let op = UUID().uuidString.lowercased()
        switch kind {
        case "delivery.register":
            guard source == nil, body["lineId"] as? String == line, let food = body["foodName"] as? String,
                  let tags = body["exclusionTags"] as? [String], let segment = body["segmentKey"] as? String else { throw URLError(.badServerResponse) }
            source = ["sourceId":op,"foodId":op,"lineId":line,"segmentKey":segment,"foodName":food,"exclusionTags":tags,
                      "reservations":[],"matches":matches,"arrival":NSNull(),"usable":NSNull(),"confirmed":NSNull()]
        case "delivery.match":
            guard body["occurrenceId"] as? String == occurrence, body["mealRevision"] as? Int == 1,
                  body["ingredientId"] as? String == ingredient, let matched = body["matched"] as? Bool,
                  source?["sourceId"] as? String == body["sourceId"] as? String else { throw URLError(.badServerResponse) }
            matches = matched ? [["occurrenceId":occurrence,"mealRevision":1,"ingredientId":ingredient]] : []
            source?["matches"] = matches
        case "delivery.reserve":
            guard !matches.isEmpty, body["occurrenceId"] as? String == occurrence, body["groupId"] as? String == group,
                  body["ingredientId"] as? String == ingredient, body["mealRevision"] as? Int == 1,
                  let amount = body["quantity"], source?["sourceId"] as? String == body["sourceId"] as? String,
                  body["predecessorId"] as? String == reservation?["reservationId"] as? String else { throw URLError(.badServerResponse) }
            let head: [String:Any] = ["reservationId":op, "occurrenceId":occurrence, "mealRevision":1,
                                      "ingredientId":ingredient, "groupId":group, "quantity":amount]
            reservation = head
            source?["reservations"] = [head]
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
        recordedCommands[key] = bytes
        receipts[key] = receipt
        return receipt
    }
}
#endif
