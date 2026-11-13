#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import CryptoKit
import Foundation

/// The test bundle supplies public HTTP responses from the reservationFixture PostgreSQL household
/// in shared-meal-changes.integration.mjs. Six wraps arrived, five were confirmed usable and two
/// were reserved for lunch. Only the household's opaque shop ID is mapped to this fixture actor.
/// The due date is fixed in 2098. Review timestamps, device keys and checkout quote times are live.
final class SharedFallbackUIFixture {
    typealias Row = [String: Any]
    private let capture: Row
    private var accepted: [Row]
    private var registryRevision: Int
    private let expired: Bool
    private var dropReceipt: Bool
    private var published = false
    private var registryReceipts: [String: (Data, Row)] = [:]
    private var previews: [String: (Data, String)] = [:]
    private var publication: (String, Data, Row)?

    init?() {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--shared-fallback-fixture"),
              let value = process.environment["RITC_FALLBACK_SHOP"], let data = value.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? Row,
              let library = rows["library"] as? Row, let candidates = library["candidates"] as? [Row],
              let revision = library["registryRevision"] as? Int else { return nil }
        capture = rows
        accepted = candidates
        registryRevision = revision
        expired = process.arguments.contains("--expired-recovery-seat")
        dropReceipt = process.arguments.contains("--fallback-drop-first-accept")
    }

    private var desk: Row { capture[published ? "changedDesk" : "desk"] as! Row }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func equivalent(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return false }
        return (a as? NSObject)?.isEqual(b) == true
    }
    private func timestamp(_ date: Date = Date()) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }
    private func id(_ row: Row, _ key: String) -> String? { (row[key] as? String)?.lowercased() }

    func respond(_ route: String, method: String, input: Row, bytes: Data) throws -> (Int, Data)? {
        func ok(_ value: Any) throws -> (Int, Data) { (200, try json(value)) }
        func reject(_ status: Int, _ code: String) throws -> (Int, Data) { (status, try json(["error": ["code": code]])) }
        let stamp = capture["library"] as! Row
        let library = stamp.merging(["registryRevision": registryRevision, "candidates": accepted]) { _, value in value }
        let base = desk["base"] as! [String: Int]
        switch (method, route) {
        case ("GET", ""):
            var shop = capture["shop"] as! Row
            shop["shopId"] = stamp["shopId"]
            shop["meals"] = (capture["delivery"] as! Row)["meals"]
            // Keep sample store observations current for the fixture account.
            shop["quote"] = (capture["quote"] as! Row).merging(["observedAt": timestamp(Date().addingTimeInterval(-60)),
                "expiresAt": timestamp(Date().addingTimeInterval(3600))]) { _, value in value }
            return try ok(shop)
        case ("GET", "/delivery-evidence"), ("GET", "/pantry-lots"):
            let delivery = route == "/delivery-evidence"
            var row = capture[delivery ? "delivery" : "pantry"] as! Row
            row["supplyRevision"] = base["supplyRevision"]
            if delivery { row["recoveryRevision"] = base["recoveryRevision"] } else { row["pantryRevision"] = base["pantryRevision"] }
            return try ok(row)
        case ("GET", "/pantry-lots/coverage"), ("GET", "/delivery-evidence/coverage"):
            return try ok(capture[route.hasPrefix("/pantry") ? "joint" : "delivered"]!)
        case ("GET", "/meal-recovery"): return try ok(desk)
        case ("GET", "/meal-recovery/coverage"): return try ok(capture[published ? "changedEffective" : "effective"]!)
        case ("GET", "/accepted-fallbacks"): return try ok(library)
        case ("POST", "/accepted-fallbacks/source"):
            guard !expired else { return try reject(403, "membership_inactive") }
            guard let source = input["source"] as? Row, let expected = capture["source"] as? Row,
                  id(source,"revisionId") == id(expected,"revisionId"), id(source,"occurrenceId") == id(expected,"occurrenceId"),
                  equivalent(source["mealRevision"], expected["mealRevision"]) else { return try reject(409, "stale_fallback") }
            return try ok(library.merging(["source": source, "recipe": capture["recipe"]!]) { _, value in value })
        case ("POST", "/accepted-fallbacks"):
            guard let key = id(input,"clientKey"), let candidate = id(input,"candidateId"), let action = input["action"] as? String,
                  equivalent(input["shopRevision"], stamp["shopRevision"]), equivalent(input["authorityEpoch"], stamp["authorityEpoch"]),
                  input["reviewed"] as? Bool == true else { return try reject(409,"stale_fallback") }
            if let prior = registryReceipts[key] { return try bytes == prior.0 ? ok(prior.1) : reject(409,"key_reused") }
            if action == "accept", expired { return try reject(403,"membership_inactive") }
            let prior = accepted.first(where: { id($0,"candidateId") == candidate })
            guard input["registryRevision"] as? Int == registryRevision, prior?["revision"] as? Int == input["baseRevision"] as? Int else { return try reject(409,"stale_fallback") }
            let revision = (prior?["revision"] as? Int ?? 0) + 1
            if action == "accept", let recipe = input["recipe"] as? Row, let usual = input["usual"] as? Bool {
                accepted.removeAll { id($0,"candidateId") == candidate }
                accepted.append(["candidateId": candidate,"revision": revision,"recipe": recipe,"usual":usual])
                accepted.sort { id($0,"candidateId")! < id($1,"candidateId")! }
            } else if action == "revoke", prior != nil { accepted.removeAll { id($0,"candidateId") == candidate } }
            else { return try reject(409,"stale_fallback") }
            registryRevision += 1
            let receipt: Row = ["shopId":stamp["shopId"]!,"shopRevision":stamp["shopRevision"]!,"authorityEpoch":stamp["authorityEpoch"]!,
                "candidateId": candidate,"revision": revision,"registryRevision": registryRevision,"accepted": action == "accept"]
            registryReceipts[key] = (bytes,receipt)
            if dropReceipt && action == "accept" { dropReceipt = false; throw URLError(.networkConnectionLost) }
            return try ok(receipt)
        case ("POST", "/meal-recovery/options"):
            guard !expired else { return try reject(403,"membership_inactive") }
            return try ok(options(input, base: base, library: library))
        case ("POST", "/meal-recovery/preview"):
            guard !expired, !published, let intent = input["intent"] as? Row, let next = intent["replacement"] as? Row,
                  let option = (capture["options"] as! [Row]).first(where: { let i = $0["intent"] as! Row; return id(i["replacement"] as! Row,"revisionId") == id(next,"revisionId") }),
                  equivalent(input["base"], base) else { return try reject(409,"stale_preview") }
            let meals = desk["meals"] as! [Row]
            let projected = meals.map { id($0,"occurrenceId") == id(next,"occurrenceId") ? next : $0 }
            let before = (capture["before"] as! Row).merging(["meals": meals]) { _, value in value }
            let after = (option["after"] as! Row).merging(["meals": projected]) { _, value in value }
            let trip = option["kind"] as? String == "topUp", repeated = option["repeatRequired"] as? Bool == true
            let consent = (!repeated || intent["agreesToRepeat"] as? Bool == true) &&
                (!trip || (intent["agreesToExtraTrip"] as? Bool == true && intent["acceptsUnresolved"] as? Bool == true))
            let key = UUID().uuidString.lowercased(), digest = SHA256.hash(data: try json(input)).map { String(format:"%02x",$0) }.joined()
            if consent { previews[key] = (try json(input), digest) }
            return try ok(["shopId": stamp["shopId"]!, "placedRevision": desk["placedRevision"]!, "base":base,"asOf":timestamp(),
                "before":before,"after":after,"previewId":key,"previewDigest":digest,"expiresAt":timestamp(Date().addingTimeInterval(600)),
                "foodConfirmed":!trip,"timingConfirmed":true,"feasible":!trip,"consentSatisfied":consent,"repeatRequired":repeated] as Row)
        case ("POST", "/commands") where input["kind"] as? String == "mealRecovery.apply":
            guard !expired, let key = id(input,"clientKey"), var body = input["body"] as? Row else { return try reject(403,"membership_inactive") }
            if let prior = publication, prior.0 == key { return try bytes == prior.1 ? ok(prior.2) : reject(409,"key_reused") }
            guard let preview = (body.removeValue(forKey:"previewId") as? String)?.lowercased(),
                  let digest = body.removeValue(forKey:"previewDigest") as? String, let checked = previews[preview], checked.1 == digest,
                  try checked.0 == json(body), !published, let intent = body["intent"] as? Row, let next = intent["replacement"] as? Row,
                  let receipt = capture["receipt"] as? Row, id(receipt,"revisionId") == id(next,"revisionId") else { return try reject(409,"stale_preview") }
            publication = (key, bytes, receipt); published = true
            return try ok(receipt)
        default: return nil
        }
    }

    /// Replay the two verified comparisons only when the inputs match the recorded household.
    /// Client-generated pack IDs and the timestamp bind to this run's actual review.
    private func options(_ input: Row, base: [String: Int], library: Row) throws -> Row {
        let pool = capture["options"] as! [Row]
        let targetID = id(capture["source"] as! Row,"occurrenceId")
        let target = (desk["meals"] as! [Row]).first { id($0,"occurrenceId") == targetID }!
        guard !published, equivalent(input["base"],base), id(input,"occurrenceId") == targetID,
              let reviews = input["reviews"] as? [Row] else { throw URLError(.badServerResponse) }
        let trip = input["trip"] as? Row
        let now = timestamp()
        var choices = [Row](), conditional = [Row]()
        for review in reviews {
            guard let candidate = id(review,"candidateId"), accepted.contains(where: { id($0,"candidateId") == candidate }),
                  var option = pool.first(where: { id($0,"candidateId") == candidate }), var intent = option["intent"] as? Row,
                  let recorded = intent["fallback"] as? Row, let expected = recorded["review"] as? Row,
                  equivalent(review["revision"],expected["revision"]), review["advanceStepsCompleted"] as? Bool == false,
                  let row = (review["ingredients"] as? [Row])?.only,
                  let original = (expected["ingredients"] as? [Row])?.only, id(row,"ingredientId") == id(original,"ingredientId"),
                  let sourceIds = row["sourceIds"] as? [String],
                  sourceIds.map({$0.lowercased()}) == original["sourceIds"] as? [String],
                  let next = intent["replacement"] as? Row, equivalent(review["remainingElapsedMinutes"],next["remainingElapsedMinutes"])
            else { throw URLError(.badServerResponse) }
            if option["kind"] as? String == "topUp" {
                guard let trip, let offer = row["offer"] as? Row else { conditional.append(capture["rejected"] as! Row); continue }
                let expectedOffer = original["offer"] as! Row
                guard equivalent(trip,recorded["trip"]), ["label","priceMinor","availablePacks","exclusionTags"].allSatisfy({equivalent(offer[$0], expectedOffer[$0])}),
                      let qty = offer["usablePerPack"] as? Row, let recordedQty = expectedOffer["usablePerPack"] as? Row,
                      equivalent(qty["amount"], recordedQty["amount"]), equivalent(qty["unit"], recordedQty["unit"])
                else { throw URLError(.badServerResponse) }
            }
            intent["reviewedAt"] = now
            intent["fallback"] = ["review": review,"trip": trip as Any? ?? NSNull()]
            option["intent"] = intent
            choices.append(option)
        }
        choices.sort { ($0["packCount"] as! Int) < ($1["packCount"] as! Int) }
        let usual = accepted.first(where: {$0["usual"] as? Bool == true}).flatMap { id($0,"candidateId") }
        return ["shopId": library["shopId"]!, "asOf":now,"target":target,"base":base,"nextReviewIndex":NSNull(),
                "options":choices,"conditional":conditional,"registryRevision":registryRevision,
                "usualMinutes":choices.first(where:{id($0,"candidateId") == usual})?["minutes"] ?? NSNull()]
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
