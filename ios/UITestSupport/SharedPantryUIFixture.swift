#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import CoreDomain
import CryptoKit
import Foundation

/// One household, placed shop and manual batch. All stock and commitments start empty.
final class SharedPantryFixtureRecords {
    typealias Object = [String:Any]
    typealias Failure = SharedDeliveryFixtureRecords.CookFailure

    private struct Need {
        let occurrence: String
        let ingredient: String
        let group: String
        let title: String
        let groupName: String
        let portions: Int
        let protected: Bool

        var quantity: Object {
            ["amount":["numerator":portions,"denominator":1],"unit":"count","originalLiteral":String(portions)]
        }
        var target: Object { ["occurrenceId":occurrence,"mealRevision":1,"ingredientId":ingredient] }
        var row: Object {
            target.merging(["groupIds":[group],"required":quantity,"protected":protected]) { _, new in new }
        }
        var meal: Object {
            let planning: Object = ["groups":[["id":group,"name":groupName,"protected":protected,
                "servings":["numerator":portions,"denominator":1]]],
                "ingredients":[["id":ingredient,"name":"Tortillas","groupIds":[group],"exclusions":[],"quantity":quantity]]]
            return ["occurrenceId":occurrence,"revision":1,"meal":["title":title,"day":"2026-11-08",
                "kind":protected ? "lunch":"dinner","portions":portions,"protected":protected,"planning":planning]]
        }
    }
    private let needs = [
        Need(occurrence:"aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ingredient:"aaaaaaa2-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
             group:"aaaaaaa3-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title:"Lunch wraps", groupName:"School lunch", portions:2, protected:true),
        Need(occurrence:"bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbbb", ingredient:"bbbbbbb2-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
             group:"bbbbbbb3-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title:"Dinner wraps", groupName:"Dinner plates", portions:4, protected:false)
    ]
    var meals: [Object] { needs.map(\.meal) }
    var revision = 0
    private var lot: Object?
    private var observation: Object?
    private var selected = false
    private var matched = Set<String>()
    private var reservations: [String:Object] = [:]

    private func scope(shop: String, supply: Int) -> Object {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["shopId":shop,"shopRevision":2,"placedRevision":1,"authorityEpoch":1,"supplyRevision":supply,
                "pantryRevision":revision,"asOf":timestamp.string(from: Date())]
    }
    func page(shop: String, supply: Int) -> Object {
        var result = scope(shop: shop, supply: supply)
        let rows = lot.map { batch -> [Object] in
            var row = batch
            row["observation"] = observation as Any? ?? NSNull()
            row["selected"] = selected
            row["matches"] = needs.filter { matched.contains($0.occurrence) }.map(\.target)
            row["reservations"] = needs.compactMap { reservations[$0.occurrence] }
            return [row]
        }
        result["lots"] = rows ?? []
        result["nextCursor"] = NSNull()
        return result
    }
    private func fraction(_ value: Rational) -> Object {
        ["numerator":String(value.numerator),"denominator":String(value.denominator)]
    }
    private func amount(_ raw: Any?) throws -> Rational? {
        if raw is NSNull || raw == nil { return nil }
        guard let q = raw as? Object, q["unit"] as? String == "count", let f = q["amount"] as? [String:Int],
              let n = f["numerator"], let d = f["denominator"] else { throw Failure.invalid }
        return try Rational(Int64(n), Int64(d))
    }
    private func rows(usable: Rational?) throws -> [Object] {
        var remaining = usable ?? .zero
        let lotID = lot?["lotId"] as? String
        var backed = [String:Rational]()
        for need in needs where matched.contains(need.occurrence) {
            if let claim = try amount(reservations[need.occurrence]?["quantity"]) {
                let held = min(remaining, claim)
                backed[need.occurrence] = held
                remaining = try remaining.subtracting(held)
            }
        }
        return try needs.map { need in
            let required = try Rational(Int64(need.portions))
            let held = backed[need.occurrence] ?? .zero
            let available = selected && matched.contains(need.occurrence)
            let extra = available ? min(remaining, try required.subtracting(held)) : .zero
            remaining = try remaining.subtracting(extra)
            let covered = try held.adding(extra)
            let location = lot?["location"] as? String
            var issues: [String] = available ? (usable == nil ? ["unconfirmed"] : []) : ["noMatch"]
            var pins = [Object]()
            if let lotID, let pin = reservations[need.occurrence], let id = pin["reservationId"],
               let claim = try amount(pin["quantity"]) {
                pins = [["sourceId":lotID,"reservationId":id,"requested":fraction(claim),"backed":fraction(held)]]
                if claim > held { issues.append("reservationShortfall") }
            }
            var row = need.row
            var allocations = [Object]()
            if covered > .zero, let lotID, let location {
                allocations.append(["sourceId":lotID,"kind":location,"amount":fraction(covered)])
            }
            row["allocations"] = allocations
            row["issues"] = issues
            row["reservations"] = pins
            row["covered"] = fraction(covered)
            row["missing"] = fraction(try required.subtracting(covered))
            row["delivered"] = fraction(.zero)
            row["pantry"] = fraction(location == "pantry" ? covered : .zero)
            row["freezer"] = fraction(location == "freezer" ? covered : .zero)
            return row
        }
    }
    func coverage(shop: String, supply: Int, deliveryOnly: Bool = false) throws -> Object {
        var result = scope(shop: shop, supply: supply)
        result["unplannedOccurrenceIds"] = [String]()
        if deliveryOnly {
            result["needs"] = try needs.map { need in
                var row = need.row
                row["covered"] = fraction(.zero); row["missing"] = fraction(try Rational(Int64(need.portions)))
                row["issues"] = ["noMatch"]; row["reservations"] = [Object](); row["allocations"] = [Object]()
                return row
            }
        } else {
            result["needs"] = try rows(usable: amount(observation?["quantity"]))
        }
        return result
    }
    private func checkRevisions(_ body: Object, supply: Int) throws {
        guard body["supplyRevision"] as? Int == supply, body["pantryRevision"] as? Int == revision else { throw Failure.staleSupply }
    }
    private func checkLot(_ body: Object) throws {
        guard let id = body["lotId"] as? String, id == lot?["lotId"] as? String else { throw Failure.invalid }
    }
    private func checkPredecessor(_ body: Object, current: Any?) throws {
        guard let id = body["predecessorId"], id is NSNull || id is String,
              id as? String == current as? String else { throw Failure.staleSupply }
    }
    func preview(shop: String, supply: Int, body: Object) throws -> Object {
        try checkRevisions(body, supply: supply)
        try checkLot(body)
        try checkPredecessor(body, current: observation?["observationId"])
        guard body["confirmedAt"] is String, let quantity = body["quantity"] else { throw Failure.invalid }
        let before = try rows(usable: amount(observation?["quantity"])), after = try rows(usable: amount(quantity))
        var impacts = [Object]()
        for (i, need) in needs.enumerated() where matched.contains(need.occurrence) {
            var impact = need.target
            impact["groupIds"] = [need.group]; impact["required"] = need.quantity
            impact["beforeCovered"] = before[i]["covered"]; impact["afterCovered"] = after[i]["covered"]
            impact["beforeMissing"] = before[i]["missing"]; impact["afterMissing"] = after[i]["missing"]
            impact["beforeReservations"] = before[i]["reservations"]; impact["afterReservations"] = after[i]["reservations"]
            impacts.append(impact)
        }
        var result = scope(shop: shop, supply: supply)
        let bytes = try JSONSerialization.data(withJSONObject: ["shop":shop,"body":body,"needs":impacts], options: [.sortedKeys])
        result["previewDigest"] = SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
        result["lotId"] = body["lotId"]; result["needs"] = impacts; result["otherShopsAffected"] = false; result["otherShopsCommitted"] = false
        return result
    }

    func record(shop: String, supply: Int, kind: String, body: Object) throws -> Object {
        try checkRevisions(body, supply: supply)
        if kind != "pantry.create" { try checkLot(body) }
        let op = UUID().uuidString.lowercased()
        switch kind {
        case "pantry.create":
            guard lot == nil, let name = body["foodName"] as? String, !name.isEmpty,
                  let tags = body["exclusionTags"] as? [String], let location = body["location"] as? String,
                  ["pantry","freezer"].contains(location), let stored = body["storedAt"], let first = body["useFirstAt"] else { throw Failure.invalid }
            lot = ["lotId":op,"origin":"manual","foodName":name,"exclusionTags":tags,"location":location,"storedAt":stored,"useFirstAt":first]
        case "pantry.select":
            guard let next = body["selected"] as? Bool, selected != next, next || matched.isEmpty else { throw Failure.invalid }
            selected = next
        case "pantry.observe":
            var reviewed = body
            guard let digest = reviewed.removeValue(forKey:"previewDigest") as? String,
                  try preview(shop: shop, supply: supply, body: reviewed)["previewDigest"] as? String == digest else { throw Failure.staleSupply }
            observation = ["observationId":op,"confirmedAt":body["confirmedAt"]!,"quantity":body["quantity"]!]
        case "pantry.match", "pantry.reserve":
            guard selected, body["mealRevision"] as? Int == 1,
                  let need = needs.first(where: { $0.occurrence == body["occurrenceId"] as? String && $0.ingredient == body["ingredientId"] as? String })
            else { throw Failure.invalid }
            if kind == "pantry.match" {
                let active = try amount(reservations[need.occurrence]?["quantity"])
                guard let add = body["matched"] as? Bool, add != matched.contains(need.occurrence), add || active == nil else { throw Failure.invalid }
                if add { matched.insert(need.occurrence) } else { matched.remove(need.occurrence) }
            } else {
                guard matched.contains(need.occurrence), body["groupId"] as? String == need.group,
                      let quantity = body["quantity"] else { throw Failure.invalid }
                let current = reservations[need.occurrence]
                try checkPredecessor(body, current: current?["reservationId"])
                let prior = try amount(current?["quantity"])
                if let proposed = try amount(quantity) {
                    guard proposed > .zero, proposed <= (try Rational(Int64(need.portions))) else { throw Failure.invalid }
                    if proposed > (prior ?? .zero) {
                        let used = try reservations.filter { $0.key != need.occurrence }.values.reduce(proposed) {
                            try $0.adding(amount($1["quantity"]) ?? .zero)
                        }
                        guard let supply = try amount(observation?["quantity"]), used <= supply else { throw Failure.invalid }
                    }
                } else if prior == nil { throw Failure.invalid }
                var pin = need.target
                pin["reservationId"] = op; pin["quantity"] = quantity; pin["groupId"] = need.group
                reservations[need.occurrence] = pin
            }
        default: throw Failure.invalid
        }
        revision += 1
        return ["kind":kind,"operationId":op,"shopId":shop,"shopRevision":2,"authorityEpoch":1,"disposition":"recorded",
                "lotId":lot!["lotId"]!,"pantryRevision":revision,"supplyRevision":supply]
    }
}
#endif
